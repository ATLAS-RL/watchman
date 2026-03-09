import SwiftUI

@main
struct WatchmanApp: App {
    @StateObject private var poller = MetricsPoller()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(poller: poller)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                Text(poller.overallStatus.label)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
