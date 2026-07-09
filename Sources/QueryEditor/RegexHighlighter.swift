import AppKit
import DBCore

/// Applies token colors via regular expressions. Colors are semantic system
/// colors, so light/dark mode both work. Deliberately simple: whole-document
/// rehighlight on change is fine at query sizes. Swappable for a tree-sitter
/// implementation behind the same interface later.
public final class RegexHighlighter {
    struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
    }

    let rules: [Rule]

    public init(language: DriverDescriptor.QueryLanguage) {
        var rules: [Rule] = []
        func add(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                rules.append(Rule(regex: regex, color: color))
            }
        }

        switch language {
        case .sql, .partiql:
            let keywords = [
                "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
                "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT",
                "INNER", "OUTER", "FULL", "CROSS", "ON", "AS", "GROUP", "BY",
                "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
                "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE", "ILIKE", "BETWEEN",
                "EXISTS", "ASC", "DESC", "WITH", "RECURSIVE", "RETURNING", "CAST",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "TRUE", "FALSE",
            ]
            add(#"\b(\#(keywords.joined(separator: "|")))\b"#, .systemBlue,
                options: [.caseInsensitive])
            add(#"\b\d+(\.\d+)?\b"#, .systemPurple)
            add(#"'(?:[^']|'')*'"#, .systemRed)
            add(#"--[^\n]*"#, .systemGray)
            add(#"/\*.*?\*/"#, .systemGray, options: [.dotMatchesLineSeparators])

        case .mongo:
            add(#"\b(db|find|aggregate|count|skip|limit|sort|project)\b"#, .systemBlue)
            add(#"\$[a-zA-Z]+\b"#, .systemTeal)
            add(#"\b\d+(\.\d+)?\b"#, .systemPurple)
            add(#""(?:[^"\\]|\\.)*""#, .systemRed)
            add(#"\b(true|false|null)\b"#, .systemOrange)

        case .redis:
            add(#"^\s*[A-Z]+\b"#, .systemBlue, options: [.anchorsMatchLines])
            add(#""(?:[^"\\]|\\.)*""#, .systemRed)
        }

        self.rules = rules
    }

    public func highlight(_ storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        for rule in rules {
            rule.regex.enumerateMatches(in: storage.string, range: fullRange) {
                match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: range)
            }
        }
        storage.endEditing()
    }
}
