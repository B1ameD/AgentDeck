import XCTest
@testable import AgentDeckApp

final class OpenCodeServerTests: XCTestCase {
    /// #34 回归:并发首次调用 baseURL 必须共享同一次启动。
    /// 修复前,第二个调用方会在第一个的探活轮询期间清掉 actor 的 process,
    /// 导致探活误判「启动后立即退出」,两边一起失败回退非流式。
    func testConcurrentFirstCallsShareOneLaunch() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            "需要 python3 充当假 serve"
        )

        // 假 opencode:收到 `serve --port N --hostname 127.0.0.1` 后延迟 1 秒才监听,
        // 拉大「已 spawn、探活轮询中」的窗口期,让第二个调用方稳定落在窗口内。
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-opencode-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }
        try """
        #!/bin/zsh
        sleep 1
        exec /usr/bin/python3 -m http.server "$3" --bind 127.0.0.1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = OpenCodeServer()
        async let first = server.baseURL(executable: script.path, environment: [:])
        // 让 caller1 走到「进程已 spawn、waitUntilReady 轮询中」再发起第二个调用
        try await Task.sleep(for: .milliseconds(400))
        async let second = server.baseURL(executable: script.path, environment: [:])

        let (urlA, urlB) = try await (first, second)
        XCTAssertEqual(urlA, urlB, "两个并发首调共享同一个 serve 实例")
        await server.shutdown()
    }
}
