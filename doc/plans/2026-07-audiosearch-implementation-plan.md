Plan: Audiosearch Implementation
===============================================================================

> Status: Planning

Native macOS command line utility for transcribing and searching a local audio and video
library. Replaces `audio-search.rb`, a Ruby script that shelled out to `ffmpeg` and
`whisper-cli` and wrote loose `.txt` sidecar files.

---

## 1. Objective

A single self-contained binary that:

- Transcribes local audio and video files using Apple's `SpeechAnalyzer` and
  `SpeechTranscriber`
- Stores timestamped transcript segments in SQLite with FTS5 full text search
- Returns ranked, timestamped, snippet-bearing results rather than bare filenames
- Re-indexes incrementally based on content hash, not filename presence
- Operates independently of the current working directory
- Preserves transcription work in a form recoverable without re-analysis
- Requires no external binary, no model file, and no network access at steady state

## 2. Platform assumptions and accepted constraints

The design depends on the Speech framework introduced in macOS 26, which performs
on-device transcription using models the operating system ships and manages. This choice
removes the need to vendor a model file, link a C++ inference library, or implement audio
decode and resampling. Inference runs on the Neural Engine, which is materially more power
efficient than GPU-based alternatives for long batches on a laptop.

Constraints accepted as a consequence, recorded so they are not rediscovered later:

- **Hard floor at macOS 26 on Apple silicon.** Intel Macs cannot run these APIs on device.
- **No custom vocabulary.** `SpeechAnalyzer` provides no equivalent of `contextualStrings`
  or of prompt conditioning. Proper nouns, callsigns, place names, and technical jargon
  get no lever. See Risk 6.
- **No model pinning.** Operating system updates may alter transcripts, and the index
  cannot detect this reliably. See Section 6.2 and Risk 2.
- **No model selection.** A larger or more accurate model is not selectable as an escape
  hatch for difficult audio.
- **Permanent platform lock-in.** The transcription layer is Apple-only by construction.

## 3. Non-goals

- Speaker diarization (a `SpeechDetector` module exists; diarization does not)
- Real time or streaming transcription
- Windows or Linux support
- Distribution to third parties (no notarization work in scope)
- Locale support beyond `en` (configurable, untested)

## 4. Requirements derived from the predecessor script

The Ruby script contained defects that the new design must close structurally rather than
patch. Each row is a design requirement, not a bug report.

| Defect in `audio-search.rb` | Structural resolution |
| --- | --- |
| Fuzzy mode matched every file (`next` skipped the inner loop only) | FTS5 `AND` query; no hand written match predicate exists |
| Default search was not whole word despite the documented intent | FTS5 tokenizer handles term boundaries |
| Multi word matches could not cross line breaks | Segments stored as rows; matching is per segment, not per line |
| Only `ARGV[1]` was used, silently discarding unquoted query terms | `ArgumentParser` collects trailing arguments into the query |
| Sidecar files written to the working directory, basenames collided | Single database at a fixed data path; canonicalized absolute paths as keys |
| Shell interpolation permitted injection and broke on apostrophes | No subprocess exists in the indexing or search path |
| Exit status of external tools was never checked | Typed Swift errors; failed files are recorded, not silently emptied |
| A zero byte transcript permanently suppressed retry | Staleness keyed on content hash plus engine identity, with explicit `failed` and `empty` states |
| Temporary WAV files leaked on interrupt | No intermediate file exists |
| Model path hardcoded to one user's home directory | No model path exists |
| Extension hardcoded to `.mp3`, case sensitive | Extension allowlist with case folding, covering audio and video containers |
| Search results printed a bare basename, not an openable path | Results carry canonical path, timestamp, and matched text |

## 5. Architecture

```
audiosearch index [PATHS...]    walk -> stat gate -> hash -> analyze -> segment -> store
audiosearch search QUERY        FTS5 MATCH -> BM25 rank -> path + timestamp + snippet
audiosearch status              corpus stats, stale entries, missing files, failures
audiosearch prune               remove rows whose files are confirmed gone
audiosearch export              emit JSONL of files and segments for recovery
audiosearch doctor              locale support, assets, permissions, FTS5, integrity
```

### 5.1 Package layout

```
Package.swift
Sources/audiosearch/
  main.swift             ArgumentParser command tree, exit codes
  Config.swift           database location, defaults, environment overrides
  Database.swift         GRDB setup, migrations, insert and query
  Maintenance.swift      FTS5 optimize and rebuild, integrity checks
  Transcriber.swift      SpeechAnalyzer wrapper, asset installation
  AudioInput.swift       input path selection, audio vs video containers
  Segmenter.swift        AttributedString runs -> merged segments
  Walker.swift           directory enumeration, guards, availability checks
  Indexer.swift          staleness determination, orchestration
  Search.swift           query translation, ranking
  Output.swift           text, tsv, and json emitters; stream discipline
  Hashing.swift          streaming content hash
  ExitCode.swift         exit code taxonomy
Tests/audiosearchTests/
  Fixtures/              generated at test setup, not committed
Resources/Info.plist     embedded via linker section, see 10.3
```

