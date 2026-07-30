# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

This repository currently contains a single design document,
`audiosearch Implementation Plan Swift v2.md`, and no Swift source yet — no
`Package.swift`, no `Sources/` tree, no tests, no git history. There is nothing to
build, lint, or run yet. Before writing any code, read the full plan document; it is
the authoritative spec and supersedes any summary below if the two ever disagree.

When implementation begins, follow the milestone order in the plan's Section 14 (M0
spike → M1 skeleton/search → M2 transcription/indexing → M3 incremental
robustness → M4 durability → M5 polish) rather than building features out of order —
several M0 questions (see below) determine whether later sections are even buildable
as written.

## What audiosearch is

A native macOS command-line tool that transcribes a local audio/video library with
Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber`, stores timestamped transcript
segments in SQLite with FTS5, and serves ranked, snippet-bearing full-text search
over them. It replaces a Ruby script (`audio-search.rb`) that shelled out to `ffmpeg`
and `whisper-cli`; the plan's Section 4 maps each defect in that script to a
structural fix in the new design (e.g. shell-interpolation injection → no subprocess
in the indexing/search path; silent zero-byte transcripts → explicit `failed`/`empty`
status states).

Hard platform floor: macOS 26 on Apple silicon (Speech framework requirement). No
custom vocabulary/prompt conditioning, no model pinning, no model selection — these
are accepted constraints, not oversights (plan Section 2).

## Planned architecture (once code exists)

Five subcommands share one SQLite database, canonical-path-keyed and independent of
invocation directory: `index [PATHS...]`, `search QUERY`, `status`, `prune`,
`export`, `doctor`. See plan Section 5 for the full command tree and Section 5.1 for
the intended file layout (`Transcriber.swift`, `AudioInput.swift`, `Segmenter.swift`,
`Walker.swift`, `Indexer.swift`, `Search.swift`, `Database.swift`, etc.) — one file
per concern, with framework-specific code isolated to `Transcriber.swift` and
`AudioInput.swift` so the transcription engine can be swapped later without touching
schema, indexing, search, or CLI code (plan Risk 6).

Key design decisions worth knowing before touching related code:

- **Two divergent transcription input paths are likely required**: `AVAudioFile`
  directly for audio containers, but video (`.mov`/`.mp4`) may need a separate
  `AVAssetReader` → `AsyncStream<AnalyzerInput>` path (Section 7.2). Which case holds
  is an M0 question that determines whether video support ships in M2 or moves to M5.
- **Segmentation is pure and deterministic** (`[RawRun]` + parameters → `[Segment]`),
  deliberately decoupled from the Speech framework so it can be unit tested against
  recorded fixtures rather than through live transcription (Section 7.5, 13.2).
  `RawRun` is `Codable` specifically to support this.
  - Segmentation gap in this rewrite: staleness is keyed on **content hash + engine
    identity**, not filename, and `status='failed'` rows always retry on the next run
    (unlike the predecessor's zero-byte-suppresses-retry bug).
- **Engine identity is a heuristic string** (`speech/<macOS build>/<locale>/<segmenter
  revision>`, Section 6.2) because no exact model identifier is exposed by the OS.
  Engine mismatch marks rows stale for *reporting* only; retranscription is always
  opt-in (`--reindex-stale`), never automatic.
- **`swift-tools-version: 5.10` is deliberate**, not an oversight — declaring 6.0 would
  turn on strict concurrency checking that conflicts with non-`Sendable` types
  (`AVAudioFile`) and GRDB's model before the tool even works. Swift 6 migration is
  explicitly deferred to M5, per-file, via upcoming-feature flags (Section 5.2, Risk
  10).
- **Prune is the only destructive operation** and must distinguish deleted (eligible),
  unreachable/unmounted-volume (never eligible), and iCloud-evicted (never eligible)
  files before removing rows (Section 11.3).
- Stream discipline is load-bearing: stdout carries only `search`/`export` output;
  everything else (progress, warnings, `status`, `doctor`) goes to stderr (Section
  10.2). Downstream piping (`--format tsv`, `jq`) depends on this.

## Build/test (once the package exists)

Not yet runnable. The plan specifies (Section 10.4):

```bash
swift build -c release
cp .build/release/audiosearch /usr/local/bin/
```

Test fixtures are generated, not committed — `say -o Tests/Fixtures/*.aiff "..."`
produces deterministic audio with known expected transcripts at test setup (Section
13.1). Segmentation is tested in isolation against committed JSON `RawRun` fixtures
rather than through live transcription, since transcription is non-deterministic and
segmentation is not (Section 13.2).

## Writing plans

For any project that is a discrete local Git repository, you will find a
`doc/plans/` directory. If you do not find one, you may create it.

Within this directory, we write our dev plans in markdown files with names that
are prefixed with the year-and-month of creation. Some example file names:

* 2026-01-logging-refactor.md
* 2026-01-token-exchange-authentication.md

When entering plan mode, the system suggests a plan file with a random name.
Ignore the random name. Instead, create the plan file directly at the correct
`YYYY-MM-short-description.md` path in `doc/plans/` using the Write tool.

The first heading should be "Plan: " followed by the name in _Title Case_,
followed by a "Status:" callout. eg:

```
Plan: Token Exchange Authentication
===============================================================================

> Status: Planning

…
```

Valid statuses include: Planning, Underway, Complete.

Feel free to use Mermaid diagrams in plans to explain concepts and flows
visually.

When marking a plan as Complete, replace implementation code blocks with a
short prose summary of the functional/visual change. Don't duplicate code
that's now in the codebase. Leave diagrammatic code-blocks in place.

Once marked as "Complete", the plan can be moved into the doc/plans/archive/
subdirectory.
