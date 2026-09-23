import AppKit
import CryptoKit
import Foundation

enum ClipKind: String, Codable {
    case text, image, file
}

enum ClipFilter: String, CaseIterable {
    case all = "All", text = "Text", links = "Links", images = "Images", files = "Files", snippets = "Snippets"

    func matches(_ item: ClipItem) -> Bool {
        if self == .snippets { return item.isSnippet }
        if item.isSnippet { return false }
        switch self {
        case .all, .snippets: return true
        case .text: return item.kind == .text && !item.isLink
        case .links: return item.isLink
        case .images: return item.kind == .image
        case .files: return item.kind == .file
        }
    }
}

struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    /// Text content, or newline-separated file paths for `.file`.
    var text: String?
    /// File name (inside the images folder) for `.image`.
    var imageFile: String?
    /// Used to detect duplicates: the text, the paths, or a hash of the image.
    var signature: String
    var date = Date()
    var pinned = false
    var sourceApp: String?
    var sourceBundleID: String?
    /// Snippets are saved texts kept apart from the history. Optional so older history files still load.
    var snippet: Bool?
    var title: String?
    /// Formatted version of the text (RTF or HTML) stored next to the history.
    var richFile: String?
    var richType: String?

    var isSnippet: Bool { snippet == true }

    var displayTitle: String {
        guard isSnippet else { return preview }
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled snippet" : t
    }

    var isLink: Bool {
        guard kind == .text, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.contains(where: \.isWhitespace), let url = URL(string: t) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// The color for text like "#0285f7", so it can be shown as a swatch.
    var color: NSColor? {
        guard kind == .text, var hex = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var preview: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let oneLine = t.replacingOccurrences(of: "\n", with: " ⏎ ")
            return String(oneLine.prefix(300))
        case .file:
            let paths = (text ?? "").split(separator: "\n")
            let names = paths.map { URL(fileURLWithPath: String($0)).lastPathComponent }
            return names.joined(separator: ", ")
        case .image:
            return "Image"
        }
    }
}

