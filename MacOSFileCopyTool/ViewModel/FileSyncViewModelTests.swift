import XCTest

/// Regression tests for C5: a run abandoned by `resetForNextSession()` must not
/// write its state back into the UI or overlap a new run.
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
}
