import Foundation

/// A single note file written into a freshly created workspace's `Notes/` directory.
///
/// Hosts compose their own seed content by building a ``WorkspaceSeedNotes`` value from
/// custom `WorkspaceSeedNote` instances, or disable seeding entirely with
/// ``WorkspaceSeedNotes/none``.
public struct WorkspaceSeedNote: Sendable, Equatable {
    /// The filename, relative to the workspace's `Notes/` directory (e.g. `"Welcome.md"`).
    public let filename: String
    /// The file contents.
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }

    /// The default welcome note previously written unconditionally by `createTimeline`.
    public static let welcome = WorkspaceSeedNote(
        filename: "Welcome.md",
        content: """
        # Welcome to Your PositronicKit Timeline

        This timeline is your private workspace. You can use the `Notes/` directory \
        in the Primary Workspace to store information that should persist and influence \
        your behavior across turns.

        ## System Orientation
        - Primary Workspace: Your runtime-managed sandbox.
        - Attached Workspaces: Directories mapped during this timeline.
        - Context Depth: Use the `Notes/` directory for long-term facts and project-specific guidance.
        """
    )

    /// The default project-tracking note previously written unconditionally by `createTimeline`.
    public static let project = WorkspaceSeedNote(
        filename: "Project.md",
        content: """
        # Project Goals & Progress

        Use this note to track the active objective and your current progress.

        ## Active Objective
        [Describe what the user wants to achieve here]

        ## Key Milestones
        - [ ] Milestone 1
        - [ ] Milestone 2

        ## Decisions & Context
        Record any critical decisions made during the timeline here.
        """
    )
}

/// The set of note files seeded into a freshly created timeline workspace.
///
/// Use ``WorkspaceSeedNotes/default`` to restore the prior built-in seeding behavior
/// (`Welcome.md` + `Project.md`), ``WorkspaceSeedNotes/none`` to disable seeding, or build a
/// custom set from ``WorkspaceSeedNote`` values to replace the opinionated content.
public struct WorkspaceSeedNotes: Sendable, Equatable {
    /// The notes to write, in declaration order.
    public let notes: [WorkspaceSeedNote]

    public init(notes: [WorkspaceSeedNote]) {
        self.notes = notes
    }

    public init(_ notes: WorkspaceSeedNote...) {
        self.notes = notes
    }

    /// The built-in default: `Welcome.md` and `Project.md`.
    public static let `default` = WorkspaceSeedNotes(.welcome, .project)

    /// No notes are written.
    public static let none = WorkspaceSeedNotes()
}

/// How `TimelineManager` provisions and owns the per-timeline filesystem workspace.
///
/// Before PKRR-029 every timeline unconditionally created a directory under the (temp-dir)
/// workspace root and wrote opinionated `Notes/Welcome.md` and `Notes/Project.md` files into it,
/// with no cleanup on eviction or deletion. `WorkspaceProfile` makes that behavior explicit and
/// opt-in, and adds a side-effect-free default plus a self-cleaning ephemeral mode.
///
/// - `.noWorkspace` (the default): no directory is created, no notes are written, and no
///   workspace record is persisted. `Timeline.workingDirectory` stays `nil`. A minimal chat
///   runtime (one-shot `complete`/`stream`, or `createTimeline` with the default configuration)
///   has **no filesystem side effects**.
/// - `.ephemeralWorkspace`: PositronicKit owns a scratch directory under `root`. The directory
///   is created on `createTimeline` and removed on `evictTimelineFromMemory(id:)` and
///   `deleteTimelinePermanently(id:)`. Use this when the runtime needs transient filesystem
///   state that must not outlive the timeline.
/// - `.hostManaged`: PositronicKit creates per-timeline directories under `root` (and seeds
///   notes) but does **not** remove them — the host owns retention and cleanup. This preserves
///   the behavior of callers that pass an explicit `workspaceRoot`.
public enum WorkspaceProfile: Sendable {
    /// No filesystem workspace is created for timelines. `createTimeline` skips directory
    /// creation, note seeding, and workspace-record persistence; `Timeline.workingDirectory`
    /// is `nil`. This is the default.
    case noWorkspace

    /// PositronicKit owns an ephemeral per-timeline scratch directory under `root`.
    ///
    /// The directory is created on `createTimeline` and removed on
    /// `evictTimelineFromMemory(id:)` and `deleteTimelinePermanently(id:)`. `seedNotes`
    /// controls which note files are written into the new directory's `Notes/` folder.
    case ephemeralWorkspace(root: URL, seedNotes: WorkspaceSeedNotes = .default)

    /// The host owns the workspace root and its retention policy.
    ///
    /// PositronicKit creates per-timeline directories under `root` (and seeds notes per
    /// `seedNotes`) but does not remove them on eviction or deletion — the host is responsible
    /// for cleanup. This is the behavior callers got before PKRR-029 when passing an explicit
    /// `workspaceRoot`.
    case hostManaged(root: URL, seedNotes: WorkspaceSeedNotes = .default)
}

public extension WorkspaceProfile {
    /// The filesystem root the bundled catalog/resolver should anchor against, if any.
    ///
    /// `.noWorkspace` has no root; the facade falls back to a process-temporary path for the
    /// catalog so agent-private workspace provisioning (a separate, opt-in path) still has a
    /// root to anchor to. Timeline creation itself is unaffected: `.noWorkspace` creates no
    /// timeline directory regardless of this value.
    var catalogRoot: URL? {
        switch self {
        case .noWorkspace: nil
        case let .ephemeralWorkspace(root, _): root
        case let .hostManaged(root, _): root
        }
    }

    /// The seed-notes policy for this profile (`.none` for `.noWorkspace`).
    var seedNotes: WorkspaceSeedNotes {
        switch self {
        case .noWorkspace: .none
        case let .ephemeralWorkspace(_, notes): notes
        case let .hostManaged(_, notes): notes
        }
    }

    /// Whether PositronicKit owns the lifecycle (creation + cleanup) of the per-timeline
    /// directory. `true` for `.ephemeralWorkspace`, `false` otherwise.
    var ownsDirectoryLifecycle: Bool {
        switch self {
        case .ephemeralWorkspace: true
        case .noWorkspace, .hostManaged: false
        }
    }

    /// Whether a per-thread directory and workspace record should be provisioned at all.
    var provisionsThreadWorkspace: Bool {
        switch self {
        case .noWorkspace: false
        case .ephemeralWorkspace, .hostManaged: true
        }
    }

    /// Deprecated timeline spelling retained for source compatibility.
    @available(*, deprecated, renamed: "provisionsThreadWorkspace", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    var provisionsTimelineWorkspace: Bool { provisionsThreadWorkspace }
}
