import AppKit
import SwiftUI

enum PanelFocus: Hashable {
    case search, actionSearch, snippetTitle, snippetBody
}

/// One entry in the ⌘K actions menu.
struct PanelAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let group: String
    var hint: String?
    /// Preview of the result, for text transforms.
    var detail: String?
    let perform: () -> Void
}

/// Shared state between the panel's keyboard handling and the SwiftUI view.
final class PanelState: ObservableObject {
    @Published var query = ""
    @Published var filter: ClipFilter = .all
    @Published var selected = 0 {
        didSet { if selected != oldValue, soundsArmed { Sounds.tick() } }
    }
    @Published var focus: PanelFocus = .search
    @Published var focusToken = 0
    @Published var canAutoPaste = true
    @Published var appeared = false
    /// Time the panel was opened; ages ("4m") are measured against it.
    @Published var now = Date()

    @Published var actionsOpen = false
    @Published var actions: [PanelAction] = []
    @Published var actionQuery = ""
    @Published var actionSelected = 0 {
        didSet { if actionSelected != oldValue, soundsArmed { Sounds.tick(pitch: 1.15) } }
    }

    /// Ticks only while the panel is open, not when it resets its state on show.
    var soundsArmed = false
    /// Scroll distance since the last tick, so scrolling the list clicks like a dial.
    var scrollAccumulator: CGFloat = 0

    /// The snippet being edited in the preview pane, if any.
    @Published var editingID: UUID?

    /// Rows turning to dust before they are removed, with the moment each started.
    @Published var dissolving: [UUID: Date] = [:]
    /// Dust still drifting above the list.
    @Published var dust: [DustBurst] = []

    /// Hovering only moves the selection after the mouse actually moves,
    /// so rows scrolling under a still pointer don't steal the keyboard cursor.
    var mouseActive = false

    var filteredActions: [PanelAction] {
        let q = actionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q) }
    }
}

