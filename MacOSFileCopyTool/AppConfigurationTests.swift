import XCTest

/// Locks in build configuration that a unit test can't otherwise see.
final class AppConfigurationTests: XCTestCase {

    private func entitlements() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("MacOSFileCopyTool.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    /// The App Sandbox quarantines every file the app copies (measured
    /// 2026-10-06: `com.apple.quarantine: 0082;…;File Diff Copy;` on a copied
    /// script whose source had no quarantine), and a sandboxed app can't remove
    /// the flag, so copied apps and scripts came out flagged as downloaded.
    func testAppIsNotSandboxed() throws {
        XCTAssertNotEqual(try entitlements()["com.apple.security.app-sandbox"] as? Bool, true,
                          "the sandbox would quarantine every copied file — see CLAUDE.md")
    }
}