### 5.2 Package manifest

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "audiosearch",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "audiosearch", targets: ["audiosearch"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "audiosearch",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "audiosearchTests", dependencies: ["audiosearch"]),
    ]
)
```

Notes:

- **Tools version 5.10 is deliberate.** Declaring 6.0 enables strict concurrency checking
  across the whole target. `AVAudioFile` is not `Sendable`, `SpeechAnalyzer` carries its
  own actor isolation, and the concurrent collection pattern in Section 7.3 crosses
  isolation boundaries. Fighting those diagnostics before the tool works is the wrong
  ordering. Migration to Swift 6 language mode is an M5 task, and may be done per-file
  via `.enableUpcomingFeature` settings rather than wholesale.
- `.macOS("26.0")` string form avoids depending on whether the toolchain exposes a
  `.v26` enum case.
- `.unsafeFlags` blocks the package from being consumed as a dependency by others. That
  is acceptable for a leaf executable but should be revisited if the core is ever split
  into a library target. See Risk 8.
- Only two external dependencies, both statically linked by SPM, so the single binary
  property holds. Everything else comes from the SDK: `Speech`, `AVFoundation`,
  `CoreMedia`, `CryptoKit`, `Foundation`.
- GRDB provides migrations, FTS5 virtual table declaration, and prepared statement
  ergonomics. Direct `import SQLite3` is a viable zero-dependency fallback at the cost of
  roughly 200 lines of C interop boilerplate.

## 6. Schema

```sql
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- seeded with schema_version, min_segment, max_segment, silence_gap_ms, locale

CREATE TABLE files (
  id          INTEGER PRIMARY KEY,
  path        TEXT NOT NULL UNIQUE,   -- canonicalized absolute
  hash        TEXT NOT NULL,          -- SHA-256 of file bytes, streamed
  size        INTEGER NOT NULL,
  mtime       INTEGER NOT NULL,
  duration    REAL,                   -- seconds, populated during indexing
  locale      TEXT NOT NULL,          -- bcp47, e.g. "en-US"
  engine      TEXT NOT NULL,          -- see 6.2
  status      TEXT NOT NULL,          -- 'ok' | 'empty' | 'failed'
  error       TEXT,                   -- populated when status='failed'
  indexed_at  INTEGER NOT NULL
);

CREATE TABLE segments (
  id      INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  t0_ms   INTEGER NOT NULL,
  t1_ms   INTEGER NOT NULL,
  text    TEXT NOT NULL
);
CREATE INDEX idx_segments_file_t0 ON segments(file_id, t0_ms);

