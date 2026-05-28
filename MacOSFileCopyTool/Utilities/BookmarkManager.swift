import Foundation

/// Persists security-scoped URL bookmarks in UserDefaults so the app retains
/// folder access across launches even inside the macOS sandbox.
enum BookmarkManager {

    // MARK: - Keys

    /// UserDefaults key for the source folder bookmark.
    static let sourceKey      = "sourceBookmarkData"
    /// UserDefaults key for the destination folder bookmark.
    static let destinationKey = "destinationBookmarkData"

    // MARK: - Save

    /// Creates a security-scoped bookmark for `url` and saves it to UserDefaults
    /// under `key`. Call this immediately after the user selects a folder.
    static func save(url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("BookmarkManager: Failed to save bookmark for \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Restore

    /// Resolves a previously saved security-scoped bookmark from UserDefaults.
    ///
    /// Returns `nil` if no bookmark is stored or the bookmark cannot be resolved
    /// (e.g. the folder was deleted or the volume is not mounted).
    /// If the bookmark data has gone stale it is refreshed automatically.
    static func restore(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Re-save refreshed bookmark data so next launch uses the updated version.
                save(url: url, key: key)
            }
            return url
        } catch {
            print("BookmarkManager: Failed to restore bookmark for key '\(key)': \(error.localizedDescription)")
            return nil
        }
    }
}
