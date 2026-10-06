import XCTest

/// Regression tests for C5 (a run abandoned by `resetForNextSession()` must not
/// write its state back into the UI or overlap a new run) and H3/H4 (log export
/// and progress delivery).
@MainActor
final class FileSyncViewModelTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private let fileCount = 300

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileSyncViewModelTests-\(UUID().uuidString)")
        source      = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            try "file \(i)".write(to: source.appendingPathComponent("f\(i).txt"), atomically: false, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeViewModel() -> FileSyncViewModel {
        let vm = FileSyncViewModel()
        vm.sourceURL      = source
        vm.destinationURL = destination
        vm.comparisonMode = .fast
        return vm
    }

    /// Lets queued `Task { @MainActor }` progress closures run.
    private func drainMainActor() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testResetDiscardsAbandonedRunState() async throws {
        let vm = makeViewModel()
        vm.startSync()
        vm.resetForNextSession()

        await vm.activeTask?.value
        try await drainMainActor()

        XCTAssertFalse(vm.isComplete, "Abandoned run's completion must not mark the session complete")
        XCTAssertFalse(vm.isRunning)
        XCTAssertEqual(vm.statusMessage, "")
        XCTAssertEqual(vm.copiedCount, 0)
        XCTAssertTrue(vm.logEntries.isEmpty)
    }

    func testNewRunAfterResetIsNotClobberedByAbandonedRun() async throws {
        let vm = makeViewModel()
        vm.startSync()
        vm.resetForNextSession()
        vm.startSync()

        await vm.activeTask?.value
        try await drainMainActor()

        XCTAssertTrue(vm.isComplete)
        XCTAssertFalse(vm.isRunning)
        XCTAssertEqual(vm.statusMessage, "Sync complete.")
        // Every file is accounted for exactly once by the new run, whatever the
        // abandoned run managed to copy before it stopped.
        XCTAssertEqual(vm.copiedCount + vm.skippedCount + vm.warningCount, fileCount)
        XCTAssertEqual(vm.errorCount, 0)
    }

    func testMirrorScanErrorIsSurfacedAndNoSheetShown() async throws {
        let vm = makeViewModel()
        vm.sourceURL = root.appendingPathComponent("unmounted")
        vm.comparisonMode = .mirror
        vm.startSync()

        await vm.activeTask?.value

        XCTAssertFalse(vm.pendingMirrorConfirmation)
        XCTAssertNotNil(vm.mirrorScanError)
        XCTAssertFalse(vm.isScanning)
    }

    // MARK: - Window reset on each run

    func testStartAndPreviewEachSignalANewRun() async throws {
        let vm = makeViewModel()
        XCTAssertEqual(vm.runStartCount, 0)

        vm.startSync()
        XCTAssertEqual(vm.runStartCount, 1, "Start must signal the window to reset")
        await vm.activeTask?.value

        vm.startPreview()
        XCTAssertEqual(vm.runStartCount, 2, "Preview must signal the window to reset")
        await vm.activeTask?.value
    }

    func testMirrorSignalsANewRunOnlyOnceConfirmed() async throws {
        let vm = makeViewModel()
        vm.comparisonMode = .mirror

        // The scan keeps the last log on screen, so the window stays put.
        vm.startSync()
        await vm.activeTask?.value
        XCTAssertTrue(vm.pendingMirrorConfirmation)
        XCTAssertEqual(vm.runStartCount, 0)

        vm.cancelMirror()
        XCTAssertEqual(vm.runStartCount, 0, "Cancelling the sheet starts nothing")

        vm.startSync()
        await vm.activeTask?.value
        vm.confirmMirror()
        XCTAssertEqual(vm.runStartCount, 1)
        await vm.activeTask?.value
    }

    func testRunWithoutFoldersDoesNotSignal() {
        let vm = makeViewModel()
        vm.destinationURL = nil
        vm.startPreview()
        XCTAssertEqual(vm.runStartCount, 0)
    }

    // MARK: - H3 / H4

    func testSavedLogIncludesEntriesPastTheScreenCap() async throws {
        let vm = makeViewModel()
        vm.logDisplayLimit = 10
        vm.startSync()
        await vm.activeTask?.value

        XCTAssertEqual(vm.logEntries.count, 11, "10 entries plus the truncation notice")

        let saved = root.appendingPathComponent("saved.txt")
        try vm.writeLog(to: saved)
        let lines = try String(contentsOf: saved, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, fileCount)
        XCTAssertFalse(lines.contains { $0.hasPrefix("[NOTE]") })
    }

    /// Contract test for the awaited progress callback. It also passes with the
    /// old fire-and-forget `Task { @MainActor }` delivery, because main-actor
    /// tasks happen to run in FIFO order; the await is what makes it guaranteed.
    func testEveryProgressUpdateIsAppliedBeforeTheRunCompletes() async throws {
        let vm = makeViewModel()
        vm.startSync()
        await vm.activeTask?.value
        // No drainMainActor(): nothing may still be queued once the run has ended.

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.copiedCount, fileCount)
        XCTAssertEqual(vm.logEntries.count, fileCount)
    }

    // MARK: - Low: a cancelled run doesn't show a full progress bar

    func testCancelledRunKeepsPartialProgress() async throws {
        let vm = makeViewModel()
        vm.startSync()
        vm.cancelSync()
        await vm.activeTask?.value

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.statusMessage, "Cancelled.")
        XCTAssertLessThan(vm.progress, 1.0)
        XCTAssertLessThan(vm.copiedCount, fileCount)
    }

    func testFinishedRunShowsFullProgress() async throws {
        let vm = makeViewModel()
        vm.startSync()
        await vm.activeTask?.value

        XCTAssertEqual(vm.progress, 1.0)
    }
}

