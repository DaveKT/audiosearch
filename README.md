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

**Underway.** The M0 spike (throwaway code proving out the riskiest technical
assumptions before any structural work) is complete, with one item still open:

- No Speech authorization prompt appears from a bare CLI binary
- `AVAudioFile` opens `.mov`/`.mp4` directly — no `AVAssetReader` fallback needed
- Transcript runs are word-level
- FTS5 works through GRDB out of the box
- ~39x real-time transcription throughput measured on Apple silicon
- Still open: accuracy on proper nouns/jargon, pending a representative real-world
  audio sample

M1 (CLI skeleton, schema, search — no transcription yet) has not started. See plan
Section 14 for the full milestone breakdown and Section 16 for tracked risks.

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

## Running the M0 spike

Structural code (CLI parsing, persistence, search) doesn't exist yet. The current
`Sources/audiosearch/main.swift` is throwaway spike code that transcribes a single
file and prints/records the result:

```bash
swift run audiosearch path/to/file.aiff
```

## License

Not yet decided.
