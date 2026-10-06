import SwiftUI
import AppKit

@MainActor
final class FileSyncViewModel: ObservableObject {

    // MARK: - Published state

    @Published var sourceURL:      URL?
    @Published var destinationURL: URL?

    @Published var comparisonMode: ComparisonMode = .fast

    @Published var isRunning:      Bool = false
    @Published var isScanning:     Bool = false
    @Published var isComplete:     Bool = false
    @Published var isDryRun:       Bool = false
    @Published var syncHasStarted: Bool = false
    @Published var isPreparing:    Bool = false
    @Published var progress:   Double = 0
    @Published var statusMessage: String = ""

    @Published var copiedCount:  Int = 0
    @Published var skippedCount: Int = 0
    @Published var warningCount: Int = 0
    @Published var deletedCount: Int = 0
    @Published var ignoredCount: Int = 0
    @Published var errorCount:   Int = 0
    @Published var logEntries:   [LogEntry] = []

    @Published var sourceBookmarkUnavailable:      Bool = false
    @Published var destinationBookmarkUnavailable: Bool = false

    @Published var pendingMirrorConfirmation = false
    @Published var orphanedFiles: [String] = []
    /// Why the Mirror pre-scan refused to offer any deletions, if it did.
    @Published var mirrorScanError: String?

    var isMirrorEnabled: Bool { comparisonMode == .mirror }

    // MARK: - Private

    /// A fresh engine per run, so cancelling one run can never affect another.
    private var activeEngine: FileSyncEngine?
    /// The most recent run or scan. After `resetForNextSession()` it may still be
    /// winding down; the next run awaits it so two runs never overlap.
    private(set) var activeTask: Task<Void, Never>?
    private var prepareTimer: Task<Void, Never>?
    private var syncGeneration = 0
    /// The current run's uncapped log, written by the engine; Save Log exports it.
    private var fullLogURL: URL?
    /// How many entries the on-screen log shows before it stops growing.
    var logDisplayLimit = FileSyncEngine.defaultMaxLogEntries

    // MARK: - Init

    init() {
        restoreBookmarks()
    }

    // MARK: - Computed helpers

    var canStartSync: Bool {
        sourceURL != nil && destinationURL != nil && !isRunning && !isScanning
    }

    // MARK: - Folder selection

    func chooseSourceFolder() {
        guard let url = runFolderPanel(title: "Select Source Folder") else { return }
        sourceURL = url
        sourceBookmarkUnavailable = false
        BookmarkManager.save(url: url, key: BookmarkManager.sourceKey)
    }

    func chooseDestinationFolder() {
        guard let url = runFolderPanel(title: "Select Destination Folder") else { return }
        destinationURL = url
        destinationBookmarkUnavailable = false
        BookmarkManager.save(url: url, key: BookmarkManager.destinationKey)
    }

    // MARK: - Sync control

    func startSync() {
        mirrorScanError = nil
        if comparisonMode == .mirror {
            beginMirrorScan()
        } else {
            beginCopy()
        }
    }

    /// Runs the comparison without modifying any files.
    /// Mirror mode bypasses the confirmation sheet since nothing will be deleted.
    func startPreview() {
        mirrorScanError = nil
        beginCopy(dryRun: true)
    }

    func confirmMirror() {
        pendingMirrorConfirmation = false
        // Only the files the user just reviewed may be deleted.
        let confirmed = Set(orphanedFiles)
        orphanedFiles = []
        beginCopy(confirmedOrphans: confirmed)
    }

    func cancelMirror() {
        pendingMirrorConfirmation = false
        orphanedFiles = []
    }

    func cancelSync() {
        activeEngine?.cancel()
        statusMessage = "Cancelling…"
    }

    func resetForNextSession() {
        // Bumping the generation discards every queued progress update and the
        // completion handler of the run being abandoned.
        syncGeneration += 1
        activeEngine?.cancel()
        activeTask?.cancel()
        activeEngine              = nil
        isRunning                 = false
        isScanning                = false
        isComplete                = false
        isDryRun                  = false
        syncHasStarted            = false
        isPreparing               = false
        prepareTimer?.cancel()
        prepareTimer              = nil
        pendingMirrorConfirmation = false
        orphanedFiles             = []
        mirrorScanError           = nil
        progress                  = 0
        statusMessage             = ""
        copiedCount               = 0
        skippedCount              = 0
        warningCount              = 0
        deletedCount              = 0
        ignoredCount              = 0
        errorCount                = 0
        logEntries                = []
        discardFullLog()
    }

    // MARK: - Log export

