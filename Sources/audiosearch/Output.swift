import ArgumentParser
import Foundation

/// Stdout carries only results — search output and `export` JSONL. Everything
/// else (progress, warnings, `status`, `doctor`, prompts) goes to stderr, or the
/// `--format tsv` and `jq` pipelines in plan Section 12.4 break. Section 10.2.
enum Streams {
    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func outLine(_ text: String = "") {
        out(text + "\n")
    }

    static func err(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func errLine(_ text: String = "") {
        err(text + "\n")
    }

    /// Progress rendering is suppressed when stderr is not a TTY (Section 10.2).
    static var stderrIsTTY: Bool {
        isatty(FileHandle.standardError.fileDescriptor) == 1
    }
}

enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case tsv
    case json
}

enum Output {

    /// `hh:mm:ss` from a millisecond offset.
    static func timestamp(millis: Int) -> String {
        let totalSeconds = max(0, millis) / 1000
        return String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3600,
            (totalSeconds % 3600) / 60,
            totalSeconds % 60
        )
    }

    /// Human-readable audio total, e.g. `291h 14m`.
    static func duration(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// Byte count for `status`, e.g. `34 MB`.
    static func byteSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Result rendering

    /// Grouped by file: the path is printed once as a heading, matching segments
    /// listed beneath it. Chosen over one-row-per-segment because a single file
    /// often carries many hits and repeating a long path drowns the text.
    ///
    /// Files appear in the order their best-ranked hit does, so global relevance
    /// ordering survives the grouping. Within a file, matches are listed in
    /// chronological order: once the path is the heading, the timestamps are what
    /// the eye scans, and a rank-shuffled column of them reads as noise.
    static func renderText(_ hits: [SearchHit]) -> String {
        var order: [String] = []
        var grouped: [String: [SearchHit]] = [:]
        for hit in hits {
            if grouped[hit.path] == nil {
                order.append(hit.path)
                grouped[hit.path] = []
            }
            grouped[hit.path]?.append(hit)
        }

        var blocks: [String] = []
        for path in order {
            var lines = [Config.abbreviatingHome(path)]
            for hit in (grouped[path] ?? []).sorted(by: { $0.t0MS < $1.t0MS }) {
                lines.append("  \(timestamp(millis: hit.t0MS))  \(singleLine(hit.snippet))")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    /// One record per line: absolute path, timestamp, snippet.
    ///
    /// Deliberately *not* home-abbreviated, unlike the text format — a `~` in a
    /// field consumed by another program is a path that no longer opens.
    static func renderTSV(_ hits: [SearchHit]) -> String {
        hits
            .map { hit in
                [hit.path, timestamp(millis: hit.t0MS), singleLine(hit.snippet)]
                    .map(escapeTSVField)
                    .joined(separator: "\t")
            }
            .joined(separator: "\n")
            .appendingNewlineIfNonEmpty()
    }

    private struct JSONHit: Encodable {
        let path: String
        let t0_ms: Int
        let t1_ms: Int
        let timestamp: String
        let snippet: String
        let text: String
        let score: Double
    }

    static func renderJSON(_ hits: [SearchHit]) throws -> String {
        // JSONEncoder's pretty printer renders an empty array as "[\n\n]".
        guard !hits.isEmpty else { return "[]\n" }

        let payload = hits.map { hit in
            JSONHit(
                path: hit.path,
                t0_ms: hit.t0MS,
                t1_ms: hit.t1MS,
                timestamp: timestamp(millis: hit.t0MS),
                snippet: hit.snippet,
                text: hit.text,
                score: hit.score
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
    }

    static func render(_ hits: [SearchHit], as format: OutputFormat) throws -> String {
        switch format {
        case .text: return renderText(hits)
        case .tsv: return renderTSV(hits)
        case .json: return try renderJSON(hits)
        }
    }

    // MARK: - Helpers

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func escapeTSVField(_ field: String) -> String {
        field.replacingOccurrences(of: "\t", with: " ")
    }
}

private extension String {
    func appendingNewlineIfNonEmpty() -> String {
        isEmpty ? self : self + "\n"
    }
}
