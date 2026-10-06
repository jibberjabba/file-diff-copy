import Foundation
import os

// MARK: - Copy reason

/// Why a file needs to be copied to the destination.
enum CopyReason: CustomStringConvertible {
    case newFile
    case sizeChanged
    case dateNewer
    case xattrChanged
    case contentDiffered

    var description: String {
        switch self {
        case .newFile:          return "new file"
        case .sizeChanged:      return "size changed"
        case .dateNewer:        return "source is newer"
        case .xattrChanged:     return "metadata changed"
        case .contentDiffered:  return "content changed"
        }
    }
}

// MARK: - Data types

/// The action taken (or that would be taken in a dry run) for a single file.
enum FileSyncAction: CustomStringConvertible {
    case copied(CopyReason)     // file was copied
    case wouldCopy(CopyReason)  // dry-run: file would be copied
    case skipped
    case deleted
    case wouldDelete            // dry-run: file would be deleted (Mirror)
    case newerDestination       // dst mod-date is strictly newer than src
    case sizeMismatch           // same date but different sizes (Date Only mode only)
    case notice(String)         // informational message, not a file action
    case ignored(String)        // source item the app never copies (hidden, symlink, …)
    case error(String)

    var description: String {
        switch self {
        case .copied(let r):    return "copied(\(r))"
        case .wouldCopy(let r): return "wouldCopy(\(r))"
        case .skipped:          return "skipped"
        case .deleted:          return "deleted"
        case .wouldDelete:      return "wouldDelete"
        case .newerDestination: return "newerDestination"
        case .sizeMismatch:     return "sizeMismatch"
        case .notice(let msg):  return "notice(\(msg))"
        case .ignored(let r):   return "ignored(\(r))"
        case .error(let r):     return "error(\(r))"
        }
    }
}

/// A single entry in the copy log.
struct LogEntry: Identifiable {
    let id = UUID()
    let action: FileSyncAction
    let relativePath: String

    var displayText: String {
        switch action {
        case .copied(let r):    return "[COPIED]     \(relativePath)  (\(r))"
        case .wouldCopy(let r): return "[WOULD COPY] \(relativePath)  (\(r))"
        case .skipped:          return "[SKIPPED]    \(relativePath)"
        case .deleted:          return "[DELETED]    \(relativePath)"
        case .wouldDelete:      return "[WOULD DEL]  \(relativePath)"
        case .newerDestination: return "[NEWER DST]  \(relativePath)"
        case .sizeMismatch:     return "[SIZE DIFF]  \(relativePath)"
        case .notice(let msg):  return "[NOTE]       \(msg)"
        case .ignored(let r):   return "[IGNORED]    \(relativePath)  (\(r))"
        case .error(let r):     return "[ERROR]      \(relativePath) — \(r)"
        }
    }
}

/// A snapshot of sync progress. Updates are throttled (see
/// `FileSyncEngine.progressInterval`), and each one carries only the log entries
/// added since the previous update — the receiver appends them.
struct SyncProgress {
    var totalFiles:     Int
    var processedFiles: Int
    var copiedCount:    Int
    var skippedCount:   Int
    var warningCount:   Int
    var deletedCount:   Int
    var ignoredCount:   Int = 0
    var errorCount:     Int
    var currentFile:    String
    var newLogEntries:  [LogEntry] = []
    var isDryRun:       Bool = false

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }
}

// MARK: - Comparison mode

enum ComparisonMode: CaseIterable, Hashable {
    case fast
    case thorough
    case dateOnly
    case mirror

    var label: String {
        switch self {
        case .fast:     return "Fast"
        case .thorough: return "Thorough"
        case .dateOnly: return "Date Only"
        case .mirror:   return "Mirror"
        }
    }

    var tooltip: String {
        switch self {
        case .fast:
            return "Size + modification date"
        case .thorough:
            return "Byte-by-byte content + extended attributes — detects any content or metadata change"
        case .dateOnly:
            return "Modification date only — copy when source is newer; identical dates skip regardless of size"
        case .mirror:
            return "Fast copy, then permanently deletes destination files not present in source"
        }
    }
}

