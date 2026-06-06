import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

/// Errors thrown during process execution before the subprocess is launched.
public enum ProcessError: Error, Equatable, Sendable {
    /// The resolved executable path does not exist on disk.
    case executableNotFound(String)
}

extension ProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "可执行文件不存在：\(path)"
        }
    }
}

/// 流式执行过程中的增量事件。stdout/stderr 为原始分片（可能跨行切分），
/// exit 在所有输出投递完毕后产生且仅一次。
public enum ProcessStreamEvent: Equatable, Sendable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

public final class ProcessRunner: Sendable {
    public init() {}

    public func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String? = nil
    ) async throws -> ProcessResult {
        let executableURL = URL(fileURLWithPath: command)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessError.executableNotFound(command)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.resolvedEnvironment(command: command, overrides: environment)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let standardInput: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            standardInput = pipe
        } else {
            standardInput = nil
        }

        let stdoutTask = Task {
            try await Self.readData(from: stdout.fileHandleForReading)
        }
        let stderrTask = Task {
            try await Self.readData(from: stderr.fileHandleForReading)
        }

        let exitCode: Int32
        do {
            exitCode = try await Self.runAndWaitUntilExit(process) {
                if let stdin, let standardInput {
                    // 使用可抛出的 write(contentsOf:)：若子进程在读取前就退出，
                    // 写入已关闭的管道会抛 EPIPE（配合 App 启动时忽略 SIGPIPE），
                    // 在此吞掉即可——进程结果会反映其失败，而不是崩溃。
                    try? standardInput.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                    try? standardInput.fileHandleForWriting.close()
                }
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
            }
        } catch {
            stdoutTask.cancel()
            stderrTask.cancel()
            if let standardInput {
                try? standardInput.fileHandleForWriting.close()
            }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            throw error
        }

        return ProcessResult(
            exitCode: exitCode,
            stdout: String(data: try await stdoutTask.value, encoding: .utf8) ?? "",
            stderr: String(data: try await stderrTask.value, encoding: .utf8) ?? ""
        )
    }

    /// 流式运行：增量产出 stdout/stderr 分片，进程退出后产出一个 .exit 事件并结束。
    /// 读取在后台 Task 中以 availableData 循环进行（EOF 返回空时退出循环），
    /// 终止回调等两个读取 Task 收尾后再发 .exit，保证输出顺序先于退出码。
    public func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String? = nil,
        stopSignal: AgentConfig.StopSignal = .interrupt
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        let executableURL = URL(fileURLWithPath: command)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProcessError.executableNotFound(command))
            }
        }

        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = args
            process.currentDirectoryURL = workingDirectory
            process.environment = Self.resolvedEnvironment(command: command, overrides: environment)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdinPipe: Pipe?
            if stdin != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            } else {
                stdinPipe = nil
            }

            let stdoutTask = Task {
                Self.pump(stdoutPipe.fileHandleForReading) { continuation.yield(.stdout($0)) }
            }
            let stderrTask = Task {
                Self.pump(stderrPipe.fileHandleForReading) { continuation.yield(.stderr($0)) }
            }

            process.terminationHandler = { process in
                Task {
                    _ = await stdoutTask.value
                    _ = await stderrTask.value
                    continuation.yield(.exit(process.terminationStatus))
                    continuation.finish()
                }
            }

            // 消费方取消（Stop / 超时）时，向子进程发送停止信号。
            let processBox = UncheckedSendableBox(process)
            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                let process = processBox.value
                guard process.isRunning else { return }
                switch stopSignal {
                case .interrupt:
                    process.interrupt() // SIGINT，等价于 Ctrl-C，多数 CLI 可优雅退出
                case .terminate, .customCommand:
                    process.terminate() // SIGTERM
                }
            }

            do {
                try process.run()
                if let stdin, let stdinPipe {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                    try? stdinPipe.fileHandleForWriting.close()
                }
            } catch {
                stdoutTask.cancel()
                stderrTask.cancel()
                continuation.finish(throwing: error)
            }
        }
    }

    /// 以 availableData 循环把一个读端的数据逐片回调出去，直到 EOF（返回空）。
    /// availableData 在任意字节边界切断，多字节 UTF-8 字符（如中文，占 3 字节）可能被
    /// 拆到两次读取里。若各分片独立解码，被拆开的字节会变成 U+FFFD（�）。故按字节缓冲，
    /// 每次只解码「完整 UTF-8 前缀」，把结尾未完成的序列留到下次；EOF 再 flush 残留。
    private static func pump(_ handle: FileHandle, _ yield: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            let safeCount = safeUTF8PrefixCount(buffer)
            guard safeCount > 0 else { continue } // 整个 buffer 都是某个字符的前半段，先攒着
            yield(String(decoding: buffer.prefix(safeCount), as: UTF8.self))
            buffer.removeFirst(safeCount)
        }
        // EOF：进程已结束，残留若是被截断的序列也无从补全，直接解码（以 U+FFFD 兜底），
        // 至少不丢可见字符。
        if !buffer.isEmpty {
            yield(String(decoding: buffer, as: UTF8.self))
        }
    }

    /// 返回 data 中可安全解码的前缀字节数：把结尾「未完成的多字节 UTF-8 序列」留到下次。
    /// 做法是从末尾回退到最后一个 lead/ASCII 字节，若它领起的序列在 data 内尚不完整，
    /// 就在该字节处截断。坏数据（找不到 lead 或非法 lead）一律全量返回，交给 U+FFFD 兜底。
    static func safeUTF8PrefixCount(_ data: Data) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }

        // 连续字节形如 10xxxxxx；从末尾向前找第一个非连续字节（lead 或 ASCII）。
        var leadOffset = count - 1
        while leadOffset >= 0, data[data.startIndex + leadOffset] & 0b1100_0000 == 0b1000_0000 {
            leadOffset -= 1
        }
        guard leadOffset >= 0 else { return count } // 全是连续字节：数据本身就坏，全量兜底

        let lead = data[data.startIndex + leadOffset]
        let expected: Int
        switch lead {
        case 0b0000_0000...0b0111_1111: expected = 1 // 0xxxxxxx ASCII
        case 0b1100_0000...0b1101_1111: expected = 2 // 110xxxxx
        case 0b1110_0000...0b1110_1111: expected = 3 // 1110xxxx
        case 0b1111_0000...0b1111_0111: expected = 4 // 11110xxx
        default: return count                         // 非法 lead 字节，全量兜底
        }

        // 末尾序列已集齐（或多余）→ 全部可解码；尚缺字节 → 在 lead 处截断，留到下次。
        return (count - leadOffset) >= expected ? count : leadOffset
    }

    /// 合并子进程环境，并兜底补齐 PATH。
    /// GUI 启动的 app 继承的是 launchd 最小 PATH（缺 homebrew/nvm 等），会让 claude 的
    /// `#!/usr/bin/env node` 因找不到 node 而退 127。除非调用方显式提供了 PATH，否则用
    /// ShellEnvironment 拼出的完整 PATH（含命令自身目录、登录 shell PATH、常见安装目录）。
    static func resolvedEnvironment(command: String, overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        if overrides["PATH"] == nil {
            env["PATH"] = ShellEnvironment.enrichedPATH(forCommandAt: command)
        }
        return env
    }

    private static func runAndWaitUntilExit(
        _ process: Process,
        onLaunch: () -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
                onLaunch()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func readData(from fileHandle: FileHandle) async throws -> Data {
        try fileHandle.readToEnd() ?? Data()
    }
}

/// 仅用于把非 Sendable 的 Process 安全带入 @Sendable 的 onTermination 闭包。
/// 闭包内只读取 isRunning 并发信号，不做并发可变访问，故标记 @unchecked Sendable。
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
