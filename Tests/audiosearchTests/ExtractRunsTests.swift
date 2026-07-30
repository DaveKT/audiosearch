import CoreMedia
import Foundation
import Testing

@testable import audiosearch

@Suite("extractRuns")
struct ExtractRunsTests {

    private func timeRange(startMS: Int, endMS: Int) -> CMTimeRange {
        let start = CMTime(value: CMTimeValue(startMS), timescale: 1000)
        let end = CMTime(value: CMTimeValue(endMS), timescale: 1000)
        return CMTimeRange(start: start, end: end)
    }

    @Test("extracts one run per tagged word, in order, with correct millisecond timing")
    func extractsTaggedRuns() {
        var text = AttributedString("The")
        text.audioTimeRange = timeRange(startMS: 0, endMS: 300)

        var quick = AttributedString(" quick")
        quick.audioTimeRange = timeRange(startMS: 300, endMS: 420)
        text.append(quick)

        let runs = extractRuns(from: text)

        #expect(runs.count == 2)
        #expect(runs[0] == RawRun(text: "The", startMS: 0, endMS: 300))
        #expect(runs[1] == RawRun(text: " quick", startMS: 300, endMS: 420))
    }

    @Test("drops runs with no audioTimeRange attribute")
    func dropsUntaggedRuns() {
        var tagged = AttributedString("hello")
        tagged.audioTimeRange = timeRange(startMS: 0, endMS: 500)

        let untagged = AttributedString(" world")
        var text = tagged
        text.append(untagged)

        let runs = extractRuns(from: text)

        #expect(runs.count == 1)
        #expect(runs[0].text == "hello")
    }

    @Test("drops runs that are whitespace-only once trimmed")
    func dropsWhitespaceOnlyRuns() {
        var text = AttributedString("word")
        text.audioTimeRange = timeRange(startMS: 0, endMS: 200)

        var whitespace = AttributedString("   ")
        whitespace.audioTimeRange = timeRange(startMS: 200, endMS: 250)
        text.append(whitespace)

        let runs = extractRuns(from: text)

        #expect(runs.count == 1)
        #expect(runs[0].text == "word")
    }

    @Test("returns an empty array for an attributed string with no runs")
    func emptyInput() {
        let runs = extractRuns(from: AttributedString(""))
        #expect(runs.isEmpty)
    }
}

extension RawRun: Equatable {
    public static func == (lhs: RawRun, rhs: RawRun) -> Bool {
        lhs.text == rhs.text && lhs.startMS == rhs.startMS && lhs.endMS == rhs.endMS
    }
}
