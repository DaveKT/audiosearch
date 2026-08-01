# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

**M0 and M1 are both complete.** M2 (transcription and indexing) is next, with one
decision outstanding that could change what M2 builds — see "Risk 6 is settled" below.

- `Package.swift` — the Section 5.2 manifest, with one deliberate difference: no
  `.unsafeFlags` `__TEXT,__info_plist` linker section, since M0 proved no Speech
  authorization prompt appears (Risk 1). That also resolves Risk 8. Don't add it back
  without evidence that a macOS release started prompting.
- `Sources/audiosearch/` — `main.swift` (command tree + hand-rolled entry point),
  `ExitCode.swift`, `Config.swift`, `Database.swift`, `Search.swift`, `Output.swift`,
  and `Transcriber.swift`. The last holds the M0 spike's validated transcription core
  (run extraction, asset installation, the load-bearing collector-before-analyze
  ordering), moved into its planned home. **Nothing calls it yet** — M2 builds the
  real indexing API around it.
- `index`, `prune`, `export` and `doctor` are stubs that exit 2 naming the milestone
  they land in. `index --set-root` is live, because config resolution was M1's job.
- `Tests/audiosearchTests/` — `ExtractRunsTests` (M0), plus `ConfigTests`,
  `StoreTests`, `SearchTests`, `OutputTests`, `QueryTranslationTests` and the
  `TestStore` harness. 49 tests, all passing, no live transcription in any of them.
- `Tests/Fixtures/` — `say`-generated audio (`known-01.aiff`, `known-02.aiff`,
  `known-02.mp4`/`.mov`, a ~36 min `long-30min.aiff` used for the throughput
  baseline) and `Tests/Fixtures/runs/*.json` recorded `RawRun` fixtures for future
  `Segmenter` tests (plan Section 13.2).

### Risk 6 is settled (measured 2026-08-01, plan Section 14.1)

Measured against a real 2h15m two-speaker podcast, not a `say` fixture. Throughput is
**50.4x real time** and coverage is 100%; general and common-technical accuracy is
excellent (`iPhone`, `macOS`, `Keyboard Maestro`, `Stream Deck` all correct), and there
are **no hallucination loops**. Casing of app names is inconsistent but costs nothing,
since FTS5 folds case.

What does fail: **niche proper nouns**, systematically and *inconsistently* —
`PCalc`→`peacalc`/`peakalc`, `TextSniper`→`tech sniper`/`text sniper`,
`Backblaze`→`Backlaze`, `Sentry`→`Century`, `Myke`→`Mike`, `Snell`→`Snow`. Searching
the correct spelling returns **zero** results, silently. Don't "fix" this by tweaking
`Segmenter` or the schema — it happens upstream of both, inside the OS model, and there
is no vocabulary lever (plan Section 2).

**Decided 2026-08-01: the Apple engine stays.** Rather than substituting an engine, a
new **M6 adds engine *selection*** (`--engine`, a `Transcriber` protocol, whisper as the
first alternative). Through M5 the Apple engine remains the only one — don't build
engine abstraction early, and don't swap the engine out. Section 15 decision 8 (a
query-time alias layer in `Search.swift`) remains unbuilt and is now independent of the
engine question, since every engine mangles some vocabulary.

The plan document remains authoritative — read it before changing course on
architecture, and check it for "resolved in M0" / "resolved in M1" / "confirmed in
M0" notes before assuming something is still an open question. Plan Section 15's
decisions 1, 2 and 6 were resolved while building M1 and are recorded there. Follow
the milestone order (M0 → M1 → … → M7) rather than building out of order. M6 (selectable
transcription engines) and M7 (user manual) were added 2026-08-01 and sit deliberately at
the end: M6 because the Apple engine is staying as the default until the tool is
otherwise finished, M7 because a manual written before the CLI contract settles documents
something that no longer exists.

The repo is public at `https://github.com/DaveKT/audiosearch` (`main` branch). A
top-level `README.md` is the human-facing entry point (status summary, build/test
commands) — keep it in sync with this file and the plan doc rather than letting it
drift. `.gitignore` excludes `.build/`, generated (non-`runs/`) test fixtures, and the
throwaway `scratch/` verification directory (see plan Section 14's GRDB/FTS5 check) —
none of those should end up tracked.

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
schema, indexing, search, or CLI code (plan Risk 6). That isolation is what **M6**
(selectable engines) cashes in — keep it intact even though nothing exercises it before
then.

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
  10.2). Downstream piping (`--format tsv`, `jq`) depends on this. Two consequences
  that look like bugs but aren't: the `N matches` header goes to stderr (it's context,
  not a result), and `--help` goes to stdout (the one deliberate exception).
- **The FTS5 index has no triggers.** `segments_fts` is external-content, populated by
  hand inside the same transaction as the segment insert. Every deletion must issue
  `INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', ?, ?)` with the
  *original* text, before the row leaves `segments`. Deleting a `files` row and letting
  `ON DELETE CASCADE` do the work desynchronises the index permanently — go through
  `Store.replaceFile` / `Store.deleteFile`, never raw SQL.
- **Exit codes are hand-rolled on purpose.** `main.swift` drives `parseAsRoot()` itself
  rather than calling `AudioSearch.main()`, because ArgumentParser exits 64 on a parse
  error where the plan specifies 2. Errors thrown from a command's `validate()` must be
  ArgumentParser's `ValidationError` — it wraps anything else before the entry point's
  handler can see it, and the exit code comes out wrong.

## Build/test

```bash
swift build                       # debug
swift build -c release            # release; ~39x real-time transcription measured this way
swift test                        # runs Tests/audiosearchTests
swift run audiosearch --help      # command tree
swift run audiosearch search "some phrase"   # needs an index; none exists until M2
```

There is no way to populate an index from the CLI until M2 lands. To exercise `search`
or `status` by hand, create the database with `audiosearch index --db <path> --set-root
<dir>`, then seed `files`, `segments` and `segments_fts` with `sqlite3` — remembering
that `segments_fts` is populated explicitly (`INSERT INTO segments_fts(rowid, text)
SELECT id, text FROM segments;`). Tests use the `TestStore` harness instead.

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