CREATE VIRTUAL TABLE segments_fts USING fts5(
  text,
  content='segments',
  content_rowid='id',
  tokenize='porter unicode61'
);
```

Notes on the non-obvious choices:

- The composite index on `(file_id, t0_ms)` rather than `file_id` alone exists because
  `--context N` retrieves ordered neighbors of a matched segment. An index on `file_id`
  alone forces a sort on every context expansion.
- `duration` is populated during indexing (Section 7.2), not left null. `status` reports
  total corpus hours from it, and `--dry-run` estimates batch time from it.
- `status='empty'` distinguishes "analysis succeeded, no speech present" from "analysis
  failed." A music track, a silent recording, and a defective analysis are otherwise
  indistinguishable, which is the structural analogue of the Ruby script's zero-byte
  transcript problem.
- External content FTS5 avoids duplicating transcript text. Population is explicit
  (`INSERT INTO segments_fts(rowid, text)`) inside the same transaction as the segment
  insert, rather than by trigger, since writes occur only during indexing.

`PRAGMA journal_mode = WAL` and `PRAGMA foreign_keys = ON` are set at open.

Hashing uses `CryptoKit.SHA256` streamed in 1 MB chunks. Video files in the corpus may be
multiple gigabytes and must not be read into memory.

### 6.1 Persisted parameters

Segmentation parameters feed the engine identity string, so an `index` invocation that
omits them after a prior run used them would mark the entire corpus stale. To prevent
this, `min_segment`, `max_segment`, `silence_gap_ms`, and `locale` are written to `meta`
on first use and become the defaults for subsequent runs. Explicit flags override and
rewrite the stored value, and `status` reports the effective values.

### 6.2 Engine identity

Because the transcription model is managed by the operating system, no exact model
identifier is available to store. The closest available proxy is a composite string:

```
speech/<macOS build version>/<locale>/<segmenter revision>
```

for example `speech/26C61/en-US/seg2`. The macOS build version is readable without a
subprocess from `/System/Library/CoreServices/SystemVersion.plist`. The segmenter
revision is derived from the persisted parameters in 6.1 plus a hardcoded version integer
bumped whenever segmentation logic changes.

This is a heuristic. It over-invalidates, since most operating system updates do not
change the speech models, and it may under-invalidate if assets update independently of
the build. The practical consequence is that engine mismatch must not silently
retranscribe an entire corpus:

- Engine mismatch marks rows stale in `status` reporting only
- Retranscription of stale-by-engine rows requires explicit `--reindex-stale`
- Content hash mismatch always retranscribes, with no prompt

## 7. Transcription

### 7.1 Asset installation

Model assets are managed by the operating system but are not necessarily present.
`doctor` and the first `index` run must handle installation.

```swift
func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let bcp47 = locale.identifier(.bcp47)

    guard await SpeechTranscriber.supportedLocales
        .contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
        throw AudioSearchError.unsupportedLocale(bcp47)
    }

    let installed = await SpeechTranscriber.installedLocales
        .contains { $0.identifier(.bcp47) == bcp47 }

    if !installed {
        if let request = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    _ = try await AssetInventory.reserve(locale: locale)
}
```

`AssetInventory` caps the number of concurrently reserved locales. A single-locale tool
will not reach the cap, but `doctor` should surface reservation state rather than failing
opaquely. Asset installation requires network access and must fail fast at the start of a
batch rather than mid-run.

### 7.2 Input paths and duration

Two distinct input paths are required, and which one applies must be resolved in M0.

**Audio containers.** `AVAudioFile(forReading:)` opens the file directly and is passed to
`analyzer.analyzeSequence(from:)`. Duration is `Double(file.length) /
file.processingFormat.sampleRate`.

**Video containers.** `AVAudioFile` is documented for audio files. If it does not open
`.mov` and `.mp4`, a second input path is required: `AVURLAsset` plus `AVAssetReader` over
the first audio track, converted to the format returned by
`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, fed through an
`AsyncStream<AnalyzerInput>` to `analyzer.start(inputSequence:)`. Duration comes from
`try await asset.load(.duration)`.

This is a material fork in the implementation. M0 must determine which case holds. If the
`AVAssetReader` path is required, video support moves to M5 rather than M2, and the
extension allowlist ships audio-only in the first working version. See Risk 9.

### 7.3 Analysis

Batch file analysis, one file at a time. `volatileResults` is deliberately omitted;
partial results are meaningless for indexing and only add work.

```swift
func transcribe(url: URL, locale: Locale) async throws -> [RawRun] {
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let audioFile = try AVAudioFile(forReading: url)

    // The result collector MUST be established before analyzeSequence is awaited,
    // or results are dropped. See Tests/audiosearchTests/OrderingTests.swift.
    async let collected: [RawRun] = {
        var runs: [RawRun] = []
        for try await result in transcriber.results where result.isFinal {
            runs.append(contentsOf: extractRuns(from: result.text))
        }
        return runs
    }()

    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        await analyzer.cancelAndFinishNow()
    }

    return try await collected
}
```

### 7.4 Run extraction

`SpeechTranscriber.Result.text` is an `AttributedString`, not a `String`. Timing arrives
as `CMTimeRange` values on runs carrying the `audioTimeRange` attribute.

```swift
struct RawRun: Codable {
    let text: String
    let startMS: Int
    let endMS: Int
}

func extractRuns(from attributed: AttributedString) -> [RawRun] {
    var out: [RawRun] = []
    for run in attributed.runs {
        guard let range = run.audioTimeRange else { continue }
        let text = String(attributed[run.range].characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        out.append(RawRun(
            text: text,
            startMS: Int(CMTimeGetSeconds(range.start) * 1000),
            endMS: Int(CMTimeGetSeconds(range.end) * 1000)
        ))
    }
    return out
}
```

`RawRun` is `Codable` specifically so that recorded runs can serve as segmentation test
fixtures (Section 13.2).

The exact attribute accessor spelling and the scope import required to reach it must be
confirmed against the SDK during M0. This is the most likely place for the code above to
need adjustment.

### 7.5 Segmentation

Speech framework runs are fine grained, potentially word level, and the caller owns
segment construction. Segment size is the primary search-quality parameter: short
segments give precise timestamps but break phrase matches across rows, while long
segments do the reverse.

Segmentation rules, in priority order:

1. Break after sentence-terminating punctuation (`.`, `?`, `!`) once the accumulated
   segment exceeds `min_segment` (default 40 characters)
2. Break when the accumulated segment reaches `max_segment` (default 240 characters)
3. Break on a gap between runs exceeding `silence_gap_ms` (default 800)

`t0_ms` is the start of the first run in the segment, `t1_ms` the end of the last.
Segmentation is pure and deterministic: it takes `[RawRun]` and parameters, and returns
`[Segment]`, with no framework dependency. This is a testability requirement, not an
incidental property.

Word-level timing is discarded at this stage. Retaining it would allow sub-segment
playback offsets at roughly a tenfold increase in row count. Deferred; see Section 15.

## 8. Indexing

### 8.1 Directory walk

`FileManager.enumerator` with explicit guards, since an unguarded walk of a home directory
will descend into application bundles and photo libraries and can hang on symlink loops:

```swift
let keys: [URLResourceKey] = [
    .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    .isSymbolicLinkKey, .ubiquitousItemDownloadingStatusKey,
    .isUbiquitousItemKey, .volumeURLKey,
]
let options: FileManager.DirectoryEnumerationOptions = [
    .skipsHiddenFiles,
    .skipsPackageDescendants,
]
```

Symlinks are not followed. Extension matching is case folded against an allowlist:
`mp3`, `m4a`, `m4b`, `aac`, `wav`, `aiff`, `aif`, `flac`, `caf`, `mp4`, `mov`, `m4v`.
Video extensions are conditional on the outcome of Section 7.2.

**iCloud dataless files.** Files evicted from local storage exist as stubs. Reading them
either blocks on a download or fails unpredictably mid-batch. Check
`ubiquitousItemDownloadingStatusKey` during the walk and classify:

- `.current`: index normally
- `.downloaded`: index normally
- not downloaded: skip and report as `unavailable`, unless `--materialize` is passed, in
  which case call `startDownloadingUbiquitousItem` and wait with a timeout

### 8.2 Staleness gate

Cheap checks before expensive work:

```swift
if let row = try db.lookup(path: canonical) {
    if row.status == "ok" || row.status == "empty",
       row.engine == engineID,
       row.size == attrs.size,
       row.mtime == attrs.mtime {
        return .unchanged
    }
    if row.status == "ok" || row.status == "empty",
       row.engine == engineID,
       row.hash == try Hashing.sha256(of: canonical) {
        try db.touch(id: row.id, mtime: attrs.mtime)
        return .touchedOnly           // renamed or copied, content identical
    }
}
```

Rows with `status='failed'` always fall through to retranscription, which is the specific
behavior the Ruby script lacked.

### 8.3 Persistence

Per-file work is wrapped in a single transaction that deletes prior segments before
inserting new ones, so re-indexing replaces rather than appends:

```swift
try await dbQueue.write { db in
    let fileID = try Database.upsertFile(db, record)
    try Database.deleteSegments(db, fileID: fileID)
    for segment in segments {
        let rowID = try Database.insertSegment(db, fileID: fileID, segment)
        try Database.insertFTS(db, rowID: rowID, text: segment.text)
    }
}
```

GRDB's write closure is synchronous even under the `async` entry point, and its return
value must be `Sendable`. The exact signature and any required isolation annotations must
be confirmed in M1; mixing GRDB's concurrency model with the `async` transcription path is
the second most likely source of compiler friction after the input path fork.

At the end of a batch that inserted more than a threshold number of segments:

```sql
INSERT INTO segments_fts(segments_fts) VALUES('optimize');
```

### 8.4 Concurrency

Default to serial. The Neural Engine is a shared resource and concurrent analyzers are
expected to serialize rather than scale, but this is an empirical question rather than a
settled one. A `--jobs N` flag defaulting to 1 permits measurement without a code change.
Hashing and directory walking may run concurrently with analysis regardless, since they
are IO bound.

`--verbose` emits per-file elapsed time and real-time factor to stderr. Without this the
concurrency question cannot be answered empirically, and the segment bound tuning in
Section 15 has no measurement basis.

### 8.5 Failure isolation and interruption

A decode or analysis error records `status='failed'` with the error description and
continues to the next file. `index` returns exit code 1 if any file failed. Failed rows
are retried on the next run.

A `SIGINT` handler cancels the current analysis task and closes the database cleanly.
Because each file commits independently, an interrupted run leaves a consistent index
containing every file completed to that point.

### 8.6 Dry run

`index --dry-run` performs the walk and the staleness gate, then reports what would be
transcribed and an estimated wall clock time derived from stored `duration` values and a
measured real-time factor. No analysis is performed and no writes occur. This is cheap to
implement and avoids committing to a multi-hour batch blind.

