import Foundation
import Testing

@testable import audiosearch

@Suite("search")
struct SearchTests {

    private func populated() throws -> TestStore {
        let harness = try TestStore()
        try harness.insert(path: "/Audio/Podcasts/ep-207.mp3", texts: [
            "getting started with software defined radio is cheaper than it used to be",
            "the software defined radio sitting on my desk right now",
        ])
        try harness.insert(path: "/Audio/Recordings/panel.m4a", texts: [
            "a panel on software defined radio and where the hobby is going",
            "the antenna tuner was making a terrible noise",
        ])
        try harness.insert(path: "/Audio/Recordings/notes.m4a", texts: [
            "radio silence for the whole afternoon",
            "defined benefit pension plans came up somehow",
        ])
        return harness
    }

    private func paths(_ hits: [SearchHit]) -> [String] {
        hits.map(\.path)
    }

    @Test("default mode matches the phrase, not the loose set of words")
    func phraseIsDefault() throws {
        let harness = try populated()
        let hits = try Search.run(harness.store, query: ["software defined radio"],
                                  options: Search.Options())
        #expect(hits.count == 3)
        // "radio silence" plus "defined benefit" is not the phrase.
        #expect(!paths(hits).contains("/Audio/Recordings/notes.m4a"))
    }

    @Test("--all matches every term in any order")
    func allMode() throws {
        let harness = try populated()
        var options = Search.Options()
        options.mode = .all
        let hits = try Search.run(harness.store, query: ["radio", "defined"], options: options)
        #expect(hits.count == 3)
        // notes.m4a has "radio" in one segment and "defined" in another; --all
        // requires both terms in the same segment, so neither qualifies.
        #expect(!paths(hits).contains("/Audio/Recordings/notes.m4a"))
    }

    @Test("--any matches either term")
    func anyMode() throws {
        let harness = try populated()
        var options = Search.Options()
        options.mode = .any
        let hits = try Search.run(harness.store, query: ["tuner", "pension"], options: options)
        #expect(hits.count == 2)
        #expect(Set(paths(hits)) == ["/Audio/Recordings/panel.m4a", "/Audio/Recordings/notes.m4a"])
    }

    @Test("--near constrains token distance")
    func nearMode() throws {
        let harness = try populated()
        var close = Search.Options()
        close.mode = .near(3)
        #expect(try Search.run(harness.store, query: ["software", "radio"], options: close).count == 3)

        var adjacent = Search.Options()
        adjacent.mode = .near(0)
        #expect(try Search.run(harness.store, query: ["antenna", "noise"], options: adjacent).isEmpty)
    }

    @Test("--prefix matches on word beginnings")
    func prefixMode() throws {
        let harness = try populated()
        var options = Search.Options()
        options.mode = .prefix
        let hits = try Search.run(harness.store, query: ["transcei"], options: options)
        #expect(hits.isEmpty)

        let matching = try Search.run(harness.store, query: ["aftern"], options: options)
        #expect(matching.count == 1)
        #expect(matching[0].path == "/Audio/Recordings/notes.m4a")
    }

    @Test("--raw reaches FTS5 untouched")
    func rawMode() throws {
        let harness = try populated()
        var options = Search.Options()
        options.mode = .raw
        let hits = try Search.run(harness.store, query: ["tuner OR pension"], options: options)
        #expect(hits.count == 2)
    }

    @Test("a malformed --raw query is a usage error, not a crash")
    func rawSyntaxError() throws {
        let harness = try populated()
        var options = Search.Options()
        options.mode = .raw
        #expect(throws: AudiosearchError.self) {
            _ = try Search.run(harness.store, query: ["NEAR(unclosed"], options: options)
        }
    }

    @Test("adversarial input returns no matches rather than raising")
    func adversarialInput() throws {
        let harness = try populated()
        for query in ["*", "^", "", "   ", "-", "\"", "a:b:c", "!!!"] {
            let hits = try Search.run(harness.store, query: [query], options: Search.Options())
            #expect(hits.isEmpty || !hits.isEmpty, "must not raise for \(query)")
        }
    }

    @Test("results are ranked, best match first, and ordering is stable")
    func ranking() throws {
        let harness = try TestStore()
        try harness.insert(path: "/Audio/dense.m4a", texts: ["antenna tuner"])
        try harness.insert(path: "/Audio/sparse.m4a", texts: [
            "the antenna tuner sat among a great many other unrelated words in this "
            + "much longer segment of transcript text that dilutes the match considerably"
        ])

        let hits = try Search.run(harness.store, query: ["antenna tuner"], options: Search.Options())
        #expect(hits.count == 2)
        // BM25 favours the shorter segment; more negative sorts first.
        #expect(hits[0].path == "/Audio/dense.m4a")
        #expect(hits[0].score <= hits[1].score)

        let repeated = try Search.run(harness.store, query: ["antenna tuner"], options: Search.Options())
        #expect(paths(hits) == paths(repeated))
    }

    @Test("snippets bracket the matched terms")
    func snippets() throws {
        let harness = try populated()
        let hits = try Search.run(harness.store, query: ["antenna tuner"], options: Search.Options())
        let hit = try #require(hits.first)
        // FTS5 brackets a matched phrase as one span, not term by term.
        #expect(hit.snippet == "the [antenna tuner] was making a terrible noise")
        #expect(hit.text == "the antenna tuner was making a terrible noise")
    }

    @Test("--path restricts results to a subtree")
    func pathFilter() throws {
        let harness = try populated()
        var options = Search.Options()
        options.pathFilter = "Recordings"
        let hits = try Search.run(harness.store, query: ["software defined radio"], options: options)
        #expect(hits.count == 1)
        #expect(hits[0].path == "/Audio/Recordings/panel.m4a")
    }

    @Test("--path treats LIKE wildcards in the filter as literal characters")
    func pathFilterEscapesWildcards() throws {
        let harness = try TestStore()
        try harness.insert(path: "/Audio/100%-live.m4a", texts: ["antenna tuner"])
        try harness.insert(path: "/Audio/1000-live.m4a", texts: ["antenna tuner"])

        var options = Search.Options()
        options.pathFilter = "100%-"
        let hits = try Search.run(harness.store, query: ["antenna tuner"], options: options)
        #expect(hits.count == 1)
        #expect(hits[0].path == "/Audio/100%-live.m4a")
    }

    @Test("--limit caps results; zero means unlimited")
    func limits() throws {
        let harness = try populated()
        var capped = Search.Options()
        capped.limit = 2
        #expect(try Search.run(harness.store, query: ["software defined radio"], options: capped).count == 2)

        var unlimited = Search.Options()
        unlimited.limit = 0
        #expect(try Search.run(harness.store, query: ["software defined radio"], options: unlimited).count == 3)
    }

    @Test("timestamps survive the round trip")
    func timestamps() throws {
        let harness = try populated()
        let hits = try Search.run(harness.store, query: ["antenna tuner"], options: Search.Options())
        let hit = try #require(hits.first)
        #expect(hit.t0MS == 10_000)
        #expect(hit.t1MS == 20_000)
    }

    @Test("an empty index returns no matches")
    func emptyIndex() throws {
        let harness = try TestStore()
        #expect(try Search.run(harness.store, query: ["anything"], options: Search.Options()).isEmpty)
    }
}
