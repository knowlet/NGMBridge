import Foundation
import Testing
@testable import NGMBridgeCore

struct CrossOverLauncherTests {
    @Test
    func buildsCxAppCommandWithoutShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wine =
            root
            .appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wine.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let request = LaunchRequest(
            mode: "launch",
            game: "2982@2141",
            gameCode: "2982",
            serviceCode: "2141",
            passArguments: ["account", "sessREDACTED", "2373", "944"],
            position: nil,
            architecturePlatform: nil,
            timestampMilliseconds: nil
        )
        let config = BridgeConfiguration(
            crossoverAppPath: root.appendingPathComponent("CrossOver.app").path,
            bottle: "Classic",
            launchMode: .cxApp,
            executable: "Maplestory_Classic.exe"
        )

        let command = try CrossOverLauncher().command(
            for: request,
            configuration: config
        )

        #expect(command.executableURL.path == wine.path)
        #expect(
            command.arguments == [
                "--bottle", "Classic",
                "--cx-app", "Maplestory_Classic.exe",
                "account", "sessREDACTED", "2373", "944"
            ])
    }

    @Test
    func launchesFixtureWithLiteralArgumentsAndDebugSuppressed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wine = root.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        let record = root.appendingPathComponent("arguments.txt")
        let marker = root.appendingPathComponent("must-not-exist")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$WINEDEBUG\" \"$@\" > '\(record.path)'\n"
        try Data(script.utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = ["sessREDACTED", "$(touch \(marker.path))", "literal;value", "two words"]
        let request = LaunchRequest(
            mode: "launch", game: "2982", gameCode: "2982", serviceCode: nil,
            passArguments: arguments, position: nil, architecturePlatform: nil,
            timestampMilliseconds: nil)
        let configuration = BridgeConfiguration(
            crossoverAppPath: root.appendingPathComponent("CrossOver.app").path,
            bottle: "Classic test", executable: "Game.exe")

        let process = try CrossOverLauncher().launch(request, configuration: configuration)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(process.environment?["WINEDEBUG"] == "-all")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(
            recorded == (["-all", "--bottle", "Classic test", "--cx-app", "Game.exe"] + arguments)
                .joined(separator: "\n") + "\n")
    }

    @Test
    func rejectsUnexpectedGameCodeBeforeLaunch() throws {
        let request = LaunchRequest(
            mode: "launch",
            game: "9999@1",
            gameCode: "9999",
            serviceCode: "1",
            passArguments: ["redacted"],
            position: nil,
            architecturePlatform: nil,
            timestampMilliseconds: nil
        )
        let config = BridgeConfiguration(allowedGameCodes: ["2982"])

        #expect(throws: CrossOverLauncherError.gameNotAllowed("9999")) {
            try CrossOverLauncher().command(for: request, configuration: config)
        }
    }
}
