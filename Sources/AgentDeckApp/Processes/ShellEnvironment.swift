import Foundation

/// 解决「GUI 启动的 app，其子进程 PATH 极简（`/usr/bin:/bin:/usr/sbin:/sbin`）」的问题。
///
/// 从 Finder/Dock/`open` 启动的 macOS app 继承的是 launchd 的最小 PATH，不含
/// `/opt/homebrew/bin`、nvm/volta/fnm 等。于是像 claude（`#!/usr/bin/env node` 开头）这类 CLI
/// 虽被找到并启动，却因子进程 PATH 里没有 `node` 而报 `env: node: No such file or directory`（退出码 127）。
///
/// 这里给子进程拼一个尽量完整的 PATH：登录 shell 的 PATH + 常见安装目录 + 当前进程 PATH，
/// 并把「被执行文件自身所在目录」排在最前（node 往往与 claude 同目录）。
enum ShellEnvironment {
    /// 基础 PATH 组件（登录 shell + 常见目录 + 当前进程 PATH），进程内只计算一次并缓存。
    static let basePATHComponents: [String] = computeBaseComponents()

    /// 不针对具体命令的完整 PATH（如解析可执行文件时用）。
    static var enrichedPATH: String { basePATHComponents.joined(separator: ":") }

    /// 针对某个可执行文件拼 PATH：把它所在目录排最前（node 常与之同目录），再接基础组件。
    static func enrichedPATH(forCommandAt commandPath: String) -> String {
        let commandDir = URL(fileURLWithPath: commandPath).deletingLastPathComponent().path
        return dedupe([commandDir] + basePATHComponents).joined(separator: ":")
    }

    private static func computeBaseComponents() -> [String] {
        var components: [String] = []
        if let shellPath = loginShellPATH() {
            components += shellPath.split(separator: ":").map(String.init)
        }
        components += AgentDetection.defaultFallbackPaths
        components += nodeVersionManagerBins()
        if let current = ProcessInfo.processInfo.environment["PATH"] {
            components += current.split(separator: ":").map(String.init)
        }
        return dedupe(components.filter { !$0.isEmpty })
    }

    /// 跑一次登录+交互 shell 取其 `$PATH`（捕获用户 nvm/volta/fnm/homebrew 的配置）。
    /// 用唯一标记把 PATH 包起来，便于从 rc 噪声里抽取；带 2s 超时与失败兜底，绝不卡 UI。
    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.fileExists(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i 让交互式 rc（.zshrc，nvm 常在此）也被 source；标记包裹避免抓到别的输出。
        process.arguments = ["-ilc", "printf '___ADPATH___%s___END___' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice // 防交互式 shell 读 stdin 卡住

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do { try process.run() } catch { return nil }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            return nil
        }

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8),
              let start = output.range(of: "___ADPATH___"),
              let end = output.range(of: "___END___", range: start.upperBound..<output.endIndex) else {
            return nil
        }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// nvm / volta / fnm / bun / pnpm 等的 bin 目录（只取真实存在的）。
    private static func nodeVersionManagerBins() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = [
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "\(home)/Library/pnpm",
            "/opt/homebrew/opt/node/bin"
        ]
        // nvm：各版本 bin，版本号大的在前（通常更可能是当前默认）。
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for version in versions.sorted(by: >) {
                dirs.append("\(nvm)/\(version)/bin")
            }
        }
        return dirs.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where !path.isEmpty && seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }
}
