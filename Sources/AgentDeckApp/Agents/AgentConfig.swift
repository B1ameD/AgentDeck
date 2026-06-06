import Foundation

public struct AgentConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var workingDirectoryPolicy: WorkingDirectoryPolicy
    public var inputMode: InputMode
    public var outputMode: OutputMode
    public var supportsStop: Bool
    public var stopSignal: StopSignal
    /// 仅当 workingDirectoryPolicy == .fixedPath 时生效：会话固定运行于此目录（支持 ~ 展开）。
    public var fixedWorkingDirectory: String?
    /// 仅当 stopSignal == .customCommand 时生效：停止时执行的命令（首项为可执行文件路径）。
    public var stopCommand: [String]?

    public init(
        id: String,
        name: String,
        command: String,
        args: [String],
        env: [String: String],
        workingDirectoryPolicy: WorkingDirectoryPolicy,
        inputMode: InputMode,
        outputMode: OutputMode,
        supportsStop: Bool,
        stopSignal: StopSignal,
        fixedWorkingDirectory: String? = nil,
        stopCommand: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.workingDirectoryPolicy = workingDirectoryPolicy
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.supportsStop = supportsStop
        self.stopSignal = stopSignal
        self.fixedWorkingDirectory = fixedWorkingDirectory
        self.stopCommand = stopCommand
    }

    public func validate() throws {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyID
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyName
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyCommand
        }
        // 选了 fixedPath 却没给路径、选了 customCommand 却没给命令 —— 都视为坏配置，
        // 由 AgentRegistry 跳过并记录警告，而不是静默回落（schema 不再撒谎）。
        if workingDirectoryPolicy == .fixedPath,
           fixedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            throw ValidationError.missingFixedDirectory
        }
        if stopSignal == .customCommand, stopCommand?.isEmpty ?? true {
            throw ValidationError.missingStopCommand
        }
    }

    public enum WorkingDirectoryPolicy: String, Codable, Equatable, Sendable {
        case workspace
        case home
        case fixedPath
        case perSessionPrompt
    }

    public enum InputMode: String, Codable, Equatable, Sendable {
        case stdin
        case oneShotArgument
    }

    public enum OutputMode: String, Codable, Equatable, Sendable {
        case stream
        case ansiStream
        case jsonLines
    }

    public enum StopSignal: String, Codable, Equatable, Sendable {
        case interrupt
        case terminate
        case customCommand
    }

    public enum ValidationError: Error, Equatable {
        case emptyID
        case emptyName
        case emptyCommand
        case missingFixedDirectory
        case missingStopCommand
    }

    /// agent 家族：决定按哪套 CLI 参数约定来构造命令行。
    /// 由内置 id 推导，自定义配置一律视为 .custom（不注入任何未知 flag）。
    public enum Kind: Equatable, Sendable {
        case claudeCode
        case codex
        case openCode
        case pi
        case custom
    }

    public var kind: Kind {
        switch id {
        case "claude-code": .claudeCode
        case "codex": .codex
        case "opencode": .openCode
        case "pi-local": .pi
        default: .custom
        }
    }

    public func runtimeEnvironment(claudeSettingsURL: URL = ClaudeSettings.defaultSettingsURL) -> [String: String] {
        switch kind {
        case .claudeCode:
            return ClaudeSettings.loadEnvironment(settingsURL: claudeSettingsURL)
                .merging(env) { _, configured in configured }
        case .openCode:
            return openCodeRuntimeEnvironment()
        case .codex, .pi, .custom:
            return env
        }
    }

    private func openCodeRuntimeEnvironment() -> [String: String] {
        if env["OPENCODE_CONFIG"] != nil || env["OPENCODE_CONFIG_CONTENT"] != nil {
            return env
        }
        let processEnv = ProcessInfo.processInfo.environment
        if processEnv["OPENCODE_CONFIG"] != nil || processEnv["OPENCODE_CONFIG_CONTENT"] != nil {
            return env
        }
        var runtime = env
        runtime["OPENCODE_CONFIG_CONTENT"] = #"{"snapshot":false}"#
        return runtime
    }
}
