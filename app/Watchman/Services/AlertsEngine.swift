import Foundation
import SwiftUI
import UserNotifications

/// Owns per-worker alert state, runs edge-detection on each poll result, and
/// dispatches notifications via `UNUserNotificationCenter`. Updated live
/// from `MetricsPoller` after every fetch cycle.
@MainActor
final class AlertsEngine: ObservableObject {
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var states: [String: LastAlertState] = [:]
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        authorizationStatus = current.authorizationStatus
        if current.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            authorizationStatus = (await center.notificationSettings()).authorizationStatus
        }
    }

    /// Opens System Settings' Notifications pane so the user can re-grant
    /// permission after denying (macOS does not re-prompt once denied).
    func openSystemNotificationsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Evaluation

    /// Called by `MetricsPoller` once per worker after each poll. `metrics`
    /// is nil when the worker was unreachable in the most recent cycle.
    func evaluate(workerId: String, alias: String, host: String?, metrics: WorkerMetrics?) {
        guard settings.notificationsEnabled else { return }
        var s = states[workerId] ?? LastAlertState()
        defer { states[workerId] = s }

        // Rule implementations arrive in the next commit. Stub routing:
        if let m = metrics {
            s.hadEverReachable = true
            if s.isUnreachable { s.isUnreachable = false }
            _ = m
            _ = alias
        } else {
            _ = host
        }
    }

    // MARK: - Dispatch

    func fire(_ type: AlertType, workerId: String, alias: String, detail: String) {
        let content = UNMutableNotificationContent()
        switch type {
        case .unreachable:
            content.title = "\(alias) unreachable"
            content.body = detail
        case .gpuTempCritical:
            content.title = "\(alias) GPU temperature critical"
            content.body = detail
        case .gpuUtilCrash:
            content.title = "\(alias) GPU idle — training may have crashed"
            content.body = detail
        case .vramCritical:
            content.title = "\(alias) VRAM nearly full"
            content.body = detail
        case .diskCritical:
            content.title = "\(alias) disk nearly full"
            content.body = detail
        }
        content.sound = .default

        let id = "\(workerId).\(type.rawValue)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
