import XCTest

final class BundleScriptTests: XCTestCase {
    func testBundleScriptCreatesRunnableAppLayout() throws {
        let packageRoot = try XCTUnwrap(URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent())
        let scriptURL = packageRoot.appending(path: "Scripts/package_app.sh")
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "AgentDeckBundleScriptTests-\(UUID().uuidString)")
        let fakeBuildRoot = temporaryRoot.appending(path: "build")
        let fakeInstallRoot = temporaryRoot.appending(path: "dist")
        let fakeExecutable = fakeBuildRoot.appending(path: "release/AgentDeck")

        try FileManager.default.createDirectory(
            at: fakeExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: fakeExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeExecutable.path
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [
            scriptURL.path,
            "--skip-build",
            "--build-path", fakeBuildRoot.path,
            "--output", fakeInstallRoot.path
        ]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let appRoot = fakeInstallRoot.appending(path: "AgentDeck.app")
        let bundledExecutable = appRoot.appending(path: "Contents/MacOS/AgentDeck")
        let infoPlist = appRoot.appending(path: "Contents/Info.plist")

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledExecutable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: infoPlist.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundledExecutable.path))

        let plistData = try Data(contentsOf: infoPlist)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any])

        XCTAssertEqual(plist["CFBundleName"] as? String, "AgentDeck")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "AgentDeck")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
    }
}