/// A floating panel that can take keyboard focus without activating the app,
/// so the app you were working in stays frontmost and receives the paste.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class HistoryPanelController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 760, height: 480)

    let store: ClipStore
    private let monitor: ClipboardMonitor
    let state = PanelState()
    private var panel: KeyPanel!
    private var eventMonitor: Any?

    init(store: ClipStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        super.init()

        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistoryView(store: store, state: state, controller: self))
    }

    var isVisible: Bool { panel.isVisible }

    private var list: [ClipItem] { store.filtered(state.query, filter: state.filter) }

    private var selectedItem: ClipItem? {
        let list = list
        return list.indices.contains(state.selected) ? list[state.selected] : nil
    }

    // MARK: Show / hide

    func toggle() { isVisible ? hide() : show() }

    func show() {
        state.soundsArmed = false
        state.query = ""
        state.filter = .all
        state.selected = 0
        state.now = Date()
        state.mouseActive = false
        state.canAutoPaste = Paster.canAutoPaste
        state.actionsOpen = false
        state.editingID = nil
        state.focus = .search
        state.appeared = false
        state.focusToken += 1

        // Upper third of the screen that has the mouse pointer, like Spotlight.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                         y: frame.maxY - frame.height * 0.22 - Self.size.height))
        }
        panel.makeKeyAndOrderFront(nil)
        installEventMonitor()
        state.scrollAccumulator = 0
        state.soundsArmed = true
        DispatchQueue.main.async {
            withAnimation(Theme.panelSpring) { self.state.appeared = true }
            self.panel.invalidateShadow()
        }
    }

    func hide() {
        state.soundsArmed = false
        if state.editingID != nil { endEditing() }
        state.actionsOpen = false
        state.actions = []
        panel.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: Pasting

    func pick(_ item: ClipItem, plain: Bool = false) {
        Paster.copy(item, plain: plain, store: store, monitor: monitor)
        hideAndPaste()
    }

    /// Pastes text produced by an action, and keeps it in the history.
    private func pasteText(_ text: String) {
        store.addText(text, source: .init(name: "Wisp", bundleID: Bundle.main.bundleIdentifier))
        Paster.copyText(text, monitor: monitor)
        hideAndPaste()
    }

    private func hideAndPaste() {
        hide()
        if Paster.canAutoPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendPasteKeystroke() }
        }
    }

    // MARK: Selection

    func select(_ index: Int) {
        state.mouseActive = false
        withAnimation(Theme.cursorSpring) { state.selected = index }
    }

    private func selectItem(id: UUID) {
        state.selected = list.firstIndex { $0.id == id } ?? 0
    }

    private func setFilter(_ filter: ClipFilter) {
        withAnimation(Theme.cursorSpring) {
            state.filter = filter
            state.selected = 0
        }
    }

    // MARK: Snippets

    func newSnippet() {
        let snippet = store.addSnippet(title: "", text: "")
        beginEditing(snippet, focus: .snippetTitle)
    }

    func saveAsSnippet(_ item: ClipItem) {
        guard item.kind == .text, !item.isSnippet else { return }
        let firstLine = (item.text ?? "").split(separator: "\n").first.map(String.init) ?? ""
        let title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(40))
        let snippet = store.addSnippet(title: title, text: item.text ?? "")
        beginEditing(snippet, focus: .snippetTitle)
    }

    func beginEditing(_ item: ClipItem, focus: PanelFocus = .snippetBody) {
        guard item.isSnippet else { return }
        closeActions()
        state.editingID = item.id
        state.query = ""
        state.filter = .snippets
        selectItem(id: item.id)
        state.focus = focus
    }

    func endEditing() {
        guard let id = state.editingID else { return }
        state.editingID = nil
        // A snippet left with no text is thrown away.
        if let item = store.items.first(where: { $0.id == id }),
           (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.delete(item)
            state.selected = 0
        }
        state.focus = .search
    }

    // MARK: Actions menu

    func openActions() {
        state.actions = buildActions(for: selectedItem)
        state.actionQuery = ""
        state.actionSelected = 0
        withAnimation(Theme.panelSpring) { state.actionsOpen = true }
        state.focus = .actionSearch
    }

    func closeActions() {
        guard state.actionsOpen else { return }
        withAnimation(.easeOut(duration: 0.12)) { state.actionsOpen = false }
        state.focus = .search
    }

    func run(_ action: PanelAction) {
        state.actionsOpen = false
        state.focus = .search
        action.perform()
    }

    private func buildActions(for item: ClipItem?) -> [PanelAction] {
        var actions: [PanelAction] = []
        if let item {
            let canPaste = Paster.canAutoPaste
            actions.append(PanelAction(id: "paste", title: canPaste ? "Paste" : "Copy", symbol: "doc.on.clipboard",
                                       group: "Item", hint: "↩") { [unowned self] in pick(item) })
            if item.kind == .text {
                actions.append(PanelAction(id: "plain", title: canPaste ? "Paste as Plain Text" : "Copy as Plain Text",
                                           symbol: "textformat", group: "Item", hint: "⌥↩") { [unowned self] in
                    pick(item, plain: true)
                })
            }
            if item.isLink, let url = URL(string: item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                actions.append(PanelAction(id: "open", title: "Open Link", symbol: "safari", group: "Item",
                                           hint: "⌘O") { [unowned self] in
                    hide()
                    NSWorkspace.shared.open(url)
                })
            }
            if item.isSnippet {
                actions.append(PanelAction(id: "edit", title: "Edit Snippet", symbol: "pencil", group: "Item",
                                           hint: "⌘E") { [unowned self] in beginEditing(item) })
            } else if item.kind == .text {
                actions.append(PanelAction(id: "snippet", title: "Save as Snippet", symbol: "bookmark", group: "Item",
                                           hint: "⌘S") { [unowned self] in saveAsSnippet(item) })
            }
            actions.append(PanelAction(id: "pin", title: item.pinned ? "Unpin" : "Pin", symbol: "pin", group: "Item",
                                       hint: "⌘P") { [unowned self] in togglePin(item) })
            actions.append(PanelAction(id: "delete", title: "Delete", symbol: "trash", group: "Item",
                                       hint: "⌘⌫") { [unowned self] in delete(item) })

            if item.kind == .text, let text = item.text {
                for (transform, result) in Transforms.available(for: text, type: Detector.type(of: item)) {
                    actions.append(PanelAction(id: transform.id, title: transform.title, symbol: transform.symbol,
                                               group: "Transform", detail: oneLine(result)) { [unowned self] in
                        pasteText(result)
                    })
                }
            }
            if item.kind == .file, let paths = item.text {
                actions.append(PanelAction(id: "paths", title: "Paste File Path", symbol: "folder", group: "Transform",
                                           detail: oneLine(paths)) { [unowned self] in pasteText(paths) })
            }
        }
        for generator in Transforms.generators {
            let result = generator.apply("")
            if let result {
                actions.append(PanelAction(id: generator.id, title: generator.title, symbol: generator.symbol,
                                           group: "Generate", detail: result) { [unowned self] in pasteText(result) })
            }
        }
        actions.append(PanelAction(id: "new", title: "New Snippet", symbol: "plus", group: "Snippets",
                                   hint: "⌘N") { [unowned self] in newSnippet() })
        return actions
    }

    private func oneLine(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(80))
    }

    func togglePin(_ item: ClipItem) {
        withAnimation(Theme.cursorSpring) {
            store.togglePin(item)
            selectItem(id: item.id)
        }
    }

    /// Turns the row to dust, then removes the item; the rows below glide up while the dust drifts.
    func delete(_ item: ClipItem) {
        guard state.dissolving[item.id] == nil else { return }
        state.dissolving[item.id] = Date()
        Sounds.dissolve()
        DispatchQueue.main.asyncAfter(deadline: .now() + Dust.sweep + 0.04) { [self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                store.delete(item)
                state.dissolving[item.id] = nil
                state.selected = min(state.selected, max(list.count - 1, 0))
            }
        }
    }

    /// Called by a dissolving row with its on-screen frame.
    func spawnDust(_ rect: CGRect) {
        let burst = DustBurst(rect: rect)
        state.dust.append(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + Dust.lifetime) { [self] in
            state.dust.removeAll { $0.id == burst.id }
        }
    }

    // MARK: Keyboard

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved {
                self.state.mouseActive = true
                return event
            }
            if event.type == .scrollWheel {
                // One soft click per row's worth of scrolling.
                self.state.scrollAccumulator += abs(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10)
                if self.state.scrollAccumulator >= 60 {
                    self.state.scrollAccumulator = 0
                    Sounds.tick(pitch: 0.9, volume: 0.1)
                }
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Returns true when the key was handled here (and shouldn't reach the text fields).
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let key = Int(event.keyCode)

        // While editing a snippet, typing goes to the editor; only these keys are ours.
        if state.editingID != nil {
            if key == 53 || (cmd && (key == 36 || key == 1)) { // Esc, ⌘↩, ⌘S
                endEditing()
                return true
            }
            return false
        }

        if state.actionsOpen {
            let actions = state.filteredActions
            switch key {
            case 53: closeActions()
            case 40 where cmd: closeActions()
            case 125:
                state.mouseActive = false
                withAnimation(Theme.cursorSpring) { state.actionSelected = min(state.actionSelected + 1, max(actions.count - 1, 0)) }
            case 126:
                state.mouseActive = false
                withAnimation(Theme.cursorSpring) { state.actionSelected = max(state.actionSelected - 1, 0) }
            case 36, 76:
                if actions.indices.contains(state.actionSelected) { run(actions[state.actionSelected]) }
            default: return false
            }
            return true
        }

        let list = list
        let item = list.indices.contains(state.selected) ? list[state.selected] : nil

        switch key {
        case 53: // Escape clears the search first, then closes.
            if state.query.isEmpty { hide() } else { state.query = "" }
        case 125: // Down
            if !list.isEmpty { select(min(state.selected + 1, list.count - 1)) }
        case 126: // Up
            select(max(state.selected - 1, 0))
        case 48: // Tab / ⇧Tab switches the type filter
            let all = ClipFilter.allCases
            let i = all.firstIndex(of: state.filter) ?? 0
            setFilter(all[(i + (flags.contains(.shift) ? all.count - 1 : 1)) % all.count])
        case 36, 76: // Return pastes; ⌥Return pastes as plain text
            if let item { pick(item, plain: flags.contains(.option)) }
        case 40 where cmd: // ⌘K
            openActions()
        case 45 where cmd: // ⌘N
            newSnippet()
        case 1 where cmd: // ⌘S
            if let item { item.isSnippet ? beginEditing(item) : saveAsSnippet(item) }
        case 14 where cmd: // ⌘E
            if let item { beginEditing(item) }
        case 31 where cmd: // ⌘O
            if let item, item.isLink, let url = URL(string: item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                hide()
                NSWorkspace.shared.open(url)
            }
        case 51 where cmd: // ⌘⌫
            if let item { delete(item) }
        case 35 where cmd: // ⌘P
            if let item { togglePin(item) }
        default:
            // ⌘1 … ⌘9 picks that row directly.
            if cmd, let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
                if list.indices.contains(n - 1) { pick(list[n - 1]) }
                return true
            }
            return false
        }
        return true
    }
}

