import Foundation
import os

enum BookmarkManager {

    private static let logger = Logger(subsystem: "com.jeff.filecopy", category: "BookmarkManager")

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
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.error("Failed to save bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func restore(key: String) -> RestoreResult {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .notStored }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                save(url: url, key: key)
            }
            return .success(url)
        } catch {
            logger.error("Failed to restore bookmark '\(key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }
}
