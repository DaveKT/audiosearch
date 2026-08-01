import ArgumentParser
import Foundation

// MARK: - Async dispatch

/// Async commands implement `execute()`, never `run()` directly.
///
/// `AsyncParsableCommand` inherits a *synchronous* `run()` from `ParsableCommand`,
/// and its default implementation throws a help request. When the command is held
/// as an existential — which it is, because `parseAsRoot()` returns
/// `ParsableCommand` — overload resolution picks that synchronous witness over the
/// async requirement, so `try await command.run()` prints the help screen and
/// exits 0 instead of doing the work. That is not a theory: `doctor` did exactly
/// this before the indirection below, and the only warning was "no 'async'
/// operations occur within 'await' expression".
///
/// A uniquely named method has no overload set, so it cannot be resolved wrongly.
/// Any new async subcommand must conform here rather than overriding `run()`.
protocol AsyncCommand: AsyncParsableCommand {
    mutating func execute() async throws
}

extension AsyncCommand {
    mutating func run() async throws {
        try await execute()
    }
}

// MARK: - Shared options

struct GlobalOptions: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Index database path.",
            discussion: "Overrides $\(Config.databaseEnvironmentKey) and the default "
                      + "~/Library/Application Support/audiosearch/index.db."
        )
    )
    var db: String?

    func openStore() throws -> Store {
        try Store.open(at: try Config.databaseURL(explicit: db))
    }

    func openExistingStore() throws -> Store {
        try Store.openExisting(at: try Config.databaseURL(explicit: db))
    }
}

// MARK: - Root

struct AudioSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audiosearch",
        abstract: "Transcribe a local audio and video library and search it full-text.",
        discussion: """
            Transcription runs entirely on device via Apple's Speech framework. \
            Results go to stdout; progress, warnings and diagnostics go to stderr, \
            so search output pipes cleanly.
            """,
        version: "0.1.0-m2",
        subcommands: [Index.self, SearchCommand.self, Status.self, Prune.self, Export.self, Doctor.self],
        defaultSubcommand: nil
    )
}

