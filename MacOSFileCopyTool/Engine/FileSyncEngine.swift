import CryptoKit
import Foundation
import os

// MARK: - Copy reason

/// Why a file needs to be copied to the destination.
enum CopyReason: CustomStringConvertible {
    case newFile
    case sizeChanged
    case dateNewer
    case xattrChanged
    case checksumDiffered

    var description: String {
        switch self {
        case .newFile:          return "new file"
        case .sizeChanged:      return "size changed"
        case .dateNewer:        return "source is newer"
        case .xattrChanged:     return "metadata changed"
        case .checksumDiffered: return "content changed"
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
        case .error(let r):     return "[ERROR]      \(relativePath) — \(r)"
        }
    }
}

/// A snapshot of sync progress published after each file is processed.
struct SyncProgress {
    var totalFiles:     Int
    var processedFiles: Int
    var copiedCount:    Int
    var skippedCount:   Int
    var warningCount:   Int
    var deletedCount:   Int
    var errorCount:     Int
    var currentFile:    String
    var logEntries:     [LogEntry]
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
    case archive
    case mirror

    var label: String {
        switch self {
        case .fast:     return "Fast"
        case .thorough: return "Thorough"
        case .archive:  return "Date Only"
        case .mirror:   return "Mirror"
        }
    }

    var tooltip: String {
        switch self {
        case .fast:
            return "Size + modification date"
        case .thorough:
            return "SHA-256 checksum + extended attributes — detects any content or metadata change"
        case .archive:
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
    var copyItem: (URL, URL) throws -> Void = { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - Public API

    /// - Parameter confirmedOrphans: relative paths the user approved for deletion
    ///   in the Mirror confirmation sheet. A real (non-dry-run) Mirror deletes only
    ///   files that are in this set *and* still orphaned now; `nil` deletes nothing.
    func sync(
        source: URL,
        destination: URL,
        mode: ComparisonMode,
        dryRun: Bool = false,
        confirmedOrphans: Set<String>? = nil,
        onProgress: @escaping (SyncProgress) -> Void
    ) async {
        var progress = SyncProgress(
            totalFiles:     0,
            processedFiles: 0,
            copiedCount:    0,
            skippedCount:   0,
            warningCount:   0,
            deletedCount:   0,
            errorCount:     0,
            currentFile:    "",
            logEntries:     []
        )
        progress.isDryRun = dryRun

        // An unmounted volume must stop the run outright — never copy into, or
        // judge orphans against, a folder that isn't there.
        for (label, root) in [("Source", source), ("Destination", destination)]
        where !isReachableDirectory(root) {
            progress.errorCount += 1
            appendLog(LogEntry(action: .error("\(label) folder is unavailable"), relativePath: root.path),
                      to: &progress)
            progress.currentFile = "\(label) folder is unavailable."
            onProgress(progress)
            logger.error("\(label) folder unavailable: \(root.path)")
            return
        }

        let sourceScan = scan(source)
        for failure in sourceScan.failures {
            progress.errorCount += 1
            appendLog(LogEntry(action: .error(failure.message), relativePath: failure.path), to: &progress)
            logger.error("Could not read \(failure.path): \(failure.message)")
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
                                   relativePath: "(mirror)"),
                          to: &progress)
                logger.error("Mirror deletions skipped: \(error.localizedDescription)")
            }
        }

        progress.totalFiles = sourceScan.files.count + orphans.count
        logger.debug("Sync started. \(sourceScan.files.count) source files\(dryRun ? " (dry run)" : "").")

        for file in sourceScan.files {
            if isCancelled { break }

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
                    appendLog(LogEntry(action: action, relativePath: relativePath), to: &progress)
                    logger.debug("\(dryRun ? "Would copy" : "Copied"): \(relativePath) (\(reason))")
                } else if let anomaly = try detectAnomaly(source: file.url,
                                                           destination: destURL,
                                                           mode: mode) {
                    progress.warningCount += 1
                    appendLog(LogEntry(action: anomaly, relativePath: relativePath), to: &progress)
                    logger.debug("Warning \(anomaly) on \(relativePath)")
                } else {
                    progress.skippedCount += 1
                    appendLog(LogEntry(action: .skipped, relativePath: relativePath), to: &progress)
                }
            } catch {
                progress.errorCount += 1
                appendLog(
                    LogEntry(action: .error(error.localizedDescription), relativePath: relativePath),
                    to: &progress
                )
                logger.error("Error on \(relativePath): \(error.localizedDescription)")
            }

