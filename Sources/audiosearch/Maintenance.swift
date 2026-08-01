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

    struct Health {
        var integrity: String
        var segments: Int
        var ftsRows: Int

        var isSynchronized: Bool { segments == ftsRows }
        var isIntact: Bool { integrity == "ok" }
        var isHealthy: Bool { isIntact && isSynchronized }
    }

    static func check(_ store: Store) throws -> Health {
        try store.queue.read { db in
            Health(
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown",
                segments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments") ?? 0,
                ftsRows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments_fts") ?? 0
            )
        }
    }
}
