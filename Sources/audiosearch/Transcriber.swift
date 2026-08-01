import AVFoundation
import CoreMedia
import Foundation
import Speech

// The SpeechAnalyzer wrapper and asset installation (plan Section 7). Together
// with AudioInput.swift this is the whole of the framework-specific surface, which
// is what makes M6's engine selection a contained change rather than a rewrite.

/// One timestamped run of recognized text. Word-level, confirmed in M0.
///
/// `Codable` specifically so recorded runs can serve as segmentation fixtures
/// (plan Section 13.2) — segmentation is deterministic and transcription is not,
/// so boundary logic is tested against replayed runs rather than live analysis.
struct RawRun: Codable {
    let text: String
    let startMS: Int
    let endMS: Int
}

enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case assetInstallationFailed(String)

    var description: String {
        switch self {
        case .unsupportedLocale(let identifier):
            return "locale not supported by this system: \(identifier)"
        case .assetInstallationFailed(let reason):
            return "speech asset installation failed: \(reason)"
        }
    }
}

/// Extracts timing-bearing runs from a result's `AttributedString`.
///
/// Runs without an `audioTimeRange` carry no position and cannot be indexed;
/// whitespace-only runs would produce empty segments. Both are dropped.
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

struct Transcriber {
    let locale: Locale

    init(localeIdentifier: String) {
        self.locale = Locale(identifier: localeIdentifier)
    }

    var bcp47: String { locale.identifier(.bcp47) }

    // MARK: - Assets

    struct AssetState {
        var supported: Bool
        var installed: Bool
        var reserved: Bool
    }

    func assetState() async -> AssetState {
        let supported = await SpeechTranscriber.supportedLocales
            .contains { $0.identifier(.bcp47) == bcp47 }
        guard supported else {
            return AssetState(supported: false, installed: false, reserved: false)
        }
        let installed = await SpeechTranscriber.installedLocales
            .contains { $0.identifier(.bcp47) == bcp47 }
        let reserved = (try? await AssetInventory.reserve(locale: locale)) != nil
        return AssetState(supported: true, installed: installed, reserved: reserved)
    }

    /// Installs assets if absent.
    ///
    /// Called once at the start of a batch rather than per file: installation needs
    /// the network, and failing fast beats failing three hours into a run
    /// (Section 7.1, Risk 7).
    func prepareAssets(onDownload: () -> Void = {}) async throws {
        let supported = await SpeechTranscriber.supportedLocales
            .contains { $0.identifier(.bcp47) == bcp47 }
        guard supported else {
            throw TranscriberError.unsupportedLocale(bcp47)
        }

        let installed = await SpeechTranscriber.installedLocales
            .contains { $0.identifier(.bcp47) == bcp47 }

        if !installed {
            onDownload()
            do {
                if let request = try await AssetInventory
                    .assetInstallationRequest(supporting: [makeModule()]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw TranscriberError.assetInstallationFailed(error.localizedDescription)
            }
        }

        // AssetInventory caps concurrently reserved locales. A single-locale tool
        // will not reach the cap, but surface the failure rather than proceeding
        // into an opaque analysis error.
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            throw TranscriberError.assetInstallationFailed(
                "could not reserve \(bcp47): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Analysis

    private func makeModule() -> SpeechTranscriber {
        // volatileResults is deliberately omitted: partial results are meaningless
        // for indexing and only add work (Section 7.3).
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Transcribes one already-opened file.
    ///
    /// Returns an empty array when analysis succeeds but finds no speech. The
    /// caller distinguishes that from failure and records `status='empty'` — a
    /// music track, a silent recording and a broken decode must not be
    /// indistinguishable, which is the structural analogue of the predecessor
    /// script's zero-byte transcript bug (Section 6).
    func transcribe(file: AVAudioFile) async throws -> [RawRun] {
        // A file with no audio frames hangs the analyzer indefinitely:
        // `analyzeSequence` returns nil, `cancelAndFinishNow()` is called, and the
        // results stream then never terminates, so awaiting the collector blocks
        // forever with no error and no timeout. Observed against a zero-length
        // fixture (`say -o silent.aiff ""`), which produces exactly this.
        //
        // Note this is specifically *zero frames*, not silence: three seconds of
        // digital silence analyses normally and correctly yields no speech.
        // Short-circuiting here is also the honest answer — there is no audio to
        // transcribe, so there is no speech, so the caller records `empty`.
        guard file.length > 0 else { return [] }

        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])

        // The collector is established before analyzeSequence is awaited. Plan
        // Section 7.3 records this as load-bearing — invert it and transcripts
        // come back silently empty.
        //
        // Measured 2026-08-01, and that is NOT true on this system: with the two
        // statements swapped, a 2.7s fixture and a 36-minute file both transcribed
        // completely (215 segments, correct duration). `SpeechTranscriber.results`
        // evidently buffers rather than dropping. See plan Section 7.3.
        //
        // The ordering is kept anyway, deliberately. It matches Apple's own sample
        // pattern, it costs nothing, and buffering is an implementation detail that
        // a point release is free to change. Do not "simplify" it away — but do not
        // believe a test can catch its inversion either, because none can while the
        // stream buffers.
        async let collected: [RawRun] = {
            var runs: [RawRun] = []
            for try await result in module.results where result.isFinal {
                runs.append(contentsOf: extractRuns(from: result.text))
            }
            return runs
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collected
    }

    // MARK: - Engine identity

    /// A heuristic identity for the engine that produced a transcript
    /// (plan Section 6.2), for example `speech/26C61/en-US/seg2`.
    ///
    /// The OS exposes no exact model identifier, so this is a proxy built from the
    /// macOS build version, the locale, and the segmenter revision. It
    /// over-invalidates, since most OS updates leave the speech models alone, and
    /// can under-invalidate if assets update independently of the build.
    ///
    /// Because it is a heuristic, a mismatch marks rows stale **for reporting
    /// only**. Retranscription is always opt-in via `--reindex-stale`; only a
    /// content hash mismatch retranscribes automatically.
    static func engineIdentity(locale: String, segmenterRevision: Int = SegmentationParameters.revision) -> String {
        "speech/\(macOSBuildVersion())/\(locale)/seg\(segmenterRevision)"
    }

    /// Read from the system plist rather than by shelling out to `sw_vers`; the
    /// indexing path spawns no subprocesses by design (Section 4).
    static func macOSBuildVersion() -> String {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let build = plist["ProductBuildVersion"] as? String
        else {
            return "unknown"
        }
        return build
    }
}