    func saveLog() {
        let panel = NSSavePanel()
        panel.title                = "Save Copy Log"
        panel.nameFieldStringValue = "CopyLog.txt"
        panel.allowedContentTypes  = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try writeLog(to: url)
        } catch {
            print("FileSyncViewModel: Failed to save log: \(error.localizedDescription)")
        }
    }

    /// Writes every entry of the last run, including those past the on-screen cap.
    func writeLog(to url: URL) throws {
        if let fullLogURL, FileManager.default.fileExists(atPath: fullLogURL.path) {
            try Data(contentsOf: fullLogURL).write(to: url, options: .atomic)
        } else {
            // The log file couldn't be created; the on-screen entries are all we have.
            let content = logEntries.map(\.displayText).joined(separator: "\n")
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func discardFullLog() {
        if let fullLogURL { try? FileManager.default.removeItem(at: fullLogURL) }
        fullLogURL = nil
    }

    // MARK: - Private helpers

    private func beginMirrorScan() {
        guard let source = sourceURL, let destination = destinationURL else { return }

        syncGeneration += 1
        let generation = syncGeneration

        isScanning    = true
        statusMessage = "Scanning destination for orphaned files…"

        let engine   = FileSyncEngine()
        activeEngine = engine
        let previous = activeTask
        let sourceAccess      = source.startAccessingSecurityScopedResource()
        let destinationAccess = destination.startAccessingSecurityScopedResource()

        activeTask = Task {
            await previous?.value
            let result: Result<[String], Error>
            do {
                result = .success(try await engine.findOrphans(source: source, destination: destination))
            } catch {
                result = .failure(error)
            }

            if sourceAccess      { source.stopAccessingSecurityScopedResource() }
            if destinationAccess { destination.stopAccessingSecurityScopedResource() }

            guard self.syncGeneration == generation else { return }
            self.isScanning    = false
            self.statusMessage = ""
            switch result {
            case .success(let orphans):
                self.orphanedFiles = orphans
                self.pendingMirrorConfirmation = true
            case .failure(let error):
                self.mirrorScanError = "Mirror stopped — \(error.localizedDescription). Nothing was deleted."
            }
        }
    }

    private func beginCopy(dryRun: Bool = false, confirmedOrphans: Set<String>? = nil) {
        guard let source = sourceURL, let destination = destinationURL else { return }

        syncGeneration += 1
        let generation = syncGeneration

        isRunning      = true
        isComplete     = false
        isDryRun       = dryRun
        syncHasStarted = false
        isPreparing    = false
        progress       = 0

        prepareTimer?.cancel()
        prepareTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled,
                  self.isRunning, !self.syncHasStarted else { return }
            self.isPreparing = true
        }
        statusMessage = dryRun ? "Previewing…" : "Starting…"
        copiedCount   = 0
        skippedCount  = 0
        warningCount  = 0
        deletedCount  = 0
        ignoredCount  = 0
        errorCount    = 0
        logEntries    = []

        discardFullLog()
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDiffCopy-\(UUID().uuidString).log")
        fullLogURL = logFile

        let sourceAccess      = source.startAccessingSecurityScopedResource()
        let destinationAccess = destination.startAccessingSecurityScopedResource()

        let engine   = FileSyncEngine()
        engine.maxLogEntries = logDisplayLimit
        activeEngine = engine
        let previous = activeTask
        let mode     = comparisonMode

        activeTask = Task {
            // A run abandoned by resetForNextSession() may still be finishing its
            // current file — never let two runs touch the destination at once.
            await previous?.value
            await engine.sync(source: source, destination: destination, mode: mode,
                              dryRun: dryRun, confirmedOrphans: confirmedOrphans,
                              logFile: logFile) { syncProgress in
                // Awaited by the engine: updates stay in order and never queue up.
                await MainActor.run { [weak self] in
                    guard let self, self.syncGeneration == generation else { return }
                    self.syncHasStarted = true
                    self.isPreparing    = false
                    self.prepareTimer?.cancel()
                    self.progress       = syncProgress.fraction
                    let verb = dryRun ? "Previewing" : "Processing"
                    self.statusMessage = syncProgress.currentFile.isEmpty
                        ? ""
                        : "\(verb): \(syncProgress.currentFile)"
                    self.copiedCount   = syncProgress.copiedCount
                    self.skippedCount  = syncProgress.skippedCount
                    self.warningCount  = syncProgress.warningCount
                    self.deletedCount  = syncProgress.deletedCount
                    self.ignoredCount  = syncProgress.ignoredCount
                    self.errorCount    = syncProgress.errorCount
                    self.logEntries.append(contentsOf: syncProgress.newLogEntries)
                }
            }

            if sourceAccess      { source.stopAccessingSecurityScopedResource() }
            if destinationAccess { destination.stopAccessingSecurityScopedResource() }

            guard self.syncGeneration == generation else { return }
            self.isRunning    = false
            self.isComplete   = true
            // A cancelled run keeps the bar where it stopped, so it doesn't look finished.
            if !engine.isCancelled { self.progress = 1.0 }
            self.statusMessage = engine.isCancelled
                ? "Cancelled."
                : dryRun
                    ? "Preview complete — no files were modified."
                    : "Sync complete."
        }
    }

    private func runFolderPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title                   = title
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories    = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func restoreBookmarks() {
        switch BookmarkManager.restore(key: BookmarkManager.sourceKey) {
        case .success(let url):
            sourceURL = url
            sourceBookmarkUnavailable = false
        case .unavailable:
            sourceBookmarkUnavailable = true
        case .notStored:
            break
        }

        switch BookmarkManager.restore(key: BookmarkManager.destinationKey) {
        case .success(let url):
            destinationURL = url
            destinationBookmarkUnavailable = false
        case .unavailable:
            destinationBookmarkUnavailable = true
        case .notStored:
            break
        }
    }
}
