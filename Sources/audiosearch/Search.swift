import Foundation
import GRDB

/// How the user's words are translated into an FTS5 expression (plan Section 9).
enum MatchMode: Equatable {
    /// Default. Adjacent words, in order: `"term1 term2"`.
    case phrase
    case any
    case all
    case near(Int)
    case prefix
    /// The user string reaches FTS5 untouched. The escape hatch, and the only
    /// mode that can raise a query syntax error.
    case raw
}

/// One ranked match.
struct SearchHit: Equatable {
    let path: String
    let t0MS: Int
    let t1MS: Int
    /// Full segment text.
    let text: String
    /// FTS5-generated excerpt with matched terms bracketed.
    let snippet: String
    /// BM25; more negative is a better match.
    let score: Double
}

enum Search {

    // MARK: - Query translation

    /// Splits user input into searchable tokens.
    ///
    /// Sanitization is mandatory, not defensive: FTS5 owns `-`, `*`, `:`, `^` and
    /// `"` as operators, so passing raw input through turns a query like
    /// `foo -bar` into a parse error rather than zero results. Anything that is
    /// not a letter or a digit is a separator here, which means adversarial input
    /// degrades to fewer tokens — never to a syntax error. Apostrophes are kept
    /// inside words so `don't` survives to the tokenizer, which splits it the same
    /// way it split the indexed text.
    static func tokenize(_ input: String) -> [String] {
        input
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { token in token.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Wraps a token as an FTS5 string literal. Double quotes are doubled per FTS5
    /// literal rules; tokenization already removes them, so this is belt and braces.
    static func quote(_ token: String) -> String {
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Translates user input into an FTS5 `MATCH` expression.
    ///
    /// Returns `nil` when nothing searchable survives tokenization (`*`, `^`, an
    /// empty string). A `nil` query means zero matches and exit code 1, which is
    /// the correct answer — not a usage error.
    static func translate(_ input: [String], mode: MatchMode) -> String? {
        let joined = input.joined(separator: " ")

        if case .raw = mode {
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let tokens = tokenize(joined)
        guard !tokens.isEmpty else { return nil }

        switch mode {
        case .phrase:
            // One quoted string containing every token is an FTS5 phrase: the
            // tokens must appear adjacently and in order.
            return quote(tokens.joined(separator: " "))
        case .any:
            return tokens.map(quote).joined(separator: " OR ")
        case .all:
            return tokens.map(quote).joined(separator: " AND ")
        case .near(let distance):
            return "NEAR(" + tokens.map(quote).joined(separator: " ") + ", \(distance))"
        case .prefix:
            // Each token matches as a prefix; multiple tokens are ANDed.
            return tokens.map { quote($0) + "*" }.joined(separator: " AND ")
        case .raw:
            preconditionFailure("handled above")
        }
    }

    // MARK: - Execution

    struct Options {
        var mode: MatchMode = .phrase
        /// Substring the file path must contain; case-insensitive.
        var pathFilter: String?
        /// Zero means unlimited.
        var limit: Int = 20
    }

    static func run(_ store: Store, query terms: [String], options: Options) throws -> [SearchHit] {
        guard let expression = translate(terms, mode: options.mode) else { return [] }

        var sql = """
            SELECT f.path       AS path,
                   s.t0_ms      AS t0_ms,
                   s.t1_ms      AS t1_ms,
                   s.text       AS text,
                   snippet(segments_fts, 0, '[', ']', '...', 12) AS snip,
                   bm25(segments_fts) AS score
            FROM segments_fts
            JOIN segments s ON s.id = segments_fts.rowid
            JOIN files    f ON f.id = s.file_id
            WHERE segments_fts MATCH ?
            """
        var arguments: [DatabaseValueConvertible] = [expression]

        if let filter = options.pathFilter, !filter.isEmpty {
            sql += "\n  AND f.path LIKE ? ESCAPE '\\'"
            arguments.append("%" + escapingLikeWildcards(filter) + "%")
        }

        // bm25 returns negative scores, best match most negative, so ascending is
        // best-first. Path and offset break ties so output is reproducible.
        sql += "\nORDER BY score, path, t0_ms"

        if options.limit > 0 {
            sql += "\nLIMIT ?"
            arguments.append(options.limit)
        }

        do {
            return try store.queue.read { db in
                try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                    SearchHit(
                        path: row["path"],
                        t0MS: row["t0_ms"],
                        t1MS: row["t1_ms"],
                        text: row["text"],
                        snippet: row["snip"],
                        score: row["score"]
                    )
                }
            }
        } catch let error as DatabaseError {
            // Only `--raw` can get here: every other mode emits a well-formed
            // expression by construction.
            throw AudiosearchError.usage(
                "unparseable query: \(error.message ?? "FTS5 syntax error") (\(expression))"
            )
        }
    }

    private static func escapingLikeWildcards(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
