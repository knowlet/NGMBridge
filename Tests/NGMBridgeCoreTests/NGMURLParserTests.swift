import Foundation
import Testing
@testable import NGMBridgeCore

struct NGMURLParserTests {
    @Test
    func parsesMapleStoryClassicLaunchURL() throws {
        let raw = "ngm://launch/%20-mode%3Alaunch%20-game%3A'2982%402141'%20-passarg%3A'4741097%20sessREDACTED%202373%20944'%20-position%3A'GameWeb%7Chttps%3A%2F%2Fmaplestoryclassic.beanfun.com%2FMain%3Faf_click_id%3D'%20-architectureplatform%3A'none'%20-timestamp%3A1785853241599"

        let result = try NGMURLParser().parse(raw)

        #expect(result.mode == "launch")
        #expect(result.game == "2982@2141")
        #expect(result.gameCode == "2982")
        #expect(result.serviceCode == "2141")
        #expect(result.passArguments == ["4741097", "sessREDACTED", "2373", "944"])
        #expect(result.architecturePlatform == "none")
        #expect(result.timestampMilliseconds == 1_785_853_241_599)
    }

    @Test
    func rejectsUnsupportedScheme() {
        #expect(throws: NGMURLParserError.unsupportedScheme) {
            try NGMURLParser().parse("https://launch/-mode:launch")
        }
    }

    @Test
    func rejectsDuplicateSensitiveField() {
        let raw = "ngm://launch/-mode:launch%20-game:'2982@2141'%20-passarg:'one'%20-passarg:'two'"
        #expect(throws: NGMURLParserError.duplicateField("passarg")) {
            try NGMURLParser().parse(raw)
        }
    }

    @Test
    func rejectsEmptyPassarg() {
        let raw = "ngm://launch/-mode:launch%20-game:'2982@2141'%20-passarg:''"
        #expect(throws: NGMURLParserError.missingField("passarg")) {
            try NGMURLParser().parse(raw)
        }
    }
}
