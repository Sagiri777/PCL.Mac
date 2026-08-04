import Foundation
import Testing
@testable import PCL_Mac

struct OfficialWebDownloadTests {
    @Test func officialPagePolicyUsesAHostBoundary() {
        let expected = URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei")!
        #expect(CurseForgeURLPolicy.isOfficialProjectPage(
            URL(string: "https://curseforge.com/minecraft/mc-mods/jei")!
        ))
        #expect(CurseForgeURLPolicy.isOfficialProjectPage(
            URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei")!
        ))
        #expect(!CurseForgeURLPolicy.isOfficialProjectPage(
            URL(string: "https://evilcurseforge.com/minecraft/mc-mods/jei")!
        ))
        #expect(!CurseForgeURLPolicy.isOfficialProjectPage(
            URL(string: "https://curseforge.com.evil.example/minecraft/mc-mods/jei")!
        ))
        #expect(!CurseForgeURLPolicy.isOfficialProjectPage(
            URL(string: "http://www.curseforge.com/minecraft/mc-mods/jei")!
        ))
        #expect(CurseForgeURLPolicy.isSameOfficialProjectPage(
            URL(string: "https://curseforge.com/minecraft/mc-mods/jei/files")!,
            as: expected
        ))
        #expect(!CurseForgeURLPolicy.isSameOfficialProjectPage(
            URL(string: "https://www.curseforge.com/minecraft/mc-mods/other-project")!,
            as: expected
        ))
    }

    @Test func manualClickAuthorizationSurvivesOfficialCountdownAndExpires() {
        let expected = URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei")!
        let authorization = OfficialWebDownloadUserAuthorization(
            projectPageURL: expected.appending(path: "files/123"),
            originalRequestURL: expected.appending(path: "download/123"),
            issuedAtUptime: 100
        )

        #expect(authorization.isValid(for: expected, nowUptime: 105))
        #expect(!authorization.isValid(
            for: URL(string: "https://www.curseforge.com/minecraft/mc-mods/other-project")!,
            nowUptime: 105
        ))
        #expect(!authorization.isValid(for: expected, nowUptime: 161))
    }

    @Test func accessibilityBrowserAutomationUsesOnlyTheQueueBoundOfficialFileRoute() {
        let page = URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei/files/all?page=2")!
        let sha1 = String(repeating: "a", count: 40)
        let group = OfficialWebDownloadGroup(
            id: sha1,
            expectedSHA1: sha1,
            pageURL: page,
            records: [record(fileID: 3_526_062, destination: "mods/jei.jar", sha1: sha1, page: page)]
        )

        let expectedURL = URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei/download/3526062")!
        #expect(OfficialWebDownloadBrowserAutomation.downloadURL(for: group) == expectedURL)
        #expect(OfficialWebDownloadBrowserAutomation.isExpectedDownloadURL(expectedURL, for: group))
        #expect(!OfficialWebDownloadBrowserAutomation.isExpectedDownloadURL(
            URL(string: "https://www.curseforge.com/minecraft/mc-mods/other-project/download/3526062")!,
            for: group
        ))
        #expect(!OfficialWebDownloadBrowserAutomation.isExpectedDownloadURL(
            URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei/download/3526063")!,
            for: group
        ))
    }

    @Test func accessibilityBrowserAutomationAuthorizationExpiresAndStaysProjectBound() {
        let page = URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei")!
        let authorization = OfficialWebDownloadBrowserAutomationAuthorization(
            projectPageURL: page,
            downloadURL: URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei/download/3526062")!,
            issuedAtUptime: 100
        )

        #expect(authorization.isValid(for: page, nowUptime: 130))
        #expect(!authorization.isValid(
            for: URL(string: "https://www.curseforge.com/minecraft/mc-mods/other-project")!,
            nowUptime: 130
        ))
        #expect(!authorization.isValid(
            for: page,
            nowUptime: 100 + OfficialWebDownloadBrowserAutomationAuthorization.validityWindow + 0.1
        ))
    }

    @Test func plannerGroupsRepeatedHashesAndSafelySkipsVerifiedFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = root.appending(path: "mods/cached.jar")
        try cached.ensureParentDirectoryExists()
        try Data("same artifact".utf8).write(to: cached)
        let sha1 = try FileHash.compute(cached, algorithm: .sha1)
        let page = URL(string: "https://www.curseforge.com/minecraft/mc-mods/example")!

        let manifest = OfficialWebDownloadManifest(files: [
            record(fileID: 1, destination: "mods/cached.jar", sha1: sha1, page: page),
            record(fileID: 2, destination: "mods/first.jar", sha1: sha1, page: page),
            record(fileID: 3, destination: "resourcepacks/second.jar", sha1: sha1, page: page),
            record(fileID: 4, destination: "mods/no-page.jar", sha1: sha1, page: nil),
            record(fileID: 5, destination: "mods/no-hash.jar", sha1: nil, page: page),
            record(fileID: 6, destination: "../outside.jar", sha1: sha1, page: page),
            record(
                fileID: 7,
                destination: "mods/untrusted-page.jar",
                sha1: sha1,
                page: URL(string: "https://evilcurseforge.com/minecraft/mc-mods/example")
            )
        ])

        let plan = OfficialWebDownloadPlanner.plan(manifest: manifest, instanceRoot: root)
        #expect(plan.alreadySatisfiedCount == 1)
        #expect(plan.groups.count == 1)
        #expect(plan.groups[0].records.count == 2)
        #expect(plan.blocked.count == 4)
        #expect(plan.blocked.map(\.reason).contains(.missingOfficialPage))
        #expect(plan.blocked.map(\.reason).contains(.missingSHA1))
        #expect(plan.blocked.map(\.reason).contains(.unsafeDestination))
        #expect(plan.blocked.map(\.reason).contains(.unsafeOfficialPage))
    }

    @Test func queueCapsActivePagesAtThreeAndRefillsAfterCompletion() {
        let groups = (0..<5).map { index in
            group(id: String(repeating: String(index), count: 40), fileID: index)
        }
        var queue = OfficialWebDownloadQueue(groups: groups, parallelLimit: 99)

        #expect(queue.startOrResume().count == 3)
        #expect(queue.active.count == 3)
        _ = queue.markCompleted(groups[0].id)
        #expect(queue.active.count == 3)
        #expect(queue.active.map(\.id).contains(groups[3].id))
        #expect(queue.pending.count == 1)
    }

    @Test func placementCopiesOneVerifiedArtifactToEveryMatchingDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appending(path: "staging/artifact.jar")
        try staged.ensureParentDirectoryExists()
        try Data("verified official file".utf8).write(to: staged)
        let sha1 = try FileHash.compute(staged, algorithm: .sha1)
        let group = OfficialWebDownloadGroup(
            id: sha1,
            expectedSHA1: sha1,
            pageURL: URL(string: "https://www.curseforge.com/minecraft/mc-mods/example")!,
            records: [
                record(fileID: 10, destination: "mods/first.jar", sha1: sha1),
                record(fileID: 11, destination: "resourcepacks/second.jar", sha1: sha1)
            ]
        )

        try OfficialWebDownloadPlacementService().place(stagedFile: staged, group: group, instanceRoot: root)

        #expect(OfficialWebDownloadPlanner.fileIsValid(at: root.appending(path: "mods/first.jar"), sha1: sha1))
        #expect(OfficialWebDownloadPlanner.fileIsValid(at: root.appending(path: "resourcepacks/second.jar"), sha1: sha1))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func hashMismatchNeverOverwritesTheInstanceDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appending(path: "staging/wrong.jar")
        let destination = root.appending(path: "mods/existing.jar")
        try staged.ensureParentDirectoryExists()
        try destination.ensureParentDirectoryExists()
        try Data("wrong bytes".utf8).write(to: staged)
        try Data("preserve existing bytes".utf8).write(to: destination)
        let expectedFile = root.appending(path: "expected.jar")
        try Data("expected bytes".utf8).write(to: expectedFile)
        let expectedSHA1 = try FileHash.compute(expectedFile, algorithm: .sha1)
        let group = OfficialWebDownloadGroup(
            id: expectedSHA1,
            expectedSHA1: expectedSHA1,
            pageURL: URL(string: "https://www.curseforge.com/minecraft/mc-mods/example")!,
            records: [record(fileID: 20, destination: "mods/existing.jar", sha1: expectedSHA1)]
        )

        var didThrow = false
        do {
            try OfficialWebDownloadPlacementService().place(stagedFile: staged, group: group, instanceRoot: root)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: destination) == Data("preserve existing bytes".utf8))
    }

    @Test func plannerRejectsAbsoluteAndSymlinkEscapingDestinations() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "mods"),
            withDestinationURL: outside
        )
        let sha1 = String(repeating: "a", count: 40)
        let manifest = OfficialWebDownloadManifest(files: [
            record(fileID: 30, destination: "/tmp/escape.jar", sha1: sha1),
            record(fileID: 31, destination: "mods/escape.jar", sha1: sha1)
        ])

        let plan = OfficialWebDownloadPlanner.plan(manifest: manifest, instanceRoot: root)

        #expect(plan.groups.isEmpty)
        #expect(plan.blocked.count == 2)
        #expect(plan.blocked.allSatisfy { $0.reason == .unsafeDestination })
    }

    private func record(
        fileID: Int,
        destination: String,
        sha1: String?,
        page: URL? = URL(string: "https://www.curseforge.com/minecraft/mc-mods/example")!
    ) -> OfficialWebDownloadRecord {
        .init(
            projectID: 123,
            fileID: fileID,
            fileName: "artifact-\(fileID).jar",
            destination: destination,
            expectedSHA1: sha1,
            curseForgePage: page
        )
    }

    private func group(id: String, fileID: Int) -> OfficialWebDownloadGroup {
        .init(
            id: id,
            expectedSHA1: id,
            pageURL: URL(string: "https://www.curseforge.com/minecraft/mc-mods/example")!,
            records: [record(fileID: fileID, destination: "mods/\(fileID).jar", sha1: id)]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "pcl-official-web-download-tests-\(UUID().uuidString)")
    }
}
