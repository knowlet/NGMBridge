import Foundation

public enum NGMURLParserError: LocalizedError, Equatable {
    case urlTooLong
    case invalidURL
    case unsupportedScheme
    case unsupportedHost
    case malformedPayload(String)
    case duplicateField(String)
    case missingField(String)
    case unsupportedMode(String)
    case emptyPassArguments
    case invalidTimestamp

    public var errorDescription: String? {
        switch self {
        case .urlTooLong:
            return "NGM URL exceeds the configured size limit"
        case .invalidURL:
            return "Invalid NGM URL"
        case .unsupportedScheme:
            return "Only the ngm URL scheme is supported"
        case .unsupportedHost:
            return "Only ngm://launch URLs are supported"
        case let .malformedPayload(reason):
            return "Malformed NGM launch payload: \(reason)"
        case let .duplicateField(field):
            return "Duplicate NGM field: \(field)"
        case let .missingField(field):
            return "Missing NGM field: \(field)"
        case let .unsupportedMode(mode):
            return "Unsupported NGM mode: \(mode)"
        case .emptyPassArguments:
            return "NGM passarg is empty"
        case .invalidTimestamp:
            return "NGM timestamp is not a valid integer"
        }
    }
}

public struct NGMURLParser: Sendable {
    public let maximumURLLength: Int

    public init(maximumURLLength: Int = 32_768) {
        self.maximumURLLength = maximumURLLength
    }

    public func parse(_ rawURL: String) throws -> LaunchRequest {
        guard rawURL.utf8.count <= maximumURLLength else {
            throw NGMURLParserError.urlTooLong
        }
        guard let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw NGMURLParserError.invalidURL
        }
        guard components.scheme?.lowercased() == "ngm" else {
            throw NGMURLParserError.unsupportedScheme
        }
        guard components.host?.lowercased() == "launch" else {
            throw NGMURLParserError.unsupportedHost
        }

        var encodedPayload = components.percentEncodedPath
        if encodedPayload.hasPrefix("/") {
            encodedPayload.removeFirst()
        }
        guard let payload = encodedPayload.removingPercentEncoding else {
            throw NGMURLParserError.malformedPayload("invalid percent encoding")
        }

        let fields = try parseFields(payload)
        let mode = try required("mode", from: fields)
        guard mode.lowercased() == "launch" else {
            throw NGMURLParserError.unsupportedMode(mode)
        }

        let game = try required("game", from: fields)
        let gameParts = game.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let gameCode = String(gameParts[0])
        guard !gameCode.isEmpty else {
            throw NGMURLParserError.malformedPayload("empty game code")
        }
        let serviceCode: String? = gameParts.count == 2 && !gameParts[1].isEmpty
            ? String(gameParts[1])
            : nil

        let passarg = try required("passarg", from: fields)
        let passArguments = passarg
            .split(whereSeparator: Self.isASCIIWhitespace)
            .map(String.init)
        guard !passArguments.isEmpty else {
            throw NGMURLParserError.emptyPassArguments
        }

        let timestamp: Int64?
        if let rawTimestamp = fields["timestamp"] {
            guard let value = Int64(rawTimestamp) else {
                throw NGMURLParserError.invalidTimestamp
            }
            timestamp = value
        } else {
            timestamp = nil
        }

        return LaunchRequest(
            mode: mode,
            game: game,
            gameCode: gameCode,
            serviceCode: serviceCode,
            passArguments: passArguments,
            position: fields["position"],
            architecturePlatform: fields["architectureplatform"],
            timestampMilliseconds: timestamp
        )
    }

    private func required(
        _ name: String,
        from fields: [String: String]
    ) throws -> String {
        guard let value = fields[name], !value.isEmpty else {
            throw NGMURLParserError.missingField(name)
        }
        return value
    }

    private func parseFields(_ payload: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        var index = payload.startIndex

        func skipWhitespace() {
            while index < payload.endIndex, Self.isASCIIWhitespace(payload[index]) {
                index = payload.index(after: index)
            }
        }

        while true {
            skipWhitespace()
            guard index < payload.endIndex else { break }
            guard payload[index] == "-" else {
                throw NGMURLParserError.malformedPayload("expected '-' before field")
            }
            index = payload.index(after: index)

            let keyStart = index
            while index < payload.endIndex,
                  payload[index] != ":",
                  !Self.isASCIIWhitespace(payload[index]) {
                index = payload.index(after: index)
            }
            guard index < payload.endIndex, payload[index] == ":" else {
                throw NGMURLParserError.malformedPayload("field is missing ':'")
            }
            let key = payload[keyStart..<index].lowercased()
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else {
                throw NGMURLParserError.malformedPayload("invalid field name")
            }
            if fields[key] != nil {
                throw NGMURLParserError.duplicateField(key)
            }

            index = payload.index(after: index)
            let value: String
            if index < payload.endIndex, payload[index] == "'" {
                index = payload.index(after: index)
                let valueStart = index
                guard let quote = payload[index...].firstIndex(of: "'") else {
                    throw NGMURLParserError.malformedPayload("unterminated quoted value")
                }
                value = String(payload[valueStart..<quote])
                index = payload.index(after: quote)
                if index < payload.endIndex, !Self.isASCIIWhitespace(payload[index]) {
                    throw NGMURLParserError.malformedPayload("unexpected characters after quoted value")
                }
            } else {
                let valueStart = index
                while index < payload.endIndex, !Self.isASCIIWhitespace(payload[index]) {
                    index = payload.index(after: index)
                }
                value = String(payload[valueStart..<index])
            }
            fields[key] = value
        }

        return fields
    }

    private static func isASCIIWhitespace(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }
}
