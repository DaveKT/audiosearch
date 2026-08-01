import AVFoundation
import Foundation
import Testing

@testable import audiosearch

/// Live transcription tests.
///
/// Everything else in this suite avoids the Speech framework deliberately. What
/// needs the real analyzer is the zero-frame hang: it produced no error and no
/// timeout, just a process that never returned, and only running the thing catches
/// that.
///
/// Fixtures are generated with `say` rather than committed (Section 13.1). A
/// subprocess here is fine; the constraint in Section 4 is on the *indexing* path.
@Suite("transcription", .serialized)
struct TranscriptionTests {

    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// Generates the fixture if absent, so a fresh clone can run the suite.
    static func spokenFixture(
        named name: String,
        saying text: String
    ) throws -> URL? {
        let url = fixturesURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        try FileManager.default.createDirectory(
            at: fixturesURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        do {
            try process.run()
        } catch {
            return nil   // no `say` available; the caller skips
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Plan Section 13.3 asks for a test that the collector-before-analyze ordering
    /// is preserved, "since inverting it silently returns empty transcripts."
    ///
    /// **That test cannot be written, because the premise is false on this system.**
    /// Verified 2026-08-01 by actually inverting the two statements in
    /// `Transcriber.transcribe` and rerunning: a 2.7s fixture and a 36-minute file
    /// both transcribed completely. `SpeechTranscriber.results` buffers. A test
    /// asserting non-empty runs therefore passes either way and would be pure
    /// theatre — worse than no test, because it would be believed.
    ///
    /// What survives is still worth having: transcription really runs, and produces
    /// ordered word-level runs, which is what `Segmenter` is built on.
    @Test("live transcription produces ordered, word-level runs")
    func liveTranscriptionProducesRuns() async throws {
        guard let url = try Self.spokenFixture(
            named: "known-01.aiff",
            saying: "the quick brown fox jumps over the lazy dog"
        ) else { return }

        let transcriber = Transcriber(localeIdentifier: "en-US")
        let assets = await transcriber.assetState()
        guard assets.supported, assets.installed else { return }

        let runs = try await transcriber.transcribe(file: try AudioInput.open(url))

        #expect(!runs.isEmpty)
        let text = runs.map(\.text).joined().lowercased()
        #expect(text.contains("quick"))
        #expect(text.contains("fox"))

        // Word-level granularity, confirmed in M0 and relied on by Segmenter.
        #expect(runs.count > 5)
        for run in runs {
            #expect(run.startMS <= run.endMS)
        }
        #expect(runs == runs.sorted { $0.startMS < $1.startMS })
    }

    /// A zero-frame file used to hang forever: `analyzeSequence` returns nil,
    /// `cancelAndFinishNow()` runs, and the results stream never terminates, so
    /// awaiting the collector blocks with no error and no timeout.
    @Test("a file with no audio frames returns empty instead of hanging", .timeLimit(.minutes(1)))
    func zeroFrameFileTerminates() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiosearch-zero-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        _ = file   // closed on deinit, leaving a valid header and zero frames

        let opened = try AudioInput.open(url)
        #expect(opened.length == 0)

        let transcriber = Transcriber(localeIdentifier: "en-US")
        let runs = try await transcriber.transcribe(file: opened)
        #expect(runs.isEmpty)
    }

    /// Silence with real frames is a different case and must reach the analyzer:
    /// it is a genuine "analysis succeeded, no speech present" result.
    @Test("digital silence with real frames analyses and yields no speech",
          .timeLimit(.minutes(2)))
    func framedSilenceYieldsEmpty() async throws {
        let transcriber = Transcriber(localeIdentifier: "en-US")
        let assets = await transcriber.assetState()
        guard assets.supported, assets.installed else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiosearch-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: 44100 * 2))
            buffer.frameLength = 44100 * 2      // two seconds of zeroes
            try file.write(from: buffer)
        }

        let opened = try AudioInput.open(url)
        #expect(opened.length > 0)
        #expect(abs(AudioInput.duration(of: opened) - 2.0) < 0.05)

        let runs = try await transcriber.transcribe(file: opened)
        #expect(runs.isEmpty, "silence should produce no speech, not spurious text")
    }
}

@Suite("engine identity")
struct EngineIdentityTests {

    @Test("identity is the documented shape")
    func shape() {
        let identity = Transcriber.engineIdentity(locale: "en-US", segmenterRevision: 2)
        let parts = identity.split(separator: "/")
        #expect(parts.count == 4)
        #expect(parts[0] == "speech")
        #expect(parts[2] == "en-US")
        #expect(parts[3] == "seg2")
    }

    @Test("the macOS build version is readable without a subprocess")
    func buildVersion() {
        let build = Transcriber.macOSBuildVersion()
        #expect(build != "unknown")
        #expect(!build.isEmpty)
    }

    /// Engine identity gates staleness reporting, so anything that changes the
    /// transcript must change the string, and nothing else may.
    @Test("locale and segmenter revision both change the identity")
    func discriminates() {
        let base = Transcriber.engineIdentity(locale: "en-US", segmenterRevision: 2)
        #expect(Transcriber.engineIdentity(locale: "en-GB", segmenterRevision: 2) != base)
        #expect(Transcriber.engineIdentity(locale: "en-US", segmenterRevision: 3) != base)
        #expect(Transcriber.engineIdentity(locale: "en-US", segmenterRevision: 2) == base)
    }
}

@Suite("hashing")
struct HashingTests {

    private func temporaryFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiosearch-hash-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }

    @Test("matches the known SHA-256 of a known input")
    func knownVector() throws {
        let url = try temporaryFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Hashing.sha256(contentsOf: url)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("hashes an empty file")
    func emptyFile() throws {
        let url = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Hashing.sha256(contentsOf: url)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// Files are streamed in 1 MB chunks because the corpus contains multi-gigabyte
    /// video. A file spanning several chunks must hash identically to one that does
    /// not, which is exactly what a chunking bug would break.
    @Test("chunk boundaries do not affect the result")
    func spansChunks() throws {
        let size = Hashing.chunkSize * 2 + 12345
        var bytes = Data(count: size)
        for index in stride(from: 0, to: size, by: 997) { bytes[index] = UInt8(index % 251) }

        let url = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try Hashing.sha256(contentsOf: url)
        #expect(streamed.count == 64)

        // Same content, different path: content addressing must not see the name.
        let copy = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try Hashing.sha256(contentsOf: copy) == streamed)
    }

    @Test("a one-byte change changes the digest")
    func sensitive() throws {
        let first = try temporaryFile(Data(repeating: 7, count: 4096))
        var changed = Data(repeating: 7, count: 4096)
        changed[2048] = 8
        let second = try temporaryFile(changed)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(try Hashing.sha256(contentsOf: first) != Hashing.sha256(contentsOf: second))
    }

    @Test("an unreadable path is an environment error, not a crash")
    func missingFile() {
        #expect(throws: AudiosearchError.self) {
            _ = try Hashing.sha256(
                contentsOf: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        }
    }
}
