import SwiftUI
import AppKit

/// Drives the UI. Owns the `FileSyncEngine`, exposes `@Published` state for
/// SwiftUI bindings, and handles all security-scoped resource access.
@MainActor
final class FileSyncViewModel: ObservableObject {

    // MARK: - Published state (consumed by the views)

    @Published var sourceURL:      URL?
    @Published var destinationURL: URL?

    @Published var comparisonMode: ComparisonMode = .fast

    @Published var isRunning:  Bool   = false
    @Published var isScanning: Bool   = false
    @Published var isComplete: Bool   = false
    @Published var progress:   Double = 0
    @Published var statusMessage: String = ""

    @Published var copiedCount:  Int = 0
    @Published var skippedCount: Int = 0
    @Published var deletedCount: Int = 0
    @Published var errorCount:   Int = 0
    @Published var logEntries:   [LogEntry] = []

    /// Populated by the Mirror pre-scan; triggers the confirmation sheet.
    @Published var pendingMirrorConfirmation = false
    @Published var orphanedFiles: [String] = []

    // MARK: - Private

    private let engine     = FileSyncEngine()
    private var activeTask: Task<Void, Never>?
    /// Incremented each time a new sync starts so stale onProgress closures
    /// from a previous run can be discarded before they overwrite fresh state.
    private var syncGeneration = 0

    // MARK: - Init

    init() {
        restoreBookmarks()
    }

    // MARK: - Computed helpers

    /// True when both folders are set and no sync or scan is currently running.
    var canStartSync: Bool {
        sourceURL != nil && destinationURL != nil && !isRunning && !isScanning
    }

    // MARK: - Folder selection

    /// Opens a folder picker and stores the selected source URL.
    func chooseSourceFolder() {
        guard let url = runFolderPanel(title: "Select Source Folder") else { return }
        sourceURL = url
        BookmarkManager.save(url: url, key: BookmarkManager.sourceKey)
    }

    /// Opens a folder picker and stores the selected destination URL.
    func chooseDestinationFolder() {
        guard let url = runFolderPanel(title: "Select Destination Folder") else { return }
        destinationURL = url
        BookmarkManager.save(url: url, key: BookmarkManager.destinationKey)
    }

    // MARK: - Sync control

    /// Entry point for the Start button. Mirror mode runs a pre-scan first;
    /// all other modes go straight to the copy engine.
    func startSync() {
        if comparisonMode == .mirror {
            beginMirrorScan()
        } else {
            beginCopy()
        }
    }

    /// Called when the user taps "Delete and Sync" in the confirmation sheet.
    func confirmMirror() {
        pendingMirrorConfirmation = false
        orphanedFiles = []
        beginCopy()
    }

    /// Called when the user taps "Cancel" in the confirmation sheet.
    func cancelMirror() {
        pendingMirrorConfirmation = false
        orphanedFiles = []
    }

    /// Requests a graceful cancellation of the running sync.
    func cancelSync() {
        engine.cancel()
        statusMessage = "Cancelling…"
    }

    /// Resets all progress and log state back to the initial empty condition.
    /// Called when the window is closed so it opens fresh next time.
    func resetForNextSession() {
        if isRunning { engine.cancel() }
        activeTask?.cancel()
        activeTask                = nil
        isRunning                 = false
        isScanning                = false
        isComplete                = false
        pendingMirrorConfirmation = false
        orphanedFiles             = []
        progress                  = 0
        statusMessage             = ""
        copiedCount               = 0
        skippedCount              = 0
        deletedCount              = 0
        errorCount                = 0
        logEntries                = []
    }

    // MARK: - Log export

    /// Opens a save panel and writes the current log to a plain-text file.
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

    /// Enumerates the destination for orphaned files and surfaces the
    /// confirmation sheet without touching any files.
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

    /// Starts the copy engine for the currently selected mode.
    private func beginCopy() {
        guard let source = sourceURL, let destination = destinationURL else { return }

        syncGeneration += 1
        let generation = syncGeneration

        isRunning     = true
        isComplete    = false
        progress      = 0
        statusMessage = "Starting…"
        copiedCount   = 0
        skippedCount  = 0
        deletedCount  = 0
        errorCount    = 0
        logEntries    = []

        _ = source.startAccessingSecurityScopedResource()
        _ = destination.startAccessingSecurityScopedResource()

        let engine = self.engine
        let mode   = comparisonMode

        activeTask = Task {
            await engine.sync(source: source, destination: destination, mode: mode) { syncProgress in
                Task { @MainActor [weak self] in
                    guard let self, self.syncGeneration == generation else { return }
                    self.progress      = syncProgress.fraction
                    self.statusMessage = syncProgress.currentFile.isEmpty
                        ? ""
                        : "Processing: \(syncProgress.currentFile)"
                    self.copiedCount   = syncProgress.copiedCount
                    self.skippedCount  = syncProgress.skippedCount
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
            self.statusMessage = engine.isCancelled ? "Cancelled." : "Sync complete."
        }
    }

    /// Runs a modal folder-selection open panel and returns the chosen URL, or nil if cancelled.
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

    /// Attempts to restore previously bookmarked source and destination folders.
    private func restoreBookmarks() {
        if let url = BookmarkManager.restore(key: BookmarkManager.sourceKey) {
            sourceURL = url
        }
        if let url = BookmarkManager.restore(key: BookmarkManager.destinationKey) {
            destinationURL = url
        }
    }
}
