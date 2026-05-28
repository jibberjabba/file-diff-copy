import CryptoKit
import Foundation
import os

// MARK: - Data types

/// The action taken for a single file during a sync run.
enum FileSyncAction {
    case copied
    case skipped
    case deleted
    case error(String)
}

/// A single entry in the copy log.
struct LogEntry: Identifiable {
    let id = UUID()
    let action: FileSyncAction
    let relativePath: String

    /// Human-readable one-line description for display in the log view.
    var displayText: String {
        switch action {
        case .copied:             return "[COPIED]  \(relativePath)"
        case .skipped:            return "[SKIPPED] \(relativePath)"
        case .deleted:            return "[DELETED] \(relativePath)"
        case .error(let reason):  return "[ERROR]   \(relativePath) — \(reason)"
        }
    }
}

/// A snapshot of sync progress published after each file is processed.
struct SyncProgress {
    var totalFiles:     Int
    var processedFiles: Int
    var copiedCount:    Int
    var skippedCount:   Int
    var deletedCount:   Int
    var errorCount:     Int
    var currentFile:    String
    var logEntries:     [LogEntry]

    /// 0.0 – 1.0 fraction for the progress bar.
    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }
}

// MARK: - Comparison mode

/// Controls how two files are compared to decide whether a copy is needed.
enum ComparisonMode: CaseIterable, Hashable {
    case fast
    case thorough
    case archive
    case mirror

    var label: String {
        switch self {
        case .fast:     return "Fast"
        case .thorough: return "Thorough"
        case .archive:  return "Archive"
        case .mirror:   return "Mirror"
        }
    }

    var tooltip: String {
        switch self {
        case .fast:     return "Size + modification date + extended attributes"
        case .thorough: return "SHA-256 checksum + extended attributes — detects any content or metadata change"
        case .archive:  return "Modification date only — never re-copies same-age files regardless of size"
        case .mirror:   return "Fast copy, then permanently deletes destination files not present in source"
        }
    }
}

// MARK: - Engine

/// Pure Swift sync engine — no SwiftUI dependency, fully testable in isolation.
///
/// Call `sync(source:destination:onProgress:)` to start a copy-if-newer run.
/// Call `cancel()` at any time to request a graceful stop.
final class FileSyncEngine {

    private let logger = Logger(subsystem: "com.macos.filecopytool", category: "FileSyncEngine")

    /// Set to true by `cancel()`. The engine checks this between each file.
    private(set) var isCancelled = false

    /// Signals that the current sync run should stop after the current file finishes.
    func cancel() {
        isCancelled = true
    }

    // MARK: - Public API

