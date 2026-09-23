import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ClipStore.shared
    private lazy var monitor = ClipboardMonitor(store: store)
    private lazy var panel = HistoryPanelController(store: store, monitor: monitor)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onCapture = { Feedback.copied() }
        monitor.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Wisp")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // ⌃⌘V opens the history from anywhere.
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | controlKey) { [weak self] in
            self?.panel.toggle()
        }
        if hotKey?.isRegistered == false {
            let alert = NSAlert()
            alert.messageText = "⌃⌘V is already used by another app"
            alert.informativeText = "You can still open the history from the menu bar icon. Change the shortcut in Sources/ClipBoard/main.swift and rebuild."
            alert.runModal()
        }

        if !Paster.canAutoPaste {
            Paster.requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // Rebuild the menu each time it opens so it always shows the latest items.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(withTitle: "Show Clipboard History", action: #selector(showPanel), keyEquivalent: "v")
            .keyEquivalentModifierMask = [.command, .control]
        menu.addItem(.separator())

        let recent = store.filtered("").prefix(10)
        if recent.isEmpty {
            menu.addItem(withTitle: "No items yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        for item in recent {
            let title = item.kind == .image ? "🖼 Image" : String(item.preview.prefix(60))
            let menuItem = NSMenuItem(title: (item.pinned ? "📌 " : "") + title,
                                      action: #selector(copyFromMenu(_:)), keyEquivalent: "")
            menuItem.representedObject = item.id
            menuItem.target = self
            if item.kind == .image, let image = store.image(for: item) {
                let thumb = NSImage(size: NSSize(width: 32, height: 32))
                thumb.lockFocus()
                image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
                thumb.unlockFocus()
                menuItem.image = thumb
                menuItem.title = "Image"
            }
            menu.addItem(menuItem)
        }

        menu.addItem(withTitle: "New Snippet", action: #selector(newSnippet), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: monitor.isPaused ? "Resume Recording" : "Pause Recording",
                                 action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(withTitle: "Clear History (keeps pinned)", action: #selector(clearHistory), keyEquivalent: "")
            .target = self

        // Copy Sound ▸ — picking one plays it, so you can compare.
        let soundMenu = NSMenu()
        for option in CopySound.allCases {
            if option == .tink || option == .none { soundMenu.addItem(.separator()) }
            let item = soundMenu.addItem(withTitle: option.rawValue, action: #selector(chooseCopySound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = Feedback.sound == option ? .on : .off
        }
        let soundItem = menu.addItem(withTitle: "Copy Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu

        let navSound = menu.addItem(withTitle: "Sound While Browsing", action: #selector(toggleNavSounds), keyEquivalent: "")
        navSound.target = self
        navSound.state = Sounds.enabled ? .on : .off

        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        if !Paster.canAutoPaste {
            menu.addItem(withTitle: "Enable Auto-Paste (Accessibility)…", action: #selector(enableAutoPaste),
                         keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Visit wispclip.com", action: #selector(openWebsite), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action == #selector(showPanel) { item.target = self }
    }

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func newSnippet() {
        panel.show()
        panel.newSnippet()
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://wispclip.com")!)
    }

    @objc private func chooseCopySound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sound = CopySound(rawValue: raw) else { return }
        Feedback.sound = sound
        Feedback.play(sound)
    }

    @objc private func toggleNavSounds() {
        Sounds.enabled.toggle()
        Sounds.tick()
    }

    @objc private func copyFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = store.items.first(where: { $0.id == id }) else { return }
        Paster.copy(item, store: store, monitor: monitor)
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        statusItem.button?.appearsDisabled = monitor.isPaused
    }

    @objc private func clearHistory() {
        store.clearUnpinned()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login setting"
            alert.informativeText = "Move Wisp.app into /Applications and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func enableAutoPaste() {
        Paster.openAccessibilitySettings()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
