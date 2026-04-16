import AppKit
import SwiftUI

@main
struct WatchmanApp: App {
    @StateObject private var poller = MetricsPoller()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(poller: poller, settings: settings)
                .preferredColorScheme(.dark)
        } label: {
            Image(nsImage: renderMenuBarImage())
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, workers: poller.workers)
                .preferredColorScheme(.dark)
        }

        Window("History", id: "history") {
            HistoryWindow(poller: poller)
        }
        .windowResizability(.contentMinSize)
    }

    // MARK: - Render colored menu bar label as NSImage

    private func renderMenuBarImage() -> NSImage {
        let attributed = buildAttributedString()
        let size = attributed.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 22))
        image.lockFocus()
        attributed.draw(at: NSPoint(x: 0, y: (22 - size.height) / 2))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        for (index, worker) in poller.workers.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  │  ",
                    attributes: [.font: smallFont, .foregroundColor: NSColor(white: 0.75, alpha: 1)]
                ))
            }

            let alias = settings.alias(for: worker.id)

            if worker.state == .unreachable {
                result.append(NSAttributedString(
                    string: "\(alias) — —",
                    attributes: [.font: font, .foregroundColor: NSColor(white: 0.60, alpha: 1)]
                ))
            } else {
                // Name
                result.append(NSAttributedString(
                    string: "\(alias) ",
                    attributes: [.font: smallFont, .foregroundColor: NSColor(white: 0.75, alpha: 1)]
                ))

                // Peak usage with gauge icon
                if let peak = worker.peakUsage {
                    let usageColor = nsUsageColor(peak)
                    if let gaugeImage = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil) {
                        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                        if let configured = gaugeImage.withSymbolConfiguration(config) {
                            let tinted = configured.tinted(with: usageColor)
                            let attachment = NSTextAttachment()
                            attachment.image = tinted
                            let iconSize = tinted.size
                            attachment.bounds = CGRect(x: 0, y: -1, width: iconSize.width, height: iconSize.height)
                            result.append(NSAttributedString(attachment: attachment))
                        }
                    }
                    result.append(NSAttributedString(
                        string: " \(peak)%",
                        attributes: [.font: font, .foregroundColor: usageColor]
                    ))
                }

                // Temp with SF Symbol thermometer (colored by temp)
                if let temp = worker.maxTemp {
                    result.append(NSAttributedString(
                        string: "  ",
                        attributes: [.font: smallFont]
                    ))

                    // Render SF Symbol thermometer colored by temperature
                    if let thermImage = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil) {
                        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                        if let configured = thermImage.withSymbolConfiguration(config) {
                            let tinted = configured.tinted(with: nsTempColor(temp))
                            let attachment = NSTextAttachment()
                            attachment.image = tinted
                            let iconSize = tinted.size
                            attachment.bounds = CGRect(x: 0, y: -1, width: iconSize.width, height: iconSize.height)
                            result.append(NSAttributedString(attachment: attachment))
                        }
                    }

                    result.append(NSAttributedString(
                        string: " \(temp)°",
                        attributes: [.font: font, .foregroundColor: nsTempColor(temp)]
                    ))
                }
            }
        }
        return result
    }

    private func nsUsageColor(_ percent: Int) -> NSColor {
        if percent >= 85 { return NSColor(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0, alpha: 1) } // #FF0050
        if percent >= 70 { return NSColor(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0, alpha: 1) } // #FFE500
        return NSColor(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0, alpha: 1) // #00FF88
    }

    private func nsTempColor(_ temp: Int) -> NSColor {
        if temp >= 85 { return NSColor(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0, alpha: 1) } // #FF0050
        if temp >= 75 { return NSColor(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0, alpha: 1) } // #FF7A00
        if temp >= 60 { return NSColor(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0, alpha: 1) } // #FFE500
        return NSColor(red: 0x66/255.0, green: 0x88/255.0, blue: 0x99/255.0, alpha: 1) // #668899 cool gray, visible on menu bar
    }
}

// MARK: - NSImage tinting helper

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
