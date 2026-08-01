import AVFoundation
import CoreMedia
import Foundation
import Speech

// Framework-specific transcription code lives here and in AudioInput.swift only,
// so the engine can be swapped without touching schema, indexing, search, or CLI
// code (plan Section 5.1, Risk 6).
//
// M1 does not call any of this. What follows is the M0 spike's validated core,
// moved out of main.swift into its planned home: run extraction (Section 7.4,
// unit-tested), asset installation (Section 7.1), and the analysis ordering
// (Section 7.3). M2 builds the real indexing API around it.

/// One timestamped run of recognized text. `Codable` so run arrays can be
/// recorded as fixtures and replayed into `Segmenter` without live transcription
/// (plan Section 13.2).
struct RawRun: Codable {
    let text: String
    let startMS: Int
    let endMS: Int
}

enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)

    var description: String {
        switch self {
        case .unsupportedLocale(let identifier):
            return "locale not supported: \(identifier)"
        }
    }
}

/// Confirmed word-level in M0, against the SDK's real
/// `AttributeScopes.SpeechAttributes.TimeRangeAttribute`.
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

func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let bcp47 = locale.identifier(.bcp47)

    let supported = await SpeechTranscriber.supportedLocales
    guard supported.contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
        throw TranscriberError.unsupportedLocale(bcp47)
    }

    let installed = await SpeechTranscriber.installedLocales
        .contains { $0.identifier(.bcp47) == bcp47 }

    if !installed {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    _ = try await AssetInventory.reserve(locale: locale)
}

/// M0 confirmed `AVAudioFile` opens `.mov` and `.mp4` directly, including files
/// with a real encoded video track — no `AVAssetReader` fallback needed (Risk 9).
func transcribe(url: URL, locale: Locale) async throws -> [RawRun] {
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )

    try await ensureAssets(for: transcriber, locale: locale)

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let audioFile = try AVAudioFile(forReading: url)

    // Load-bearing ordering: the result collector MUST be established before
    // analyzeSequence is awaited, or results are dropped silently and the
    // transcript comes back empty (plan Section 7.3).
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
