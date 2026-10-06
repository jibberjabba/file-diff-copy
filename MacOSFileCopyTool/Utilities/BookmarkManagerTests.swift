import XCTest

/// Regression tests for M5: bookmarks round-trip, and a stale bookmark (folder
/// renamed or moved) is refreshed so it keeps resolving.
final class BookmarkManagerTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BookmarkManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "BookmarkManagerTests-\(UUID().uuidString)"
        BookmarkManager.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        BookmarkManager.defaults.removePersistentDomain(forName: suiteName)
        BookmarkManager.defaults = .standard
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resolvedPath(_ result: BookmarkManager.RestoreResult) -> String? {
        if case .success(let url) = result { return url.resolvingSymlinksInPath().path }
        return nil
    }

    func testRoundTrip() throws {
        let url = try folder("Photos")
        BookmarkManager.save(url: url, key: BookmarkManager.sourceKey)

        XCTAssertEqual(resolvedPath(BookmarkManager.restore(key: BookmarkManager.sourceKey)),
                       url.resolvingSymlinksInPath().path)
    }

    func testNothingStored() {
        guard case .notStored = BookmarkManager.restore(key: BookmarkManager.destinationKey) else {
            return XCTFail("expected .notStored")
        }
    }

    func testUnresolvableBookmarkIsUnavailable() {
        BookmarkManager.defaults.set(Data("not a bookmark".utf8), forKey: BookmarkManager.sourceKey)
        guard case .unavailable = BookmarkManager.restore(key: BookmarkManager.sourceKey) else {
            return XCTFail("expected .unavailable")
        }
    }

    func testStaleBookmarkIsRefreshed() throws {
        let original = try folder("Before")
        BookmarkManager.save(url: original, key: BookmarkManager.sourceKey)
        let renamed = root.appendingPathComponent("After")
        try FileManager.default.moveItem(at: original, to: renamed)
        let staleData = BookmarkManager.defaults.data(forKey: BookmarkManager.sourceKey)

        // The first restore follows the rename and re-saves the bookmark.
        XCTAssertEqual(resolvedPath(BookmarkManager.restore(key: BookmarkManager.sourceKey)),
                       renamed.resolvingSymlinksInPath().path)

        let refreshed = try XCTUnwrap(BookmarkManager.defaults.data(forKey: BookmarkManager.sourceKey))
        XCTAssertNotEqual(refreshed, staleData, "the stale bookmark must be replaced")
        var isStale = true
        _ = try URL(resolvingBookmarkData: refreshed, options: .withSecurityScope,
                    relativeTo: nil, bookmarkDataIsStale: &isStale)
        XCTAssertFalse(isStale)
    }
}

extension BookmarkManagerTests {

    func testSwapExchangesStoredBookmarks() throws {
        let a = try folder("A")
        let b = try folder("B")
        BookmarkManager.save(url: a, key: BookmarkManager.sourceKey)
        BookmarkManager.save(url: b, key: BookmarkManager.destinationKey)

        BookmarkManager.swap(BookmarkManager.sourceKey, BookmarkManager.destinationKey)

        XCTAssertEqual(resolvedPath(BookmarkManager.restore(key: BookmarkManager.sourceKey)),
                       b.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolvedPath(BookmarkManager.restore(key: BookmarkManager.destinationKey)),
                       a.resolvingSymlinksInPath().path)
    }

    func testSwapWithOneSideEmptyMovesTheBookmark() throws {
        let a = try folder("A")
        BookmarkManager.save(url: a, key: BookmarkManager.sourceKey)

        BookmarkManager.swap(BookmarkManager.sourceKey, BookmarkManager.destinationKey)

        guard case .notStored = BookmarkManager.restore(key: BookmarkManager.sourceKey) else {
            return XCTFail("expected .notStored")
        }
        XCTAssertEqual(resolvedPath(BookmarkManager.restore(key: BookmarkManager.destinationKey)),
                       a.resolvingSymlinksInPath().path)
    }

    func testSwapKeepsAnUnresolvableBookmark() {
        let junk = Data("not a bookmark".utf8)
        BookmarkManager.defaults.set(junk, forKey: BookmarkManager.sourceKey)

        BookmarkManager.swap(BookmarkManager.sourceKey, BookmarkManager.destinationKey)

        XCTAssertEqual(BookmarkManager.defaults.data(forKey: BookmarkManager.destinationKey), junk)
        XCTAssertNil(BookmarkManager.defaults.data(forKey: BookmarkManager.sourceKey))
    }
}
