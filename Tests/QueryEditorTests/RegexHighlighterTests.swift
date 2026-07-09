import AppKit
import DBCore
import Testing

@testable import QueryEditor

@Suite struct RegexHighlighterTests {
    /// Colors applied to `text`, keyed by the exact substring.
    private func colors(
        _ text: String, language: DriverDescriptor.QueryLanguage
    ) -> [(substring: String, color: NSColor)] {
        let storage = NSTextStorage(string: text)
        RegexHighlighter(language: language).highlight(storage)
        var result: [(String, NSColor)] = []
        storage.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let substring = (storage.string as NSString).substring(with: range)
            result.append((substring, color))
        }
        return result
    }

    private func color(
        of substring: String, in text: String,
        language: DriverDescriptor.QueryLanguage
    ) -> NSColor? {
        colors(text, language: language).first { $0.substring == substring }?.color
    }

    @Test func sqlTokens() {
        let sql = "SELECT id FROM users WHERE name = 'a''b' -- trailing\nLIMIT 10"
        #expect(color(of: "SELECT", in: sql, language: .sql) == .systemBlue)
        // Plain identifiers stay label-colored (runs merge with whitespace).
        #expect(colors(sql, language: .sql).contains {
            $0.substring.contains("id") && $0.color == .labelColor
        })
        #expect(color(of: "'a''b'", in: sql, language: .sql) == .systemRed)
        #expect(color(of: "-- trailing", in: sql, language: .sql) == .systemGray)
        #expect(color(of: "10", in: sql, language: .sql) == .systemPurple)
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        let sql = "select * from t"
        #expect(color(of: "select", in: sql, language: .sql) == .systemBlue)
        #expect(color(of: "from", in: sql, language: .sql) == .systemBlue)
    }

    @Test func blockCommentsSpanLines() {
        let sql = "SELECT /* multi\nline */ 1"
        #expect(color(of: "/* multi\nline */", in: sql, language: .sql) == .systemGray)
    }

    @Test func mongoTokens() {
        let query = #"db.users.find({"status": "active", "n": 5, "ok": true})"#
        #expect(color(of: "db", in: query, language: .mongo) == .systemBlue)
        #expect(color(of: "find", in: query, language: .mongo) == .systemBlue)
        #expect(color(of: #""active""#, in: query, language: .mongo) == .systemRed)
        #expect(color(of: "5", in: query, language: .mongo) == .systemPurple)
        #expect(color(of: "true", in: query, language: .mongo) == .systemOrange)
    }

    @Test func mongoOperatorsHighlighted() {
        // Unquoted $-operators get the operator color; quoted ones read as
        // strings (string rule applies last), which is the intended precedence.
        let unquoted = "{$match: {}}"
        #expect(color(of: "$match", in: unquoted, language: .mongo) == .systemTeal)
        let quoted = #"{"$match": {}}"#
        #expect(color(of: #""$match""#, in: quoted, language: .mongo) == .systemRed)
    }

    @Test func redisCommandHighlighted() {
        let command = #"SET greeting "hello world""#
        #expect(color(of: "SET", in: command, language: .redis) == .systemBlue)
        #expect(color(of: #""hello world""#, in: command, language: .redis) == .systemRed)
    }

    @Test func rehighlightResetsStaleColors() {
        let storage = NSTextStorage(string: "SELECT 1")
        let highlighter = RegexHighlighter(language: .sql)
        highlighter.highlight(storage)
        storage.replaceCharacters(in: NSRange(location: 0, length: 6), with: "plain0")
        highlighter.highlight(storage)
        // "SELECT" is gone; nothing may keep the stale keyword color.
        var stale = false
        storage.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let color = value as? NSColor, color == .systemBlue { stale = true }
        }
        #expect(!stale)
    }
}
