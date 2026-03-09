import SwiftUI

struct MenuBarView: View {
    @ObservedObject var poller: MetricsPoller

    var body: some View {
        VStack(spacing: 8) {
            ForEach(poller.workers) { worker in
                WorkerDetailView(worker: worker)
            }

            Divider()

            Button("Quit Watchman") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 320)
    }
}
