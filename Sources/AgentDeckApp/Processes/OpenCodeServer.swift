import Foundation
import Darwin
import os

/// 流式调用 opencode 失败时抛出的错误。调用方（AgentSession）据此回退到非流式 `opencode run`。
public enum OpenCodeStreamingError: Error, LocalizedError, Equatable {
    /// 流式通道不可用（服务起不来 / 连接失败 / 会话创建失败等），应回退非流式。
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "opencode 流式不可用：\(reason)"
        }
    }
}

/// 管理一个进程内共享的 headless `opencode serve` 实例。
///
/// opencode 的 `run` 子命令只在一个文本 part **整段生成完**（`part.time.end`）后才输出，
/// 因此天然不是逐 token 流式。要拿到增量文本，必须连到 opencode 的服务端事件流（SSE `/event`）。
/// 本类型负责把服务拉起来一次、之后复用，并对外给出 base URL。工作目录通过每次请求的
/// `x-opencode-directory` 头传递，所以一个共享服务即可服务所有会话/目录。
///
/// `Process` 始终在 actor 隔离内创建、持有、终止（从不跨隔离传递，满足 Swift 6 并发安全）。
actor OpenCodeServer {
    static let shared = OpenCodeServer()

    private let log = Logger(subsystem: "AgentDeck", category: "opencode-server")
    private var cachedBaseURL: URL?
    private var process: Process?
    /// 进行中的启动任务：并发调用方共享同一次启动，避免起多个服务。只回传 Sendable 的 URL。
    private var startTask: Task<URL, Error>?

    /// 已拉起的 serve 进程 pid，供 atexit 兜底回收（避免每次启动遗留孤儿 node 进程逐次累积）。
    /// 仅在 actor 隔离内写、在进程退出（单线程）时读，故标记 nonisolated(unsafe)。
    private static nonisolated(unsafe) var runningServePID: pid_t = 0
    /// 进程退出时 best-effort 终止 serve。闭包无捕获，可转为 C 函数指针。正常退出（含 Cmd-Q）会触发。
    private static let installExitCleanup: Void = {
        atexit {
            if OpenCodeServer.runningServePID != 0 { kill(OpenCodeServer.runningServePID, SIGTERM) }
        }
    }()

    /// 返回可用的 base URL；首次调用会拉起 `opencode serve`，之后复用。
    /// 启动/就绪失败时抛 `OpenCodeStreamingError.unavailable`，调用方应回退非流式。
    func baseURL(executable: String, environment: [String: String]) async throws -> URL {
        if let cachedBaseURL, process?.isRunning == true {
            return cachedBaseURL
        }
        // 之前起过但已退出：清掉缓存，重新启动。
        cachedBaseURL = nil
        process = nil

        if let startTask {
            return try await startTask.value
        }

        let task = Task { try await self.launch(executable: executable, environment: environment) }
        startTask = task
        do {
            let url = try await task.value
            cachedBaseURL = url
            startTask = nil
            log.info("opencode serve 就绪：\(url.absoluteString, privacy: .public)")
            return url
        } catch {
            startTask = nil
            throw error
        }
    }

    /// 仅供测试/退出清理：终止服务进程。
    func shutdown() {
        process?.terminate()
        process = nil
        cachedBaseURL = nil
        Self.runningServePID = 0
    }

    /// actor 隔离：创建并持有 Process（存入 actor 状态），仅返回 Sendable 的 URL。
    private func launch(executable: String, environment: [String: String]) async throws -> URL {
        guard FileManager.default.fileExists(atPath: executable) else {
            throw OpenCodeStreamingError.unavailable("找不到 opencode 可执行文件：\(executable)")
        }
        guard let port = Self.freeLoopbackPort() else {
            throw OpenCodeStreamingError.unavailable("无法分配本地端口")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", "--port", String(port), "--hostname", "127.0.0.1"]
        process.environment = ProcessRunner.resolvedEnvironment(command: executable, overrides: environment)
        // 输出全部丢弃：用自选端口 + 探活判断就绪，不需要解析日志；
        // 丢到 /dev/null 也避免管道缓冲写满阻塞服务。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw OpenCodeStreamingError.unavailable("无法启动 opencode serve：\(error.localizedDescription)")
        }
        self.process = process
        Self.runningServePID = process.processIdentifier
        _ = Self.installExitCleanup // 确保 atexit 回收只注册一次

        guard let base = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate()
            self.process = nil
            Self.runningServePID = 0
            throw OpenCodeStreamingError.unavailable("非法 base URL")
        }

        do {
            try await waitUntilReady(base: base)
        } catch {
            process.terminate()
            self.process = nil
            Self.runningServePID = 0
            throw error
        }
        return base
    }

    /// 轮询探活：拿到任意 HTTP 响应即视为就绪；进程提前退出或超时则失败。
    /// 用 Task.sleep（非阻塞）轮询，不阻塞执行线程；进程存活状态读 actor 自身状态。
    private func waitUntilReady(base: URL, timeout: TimeInterval = 25) async throws {
        let probe = base.appendingPathComponent("doc")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if process?.isRunning != true {
                throw OpenCodeStreamingError.unavailable("opencode serve 启动后立即退出")
            }
            var request = URLRequest(url: probe)
            request.timeoutInterval = 3
            do {
                _ = try await URLSession.shared.data(for: request)
                return // 任意 HTTP 响应都说明服务在监听
            } catch {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        throw OpenCodeStreamingError.unavailable("opencode serve 启动超时")
    }

    /// 让内核分配一个空闲的 127.0.0.1 端口：bind(:0) 后读回端口再关闭。
    /// close 到 serve 真正 bind 之间有极小竞态；万一被抢占，探活会超时并回退非流式。
    private static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { return nil }
        return UInt16(bigEndian: name.sin_port)
    }
}
