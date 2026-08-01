import Foundation
import Testing

@testable import audiosearch

@Suite("config")
struct ConfigTests {

    @Test("--db wins over the environment, which wins over the default")
    func databaseResolutionOrder() throws {
        let environment = [Config.databaseEnvironmentKey: "/tmp/from-env.db"]

        #expect(try Config.databaseURL(explicit: "/tmp/explicit.db", environment: environment).path
                == "/tmp/explicit.db")
        #expect(try Config.databaseURL(explicit: nil, environment: environment).path
                == "/tmp/from-env.db")

        let fallback = try Config.databaseURL(explicit: nil, environment: [:])
        #expect(fallback.path.hasSuffix("/Application Support/audiosearch/index.db"))
    }

    @Test("an empty override is treated as absent, not as an empty path")
    func emptyOverrides() throws {
        let environment = [Config.databaseEnvironmentKey: ""]
        let resolved = try Config.databaseURL(explicit: "", environment: environment)
        #expect(resolved.path.hasSuffix("/audiosearch/index.db"))
    }

    @Test("the database path is tilde-expanded")
    func tildeExpansion() throws {
        let resolved = try Config.databaseURL(explicit: "~/custom.db", environment: [:])
        #expect(resolved.path == NSHomeDirectory() + "/custom.db")
    }

    @Test("canonical paths are absolute, tilde-expanded and standardized")
    func canonicalPaths() {
        #expect(Config.canonicalPath("~/Audio") == Config.canonicalPath(NSHomeDirectory() + "/Audio"))
        #expect(Config.canonicalPath("/tmp/a/../b") == Config.canonicalPath("/tmp/b"))
        #expect(Config.canonicalPath("/tmp/trailing/").hasSuffix("/") == false)
    }

    @Test("home abbreviation applies only to paths actually under home")
    func homeAbbreviation() {
        #expect(Config.abbreviatingHome(NSHomeDirectory() + "/Audio/x.mp3") == "~/Audio/x.mp3")
        #expect(Config.abbreviatingHome(NSHomeDirectory()) == "~")
        #expect(Config.abbreviatingHome("/Volumes/Archive/x.mp3") == "/Volumes/Archive/x.mp3")
        // A sibling directory whose name merely starts with the home path.
        #expect(Config.abbreviatingHome(NSHomeDirectory() + "-backup/x.mp3")
                == NSHomeDirectory() + "-backup/x.mp3")
    }

    @Test("AUDIOSEARCH_ROOT overrides the persisted library root")
    func libraryRootResolution() {
        #expect(Config.libraryRoot(stored: "/Audio", environment: [:]) == "/Audio")
        #expect(Config.libraryRoot(
            stored: "/Audio",
            environment: [Config.libraryRootEnvironmentKey: "/tmp/other"]
        ) == "/tmp/other")
        #expect(Config.libraryRoot(stored: nil, environment: [:]) == nil)
        #expect(Config.libraryRoot(stored: nil, environment: [Config.libraryRootEnvironmentKey: ""]) == nil)
    }
}
