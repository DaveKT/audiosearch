import AVFoundation
import Foundation

/// Input path selection and duration (plan Section 7.2).
///
/// One of only two files that touch a media framework, so the transcription engine
/// can be replaced without disturbing schema, indexing, search or CLI code
/// (Section 5.1, Risk 6, and M6).
enum AudioInput {

    /// Decode failures are per-file, not fatal: the Indexer records them as
    /// `status='failed'` and moves to the next file (Section 8.5).
    struct DecodeError: Error, CustomStringConvertible {
        let path: String
        let underlying: String

        var description: String { "decode error: \(underlying)" }
    }

    /// Opens a file for analysis.
    ///
    /// A single path handles audio *and* video: M0 confirmed `AVAudioFile` opens
    /// `.mov` and `.mp4` directly, including containers with a real encoded video
    /// track, and `.mp3` was confirmed alongside the Section 14.1 accuracy work.
    /// The `AVAssetReader` fallback in Section 7.2 stays documented and unbuilt —
    /// do not add it speculatively; add it only if a real container fails here.
    static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw DecodeError(path: url.path, underlying: error.localizedDescription)
        }
    }

    /// Duration in seconds.
    static func duration(of file: AVAudioFile) -> Double {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    /// Extensions the walker will consider. Case folded at comparison time.
    ///
    /// Video extensions are present because Risk 9 resolved in M0: they open
    /// through the same path as audio, so they ship in M2 rather than M5.
    static let extensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "caf",
        "mp4", "mov", "m4v",
    ]

    static func isIndexable(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