    /// Recursively copies files from `source` to `destination` using the given
    /// comparison mode to decide whether each file needs copying.
    ///
    /// - Parameters:
    ///   - source: Root folder to copy from.
    ///   - destination: Root folder to copy into.
    ///   - mode: How files are compared (fast / thorough / archive).
    ///   - onProgress: Called after every file is processed. Called from the
    ///     cooperative thread pool — callers must hop to MainActor for UI updates.
    func sync(
        source: URL,
        destination: URL,
        mode: ComparisonMode,
        onProgress: @escaping (SyncProgress) -> Void
    ) async {
        isCancelled = false

        // First pass: count all files so the progress bar has a denominator.
        let allFiles = enumerateFiles(in: source)
        logger.debug("Sync started. Found \(allFiles.count) source files.")

        var progress = SyncProgress(
            totalFiles:     allFiles.count,
            processedFiles: 0,
            copiedCount:    0,
            skippedCount:   0,
            deletedCount:   0,
            errorCount:     0,
            currentFile:    "",
            logEntries:     []
        )

        for fileURL in allFiles {
            if isCancelled { break }

            // Strip the source root to get a path like "Reports/2025/Q4.xlsx".
            let relativePath = String(
                fileURL.path.dropFirst(source.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            let destURL = destination.appendingPathComponent(relativePath)
            progress.currentFile = relativePath

            do {
                if try needsCopy(source: fileURL, destination: destURL, mode: mode) {
                    try performCopy(source: fileURL, destination: destURL)
                    progress.copiedCount += 1
                    progress.logEntries.append(LogEntry(action: .copied, relativePath: relativePath))
                    logger.debug("Copied: \(relativePath)")
                } else {
                    progress.skippedCount += 1
                    progress.logEntries.append(LogEntry(action: .skipped, relativePath: relativePath))
                }
            } catch {
                progress.errorCount += 1
                progress.logEntries.append(
                    LogEntry(action: .error(error.localizedDescription), relativePath: relativePath)
                )
                logger.error("Error on \(relativePath): \(error.localizedDescription)")
            }

            progress.processedFiles += 1
            onProgress(progress)

            // Yield to keep the cooperative thread pool responsive.
            await Task.yield()
        }

        // Mirror deletion pass — remove destination files absent from source.
        if mode == .mirror && !isCancelled {
            let orphans = await findOrphans(source: source, destination: destination)
            for orphanURL in orphans {
                if isCancelled { break }
                let relativePath = String(
                    orphanURL.path.dropFirst(destination.path.count)
                ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                progress.currentFile = relativePath
                do {
                    try FileManager.default.removeItem(at: orphanURL)
                    progress.deletedCount += 1
                    progress.logEntries.append(LogEntry(action: .deleted, relativePath: relativePath))
                    logger.debug("Deleted: \(relativePath)")
                } catch {
                    progress.errorCount += 1
                    progress.logEntries.append(
                        LogEntry(action: .error(error.localizedDescription), relativePath: relativePath)
                    )
                    logger.error("Delete failed for \(relativePath): \(error.localizedDescription)")
                }
                onProgress(progress)
                await Task.yield()
            }
        }

        progress.currentFile = isCancelled ? "Cancelled." : "Complete."
        onProgress(progress)
        logger.debug("Sync finished. Copied: \(progress.copiedCount), Skipped: \(progress.skippedCount), Deleted: \(progress.deletedCount), Errors: \(progress.errorCount)")
    }

    // MARK: - Public helpers

    /// Returns all files in `destination` that have no matching path in `source`.
    /// Used by the ViewModel for the Mirror pre-scan confirmation step.
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

    /// Returns every regular file (non-directory, non-hidden) under `directory`.
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

    /// Returns `true` when the source file should be copied to the destination,
    /// applying the logic for the given `ComparisonMode`.
    private func needsCopy(source: URL, destination: URL, mode: ComparisonMode) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return true
        }

        switch mode {

        case .fast, .mirror:  // Mirror uses Fast comparison for the copy pass.
            // 1. Size. 2. Mod-date (1-sec granularity). 3. Extended attributes.
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return true }
            guard let srcDate = srcValues.contentModificationDate,
                  let dstDate = dstValues.contentModificationDate else { return true }
            let srcSec = srcDate.timeIntervalSinceReferenceDate.rounded(.down)
            let dstSec = dstDate.timeIntervalSinceReferenceDate.rounded(.down)
            if srcSec > dstSec { return true }
            return !xattrsMatch(source: source, destination: destination)

        case .thorough:
            // 1. Size (fast-reject). 2. Xattrs (cheap, avoids SHA-256 if only
            //    metadata changed). 3. Full SHA-256 of file content.
            let srcValues = try source.resourceValues(forKeys: [.fileSizeKey])
            let dstValues = try destination.resourceValues(forKeys: [.fileSizeKey])
            if let srcSize = srcValues.fileSize, let dstSize = dstValues.fileSize,
               srcSize != dstSize { return true }
            if !xattrsMatch(source: source, destination: destination) { return true }
            return try sha256(of: source) != sha256(of: destination)

        case .archive:
            // Date only — size differences are intentionally ignored.
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let srcValues = try source.resourceValues(forKeys: keys)
            let dstValues = try destination.resourceValues(forKeys: keys)
            guard let srcDate = srcValues.contentModificationDate,
                  let dstDate = dstValues.contentModificationDate else { return true }
            let srcSec = srcDate.timeIntervalSinceReferenceDate.rounded(.down)
            let dstSec = dstDate.timeIntervalSinceReferenceDate.rounded(.down)
            return srcSec > dstSec
        }
    }

    /// Streams `url` through SHA-256 in 1 MB chunks to avoid loading the whole
    /// file into memory at once.
    private func sha256(of url: URL) throws -> SHA256Digest {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    /// Returns `true` when both files carry identical extended attributes
    /// (after filtering out system-managed entries that change autonomously).
    private func xattrsMatch(source: URL, destination: URL) -> Bool {
        extendedAttributes(of: source) == extendedAttributes(of: destination)
    }

    /// Reads all extended attributes of `url` into a `[name: data]` dictionary,
    /// skipping entries in `ignoredXattrNames`.
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

    /// Xattrs that macOS updates automatically — comparing these would cause
    /// spurious copies unrelated to user-visible file changes.
    private static let ignoredXattrNames: Set<String> = [
        "com.apple.quarantine",       // set by Gatekeeper on downloaded files
        "com.apple.lastuseddate#PS",  // updated by Launch Services on every open
    ]

    /// Copies `source` to `destination`, creating intermediate directories as needed.
    /// The source modification date is preserved on the destination file after the copy.
    private func performCopy(source: URL, destination: URL) throws {
        let fm = FileManager.default

        // Read the source modification date before the copy (in case the copy moves the file).
        let srcValues = try source.resourceValues(forKeys: [.contentModificationDateKey])
        let srcDate   = srcValues.contentModificationDate

        // Ensure the parent directory exists.
        let destDir = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove the existing destination file before copying.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)

        // Restore the original modification date so future runs compare correctly.
        if let date = srcDate {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
        }
    }
}
