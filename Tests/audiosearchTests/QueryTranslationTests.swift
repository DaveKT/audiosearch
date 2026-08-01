import Foundation
import Testing

@testable import audiosearch

/// Plan Section 13.3: table-driven cases over adversarial input, asserting no
/// error and correct FTS5 translation. FTS5 owns `-`, `*`, `:`, `^` and `"`, so
/// untranslated input produces a parse error rather than zero results.
@Suite("query translation")
struct QueryTranslationTests {

    struct Case {
        let input: [String]
        let mode: MatchMode
        let expected: String?
        let comment: String
    }

    static let cases: [Case] = [
        Case(input: ["software defined radio"], mode: .phrase,
             expected: "\"software defined radio\"",
             comment: "default is an adjacent, ordered phrase"),
        Case(input: ["corning", "glass", "museum"], mode: .all,
             expected: "\"corning\" AND \"glass\" AND \"museum\"",
             comment: "separate shell words are separate terms"),
        Case(input: ["antenna", "tuner"], mode: .any,
             expected: "\"antenna\" OR \"tuner\"",
             comment: "--any"),
        Case(input: ["antenna", "tuner"], mode: .near(10),
             expected: "NEAR(\"antenna\" \"tuner\", 10)",
             comment: "--near N"),
        Case(input: ["transcei"], mode: .prefix,
             expected: "\"transcei\"*",
             comment: "--prefix"),
        Case(input: ["trans", "recv"], mode: .prefix,
             expected: "\"trans\"* AND \"recv\"*",
             comment: "every token is prefixed, and they are ANDed"),

        // Adversarial input. None of these may raise; each degrades to literal terms.
        Case(input: ["foo -bar \"baz"], mode: .phrase,
             expected: "\"foo bar baz\"",
             comment: "unbalanced quote and leading hyphen become literal terms"),
        Case(input: ["a:b"], mode: .phrase,
             expected: "\"a b\"",
             comment: "colon is a column filter in FTS5; neutralized"),
        Case(input: ["*"], mode: .phrase,
             expected: nil,
             comment: "nothing searchable survives; zero matches, not an error"),
        Case(input: ["^x"], mode: .phrase,
             expected: "\"x\"",
             comment: "caret anchors in FTS5; stripped"),
        Case(input: [""], mode: .phrase,
             expected: nil,
             comment: "empty string"),
        Case(input: ["   "], mode: .all,
             expected: nil,
             comment: "whitespace only"),
        Case(input: ["!!!", "???"], mode: .any,
             expected: nil,
             comment: "punctuation only"),
        Case(input: ["don't"], mode: .phrase,
             expected: "\"don't\"",
             comment: "apostrophes stay inside the word for the tokenizer to split"),
        Case(input: ["NEAR(a b, 2)"], mode: .all,
             expected: "\"NEAR\" AND \"a\" AND \"b\" AND \"2\"",
             comment: "FTS5 operator syntax typed by hand is literal without --raw"),
        Case(input: ["café", "señor"], mode: .all,
             expected: "\"café\" AND \"señor\"",
             comment: "non-ASCII letters are ordinary characters"),
        Case(input: ["OR", "AND"], mode: .all,
             expected: "\"OR\" AND \"AND\"",
             comment: "quoting keeps FTS5 keywords from being read as operators"),

        // --raw is the documented escape hatch: through untouched.
        Case(input: ["antenna OR tuner"], mode: .raw,
             expected: "antenna OR tuner",
             comment: "--raw passes through"),
        Case(input: ["  "], mode: .raw,
             expected: nil,
             comment: "--raw with nothing in it is still zero matches"),
    ]

    @Test("translates every case without raising", arguments: cases)
    func translates(testCase: Case) {
        #expect(
            Search.translate(testCase.input, mode: testCase.mode) == testCase.expected,
            "\(testCase.comment): \(testCase.input)"
        )
    }

    @Test("tokenizer keeps letters and digits and drops everything else")
    func tokenizer() {
        #expect(Search.tokenize("ft-8 radio, 2m band!") == ["ft", "8", "radio", "2m", "band"])
        #expect(Search.tokenize("").isEmpty)
        #expect(Search.tokenize("---***").isEmpty)
    }

    @Test("embedded double quotes are doubled, per FTS5 string literal rules")
    func quoting() {
        #expect(Search.quote("plain") == "\"plain\"")
        #expect(Search.quote("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }
}

extension QueryTranslationTests.Case: CustomTestStringConvertible {
    var testDescription: String { comment }
}