## 9. Search

```sql
SELECT f.path, s.t0_ms, s.t1_ms,
       snippet(segments_fts, 0, '[', ']', '...', 12) AS snip,
       bm25(segments_fts) AS score
FROM segments_fts
JOIN segments s ON s.id = segments_fts.rowid
JOIN files    f ON f.id = s.file_id
WHERE segments_fts MATCH ?
ORDER BY score
LIMIT ?;
```

| Flag | FTS5 expression |
| --- | --- |
| default | `"term1 term2"` (phrase, adjacent) |
| `--any` | `term1 OR term2` |
| `--all` | `term1 AND term2` |
| `--near N` | `NEAR(term1 term2, N)` |
| `--prefix` | `term*` |
| `--raw` | pass the user string through untouched |

Sanitization is mandatory. FTS5 defines its own operator syntax, so bare `-`, `*`, `:`,
`^`, and `"` in user input produce a parse error rather than zero results. Default
behavior tokenizes the input and quotes each term; `--raw` is the escape hatch for users
wanting FTS5 syntax directly.

Additional filters: `--path SUBSTR`, `--limit N`, `--context N` for adjacent segments
around each hit, `--after` and `--before` on file mtime.

## 10. CLI contract, configuration, permissions, distribution

### 10.1 Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, with at least one result where results apply |
| 1 | No search matches, or partial failure during indexing |
| 2 | Usage error (bad flags, unparseable query) |
| 3 | Environment error (assets missing, locale unsupported, database unreadable, FTS5 absent) |

Returning 1 for no matches follows the `grep` convention and makes shell composition
predictable.

### 10.2 Stream discipline

Stdout carries only results: search output in the selected format, and `export` JSONL.
Everything else goes to stderr: progress bars, scan counts, warnings, prompts, and
`status` and `doctor` output. Without this rule, the `--format tsv` piping in Section 12.4
breaks. Progress rendering is suppressed automatically when stderr is not a TTY.

### 10.3 Paths and permissions

Resolution order for the database, highest precedence first: `--db <path>`, then
`AUDIOSEARCH_DB`, then `~/Library/Application Support/audiosearch/index.db`, constructed
from `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)`.

Storing canonicalized absolute paths (`URL.resolvingSymlinksInPath().standardized`) makes
the index independent of invocation directory.

**Speech recognition authorization.** The older `SFSpeechRecognizer` required
`NSSpeechRecognitionUsageDescription` in an `Info.plist` and an explicit authorization
prompt. `SpeechAnalyzer` is on-device only, and existing command line tools using it ship
as plain Homebrew binaries, which suggests file-based analysis does not require the
prompt. If it does, a bare executable has no bundle from which to read a plist, and the
fix is to embed one in a `__TEXT,__info_plist` linker section as shown in Section 5.2.

**File access.** Reading from `~/Documents`, `~/Desktop`, or `~/Downloads` triggers TCC
against the calling process, meaning the terminal application rather than `audiosearch`.
This is normal command line behavior and requires documentation rather than a solution.
`doctor` must detect and report `EPERM` on the configured library root rather than
reporting zero files found.

### 10.4 Build

```bash
swift build -c release
cp .build/release/audiosearch /usr/local/bin/
```

No external build toolchain, no model download, no universal binary step. The Swift
runtime ships in macOS, so the binary is self-contained. Xcode 26 or the matching command
line tools are required to build.

A Homebrew tap formula is the natural distribution step if the tool is ever shared.
Locally built binaries require no signing; downloaded binaries trigger Gatekeeper
quarantine, for which ad hoc signing is insufficient and notarization requires a
Developer ID. Both remain out of scope.

## 11. Durability and recovery

Transcription is the expensive, irreversible work in this system. A corpus representing
many hours of compute must not exist solely inside one SQLite file.

### 11.1 Export

`audiosearch export` emits JSONL to stdout, one object per file with its segments nested.
The format is sufficient to rebuild the entire index without re-analysis:

```
{"path":"...","hash":"...","duration":1878.4,"locale":"en-US","engine":"speech/26C61/en-US/seg2","status":"ok","segments":[{"t0":872340,"t1":876100,"text":"..."}]}
```

`audiosearch index --import <file.jsonl>` is the inverse, matching by content hash so that
moved files re-associate correctly.

### 11.2 FTS5 maintenance

External content FTS5 tables can desync from the content table. Two operations, both
cheap relative to retranscription:

```sql
INSERT INTO segments_fts(segments_fts) VALUES('optimize');   -- after large batches
INSERT INTO segments_fts(segments_fts) VALUES('rebuild');    -- doctor --repair
```

