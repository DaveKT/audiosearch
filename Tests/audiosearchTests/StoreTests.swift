import Foundation
import GRDB
import Testing

@testable import audiosearch

@Suite("store")
struct StoreTests {

    @Test("synthetic segments round trip")
    func roundTrip() throws {
        let harness = try TestStore()
        let fileID = try harness.insert(
            path: "/tmp/audio/one.m4a",
            texts: ["the quick brown fox", "jumps over the lazy dog"]
        )

        let file = try #require(try harness.store.file(path: "/tmp/audio/one.m4a"))
        #expect(file.id == fileID)
        #expect(file.status == .ok)
        #expect(file.duration == 20)
        #expect(file.locale == "en-US")

        let segments = try harness.store.segments(fileID: fileID)
        #expect(segments.count == 2)
        #expect(segments[0].text == "the quick brown fox")
        #expect(segments[0].t0MS == 0)
        #expect(segments[1].t0MS == 10_000)
        #expect(segments.allSatisfy { $0.fileID == fileID })
    }

    @Test("migration seeds schema version and the persisted segmentation parameters")
    func seededMeta() throws {
        let harness = try TestStore()
        #expect(try harness.store.meta(Store.MetaKey.schemaVersion) == String(Store.schemaVersion))

        let parameters = try harness.store.parameters()
        #expect(parameters == Store.Parameters(
            minSegment: 40, maxSegment: 240, silenceGapMS: 800, locale: "en-US"
        ))
    }

    @Test("meta writes are read back and overwrite in place")
    func metaUpsert() throws {
        let harness = try TestStore()
        try harness.store.setMeta(Store.MetaKey.libraryRoot, "/Volumes/Audio")
        #expect(try harness.store.meta(Store.MetaKey.libraryRoot) == "/Volumes/Audio")

        try harness.store.setMeta(Store.MetaKey.libraryRoot, "/Users/dave/Audio")
        #expect(try harness.store.meta(Store.MetaKey.libraryRoot) == "/Users/dave/Audio")

        let rows = try harness.store.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta WHERE key = ?",
                             arguments: [Store.MetaKey.libraryRoot])
        }
        #expect(rows == 1)
    }

    @Test("reindexing a path replaces its segments rather than accumulating them")
    func replaceIsIdempotent() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/audio/one.m4a", texts: ["first pass text"])
        try harness.insert(path: "/tmp/audio/one.m4a", texts: ["second pass text", "and more"])

        let counts = try harness.store.counts()
        #expect(counts.files == 1)
        #expect(counts.segments == 2)

        let file = try #require(try harness.store.file(path: "/tmp/audio/one.m4a"))
        let segments = try harness.store.segments(fileID: try #require(file.id))
        #expect(segments.map(\.text) == ["second pass text", "and more"])
    }

    /// The external-content FTS5 table has no triggers, so every delete must be
    /// issued by hand. If that is ever dropped, stale rows keep matching and the
    /// index silently returns text that is no longer in the corpus.
    @Test("replacing a file removes its old text from the search index")
    func replaceClearsSearchIndex() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/audio/one.m4a", texts: ["propagation forecast tonight"])
        #expect(try search(harness, "propagation forecast").count == 1)

        try harness.insert(path: "/tmp/audio/one.m4a", texts: ["entirely different content"])
        #expect(try search(harness, "propagation forecast").isEmpty)
        #expect(try search(harness, "entirely different").count == 1)

        let counts = try harness.store.counts()
        #expect(counts.segments == counts.ftsRows)
    }

    @Test("deleting a file removes its rows and its search index entries")
    func deleteClearsSearchIndex() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/audio/one.m4a", texts: ["propagation forecast tonight"])
        try harness.insert(path: "/tmp/audio/two.m4a", texts: ["antenna tuner settings"])

        try harness.store.deleteFile(path: "/tmp/audio/one.m4a")

        #expect(try search(harness, "propagation forecast").isEmpty)
        #expect(try search(harness, "antenna tuner").count == 1)

        let counts = try harness.store.counts()
        #expect(counts.files == 1)
        #expect(counts.segments == 1)
        #expect(counts.ftsRows == 1)
    }

    @Test("deleting a path that was never indexed is a no-op")
    func deleteUnknownPath() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/audio/one.m4a", texts: ["some text"])
        try harness.store.deleteFile(path: "/tmp/audio/absent.m4a")
        #expect(try harness.store.counts().files == 1)
    }

    @Test("counts group files by status and total their durations")
    func counts() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["one", "two"])
        try harness.insert(path: "/tmp/b.m4a", texts: [], status: .empty)
        try harness.insert(path: "/tmp/c.m4a", texts: [], status: .failed)

        let counts = try harness.store.counts()
        #expect(counts.files == 3)
        #expect(counts.byStatus[.ok] == 1)
        #expect(counts.byStatus[.empty] == 1)
        #expect(counts.byStatus[.failed] == 1)
        #expect(counts.segments == 2)
        #expect(counts.totalDuration == 20)
    }

    @Test("distinct engine identities are reported")
    func engines() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["one"], engine: "speech/26C61/en-US/seg2")
        try harness.insert(path: "/tmp/b.m4a", texts: ["two"], engine: "speech/26C61/en-US/seg2")
        try harness.insert(path: "/tmp/c.m4a", texts: ["three"], engine: "speech/26D48/en-US/seg2")

        #expect(try harness.store.engines() == ["speech/26C61/en-US/seg2", "speech/26D48/en-US/seg2"])
    }

    @Test("WAL and foreign key enforcement are on")
    func pragmas() throws {
        let harness = try TestStore()
        let (journalMode, foreignKeys) = try harness.store.queue.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"),
             try Int.fetchOne(db, sql: "PRAGMA foreign_keys"))
        }
        #expect(journalMode?.lowercased() == "wal")
        #expect(foreignKeys == 1)
    }

    @Test("opening a database that does not exist is an environment error, not an empty index")
    func openExistingMissing() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiosearch-absent-\(UUID().uuidString).db")
        #expect(throws: AudiosearchError.self) {
            _ = try Store.openExisting(at: path)
        }
    }

    private func search(_ harness: TestStore, _ query: String) throws -> [SearchHit] {
        try Search.run(harness.store, query: [query], options: Search.Options())
    }
}
