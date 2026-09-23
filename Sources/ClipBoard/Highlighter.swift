import SwiftUI

/// Minimal syntax coloring for the preview pane.
enum Highlighter {
    private static let limit = 30_000

    static func json(_ text: String) -> AttributedString {
        // 1: string, 2: the colon that makes it a key, 3: number, 4: literal, 5: punctuation
        let pattern = #"("(?:\\.|[^"\\])*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}\[\],:])"#
        return highlight(text, pattern: pattern) { match, ns in
            if match.range(at: 1).location != NSNotFound {
                return match.range(at: 2).location != NSNotFound ? Theme.synKey : Theme.synString
            }
            if match.range(at: 3).location != NSNotFound { return Theme.synNumber }
            if match.range(at: 4).location != NSNotFound { return Theme.synKeyword }
            return Theme.muted
        }
    }

    static func sql(_ text: String) -> AttributedString {
        // 1: comment, 2: string, 3: quoted identifier, 4: number, 5: word
        let pattern = #"(--[^\n]*|/\*[\s\S]*?\*/)|('(?:''|[^'])*')|("[^"]*")|\b(\d+(?:\.\d+)?)\b|([A-Za-z_][A-Za-z0-9_]*)"#
        return highlight(text, pattern: pattern) { match, ns in
            if match.range(at: 1).location != NSNotFound { return Theme.faint }
            if match.range(at: 2).location != NSNotFound { return Theme.synString }
            if match.range(at: 3).location != NSNotFound { return Theme.synKey }
            if match.range(at: 4).location != NSNotFound { return Theme.synNumber }
            let word = ns.substring(with: match.range(at: 5)).uppercased()
            return Transforms.sqlKeywords.contains(word) ? Theme.synKeyword : nil
        }
    }

    /// Walks the regex matches and stitches plain and colored runs together.
    private static func highlight(_ full: String, pattern: String,
                                  color: (NSTextCheckingResult, NSString) -> Color?) -> AttributedString {
        let text = String(full.prefix(limit))
        var plain = AttributedString(text)
        plain.foregroundColor = Theme.foreground
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return plain }

        let ns = text as NSString
        var result = AttributedString()
        var cursor = 0
        func append(_ range: NSRange, _ c: Color) {
            var run = AttributedString(ns.substring(with: range))
            run.foregroundColor = c
            result += run
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let c = color(match, ns) else { continue }
            if match.range.location > cursor {
                append(NSRange(location: cursor, length: match.range.location - cursor), Theme.foreground)
            }
            append(match.range, c)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            append(NSRange(location: cursor, length: ns.length - cursor), Theme.foreground)
        }
        return result
    }
}