// MARK: - Main view

struct HistoryView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    unowned let controller: HistoryPanelController

    @FocusState private var focus: PanelFocus?
    @Namespace private var ns

    private let radius: CGFloat = 14

    var body: some View {
        let list = store.filtered(state.query, filter: state.filter)
        let current = list.indices.contains(state.selected) ? list[state.selected] : nil

        ZStack {
            VStack(spacing: 0) {
                searchBar(count: list.count)
                hairline
                filterBar
                HStack(spacing: 0) {
                    listColumn(list)
                        .frame(width: 330)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    PreviewPane(item: current, store: store, state: state, focus: $focus)
                        .frame(maxWidth: .infinity)
                }
                if !state.canAutoPaste {
                    hairline
                    autoPasteBanner
                }
                hairline
                footer(item: current)
            }

            if state.actionsOpen {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.closeActions() }
                    .transition(.opacity)
                ActionsMenu(state: state, controller: controller, focus: $focus)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .frame(width: HistoryPanelController.size.width, height: HistoryPanelController.size.height)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Theme.borderStrong, lineWidth: 1))
        .scaleEffect(state.appeared ? 1 : 0.97, anchor: .top)
        .opacity(state.appeared ? 1 : 0)
        .onChange(of: state.focus) { focus = state.focus }
        .onChange(of: state.focusToken) { focus = state.focus }
        .onChange(of: focus) { if let focus { state.focus = focus } }
        .onAppear { focus = state.focus }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: Search

    private func searchBar(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.muted)
            TextField("", text: $state.query, prompt: Text("Search clipboard…").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.foreground)
                .focused($focus, equals: .search)
                .onChange(of: state.query) { if state.editingID == nil { state.selected = 0 } }
            if !state.query.isEmpty {
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .transition(.opacity)
            }
            Kbd("ESC")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.background)
    }

    // MARK: Filter tabs

    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(ClipFilter.allCases, id: \.self) { filter in
                let active = filter == state.filter
                HStack(spacing: 4) {
                    if filter == .snippets {
                        Image(systemName: "bookmark.fill").font(.system(size: 9))
                    }
                    Text(filter.rawValue)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.foreground : Theme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if active {
                        Capsule()
                            .fill(Theme.highlight)
                            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                            .matchedGeometryEffect(id: "filter", in: ns)
                    }
                }
                .contentShape(Capsule())
                .onTapGesture {
                    controller.endEditing()
                    withAnimation(Theme.cursorSpring) {
                        state.filter = filter
                        state.selected = 0
                    }
                    state.focus = .search
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Kbd("⇥")
                Text("to switch").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.background)
        .overlay(alignment: .bottom) { hairline }
    }

    // MARK: List

    @ViewBuilder
    private func listColumn(_ list: [ClipItem]) -> some View {
        if list.isEmpty {
            EmptyState(filter: state.filter, hasItems: !store.items.isEmpty) { controller.newSnippet() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections(list), id: \.title) { section in
                            SectionLabel(text: section.title)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(section.rows, id: \.item.id) { row in
                                rowView(row.item, index: row.index)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .coordinateSpace(name: "dust")
                .overlay { DustLayer(bursts: state.dust) }
                .onChange(of: state.selected) {
                    guard !state.mouseActive, list.indices.contains(state.selected) else { return }
                    proxy.scrollTo(list[state.selected].id)
                }
                .onChange(of: state.focusToken) {
                    if let first = list.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private func rowView(_ item: ClipItem, index: Int) -> some View {
        ClipRow(item: item, index: index, selected: index == state.selected,
                store: store, now: state.now, ns: ns,
                onDelete: { controller.delete(item) })
            .modifier(DustErase(start: state.dissolving[item.id]))
            .background {
                if state.dissolving[item.id] != nil {
                    GeometryReader { g in
                        Color.clear.onAppear { controller.spawnDust(g.frame(in: .named("dust"))) }
                    }
                }
            }
            .id(item.id)
            .contentShape(Rectangle())
            .onTapGesture {
                if state.editingID != nil {
                    controller.endEditing()
                    controller.select(index)
                } else {
                    controller.pick(item, plain: NSEvent.modifierFlags.contains(.option))
                }
            }
            .onHover { inside in
                guard inside, state.mouseActive, state.editingID == nil, state.selected != index else { return }
                withAnimation(Theme.cursorSpring) { state.selected = index }
            }
            .contextMenu {
                Button("Paste") { controller.pick(item) }
                if item.kind == .text {
                    Button("Paste as Plain Text") { controller.pick(item, plain: true) }
                }
                if item.isSnippet {
                    Button("Edit Snippet") { controller.beginEditing(item) }
                } else if item.kind == .text {
                    Button("Save as Snippet") { controller.saveAsSnippet(item) }
                }
                Button(item.pinned ? "Unpin" : "Pin") { controller.togglePin(item) }
                Divider()
                Button("Delete") { controller.delete(item) }
            }
    }

    private struct Section {
        var title: String
        var rows: [(index: Int, item: ClipItem)]
    }

    /// Groups into Pinned / Snippets / Today / Yesterday / This Week / Older, keeping list order.
    private func sections(_ list: [ClipItem]) -> [Section] {
        let cal = Calendar.current
        var result: [Section] = []
        for (index, item) in list.enumerated() {
            let title: String
            if item.pinned { title = "Pinned" }
            else if item.isSnippet { title = "Snippets" }
            else if cal.isDateInToday(item.date) { title = "Today" }
            else if cal.isDateInYesterday(item.date) { title = "Yesterday" }
            else if state.now.timeIntervalSince(item.date) < 7 * 86400 { title = "This Week" }
            else { title = "Older" }

            if result.last?.title == title {
                result[result.count - 1].rows.append((index, item))
            } else {
                result.append(Section(title: title, rows: [(index, item)]))
            }
        }
        return result
    }

    // MARK: Footer

    private var autoPasteBanner: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.warning).frame(width: 6, height: 6)
            Text("Auto-paste is off. Items are copied; press ⌘V yourself.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
            Spacer()
            Button("Enable") { Paster.openAccessibilitySettings() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.background)
    }

    private func footer(item: ClipItem?) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.highlight))
                Text("Clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Text("\(store.items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
            if state.editingID != nil {
                FooterAction(title: "Editing snippet, saved automatically", key: nil)
                footerDivider
                FooterAction(title: "Done", key: "ESC", primary: true)
            } else if let item {
                FooterAction(title: state.canAutoPaste ? "Paste" : "Copy", key: "↩", primary: true)
                if item.kind == .text {
                    footerDivider
                    FooterAction(title: "Plain Text", key: "⌥↩")
                }
                footerDivider
                if item.isSnippet {
                    FooterAction(title: "Edit", key: "⌘E")
                } else if item.kind == .text {
                    FooterAction(title: "Save Snippet", key: "⌘S")
                }
                footerDivider
                FooterAction(title: "Actions", key: "⌘K")
                footerDivider
                FooterAction(title: "Delete", key: "⌘⌫")
            } else {
                FooterAction(title: "New Snippet", key: "⌘N")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.background)
    }

    private var footerDivider: some View {
        Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 14)
    }
}

private struct FooterAction: View {
    let title: String
    let key: String?
    var primary = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: primary ? .medium : .regular))
                .foregroundStyle(primary ? Theme.foreground : Theme.muted)
            if let key { Kbd(key) }
        }
    }
}

