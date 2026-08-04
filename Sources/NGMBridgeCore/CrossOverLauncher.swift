import Foundation

public enum CrossOverLauncherError: LocalizedError, Equatable {
    case gameNotAllowed(String)
    case wineNotExecutable(String)
    case executableNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .gameNotAllowed(code):
            return "NGM game code is not allowed: \(code)"
        case let .wineNotExecutable(path):
            return "CrossOver wine was not found or is not executable: \(path)"
        case let .executableNotFound(path):
            return "Configured Windows executable was not found: \(path)"
        }
    }
}

public struct CrossOverCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public struct CrossOverLauncher: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func command(
        for request: LaunchRequest,
        configuration: BridgeConfiguration
    ) throws -> CrossOverCommand {
        try configuration.validate()
        guard configuration.allowedGameCodes.contains(request.gameCode) else {
            throw CrossOverLauncherError.gameNotAllowed(request.gameCode)
        }
        guard fileManager.isExecutableFile(atPath: configuration.winePath) else {
            throw CrossOverLauncherError.wineNotExecutable(configuration.winePath)
        }
        if configuration.launchMode == .direct,
           !fileManager.fileExists(atPath: configuration.executable) {
            throw CrossOverLauncherError.executableNotFound(configuration.executable)
        }

        var arguments = ["--bottle", configuration.bottle]
        switch configuration.launchMode {
        case .cxApp:
            arguments += ["--cx-app", configuration.executable]
        case .direct:
            arguments.append(configuration.executable)
        }
        arguments += request.passArguments

        return CrossOverCommand(
            executableURL: URL(fileURLWithPath: configuration.winePath),
            arguments: arguments
        )
    }

    @discardableResult
    public func launch(
        _ request: LaunchRequest,
        configuration: BridgeConfiguration
    ) throws -> Process {
        let command = try command(for: request, configuration: configuration)
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments

        // Prevent session-bearing launch arguments from being echoed by Wine debug output.
        var environment = ProcessInfo.processInfo.environment
        environment["WINEDEBUG"] = "-all"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        return process
    }
}
