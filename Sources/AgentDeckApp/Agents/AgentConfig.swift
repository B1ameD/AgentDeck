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
    /// 传输方式：`cli`（默认，进程 stdout/JSONL）或 `acp`（Agent Client Protocol，JSON-RPC over stdio）。
    /// 旧配置缺该键 → 解码为 nil → `resolvedTransport` 回落 `.cli`，不破坏现有 agent。
    /// acp 时 command/args 指向 ACP 适配器（如 `npx -y @agentclientprotocol/claude-agent-acp`）。
    public var transport: Transport?

    /// 实际传输方式（缺省回落 cli）。
    public var resolvedTransport: Transport { transport ?? .cli }

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
        stopCommand: [String]? = nil,
        transport: Transport? = nil
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
        self.transport = transport
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

    /// 非致命问题（配置仍会加载，但大概率跑不起来）：与 validate()（致命→跳过）分级（#30）。
    /// - 可执行文件：绝对/相对路径查可执行位；裸名先按 PATH 解析（运行时还会按登录 shell PATH 再解析一次，
    ///   故裸名解析不到只是提醒）。
    /// - env 键名：空/含 `=`/含空格 都会让子进程环境注入静默出错。
    /// - 固定工作目录：不存在则每次运行都会失败。
    public func validationWarnings(
        executableResolver: (String) -> String? = AgentDetection.resolveExecutable(named:)
    ) -> [String] {
        var warnings: [String] = []
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.contains("/") {
            let expanded = (cmd as NSString).expandingTildeInPath
            if !FileManager.default.isExecutableFile(atPath: expanded) {
                warnings.append("可执行文件不存在或缺少执行权限：\(cmd)")
            }
        } else if executableResolver(cmd) == nil {
            warnings.append("PATH 中找不到「\(cmd)」（运行时会再按登录 shell PATH 解析，可能仍可用）")
        }
        for key in env.keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("=") || trimmed.contains(" ") {
                warnings.append("环境变量键名非法：「\(key)」")
            }
        }
        if workingDirectoryPolicy == .fixedPath, let path = fixedWorkingDirectory {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) || !isDirectory.boolValue {
                warnings.append("固定工作目录不存在：\(path)")
            }
        }
        return warnings
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

    public enum Transport: String, Codable, Equatable, Sendable {
        case cli
        case acp
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

    /// 该后端是否能让 plan/build 模式真正生效。pi/custom 为未知 CLI，
    /// CLIInvocationBuilder 走 passthrough 不注入任何 mode 语义，故视为不支持。
    /// 单一事实来源：UI 模式芯片灰显与 /plan、/build 斜杠菜单可用性均据此判定。
    public var supportsPlanMode: Bool {
        switch kind {
        case .pi, .custom: false
        case .claudeCode, .codex, .openCode: true
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
        // snapshot:false 关闭快照；permission 在配置层预先放行工具(edit/bash/webfetch)实现非交互自治
        // ——否则 serve 模式默认对工具「ask」→ 触发 permission.asked，运行卡在等授权(#opencode 挂起)。
        // question/plan_enter/plan_exit 仍 deny(避免交互式挂起)。等同 claude bypassPermissions / codex bypass。
        runtime["OPENCODE_CONFIG_CONTENT"] =
            #"{"snapshot":false,"permission":{"edit":"allow","bash":"allow","webfetch":"allow","question":"deny","plan_enter":"deny","plan_exit":"deny"}}"#
        return runtime
    }
}