// MARK: - Actions menu

private struct ActionsMenu: View {
    @ObservedObject var state: PanelState
    unowned let controller: HistoryPanelController
    var focus: FocusState<PanelFocus?>.Binding
    @Namespace private var ns

    var body: some View {
        let actions = state.filteredActions
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField("", text: $state.actionQuery, prompt: Text("Search actions…").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.foreground)
                    .focused(focus, equals: .actionSearch)
                    .onChange(of: state.actionQuery) { state.actionSelected = 0 }
                Kbd("⌘K")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle().fill(Theme.border).frame(height: 1)

            if actions.isEmpty {
                Text("No matching actions")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(groups(actions), id: \.name) { group in
                                SectionLabel(text: group.name)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                                ForEach(group.rows, id: \.action.id) { row in
                                    actionRow(row.action, selected: row.index == state.actionSelected)
                                        .id(row.action.id)
                                        .onTapGesture { controller.run(row.action) }
                                        .onHover { inside in
                                            guard inside, state.mouseActive else { return }
                                            withAnimation(Theme.cursorSpring) { state.actionSelected = row.index }
                                        }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: state.actionSelected) {
                        guard !state.mouseActive, actions.indices.contains(state.actionSelected) else { return }
                        proxy.scrollTo(actions[state.actionSelected].id)
                    }
                }
            }
        }
        .frame(width: 420, height: 360)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }

    private func actionRow(_ action: PanelAction, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.foreground : Theme.muted)
                .frame(width: 18)
            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.foreground : Theme.foreground.opacity(0.82))
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = action.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if let hint = action.hint { Kbd(hint) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.highlight)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
                    .matchedGeometryEffect(id: "actionCursor", in: ns)
            }
        }
    }

    private struct Group {
        var name: String
        var rows: [(index: Int, action: PanelAction)]
    }

    private func groups(_ actions: [PanelAction]) -> [Group] {
        var result: [Group] = []
        for (index, action) in actions.enumerated() {
            if let i = result.firstIndex(where: { $0.name == action.group }) {
                result[i].rows.append((index, action))
            } else {
                result.append(Group(name: action.group, rows: [(index, action)]))
            }
        }
        return result
    }
}

