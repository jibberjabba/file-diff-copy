import XCTest

/// Regression tests for the engine's data-safety guarantees (review items C1–C5).
/// Each test builds its own source/destination tree in a fresh temp directory.
final class FileSyncEngineTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // Deliberately the non-/private spelling (/var/folders/…), which the
        // enumerator reports back as /private/var/folders/… (C3).
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileSyncEngineTests-\(UUID().uuidString)")
        source      = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ text: String, to url: URL, date: Date? = nil) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    private func run(
        _ engine: FileSyncEngine = FileSyncEngine(),
        source: URL? = nil,
        mode: ComparisonMode = .fast,
        dryRun: Bool = false,
        confirmedOrphans: Set<String>? = nil
    ) async -> SyncProgress {
        var last: SyncProgress?
        await engine.sync(source: source ?? self.source, destination: destination, mode: mode,
                          dryRun: dryRun, confirmedOrphans: confirmedOrphans) { last = $0 }
        return last!
    }

    // MARK: - C1: Mirror never deletes on an untrustworthy source

    func testMirrorDeletesNothingWhenSourceIsUnavailable() async throws {
        let kept = try write("keep me", to: destination.appendingPathComponent("a.txt"))
        let missingSource = root.appendingPathComponent("unmounted-volume")

        let result = await run(source: missingSource, mode: .mirror, confirmedOrphans: ["a.txt"])

        XCTAssertTrue(exists(kept))
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertGreaterThan(result.errorCount, 0)
    }

    func testMirrorDeletesNothingWhenSourceIsEmpty() async throws {
        let kept = try write("keep me", to: destination.appendingPathComponent("a.txt"))

        let result = await run(mode: .mirror, confirmedOrphans: ["a.txt"])

        XCTAssertTrue(exists(kept))
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertGreaterThan(result.errorCount, 0)
    }

    func testMirrorDeletesOnlyConfirmedOrphans() async throws {
        try write("src", to: source.appendingPathComponent("present.txt"))
        let confirmed   = try write("x", to: destination.appendingPathComponent("confirmed.txt"))
        let unconfirmed = try write("y", to: destination.appendingPathComponent("appeared-later.txt"))

        let result = await run(mode: .mirror, confirmedOrphans: ["confirmed.txt"])

        XCTAssertFalse(exists(confirmed))
        XCTAssertTrue(exists(unconfirmed))
        XCTAssertEqual(result.deletedCount, 1)
    }

    func testRealMirrorWithoutConfirmationDeletesNothing() async throws {
        try write("src", to: source.appendingPathComponent("present.txt"))
        let orphan = try write("x", to: destination.appendingPathComponent("orphan.txt"))

        let result = await run(mode: .mirror, confirmedOrphans: nil)

        XCTAssertTrue(exists(orphan))
        XCTAssertEqual(result.deletedCount, 0)
    }

    func testMirrorPreviewListsOrphansWithoutDeleting() async throws {
        try write("src", to: source.appendingPathComponent("present.txt"))
        let orphan = try write("x", to: destination.appendingPathComponent("sub/orphan.txt"))

        let result = await run(mode: .mirror, dryRun: true)

        XCTAssertTrue(exists(orphan))
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(result.logEntries.contains { $0.relativePath == "sub/orphan.txt" })
    }

    func testFindOrphansThrowsWhenSourceIsUnavailable() async throws {
        try write("x", to: destination.appendingPathComponent("a.txt"))
        let engine = FileSyncEngine()
        do {
            _ = try await engine.findOrphans(source: root.appendingPathComponent("missing"),
                                             destination: destination)
            XCTFail("Expected findOrphans to throw")
        } catch let error as MirrorSafetyError {
            XCTAssertEqual(error, .sourceUnavailable)
        }
    }

    // MARK: - C2: unreadable source folders are reported and block Mirror

    func testUnreadableSourceFolderIsReportedAndBlocksMirrorDeletion() async throws {
        try write("src", to: source.appendingPathComponent("readable.txt"))
        let lockedDir = source.appendingPathComponent("locked")
        try write("src", to: lockedDir.appendingPathComponent("inside.txt"))
        let destCopy = try write("dst", to: destination.appendingPathComponent("locked/inside.txt"))

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir.path)
        addTeardownBlock { [fm] in
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }

        let result = await run(mode: .mirror, confirmedOrphans: ["locked/inside.txt"])

        XCTAssertTrue(exists(destCopy), "A file hidden by an unreadable source folder must not be deleted")
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertGreaterThan(result.errorCount, 0)
        XCTAssertTrue(result.logEntries.contains {
            if case .error = $0.action { return $0.relativePath.contains("locked") } else { return false }
        })
    }

    // MARK: - C3: relative paths are correct whatever spelling the root uses

    func testRelativePathsSurvivePrivatePrefixResolution() async throws {
        XCTAssertFalse(source.path.hasPrefix("/private/"), "Test needs the /var spelling of the temp dir")
        try write("nested", to: source.appendingPathComponent("sub/file.txt"))

        let result = await run()

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(try read(destination.appendingPathComponent("sub/file.txt")), "nested")
    }

    func testSymlinkedSourceRootIsFollowed() async throws {
        try write("via link", to: source.appendingPathComponent("file.txt"))
        let link = root.appendingPathComponent("source-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)

        let result = await run(source: link)

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(try read(destination.appendingPathComponent("file.txt")), "via link")
    }

    func testMirrorThroughSymlinkedSourceKeepsMatchingFiles() async throws {
        try write("same", to: source.appendingPathComponent("file.txt"))
        let destFile = try write("same", to: destination.appendingPathComponent("file.txt"))
        let link = root.appendingPathComponent("source-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)

        let result = await run(source: link, mode: .mirror, confirmedOrphans: ["file.txt"])

        XCTAssertTrue(exists(destFile))
        XCTAssertEqual(result.deletedCount, 0)
    }

    func testRelativePathAcceptsEitherRootSpelling() {
        let prefixes = FileSyncEngine.rootPrefixes(for: URL(fileURLWithPath: "/tmp/root"))
        XCTAssertEqual(FileSyncEngine.relativePath(of: URL(fileURLWithPath: "/private/tmp/root/a/b.txt"),
                                                   prefixes: prefixes), "a/b.txt")
        XCTAssertEqual(FileSyncEngine.relativePath(of: URL(fileURLWithPath: "/tmp/root/a/b.txt"),
                                                   prefixes: prefixes), "a/b.txt")
        XCTAssertNil(FileSyncEngine.relativePath(of: URL(fileURLWithPath: "/tmp/rootish/b.txt"),
                                                 prefixes: prefixes))
    }

    // MARK: - C4: a failed copy never destroys the existing destination

    func testFailedCopyLeavesExistingDestinationIntact() async throws {
        let old = Date(timeIntervalSinceNow: -3600)
        try write("new, longer content", to: source.appendingPathComponent("doc.txt"))
        let destFile = try write("old", to: destination.appendingPathComponent("doc.txt"), date: old)

        let engine = FileSyncEngine()
        engine.copyItem = { _, partial in
            try "partial".write(to: partial, atomically: false, encoding: .utf8)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let result = await run(engine)

        XCTAssertEqual(result.errorCount, 1)
        XCTAssertEqual(try read(destFile), "old")
        let leftovers = try fm.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".fdc-") }
        XCTAssertEqual(leftovers, [], "Temp file should be cleaned up after a failed copy")
    }

    func testSuccessfulCopyReplacesContentAndKeepsSourceDate() async throws {
        let srcDate = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        try write("fresh", to: source.appendingPathComponent("doc.txt"), date: srcDate)
        let destFile = try write("stale!", to: destination.appendingPathComponent("doc.txt"),
                                 date: srcDate.addingTimeInterval(-86_400))

        let first = await run()
        XCTAssertEqual(first.copiedCount, 1)
        XCTAssertEqual(try read(destFile), "fresh")
        let destDate = try destFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        XCTAssertEqual(destDate.timeIntervalSinceReferenceDate.rounded(.down),
                       srcDate.timeIntervalSinceReferenceDate.rounded(.down))

        // A second run must see the files as in sync.
        let second = await run()
        XCTAssertEqual(second.copiedCount, 0)
        XCTAssertEqual(second.skippedCount, 1)
    }

    // MARK: - C5: cancellation is sticky

    func testCancelledEngineStaysCancelledWhenSyncIsCalled() async throws {
        try write("a", to: source.appendingPathComponent("a.txt"))
        let engine = FileSyncEngine()
        engine.cancel()

        let result = await run(engine)

        XCTAssertEqual(result.processedFiles, 0)
        XCTAssertFalse(exists(destination.appendingPathComponent("a.txt")))
        XCTAssertEqual(result.currentFile, "Cancelled.")
    }
}
