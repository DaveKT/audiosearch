import CryptoKit
import Foundation

/// Streaming content hash (plan Section 6).
///
/// Video files in the corpus may be multiple gigabytes, so the file is never read
/// into memory: it is fed to SHA-256 in 1 MB chunks.
enum Hashing {
    static let chunkSize = 1 << 20

    static func sha256(contentsOf url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AudiosearchError.environment(
                "cannot read \(url.path): \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw AudiosearchError.environment(
                    "read failed on \(url.path): \(error.localizedDescription)"
                )
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
