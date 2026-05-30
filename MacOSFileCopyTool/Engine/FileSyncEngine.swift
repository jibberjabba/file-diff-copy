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

// MARK: - Engine

/// Pure Swift sync engine — no SwiftUI dependency, fully testable in isolation.
///
/// Pass `dryRun: true` to preview what would happen without modifying any files.
/// Log entries use `.wouldCopy` / `.wouldDelete` in dry-run mode.
/// Call `cancel()` at any time to request a graceful stop.
final class FileSyncEngine {

    private let logger = Logger(subsystem: "com.macos.filecopytool", category: "FileSyncEngine")

    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    // MARK: - Public API

    func sync(
        source: URL,
        destination: URL,
        mode: ComparisonMode,
        dryRun: Bool = false,
        onProgress: @escaping (SyncProgress) -> Void
    ) async {
        isCancelled = false

        let allFiles = enumerateFiles(in: source)

        // Pre-scan orphans for Mirror so their count is in the progress denominator.
        let preScannedOrphans: [URL]
        if mode == .mirror {
            preScannedOrphans = await findOrphans(source: source, destination: destination)
        } else {
            preScannedOrphans = []
        }

        logger.debug("Sync started. \(allFiles.count) source files\(dryRun ? " (dry run)" : "").")

        var progress = SyncProgress(
            totalFiles:     allFiles.count + preScannedOrphans.count,
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

        for fileURL in allFiles {
            if isCancelled { break }

            let relativePath = String(
                fileURL.path.dropFirst(source.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            let destURL = destination.appendingPathComponent(relativePath)
            progress.currentFile = relativePath

            do {
                if let reason = try copyReason(source: fileURL, destination: destURL, mode: mode) {
                    if !dryRun {
                        try performCopy(source: fileURL, destination: destURL)
                    }
                    progress.copiedCount += 1
                    let action: FileSyncAction = dryRun ? .wouldCopy(reason) : .copied(reason)
                    appendLog(LogEntry(action: action, relativePath: relativePath), to: &progress)
                    logger.debug("\(dryRun ? "Would copy" : "Copied"): \(relativePath) (\(reason))")
                } else if let anomaly = try detectAnomaly(source: fileURL,
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

        // Mirror deletion pass — uses pre-scanned list; skips all I/O in dry-run.
        if mode == .mirror && !isCancelled {
            for orphanURL in preScannedOrphans {
                if isCancelled { break }
                let relativePath = String(
                    orphanURL.path.dropFirst(destination.path.count)
                ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                progress.currentFile = relativePath
                do {
                    if !dryRun {
                        try FileManager.default.removeItem(at: orphanURL)
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
                progress.processedFiles += 1
                onProgress(progress)
                await Task.yield()
            }
        }

        progress.currentFile = isCancelled ? "Cancelled."
                             : dryRun      ? "Preview complete."
                             :               "Complete."
        onProgress(progress)
        logger.debug("Sync finished. Copied: \(progress.copiedCount), Skipped: \(progress.skippedCount), Deleted: \(progress.deletedCount), Errors: \(progress.errorCount)")
    }

    // MARK: - Public helpers

    func findOrphans(source: URL, destination: URL) async -> [URL] {
        enumerateFiles(in: destination).filter { destURL in
            let relativePath = String(
                destURL.path.dropFirst(destination.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !FileManager.default.fileExists(
                atPath: source.appendingPathComponent(relativePath).path
            )
        }
    }

    // MARK: - Private helpers

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

    private func enumerateFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    files.append(url)
                }
            } catch {
                logger.error("Could not read resource values for \(url.path): \(error.localizedDescription)")
            }
        }
        return files
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

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)

        if let date = srcDate {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
        }
    }
}
