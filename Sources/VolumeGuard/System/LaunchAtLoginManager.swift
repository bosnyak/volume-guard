import Foundation
import ServiceManagement

/// Manages "Launch at Login" (Iniciar ao ligar o Mac) using a user LaunchAgent plist
/// (plus SMAppService when signed in /Applications) so it works reliably with both
/// ad-hoc builds and installed /Applications bundles.
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    private let agentLabel = "dev.volumeguard.app"

    private var launchAgentURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    @Published var isEnabled: Bool = false

    private init() {
        self.isEnabled = checkIsEnabled()
    }

    func checkIsEnabled() -> Bool {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            return true
        }
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                return true
            }
        }
        return false
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enableLaunchAgent()
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.register()
            }
        } else {
            disableLaunchAgent()
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.unregister()
            }
        }
        isEnabled = checkIsEnabled()
    }

    private func enableLaunchAgent() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let agentsDir = launchAgentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let plistDict: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
            try? data.write(to: launchAgentURL, options: .atomic)
        }
    }

    private func disableLaunchAgent() {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
    }
}
