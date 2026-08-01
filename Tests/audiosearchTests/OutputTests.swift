import Foundation
import Testing

@testable import audiosearch

@Suite("output")
struct OutputTests {

    private let hits = [
        SearchHit(path: "/Audio/Podcasts/ep-207.mp3", t0MS: 872_340, t1MS: 876_100,
                  text: "getting started with software defined radio is cheap",
                  snippet: "...with [software] [defined] [radio] is cheap...", score: -3.2),
        SearchHit(path: "/Audio/Podcasts/ep-207.mp3", t0MS: 2_467_000, t1MS: 2_470_000,
                  text: "the software defined radio on my desk",
                  snippet: "...the [software] [defined] [radio] on my desk...", score: -2.9),
        SearchHit(path: "/Audio/Recordings/panel.m4a", t0MS: 3_775_000, t1MS: 3_778_000,
                  text: "a panel on software defined radio",
                  snippet: "...panel on [software] [defined] [radio]...", score: -2.1),
    ]

    @Test("timestamps render as hh:mm:ss")
    func timestamps() {
        #expect(Output.timestamp(millis: 0) == "00:00:00")
        #expect(Output.timestamp(millis: 872_340) == "00:14:32")
        #expect(Output.timestamp(millis: 3_775_000) == "01:02:55")
        #expect(Output.timestamp(millis: 360_000_000) == "100:00:00")
        #expect(Output.timestamp(millis: -5) == "00:00:00")
    }

    @Test("text format prints each path once, with its matches beneath")
    func textGrouping() {
        let rendered = Output.renderText(hits)
        #expect(rendered == """
            /Audio/Podcasts/ep-207.mp3
              00:14:32  ...with [software] [defined] [radio] is cheap...
              00:41:07  ...the [software] [defined] [radio] on my desk...

            /Audio/Recordings/panel.m4a
              01:02:55  ...panel on [software] [defined] [radio]...

            """)
    }

    @Test("within a file, matches are listed chronologically regardless of rank")
    func textSortsSegmentsByTime() {
        // Second hit ranks better than the first but occurs later in the file.
        let rendered = Output.renderText([hits[1], hits[0]])
        #expect(rendered == """
            /Audio/Podcasts/ep-207.mp3
              00:14:32  ...with [software] [defined] [radio] is cheap...
              00:41:07  ...the [software] [defined] [radio] on my desk...

            """)
    }

    @Test("files appear in the order their best-ranked hit does")
    func textPreservesRankOrder() {
        let reordered = [hits[2], hits[0], hits[1]]
        let rendered = Output.renderText(reordered)
        let panelIndex = try? #require(rendered.range(of: "/Audio/Recordings/panel.m4a")?.lowerBound)
        let podcastIndex = try? #require(rendered.range(of: "/Audio/Podcasts/ep-207.mp3")?.lowerBound)
        #expect(panelIndex! < podcastIndex!)
    }

    @Test("text format abbreviates the home directory")
    func textAbbreviatesHome() {
        let hit = SearchHit(path: NSHomeDirectory() + "/Audio/x.mp3", t0MS: 0, t1MS: 1,
                            text: "t", snippet: "s", score: -1)
        #expect(Output.renderText([hit]).hasPrefix("~/Audio/x.mp3"))
    }

    /// Machine-readable formats keep absolute paths: a `~` in a field another
    /// program consumes is a path that no longer opens.
    @Test("tsv emits one absolute-path record per line")
    func tsvFormat() {
        let hit = SearchHit(path: NSHomeDirectory() + "/Audio/x.mp3", t0MS: 1_324_000, t1MS: 1_330_000,
                            text: "t", snippet: "...[propagation] [forecast] looks...", score: -1)
        let rendered = Output.renderTSV([hit])
        #expect(rendered == "\(NSHomeDirectory())/Audio/x.mp3\t00:22:04\t...[propagation] [forecast] looks...\n")
        #expect(rendered.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
    }

    @Test("tsv neutralizes tabs and newlines inside a field")
    func tsvEscaping() {
        let hit = SearchHit(path: "/a/b.mp3", t0MS: 0, t1MS: 1,
                            text: "t", snippet: "one\ttwo\nthree", score: -1)
        let rendered = Output.renderTSV([hit])
        #expect(rendered == "/a/b.mp3\t00:00:00\tone two three\n")
        #expect(rendered.filter { $0 == "\t" }.count == 2)
    }

    @Test("json emits an array of objects with absolute paths")
    func jsonFormat() throws {
        let rendered = try Output.renderJSON(hits)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [[String: Any]]
        )
        #expect(parsed.count == 3)
        #expect(parsed[0]["path"] as? String == "/Audio/Podcasts/ep-207.mp3")
        #expect(parsed[0]["t0_ms"] as? Int == 872_340)
        #expect(parsed[0]["timestamp"] as? String == "00:14:32")
        #expect(parsed[0]["text"] as? String == "getting started with software defined radio is cheap")
        // Slashes unescaped, so paths stay readable and greppable.
        #expect(rendered.contains("\\/") == false)
    }

    @Test("every format renders no results as empty output")
    func emptyResults() throws {
        for format in OutputFormat.allCases {
            let rendered = try Output.render([], as: format)
            #expect(rendered == (format == .json ? "[]\n" : ""))
        }
    }

    @Test("durations and byte sizes render for status")
    func statusFormatting() {
        #expect(Output.duration(seconds: 1_048_440) == "291h 14m")
        #expect(Output.duration(seconds: 0) == "0h 0m")
        #expect(Output.byteSize(0).isEmpty == false)
    }
}
