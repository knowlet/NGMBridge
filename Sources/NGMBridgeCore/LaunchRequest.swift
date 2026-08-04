import Foundation

public struct LaunchRequest: Equatable, Sendable {
    public let mode: String
    public let game: String
    public let gameCode: String
    public let serviceCode: String?
    public let passArguments: [String]
    public let position: String?
    public let architecturePlatform: String?
    public let timestampMilliseconds: Int64?

    public init(
        mode: String,
        game: String,
        gameCode: String,
        serviceCode: String?,
        passArguments: [String],
        position: String?,
        architecturePlatform: String?,
        timestampMilliseconds: Int64?
    ) {
        self.mode = mode
        self.game = game
        self.gameCode = gameCode
        self.serviceCode = serviceCode
        self.passArguments = passArguments
        self.position = position
        self.architecturePlatform = architecturePlatform
        self.timestampMilliseconds = timestampMilliseconds
    }
}
