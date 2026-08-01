import Foundation
import Testing

@testable import audiosearch

/// Segment boundary logic is the most likely place for a silent regression, so it
/// is tested directly against recorded runs rather than through live transcription
/// (plan Section 13.2).
@Suite("segmenter")
struct SegmenterTests {

    // MARK: - Fixtures

    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // audiosearchTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/runs")

    /// The three real-speech fixtures carry authentic timing with the words
    /// stripped, because the source is private and this repo is public. Assertions
    /// here are about boundaries and timestamps, never about text.
    static func load(_ name: String) throws -> [RawRun] {
        let url = fixturesURL.appendingPathComponent("\(name).json")
        return try JSONDecoder().decode([RawRun].self, from: try Data(contentsOf: url))
    }

    static let realSpeechFixtures = ["podcast-excerpt", "rapid-speech", "long-pauses"]

    // MARK: - Rules

    private func run(_ text: String, _ start: Int, _ end: Int) -> RawRun {
        RawRun(text: text, startMS: start, endMS: end)
    }

    @Test("empty input produces no segments")
    func empty() {
        #expect(Segmenter.segment([]).isEmpty)
    }

    @Test("runs shorter than every threshold still produce one segment")
    func singleShortSegment() {
        let segments = Segmenter.segment([run("hello", 0, 500), run(" world", 500, 900)])
        #expect(segments == [Segment(t0MS: 0, t1MS: 900, text: "hello world")])
    }

    @Test("rule 1: a sentence ends a segment once it exceeds minSegment")
    func sentenceBreak() {
        let parameters = SegmentationParameters(minSegment: 10, maxSegment: 1000, silenceGapMS: 10_000)
        let segments = Segmenter.segment([
            run("the quick brown fox jumps.", 0, 1000),
            run(" and then more words follow", 1000, 2000),
        ], parameters: parameters)

        #expect(segments.count == 2)
        #expect(segments[0].text == "the quick brown fox jumps.")
        #expect(segments[0].t1MS == 1000)
        #expect(segments[1].t0MS == 1000)
    }

    @Test("rule 1 does not fire below minSegment, so short sentences accumulate")
    func shortSentencesAccumulate() {
        let parameters = SegmentationParameters(minSegment: 40, maxSegment: 1000, silenceGapMS: 10_000)
        let segments = Segmenter.segment([
            run("Yes.", 0, 200), run(" No.", 200, 400), run(" Maybe.", 400, 600),
        ], parameters: parameters)

        // Each is a sentence, but none reaches minSegment, so they stay together
        // rather than becoming three near-useless rows.
        #expect(segments.count == 1)
        #expect(segments[0].text == "Yes. No. Maybe.")
    }

    @Test("rule 2: a segment breaks on reaching maxSegment even mid-sentence")
    func maxLengthBreak() {
        let parameters = SegmentationParameters(minSegment: 5, maxSegment: 20, silenceGapMS: 10_000)
        let words = (0..<10).map { run("word\($0) ", $0 * 100, $0 * 100 + 100) }
        let segments = Segmenter.segment(words, parameters: parameters)

        #expect(segments.count > 1)
        // Runs are atomic, so the bound may overshoot by at most one word.
        for segment in segments {
            #expect(segment.text.count <= 20 + 8)
        }
    }

    @Test("rule 3: a silence longer than the gap breaks the segment unconditionally")
    func silenceBreak() {
        let parameters = SegmentationParameters(minSegment: 400, maxSegment: 1000, silenceGapMS: 800)
        let segments = Segmenter.segment([
            run("before the pause", 0, 1000),
            run(" after the pause", 5000, 6000),
        ], parameters: parameters)

        // Neither side reaches minSegment or maxSegment. A real silence is still a
        // real boundary: rule 3 is not gated on length.
        #expect(segments.count == 2)
        #expect(segments[0] == Segment(t0MS: 0, t1MS: 1000, text: "before the pause"))
        #expect(segments[1] == Segment(t0MS: 5000, t1MS: 6000, text: "after the pause"))
    }

    @Test("a gap exactly at the threshold does not break")
    func gapBoundary() {
        let parameters = SegmentationParameters(minSegment: 400, maxSegment: 1000, silenceGapMS: 800)
        let segments = Segmenter.segment([
            run("before", 0, 1000),
            run(" after", 1800, 2000),   // gap of exactly 800
        ], parameters: parameters)
        #expect(segments.count == 1)
    }

