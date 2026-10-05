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

    // MARK: - New-file fast path (no temp file when there's nothing to protect)

    /// Wraps the real copy and records every path the engine copied to.
    private func recordingCopy(into targets: @escaping (URL) -> Void) -> (URL, URL) throws -> Void {
        { source, destination in
            targets(destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    func testNewFileIsCopiedDirectlyWithoutTempFile() async throws {
        let srcDate = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        try write("brand new", to: source.appendingPathComponent("sub/new.txt"), date: srcDate)
        let destFile = destination.appendingPathComponent("sub/new.txt")

        var targets: [URL] = []
        let engine = FileSyncEngine()
        engine.copyItem = recordingCopy { targets.append($0) }
        let result = await run(engine)

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(targets.map(\.lastPathComponent), ["new.txt"], "New files should skip the temp file")
        XCTAssertEqual(try read(destFile), "brand new")
        let destDate = try destFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        XCTAssertEqual(destDate.timeIntervalSinceReferenceDate.rounded(.down),
                       srcDate.timeIntervalSinceReferenceDate.rounded(.down))
    }

    func testOverwriteStillGoesThroughTempFile() async throws {
        try write("new content", to: source.appendingPathComponent("doc.txt"))
        try write("old", to: destination.appendingPathComponent("doc.txt"),
                  date: Date(timeIntervalSinceNow: -3600))

        var targets: [URL] = []
        let engine = FileSyncEngine()
        engine.copyItem = recordingCopy { targets.append($0) }
        let result = await run(engine)

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(targets.count, 1)
        XCTAssertTrue(targets[0].lastPathComponent.hasPrefix(".fdc-"), "Overwrites must use a temp file")
        XCTAssertEqual(try read(destination.appendingPathComponent("doc.txt")), "new content")
    }

    func testFailedNewFileCopyRemovesPartialFile() async throws {
        try write("brand new", to: source.appendingPathComponent("new.txt"))
        let destFile = destination.appendingPathComponent("new.txt")

        let engine = FileSyncEngine()
        engine.copyItem = { _, partial in
            try "part".write(to: partial, atomically: false, encoding: .utf8)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let first = await run(engine)

        XCTAssertEqual(first.errorCount, 1)
        XCTAssertFalse(exists(destFile), "A partial new file must not be left behind")

        // Date Only would never retry a leftover partial (its date is newer), so
        // the retry succeeding here proves nothing was left in the way.
        let retry = await run(mode: .archive)
        XCTAssertEqual(retry.copiedCount, 1)
        XCTAssertEqual(try read(destFile), "brand new")
    }

    func testNewFileRaceLeavesOtherWritersFileAlone() async throws {
        try write("ours", to: source.appendingPathComponent("new.txt"))
        let destFile = destination.appendingPathComponent("new.txt")

        let engine = FileSyncEngine()
        engine.copyItem = { _, target in
            // Another process creates the file between our check and our copy.
            try "theirs".write(to: target, atomically: false, encoding: .utf8)
            throw CocoaError(.fileWriteFileExists)
        }
        let result = await run(engine)

        XCTAssertEqual(result.errorCount, 1)
        XCTAssertEqual(try read(destFile), "theirs")
    }

    // MARK: - H1: a newer destination is never overwritten

    private let older = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var newer: Date { older.addingTimeInterval(3600) }

    /// Destination was edited after the source, so its size or content differs.
    private func makeEditedDestination(sameSize: Bool = false) throws -> URL {
        try write(sameSize ? "AAAA" : "original", to: source.appendingPathComponent("notes.txt"), date: older)
        return try write(sameSize ? "BBBB" : "original + edits made at the destination",
                         to: destination.appendingPathComponent("notes.txt"), date: newer)
    }

    private func assertKeptAsNewerDestination(_ result: SyncProgress, _ destFile: URL,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(result.copiedCount, 0, file: file, line: line)
        XCTAssertEqual(result.warningCount, 1, file: file, line: line)
        XCTAssertTrue(result.logEntries.contains {
            if case .newerDestination = $0.action { return $0.relativePath == "notes.txt" } else { return false }
        }, "Expected a [NEWER DST] entry", file: file, line: line)
        XCTAssertNotEqual(try read(destFile), try read(source.appendingPathComponent("notes.txt")),
                          "Destination edits must survive", file: file, line: line)
    }

    func testFastKeepsNewerDestinationWithDifferentSize() async throws {
        let destFile = try makeEditedDestination()
        try assertKeptAsNewerDestination(await run(mode: .fast), destFile)
    }

    func testMirrorKeepsNewerDestinationWithDifferentSize() async throws {
        let destFile = try makeEditedDestination()
        try assertKeptAsNewerDestination(await run(mode: .mirror, confirmedOrphans: []), destFile)
    }

    func testThoroughKeepsNewerDestinationWithDifferentContent() async throws {
        let destFile = try makeEditedDestination(sameSize: true)
        try assertKeptAsNewerDestination(await run(mode: .thorough), destFile)
    }

    func testPreviewReportsNewerDestinationInsteadOfWouldCopy() async throws {
        let destFile = try makeEditedDestination()
        try assertKeptAsNewerDestination(await run(mode: .fast, dryRun: true), destFile)
    }

    func testFastStillCopiesSizeChangeWhenDatesAreEqual() async throws {
        try write("short", to: source.appendingPathComponent("notes.txt"), date: older)
        let destFile = try write("much longer old text", to: destination.appendingPathComponent("notes.txt"),
                                 date: older)

        let result = await run(mode: .fast)

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(try read(destFile), "short")
    }

    // MARK: - H2: a source file never replaces a destination folder

    private func makeFolderCollision() throws -> URL {
        try write("I am a file", to: source.appendingPathComponent("photos"), date: newer)
        return try write("precious", to: destination.appendingPathComponent("photos/IMG_0001.jpg"), date: older)
    }

    func testSourceFileDoesNotReplaceDestinationFolder() async throws {
        for mode in ComparisonMode.allCases {
            let inner = try makeFolderCollision()

            let result = await run(mode: mode, confirmedOrphans: [])

            XCTAssertEqual(try read(inner), "precious", "\(mode.label): folder contents must survive")
            XCTAssertEqual(result.copiedCount, 0, mode.label)
            XCTAssertEqual(result.errorCount, 1, mode.label)
            XCTAssertTrue(result.logEntries.contains {
                if case .error = $0.action { return $0.relativePath == "photos" } else { return false }
            }, "\(mode.label): expected an [ERROR] entry for the collision")
        }
    }

    func testFolderCollisionIsReportedInPreview() async throws {
        let inner = try makeFolderCollision()

        let result = await run(mode: .fast, dryRun: true)

        XCTAssertEqual(result.copiedCount, 0, "Preview must not claim it would replace a folder")
        XCTAssertEqual(result.errorCount, 1)
        XCTAssertTrue(exists(inner))
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