`doctor` runs `PRAGMA integrity_check` and compares `COUNT(*)` between `segments` and
`segments_fts`, reporting a mismatch and recommending `--repair`.

### 11.3 Prune safety

Prune is the only destructive operation and must not run on incomplete information.

An absent path has three distinct causes, and only one justifies deletion:

- **Deleted.** The containing volume is mounted and the path does not exist. Eligible.
- **Unreachable.** The containing volume is not mounted. External drives and network
  shares fall here. Never eligible.
- **Evicted.** An iCloud stub that reports as present but dataless. Never eligible.

Resolution uses `volumeURLKey` recorded at index time, compared against currently mounted
volumes from `FileManager.mountedVolumeURLs`. Rows on unmounted volumes are reported
separately as unreachable and are excluded from the deletion set. `prune` requires `--yes`
when the eligible set exceeds 10 percent of indexed files, and `--dry-run` is available.

## 12. User-facing behavior

### 12.1 First run

```
$ audiosearch doctor
Database:  ~/Library/Application Support/audiosearch/index.db (not yet created)
Locale:    en-US (supported, assets not installed)
Install speech assets now? [Y/n] y
Downloading ... done
FTS5:      available
Integrity: n/a (no index yet)
Library:   not configured (set AUDIOSEARCH_ROOT or pass paths to index)
```

No model file is downloaded and no model path is configured. Speech assets are installed
once by the operating system and shared with every other application on the system.

### 12.2 Indexing

```
$ audiosearch index --dry-run ~/Audio/Podcasts
Scanning ... 412 audio files found
  388 unchanged, 21 new, 3 modified, 2 unavailable (not downloaded from iCloud)
Would transcribe 24 files, 11h 38m of audio.
Estimated time: 24m at the last measured rate (28x real time).
```

```
$ audiosearch index ~/Audio/Podcasts ~/Video/Talks
Scanning ... 412 audio files, 38 video files found
  388 unchanged, 24 new, 3 modified

Transcribing 27 files (en-US)
[00:03:41] ####################------------  15/27  ep-207.mp3  (31m18s)
```

A second run over an unchanged tree performs no analysis:

```
$ audiosearch index ~/Audio/Podcasts
Scanning ... 412 audio files found
  412 unchanged, 0 new, 0 modified
Nothing to do.
```

Renaming a file causes rehashing but not retranscription, since the content is unchanged.
Editing a file causes retranscription. A file that fails is reported and retried on the
next run rather than being silently marked complete.

### 12.3 Searching

Results carry a path, a timestamp, and the matched text in context, ranked by relevance:

```
$ audiosearch search "software defined radio"
3 matches

~/Audio/Podcasts/ham-nation/ep-207.mp3
  00:14:32  ...getting started with [software] [defined] [radio] is cheaper than...
  00:41:07  ...the [software] [defined] [radio] sitting on my desk right now...

~/Audio/Recordings/hamfest-2025-panel.m4a
  01:02:55  ...panel on [software] [defined] [radio] and where the hobby is...
```

Match modes are explicit rather than implied by a single fuzzy flag:

```
$ audiosearch search --all corning glass museum        # all terms, any order
$ audiosearch search --near 10 antenna tuner           # within ten tokens
$ audiosearch search --prefix transcei                 # prefix match
$ audiosearch search --path Recordings meeting notes   # restrict to a subtree
```

### 12.4 Composing with other tools

```
$ audiosearch search --format tsv "propagation forecast"
~/Audio/Podcasts/ep-198.mp3	00:22:04	...tonight's [propagation] [forecast] looks...

$ audiosearch search --format json "propagation forecast" | jq -r '.[0].path'

$ audiosearch search "nonexistent phrase" || echo "no hits"
no hits
```

Playback jumps directly to the matched offset:

```
$ audiosearch search --play 1 "propagation forecast"
Playing ~/Audio/Podcasts/ep-198.mp3 at 00:22:04
```

### 12.5 Maintenance

```
$ audiosearch status
Index:      ~/Library/Application Support/audiosearch/index.db (34 MB)
Engine:     speech/26C61/en-US/seg2
Segmenting: min 40, max 240, silence gap 800ms
Files:      412 indexed, 3 empty, 1 failed, 0 stale
Segments:   186,204
Audio:      291h 14m
Missing:    6 deleted, 14 unreachable (volume /Volumes/Archive not mounted)

$ audiosearch status --failed
~/Audio/Recordings/corrupt-take.m4a   decode error: unsupported codec parameters

$ audiosearch status --empty
~/Audio/Music/instrumental-set.m4a    analysis returned no speech

$ audiosearch prune --dry-run
Would remove 6 files and 2,914 segments.
Excluded: 14 files on unmounted volume /Volumes/Archive.

$ audiosearch export > ~/Backups/audiosearch-2026-07-30.jsonl
```

