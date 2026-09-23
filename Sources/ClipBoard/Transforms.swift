import Foundation

/// A text → text conversion offered in the ⌘K actions menu.
/// `apply` returns nil when the transform doesn't fit the text.
struct TextTransform {
    let id: String
    let title: String
    let symbol: String
    let apply: (String) -> String?
}

enum Transforms {
    /// Transforms that apply to `text`, each with its result (shown as a preview).
    static func available(for text: String, type: ContentType) -> [(transform: TextTransform, result: String)] {
        guard text.utf8.count <= 500_000 else { return [] }
        // Case and line tools make no sense on structured data like JSON.
        let skipped: Set<String>
        switch type {
        case .json, .jwt: skipped = ["case.upper", "case.lower", "case.title", "case.camel", "case.snake",
                                     "case.kebab", "lines.sort", "lines.dedupe", "lines.join", "sql.in"]
        case .sql: skipped = ["case.title", "case.camel", "case.snake", "case.kebab", "sql.in"]
        case .link, .email, .uuid: skipped = ["case.title", "case.camel", "case.snake", "case.kebab"]
        default: skipped = []
        }
        return all.filter { !skipped.contains($0.id) }.compactMap { t in
            guard let result = t.apply(text), !result.isEmpty, result != text else { return nil }
            return (t, result)
        }
    }

    static let generators: [TextTransform] = [
        TextTransform(id: "gen.uuid", title: "Generate UUID", symbol: "number") { _ in
            UUID().uuidString.lowercased()
        },
        TextTransform(id: "gen.unix", title: "Current Unix Timestamp", symbol: "clock") { _ in
            String(Int(Date().timeIntervalSince1970))
        },
        TextTransform(id: "gen.iso", title: "Current Date (ISO 8601)", symbol: "calendar") { _ in
            ISO8601DateFormatter().string(from: Date())
        },
    ]

