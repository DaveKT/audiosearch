import Foundation
import GRDB
import Testing

@testable import audiosearch

@Suite("maintenance")
struct MaintenanceTests {

    /// Writes a segment row directly, bypassing `Store.replaceFile` and therefore
    /// skipping the explicit FTS insert. This is exactly the corruption that a
    /// missing `segments_fts` write would cause in production.
    private func desynchronize(_ store: Store) throws {
        try store.queue.write { db in
            try db.execute(
                sql: "INSERT INTO segments(file_id, t0_ms, t1_ms, text) VALUES(1, 0, 1, ?)",
                arguments: ["unsearchable orphan text"]
            )
        }
    }

    @Test("a healthy index reports consistent")
    func healthyIndex() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["propagation forecast tonight"])
        #expect(try Maintenance.searchIndexIsConsistent(harness.store))
    }

    /// The test that earns the whole change: this is what the old row-count
    /// comparison could not do. If `searchIndexIsConsistent` ever regresses to
    /// comparing counts, this fails.
    @Test("a desynchronised index is detected")
    func detectsDesynchronisation() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["propagation forecast tonight"])
        try desynchronize(harness.store)

        #expect(try Maintenance.searchIndexIsConsistent(harness.store) == false)

        // And the damage is real, not merely bookkeeping: the row exists but
        // cannot be found.
        let hits = try Search.run(harness.store, query: ["unsearchable orphan"],
                                  options: Search.Options())
        #expect(hits.isEmpty)
    }

    /// Guards the specific trap in plan Section 11.2: counting an external content
    /// table reads through to its content table, so the counts are equal by
    /// construction even when the index is broken.
    @Test("row counts cannot detect desynchronisation, which is why they are not used")
    func rowCountsAreVacuous() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["propagation forecast tonight"])
        try desynchronize(harness.store)

        let (segments, ftsRows) = try harness.store.queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments_fts") ?? -2)
        }
        #expect(segments == ftsRows, "counts agree even though the index is broken")
        #expect(try Maintenance.searchIndexIsConsistent(harness.store) == false)
    }

    @Test("rebuild repairs a desynchronised index and makes the text findable")
    func rebuildRepairs() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["propagation forecast tonight"])
        try desynchronize(harness.store)
        #expect(try Maintenance.searchIndexIsConsistent(harness.store) == false)

        try Maintenance.rebuild(harness.store)

        #expect(try Maintenance.searchIndexIsConsistent(harness.store))
        let hits = try Search.run(harness.store, query: ["unsearchable orphan"],
                                  options: Search.Options())
        #expect(hits.count == 1)
    }

    @Test("optimize leaves the index consistent and searchable")
    func optimizeIsSafe() throws {
        let harness = try TestStore()
        for index in 0..<20 {
            try harness.insert(path: "/tmp/file-\(index).m4a",
                               texts: ["antenna tuner number \(index)"])
        }
        try Maintenance.optimize(harness.store)

        #expect(try Maintenance.searchIndexIsConsistent(harness.store))
        #expect(try Search.run(harness.store, query: ["antenna tuner"],
                               options: Search.Options(mode: .phrase, pathFilter: nil, limit: 0))
                .count == 20)
    }

    @Test("health check reports integrity and segment count")
    func healthCheck() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["one", "two", "three"])

        let health = try Maintenance.check(harness.store)
        #expect(health.integrity == "ok")
        #expect(health.isIntact)
        #expect(health.segments == 3)
        #expect(health.searchIndexConsistent)
        #expect(health.isHealthy)
    }

    @Test("health check reports an unhealthy index as unhealthy")
    func healthCheckDetectsProblems() throws {
        let harness = try TestStore()
        try harness.insert(path: "/tmp/a.m4a", texts: ["one"])
        try desynchronize(harness.store)

        let health = try Maintenance.check(harness.store)
        #expect(health.isIntact)          // the SQLite file itself is fine
        #expect(!health.searchIndexConsistent)
        #expect(!health.isHealthy)
    }
}
