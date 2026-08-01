import Foundation
import GRDB

// MARK: - Records

/// `files.status` (plan Section 6). `empty` distinguishes "analysis succeeded, no
/// speech present" from "analysis failed" — the structural fix for the predecessor
/// script's zero-byte-transcript ambiguity.
enum FileStatus: String, Codable, DatabaseValueConvertible, CaseIterable {
    case ok
    case empty
    case failed
}

struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "files"

    var id: Int64?
    /// Canonicalized absolute path (`Config.canonicalPath`).
    var path: String
    /// SHA-256 of the file bytes, streamed.
    var hash: String
    var size: Int64
    var mtime: Int64
    /// Seconds; populated during indexing, not left null once transcription runs.
    var duration: Double?
    var locale: String
    var engine: String
    var status: FileStatus
    /// Populated when `status == .failed`.
    var error: String?
    var indexedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, path, hash, size, mtime, duration, locale, engine, status, error
        case indexedAt = "indexed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct SegmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "segments"

    var id: Int64?
    var fileID: Int64
    var t0MS: Int
    var t1MS: Int
    var text: String

    enum CodingKeys: String, CodingKey {
        case id
        case fileID = "file_id"
        case t0MS = "t0_ms"
        case t1MS = "t1_ms"
        case text
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Store

/// GRDB setup, migrations, and the write/read paths over the Section 6 schema.
struct Store {
    let queue: DatabaseQueue
    let url: URL

    static let schemaVersion = 1

    /// Persisted parameter keys in `meta` (plan Section 6.1). Segmentation
    /// parameters live here so that an `index` run which omits the flags does not
    /// mark the whole corpus stale by silently reverting to compiled-in defaults.
    enum MetaKey {
        static let schemaVersion = "schema_version"
        static let minSegment = "min_segment"
        static let maxSegment = "max_segment"
        static let silenceGapMS = "silence_gap_ms"
        static let locale = "locale"
        static let libraryRoot = "library_root"
    }

    enum Defaults {
        static let minSegment = 40
        static let maxSegment = 240
        static let silenceGapMS = 800
        static let locale = "en-US"
    }

    // MARK: Opening

    static func open(at url: URL, createDirectory: Bool = true) throws -> Store {
        if createDirectory {
            try Config.prepareContainingDirectory(for: url)
        }

        var configuration = Configuration()
        // GRDB already sets `PRAGMA foreign_keys = ON` per connection; WAL is not a
        // default for DatabaseQueue, so set it explicitly (plan Section 6).
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw AudiosearchError.environment(
                "cannot open database at \(url.path): \(error.localizedDescription)"
            )
        }

        let store = Store(queue: queue, url: url)
        try store.migrate()
        return store
    }

    /// Opens a store for reading only, failing with an environment error rather
    /// than creating an empty database when none exists yet.
    static func openExisting(at url: URL) throws -> Store {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudiosearchError.environment(
                """
                no index at \(url.path)
                Run 'audiosearch index <path>' to create one.
                """
            )
        }
        return try open(at: url, createDirectory: false)
    }

    // MARK: Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (
                  key   TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                );

                CREATE TABLE files (
                  id          INTEGER PRIMARY KEY,
                  path        TEXT NOT NULL UNIQUE,
                  hash        TEXT NOT NULL,
                  size        INTEGER NOT NULL,
                  mtime       INTEGER NOT NULL,
                  duration    REAL,
                  locale      TEXT NOT NULL,
                  engine      TEXT NOT NULL,
                  status      TEXT NOT NULL,
                  error       TEXT,
                  indexed_at  INTEGER NOT NULL
                );

                CREATE TABLE segments (
                  id      INTEGER PRIMARY KEY,
                  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                  t0_ms   INTEGER NOT NULL,
                  t1_ms   INTEGER NOT NULL,
                  text    TEXT NOT NULL
                );

                -- Composite rather than file_id alone: `--context N` retrieves
                -- ordered neighbours of a match, and file_id alone forces a sort
                -- on every context expansion.
                CREATE INDEX idx_segments_file_t0 ON segments(file_id, t0_ms);

                -- External content: the transcript text is not duplicated. Raw SQL
                -- rather than GRDB's `synchronize(withTable:)` because population is
                -- deliberately explicit, not trigger-driven — writes happen only
                -- during indexing (plan Section 6).
                CREATE VIRTUAL TABLE segments_fts USING fts5(
                  text,
                  content='segments',
                  content_rowid='id',
                  tokenize='porter unicode61'
                );
                """)

            // GRDB tracks applied migrations in its own table; schema_version is
            // additionally recorded in meta because it is part of the documented
            // on-disk contract and is reported by `status`.
            try Self.setMeta(db, MetaKey.schemaVersion, String(Self.schemaVersion))
            try Self.setMeta(db, MetaKey.minSegment, String(Defaults.minSegment))
            try Self.setMeta(db, MetaKey.maxSegment, String(Defaults.maxSegment))
            try Self.setMeta(db, MetaKey.silenceGapMS, String(Defaults.silenceGapMS))
            try Self.setMeta(db, MetaKey.locale, Defaults.locale)
        }

        do {
            try migrator.migrate(queue)
        } catch {
            throw AudiosearchError.environment(
                "cannot migrate database at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: meta

    static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: "INSERT INTO meta(key, value) VALUES(?, ?) "
               + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value]
        )
    }

    static func meta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func metaInt(_ db: Database, _ key: String) throws -> Int? {
        try meta(db, key).flatMap(Int.init)
    }

    func meta(_ key: String) throws -> String? {
        try queue.read { try Self.meta($0, key) }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try queue.write { try Self.setMeta($0, key, value) }
    }

    /// Effective segmentation parameters, as persisted (plan Section 6.1).
    struct Parameters: Equatable {
        var minSegment: Int
        var maxSegment: Int
        var silenceGapMS: Int
        var locale: String
    }

    func parameters() throws -> Parameters {
        try queue.read { db in
            Parameters(
                minSegment: try Self.metaInt(db, MetaKey.minSegment) ?? Defaults.minSegment,
                maxSegment: try Self.metaInt(db, MetaKey.maxSegment) ?? Defaults.maxSegment,
                silenceGapMS: try Self.metaInt(db, MetaKey.silenceGapMS) ?? Defaults.silenceGapMS,
                locale: try Self.meta(db, MetaKey.locale) ?? Defaults.locale
            )
        }
    }

    // MARK: Writes

    /// Inserts or replaces one file and its segments in a single transaction.
    ///
    /// `segments_fts` is external-content with no triggers, so both halves of every
    /// change are issued by hand: `'delete'` commands carrying the *old* text before
    /// rows leave `segments`, then fresh rows after they arrive. Deleting the parent
    /// `files` row and relying on `ON DELETE CASCADE` would drop segments without
    /// ever telling the FTS index, leaving it permanently desynchronised.
    @discardableResult
    func replaceFile(_ file: FileRecord, segments: [SegmentRecord]) throws -> Int64 {
        try queue.write { db in
            var record = file
            record.id = nil

            if let existingID = try Int64.fetchOne(
                db, sql: "SELECT id FROM files WHERE path = ?", arguments: [file.path]
            ) {
                try Self.deleteSegments(db, fileID: existingID)
                record.id = existingID
                try record.update(db)
            } else {
                try record.insert(db)
            }

            guard let fileID = record.id else {
                throw AudiosearchError.environment("insert of \(file.path) returned no row id")
            }

            for segment in segments {
                var row = segment
                row.id = nil
                row.fileID = fileID
                try row.insert(db)
                try db.execute(
                    sql: "INSERT INTO segments_fts(rowid, text) VALUES(?, ?)",
                    arguments: [row.id, row.text]
                )
            }

            return fileID
        }
    }

    /// Removes a file row and everything indexed under it, FTS index included.
    func deleteFile(path: String) throws {
        try queue.write { db in
            guard let fileID = try Int64.fetchOne(
                db, sql: "SELECT id FROM files WHERE path = ?", arguments: [path]
            ) else { return }
            try Self.deleteSegments(db, fileID: fileID)
            try db.execute(sql: "DELETE FROM files WHERE id = ?", arguments: [fileID])
        }
    }

    private static func deleteSegments(_ db: Database, fileID: Int64) throws {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, text FROM segments WHERE file_id = ?",
            arguments: [fileID]
        )
        for row in rows {
            // The 'delete' command must be given the exact text originally
            // indexed, or FTS5 corrupts its own posting lists.
            try db.execute(
                sql: "INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', ?, ?)",
                arguments: [row["id"] as Int64, row["text"] as String]
            )
        }
        try db.execute(sql: "DELETE FROM segments WHERE file_id = ?", arguments: [fileID])
    }

    // MARK: Reads

    func file(path: String) throws -> FileRecord? {
        try queue.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?", arguments: [path])
        }
    }

    func segments(fileID: Int64) throws -> [SegmentRecord] {
        try queue.read { db in
            try SegmentRecord.fetchAll(
                db,
                sql: "SELECT * FROM segments WHERE file_id = ? ORDER BY t0_ms",
                arguments: [fileID]
            )
        }
    }

    /// Corpus counts for `status`.
    struct Counts: Equatable {
        var files: Int
        var byStatus: [FileStatus: Int]
        var segments: Int
        var ftsRows: Int
        var totalDuration: Double
    }

    func counts() throws -> Counts {
        try queue.read { db in
            var byStatus: [FileStatus: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM files GROUP BY status") {
                if let status = FileStatus(rawValue: row["status"]) {
                    byStatus[status] = row["n"]
                }
            }
            return Counts(
                files: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0,
                byStatus: byStatus,
                segments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments") ?? 0,
                ftsRows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments_fts") ?? 0,
                totalDuration: try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(duration), 0) FROM files") ?? 0
            )
        }
    }

    /// Distinct engine identity strings present in the index. Comparing these
    /// against the *current* engine is the M3 staleness gate; `status` reports
    /// them as-is for now.
    func engines() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT engine FROM files ORDER BY engine")
        }
    }

    var fileSizeOnDisk: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int64) ?? 0
    }
}
