import Foundation

public enum CrossOverLaunchMode: String, Codable, Sendable {
    case cxApp
    case direct
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var crossoverAppPath: String
    public var bottle: String
    public var launchMode: CrossOverLaunchMode
    public var executable: String
    public var allowedGameCodes: [String]
    public var terminateAfterLaunch: Bool

    public init(
        crossoverAppPath: String = "/Applications/CrossOver.app",
        bottle: String = "MapleStoryClassic",
        launchMode: CrossOverLaunchMode = .cxApp,
        executable: String = "Maplestory_Classic.exe",
        allowedGameCodes: [String] = ["2982"],
        terminateAfterLaunch: Bool = true
    ) {
        self.crossoverAppPath = crossoverAppPath
        self.bottle = bottle
        self.launchMode = launchMode
        self.executable = executable
        self.allowedGameCodes = allowedGameCodes
        self.terminateAfterLaunch = terminateAfterLaunch
    }

    public var winePath: String {
        URL(fileURLWithPath: crossoverAppPath)
            .appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
            .path
    }

    public func validate() throws {
        guard !bottle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeConfigurationError.emptyBottle
        }
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeConfigurationError.emptyExecutable
        }
        guard !allowedGameCodes.isEmpty,
              allowedGameCodes.allSatisfy({ !$0.isEmpty })
        else {
            throw BridgeConfigurationError.emptyAllowedGameCodes
        }
    }

    public static func defaultConfigURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("NGMBridge", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static func loadOrCreate(
        at url: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> BridgeConfiguration {
        let configURL = try url ?? defaultConfigURL(fileManager: fileManager)
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if !fileManager.fileExists(atPath: configURL.path) {
            let template = BridgeConfiguration()
            let data = try JSONEncoder.pretty.encode(template)
            try data.write(to: configURL, options: .atomic)
            throw BridgeConfigurationError.templateCreated(configURL.path)
        }

        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(BridgeConfiguration.self, from: data)
        try config.validate()
        return config
    }
}

public enum BridgeConfigurationError: LocalizedError, Equatable {
    case emptyBottle
    case emptyExecutable
    case emptyAllowedGameCodes
    case templateCreated(String)

    public var errorDescription: String? {
        switch self {
        case .emptyBottle:
            return "CrossOver bottle name is empty"
        case .emptyExecutable:
            return "Windows executable is empty"
        case .emptyAllowedGameCodes:
            return "At least one allowed game code is required"
        case let .templateCreated(path):
            return "A configuration template was created at \(path). Edit it and launch again."
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
