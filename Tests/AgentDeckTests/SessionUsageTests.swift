import XCTest
@testable import AgentDeckApp

final class SessionUsageTests: XCTestCase {
    /// 实测 claude result 行的字段形状(2026-06-10 真机捕获,字段精简)。
    private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"banana","session_id":"e5eae88e","total_cost_usd":0.0108564,"usage":{"input_tokens":10,"output_tokens":43,"cache_read_input_tokens":12084,"cache_creation_input_tokens":7132}}"#

    func testParsesRealResultLine() {
        let turn = UsageCapture.turnUsage(fromJSONLine: resultLine)
        XCTAssertNotNil(turn)
        XCTAssertEqual(turn?.inputTokens, 10)
        XCTAssertEqual(turn?.outputTokens, 43)
        XCTAssertEqual(turn?.cacheReadTokens, 12084)
        XCTAssertEqual(turn?.cacheCreationTokens, 7132)
        XCTAssertEqual(turn?.costUSD ?? 0, 0.0108564, accuracy: 0.000_001)
    }

    func testIgnoresNonResultAndNonUsageLines() {
        XCTAssertNil(UsageCapture.turnUsage(fromJSONLine: #"{"type":"system","session_id":"x"}"#))
        XCTAssertNil(UsageCapture.turnUsage(fromJSONLine: #"{"type":"assistant","message":{"content":"total_cost_usd 不是顶层"}}"#))
        XCTAssertNil(UsageCapture.turnUsage(fromJSONLine: "纯文本 total_cost_usd 也不行"))
        XCTAssertNil(UsageCapture.turnUsage(fromJSONLine: #"{"type":"result","total_cost_usd":0}"#), "全零不计轮")
    }

    func testCaptureAcrossChunkBoundaryAndFlush() {
        var capture = UsageCapture()
        let mid = resultLine.index(resultLine.startIndex, offsetBy: 60)
        XCTAssertNil(capture.consume(String(resultLine[..<mid])))
        XCTAssertNil(capture.consume(String(resultLine[mid...])), "无换行,留在缓冲")
        let turn = capture.flush()
        XCTAssertEqual(turn?.outputTokens, 43)
        XCTAssertNil(capture.flush(), "flush 后缓冲已清")

        var newlineCapture = UsageCapture()
        XCTAssertEqual(newlineCapture.consume(resultLine + "\n")?.inputTokens, 10)
    }

    func testSessionUsageAccumulatesAndFormats() {
        var usage = SessionUsage()
        XCTAssertTrue(usage.isEmpty)
        var turn = TurnUsage()
        turn.inputTokens = 1000
        turn.outputTokens = 500
        turn.cacheCreationTokens = 200
        turn.costUSD = 0.02
        usage.add(turn)
        usage.add(turn)
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.inputTokens, 2000)
        XCTAssertEqual(usage.outputTokens, 1000)
        XCTAssertEqual(usage.costUSD, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(usage.compactSummary, "↑2.4k ↓1.0k · $0.040")
        XCTAssertEqual(SessionUsage.compact(999), "999")
        XCTAssertEqual(SessionUsage.compact(1_200_000), "1.20M")

        var pricey = SessionUsage()
        var bigTurn = TurnUsage()
        bigTurn.costUSD = 1.5
        bigTurn.inputTokens = 1
        pricey.add(bigTurn)
        XCTAssertEqual(pricey.costLabel, "$1.50")
    }

    @MainActor
    func testAgentSessionAccumulatesUsageAcrossRuns() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: UsageEmittingRunner(stdout: resultLine + "\n")
        )

        await session.send("first")
        XCTAssertEqual(session.usage.turns, 1)
        XCTAssertEqual(session.usage.outputTokens, 43)

        await session.send("second")
        XCTAssertEqual(session.usage.turns, 2)
        XCTAssertEqual(session.usage.inputTokens, 20)
        XCTAssertEqual(session.usage.costUSD, 0.0217128, accuracy: 0.000_001)
    }
}

private struct UsageEmittingRunner: AgentRunning {
    let stdout: String

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
