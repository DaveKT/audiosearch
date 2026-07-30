# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

The M0 spike (plan Section 14) is complete except one item pending a real audio
sample (accuracy on jargon/proper nouns, Risk 6). The package builds and runs:

- `Package.swift` — a minimal M0 scaffold: an executable target only, no
  `ArgumentParser`/GRDB dependencies yet. This is deliberately smaller than the target
  manifest in plan Section 5.2 — widen it to that shape when M1 begins.
- `Sources/audiosearch/main.swift` — throwaway spike code (asset installation,
  transcription, run extraction). Expect this to be deleted/rewritten once M1 starts;
  don't build on top of it.
- `Tests/audiosearchTests/ExtractRunsTests.swift` — unit tests for `extractRuns`
  against the SDK's real `AttributeScopes.SpeechAttributes.TimeRangeAttribute`.
- `Tests/Fixtures/` — `say`-generated audio (`known-01.aiff`, `known-02.aiff`,
  `known-02.mp4`/`.mov`, a ~36 min `long-30min.aiff` used for the throughput
  baseline) and `Tests/Fixtures/runs/*.json` recorded `RawRun` fixtures for future
  `Segmenter` tests (plan Section 13.2).

The plan document remains authoritative — read it before changing course on
architecture, and check it for "resolved in M0" / "confirmed in M0" notes before
assuming something is still an open question. Follow the milestone order (M0 → M1 →
M2 → M3 → M4 → M5) rather than building out of order; M1 (schema, CLI, search) has
not started yet.

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

## Planned architecture

Five subcommands share one SQLite database, canonical-path-keyed and independent of
invocation directory: `index [PATHS...]`, `search QUERY`, `status`, `prune`,
`export`, `doctor`. See plan Section 5 for the full command tree and Section 5.1 for
the intended file layout (`Transcriber.swift`, `AudioInput.swift`, `Segmenter.swift`,
`Walker.swift`, `Indexer.swift`, `Search.swift`, `Database.swift`, etc.) — one file
per concern, with framework-specific code isolated to `Transcriber.swift` and
`AudioInput.swift` so the transcription engine can be swapped later without touching
schema, indexing, search, or CLI code (plan Risk 6).

Key design decisions worth knowing before touching related code:

- **A single input path handles both audio and video** — confirmed in M0:
  `AVAudioFile` opens `.mov`/`.mp4` directly, including files with a real encoded
  video track. The `AVAssetReader` → `AsyncStream<AnalyzerInput>` fallback (Section
  7.2) is documented but not built; video support ships in M2, not M5.
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

## Build/test

```bash
swift build                       # debug
swift build -c release            # release; ~39x real-time transcription measured this way
swift test                        # runs Tests/audiosearchTests
swift run audiosearch <path>       # M0 spike: transcribes one file, prints runs, writes <path>.runs.json
```

Eventual install step, once M1+ exists (plan Section 10.4): `cp
.build/release/audiosearch /usr/local/bin/`.

Audio fixtures are generated, not committed as source — `say -o Tests/Fixtures/*.aiff
"..."` produces deterministic audio with known expected transcripts (Section 13.1).
`Tests/Fixtures/runs/*.json` recorded `RawRun` fixtures **are** committed, since
they're small JSON and let `Segmenter` be tested in isolation without live
transcription once it's written (Section 13.2).

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

## Running subtask agents

When spinning up an agent to work on a subtask (e.g. a background implementation or
research task), launch it inside a named `tmux` session rather than backgrounding it
directly, so its progress can be attached to and monitored instead of only seen after
it finishes:

```bash
tmux new-session -d -s <task-name> '<command>'
tmux attach -t <task-name>     # monitor output; detach with Ctrl-b d
tmux ls                        # list in-flight task sessions
tmux kill-session -t <task-name>  # clean up once the task is done
```

Name the session after the task so multiple concurrent agents stay identifiable.
