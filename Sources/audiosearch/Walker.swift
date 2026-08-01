import Foundation

/// Directory enumeration with guards (plan Section 8.1).
///
/// An unguarded walk of a home directory descends into application bundles and
/// photo libraries, and can hang on symlink loops. Every guard here exists because
/// of one of those.
enum Walker {

    /// A file the walk found and classified.
    struct Found: Equatable {
        /// Canonical absolute path.
        let path: String
        let size: Int64
        /// Seconds since epoch.
        let mtime: Int64
    }

    /// A file that exists but cannot be read right now. Never an error, never
    /// silently dropped: reported so "nothing found" and "nothing readable" stay
    /// distinguishable.
    struct Unavailable: Equatable {
        enum Reason: String {
            /// An iCloud stub, present in the listing but not on disk. Reading it
            /// either blocks on a download or fails unpredictably mid-batch.
            case notDownloaded = "not downloaded from iCloud"
            case unreadable = "unreadable"
        }

        let path: String
        let reason: Reason
    }

    struct Result {
        var files: [Found] = []
        var unavailable: [Unavailable] = []
        /// Paths passed on the command line that do not exist at all.
        var missing: [String] = []
    }

    static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        .isSymbolicLinkKey, .ubiquitousItemDownloadingStatusKey,
        .isUbiquitousItemKey, .volumeURLKey,
    ]

    /// Walks the given roots. A root may be a single file or a directory.
    ///
    /// Results are sorted by path so an indexing run is reproducible and progress
    /// output is stable between runs.
    static func walk(
        roots: [String],
        fileManager: FileManager = .default
    ) -> Result {
        var result = Result()
        var seen = Set<String>()

        for root in roots {
            let canonical = Config.canonicalPath(root)
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory) else {
                result.missing.append(canonical)
                continue
            }

            if isDirectory.boolValue {
                walk(directory: URL(fileURLWithPath: canonical, isDirectory: true),
                     into: &result, seen: &seen, fileManager: fileManager)
            } else {
                // An explicitly named file bypasses the extension allowlist: the
                // user asked for this file by name, so honour that rather than
                // silently doing nothing.
                consider(URL(fileURLWithPath: canonical), into: &result, seen: &seen,
                         enforcingExtension: false, fileManager: fileManager)
            }
        }

        result.files.sort { $0.path < $1.path }
        result.unavailable.sort { $0.path < $1.path }
        result.missing.sort()
        return result
    }

    private static func walk(
        directory: URL,
        into result: inout Result,
        seen: inout Set<String>,
        fileManager: FileManager
    ) {
        // skipsPackageDescendants keeps the walk out of .app, .photoslibrary and
        // every other bundle; skipsHiddenFiles keeps it out of dotfile trees.
        // Symlinks are not followed at all, which is what makes loops impossible
        // rather than merely unlikely.
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
        ]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else {
            result.unavailable.append(
                Unavailable(path: directory.path, reason: .unreadable)
            )
            return
        }

        for case let url as URL in enumerator {
            consider(url, into: &result, seen: &seen,
                     enforcingExtension: true, fileManager: fileManager)
        }
    }

    private static func consider(
        _ url: URL,
        into result: inout Result,
        seen: inout Set<String>,
        enforcingExtension: Bool,
        fileManager: FileManager
    ) {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
            result.unavailable.append(Unavailable(path: url.path, reason: .unreadable))
            return
        }

        if values.isSymbolicLink == true { return }
        guard values.isRegularFile == true else { return }
        if enforcingExtension, !AudioInput.isIndexable(url) { return }

        // Canonicalize late: two roots may reach the same file by different paths,
        // and the index is keyed on the canonical form.
        let path = Config.canonicalPath(url.path)
        guard seen.insert(path).inserted else { return }

        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded {
            result.unavailable.append(Unavailable(path: path, reason: .notDownloaded))
            return
        }

        result.files.append(Found(
            path: path,
            size: Int64(values.fileSize ?? 0),
            mtime: Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        ))
    }
}
