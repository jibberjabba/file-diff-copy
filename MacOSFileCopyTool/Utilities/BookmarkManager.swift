import Foundation
import os

enum BookmarkManager {

    private static let logger = Logger(subsystem: "com.jeff.filecopy", category: "BookmarkManager")

    /// Where bookmarks are stored. Tests point this at a throwaway suite.
    static var defaults: UserDefaults = .standard

    static let sourceKey      = "sourceBookmarkData"
    static let destinationKey = "destinationBookmarkData"

    enum RestoreResult {
        case success(URL)
        case notStored      // no bookmark saved — user has never selected this folder
        case unavailable    // bookmark exists but can't be resolved (volume not mounted, etc.)
    }

    static func save(url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to save bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Exchanges the bookmarks stored under two keys. The raw data is moved, not
    /// re-created from URLs, so a bookmark whose volume isn't mounted keeps working.
    static func swap(_ keyA: String, _ keyB: String) {
        let dataA = defaults.data(forKey: keyA)
        let dataB = defaults.data(forKey: keyB)
        defaults.set(dataB, forKey: keyA)   // nil removes the key
        defaults.set(dataA, forKey: keyB)
    }

    static func restore(key: String) -> RestoreResult {
        guard let data = defaults.data(forKey: key) else { return .notStored }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // A security-scoped URL must be opened before a fresh bookmark
                // can be made from it.
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                save(url: url, key: key)
            }
            return .success(url)
        } catch {
            logger.error("Failed to restore bookmark '\(key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }
}