After an operating system update, some files report as stale. Retranscription is opt-in,
because the staleness signal is a heuristic rather than a guarantee:

```
$ audiosearch status
Engine:     speech/26D48/en-US/seg2
Files:      412 indexed, 1 failed, 412 stale (engine changed from 26C61)
Run 'audiosearch index --reindex-stale' to retranscribe.
```

## 13. Testing strategy

### 13.1 Generated audio fixtures

No binary assets are committed. The `say` command produces deterministic audio from known
text at test setup:

```bash
say -o Tests/Fixtures/known-01.aiff "the quick brown fox jumps over the lazy dog"
say -o Tests/Fixtures/known-02.aiff "propagation forecast for the eastern seaboard"
say -o Tests/Fixtures/silent.aiff ""
```

This gives end-to-end tests with expected transcripts, a known-empty case for
`status='empty'`, and no repository bloat. Fixture generation is a make target and a test
setup precondition.

### 13.2 Segmentation tested in isolation

Segmentation is deterministic; transcription is not. Testing segment boundaries through
the full Speech framework path makes failures slow, flaky, and ambiguous about which layer
broke.

`RawRun` is `Codable` for this reason. Record run arrays from real analysis once, commit
them as JSON, and test `Segmenter` against them directly:

```
Tests/Fixtures/runs/podcast-excerpt.json
Tests/Fixtures/runs/rapid-speech.json
Tests/Fixtures/runs/long-pauses.json
```

Segment boundary logic is the most likely place for silent regressions, and this makes
those tests fast and unambiguous.

### 13.3 Other test surfaces

- **Query sanitization.** Table-driven cases over adversarial inputs (`foo -bar "baz`,
  `a:b`, `*`, `^x`, empty string) asserting no error and correct FTS5 translation.
- **Staleness gate.** Synthetic `files` rows exercising every branch: unchanged, touched
  only, content changed, engine changed, previously failed.
- **Ordering.** An explicit test that the Section 7.3 collector-before-analyze ordering is
  preserved, since inverting it silently returns empty transcripts.
- **Prune classification.** Injected volume state asserting that unreachable rows are
  never in the deletion set.
- **Round trip.** `export` followed by `index --import` into an empty database reproduces
  identical segment content.

## 14. Milestones

### M0: Spike (one day, before any structural work)

A throwaway `main.swift`, no persistence, no CLI parsing. Every item is a question whose
answer changes later sections.

- Transcribe one audio file from a bare executable with no application bundle
- Confirm whether an authorization prompt appears, and whether it can be satisfied
- **Determine whether `AVAudioFile` opens `.mov` and `.mp4`.** If not, prototype the
  `AVAssetReader` path and move video support to M5 (Section 7.2, Risk 9)
- Extract `audioTimeRange` from result runs; determine actual run granularity and record
  it, since Section 7.5 depends on the answer
- Confirm the system SQLite exposed through GRDB has FTS5 compiled in
- Time a 30 minute file end to end for a throughput baseline
- Transcribe a sample representative of the real corpus and assess accuracy on proper
  nouns and domain jargon, per Risk 6
- Record one set of `RawRun` output as the first segmentation fixture

If FTS5 is absent from system SQLite, substitute a GRDB configuration with bundled SQLite
before M1.

### M1: Skeleton, schema, search (no transcription)

- `ArgumentParser` command tree, exit code taxonomy, stream discipline
- Config resolution, schema creation, `schema_version` migration path, persisted
  parameters in `meta`
- Insert and query paths for files and segments
- Complete search implementation: query translation, ranking, all three output formats

Acceptance: synthetic segments inserted by a test fixture round trip correctly; all query
modes return correct ranked results; snippet output renders; adversarial inputs do not
error; no-match returns exit code 1; results appear on stdout with nothing else.

### M2: Transcription and indexing

- `Transcriber.swift`, `AudioInput.swift`, and `Segmenter.swift` per Section 7
- Asset installation and `doctor`
- `Walker.swift` with package, symlink, and iCloud guards
- Serial per-file indexing with per-file transactions, duration capture

Acceptance: end to end index and search over a real directory; filenames containing
apostrophes, spaces, and non-ASCII characters index correctly; an application bundle in
the tree is not descended into; a silent fixture yields `status='empty'`, not `'ok'`.

### M3: Incremental behavior and robustness

- Staleness gate, content hashing, `touchedOnly` path
- Failure recording, retry on next run, exit code 1 on partial failure
- `SIGINT` handling, progress reporting, `--verbose` timing, `--dry-run`
- `status` with full classification, `prune` with volume safety

