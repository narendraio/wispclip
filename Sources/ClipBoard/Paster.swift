import AppKit
import ApplicationServices

/// Puts a history item back on the clipboard and (if allowed) pastes it into the front app.
enum Paster {
    /// `plain` drops the formatting and pastes only the text.
    static func copy(_ item: ClipItem, plain: Bool = false, store: ClipStore, monitor: ClipboardMonitor) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
            if !plain, let rich = store.richData(for: item) {
                pb.setData(rich.data, forType: rich.type)
            }
        case .file:
            let urls = (item.text ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pb.writeObjects(urls)
        case .image:
            if let data = store.imageData(for: item), let image = NSImage(data: data) {
                pb.writeObjects([image])
                pb.setData(data, forType: .png)
            }
        }
        monitor.skipCurrentChange()
    }

    static func copyText(_ text: String, monitor: ClipboardMonitor) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        monitor.skipCurrentChange()
    }

    static var canAutoPaste: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt asking for Accessibility access (needed to send ⌘V).
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Simulates ⌘V in whichever app is frontmost.
    static func sendPasteKeystroke() {
        guard canAutoPaste else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
