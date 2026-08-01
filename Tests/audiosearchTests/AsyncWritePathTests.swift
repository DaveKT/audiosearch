import Foundation
import Testing

@testable import audiosearch

/// Plan Section 8.3 flags mixing GRDB's concurrency model with the `async`
/// transcription path as the second most likely source of compiler friction in
/// M2, and assigns confirming the signature to M1. M1 had no async code to
/// confirm it against, so it is confirmed here instead: these tests exist to fail
/// at *compile* time if the write path cannot be driven from an async context.
@Suite("async write path")
struct AsyncWritePathTests {

    /// The shape M2's Indexer will actually have: an async function that awaits
    /// transcription, then writes. Store.replaceFile is synchronous and blocks the
    /// calling thread inside GRDB's own queue, which is the intended usage.
    private func indexOneFile(_ store: Store, path: String, texts: [String]) async throws -> Int64 {
        // Stands in for `await transcriber.transcribe(url:)`.
        await Task.yield()

        let file = FileRecord(
            id: nil, path: path, hash: "h", size: 1, mtime: 1, duration: 1,
            locale: "en-US", engine: "speech/test/en-US/seg2",
            status: .ok, error: nil, indexedAt: 1
        )
        let segments = texts.enumerated().map { offset, text in
            SegmentRecord(id: nil, fileID: 0, t0MS: offset * 1000,
                          t1MS: (offset + 1) * 1000, text: text)
        }
        return try store.replaceFile(file, segments: segments)
    }

    @Test("the write path compiles and runs from an async context")
    func writeFromAsyncContext() async throws {
        let harness = try TestStore()
        let fileID = try await indexOneFile(
            harness.store, path: "/tmp/async.m4a", texts: ["propagation forecast tonight"]
        )
        #expect(fileID > 0)
        #expect(try Search.run(harness.store, query: ["propagation forecast"],
                               options: Search.Options()).count == 1)
    }

    /// Section 8.4 defaults indexing to serial but keeps `--jobs N` open so the
    /// question can be measured. If the store cannot be written from more than one
    /// task at all, that flag is dead on arrival — so prove it can be now, while
    /// it is cheap to find out.
    @Test("sequential awaits across many files leave a consistent index")
    func serialIndexingLoop() async throws {
        let harness = try TestStore()
        for index in 0..<25 {
            _ = try await indexOneFile(
                harness.store, path: "/tmp/file-\(index).m4a", texts: ["antenna tuner \(index)"]
            )
        }
        let counts = try harness.store.counts()
        #expect(counts.files == 25)
        #expect(counts.segments == 25)
        #expect(counts.segments == counts.ftsRows)
    }

    @Test("concurrent writers serialize rather than corrupting the index")
    func concurrentWriters() async throws {
        let harness = try TestStore()
        let store = harness.store

        try await withThrowingTaskGroup(of: Int64.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await indexOneFile(
                        store, path: "/tmp/parallel-\(index).m4a",
                        texts: ["software defined radio \(index)"]
                    )
                }
            }
            for try await _ in group {}
        }

        let counts = try harness.store.counts()
        #expect(counts.files == 12)
        #expect(counts.segments == 12)
        // The invariant that matters: no torn writes between segments and the
        // external-content FTS index.
        #expect(counts.segments == counts.ftsRows)
        #expect(try Search.run(store, query: ["software defined radio"],
                               options: Search.Options(mode: .phrase, pathFilter: nil, limit: 0)).count == 12)
    }
}