// MARK: - search

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search indexed transcripts.",
        discussion: """
            By default the words you supply are matched as a phrase: adjacent, in \
            order. Match modes are explicit rather than folded into one fuzzy flag.

            Input is tokenized and quoted before it reaches FTS5, so punctuation \
            that FTS5 treats as operators (- * : ^ ") is matched literally instead \
            of raising a syntax error. Use --raw to write FTS5 expressions directly.

            Exits 1 when nothing matches, following grep.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: ArgumentHelp("Words to search for.", valueName: "query"))
    var query: [String] = []

    @Flag(name: .long, help: "Match any of the terms.")
    var any = false

    @Flag(name: .long, help: "Match all terms, in any order.")
    var all = false

    @Flag(name: .long, help: "Match terms as prefixes.")
    var prefix = false

    @Flag(name: .long, help: "Pass the query to FTS5 untouched.")
    var raw = false

    @Option(name: .long, help: ArgumentHelp("Match terms within N tokens of each other.", valueName: "N"))
    var near: Int?

    @Option(name: .long, help: ArgumentHelp("Only search files whose path contains SUBSTR.", valueName: "substr"))
    var path: String?

    @Option(name: .long, help: ArgumentHelp("Maximum results; 0 for unlimited.", valueName: "n"))
    var limit: Int = 20

    @Option(name: .long, help: "Output format.")
    var format: OutputFormat = .text

    // ArgumentParser calls validate() during parsing and wraps whatever it throws,
    // so an AudiosearchError raised here would never reach the handler in this
    // file. ValidationError is the type it understands; the entry point remaps its
    // exit code from ArgumentParser's 64 to the plan's 2.
    func validate() throws {
        let selected = [any, all, prefix, raw].filter { $0 }.count + (near == nil ? 0 : 1)
        guard selected <= 1 else {
            throw ValidationError("choose at most one of --any, --all, --near, --prefix, --raw")
        }
        if let near, near < 0 {
            throw ValidationError("--near expects a non-negative token distance")
        }
        guard limit >= 0 else {
            throw ValidationError("--limit expects a non-negative count")
        }
        guard !query.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("no query given")
        }
    }

    var mode: MatchMode {
        if raw { return .raw }
        if any { return .any }
        if all { return .all }
        if prefix { return .prefix }
        if let near { return .near(near) }
        return .phrase
    }

    func run() throws {
        let store = try global.openExistingStore()
        let hits = try Search.run(
            store,
            query: query,
            options: Search.Options(mode: mode, pathFilter: path, limit: limit)
        )

        guard !hits.isEmpty else {
            if format == .text {
                Streams.errLine("no matches")
            }
            throw Exit.noResults
        }

        // The match count is context, not a result, so it goes to stderr: it
        // renders identically in a terminal but never lands in a pipe.
        if format == .text {
            Streams.errLine("\(hits.count) match\(hits.count == 1 ? "" : "es")\n")
        }
        Streams.out(try Output.render(hits, as: format))
    }
}

// MARK: - index

struct Index: AsyncCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Transcribe and index audio and video files.",
        discussion: """
            With no PATHS, indexes the configured library root. Set one with \
            --set-root, or override it for a single run with \
            $\(Config.libraryRootEnvironmentKey). Requiring a configured root \
            rather than defaulting to the working directory removes a class of \
            accidental multi-hour scans.

            Segmentation parameters and locale persist after first use, so a later \
            run that omits them does not silently change how the corpus is indexed. \
            Passing them explicitly overrides and rewrites the stored value.

            A file whose contents are unchanged is not retranscribed. A file that \
            previously failed is always retried.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: ArgumentHelp("Files or directories to index.", valueName: "paths"))
    var paths: [String] = []

    @Option(name: .long, help: ArgumentHelp("Persist PATH as the default library root, then exit.", valueName: "path"))
    var setRoot: String?

    @Option(name: .long, help: ArgumentHelp("BCP-47 locale to transcribe in.", valueName: "id"))
    var locale: String?

    @Option(name: .long, help: ArgumentHelp("Minimum characters before a sentence break splits a segment.", valueName: "n"))
    var minSegment: Int?

    @Option(name: .long, help: ArgumentHelp("Maximum characters in a segment.", valueName: "n"))
    var maxSegment: Int?

    @Option(name: .long, help: ArgumentHelp("Silence in milliseconds that forces a segment break.", valueName: "ms"))
    var silenceGap: Int?

    @Flag(name: .long, help: "Suppress progress output.")
    var quiet = false

    func validate() throws {
        if let minSegment, minSegment < 0 {
            throw ValidationError("--min-segment expects a non-negative count")
        }
        if let maxSegment, maxSegment < 1 {
            throw ValidationError("--max-segment expects a positive count")
        }
        if let minSegment, let maxSegment, minSegment >= maxSegment {
            throw ValidationError("--min-segment must be smaller than --max-segment")
        }
        if let silenceGap, silenceGap < 0 {
            throw ValidationError("--silence-gap expects a non-negative duration")
        }
    }

    func execute() async throws {
        let store = try global.openStore()

        if let setRoot {
            let canonical = Config.canonicalPath(setRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw AudiosearchError.usage("not a directory: \(canonical)")
            }
            try store.setMeta(Store.MetaKey.libraryRoot, canonical)
            Streams.errLine("library root set to \(Config.abbreviatingHome(canonical))")
            return
        }

        let targets = try resolveTargets(store)

        // Explicit flags override the stored values and rewrite them, so the two
        // never disagree (Section 6.1).
        if let locale { try store.setMeta(Store.MetaKey.locale, locale) }
        if let minSegment { try store.setMeta(Store.MetaKey.minSegment, String(minSegment)) }
        if let maxSegment { try store.setMeta(Store.MetaKey.maxSegment, String(maxSegment)) }
        if let silenceGap { try store.setMeta(Store.MetaKey.silenceGapMS, String(silenceGap)) }

        let stored = try store.parameters()
        let transcriber = Transcriber(localeIdentifier: stored.locale)
        let indexer = Indexer(
            store: store,
            transcriber: transcriber,
            parameters: SegmentationParameters(stored),
            engine: Transcriber.engineIdentity(locale: transcriber.bcp47),
            progress: ProgressReporter(quiet: quiet)
        )

        let outcome = try await indexer.run(roots: targets)
        report(outcome)

        // Exit 1 on partial failure, so a scripted run can tell the difference
        // between "indexed everything" and "indexed most things" (Section 10.1).
        if outcome.hadFailures { throw Exit.noResults }
    }

    private func report(_ outcome: Indexer.Outcome) {
        guard !quiet else { return }
        var parts = ["\(outcome.transcribed) transcribed"]
        if outcome.empty > 0 { parts.append("\(outcome.empty) empty") }
        if outcome.skipped > 0 { parts.append("\(outcome.skipped) unchanged") }
        if outcome.failed > 0 { parts.append("\(outcome.failed) failed") }
        if outcome.unavailable > 0 { parts.append("\(outcome.unavailable) unavailable") }
        if outcome.missing > 0 { parts.append("\(outcome.missing) not found") }

        Streams.errLine("")
        Streams.errLine(parts.joined(separator: ", ") + ".")
        if outcome.failed > 0 {
            Streams.errLine("Failed files are retried on the next run.")
        }
    }

    private func resolveTargets(_ store: Store) throws -> [String] {
        if !paths.isEmpty {
            return paths.map(Config.canonicalPath)
        }
        let stored = try store.meta(Store.MetaKey.libraryRoot)
        guard let root = Config.libraryRoot(stored: stored) else {
            throw AudiosearchError.usage(
                """
                no paths given and no library root configured
                Set one with 'audiosearch index --set-root <dir>', or pass paths explicitly.
                """
            )
        }
        return [root]
    }
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report index location, size, and corpus statistics."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws {
        let store = try global.openExistingStore()
        let counts = try store.counts()
        let parameters = try store.parameters()
        let root = Config.libraryRoot(stored: try store.meta(Store.MetaKey.libraryRoot))

        // All of this is diagnostics, so all of it goes to stderr (Section 10.2).
        Streams.errLine("Index:      \(Config.abbreviatingHome(store.url.path)) "
                      + "(\(Output.byteSize(store.fileSizeOnDisk)))")
        Streams.errLine("Schema:     v\(try store.meta(Store.MetaKey.schemaVersion) ?? "?")")
        if let root {
            Streams.errLine("Root:       \(Config.abbreviatingHome(root))")
        }
        let engines = try store.engines()
        if !engines.isEmpty {
            Streams.errLine("Engine:     \(engines.joined(separator: ", "))")
        }
        Streams.errLine("Segmenting: min \(parameters.minSegment), max \(parameters.maxSegment), "
                      + "silence gap \(parameters.silenceGapMS)ms, locale \(parameters.locale)")
        Streams.errLine("Files:      \(counts.files) indexed, "
                      + "\(counts.byStatus[.empty] ?? 0) empty, "
                      + "\(counts.byStatus[.failed] ?? 0) failed")
        Streams.errLine("Segments:   \(counts.segments)")
        Streams.errLine("Audio:      \(Output.duration(seconds: counts.totalDuration))")

        if !(try Maintenance.searchIndexIsConsistent(store)) {
            Streams.errLine("")
            Streams.errLine("Warning:    search index is out of sync with the stored "
                          + "transcripts.")
            Streams.errLine("            Run 'audiosearch doctor --repair'.")
        }

        // Stale, missing and unreachable classification needs the staleness gate
        // and recorded volume state, both of which land in M3.
        Streams.errLine("")
        Streams.errLine("Stale, missing and failure detail arrive in M3.")
    }
}

