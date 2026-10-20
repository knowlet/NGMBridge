import Foundation
import Testing
@testable import NGMBridgeCore

struct DiagnosticPrivacyTests {
    @Test
    func rejectsUnsupportedModeWithoutEchoingPayload() throws {
        let sensitive = "sessREDACTED"
        let raw = launchURL("-mode:'\(sensitive)' -game:2982 -passarg:redacted")
        do {
            _ = try NGMURLParser().parse(raw)
            Issue.record("Expected unsupported mode rejection")
        } catch {
            #expect(error as? NGMURLParserError == .unsupportedMode(sensitive))
            #expect(!error.localizedDescription.contains(sensitive))
        }
    }

    @Test
    func rejectsDuplicateUnknownFieldWithoutEchoingItsName() throws {
        let sensitive = "sessREDACTED"
        let raw = launchURL("-mode:launch -game:2982 -passarg:redacted -\(sensitive):one -\(sensitive):two")
        do {
            _ = try NGMURLParser().parse(raw)
            Issue.record("Expected duplicate field rejection")
        } catch {
            #expect(error as? NGMURLParserError == .duplicateField(sensitive.lowercased()))
            #expect(!error.localizedDescription.lowercased().contains(sensitive.lowercased()))
        }
    }

    @Test
    func rejectsDisallowedGameWithoutEchoingPayload() throws {
        let sensitive = "sessREDACTED"
        let request = try NGMURLParser().parse(
            launchURL("-mode:launch -game:'\(sensitive)' -passarg:redacted"))
        do {
            _ = try CrossOverLauncher().command(for: request, configuration: BridgeConfiguration())
            Issue.record("Expected game allowlist rejection")
        } catch {
            #expect(error as? CrossOverLauncherError == .gameNotAllowed(sensitive))
            #expect(!error.localizedDescription.contains(sensitive))
        }
    }

    private func launchURL(_ payload: String) -> String {
        "ngm://launch/" + payload.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    }
}