// MARK: - Scanning

/// A regular file found under a scanned root, with its path relative to that root.
struct ScannedFile {
    let url: URL
    let relativePath: String
}

/// The result of walking one folder tree. `failures` holds every item that could
/// not be read — a non-empty list means the file list is incomplete.
struct ScanResult {
    var files:    [ScannedFile] = []
    var failures: [(path: String, message: String)] = []
    /// Items that are deliberately not synced, with the reason.
    var ignored:  [(relativePath: String, reason: String)] = []
}

/// Why a scanned item is not synced. Hidden folders count as one item; their
/// contents are not walked.
enum IgnoreReason {
    static let hiddenFile   = "hidden file — not copied"
    static let hiddenFolder = "hidden folder — not copied"
    static let symlink      = "symbolic link — not followed"
    static let special      = "not a regular file or folder"
}

/// Per-file errors the engine raises itself (reported in the log like I/O errors).
enum SyncFileError: LocalizedError, Equatable {
    case destinationIsFolder
    /// The run was cancelled part-way through this file's copy or comparison.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .destinationIsFolder:
            return "a folder with this name exists at the destination — not replaced"
        case .cancelled:
            return "cancelled"
        }
    }
}

/// Reasons the Mirror deletion pass refuses to run. Each one means "absent from
/// the source" can't be trusted, so deleting would risk wiping good files.
enum MirrorSafetyError: LocalizedError, Equatable {
    case sourceUnavailable
    case sourceEmpty
    case scanIncomplete(Int)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:     return "the source folder is unavailable"
        case .sourceEmpty:           return "the source folder contains no files"
        case .scanIncomplete(let n): return "\(n) item(s) could not be read while scanning"
        }
    }
}

// MARK: - Engine

/// Pure Swift sync engine — no SwiftUI dependency, fully testable in isolation.
///
/// Create a new engine for every run: cancellation is sticky, so a cancelled
/// engine can never be revived by a later `sync()` call.
///
/// Pass `dryRun: true` to preview what would happen without modifying any files.
/// Log entries use `.wouldCopy` / `.wouldDelete` in dry-run mode.
final class FileSyncEngine {

    private let logger = Logger(subsystem: "com.macos.filecopytool", category: "FileSyncEngine")

    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    /// Read from the engine's thread, written from the main actor — hence the lock.
    /// Also honours cancellation of the enclosing Swift `Task`.
    var isCancelled: Bool {
        cancelFlag.withLock { $0 } || Task.isCancelled
    }

    func cancel() {
        cancelFlag.withLock { $0 = true }
    }

    /// File-copy primitive. Tests replace it to simulate a copy failing part-way.
    /// The default stops part-way through a file when the run is cancelled.
    var copyItem: (URL, URL) throws -> Void = { _, _ in }

    init() {
        copyItem = { [unowned self] source, destination in
            try Self.copyFile(from: source, to: destination, isCancelled: { self.isCancelled })
        }
    }

    /// Reads up to `count` bytes. Tests replace it to count how much of a file
    /// the content comparison actually reads.
    var readChunk: (FileHandle, Int) throws -> Data = { handle, count in
        try handle.read(upToCount: count) ?? Data()
    }

    /// Entries shown in the on-screen log; the rest go only to the full log file.
    static let defaultMaxLogEntries = 20_000
    var maxLogEntries = FileSyncEngine.defaultMaxLogEntries

    /// Minimum time between progress updates. The first and last are always sent.
    var progressInterval: Duration = .milliseconds(100)

    // MARK: - Public API