/// Holds the clipboard history and saves it to ~/Library/Application Support/ClipBoard.
/// (The folder keeps its original name so existing history carries over after the rename to Wisp.)
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    @Published private(set) var items: [ClipItem] = []

    var maxItems = 300

    let folder: URL
    let imagesFolder: URL
    let richFolder: URL
    private let historyFile: URL
    private var imageCache: [String: NSImage] = [:]
    private var saveWork: DispatchWorkItem?

    struct Source {
        var name: String?
        var bundleID: String?
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("ClipBoard", isDirectory: true)
        imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
        richFolder = folder.appendingPathComponent("rich", isDirectory: true)
        historyFile = folder.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: richFolder, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Adding

    struct RichText {
        var data: Data
        var type: NSPasteboard.PasteboardType
    }

    func addText(_ text: String, rich: RichText? = nil, source: Source) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let signature = "t:" + text
        // Reuse the id of an earlier identical copy so the formatting file name stays stable.
        let id = items.first { $0.signature == signature }?.id ?? UUID()
        var item = ClipItem(id: id, kind: .text, text: text, signature: signature,
                            sourceApp: source.name, sourceBundleID: source.bundleID)
        let richURL = richFolder.appendingPathComponent(id.uuidString)
        if let rich {
            try? rich.data.write(to: richURL)
            item.richFile = id.uuidString
            item.richType = rich.type.rawValue
        } else {
            try? FileManager.default.removeItem(at: richURL)
        }
        insert(item)
    }

    func richData(for item: ClipItem) -> RichText? {
        guard let name = item.richFile, let type = item.richType,
              let data = try? Data(contentsOf: richFolder.appendingPathComponent(name)) else { return nil }
        return RichText(data: data, type: NSPasteboard.PasteboardType(type))
    }

    // MARK: - Snippets

    @discardableResult
    func addSnippet(title: String, text: String) -> ClipItem {
        let id = UUID()
        let item = ClipItem(id: id, kind: .text, text: text, signature: "s:" + id.uuidString, snippet: true, title: title)
        items.insert(item, at: 0)
        scheduleSave()
        return item
    }

    func updateSnippet(_ id: UUID, title: String? = nil, text: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[i].title = title }
        if let text { items[i].text = text }
        scheduleSave()
    }

    func addFiles(_ urls: [URL], source: Source) {
        let paths = urls.map(\.path).joined(separator: "\n")
        insert(ClipItem(kind: .file, text: paths, signature: "f:" + paths,
                        sourceApp: source.name, sourceBundleID: source.bundleID))
    }

    func addImage(pngData: Data, source: Source) {
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        let signature = "i:" + hash
        if items.contains(where: { $0.signature == signature }) {
            insert(ClipItem(kind: .image, imageFile: hash + ".png", signature: signature,
                        sourceApp: source.name, sourceBundleID: source.bundleID))
            return
        }
        let name = hash + ".png"
        try? pngData.write(to: imagesFolder.appendingPathComponent(name))
        insert(ClipItem(kind: .image, imageFile: name, signature: signature,
                        sourceApp: source.name, sourceBundleID: source.bundleID))
    }

    private func insert(_ item: ClipItem) {
        var item = item
        // Copying the same thing again moves it to the top instead of duplicating it.
        if let existing = items.firstIndex(where: { $0.signature == item.signature }) {
            item.pinned = items[existing].pinned
            item.id = items[existing].id
            items.remove(at: existing)
        }
        items.insert(item, at: 0)
        trim()
        scheduleSave()
    }

    private func trim() {
        var unpinnedCount = 0
        var removed: [ClipItem] = []
        items.removeAll { item in
            guard !item.pinned, !item.isSnippet else { return false }
            unpinnedCount += 1
            if unpinnedCount > maxItems {
                removed.append(item)
                return true
            }
            return false
        }
        removed.forEach(deleteFiles)
    }

    // MARK: - Editing

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        scheduleSave()
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        deleteFiles(item)
        scheduleSave()
    }

    /// Removes everything except pinned items and snippets.
    func clearUnpinned() {
        let keep: (ClipItem) -> Bool = { $0.pinned || $0.isSnippet }
        let removed = items.filter { !keep($0) }
        items.removeAll { !keep($0) }
        removed.forEach(deleteFiles)
        scheduleSave()
    }

    func filtered(_ query: String, filter: ClipFilter = .all) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Snippets live in their own tab, but also show up when searching from "All".
        let base = items.filter { filter.matches($0) || (filter == .all && !q.isEmpty && $0.isSnippet) }.filter { item in
            q.isEmpty ||
            (item.text ?? "").localizedCaseInsensitiveContains(q)
                || (item.title ?? "").localizedCaseInsensitiveContains(q)
                || (item.sourceApp ?? "").localizedCaseInsensitiveContains(q)
                || (item.kind == .image && "image".localizedCaseInsensitiveContains(q))
        }
        // Pinned items first, then newest first.
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    // MARK: - Images

    func image(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFile else { return nil }
        if let cached = imageCache[name] { return cached }
        let image = NSImage(contentsOf: imagesFolder.appendingPathComponent(name))
        imageCache[name] = image
        return image
    }

    func imageData(for item: ClipItem) -> Data? {
        guard let name = item.imageFile else { return nil }
        return try? Data(contentsOf: imagesFolder.appendingPathComponent(name))
    }

    private func deleteFiles(_ item: ClipItem) {
        if let rich = item.richFile, !items.contains(where: { $0.richFile == rich }) {
            try? FileManager.default.removeItem(at: richFolder.appendingPathComponent(rich))
        }
        guard let name = item.imageFile, !items.contains(where: { $0.imageFile == name }) else { return }
        imageCache[name] = nil
        try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(name))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: historyFile),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = decoded
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: historyFile, options: .atomic)
    }
}
