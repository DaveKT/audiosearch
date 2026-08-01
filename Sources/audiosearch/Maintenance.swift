import Foundation
import GRDB

/// FTS5 maintenance and integrity checks (plan Section 11.2).
///
/// External-content FTS5 tables can desync from the content table. Both repairs
/// are cheap relative to retranscription, which is the only genuinely expensive
/// and irreversible work in this system.
enum Maintenance {

    /// Run after a large indexing batch.
    static func optimize(_ store: Store) throws {
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO segments_fts(segments_fts) VALUES('optimize')")
        }
    }

    /// Rebuild the search index from the content table. Used by `doctor --repair`.
    ///
    /// Safe in the sense that matters: it recomputes the FTS index from `segments`,
    /// which holds the transcripts. No transcription is lost or repeated.
    static func rebuild(_ store: Store) throws {
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO segments_fts(segments_fts) VALUES('rebuild')")
        }
    }

    /// Whether the FTS index actually agrees with the transcripts in `segments`.
    ///
    /// **Not** a row-count comparison. Plan Section 11.2 prescribed comparing
    /// `COUNT(*)` between `segments` and `segments_fts`, but for an *external
    /// content* table that comparison is vacuous: querying `segments_fts` reads
    /// through to the content table, so the two counts are equal by construction
    /// and stay equal no matter how badly the index has drifted. Verified — a
    /// segment inserted without its FTS row reported "2 segments, 2 indexed, in
    /// sync" while being completely unsearchable.
    ///
    /// The real check is FTS5's own `integrity-check` with its argument set to 1,
    /// which compares the index against the content table rather than merely
    /// checking that the index is internally well formed. The bare form (argument
    /// omitted or 0) also passes on a desynchronised index.
    static func searchIndexIsConsistent(_ store: Store) throws -> Bool {
        do {
            try store.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO segments_fts(segments_fts, rank) VALUES('integrity-check', 1)"
                )
            }
            return true
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT {
            return false
        }
    }

    struct Health {
        var integrity: String
        var segments: Int
        var searchIndexConsistent: Bool

        var isIntact: Bool { integrity == "ok" }
        var isHealthy: Bool { isIntact && searchIndexConsistent }
    }

    static func check(_ store: Store) throws -> Health {
        let (integrity, segments) = try store.queue.read { db in
            (try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown",
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments") ?? 0)
        }
        return Health(
            integrity: integrity,
            segments: segments,
            searchIndexConsistent: try searchIndexIsConsistent(store)
        )
    }
}
