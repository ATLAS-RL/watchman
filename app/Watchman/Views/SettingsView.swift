import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var alerts: AlertsEngine
    let workers: [WorkerEntry]

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            WorkersTab(settings: settings, workers: workers)
                .tabItem { Label("Workers", systemImage: "server.rack") }
            AlertsTab(settings: settings, alerts: alerts)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
        }
        .frame(width: 480, height: 520)
        .background(Theme.panelBg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Workers (aliases)

private struct WorkersTab: View {
    @ObservedObject var settings: AppSettings
    let workers: [WorkerEntry]

    @State private var draftAliases: [String: String] = [:]
    @State private var hasChanges = false

    var body: some View {
        Form {
            Section(
                header: Text("Worker aliases"),
                footer: Text("Customize names shown in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                ForEach(workers) { worker in
                    HStack {
                        Text(worker.id)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField(worker.id, text: draftBinding(for: worker.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save") {
                        for (id, alias) in draftAliases {
                            settings.workerAliases[id] = alias
                        }
                        hasChanges = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!hasChanges)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftAliases = settings.workerAliases }
    }

    private func draftBinding(for id: String) -> Binding<String> {
        Binding(
            get: { draftAliases[id] ?? "" },
            set: {
                draftAliases[id] = $0
                hasChanges = true
            }
        )
    }
}