            progress.processedFiles += 1
            onProgress(progress)
            await Task.yield()
        }

        // Mirror deletion pass — skips all I/O in dry-run.
        if !orphans.isEmpty && !isCancelled {
            if !isReachableDirectory(source) {
                progress.errorCount += 1
                appendLog(LogEntry(action: .error("Mirror deletions skipped — the source folder became unavailable"),
                                   relativePath: "(mirror)"),
                          to: &progress)
            } else {
                for orphan in orphans {
                    if isCancelled { break }
                    let relativePath = orphan.relativePath
                    progress.currentFile = relativePath

                    // The file may have appeared in the source since the scan.
                    if FileManager.default.fileExists(atPath: source.appendingPathComponent(relativePath).path) {
                        progress.skippedCount += 1
                        appendLog(LogEntry(action: .skipped, relativePath: relativePath), to: &progress)
                    } else {
                        do {
                            if !dryRun {
                                try FileManager.default.removeItem(at: orphan.url)
                            }
                            progress.deletedCount += 1
                            let action: FileSyncAction = dryRun ? .wouldDelete : .deleted
                            appendLog(LogEntry(action: action, relativePath: relativePath), to: &progress)
                            logger.debug("\(dryRun ? "Would delete" : "Deleted"): \(relativePath)")
                        } catch {
                            progress.errorCount += 1
                            appendLog(
                                LogEntry(action: .error(error.localizedDescription), relativePath: relativePath),
                                to: &progress
                            )
                            logger.error("Delete failed for \(relativePath): \(error.localizedDescription)")
                        }
                    }
                    progress.processedFiles += 1
                    onProgress(progress)
                    await Task.yield()
                }
            }
        }

        progress.currentFile = isCancelled ? "Cancelled."
                             : dryRun      ? "Preview complete."
                             :               "Complete."
        onProgress(progress)
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
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
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
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                guard let relativePath = Self.relativePath(of: url, prefixes: prefixes) else {
                    result.failures.append((url.path, "Path is outside the scanned folder"))
                    continue
                }
                result.files.append(ScannedFile(url: url, relativePath: relativePath))
            } catch {
                result.failures.append((url.path, error.localizedDescription))
            }
        }
        result.failures += enumerationFailures.items
        return result
    }

    // MARK: - Private helpers

    private final class FailureList {
        var items: [(path: String, message: String)] = []
    }

    private static let maxLogEntries = 20_000

    private func appendLog(_ entry: LogEntry, to progress: inout SyncProgress) {
        if progress.logEntries.count < Self.maxLogEntries {
            progress.logEntries.append(entry)
        } else if progress.logEntries.count == Self.maxLogEntries {
            progress.logEntries.append(LogEntry(
                action: .notice("Log truncated at \(Self.maxLogEntries) entries — use Save Log to export all"),
                relativePath: ""
            ))
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
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .newFile
        }

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
            // Size (fast-reject), xattrs (cheap metadata check), then full SHA-256.
            let srcValues = try source.resourceValues(forKeys: [.fileSizeKey])
            let dstValues = try destination.resourceValues(forKeys: [.fileSizeKey])
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return .sizeChanged }
            if !xattrsMatch(source: source, destination: destination) { return .xattrChanged }
            return try sha256(of: source) != sha256(of: destination) ? .checksumDiffered : nil

        case .archive:
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
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            guard let srcDate = srcValues.contentModificationDate,
                  let dstDate = dstValues.contentModificationDate else { return nil }
            let srcSec = srcDate.timeIntervalSinceReferenceDate.rounded(.down)
            let dstSec = dstDate.timeIntervalSinceReferenceDate.rounded(.down)
            return dstSec > srcSec ? .newerDestination : nil

        case .archive:
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            guard let srcDate = srcValues.contentModificationDate,
                  let dstDate = dstValues.contentModificationDate else { return nil }
            let srcSec = srcDate.timeIntervalSinceReferenceDate.rounded(.down)
            let dstSec = dstDate.timeIntervalSinceReferenceDate.rounded(.down)
            if dstSec > srcSec { return .newerDestination }
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return .sizeMismatch }
            return nil
        }
    }

    private func sha256(of url: URL) throws -> SHA256Digest {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
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
            guard !Self.ignoredXattrNames.contains(name) else { continue }

            let dataSize = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard dataSize > 0 else { continue }

            var dataBuf = [UInt8](repeating: 0, count: dataSize)
            guard getxattr(path, name, &dataBuf, dataSize, 0, XATTR_NOFOLLOW) == dataSize else { continue }
            result[name] = Data(dataBuf)
        }

        return result
    }

    private static let ignoredXattrNames: Set<String> = [
        "com.apple.quarantine",
        "com.apple.lastuseddate#PS",
    ]


    private func performCopy(source: URL, destination: URL) throws {
        let fm = FileManager.default

        let srcValues = try source.resourceValues(forKeys: [.contentModificationDateKey])
        let srcDate   = srcValues.contentModificationDate

        let destDir = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Copy to a temp file beside the destination, then swap it into place, so
        // a failed copy never destroys the existing destination file. The leading
        // dot keeps a leftover temp file (e.g. after a crash) out of later scans.
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
