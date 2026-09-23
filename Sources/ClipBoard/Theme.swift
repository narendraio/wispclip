import AppKit
import SwiftUI

/// Colors and small building blocks modeled on the beUI command palette:
/// neutral surfaces, hairline borders, muted secondary text, bordered key caps.
enum Theme {
    static let background = dynamic(light: .init(white: 0.99, alpha: 1), dark: rgb(0x151515))
    static let card = dynamic(light: .init(white: 0.97, alpha: 1), dark: rgb(0x1C1C1C))
    static let foreground = dynamic(light: .init(white: 0.15, alpha: 1), dark: .init(white: 0.96, alpha: 1))
    static let muted = dynamic(light: .init(white: 0.50, alpha: 1), dark: .init(white: 0.62, alpha: 1))
    static let faint = dynamic(light: .init(white: 0.66, alpha: 1), dark: .init(white: 0.40, alpha: 1))
    static let border = dynamic(light: .init(white: 0.15, alpha: 0.07), dark: .init(white: 1, alpha: 0.06))
    static let borderStrong = dynamic(light: .init(white: 0.15, alpha: 0.12), dark: .init(white: 1, alpha: 0.10))
    static let highlight = dynamic(light: .init(white: 0.15, alpha: 0.05), dark: .init(white: 1, alpha: 0.065))
    static let accent = dynamic(light: rgb(0x00A5B8), dark: rgb(0x2AD4E4))
    static let warning = Color(red: 0.96, green: 0.65, blue: 0.14)

    // Syntax colors for JSON / SQL previews.
    static let synKey = accent
    static let synString = dynamic(light: rgb(0x1A7F37), dark: rgb(0x7EE787))
    static let synNumber = dynamic(light: rgb(0xB35900), dark: rgb(0xFFA657))
    static let synKeyword = dynamic(light: rgb(0x8250DF), dark: rgb(0xD2A8FF))

    /// Spring for the moving selection: tight enough to keep up with held arrow keys.
    static let cursorSpring = Animation.spring(response: 0.22, dampingFraction: 0.86)
    /// Spring for the panel opening: reads as instant.
    static let panelSpring = Animation.spring(response: 0.24, dampingFraction: 0.82)

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// A bordered key cap, e.g. `ESC` or `⌘P`.
struct Kbd: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.borderStrong, lineWidth: 1))
    }
}

/// Small uppercase group label.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.muted)
    }
}

/// Button that looks like a quiet bordered pill.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension Date {
    /// "now", "4m", "2h", "3d", "5w".
    func shortAge(now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(self)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 7): return "\(s / 86400)d"
        default: return "\(s / (86400 * 7))w"
        }
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
