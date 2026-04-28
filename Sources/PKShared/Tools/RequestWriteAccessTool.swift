import Foundation
import JSONSchemaBuilder

@available(*, deprecated, message: "Downstream hosts should model write-access escalation explicitly instead of relying on this legacy tool stub.")
/// A legacy tool used by the LLM to request permission to modify files in the active workspace.
/// When executed downstream, this triggers a user prompt to upgrade the workspace trust level.
public struct RequestWriteAccessTool: Tool {
    public let id = "request_write_access"
    public let name = "Request Write Access"
    public let description =
        "Request permission from the user to modify files in the active workspace. " +
        "Call this tool when you need to create, write, edit, or delete files " +
        "but the workspace is currently in read-only mode."
    public let requiresPermission = false

    public init() {}

    public func canExecute() async -> Bool {
        return true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "reason") {
                JSONString().description(
                    "The reason why write access is needed. This will be shown to the user."
                )
            }
            .required()
        }.schema
    }

    public func execute(parameters _: [String: Any]) async throws -> ToolResult {
        // This tool is handled downstream. ToolRouter defers it automatically based on the
        // workspace location. This execute() path is only reached as a fallback.
        .failure("This tool requires downstream handling")
    }
}