// MARK: - Row

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let store: ClipStore
    let now: Date
    let ns: Namespace.ID
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(item: item, store: store, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: item.isSnippet ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.foreground : Theme.foreground.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.accent)
                    }
                    if item.isSnippet {
                        Text(item.preview.isEmpty ? "Empty" : item.preview).lineLimit(1)
                    } else {
                        Text(typeLabel)
                            .foregroundStyle(typeLabel == "Text" ? Theme.muted : Theme.accent)
                        Text("·")
                        Text(item.sourceApp ?? "Unknown").lineLimit(1)
                        Text("·")
                        Text(item.date.shortAge(now: now))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            }

            Spacer(minLength: 6)

            if selected {
                DeleteButton(action: onDelete).transition(.opacity)
                Kbd("↩").transition(.opacity)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.highlight)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
                    .matchedGeometryEffect(id: "cursor", in: ns)
            }
        }
    }

    private var title: String {
        switch item.kind {
        case .image:
            if let rep = store.image(for: item)?.representations.first {
                return "Image \(rep.pixelsWide)×\(rep.pixelsHigh)"
            }
            return "Image"
        default:
            return item.displayTitle
        }
    }

    private var typeLabel: String {
        switch item.kind {
        case .text: return Detector.type(of: item).rawValue
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

/// Trash button shown on the selected row; turns red on hover.
private struct DeleteButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Color.red : Theme.muted)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.red.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Delete (⌘⌫)")
        .onHover { hovering = $0 }
    }
}

