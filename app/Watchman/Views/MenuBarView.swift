import SwiftUI

// MARK: - StatusPill

private struct StatusPill: View {
    let status: OverallStatus

    private var color: Color {
        switch status {
        case .allGood: return .green
        case .someWarning: return .yellow
        case .someCritical: return .red
        case .allUnreachable: return .gray
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color)
            )
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @ObservedObject var poller: MetricsPoller
    @ObservedObject var settings: AppSettings

    private var relativeTimestamp: String {
        guard let t = poller.lastPollTime else { return "Not yet polled" }
        let elapsed = Int(-t.timeIntervalSinceNow)
        if elapsed < 2 { return "Updated just now" }
        return "Updated \(elapsed) seconds ago"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Watchman")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                StatusPill(status: poller.overallStatus)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Worker cards
            VStack(spacing: 8) {
                ForEach(poller.workers) { worker in
                    WorkerDetailView(
                        worker: worker,
                        alias: settings.workerAliases[worker.id]
                    )
                }
            }
            .padding(.horizontal, 12)

            Spacer().frame(height: 10)

            // Footer
            HStack {
                Text(relativeTimestamp)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                SettingsLink {
                    Image(systemName: "gear")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 360)
        .background(Theme.panelBg)
    }
}
