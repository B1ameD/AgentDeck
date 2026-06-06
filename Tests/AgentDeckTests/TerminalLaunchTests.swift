import XCTest
@testable import AgentDeckApp

final class TerminalLaunchTests: XCTestCase {
    func testClaudeAuthenticationLaunchRunsAuthLoginDirectly() {
        let launch = TerminalLaunch.claudeAuthentication(executable: "/usr/local/bin/claude")

        XCTAssertEqual(launch.executable, "/usr/local/bin/claude")
        XCTAssertEqual(launch.arguments, ["auth", "login"])
        XCTAssertEqual(launch.title, "Claude 登录")
    }

    func testShellLaunchUsesLoginShell() {
        let launch = TerminalLaunch.shell(executable: "/bin/zsh")

        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.arguments, ["-l"])
        XCTAssertEqual(launch.title, "终端")
    }
}
