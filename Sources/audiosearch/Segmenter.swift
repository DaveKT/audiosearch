import Foundation

/// A merged, timestamped span of transcript text — one row of `segments`.
struct Segment: Equatable {
    let t0MS: Int
    let t1MS: Int
    let text: String
}

/// Segmentation parameters (plan Sections 6.1, 7.5). Persisted in `meta` so that a
/// run which omits the flags does not silently revert to compiled-in defaults and
/// mark the whole corpus stale.
struct SegmentationParameters: Equatable {
    var minSegment: Int = Store.Defaults.minSegment
    var maxSegment: Int = Store.Defaults.maxSegment
    var silenceGapMS: Int = Store.Defaults.silenceGapMS

    /// Bumped whenever segmentation logic changes; feeds the engine identity
    /// string (Section 6.2), so a bump marks existing rows stale for reporting.
    static let revision = 2

    init(minSegment: Int = Store.Defaults.minSegment,
         maxSegment: Int = Store.Defaults.maxSegment,
         silenceGapMS: Int = Store.Defaults.silenceGapMS) {
        self.minSegment = minSegment
        self.maxSegment = maxSegment
        self.silenceGapMS = silenceGapMS
    }

    init(_ stored: Store.Parameters) {
        self.init(minSegment: stored.minSegment,
                  maxSegment: stored.maxSegment,
                  silenceGapMS: stored.silenceGapMS)
    }
}

/// Turns word-level runs into searchable segments.
///
/// Pure and deterministic by construction: `[RawRun]` plus parameters in,
/// `[Segment]` out, with no reference to the Speech framework. That is a
/// testability requirement rather than an incidental property (plan Section 7.5) —
/// transcription is not reproducible, so boundary logic is tested against recorded
/// fixtures instead of through live analysis.
enum Segmenter {

    /// Segment size is the primary search-quality parameter. Short segments give
    /// precise timestamps but break phrase matches across rows; long segments do
    /// the reverse.
    ///
    /// Rules, in the priority order of Section 7.5:
    ///
    /// 1. Break after `.`, `?` or `!` once the segment exceeds `minSegment`.
    /// 2. Break when the segment reaches `maxSegment`.
    /// 3. Break on a gap between runs exceeding `silenceGapMS`.
    ///
    /// Note that `minSegment` gates rule 1 only. Rule 3 is unconditional: a real
    /// silence is a real boundary, and a segment that spans one reads as two
    /// unrelated thoughts joined together. The recorded `long-pauses` fixture
    /// contains a 19-second gap for exactly this reason.
    static func segment(
        _ runs: [RawRun],
        parameters: SegmentationParameters = SegmentationParameters()
    ) -> [Segment] {
        var segments: [Segment] = []

        var pending: [RawRun] = []
        var accumulated = ""

        func flush() {
            defer {
                pending.removeAll(keepingCapacity: true)
                accumulated.removeAll(keepingCapacity: true)
            }
            guard let first = pending.first, let last = pending.last else { return }
            let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(Segment(t0MS: first.startMS, t1MS: last.endMS, text: text))
        }

        for (index, run) in runs.enumerated() {
            // Rule 3, evaluated before the run is absorbed: the gap belongs
            // between this run and the previous one, not inside either segment.
            if index > 0, !pending.isEmpty {
                let gap = run.startMS - runs[index - 1].endMS
                if gap > parameters.silenceGapMS {
                    flush()
                }
            }

            pending.append(run)
            accumulated += run.text

            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)

            // Rule 1.
            if trimmed.count > parameters.minSegment, endsSentence(trimmed) {
                flush()
                continue
            }

            // Rule 2. Runs are atomic, so this overshoots by at most one word
            // rather than splitting mid-word.
            if trimmed.count >= parameters.maxSegment {
                flush()
            }
        }

        flush()
        return segments
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "?" || last == "!"
    }
}
