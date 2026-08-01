# audiosearch

[![CI](https://github.com/DaveKT/audiosearch/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/DaveKT/audiosearch/actions/workflows/ci.yml)

A native macOS command-line tool that transcribes a local audio/video library using
Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber`, stores timestamped transcript
segments in SQLite with FTS5, and serves ranked, snippet-bearing full-text search over
them.

It replaces `audio-search.rb`, a Ruby script that shelled out to `ffmpeg` and
`whisper-cli` and wrote loose `.txt` sidecar files. See
[`doc/plans/2026-07-audiosearch-implementation-plan.md`](doc/plans/2026-07-audiosearch-implementation-plan.md)
for the full design: schema, CLI contract, milestone plan, and the reasoning behind
every non-obvious decision. That document is the authoritative spec; this README is
just an entry point.

## Status

**Underway, and usable.** As of M2 the tool indexes a directory and searches it end to
end. It is not yet polished: see the milestone list below for what is still missing.

The M0 spike (throwaway code proving out the riskiest technical assumptions before any
structural work) is complete:

- No Speech authorization prompt appears from a bare CLI binary
- `AVAudioFile` opens `.mov`/`.mp4`/`.mp3` directly — no `AVAssetReader` fallback needed
- Transcript runs are word-level
- FTS5 works through GRDB out of the box
- 50x real-time transcription throughput on a real 2h15m podcast, 100% coverage, no
  hallucination loops
- Accuracy measured against real audio: excellent on general speech and common technical
  vocabulary; **niche proper nouns fail** (`PCalc` → `peacalc`, `Backblaze` → `Backlaze`,
  `Sentry` → `Century`), and searching the correct spelling finds nothing. See plan
  Section 14.1. The platform offers no vocabulary lever, so this is a known limitation
  of the default engine rather than something to be tuned away; the response is M6
  below, not a change to how indexing or search work

M1 is complete: the command tree, exit code taxonomy and stream discipline; database
location and library root resolution; the schema with its migration path; and the whole
of search — query translation, BM25 ranking, snippets, and the `text`, `tsv` and `json`
output formats.

M2 is complete: transcription, the directory walk with its bundle/symlink/iCloud guards,
segmentation, and per-file indexing. `index`, `search`, `status` and `doctor` all work.

The remaining milestones, in order: **M3** incremental indexing, `--dry-run`, interrupt
handling and `prune`, **M4** durability (`export` / `--import`), **M5** polish, **M6**
selectable transcription engines, **M7** a real user manual.

Known rough edges until M3: progress reporting is per-file rather than a progress bar,
`status` does not yet classify stale or missing files, and `prune` and `export` are stubs
that exit telling you which milestone they arrive in.

M6 and M7 sit at the end on purpose. Apple's on-device engine stays the default and the
only engine until the tool is otherwise finished — M6 adds the ability to *choose* a
different one (`--engine`, whisper as the first alternative, prompt conditioning via
`--vocabulary`), which is the response to the accuracy limits above rather than a
replacement of what works. M7 comes last because a manual written before the CLI
contract settles documents something that no longer exists.

See plan Section 14 for the full milestone breakdown, Section 14.1 for the accuracy
measurements, and Section 16 for tracked risks.

## Requirements

- macOS 26 or later, Apple silicon (the Speech framework's on-device transcription is
  not available on Intel Macs)
- Xcode 26 (or matching command line tools) to build

## Building

```bash
swift build              # debug
swift build -c release   # release
```

## Testing

```bash
swift test                                        # unit tests
Scripts/smoke.sh .build/release/audiosearch       # CLI contract against the real binary
```

Audio test fixtures are generated at test setup via `say`, not committed as binary
assets (plan Section 13.1). Segmentation fixtures recorded from real transcription
runs (`Tests/Fixtures/runs/*.json`) are committed, since they're small JSON and let
segmentation logic be tested without live transcription (Section 13.2).

`Scripts/smoke.sh` covers what unit tests structurally can't: the exit-code taxonomy and
the stdout/stderr split, exercised through the actual binary. It needs no speech assets,
which is what lets CI verify something real — the handful of tests that do drive the
analyzer self-skip when models aren't installed, as they are on a GitHub runner.

CI runs on `macos-26` (Apple silicon, Xcode 26.6 pinned) on every push and pull request.
Earlier runner images cannot build this at all: `SpeechAnalyzer` does not exist in their
SDKs.

## Usage

```
audiosearch index [PATHS...]    walk, transcribe and store          built
audiosearch search QUERY        ranked full-text search             built
audiosearch status              index location, size, corpus stats  built
audiosearch doctor              locale, assets, permissions, FTS5   built
audiosearch prune               drop rows whose files are gone      (M3)
audiosearch export              JSONL dump for backup and recovery  (M4)
```

Getting started:

```bash
audiosearch doctor --install-assets      # check the system, download speech assets
audiosearch index ~/Audio/Podcasts       # transcribe and index (roughly 50x real time)
audiosearch search "propagation forecast"
```

Indexing is incremental: a file whose contents have not changed is not retranscribed, so
re-running `index` over a large library is cheap. A file that failed is always retried.
Renaming a file does not cause retranscription, because staleness is keyed on content,
not on the filename.

Search matches your words as a phrase by default — adjacent, in order. Other modes are
explicit rather than folded into one fuzzy flag:

```bash
audiosearch search "software defined radio"
audiosearch search --all corning glass museum     # all terms, any order
audiosearch search --any antenna tuner            # either term
audiosearch search --near 10 antenna tuner        # within ten tokens
audiosearch search --prefix transcei              # prefix match
audiosearch search --raw 'antenna NOT tuner'      # FTS5 syntax, untouched
```

Plus `--path SUBSTR` to restrict to a subtree, `--limit N`, and `--format text|tsv|json`.

Punctuation FTS5 would otherwise read as an operator (`-`, `*`, `:`, `^`, `"`) is
matched literally, so a query pasted from anywhere returns results or nothing — never a
syntax error.

Results go to stdout; the match count, progress and diagnostics go to stderr. Search
exits 1 when nothing matches, following `grep`, so pipes and `||` behave:

```bash
audiosearch search --format tsv "propagation forecast" | cut -f1,2
audiosearch search --format json "propagation forecast" | jq -r '.[0].path'
audiosearch search "nonexistent phrase" || echo "no hits"
```

The index lives at `~/Library/Application Support/audiosearch/index.db`, overridable
with `--db` or `$AUDIOSEARCH_DB`. `audiosearch index --set-root <dir>` records a default
library root so a bare `index` can't accidentally scan your home directory;
`$AUDIOSEARCH_ROOT` overrides it for one run.

Segment size is the main search-quality dial: short segments give precise timestamps but
break phrase matches across rows, long ones do the reverse. Tune with
`index --min-segment`, `--max-segment` and `--silence-gap`, and set the transcription
language with `--locale`. All four persist, so a later run that omits them doesn't
silently change how your corpus is indexed.

If something looks wrong, `audiosearch doctor` checks locale support, speech assets,
database integrity and whether the search index has drifted out of sync with the stored
transcripts; `doctor --repair` rebuilds the search index from those transcripts, which
never re-transcribes anything.

Exit codes: `0` success, `1` no matches or partial indexing failure, `2` usage error,
`3` environment error (missing index, missing assets, unsupported locale).

This section is a summary, and deliberately stays one. A full user manual is M7, at
which point this README shrinks back to an entry point that links to it.

## License

Not yet decided.
