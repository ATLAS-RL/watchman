import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let workers: [WorkerEntry]

    @State private var draftAliases: [String: String] = [:]
    @State private var hasChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            // General
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .foregroundStyle(Theme.textPrimary)

            // Worker Aliases
            VStack(alignment: .leading, spacing: 8) {
                Text("Worker Aliases")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.accent)
                Text("Customize names shown in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                ForEach(workers) { worker in
                    HStack {
                        Text(worker.id)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField(
                            worker.id,
                            text: draftBinding(for: worker.id)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Spacer()

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
        .padding(20)
        .frame(width: 360, height: 280)
        .fixedSize()
        .background(Theme.panelBg)
        .preferredColorScheme(.dark)
        .onAppear {
            draftAliases = settings.workerAliases
        }
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
