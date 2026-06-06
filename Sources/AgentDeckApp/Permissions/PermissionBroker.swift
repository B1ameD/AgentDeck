import Foundation

public struct PermissionRequest: Equatable, Sendable {
    public enum Risk: Equatable, Sendable {
        case normalAgentProcess
        case runsShellCommand
        case readsFiles
        case modifiesFiles
    }

    public var agentName: String
    public var command: String
    public var workingDirectory: String
    public var risk: Risk

    public init(agentName: String, command: String, workingDirectory: String, risk: Risk) {
        self.agentName = agentName
        self.command = command
        self.workingDirectory = workingDirectory
        self.risk = risk
    }
}

public enum PermissionDecision: Equatable, Sendable {
    case allow
    case ask
    case deny
}

public struct PermissionBroker: Sendable {
    public init() {}

    public func defaultDecision(for request: PermissionRequest) -> PermissionDecision {
        switch request.risk {
        case .normalAgentProcess:
            return .allow
        case .runsShellCommand, .readsFiles, .modifiesFiles:
            return .ask
        }
    }
}
