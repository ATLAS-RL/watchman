import Foundation
import ServiceManagement
import SwiftUI

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }

    /// Worker aliases keyed by worker id (e.g. "worker-0" → "W0")
    @Published var workerAliases: [String: String] = [:] {
        didSet { saveAliases() }
    }

    private let aliasesKey = "workerAliases"

    init() {
        if let data = UserDefaults.standard.data(forKey: aliasesKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data)
        {
            self.workerAliases = dict
        }
    }

    func alias(for workerId: String) -> String {
        let value = workerAliases[workerId]
        return (value?.isEmpty == false) ? value! : workerId
    }

    private func saveAliases() {
        if let data = try? JSONEncoder().encode(workerAliases) {
            UserDefaults.standard.set(data, forKey: aliasesKey)
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }
}