Acceptance: a second `index` run over an unchanged tree performs no analysis; renaming a
file does not retranscribe; editing a file does; interrupting mid run leaves a consistent
index; a deliberately corrupt file is recorded as failed and retried; prune excludes rows
on an unmounted volume.

### M4: Durability

- `export` and `index --import`
- FTS5 optimize after batches, `doctor --repair` with rebuild and integrity check

Acceptance: export, delete the database, import, and search returns identical results.

M1 through M4 constitute the working tool, at roughly 900 lines of Swift.

### M5: Polish and migration

- Video container support, if M0 determined a second input path is required
- `--play` integration (`afplay`, or `mpv --start=` when present)
- `--context`, `--after` and `--before`, `--materialize`
- Shell completions via `ArgumentParser` completion script generation
- Swift 6 language mode migration, per-file via upcoming feature flags
- Optional sidecar export (Section 15, decision 5)

## 15. Open decisions

1. **Default query mode.** Phrase matching is least surprising. Affects muscle memory, so
   decide before M1 ships.
2. **Result grouping.** One row per matching segment, or segments grouped under a file
   heading with the path printed once.
3. **Segment bounds.** Defaults of 40 and 240 characters are starting points. Tune against
   a real corpus in M3 using `--verbose` measurements, since the values materially change
   phrase match recall.
4. **Word-level timestamps.** Retaining per-word timing enables exact playback offsets and
   word-level highlighting at roughly a tenfold row count increase. Deferrable without a
   schema break by adding a nullable `words` JSON column to `segments` later.
5. **Sidecar export.** Section 11.1 covers recovery. A separate question is whether
   transcripts should also be written as individual text files, making them visible to
   Spotlight and to any document management tool indexing the same tree. Writing into a
   single dedicated directory keyed by content hash, rather than beside the source audio,
   captures the benefit without the basename collisions of the Ruby script.
6. **`index` with no path argument.** Current working directory, or a configured library
   root. A configured root removes a class of accidental large scans.
7. **Empty-file retry policy.** `status='empty'` currently behaves like `'ok'` for
   staleness. Whether an engine change should retry empty files more eagerly than
   successful ones is unresolved.

## 16. Risks

| # | Risk | Mitigation |
| --- | --- | --- |
| 1 | Speech authorization required from a bundle-less CLI | Resolved in M0; fallback is an embedded `__TEXT,__info_plist` section, already wired into the manifest |
| 2 | Operating system update silently changes transcripts; the index cannot detect it reliably | Engine identity string (Section 6.2); mismatch reports as stale rather than triggering automatic retranscription; `export` preserves prior transcripts regardless |
| 3 | System SQLite lacks FTS5 through GRDB | Verified in M0; fallback is a GRDB configuration with bundled SQLite, at the cost of binary size only |
| 4 | Run granularity finer or coarser than assumed, invalidating Section 7.5 | Measured in M0 before `Segmenter.swift` is written |
| 5 | Speech framework API churn across macOS 26.x point releases | All framework use isolated in `Transcriber.swift` and `AudioInput.swift`; integration tests against generated fixtures |
| 6 | Accuracy shortfall on jargon, proper nouns, and callsigns, with no vocabulary lever | Measured against a representative sample in M0. If unacceptable, substitute a whisper-based transcription module supporting prompt conditioning; the substitution is confined to `Transcriber.swift`, `AudioInput.swift`, and `Segmenter.swift`, since Sections 6, 8, 9, 10, and 11 are engine independent |
| 7 | Asset download required on first run in an offline environment | `doctor` reports asset state explicitly; `index` fails fast with exit code 3 rather than mid-batch |
| 8 | `.unsafeFlags` blocks future extraction of a library target | Revisit only if a library target becomes necessary; the plist section can move to a build script instead |
| 9 | `AVAudioFile` does not open video containers, requiring a second `AVAssetReader` input path | Determined in M0. If confirmed, video extensions are removed from the M2 allowlist and the feature moves to M5. Audio-only remains fully functional |
| 10 | Swift 6 strict concurrency conflicts with non-`Sendable` framework types and GRDB's model | Tools version pinned at 5.10 for M0 through M4; migration is an M5 task with per-file upcoming feature flags |
| 11 | Prune deletes rows for files on a temporarily unmounted volume | Volume mount state checked against `mountedVolumeURLs` (Section 11.3); unreachable rows excluded from the deletion set and reported separately; `--yes` required above a 10 percent threshold |
| 12 | Long batch lost to database corruption | `export` provides a rebuildable artifact; `doctor --repair` handles FTS5 desync without retranscription |