// MARK: - Not yet implemented

struct Prune: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove rows whose files are confirmed gone."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws {
        throw NotImplemented(command: "prune", milestone: "M3")
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Emit the index as JSONL for backup and recovery."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws {
        throw NotImplemented(command: "export", milestone: "M4")
    }
}

struct Doctor: AsyncCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check locale support, assets, permissions, FTS5 and integrity.",
        discussion: """
            Reports rather than guesses. An unreadable library root is reported as \
            a permission problem, not as an empty corpus.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Rebuild the search index if it has desynchronised.")
    var repair = false

    @Flag(name: .long, help: "Install speech assets if they are missing.")
    var installAssets = false

    func execute() async throws {
        let databaseURL = try Config.databaseURL(explicit: global.db)
        let exists = FileManager.default.fileExists(atPath: databaseURL.path)

        Streams.errLine("Database:  \(Config.abbreviatingHome(databaseURL.path))"
                      + (exists ? "" : " (not yet created)"))

        // Opening creates and migrates, which is itself the check that the
        // location is writable and that the schema applies.
        let store: Store
        do {
            store = try Store.open(at: databaseURL)
        } catch let error as AudiosearchError {
            Streams.errLine("           unusable: \(error.message)")
            throw error
        }

        let locale = try store.meta(Store.MetaKey.locale) ?? Store.Defaults.locale
        let transcriber = Transcriber(localeIdentifier: locale)

        var problems: [String] = []

        // Assets.
        let assets = await transcriber.assetState()
        if !assets.supported {
            Streams.errLine("Locale:    \(transcriber.bcp47) (NOT SUPPORTED on this system)")
            problems.append("locale \(transcriber.bcp47) is not supported")
        } else if !assets.installed {
            Streams.errLine("Locale:    \(transcriber.bcp47) (supported, assets not installed)")
            if installAssets {
                Streams.errLine("           downloading ...")
                try await transcriber.prepareAssets()
                Streams.errLine("           done")
            } else {
                problems.append("speech assets are not installed "
                              + "(run 'audiosearch doctor --install-assets')")
            }
        } else {
            Streams.errLine("Locale:    \(transcriber.bcp47) (supported, assets installed"
                          + (assets.reserved ? ", reserved)" : ", NOT reserved)"))
            if !assets.reserved {
                problems.append("speech assets could not be reserved")
            }
        }

        // FTS5 and integrity.
        let health = try Maintenance.check(store)
        Streams.errLine("FTS5:      available")
        Streams.errLine("Integrity: \(health.integrity)")
        if !health.isIntact { problems.append("database integrity check failed") }

        if health.searchIndexConsistent {
            Streams.errLine("Index:     \(health.segments) segments, in sync")
        } else {
            Streams.errLine("Index:     \(health.segments) segments — OUT OF SYNC "
                          + "(some transcripts are not searchable)")
            if repair {
                Streams.errLine("           rebuilding ...")
                try Maintenance.rebuild(store)
                let repaired = try Maintenance.searchIndexIsConsistent(store)
                Streams.errLine("           \(repaired ? "repaired" : "still out of sync")")
                if !repaired { problems.append("search index could not be rebuilt") }
            } else {
                problems.append("search index is out of sync (run 'audiosearch doctor --repair')")
            }
        }

        // Library root, and whether it can actually be read. Reporting EPERM is
        // the whole point: "0 files found" for a root you lack permission to read
        // is a lie (Section 10.3).
        let root = Config.libraryRoot(stored: try store.meta(Store.MetaKey.libraryRoot))
        if let root {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) {
                Streams.errLine("Library:   \(Config.abbreviatingHome(root)) (MISSING)")
                problems.append("library root does not exist")
            } else if !FileManager.default.isReadableFile(atPath: root) {
                Streams.errLine("Library:   \(Config.abbreviatingHome(root)) (NOT READABLE)")
                problems.append("library root is not readable — grant your terminal "
                              + "Full Disk Access, or move the library")
            } else {
                Streams.errLine("Library:   \(Config.abbreviatingHome(root))")
            }
        } else {
            Streams.errLine("Library:   not configured "
                          + "(set with 'audiosearch index --set-root', or pass paths)")
        }

        guard problems.isEmpty else {
            Streams.errLine("")
            for problem in problems { Streams.errLine("  problem: \(problem)") }
            throw Exit.environment
        }
    }
}

// MARK: - Entry point

// Hand-rolled rather than `AudioSearch.main()` so that the plan's exit code
// taxonomy (Section 10.1) holds on every path: ArgumentParser would otherwise
// exit 64 on a usage error. Help and version text stay on stdout, the one
// deliberate exception to Section 10.2 — `--help | less` is universal.
do {
    var command = try AudioSearch.parseAsRoot()
    // `index` and `doctor` are async; `search` and `status` are not. Driving both
    // by hand is the cost of owning the exit codes.
    if var asyncCommand = command as? AsyncCommand {
        try await asyncCommand.execute()
    } else {
        try command.run()
    }
    exit(Exit.success.rawValue)
} catch let error as AudiosearchError {
    Streams.errLine("audiosearch: \(error.message)")
    exit(error.code.rawValue)
} catch let error as NotImplemented {
    Streams.errLine("audiosearch: \(error.description)")
    exit(Exit.usage.rawValue)
} catch let code as ExitCode {
    exit(code.rawValue)
} catch {
    let parserCode = AudioSearch.exitCode(for: error)
    let message = AudioSearch.fullMessage(for: error)

    if parserCode == .success {
        if !message.isEmpty { Streams.outLine(message) }
        exit(Exit.success.rawValue)
    }

    if !message.isEmpty { Streams.errLine(message) }
    // 64 is ArgumentParser's EX_USAGE; anything else reaching here is an
    // unexpected runtime failure, which is closest to an environment error.
    exit(parserCode.rawValue == 64 ? Exit.usage.rawValue : Exit.environment.rawValue)
}
