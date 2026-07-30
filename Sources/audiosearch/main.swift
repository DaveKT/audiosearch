// M0 spike: throwaway, no persistence, no CLI parsing.
// Every function here exists to answer one open question from
// doc/plans/2026-07-audiosearch-implementation-plan.md Section 14 (M0).
// This file is expected to be deleted/rewritten once M1 begins.

import Foundation
import Speech
import AVFoundation
import CoreMedia

struct RawRun: Codable {
    let text: String
    let startMS: Int
    let endMS: Int
}

enum SpikeError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case noArgument

    var description: String {
        switch self {
        case .unsupportedLocale(let id): return "locale not supported: \(id)"
        case .noArgument: return "usage: audiosearch-spike <audio-or-video-file>"
        }
    }
}

func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let bcp47 = locale.identifier(.bcp47)

    let supported = await SpeechTranscriber.supportedLocales
    guard supported.contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
        throw SpikeError.unsupportedLocale(bcp47)
    }

    let installed = await SpeechTranscriber.installedLocales
        .contains { $0.identifier(.bcp47) == bcp47 }

    print("[assets] locale \(bcp47): supported=true installed=\(installed)")

    if !installed {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("[assets] downloading...")
            try await request.downloadAndInstall()
            print("[assets] installed")
        }
    }

    _ = try await AssetInventory.reserve(locale: locale)
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

    // The result collector MUST be established before analyzeSequence is awaited,
    // or results are dropped (plan Section 7.3).
    async let collected: [RawRun] = {
        var runs: [RawRun] = []
        do {
            for try await result in transcriber.results where result.isFinal {
                runs.append(contentsOf: extractRuns(from: result.text))
            }
        } catch {
            print("[collector] error: \(error)")
        }
        return runs
    }()

    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        await analyzer.cancelAndFinishNow()
    }

    return await collected
}

@main
struct Spike {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print(SpikeError.noArgument.description)
            exit(2)
        }
        let path = args[1]
        let url = URL(fileURLWithPath: path)
        let locale = Locale(identifier: "en-US")

        print("[spike] file: \(path)")
        print("[spike] SFSpeechRecognizer auth status: \(SFSpeechRecognizer.authorizationStatus().rawValue)")

        let clock = ContinuousClock()
        let start = clock.now

        do {
            let runs = try await transcribe(url: url, locale: locale)
            let elapsed = clock.now - start
            print("[spike] runs: \(runs.count)")
            print("[spike] elapsed: \(elapsed)")

            if let first = runs.first, let last = runs.last {
                let audioSeconds = Double(last.endMS) / 1000.0
                print("[spike] audio span: \(String(format: "%.1f", audioSeconds))s, first run: \(first)")
            }

            for (i, run) in runs.prefix(10).enumerated() {
                print("  [\(i)] \(run.startMS)-\(run.endMS)ms: \(run.text)")
            }

            // Dump full run set as JSON for fixture recording / offline inspection.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(runs)
            let outURL = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("runs.json")
            try data.write(to: outURL)
            print("[spike] wrote \(runs.count) runs to \(outURL.path)")
        } catch {
            print("[spike] FAILED: \(error)")
            exit(1)
        }
    }
}
