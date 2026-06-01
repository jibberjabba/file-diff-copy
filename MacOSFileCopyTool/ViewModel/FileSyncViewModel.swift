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
    @Published var errorCount:   Int = 0
    @Published var logEntries:   [LogEntry] = []

    @Published var sourceBookmarkUnavailable:      Bool = false
    @Published var destinationBookmarkUnavailable: Bool = false

    @Published var pendingMirrorConfirmation = false
    @Published var orphanedFiles: [String] = []

    var isMirrorEnabled: Bool { comparisonMode == .mirror }

    // MARK: - Private

    private let engine        = FileSyncEngine()
    private var activeTask:   Task<Void, Never>?
    private var prepareTimer: Task<Void, Never>?
    private var syncGeneration = 0

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
        if comparisonMode == .mirror {
            beginMirrorScan()
        } else {
            beginCopy()
        }
    }

    /// Runs the comparison without modifying any files.
    /// Mirror mode bypasses the confirmation sheet since nothing will be deleted.
    func startPreview() {
        beginCopy(dryRun: true)
    }

    func confirmMirror() {
        pendingMirrorConfirmation = false
        orphanedFiles = []
        beginCopy()
    }

    func cancelMirror() {
        pendingMirrorConfirmation = false
        orphanedFiles = []
    }

    func cancelSync() {
        engine.cancel()
        statusMessage = "Cancelling…"
    }

    func resetForNextSession() {
        if isRunning { engine.cancel() }
        activeTask?.cancel()
        activeTask                = nil
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
        progress                  = 0
        statusMessage             = ""
        copiedCount               = 0
        skippedCount              = 0
        warningCount              = 0
        deletedCount              = 0
        errorCount                = 0
        logEntries                = []
    }

    // MARK: - Log export

    func saveLog() {
        let panel = NSSavePanel()
        panel.title                = "Save Copy Log"
        panel.nameFieldStringValue = "CopyLog.txt"
        panel.allowedContentTypes  = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = logEntries.map(\.displayText).joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("FileSyncViewModel: Failed to save log: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    private func beginMirrorScan() {
        guard let source = sourceURL, let destination = destinationURL else { return }

        isScanning    = true
        statusMessage = "Scanning destination for orphaned files…"

        let engine = self.engine
        _ = source.startAccessingSecurityScopedResource()
        _ = destination.startAccessingSecurityScopedResource()

        activeTask = Task {
            let orphans = await engine.findOrphans(source: source, destination: destination)

            source.stopAccessingSecurityScopedResource()
            destination.stopAccessingSecurityScopedResource()

            self.isScanning    = false
            self.statusMessage = ""
            self.orphanedFiles = orphans.map { url in
                String(url.path.dropFirst(destination.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            self.pendingMirrorConfirmation = true
        }
    }

    private func beginCopy(dryRun: Bool = false) {
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
        errorCount    = 0
        logEntries    = []

        _ = source.startAccessingSecurityScopedResource()
        _ = destination.startAccessingSecurityScopedResource()

        let engine = self.engine
        let mode   = comparisonMode

        activeTask = Task {
            await engine.sync(source: source, destination: destination, mode: mode, dryRun: dryRun) { syncProgress in
                Task { @MainActor [weak self] in
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
                    self.errorCount    = syncProgress.errorCount
                    self.logEntries    = syncProgress.logEntries
                }
            }

            source.stopAccessingSecurityScopedResource()
            destination.stopAccessingSecurityScopedResource()

            self.isRunning    = false
            self.isComplete   = true
            self.progress     = 1.0
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
