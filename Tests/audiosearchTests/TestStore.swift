import Foundation
import Testing

@testable import audiosearch

/// A `Store` on a scratch database, torn down with the test.
///
/// Segments are inserted synthetically rather than transcribed: M1 has no
/// transcription, and the plan's acceptance criterion is precisely that synthetic
/// segments round trip (Section 14, M1).
final class TestStore {
    let store: Store
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiosearch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try Store.open(at: directory.appendingPathComponent("index.db"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Inserts a file with segments laid out back to back, ten seconds apart.
    @discardableResult
    func insert(
        path: String,
        texts: [String],
        status: FileStatus = .ok,
        hash: String = "sha256-test",
        engine: String = "speech/26C61/en-US/seg2"
    ) throws -> Int64 {
        let file = FileRecord(
            id: nil,
            path: path,
            hash: hash,
            size: 1024,
            mtime: 1_700_000_000,
            duration: Double(texts.count) * 10,
            locale: "en-US",
            engine: engine,
            status: status,
            error: nil,
            indexedAt: 1_700_000_000
        )
        let segments = texts.enumerated().map { offset, text in
            SegmentRecord(
                id: nil,
                fileID: 0,
                t0MS: offset * 10_000,
                t1MS: (offset + 1) * 10_000,
                text: text
            )
        }
        return try store.replaceFile(file, segments: segments)
    }
}
