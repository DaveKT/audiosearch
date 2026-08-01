import Foundation

/// Walk, transcribe, segment, store (plan Section 8).
///
/// Scope note. M2 owns the walk, transcription, segmentation and per-file
/// persistence; M3 owns the staleness gate, `--dry-run`, `SIGINT` handling,
/// `--verbose` timing and full `status` classification. Three M3 items are
/// nonetheless present here in minimal form, deliberately:
///
/// - **Content hashing**, because `files.hash` is `NOT NULL` and a row cannot be
///   written without it. The *gate* built on it is still M3.
/// - **A same-hash skip**, because without it every run retranscribes the whole
///   corpus, and a two-hour file costs minutes each time. This is the crude
///   version: M3 adds the `stat`-first `touchedOnly` path, engine-staleness
///   reporting and `--reindex-stale`.
/// - **Failure isolation**, because one unreadable file would otherwise abort a
///   multi-hour batch. M3 adds retry policy reporting around it.
struct Indexer {
    let store: Store
    let transcriber: Transcriber
    let parameters: SegmentationParameters
    let engine: String
    var progress: ProgressReporter

    struct Outcome {
        var transcribed = 0
        var skipped = 0
        var empty = 0
        var failed = 0
        var unavailable = 0
        var missing = 0
        var segmentsWritten = 0

        /// Exit 1 on partial failure, per Section 10.1.
        var hadFailures: Bool { failed > 0 }
    }

    /// Optimizing after every small batch costs more than it saves.
    static let optimizeThreshold = 1000

    func run(roots: [String]) async throws -> Outcome {
        var outcome = Outcome()

        let scan = Walker.walk(roots: roots)
        outcome.unavailable = scan.unavailable.count
        outcome.missing = scan.missing.count

        for missing in scan.missing {
            progress.warn("not found: \(Config.abbreviatingHome(missing))")
        }
        for unavailable in scan.unavailable {
            progress.warn("skipped \(Config.abbreviatingHome(unavailable.path)): \(unavailable.reason.rawValue)")
        }

        progress.scanned(files: scan.files.count)

        // Decide what needs work before touching the network or the models, so a
        // no-op run stays a no-op.
        var pending: [(file: Walker.Found, hash: String)] = []
        for found in scan.files {
            do {
                let hash = try Hashing.sha256(contentsOf: URL(fileURLWithPath: found.path))
                if try isUpToDate(path: found.path, hash: hash) {
                    outcome.skipped += 1
                } else {
                    pending.append((found, hash))
                }
            } catch {
                record(failure: error, path: found.path, size: found.size,
                       mtime: found.mtime, into: &outcome)
            }
        }

        guard !pending.isEmpty else {
            progress.nothingToDo(skipped: outcome.skipped)
            return outcome
        }

        // Fail fast, before a long batch rather than partway into one (Risk 7).
        try await transcriber.prepareAssets {
            progress.warn("downloading speech assets for \(transcriber.bcp47)...")
        }

        progress.starting(count: pending.count, locale: transcriber.bcp47)

        for (position, item) in pending.enumerated() {
            progress.beginFile(index: position, of: pending.count, path: item.file.path)
            do {
                let written = try await indexOne(file: item.file, hash: item.hash, into: &outcome)
                outcome.segmentsWritten += written
            } catch {
                record(failure: error, path: item.file.path, size: item.file.size,
                       mtime: item.file.mtime, into: &outcome)
            }
        }

        if outcome.segmentsWritten > Self.optimizeThreshold {
            try Maintenance.optimize(store)
        }

        return outcome
    }

    // MARK: - One file

