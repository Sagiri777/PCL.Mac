import Foundation
import Testing
import ZIPFoundation
@testable import PCL_Mac

struct ForgeModTests {
    @Test func parsesForgeMetadataFromAnIsolatedFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-forge-mod-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = root.appending(path: "payload")
        let metadataURL = payload.appending(path: "META-INF/mods.toml")
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        modLoader="javafml"
        loaderVersion="[1,)"
        license="MIT"

        [[mods]]
        modId="fixture_mod"
        version="1.2.3"
        displayName="Fixture Mod"
        description="Deterministic Forge fixture"
        """.utf8).write(to: metadataURL)

        let archiveURL = root.appending(path: "fixture.jar")
        try FileManager.default.zipItem(at: payload, to: archiveURL, shouldKeepParent: false)

        let mod = try #require(Mod.loadMod(url: archiveURL))
        #expect(mod.id == "fixture_mod")
        #expect(mod.name == "Fixture Mod")
        #expect(mod.version == "1.2.3")
        #expect(mod.brand == .forge)
    }
}