    @Test("timestamps span the first and last run of each segment")
    func timestampSpan() {
        let parameters = SegmentationParameters(minSegment: 400, maxSegment: 1000, silenceGapMS: 800)
        let segments = Segmenter.segment([
            run("a", 100, 200), run(" b", 200, 300), run(" c", 300, 450),
            run(" d", 9000, 9100),
        ], parameters: parameters)

        #expect(segments.count == 2)
        #expect(segments[0].t0MS == 100)
        #expect(segments[0].t1MS == 450)
        #expect(segments[1].t0MS == 9000)
        #expect(segments[1].t1MS == 9100)
    }

    @Test("whitespace-only input yields no segments rather than empty rows")
    func whitespaceOnly() {
        #expect(Segmenter.segment([run("   ", 0, 100), run(" ", 100, 200)]).isEmpty)
    }

    @Test("segmentation is deterministic")
    func deterministic() throws {
        let runs = try Self.load("podcast-excerpt")
        #expect(Segmenter.segment(runs) == Segmenter.segment(runs))
    }

    // MARK: - Against recorded real speech

    @Test("every recorded fixture segments without loss or overlap",
          arguments: SegmenterTests.realSpeechFixtures)
    func realSpeechInvariants(fixture: String) throws {
        let runs = try Self.load(fixture)
        #expect(!runs.isEmpty)

        let segments = Segmenter.segment(runs)
        #expect(!segments.isEmpty)

        for segment in segments {
            #expect(segment.t0MS <= segment.t1MS)
            #expect(!segment.text.isEmpty)
            #expect(segment.text == segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Segments must advance monotonically and never overlap, or `--context N`
        // and playback offsets both become meaningless.
        for (earlier, later) in zip(segments, segments.dropFirst()) {
            #expect(earlier.t1MS <= later.t0MS)
        }

        // No transcript text may be dropped on the floor.
        let fromRuns = runs.map(\.text).joined()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let fromSegments = segments.map(\.text).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        #expect(fromRuns == fromSegments)
    }

    @Test("no segment spans a silence longer than the configured gap",
          arguments: SegmenterTests.realSpeechFixtures)
    func neverSpansSilence(fixture: String) throws {
        let runs = try Self.load(fixture)
        let parameters = SegmentationParameters()
        let segments = Segmenter.segment(runs, parameters: parameters)

        // Reconstruct which runs fell into each segment by walking timestamps.
        var index = 0
        for segment in segments {
            var previousEnd: Int?
            while index < runs.count, runs[index].endMS <= segment.t1MS {
                if let previousEnd {
                    #expect(runs[index].startMS - previousEnd <= parameters.silenceGapMS,
                            "\(fixture): segment at \(segment.t0MS)ms spans a silence")
                }
                previousEnd = runs[index].endMS
                index += 1
            }
        }
    }

    /// `long-pauses` was chosen from the source recording precisely because it has
    /// seven silences over 800ms, and `rapid-speech` because it has none. If those
    /// properties ever stop holding, the fixtures have been regenerated wrongly and
    /// the tests above are no longer exercising what they claim to.
    @Test("the fixtures still have the acoustic properties they were selected for")
    func fixturesRemainRepresentative() throws {
        func gapsOver800(_ name: String) throws -> Int {
            let runs = try Self.load(name)
            return zip(runs, runs.dropFirst())
                .filter { $1.startMS - $0.endMS > 800 }
                .count
        }

        #expect(try gapsOver800("rapid-speech") == 0)
        #expect(try gapsOver800("long-pauses") >= 5)
        #expect(try Self.load("podcast-excerpt").count == 220)
    }

    @Test("tighter bounds produce more, smaller segments")
    func boundsAffectGranularity() throws {
        let runs = try Self.load("podcast-excerpt")
        let coarse = Segmenter.segment(runs, parameters: SegmentationParameters(
            minSegment: 40, maxSegment: 400, silenceGapMS: 800))
        let fine = Segmenter.segment(runs, parameters: SegmentationParameters(
            minSegment: 20, maxSegment: 80, silenceGapMS: 800))
        #expect(fine.count > coarse.count)
    }
}
