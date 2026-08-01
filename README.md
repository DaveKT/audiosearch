# audiosearch

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

**Underway. Not usable yet** — nothing can put anything into the index until M2.

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
  Section 14.1 — this is a known limitation with no vocabulary lever on the platform,
  and the response to it is still an open decision

M1 is complete: the command tree, exit code taxonomy and stream discipline; database
location and library root resolution; the schema with its migration path; and the whole
of search — query translation, BM25 ranking, snippets, and the `text`, `tsv` and `json`
output formats.

M2 is next, and is what makes the tool do anything: transcription, the directory walk,
and indexing. Until then `index`, `prune`, `export` and `doctor` are stubs that exit
telling you which milestone they arrive in.

See plan Section 14 for the full milestone breakdown and Section 16 for tracked risks.

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
swift test
```

Audio test fixtures are generated at test setup via `say`, not committed as binary
assets (plan Section 13.1). Segmentation fixtures recorded from real transcription
runs (`Tests/Fixtures/runs/*.json`) are committed, since they're small JSON and let
segmentation logic be tested without live transcription (Section 13.2).

## Usage

```
audiosearch index [PATHS...]    walk, transcribe and store          (M2)
audiosearch search QUERY        ranked full-text search             built
audiosearch status              index location, size, corpus stats  built
audiosearch prune               drop rows whose files are gone      (M3)
audiosearch export              JSONL dump for backup and recovery  (M4)
audiosearch doctor              locale, assets, permissions, FTS5   (M2)
```

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

Exit codes: `0` success, `1` no matches or partial indexing failure, `2` usage error,
`3` environment error (missing index, missing assets, unsupported locale).

## License

Not yet decided.