    /// - Parameter confirmedOrphans: relative paths the user approved for deletion
    ///   in the Mirror confirmation sheet. A real (non-dry-run) Mirror deletes only
    ///   files that are in this set *and* still orphaned now; `nil` deletes nothing.
    /// - Parameter logFile: if given, every log entry is written here as text,
    ///   uncapped — this is what Save Log exports.
    /// - Parameter onProgress: awaited before the engine continues, so updates
    ///   arrive in order and never pile up.
    func sync(
        source: URL,
        destination: URL,
        mode: ComparisonMode,
        dryRun: Bool = false,
        confirmedOrphans: Set<String>? = nil,
        logFile: URL? = nil,
        onProgress: (SyncProgress) async -> Void
    ) async {
        var progress = SyncProgress(
            totalFiles:     0,
            processedFiles: 0,
            copiedCount:    0,
            skippedCount:   0,
            warningCount:   0,
            deletedCount:   0,
            errorCount:     0,
            currentFile:    ""
        )
        progress.isDryRun = dryRun

        let log = RunLog(maxDisplayed: maxLogEntries, file: logFile, logger: logger)
        defer { log.close() }
        var lastReport: ContinuousClock.Instant?

        func appendLog(_ entry: LogEntry) { log.append(entry) }

        func report(force: Bool = false) async {
            let now = ContinuousClock.now
            if !force, let lastReport, now - lastReport < progressInterval { return }
            lastReport = now
            progress.newLogEntries = log.takePending()
            log.flush()
            await onProgress(progress)
        }

        // An unmounted volume must stop the run outright — never copy into, or
        // judge orphans against, a folder that isn't there.
        for (label, root) in [("Source", source), ("Destination", destination)]
        where !isReachableDirectory(root) {
            progress.errorCount += 1
            appendLog(LogEntry(action: .error("\(label) folder is unavailable"), relativePath: root.path))
            progress.currentFile = "\(label) folder is unavailable."
            await report(force: true)
            logger.error("\(label) folder unavailable: \(root.path)")
            return
        }

        let sourceScan = scan(source)
        for failure in sourceScan.failures {
            progress.errorCount += 1
            appendLog(LogEntry(action: .error(failure.message), relativePath: failure.path))
            logger.error("Could not read \(failure.path): \(failure.message)")
        }
        for item in sourceScan.ignored {
            progress.ignoredCount += 1
            appendLog(LogEntry(action: .ignored(item.reason), relativePath: item.relativePath))
        }

        // Pre-scan orphans for Mirror so their count is in the progress denominator.
        var orphans: [ScannedFile] = []
        if mode == .mirror {
            do {
                orphans = try mirrorOrphans(source: source, destination: destination, sourceScan: sourceScan)
                if !dryRun {
                    let confirmed = confirmedOrphans ?? []
                    orphans = orphans.filter { confirmed.contains($0.relativePath) }
                }
            } catch {
                progress.errorCount += 1
                appendLog(LogEntry(action: .error("Mirror deletions skipped — \(error.localizedDescription)"),
                                   relativePath: "(mirror)"))
                logger.error("Mirror deletions skipped: \(error.localizedDescription)")
            }
        }

        progress.totalFiles = sourceScan.files.count + orphans.count
        logger.debug("Sync started. \(sourceScan.files.count) source files\(dryRun ? " (dry run)" : "").")

        for file in sourceScan.files {
            if isCancelled { break }
            var stopped = false

            let relativePath = file.relativePath
            let destURL = destination.appendingPathComponent(relativePath)
            progress.currentFile = relativePath

            do {
                if let reason = try copyReason(source: file.url, destination: destURL, mode: mode) {
                    if !dryRun {
                        try performCopy(source: file.url, destination: destURL)
                    }
                    progress.copiedCount += 1
                    let action: FileSyncAction = dryRun ? .wouldCopy(reason) : .copied(reason)
                    appendLog(LogEntry(action: action, relativePath: relativePath))
                    logger.debug("\(dryRun ? "Would copy" : "Copied"): \(relativePath) (\(reason))")
                } else if let anomaly = try detectAnomaly(source: file.url,
                                                           destination: destURL,
                                                           mode: mode) {
                    progress.warningCount += 1
                    appendLog(LogEntry(action: anomaly, relativePath: relativePath))
                    logger.debug("Warning \(anomaly) on \(relativePath)")
                } else {
                    progress.skippedCount += 1
                    appendLog(LogEntry(action: .skipped, relativePath: relativePath))
                }
            } catch SyncFileError.cancelled {
                // Stopped part-way: the destination is as it was (performCopy
                // cleans up), so this is not an error.
                appendLog(LogEntry(action: .notice("Cancelled during \(relativePath) — left unchanged"),
                                   relativePath: relativePath))
                stopped = true
            } catch {
                progress.errorCount += 1
                appendLog(
                    LogEntry(action: .error(error.localizedDescription), relativePath: relativePath))
                logger.error("Error on \(relativePath): \(error.localizedDescription)")
            }
            if stopped { break }

            progress.processedFiles += 1
            await report()
            await Task.yield()
        }

        // Mirror deletion pass — skips all I/O in dry-run.
        if !orphans.isEmpty && !isCancelled {
            if !isReachableDirectory(source) {
                progress.errorCount += 1
                appendLog(LogEntry(action: .error("Mirror deletions skipped — the source folder became unavailable"),
                                   relativePath: "(mirror)"))
            } else {
                var removed = Set<String>()
                for orphan in orphans {
                    if isCancelled { break }
                    let relativePath = orphan.relativePath
                    progress.currentFile = relativePath

                    // The file may have appeared in the source since the scan.
                    if FileManager.default.fileExists(atPath: source.appendingPathComponent(relativePath).path) {
                        progress.skippedCount += 1
                        appendLog(LogEntry(action: .skipped, relativePath: relativePath))
                    } else {
                        do {
                            if !dryRun {
                                try FileManager.default.removeItem(at: orphan.url)
                            }
                            progress.deletedCount += 1
                            removed.insert(relativePath)
                            let action: FileSyncAction = dryRun ? .wouldDelete : .deleted
                            appendLog(LogEntry(action: action, relativePath: relativePath))
                            logger.debug("\(dryRun ? "Would delete" : "Deleted"): \(relativePath)")
                        } catch {
                            progress.errorCount += 1
                            appendLog(
                                LogEntry(action: .error(error.localizedDescription), relativePath: relativePath))
                            logger.error("Delete failed for \(relativePath): \(error.localizedDescription)")
                        }
                    }
                    progress.processedFiles += 1
                    await report()
                    await Task.yield()
                }

                // Folders those deletions emptied go too, deepest first.
                if !isCancelled {
                    for folder in foldersLeftEmpty(after: removed, source: source, destination: destination) {
                        if dryRun || Self.removeEmptyFolder(destination.appendingPathComponent(folder)) {
                            progress.deletedCount += 1
                            appendLog(LogEntry(action: dryRun ? .wouldDelete : .deleted, relativePath: folder + "/"))
                        } else {
                            appendLog(LogEntry(action: .notice("Kept folder \(folder)/ — it is no longer empty"),
                                               relativePath: folder))
                        }
                    }
                    await report()
                }
            }
        }

        progress.currentFile = isCancelled ? "Cancelled."
                             : dryRun      ? "Preview complete."
                             :               "Complete."
        await report(force: true)
        logger.debug("Sync finished. Copied: \(progress.copiedCount), Skipped: \(progress.skippedCount), Deleted: \(progress.deletedCount), Errors: \(progress.errorCount)")
    }