    static let all: [TextTransform] = [
        TextTransform(id: "json.format", title: "Format JSON", symbol: "curlybraces") { prettyJSON($0) },
        TextTransform(id: "json.minify", title: "Minify JSON", symbol: "arrow.down.right.and.arrow.up.left") {
            minifyJSON($0)
        },
        TextTransform(id: "jwt.decode", title: "Decode JWT Payload", symbol: "key") { text in
            JWT(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { prettyJSON($0.payload) }
        },
        TextTransform(id: "sql.format", title: "Format SQL", symbol: "cylinder.split.1x2") { text in
            Detector.isSQL(text) ? formatSQL(text) : nil
        },
        TextTransform(id: "sql.in", title: "Make SQL IN List", symbol: "list.bullet") { sqlInList($0) },

        TextTransform(id: "case.upper", title: "UPPERCASE", symbol: "textformat.size.larger") { $0.uppercased() },
        TextTransform(id: "case.lower", title: "lowercase", symbol: "textformat.size.smaller") { $0.lowercased() },
        TextTransform(id: "case.title", title: "Title Case", symbol: "textformat") { text in
            isShortLine(text) ? text.capitalized : nil
        },
        TextTransform(id: "case.camel", title: "camelCase", symbol: "character.cursor.ibeam") { text in
            guard isShortLine(text) else { return nil }
            let w = words(text)
            guard w.count > 1 else { return nil }
            return w[0].lowercased() + w.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        },
        TextTransform(id: "case.snake", title: "snake_case", symbol: "character.cursor.ibeam") { text in
            guard isShortLine(text), words(text).count > 1 else { return nil }
            return words(text).map { $0.lowercased() }.joined(separator: "_")
        },
        TextTransform(id: "case.kebab", title: "kebab-case", symbol: "character.cursor.ibeam") { text in
            guard isShortLine(text), words(text).count > 1 else { return nil }
            return words(text).map { $0.lowercased() }.joined(separator: "-")
        },

        TextTransform(id: "ws.trim", title: "Trim Whitespace", symbol: "scissors") {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        },
        TextTransform(id: "lines.join", title: "Join Lines", symbol: "arrow.right.to.line") { text in
            let lines = nonEmptyLines(text)
            return lines.count > 1 ? lines.joined(separator: " ") : nil
        },
        TextTransform(id: "lines.sort", title: "Sort Lines", symbol: "arrow.up.arrow.down") { text in
            let lines = text.components(separatedBy: .newlines)
            return lines.count > 1 ? lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n") : nil
        },
        TextTransform(id: "lines.dedupe", title: "Remove Duplicate Lines", symbol: "line.3.horizontal.decrease") { text in
            var seen = Set<String>()
            let lines = text.components(separatedBy: .newlines).filter { seen.insert($0).inserted }
            return lines.joined(separator: "\n")
        },

        TextTransform(id: "url.encode", title: "URL Encode", symbol: "percent") { text in
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+?#/:")
            return text.addingPercentEncoding(withAllowedCharacters: allowed)
        },
        TextTransform(id: "url.decode", title: "URL Decode", symbol: "percent") { text in
            text.contains("%") ? text.removingPercentEncoding : nil
        },
        TextTransform(id: "b64.encode", title: "Base64 Encode", symbol: "lock") { text in
            text.utf8.count <= 100_000 ? Data(text.utf8).base64EncodedString() : nil
        },
        TextTransform(id: "b64.decode", title: "Base64 Decode", symbol: "lock.open") { text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 8, Detector.matches(t, #"^[A-Za-z0-9+/_-]+={0,2}$"#),
                  let decoded = JWT.decode(t),
                  !decoded.unicodeScalars.contains(where: { $0.value < 32 && !"\n\r\t".unicodeScalars.contains($0) })
            else { return nil }
            return decoded
        },
    ]

    // MARK: - JSON

    /// Re-indents JSON without re-parsing it, so key order is kept exactly as copied.
    static func prettyJSON(_ text: String) -> String? {
        guard Detector.isJSON(text) else { return nil }
        var out = ""
        var indent = 0
        var inString = false, escaped = false
        func newline() { out += "\n" + String(repeating: "  ", count: indent) }
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "{", "[": out.append(ch); indent += 1; newline()
            case "}", "]": indent -= 1; newline(); out.append(ch)
            case ",": out.append(ch); newline()
            case ":": out += ": "
            case " ", "\n", "\t", "\r": break
            default: out.append(ch)
            }
        }
        // Collapse empty objects/arrays: "{\n  }" → "{}". Raw newlines can't occur inside JSON strings.
        return out.replacingOccurrences(of: #"([\[{])\n\s*([\]}])"#, with: "$1$2", options: .regularExpression)
    }

    static func minifyJSON(_ text: String) -> String? {
        guard Detector.isJSON(text) else { return nil }
        var out = ""
        var inString = false, escaped = false
        for ch in text {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
                out.append(ch)
            } else if !ch.isWhitespace {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - SQL

    static let sqlKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "FULL", "CROSS", "GROUP", "ORDER", "BY", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX",
        "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "EXISTS", "BETWEEN", "LIKE", "ILIKE", "ASC", "DESC",
        "WITH", "RETURNING", "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "TRUE", "FALSE", "PRIMARY", "KEY",
        "REFERENCES", "DEFAULT", "TRUNCATE", "EXPLAIN", "CAST", "INTERVAL", "USING", "ANY", "LATERAL", "FILTER",
    ]

    /// Uppercases keywords and puts each clause on its own line.
    static func formatSQL(_ text: String) -> String {
        let clauseStarts: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
                                         "UNION", "INSERT", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING",
                                         "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "JOIN"]
        let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS"]
        let pattern = #"--[^\n]*|/\*[\s\S]*?\*/|'(?:''|[^'])*'|"[^"]*"|[A-Za-z_][A-Za-z0-9_]*|\s+|."#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var previousWord = ""
        var inBetween = false
        var parenDepth = 0

        func lineBreak(indent: String = "") {
            while out.last == " " { out.removeLast() }
            if !out.isEmpty { out += "\n" + indent }
        }

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            if token.allSatisfy(\.isWhitespace) {
                if !out.isEmpty, out.last != " ", out.last != "\n", out.last != "(" { out += " " }
                continue
            }
            if token.hasPrefix("--") {
                out += token
                lineBreak()
                continue
            }
            let upper = token.uppercased()
            let isWord = token.first.map { $0.isLetter || $0 == "_" } ?? false
            if isWord, sqlKeywords.contains(upper) {
                if parenDepth == 0 {
                    if clauseStarts.contains(upper), !(upper == "JOIN" && joinModifiers.contains(previousWord)) {
                        lineBreak()
                    } else if upper == "AND" || upper == "OR", !inBetween {
                        lineBreak(indent: "  ")
                    }
                }
                if upper == "BETWEEN" { inBetween = true } else if upper == "AND" { inBetween = false }
                out += upper
                previousWord = upper
            } else {
                if token == "(" { parenDepth += 1 }
                if token == ")" { parenDepth = max(0, parenDepth - 1); while out.last == " " { out.removeLast() } }
                if token == "," || token == ";" { while out.last == " " { out.removeLast() } }
                out += token
                if isWord { previousWord = upper }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "a\nb\nc" → "('a', 'b', 'c')"; numbers stay unquoted.
    static func sqlInList(_ text: String) -> String? {
        guard !Detector.isSQL(text), !Detector.isJSON(text) else { return nil }
        let values = text.components(separatedBy: CharacterSet(charactersIn: "\n\r\t,"))
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'\""))) }
            .filter { !$0.isEmpty }
        guard values.count >= 2, values.count <= 50_000 else { return nil }
        let allNumbers = values.allSatisfy { Double($0) != nil }
        let items = values.map { allNumbers ? $0 : "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        return "(" + items.joined(separator: ", ") + ")"
    }

    // MARK: - Helpers

    private static func isShortLine(_ text: String) -> Bool {
        text.count <= 200 && !text.contains("\n")
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Splits "someHTTPValue_here-too" into words for case conversion.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if let p = previous, ch.isUppercase, p.isLowercase || p.isNumber, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
            previous = ch
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
