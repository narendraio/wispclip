import Foundation

/// What a text item looks like, so it can get a matching icon, preview, and actions.
enum ContentType: String {
    case text = "Text", link = "Link", color = "Color", email = "Email"
    case json = "JSON", sql = "SQL", uuid = "UUID", jwt = "JWT"

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .color: return "paintpalette"
        case .email: return "envelope"
        case .json: return "curlybraces"
        case .sql: return "cylinder.split.1x2"
        case .uuid: return "number"
        case .jwt: return "key"
        }
    }
}

enum Detector {
    private static var cache: [String: ContentType] = [:]

    static func type(of item: ClipItem) -> ContentType {
        guard item.kind == .text, let text = item.text else { return .text }
        let key = "\(item.id)|\(text.count)|\(text.hashValue)"
        if let cached = cache[key] { return cached }
        let type = detect(text, item: item)
        cache[key] = type
        return type
    }

    private static func detect(_ raw: String, item: ClipItem) -> ContentType {
        if item.color != nil { return .color }
        if item.isLink { return .link }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(text, #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#) { return .uuid }
        if matches(text, #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#) { return .email }
        if JWT(text) != nil { return .jwt }
        if isJSON(text) { return .json }
        if isSQL(text) { return .sql }
        return .text
    }

    static func isJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, let last = t.last, t.utf8.count < 2_000_000,
              (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }

    static func isSQL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count < 200_000 else { return false }
        let statement = #"^(--[^\n]*\n\s*)*(select|insert\s+into|update|delete\s+from|with\s+\w+\s+as|create|alter|drop|truncate|explain)\b"#
        if matches(t, statement, caseInsensitive: true) { return true }
        // Fragments like "where id = '…'" copied out of a longer query.
        let fragment = #"^(where|from|and|or|left\s+join|inner\s+join|join|order\s+by|group\s+by|having|values|set)\b"#
        return matches(t, fragment, caseInsensitive: true)
            && matches(t, #"(=|<>|!=|<|>|\bin\s*\(|\blike\b|\bis\s+(not\s+)?null\b)"#, caseInsensitive: true)
    }

    static func matches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }
}

/// A decoded JSON Web Token.
struct JWT {
    let header: String
    let payload: String
    let claims: [String: Any]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, text.count < 20_000, !text.contains(where: \.isWhitespace),
              let h = JWT.decode(parts[0]), let p = JWT.decode(parts[1]),
              let headerObj = (try? JSONSerialization.jsonObject(with: Data(h.utf8))) as? [String: Any],
              headerObj["alg"] != nil,
              let claims = (try? JSONSerialization.jsonObject(with: Data(p.utf8))) as? [String: Any]
        else { return nil }
        header = h
        payload = p
        self.claims = claims
    }

    var algorithm: String? {
        ((try? JSONSerialization.jsonObject(with: Data(header.utf8))) as? [String: Any])?["alg"] as? String
    }

    func date(_ claim: String) -> Date? {
        (claims[claim] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    static func decode<S: StringProtocol>(_ segment: S) -> String? {
        var s = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
