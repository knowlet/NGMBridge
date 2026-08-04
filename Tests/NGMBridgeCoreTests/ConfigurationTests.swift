import Foundation
import Testing
@testable import NGMBridgeCore

struct ConfigurationTests {
    @Test
    func derivesWinePath() {
        let config = BridgeConfiguration(crossoverAppPath: "/Applications/CrossOver.app")
        #expect(config.winePath == "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
    }
}
