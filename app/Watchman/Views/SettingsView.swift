import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let workers: [WorkerEntry]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Worker Aliases") {
                Text("Customize names shown in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(workers) { worker in
                    HStack {
                        Text(worker.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        TextField(
                            worker.id,
                            text: aliasBinding(for: worker.id)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 240)
        .navigationTitle("Watchman Settings")
    }

    private func aliasBinding(for id: String) -> Binding<String> {
        Binding(
            get: { settings.workerAliases[id] ?? "" },
            set: { settings.workerAliases[id] = $0 }
        )
    }
}