/// Small square showing an image thumbnail, color swatch, or a type symbol.
struct Thumbnail: View {
    let item: ClipItem
    let store: ClipStore
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.background)
            content
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image, let image = store.image(for: item) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let color = item.color {
            Color(nsColor: color).padding(5).clipShape(RoundedRectangle(cornerRadius: 3))
        } else if item.kind == .file, let first = item.text?.split(separator: "\n").first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: String(first)))
                .resizable().scaledToFit().padding(3)
        } else {
            let type = Detector.type(of: item)
            Image(systemName: item.isSnippet ? "bookmark" : type.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.isSnippet || type != .text ? Theme.accent : Theme.muted)
        }
    }
}

// MARK: - Preview

struct PreviewPane: View {
    let item: ClipItem?
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    var focus: FocusState<PanelFocus?>.Binding

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                if state.editingID == item.id {
                    SnippetEditor(id: item.id, store: store, focus: focus)
                } else {
                    ScrollView {
                        content(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: .infinity)
                }

                Rectangle().fill(Theme.border).frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Information")
                        .padding(.bottom, 2)
                    if !item.isSnippet {
                        MetaRow(label: "Source") {
                            HStack(spacing: 5) {
                                if let icon = AppIcons.icon(bundleID: item.sourceBundleID) {
                                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                                }
                                Text(item.sourceApp ?? "Unknown")
                            }
                        }
                    }
                    ForEach(details(item), id: \.0) { label, value in
                        MetaRow(label: label) { Text(value) }
                    }
                    MetaRow(label: item.isSnippet ? "Created" : "Copied") {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(16)
                .background(Theme.background.opacity(0.5))
            }
            .id(item.id)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            textContent(item)
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: 220)
            }
        case .file:
            VStack(alignment: .leading, spacing: 10) {
                ForEach((item.text ?? "").split(separator: "\n").map(String.init), id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.foreground)
                            Text((path as NSString).deletingLastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    private let code = Font.system(size: 12.5, design: .monospaced)

    @ViewBuilder private func textContent(_ item: ClipItem) -> some View {
        let text = item.text ?? ""
        VStack(alignment: .leading, spacing: 10) {
            if item.isSnippet {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.foreground)
                    Spacer()
                    Kbd("⌘E")
                    Text("to edit").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            switch Detector.type(of: item) {
            case .color:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: item.color ?? .clear))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
                Text(text).font(code).foregroundStyle(Theme.foreground)
            case .json:
                Text(Highlighter.json(Transforms.prettyJSON(text) ?? text))
                    .font(code).lineSpacing(3).textSelection(.enabled)
            case .sql:
                Text(Highlighter.sql(text))
                    .font(code).lineSpacing(3).textSelection(.enabled)
            case .jwt:
                if let jwt = JWT(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    SectionLabel(text: "Header")
                    Text(Highlighter.json(Transforms.prettyJSON(jwt.header) ?? jwt.header)).font(code)
                    SectionLabel(text: "Payload").padding(.top, 4)
                    Text(Highlighter.json(Transforms.prettyJSON(jwt.payload) ?? jwt.payload))
                        .font(code).lineSpacing(3).textSelection(.enabled)
                }
            case .link:
                Text(text).font(code).foregroundStyle(Theme.accent).textSelection(.enabled)
            default:
                Text(String(text.prefix(8000)))
                    .font(code)
                    .foregroundStyle(Theme.foreground)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
    }

    private func details(_ item: ClipItem) -> [(String, String)] {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            let type = Detector.type(of: item)
            var rows = [("Type", item.isSnippet ? "Snippet · \(type.rawValue)" : type.rawValue)]
            switch type {
            case .json:
                if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                    if let dict = obj as? [String: Any] { rows.append(("Structure", "Object · \(dict.count) keys")) }
                    if let array = obj as? [Any] { rows.append(("Structure", "Array · \(array.count) items")) }
                }
            case .sql:
                let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0.isWhitespace }).first.map { $0.uppercased() } ?? ""
                rows.append(("Statement", word))
            case .jwt:
                if let jwt = JWT(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    rows.append(("Algorithm", jwt.algorithm ?? "—"))
                    if let iat = jwt.date("iat") {
                        rows.append(("Issued", iat.formatted(date: .abbreviated, time: .shortened)))
                    }
                    if let exp = jwt.date("exp") {
                        let rel = exp.formatted(.relative(presentation: .named))
                        rows.append(("Expires", exp < Date() ? "Expired \(rel)" : rel))
                    }
                }
            case .uuid:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let version = t.count > 14 ? String(t[t.index(t.startIndex, offsetBy: 14)]) : "?"
                rows.append(("Version", "v\(version)"))
            default:
                break
            }
            if item.richType != nil {
                rows.append(("Format", item.richType == NSPasteboard.PasteboardType.html.rawValue ? "Rich text (HTML)" : "Rich text (RTF)"))
            }
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            rows.append(("Size", "\(plural(text.count, "char")) · \(plural(words, "word")) · \(plural(lines, "line"))"))
            return rows
        case .image:
            var rows = [("Type", "Image")]
            if let rep = store.image(for: item)?.representations.first {
                rows.append(("Dimensions", "\(rep.pixelsWide) × \(rep.pixelsHigh)"))
            }
            if let bytes = store.imageData(for: item)?.count {
                rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
            return rows
        case .file:
            let count = (item.text ?? "").split(separator: "\n").count
            return [("Type", count == 1 ? "File" : "Files"), ("Count", "\(count)")]
        }
    }
}