    private func indexOne(
        file: Walker.Found,
        hash: String,
        into outcome: inout Outcome
    ) async throws -> Int {
        let url = URL(fileURLWithPath: file.path)
        let audio = try AudioInput.open(url)
        let duration = AudioInput.duration(of: audio)

        let runs = try await transcriber.transcribe(file: audio)
        let segments = Segmenter.segment(runs, parameters: parameters)

        // Analysis succeeded but found no speech. This is NOT a failure, and
        // conflating the two is the defect Section 4 exists to remove: a music
        // track, a silent recording and a broken decode must stay distinguishable.
        let status: FileStatus = segments.isEmpty ? .empty : .ok
        if status == .empty { outcome.empty += 1 } else { outcome.transcribed += 1 }

        let record = FileRecord(
            id: nil,
            path: file.path,
            hash: hash,
            size: file.size,
            mtime: file.mtime,
            duration: duration,
            locale: transcriber.bcp47,
            engine: engine,
            status: status,
            error: nil,
            indexedAt: Int64(Date().timeIntervalSince1970)
        )

        // One transaction per file, so an interrupted run leaves a consistent
        // index containing every file completed to that point (Section 8.5).
        try store.replaceFile(record, segments: segments.map {
            SegmentRecord(id: nil, fileID: 0, t0MS: $0.t0MS, t1MS: $0.t1MS, text: $0.text)
        })

        progress.finishedFile(path: file.path, duration: duration,
                              segments: segments.count, status: status)
        return segments.count
    }

    /// Crude precursor to the M3 staleness gate: same bytes, same engine, and not
    /// a previous failure. `status='failed'` deliberately never counts as up to
    /// date — the predecessor script's zero-byte transcripts suppressed their own
    /// retry, and that bug is not being reproduced.
    private func isUpToDate(path: String, hash: String) throws -> Bool {
        guard let existing = try store.file(path: path) else { return false }
        return existing.hash == hash
            && existing.engine == engine
            && existing.status != .failed
    }

    private func record(
        failure: Error,
        path: String,
        size: Int64,
        mtime: Int64,
        into outcome: inout Outcome
    ) {
        let message = describe(failure)
        outcome.failed += 1
        progress.failed(path: path, message: message)

        // Recorded rather than merely reported, so `status --failed` can list it
        // and the next run retries it. An empty hash is deliberate: it can never
        // equal a real digest, so the retry can never be skipped.
        let record = FileRecord(
            id: nil, path: path, hash: "", size: size, mtime: mtime, duration: nil,
            locale: transcriber.bcp47, engine: engine, status: .failed,
            error: message, indexedAt: Int64(Date().timeIntervalSince1970)
        )
        do {
            try store.replaceFile(record, segments: [])
        } catch {
            // The database itself is failing. Say so rather than reporting a
            // clean run that recorded nothing.
            progress.warn("could not record failure for \(path): \(error.localizedDescription)")
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let error as AudioInput.DecodeError: return error.description
        case let error as TranscriberError: return error.description
        case let error as AudiosearchError: return error.message
        default: return error.localizedDescription
        }
    }
}

// MARK: - Progress

/// Progress goes to stderr and is suppressed when stderr is not a TTY, so piping
/// search output stays clean (Section 10.2).
///
/// M3 replaces the per-file lines with the progress bar in Section 12.2 and adds
/// `--verbose` real-time factors.
struct ProgressReporter {
    var enabled: Bool = Streams.stderrIsTTY
    var quiet: Bool = false

    func warn(_ message: String) {
        guard !quiet else { return }
        Streams.errLine("audiosearch: \(message)")
    }

    func scanned(files: Int) {
        guard !quiet else { return }
        Streams.errLine("Scanning ... \(files) indexable file\(files == 1 ? "" : "s") found")
    }

    func nothingToDo(skipped: Int) {
        guard !quiet else { return }
        Streams.errLine("  \(skipped) unchanged, 0 new")
        Streams.errLine("Nothing to do.")
    }

    func starting(count: Int, locale: String) {
        guard !quiet else { return }
        Streams.errLine("")
        Streams.errLine("Transcribing \(count) file\(count == 1 ? "" : "s") (\(locale))")
    }

    func beginFile(index: Int, of total: Int, path: String) {
        guard enabled, !quiet else { return }
        Streams.errLine("  [\(index + 1)/\(total)] \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    func finishedFile(path: String, duration: Double, segments: Int, status: FileStatus) {
        guard enabled, !quiet else { return }
        let detail = status == .empty
            ? "no speech found"
            : "\(segments) segment\(segments == 1 ? "" : "s")"
        Streams.errLine("          \(Output.duration(seconds: duration)) audio, \(detail)")
    }

    func failed(path: String, message: String) {
        guard !quiet else { return }
        Streams.errLine("  failed: \(Config.abbreviatingHome(path)) — \(message)")
    }
}
