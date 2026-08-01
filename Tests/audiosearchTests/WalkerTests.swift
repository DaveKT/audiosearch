import Foundation
import Testing

@testable import audiosearch

/// Every guard in `Walker` exists because an unguarded walk of a home directory
/// descends into application bundles and photo libraries, or hangs on a symlink
/// loop (plan Section 8.1). These tests hold those guards in place.
@Suite("walker")
struct WalkerTests {

    /// A scratch tree, removed with the test.
    final class Tree {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("audiosearch-walk-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 16) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        func directory(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func symlink(_ relative: String, to destination: URL) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        }

        var path: String { root.path }
    }

    private func names(_ result: Walker.Result) -> Set<String> {
        Set(result.files.map { URL(fileURLWithPath: $0.path).lastPathComponent })
    }

    @Test("finds audio and video files and ignores everything else")
    func extensionAllowlist() throws {
        let tree = try Tree()
        try tree.file("a.mp3")
        try tree.file("b.m4a")
        try tree.file("c.mov")
        try tree.file("d.mp4")
        try tree.file("notes.txt")
        try tree.file("cover.jpg")
        try tree.file("no-extension")

        let found = names(Walker.walk(roots: [tree.path]))
        #expect(found == ["a.mp3", "b.m4a", "c.mov", "d.mp4"])
    }

    @Test("extension matching is case folded")
    func caseFoldedExtensions() throws {
        let tree = try Tree()
        try tree.file("SHOUTING.MP3")
        try tree.file("Mixed.M4a")

        #expect(names(Walker.walk(roots: [tree.path])) == ["SHOUTING.MP3", "Mixed.M4a"])
    }

    /// The guard that matters most in a home directory: an .app bundle contains
    /// hundreds of files and none of them are the user's recordings.
    @Test("does not descend into application bundles")
    func skipsPackages() throws {
        let tree = try Tree()
        try tree.file("real.mp3")
        try tree.file("Fake.app/Contents/Resources/bundled.mp3")

        let found = names(Walker.walk(roots: [tree.path]))
        #expect(found == ["real.mp3"])
    }

    @Test("skips hidden files and directories")
    func skipsHidden() throws {
        let tree = try Tree()
        try tree.file("visible.mp3")
        try tree.file(".hidden/secret.mp3")
        try tree.file(".dotfile.mp3")

        #expect(names(Walker.walk(roots: [tree.path])) == ["visible.mp3"])
    }

    /// Not following symlinks is what makes loops impossible rather than merely
    /// unlikely. This test would hang, not fail, if the guard were removed.
    @Test("does not follow symlinks, so a loop cannot hang the walk")
    func symlinkLoop() throws {
        let tree = try Tree()
        try tree.file("real.mp3")
        let nested = try tree.directory("nested")
        try tree.symlink("nested/loop", to: tree.root)
        try tree.symlink("nested/alias.mp3", to: nested.appendingPathComponent("../real.mp3"))

        #expect(names(Walker.walk(roots: [tree.path])) == ["real.mp3"])
    }

    @Test("descends into ordinary subdirectories")
    func nestedDirectories() throws {
        let tree = try Tree()
        try tree.file("top.mp3")
        try tree.file("one/two/three/deep.mp3")

        #expect(names(Walker.walk(roots: [tree.path])) == ["top.mp3", "deep.mp3"])
    }

    @Test("handles apostrophes, spaces and non-ASCII names")
    func awkwardFilenames() throws {
        let tree = try Tree()
        try tree.file("Dave's recording.mp3")
        try tree.file("a file with spaces.m4a")
        try tree.file("café — señor.mp3")

        #expect(names(Walker.walk(roots: [tree.path]))
                == ["Dave's recording.mp3", "a file with spaces.m4a", "café — señor.mp3"])
    }

    @Test("captures size and modification time")
    func metadata() throws {
        let tree = try Tree()
        try tree.file("a.mp3", bytes: 1234)

        let found = try #require(Walker.walk(roots: [tree.path]).files.first)
        #expect(found.size == 1234)
        #expect(found.mtime > 0)
    }

    /// A file named explicitly on the command line is honoured even if its
    /// extension is not on the allowlist: the user asked for it by name, and
    /// silently doing nothing would be worse than trying and failing.
    @Test("an explicitly named file bypasses the extension allowlist")
    func explicitFileBypassesAllowlist() throws {
        let tree = try Tree()
        let odd = try tree.file("recording.weird")

        let result = Walker.walk(roots: [odd.path])
        #expect(result.files.count == 1)
        #expect(result.files[0].path == Config.canonicalPath(odd.path))
    }

    @Test("a path that does not exist is reported, not silently ignored")
    func missingPath() throws {
        let result = Walker.walk(roots: ["/nonexistent/\(UUID().uuidString)/audio.mp3"])
        #expect(result.files.isEmpty)
        #expect(result.missing.count == 1)
    }

    @Test("the same file reached by two roots is only indexed once")
    func deduplicates() throws {
        let tree = try Tree()
        try tree.file("one.mp3")

        let result = Walker.walk(roots: [tree.path, tree.path, tree.path + "/one.mp3"])
        #expect(result.files.count == 1)
    }

    @Test("results are sorted, so runs are reproducible")
    func sorted() throws {
        let tree = try Tree()
        for name in ["z.mp3", "a.mp3", "m.mp3"] { try tree.file(name) }

        let paths = Walker.walk(roots: [tree.path]).files.map(\.path)
        #expect(paths == paths.sorted())
    }

    @Test("paths are canonical, so the index does not depend on how it was reached")
    func canonicalPaths() throws {
        let tree = try Tree()
        try tree.file("nested/one.mp3")

        let viaDotDot = tree.path + "/nested/../nested"
        let result = Walker.walk(roots: [viaDotDot])
        #expect(result.files.count == 1)
        #expect(!result.files[0].path.contains(".."))
    }
}
