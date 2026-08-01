import ArgumentParser
import Foundation

/// Exit code taxonomy (plan Section 10.1).
///
/// ArgumentParser's own default for a usage error is 64 (`EX_USAGE`); the root
/// command in `main.swift` remaps that to `Exit.usage` so the published contract
/// holds for every failure path.
enum Exit {
    /// Success, with at least one result where results apply.
    static let success = ExitCode(0)
    /// No search matches, or partial failure during indexing.
    static let noResults = ExitCode(1)
    /// Usage error: bad flags, unparseable query.
    static let usage = ExitCode(2)
    /// Environment error: assets missing, locale unsupported, database
    /// unreadable, FTS5 absent.
    static let environment = ExitCode(3)
}

/// An error carrying both a human-readable message and the exit code it maps to.
///
/// Thrown from anywhere in the tool; `main.swift` prints `message` to stderr
/// (never stdout — plan Section 10.2) and exits with `code`.
struct AudiosearchError: Error, CustomStringConvertible {
    let code: ExitCode
    let message: String

    var description: String { message }

    static func usage(_ message: String) -> AudiosearchError {
        AudiosearchError(code: Exit.usage, message: message)
    }

    static func environment(_ message: String) -> AudiosearchError {
        AudiosearchError(code: Exit.environment, message: message)
    }
}

/// Work not yet built. Named milestones rather than a bare "unimplemented" so a
/// user who runs ahead of the roadmap is told which release the command lands in.
struct NotImplemented: Error, CustomStringConvertible {
    let command: String
    let milestone: String

    var description: String {
        "`audiosearch \(command)` is not implemented yet (planned for \(milestone))."
    }
}
