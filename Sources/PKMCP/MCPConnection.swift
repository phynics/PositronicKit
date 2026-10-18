import Foundation
import MCP
import PKContracts

/// Owns one live MCP server connection and its lifecycle.
///
/// A connection connects lazily on first use, performs the MCP initialize handshake, caches the
/// paginated tool list, and reconnects on the next call after a failure. A
/// `notifications/tools/list_changed` notification invalidates the cache only for the next catalog
/// capture, never for a catalog already admitted.
///
/// The connection is the unit a profile pools: `.perWorkspace` gives each session Workspace a
/// private connection, while `.pooled` hands the same connection to every session Workspace for
/// the profile.
actor MCPConnection {
    private let configuration: MCPServerConfiguration
    private let secretResolver: any MCPSecretResolver
    private let transportFactory: MCPTransportFactory?

    private var client: MCP.Client?
    #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    private var process: Process?
    #endif
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var cachedTools: [ToolReference]?
    private var lastConnectionFailed = false

    init(
        configuration: MCPServerConfiguration,
        secretResolver: any MCPSecretResolver,
        transportFactory: MCPTransportFactory?
    ) {
        self.configuration = configuration
        self.secretResolver = secretResolver
        self.transportFactory = transportFactory
    }

    /// Whether the most recent connection attempt succeeded. The connection is optimistic before
    /// the first connection so a lazily connected server is still offered to the model.
    var isHealthy: Bool {
        get async { !lastConnectionFailed }
    }

    // MARK: - Tools

    func listTools() async throws -> [ToolReference] {
        if let cachedTools {
            return cachedTools
        }
        do {
            let client = try await ensureConnected()
            var references: [ToolReference] = []
            var cursor: String?
            repeat {
                let (page, nextCursor) = try await client.listTools(cursor: cursor)
                references.append(contentsOf: page.map {
                    MCPToolMapping.toolReference(for: $0, permission: configuration.permission)
                })
                cursor = nextCursor
            } while cursor != nil
            cachedTools = references
            return references
        } catch {
            await markUnhealthy()
            throw error
        }
    }

    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        let client: MCP.Client
        do {
            client = try await ensureConnected()
        } catch {
            return .failure(message(for: error))
        }

        let request = CallTool.request(
            .init(name: id, arguments: MCPToolMapping.value(from: parameters))
        )
        let context: RequestContext<CallTool.Result>
        do {
            context = try await client.send(request)
        } catch {
            await markUnhealthy()
            return .failure(message(for: error))
        }

        let result: CallTool.Result
        do {
            result = try await awaitResult(context, client: client, toolID: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await markUnhealthy()
            return .failure(message(for: error))
        }

        let output = MCPToolMapping.output(
            from: result.content,
            structuredContent: result.structuredContent
        )
        if result.isError == true {
            return .failure(output.isEmpty ? "MCP tool '\(id)' reported an error." : output)
        }
        return .success(output)
    }

    // MARK: - Connection

    private func ensureConnected() async throws -> MCP.Client {
        if let client {
            return client
        }
        let transport: any MCP.Transport
        do {
            transport = try await makeTransport()
        } catch {
            lastConnectionFailed = true
            throw error
        }

        let newClient = MCP.Client(name: "PositronicKit", version: "1.0.0")
        await newClient.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            await self?.invalidateTools()
        }
        do {
            _ = try await newClient.connect(transport: transport)
        } catch {
            await newClient.disconnect()
            terminateProcess()
            lastConnectionFailed = true
            throw MCPWorkspaceError.connectionFailed(message(for: error))
        }
        client = newClient
        lastConnectionFailed = false
        return newClient
    }

    private func markUnhealthy() async {
        lastConnectionFailed = true
        cachedTools = nil
        if let client {
            await client.disconnect()
        }
        client = nil
        terminateProcess()
    }

    private func invalidateTools() {
        cachedTools = nil
    }

    // MARK: - Transport construction

    private func makeTransport() async throws -> any MCP.Transport {
        if let transportFactory {
            return try await transportFactory(configuration)
        }
        switch configuration.transport {
        case let .streamableHTTP(url, headers):
            var resolvedHeaders: [String: String] = [:]
            for (key, value) in headers {
                resolvedHeaders[key] = try await resolved(value)
            }
            return HTTPClientTransport(
                endpoint: url,
                requestModifier: { request in
                    var request = request
                    for (key, value) in resolvedHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    return request
                }
            )
        case let .stdio(executable, arguments, environment):
            return try await makeStdioTransport(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        }
    }

    private func makeStdioTransport(
        executable: String,
        arguments: [String],
        environment: [String: MCPSecretValue]
    ) async throws -> any MCP.Transport {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            throw MCPWorkspaceError.unsupportedTransport("stdio is unavailable on this platform")
        #else
            var resolvedEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                resolvedEnvironment[key] = try await resolved(value)
            }

            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = arguments
            child.environment = resolvedEnvironment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            child.standardInput = stdinPipe
            child.standardOutput = stdoutPipe
            child.standardError = FileHandle.standardError

            do {
                try child.run()
            } catch {
                throw MCPWorkspaceError.connectionFailed(
                    "could not start '\(executable)': \(message(for: error))"
                )
            }

            process = child
            inputPipe = stdinPipe
            outputPipe = stdoutPipe

            let input = stdoutPipe.fileHandleForReading.fileDescriptor
            let output = stdinPipe.fileHandleForWriting.fileDescriptor
            return StdioTransport(input: .init(rawValue: input), output: .init(rawValue: output))
        #endif
    }

    private func terminateProcess() {
        #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        #endif
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        inputPipe = nil
        outputPipe = nil
    }

    // MARK: - Call

    private func awaitResult(
        _ context: RequestContext<CallTool.Result>,
        client: MCP.Client,
        toolID: String
    ) async throws -> CallTool.Result {
        let timeout = configuration.callTimeout
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CallTool.Result.self) { group in
                group.addTask {
                    try await context.value
                }
                if let timeout {
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw MCPWorkspaceError.callTimedOut(
                            tool: toolID,
                            seconds: timeout.totalSeconds
                        )
                    }
                }
                do {
                    guard let result = try await group.next() else {
                        throw MCPWorkspaceError.serverError("MCP call returned no result")
                    }
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    try? await client.cancelRequest(context.requestID, reason: "cancelled")
                    throw error
                }
            }
        } onCancel: {
            Task { try? await client.cancelRequest(context.requestID, reason: "turn cancelled") }
        }
    }

    private func resolved(_ value: MCPSecretValue) async throws -> String {
        switch value {
        case let .value(value):
            return value
        case let .secret(reference):
            return try await secretResolver.resolveSecret(reference)
        }
    }

    private func message(for error: Error) -> String {
        if let pkError = error as? any PKError {
            return pkError.userFriendlyMessage
        }
        return error.localizedDescription
    }
}

private extension Duration {
    /// This duration as fractional seconds for a model-facing message.
    var totalSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
