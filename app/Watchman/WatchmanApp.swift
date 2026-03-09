import AppKit
import SwiftUI

@main
struct WatchmanApp: App {
    @StateObject private var poller = MetricsPoller()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(poller: poller, settings: settings)
        } label: {
            Image(nsImage: renderMenuBarImage())
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, workers: poller.workers)
        }
    }

    // MARK: - Render colored menu bar label as NSImage
    // Format: {alias} ● {peak%} 🌡{temp} │ {alias} ● {peak%} 🌡{temp}

    private func renderMenuBarImage() -> NSImage {
        let attributed = buildAttributedString()
        let size = attributed.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18))
        image.lockFocus()
        attributed.draw(at: NSPoint(x: 0, y: (18 - size.height) / 2))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        for (index, worker) in poller.workers.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  │  ",
                    attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }

            let alias = settings.alias(for: worker.id)

            if worker.state == .unreachable {
                result.append(NSAttributedString(
                    string: "\(alias) — —",
                    attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            } else {
                // Name
                result.append(NSAttributedString(
                    string: "\(alias) ",
                    attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]
                ))

                // Peak usage with colored dot
                if let peak = worker.peakUsage {
                    result.append(NSAttributedString(
                        string: "●",
                        attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: nsUsageColor(peak)]
                    ))
                    result.append(NSAttributedString(
                        string: "\(peak)%",
                        attributes: [.font: font, .foregroundColor: nsUsageColor(peak)]
                    ))
                }

                // Temp with thermometer
                if let temp = worker.maxTemp {
                    result.append(NSAttributedString(
                        string: " ",
                        attributes: [.font: smallFont]
                    ))
                    // Thermometer icon as text
                    result.append(NSAttributedString(
                        string: "🌡",
                        attributes: [.font: NSFont.systemFont(ofSize: 9)]
                    ))
                    result.append(NSAttributedString(
                        string: "\(temp)°",
                        attributes: [.font: font, .foregroundColor: nsTempColor(temp)]
                    ))
                }
            }
        }
        return result
    }

    private func nsUsageColor(_ percent: Int) -> NSColor {
        if percent >= 85 { return .systemRed }
        if percent >= 70 { return .systemYellow }
        return .systemGreen
    }

    private func nsTempColor(_ temp: Int) -> NSColor {
        if temp >= 85 { return .systemRed }
        if temp >= 75 { return .systemOrange }
        if temp >= 60 { return .systemYellow }
        return .labelColor
    }
}