    // MARK: - Public helpers

    /// Relative paths of destination files with no counterpart in the source.
    /// Throws instead of guessing whenever the source can't be fully read.
    func findOrphans(source: URL, destination: URL) async throws -> [String] {
        try mirrorOrphans(source: source, destination: destination, sourceScan: scan(source))
            .map(\.relativePath)
    }

    /// Walks `root` and returns every regular file in it.
    func scan(_ root: URL) -> ScanResult {
        var result = ScanResult()

        // Enumerating a symlink yields nothing, so resolve the root first.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let enumerationFailures = FailureList()

        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .isHiddenKey, .contentModificationDateKey, .fileSizeKey],
            // Not .skipsHiddenFiles: hidden items are skipped below, but reported.
            options: [],
            errorHandler: { url, error in
                enumerationFailures.items.append((url.path, error.localizedDescription))
                return true   // keep going; the failure is reported, not ignored
            }
        ) else {
            result.failures.append((root.path, "Could not open folder"))
            return result
        }

        let prefixes = Self.rootPrefixes(for: resolvedRoot)
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
                let isDirectory = values.isDirectory == true
                if values.isHidden == true, isDirectory { enumerator.skipDescendants() }
                // Plain folders aren't synced themselves; their files are.
                if isDirectory && values.isHidden != true { continue }

                guard let relativePath = Self.relativePath(of: url, prefixes: prefixes) else {
                    result.failures.append((url.path, "Path is outside the scanned folder"))
                    continue
                }
                if values.isHidden == true {
                    if !Self.isSilentlyIgnored(url.lastPathComponent) {
                        result.ignored.append((relativePath,
                                               isDirectory ? IgnoreReason.hiddenFolder : IgnoreReason.hiddenFile))
                    }
                } else if values.isSymbolicLink == true {
                    result.ignored.append((relativePath, IgnoreReason.symlink))
                } else if values.isRegularFile == true {
                    result.files.append(ScannedFile(url: url, relativePath: relativePath))
                } else {
                    result.ignored.append((relativePath, IgnoreReason.special))
                }
            } catch {
                result.failures.append((url.path, error.localizedDescription))
            }
        }
        result.failures += enumerationFailures.items
        return result
    }

    /// Hidden files not worth a log line: Finder's per-folder `.DS_Store`, and
    /// this app's own temp files left behind by a crash mid-copy.
    static func isSilentlyIgnored(_ name: String) -> Bool {
        name == ".DS_Store" || (name.hasPrefix(".fdc-") && name.hasSuffix(".tmp"))
    }

    // MARK: - Private helpers

    private final class FailureList {
        var items: [(path: String, message: String)] = []
    }

    /// One run's log: a capped list for the screen, plus an uncapped text file.
    private final class RunLog {
        private let maxDisplayed: Int
        private var displayedCount = 0
        private var pending: [LogEntry] = []
        private var handle: FileHandle?
        private var buffer = Data()
        private let logger: Logger

        init(maxDisplayed: Int, file: URL?, logger: Logger) {
            self.maxDisplayed = maxDisplayed
            self.logger = logger
            guard let file else { return }
            if FileManager.default.createFile(atPath: file.path, contents: nil) {
                handle = try? FileHandle(forWritingTo: file)
            }
            if handle == nil { logger.error("Could not create log file at \(file.path)") }
        }

        func append(_ entry: LogEntry) {
            if handle != nil {
                buffer.append(contentsOf: (entry.displayText + "\n").utf8)
                if buffer.count >= 64 * 1024 { flush() }
            }
            if displayedCount < maxDisplayed {
                pending.append(entry)
            } else if displayedCount == maxDisplayed {
                pending.append(LogEntry(
                    action: .notice("Log truncated at \(maxDisplayed) entries — use Save Log to export all"),
                    relativePath: ""
                ))
            } else {
                return
            }
            displayedCount += 1
        }

        func takePending() -> [LogEntry] {
            defer { pending = [] }
            return pending
        }

        func flush() {
            guard let handle, !buffer.isEmpty else { return }
            do {
                try handle.write(contentsOf: buffer)
            } catch {
                logger.error("Could not write log file: \(error.localizedDescription)")
                self.handle = nil
            }
            buffer = Data()
        }

        func close() {
            flush()
            try? handle?.close()
            handle = nil
        }
    }

    private func isReachableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func mirrorOrphans(source: URL, destination: URL, sourceScan: ScanResult) throws -> [ScannedFile] {
        guard isReachableDirectory(source) else { throw MirrorSafetyError.sourceUnavailable }
        guard sourceScan.failures.isEmpty else {
            throw MirrorSafetyError.scanIncomplete(sourceScan.failures.count)
        }
        guard !sourceScan.files.isEmpty else { throw MirrorSafetyError.sourceEmpty }

        let destinationScan = scan(destination)
        guard destinationScan.failures.isEmpty else {
            throw MirrorSafetyError.scanIncomplete(destinationScan.failures.count)
        }

        // A file is an orphan only if the scan didn't see it AND it isn't on disk
        // (covers case-insensitive name matches and hidden/symlinked source entries).
        let sourcePaths = Set(sourceScan.files.map(\.relativePath))
        return destinationScan.files.filter { file in
            !sourcePaths.contains(file.relativePath)
                && !FileManager.default.fileExists(atPath: source.appendingPathComponent(file.relativePath).path)
        }
    }

    /// Destination folders that the Mirror deletions in `removed` leave empty,
    /// deepest first. Only folders above a removed file are considered, so a
    /// folder that was already empty is never touched. A folder that exists in
    /// the source is kept. Finder's `.DS_Store` doesn't count as content; any
    /// other item (hidden files included) keeps the folder.
    func foldersLeftEmpty(after removed: Set<String>, source: URL, destination: URL) -> [String] {
        let fm = FileManager.default
        var candidates = Set<String>()
        for path in removed {
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty {
                candidates.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }

        var empty: [String] = []
        let deepestFirst = candidates.sorted {
            let (a, b) = ($0.split(separator: "/").count, $1.split(separator: "/").count)
            return a != b ? a > b : $0 < $1
        }
        for folder in deepestFirst {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: source.appendingPathComponent(folder).path, isDirectory: &isDirectory),
               isDirectory.boolValue { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: destination.appendingPathComponent(folder).path)
            else { continue }
            let willBeEmpty = entries.allSatisfy { name in
                let child = folder + "/" + name
                return name == ".DS_Store" || removed.contains(child) || empty.contains(child)
            }
            if willBeEmpty { empty.append(folder) }
        }
        return empty
    }

    /// Removes `folder` only if it is empty apart from a `.DS_Store`. `rmdir`
    /// refuses a non-empty folder, so anything added since the check survives.
    static func removeEmptyFolder(_ folder: URL) -> Bool {
        let dsStore = folder.appendingPathComponent(".DS_Store")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
           entries == [".DS_Store"] {
            try? FileManager.default.removeItem(at: dsStore)
        }
        return rmdir(folder.path) == 0
    }

    /// The enumerator may report children under a different spelling of the root
    /// (`/tmp/x` → `/private/tmp/x`), so accept both forms of the prefix.
    static func rootPrefixes(for root: URL) -> [String] {
        let base = root.standardizedFileURL.path
        let alternate = base.hasPrefix("/private/") ? String(base.dropFirst("/private".count))
                                                    : "/private" + base
        return [base, alternate].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// `nil` when `url` isn't under any of `prefixes` — callers must treat that as
    /// an error rather than guess at a relative path.
    static func relativePath(of url: URL, prefixes: [String]) -> String? {
        let path = url.standardizedFileURL.path
        for prefix in prefixes where path.hasPrefix(prefix) {
            let relativePath = String(path.dropFirst(prefix.count))
            return relativePath.isEmpty ? nil : relativePath
        }
        return nil
    }

    /// Returns why `source` should be copied, or `nil` if the destination is already in sync.
    private func copyReason(source: URL, destination: URL, mode: ComparisonMode) throws -> CopyReason? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return .newFile
        }

        // Replacing would recursively delete the folder and everything in it.
        if isDirectory.boolValue { throw SyncFileError.destinationIsFolder }

        // A destination edited more recently than the source is never overwritten,
        // in any mode — not even when its size or content differs. It is skipped
        // here and reported as [NEWER DST] by detectAnomaly.
        if try destinationIsNewer(source: source, destination: destination) { return nil }

        switch mode {

        case .fast, .mirror:
            // Size then mod-date. No xattr — xattr comparison is Thorough-only.
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return .sizeChanged }
            guard let srcDate = srcValues.contentModificationDate,
                  let dstDate = dstValues.contentModificationDate else { return .dateNewer }
            let srcSec = srcDate.timeIntervalSinceReferenceDate.rounded(.down)
            let dstSec = dstDate.timeIntervalSinceReferenceDate.rounded(.down)
            return srcSec > dstSec ? .dateNewer : nil

        case .thorough:
            // Size (fast-reject), xattrs (cheap metadata check), then the bytes.
            let srcValues = try source.resourceValues(forKeys: [.fileSizeKey])
            let dstValues = try destination.resourceValues(forKeys: [.fileSizeKey])
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return .sizeChanged }
            if !xattrsMatch(source: source, destination: destination) { return .xattrChanged }
            return try contentsDiffer(source, destination) ? .contentDiffered : nil

        case .dateOnly:
            // Date only — size differences intentionally ignored.
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            guard let srcDate = srcValues.contentModificationDate,
                  let dstDate = dstValues.contentModificationDate else { return .dateNewer }
            let srcSec = srcDate.timeIntervalSinceReferenceDate.rounded(.down)
            let dstSec = dstDate.timeIntervalSinceReferenceDate.rounded(.down)
            return srcSec > dstSec ? .dateNewer : nil
        }
    }

    private func detectAnomaly(source: URL, destination: URL, mode: ComparisonMode) throws -> FileSyncAction? {
        switch mode {

        case .fast, .mirror, .thorough:
            return try destinationIsNewer(source: source, destination: destination) ? .newerDestination : nil

        case .dateOnly:
            if try destinationIsNewer(source: source, destination: destination) { return .newerDestination }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            guard srcValues.contentModificationDate != nil,
                  dstValues.contentModificationDate != nil else { return nil }
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return .sizeMismatch }
            return nil
        }
    }

    /// True when the destination's mod-date is strictly later, compared at
    /// 1-second granularity (see the 1-second note in CLAUDE.md).
    private func destinationIsNewer(source: URL, destination: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let srcDate = try source.resourceValues(forKeys: keys).contentModificationDate,
              let dstDate = try destination.resourceValues(forKeys: keys).contentModificationDate
        else { return false }
        return dstDate.timeIntervalSinceReferenceDate.rounded(.down)
             > srcDate.timeIntervalSinceReferenceDate.rounded(.down)
    }

    static let compareChunkSize = 1_048_576

    /// Compares the two files a chunk at a time and stops at the first chunk that
    /// differs. Hashing both files would always read every byte of both, and the
    /// digests aren't kept between runs, so a hash buys nothing here.
    func contentsDiffer(_ a: URL, _ b: URL) throws -> Bool {
        let handleA = try FileHandle(forReadingFrom: a)
        defer { try? handleA.close() }
        let handleB = try FileHandle(forReadingFrom: b)
        defer { try? handleB.close() }

        while true {
            // Each chunk is an autoreleased NSData; without the pool a multi-GB
            // comparison keeps every chunk alive until the whole file is done.
            let (chunkA, chunkB) = try autoreleasepool {
                (try readFully(handleA), try readFully(handleB))
            }
            if chunkA != chunkB { return true }
            if chunkA.isEmpty { return false }   // both at end of file
            if isCancelled { throw SyncFileError.cancelled }
        }
    }

    /// One full chunk, or less only at end of file. A network filesystem may
    /// return short reads, which must not be mistaken for a difference.
    private func readFully(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < Self.compareChunkSize {
            let piece = try readChunk(handle, Self.compareChunkSize - data.count)
            if piece.isEmpty { break }
            data.append(piece)
        }
        return data
    }

    private func xattrsMatch(source: URL, destination: URL) -> Bool {
        extendedAttributes(of: source) == extendedAttributes(of: destination)
    }

    private func extendedAttributes(of url: URL) -> [String: Data] {
        let path = url.path
        var result: [String: Data] = [:]

        let bufSize = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard bufSize > 0 else { return result }

        var nameBuf = [CChar](repeating: 0, count: bufSize)
        let actualSize = listxattr(path, &nameBuf, bufSize, XATTR_NOFOLLOW)
        guard actualSize > 0 else { return result }

        var offset = 0
        while offset < actualSize {
            let name = nameBuf.withUnsafeBufferPointer { ptr in
                String(cString: ptr.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            guard !Self.isIgnoredXattr(name) else { continue }

            let dataSize = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard dataSize > 0 else { continue }

            var dataBuf = [UInt8](repeating: 0, count: dataSize)
            guard getxattr(path, name, &dataBuf, dataSize, 0, XATTR_NOFOLLOW) == dataSize else { continue }
            result[name] = Data(dataBuf)
        }

        return result
    }

    /// xattrs macOS writes on its own, for bookkeeping rather than as part of the
    /// file. They are still copied; they just never make Thorough re-copy a file.
    private static let ignoredXattrNames: Set<String> = [
        "com.apple.quarantine",       // Gatekeeper; the sandbox also stamps it on every file the app writes
        "com.apple.lastuseddate#PS",  // Launch Services, updated whenever the file is opened
        "com.apple.macl",             // sandbox access grants, added when the file is opened in a sandboxed app
        "com.apple.provenance",       // Gatekeeper's record of the app that created the file
    ]
    private static let ignoredXattrPrefixes = [
        "com.apple.metadata:kMDLabel_",  // private Spotlight labels written by system services
    ]

    static func isIgnoredXattr(_ name: String) -> Bool {
        ignoredXattrNames.contains(name) || ignoredXattrPrefixes.contains { name.hasPrefix($0) }
    }

    /// Copies one file with `copyfile(3)` — what `FileManager.copyItem` uses —
    /// with the same result: data, xattrs, ACLs and permissions, as an APFS clone
    /// where possible, and failing if `destination` exists. Unlike `copyItem`, it
    /// checks `isCancelled` after every chunk and stops part-way, throwing
    /// `SyncFileError.cancelled` and leaving a partial file for the caller to remove.
    /// `clone: false` forces a chunked copy (tests use it; a clone is instant).
    static func copyFile(from source: URL, to destination: URL, clone: Bool = true,
                         isCancelled: @escaping () -> Bool) throws {
        if isCancelled() { throw SyncFileError.cancelled }

        final class Context { let isCancelled: () -> Bool; init(_ c: @escaping () -> Bool) { isCancelled = c } }
        let context = Context(isCancelled)
        let callback: copyfile_callback_t = { _, _, _, _, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            return Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue().isCancelled()
                ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }

        guard let state = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        var flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
                                     | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
        if clone { flags |= copyfile_flags_t(COPYFILE_CLONE) }

        let result = withExtendedLifetime(context) {
            copyfile(source.path, destination.path, state, flags)
        }
        guard result != 0 else { return }
        let code = errno
        if code == ECANCELED || isCancelled() { throw SyncFileError.cancelled }
        if code == EEXIST { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path]) }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                      userInfo: [NSFilePathErrorKey: destination.path])
    }

    private func performCopy(source: URL, destination: URL) throws {
        let fm = FileManager.default

        let srcValues = try source.resourceValues(forKeys: [.contentModificationDateKey])
        let srcDate   = srcValues.contentModificationDate

        let destDir = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // New file: nothing to protect, so copy straight to the final path. The
        // temp-and-swap below costs an extra round trip per file (~50% slower
        // over SMB). A partial file from a failed copy is removed, since in
        // Date Only mode its newer date would otherwise block every later copy.
        if !fm.fileExists(atPath: destination.path) {
            do {
                try copyItem(source, destination)
                if let date = srcDate {
                    try fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
                }
            } catch {
                // "File exists" means another writer created it after our check:
                // it isn't ours, so leave it alone.
                if (error as? CocoaError)?.code != .fileWriteFileExists {
                    try? fm.removeItem(at: destination)
                }
                throw error
            }
            return
        }

        // Existing file: copy to a temp file beside it, then swap it into place,
        // so a failed copy never destroys the current destination file. The
        // leading dot keeps a leftover temp file (e.g. after a crash) out of
        // later scans.
        let tempURL = destDir.appendingPathComponent(".fdc-\(UUID().uuidString).tmp")
        do {
            try copyItem(source, tempURL)
            if let date = srcDate {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: tempURL.path)
            }
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL,
                                         backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }
}
