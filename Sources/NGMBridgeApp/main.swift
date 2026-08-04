#if os(macOS)
import AppKit
import Foundation
import NGMBridgeCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "dev.knowlet.NGMBridge", category: "launch")
    private let parser = NGMURLParser()
    private let launcher = CrossOverLauncher()
    private var receivedURL = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.receivedURL else { return }
            self.showStatus()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        guard let url = urls.first else {
            showError("No URL was delivered to NGMBridge")
            return
        }
        handle(url)
    }

    private func handle(_ url: URL) {
        do {
            let request = try parser.parse(url.absoluteString)
            let configuration = try BridgeConfiguration.loadOrCreate()
            try launcher.launch(request, configuration: configuration)
            logger.notice(
                "CrossOver launch started for game code \(request.gameCode, privacy: .public); argument values redacted"
            )
            if configuration.terminateAfterLaunch {
                NSApp.terminate(nil)
            }
        } catch {
            logger.error("Launch rejected: \(error.localizedDescription, privacy: .public)")
            showError(error.localizedDescription)
        }
    }

    private func showStatus() {
        do {
            let configuration = try BridgeConfiguration.loadOrCreate()
            showAlert(
                title: "NGMBridge is ready",
                message: "Handler: ngm://launch\nBottle: \(configuration.bottle)\nExecutable: \(configuration.executable)"
            )
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        showAlert(title: "NGMBridge", message: message, critical: true)
    }

    private func showAlert(title: String, message: String, critical: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = critical ? .critical : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
#else
import Foundation
print("NGMBridge is a macOS application. Core parsing tests are cross-platform.")
exit(1)
#endif
