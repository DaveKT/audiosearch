import Foundation

/// Database location and library-root resolution (plan Section 10.3).
enum Config {
    static let databaseEnvironmentKey = "AUDIOSEARCH_DB"
    static let libraryRootEnvironmentKey = "AUDIOSEARCH_ROOT"

    /// Resolution order, highest precedence first: `--db <path>`, then
    /// `AUDIOSEARCH_DB`, then `~/Library/Application Support/audiosearch/index.db`.
    static func databaseURL(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: expandingTilde(explicit)).standardized
        }
        if let fromEnvironment = environment[databaseEnvironmentKey], !fromEnvironment.isEmpty {
            return URL(fileURLWithPath: expandingTilde(fromEnvironment)).standardized
        }
        return try defaultDatabaseURL()
    }

    static func defaultDatabaseURL() throws -> URL {
        let support: URL
        do {
            support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw AudiosearchError.environment(
                "cannot locate Application Support directory: \(error.localizedDescription)"
            )
        }
        return support
            .appendingPathComponent("audiosearch", isDirectory: true)
            .appendingPathComponent("index.db", isDirectory: false)
    }

    /// Creates the database's containing directory if it does not exist.
    static func prepareContainingDirectory(for databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw AudiosearchError.environment(
                "cannot create \(directory.path): \(error.localizedDescription)"
            )
        }
    }

    /// Canonical absolute path: tilde-expanded, symlink-resolved, standardized.
    ///
    /// Storing paths in this form makes the index independent of the directory
    /// the tool was invoked from (plan Section 10.3).
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: expandingTilde(path))
            .resolvingSymlinksInPath()
            .standardized
            .path
    }

    /// Inverse of `canonicalPath` for display only: re-abbreviates the user's home
    /// directory to `~`. Never applied to machine-readable output (Section 12.4).
    static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Library root used by `index` with no path argument. `AUDIOSEARCH_ROOT`
    /// overrides the value persisted in `meta` by `index --set-root`.
    static func libraryRoot(
        stored: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let fromEnvironment = environment[libraryRootEnvironmentKey], !fromEnvironment.isEmpty {
            return canonicalPath(fromEnvironment)
        }
        return stored
    }

    private static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