// MARK: - Swap Source and Destination

extension FileSyncViewModelTests {

    /// Runs `body` with bookmarks stored in a throwaway suite, so swapping never
    /// touches the folders saved in the real preferences.
    private func withScratchBookmarks(_ body: () throws -> Void) rethrows {
        let suiteName = "FileSyncViewModelTests-\(UUID().uuidString)"
        BookmarkManager.defaults = UserDefaults(suiteName: suiteName)!
        defer {
            BookmarkManager.defaults.removePersistentDomain(forName: suiteName)
            BookmarkManager.defaults = .standard
        }
        try body()
    }

    func testSwapExchangesFoldersAndSavedBookmarks() {
        withScratchBookmarks {
            let vm = makeViewModel()
            BookmarkManager.save(url: source, key: BookmarkManager.sourceKey)
            BookmarkManager.save(url: destination, key: BookmarkManager.destinationKey)

            vm.swapFolders()

            XCTAssertEqual(vm.sourceURL, destination)
            XCTAssertEqual(vm.destinationURL, source)
            guard case .success(let savedSource) = BookmarkManager.restore(key: BookmarkManager.sourceKey) else {
                return XCTFail("source bookmark missing after swap")
            }
            XCTAssertEqual(savedSource.resolvingSymlinksInPath().path,
                           destination.resolvingSymlinksInPath().path)
        }
    }

    func testSwapCarriesTheUnavailableWarning() {
        withScratchBookmarks {
            let vm = makeViewModel()
            vm.sourceURL = nil
            vm.sourceBookmarkUnavailable = true

            vm.swapFolders()

            XCTAssertEqual(vm.sourceURL, destination)
            XCTAssertNil(vm.destinationURL)
            XCTAssertFalse(vm.sourceBookmarkUnavailable)
            XCTAssertTrue(vm.destinationBookmarkUnavailable)
        }
    }

    func testSwapIsRefusedWhileRunning() async {
        let suiteName = "FileSyncViewModelTests-\(UUID().uuidString)"
        BookmarkManager.defaults = UserDefaults(suiteName: suiteName)!
        defer {
            BookmarkManager.defaults.removePersistentDomain(forName: suiteName)
            BookmarkManager.defaults = .standard
        }
        let vm = makeViewModel()
        vm.startSync()
        XCTAssertFalse(vm.canSwapFolders)

        vm.swapFolders()

        XCTAssertEqual(vm.sourceURL, source)
        XCTAssertEqual(vm.destinationURL, destination)
        await vm.activeTask?.value
    }

    func testSwapClearsAStaleMirrorScanError() {
        withScratchBookmarks {
            let vm = makeViewModel()
            vm.mirrorScanError = "Source folder unavailable"

            vm.swapFolders()

            XCTAssertNil(vm.mirrorScanError)
        }
    }
}
