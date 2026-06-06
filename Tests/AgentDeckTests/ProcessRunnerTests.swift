import XCTest
@testable import AgentDeckApp

final class ProcessRunnerTests: XCTestCase {
    func testOneShotRunCapturesStdout() async throws {
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/bin/echo",
            args: ["hello"],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.stderr, "")
    }

    func testOneShotRunCapturesStderrAndExitCode() async throws {
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/bin/sh",
            args: ["-c", "echo problem >&2; exit 7"],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "problem")
    }

    func testOneShotRunWritesStdinAndClosesIt() async throws {
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/bin/cat",
            args: [],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdin: "hello from stdin\n"
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello from stdin\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testOneShotRunCapturesLargeStdoutWithoutHanging() async throws {
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/usr/bin/perl",
            args: ["-e", blockingWriteScript(handle: "STDOUT", byteCount: 262144)],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 262144)
        XCTAssertEqual(result.stderr, "")
    }

    func testOneShotRunCapturesLargeStderrWithoutHanging() async throws {
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/usr/bin/perl",
            args: ["-e", blockingWriteScript(handle: "STDERR", byteCount: 262144)],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.count, 262144)
    }

    func testOneShotRunPropagatesEnvironment() async throws {
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/bin/sh",
            args: ["-c", "printf %s \"$PROCESS_RUNNER_TEST_VALUE\""],
            environment: ["PROCESS_RUNNER_TEST_VALUE": "from-environment"],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "from-environment")
        XCTAssertEqual(result.stderr, "")
    }

    func testOneShotRunPropagatesWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/bin/pwd",
            args: [],
            environment: [:],
            workingDirectory: directory
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path,
            directory.standardizedFileURL.path
        )
        XCTAssertEqual(result.stderr, "")
    }

    func testOneShotRunDoesNotHangWhenProcessExitsImmediately() async throws {
        let runner = ProcessRunner()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 {
                    let result = try await runner.runOneShot(
                        command: "/usr/bin/true",
                        args: [],
                        environment: [:],
                        workingDirectory: FileManager.default.temporaryDirectory
                    )

                    XCTAssertEqual(result, ProcessResult(exitCode: 0, stdout: "", stderr: ""))
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(3))
                XCTFail("ProcessRunner timed out waiting for immediate exits")
            }

            try await group.next()
            group.cancelAll()
        }
    }

    func testStreamEmitsStdoutChunksThenExit() async throws {
        let runner = ProcessRunner()
        var stdout = ""
        var exitCode: Int32?

        for try await event in runner.stream(
            command: "/bin/sh",
            args: ["-c", "printf one; printf two"],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdin: nil
        ) {
            switch event {
            case .stdout(let chunk): stdout += chunk
            case .stderr: break
            case .exit(let code): exitCode = code
            }
        }

        XCTAssertEqual(stdout, "onetwo")
        XCTAssertEqual(exitCode, 0)
    }

    func testStreamCapturesStderrAndExitCode() async throws {
        let runner = ProcessRunner()
        var stderr = ""
        var exitCode: Int32?

        for try await event in runner.stream(
            command: "/bin/sh",
            args: ["-c", "echo boom >&2; exit 7"],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdin: nil
        ) {
            switch event {
            case .stdout: break
            case .stderr(let chunk): stderr += chunk
            case .exit(let code): exitCode = code
            }
        }

        XCTAssertEqual(stderr.trimmingCharacters(in: .whitespacesAndNewlines), "boom")
        XCTAssertEqual(exitCode, 7)
    }

    func testStreamWritesStdin() async throws {
        let runner = ProcessRunner()
        var stdout = ""

        for try await event in runner.stream(
            command: "/bin/cat",
            args: [],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdin: "streamed stdin\n"
        ) {
            if case .stdout(let chunk) = event { stdout += chunk }
        }

        XCTAssertEqual(stdout, "streamed stdin\n")
    }

    func testStdinToImmediatelyExitingProcessDoesNotCrash() async throws {
        // App 启动时会 signal(SIGPIPE, SIG_IGN)；测试里手动模拟该环境。
        // /usr/bin/true 立即退出且不读 stdin，写入超过管道缓冲的大数据，
        // 历史上会因 broken pipe 触发 SIGPIPE 杀死进程，现应安全返回。
        signal(SIGPIPE, SIG_IGN)
        let runner = ProcessRunner()
        let result = try await runner.runOneShot(
            command: "/usr/bin/true",
            args: [],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdin: String(repeating: "x", count: 200_000)
        )

        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - 多字节 UTF-8 跨分片（中文/emoji 不应变成 �）

    func testSafeUTF8PrefixCountHoldsBackIncompleteTrailingSequence() {
        // ASCII：全可解码
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0x61, 0x62])), 2)

        // 「你」= E4 BD A0（3 字节）
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0x61, 0xE4])), 1)             // 留 E4
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0x61, 0xE4, 0xBD])), 1)       // 留 E4 BD
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0x61, 0xE4, 0xBD, 0xA0])), 4) // 集齐

        // 「é」= C3 A9（2 字节）
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0xC3])), 0)
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0xC3, 0xA9])), 2)

        // 😀 = F0 9F 98 80（4 字节）
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0xF0, 0x9F, 0x98])), 0)
        XCTAssertEqual(ProcessRunner.safeUTF8PrefixCount(Data([0xF0, 0x9F, 0x98, 0x80])), 4)
    }

    func testIncrementalDecodeReassemblesBytesSplitAtAnyBoundary() {
        // 复刻 pump 的缓冲循环：把一段中文/emoji 字节流按会切断多字节字的尺寸喂进去，
        // 断言逐片解码后能无损还原、且不含替换字符 U+FFFD。
        let text = String(repeating: "造梦盒子·滴水连环—你好，世界！😀", count: 2000)
        let bytes = Array(text.utf8)
        let sizes = [1, 2, 3, 5, 7, 11, 4096]

        var assembled = ""
        var buffer = Data()
        var index = 0
        var step = 0
        while index < bytes.count {
            let n = min(sizes[step % sizes.count], bytes.count - index)
            step += 1
            buffer.append(contentsOf: bytes[index..<index + n])
            index += n
            let safe = ProcessRunner.safeUTF8PrefixCount(buffer)
            if safe > 0 {
                assembled += String(decoding: buffer.prefix(safe), as: UTF8.self)
                buffer.removeFirst(safe)
            }
        }
        if !buffer.isEmpty { assembled += String(decoding: buffer, as: UTF8.self) }

        XCTAssertEqual(assembled, text)
        XCTAssertFalse(assembled.contains("\u{FFFD}"))
    }

    func testStreamDeliversLargeChineseOutputIntact() async throws {
        // 端到端：~200KB 中文经管道回显，必然跨多次 availableData 读取（>64KB 缓冲），
        // 旧实现会在分片边界产生 �；修复后应逐字节无损。
        let runner = ProcessRunner()
        let text = String(repeating: "造梦盒子·滴水连环——你好，世界！", count: 4000)
        var stdout = ""

        for try await event in runner.stream(
            command: "/bin/cat",
            args: [],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdin: text
        ) {
            if case .stdout(let chunk) = event { stdout += chunk }
        }

        XCTAssertEqual(stdout, text)
        XCTAssertFalse(stdout.contains("\u{FFFD}"))
    }

    private func blockingWriteScript(handle: String, byteCount: Int) -> String {
        """
        $SIG{ALRM} = sub { exit 86 };
        alarm 3;
        print \(handle) 'x' x \(byteCount) or die $!;
        alarm 0;
        """
    }
}