/// Title + body editor for a snippet; every keystroke is saved.
private struct SnippetEditor: View {
    let id: UUID
    @ObservedObject var store: ClipStore
    var focus: FocusState<PanelFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: binding(\.title), prompt: Text("Snippet name").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.foreground)
                .focused(focus, equals: .snippetTitle)
            Rectangle().fill(Theme.border).frame(height: 1)
            TextEditor(text: binding(\.text))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.foreground)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused(focus, equals: .snippetBody)
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(Theme.background.opacity(0.35))
    }

    private func binding(_ keyPath: KeyPath<ClipItem, String?>) -> Binding<String> {
        Binding(
            get: { store.items.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                if keyPath == \ClipItem.title {
                    store.updateSnippet(id, title: value)
                } else {
                    store.updateSnippet(id, text: value)
                }
            }
        )
    }
}

private func plural(_ n: Int, _ word: String) -> String {
    "\(n.formatted()) \(word)\(n == 1 ? "" : "s")"
}

private struct MetaRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            value.foregroundStyle(Theme.foreground).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Empty

private struct EmptyState: View {
    let filter: ClipFilter
    let hasItems: Bool
    let newSnippet: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.borderStrong, lineWidth: 1))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.foreground)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if filter == .snippets {
                Button("New Snippet  ⌘N", action: newSnippet)
                    .buttonStyle(PillButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(24)
    }

    private var symbol: String {
        filter == .snippets ? "bookmark" : hasItems ? "magnifyingglass" : "doc.on.clipboard"
    }

    private var title: String {
        filter == .snippets ? "No snippets yet" : hasItems ? "No results found" : "Nothing copied yet"
    }

    private var subtitle: String {
        if filter == .snippets { return "Save text you reuse often.\nSelect an item and press ⌘S." }
        return hasItems ? "Try a different search or filter." : "Copy anything and it will show up here."
    }
}
