import Foundation
import ServiceManagement
import SwiftUI

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }

    // MARK: - Alert settings (populated in the preferences tab)

    @AppStorage("notificationsEnabled")    var notificationsEnabled:    Bool = true
    @AppStorage("alertUnreachableEnabled") var alertUnreachableEnabled: Bool = true

    @AppStorage("alertGpuTempEnabled") var alertGpuTempEnabled: Bool   = true
    @AppStorage("gpuTempTrigger")      var gpuTempTrigger:      Double = 85
    @AppStorage("gpuTempClear")        var gpuTempClear:        Double = 80

    @AppStorage("alertGpuCrashEnabled")    var alertGpuCrashEnabled:    Bool   = true
    @AppStorage("gpuCrashHighPct")         var gpuCrashHighPct:         Double = 70
    @AppStorage("gpuCrashLowPct")          var gpuCrashLowPct:          Double = 5
    @AppStorage("gpuCrashSustainedSec")    var gpuCrashSustainedSec:    Double = 60

    @AppStorage("alertVramEnabled") var alertVramEnabled: Bool   = true
    @AppStorage("vramTrigger")      var vramTrigger:      Double = 95
    @AppStorage("vramClear")        var vramClear:        Double = 90

    @AppStorage("alertDiskEnabled") var alertDiskEnabled: Bool   = true
    @AppStorage("diskTrigger")      var diskTrigger:      Double = 95
    @AppStorage("diskClear")        var diskClear:        Double = 90

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
