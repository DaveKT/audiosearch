import ArgumentParser
import Foundation

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
        version: "0.1.0-m1",
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

struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Transcribe and index audio and video files.",
        discussion: """
            With no PATHS, indexes the configured library root. Set one with \
            --set-root, or override it for a single run with \
            $\(Config.libraryRootEnvironmentKey). Requiring a configured root \
            rather than defaulting to the working directory removes a class of \
            accidental multi-hour scans.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: ArgumentHelp("Files or directories to index.", valueName: "paths"))
    var paths: [String] = []

    @Option(name: .long, help: ArgumentHelp("Persist PATH as the default library root, then exit.", valueName: "path"))
    var setRoot: String?

    func run() throws {
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
        Streams.errLine("would index: \(targets.map(Config.abbreviatingHome).joined(separator: ", "))")
        throw NotImplemented(command: "index", milestone: "M2")
    }

    /// Resolved here rather than in M2 because path resolution is M1's job; the
    /// walk and the transcription that consume it are not.
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

        if counts.segments != counts.ftsRows {
            Streams.errLine("")
            Streams.errLine("Warning:    search index desynchronised "
                          + "(\(counts.segments) segments, \(counts.ftsRows) indexed).")
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

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check locale support, assets, permissions, FTS5 and integrity."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws {
        throw NotImplemented(command: "doctor", milestone: "M2")
    }
}

// MARK: - Entry point

// Hand-rolled rather than `AudioSearch.main()` so that the plan's exit code
// taxonomy (Section 10.1) holds on every path: ArgumentParser would otherwise
// exit 64 on a usage error. Help and version text stay on stdout, the one
// deliberate exception to Section 10.2 — `--help | less` is universal.
do {
    var command = try AudioSearch.parseAsRoot()
    try command.run()
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
