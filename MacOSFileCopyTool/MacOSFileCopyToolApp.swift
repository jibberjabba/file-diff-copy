import SwiftUI
import AppKit

// MARK: - App Delegate

/// Handles post-launch housekeeping and window lifecycle events.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    static let defaultWidth:   CGFloat = 640
    static let compactHeight:  CGFloat = 240
    static let expandedHeight: CGFloat = 620

    /// Weak reference set by MacOSFileCopyToolApp so window lifecycle
    /// events can inspect ViewModel state without owning it.
    weak var viewModel: FileSyncViewModel?

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApp.windows.first {
            window.delegate = self
            resetWindow(window)
        } else {
            Task { @MainActor in
                if let window = NSApp.windows.first {
                    window.delegate = self
                    self.resetWindow(window)
                }
            }
        }
    }

    // MARK: NSWindowDelegate — close

    /// Called when the user clicks the red dot.
    /// Shrinks the frame back to compact so it is the right size when
    /// reopened. ViewModel state is reset in ContentView.onAppear.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        resetWindow(window)
    }

    // MARK: NSWindowDelegate — full screen

    /// After macOS finishes the exit-full-screen animation, resize the window
    /// to a height that reflects whatever content is currently visible:
    ///   • Copy log / progress present → expanded height
    ///   • Nothing run yet (or state was reset) → compact height
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let height = heightForCurrentState()
        setWindowHeight(height, on: window, animated: false)
    }

    // MARK: - Private helpers

    /// Returns the appropriate window height based on what the ViewModel
    /// currently has to show.
    private func heightForCurrentState() -> CGFloat {
        guard let vm = viewModel else { return Self.compactHeight }
        // Show the expanded height whenever there is progress or log content.
        let hasContent = vm.syncHasStarted || vm.isComplete || !vm.logEntries.isEmpty
        return hasContent ? Self.expandedHeight : Self.compactHeight
    }

    /// Resets the window to compact height and clears the autosave name so
    /// macOS never restores an expanded size on the next launch.
    private func resetWindow(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        setWindowHeight(Self.compactHeight, on: window, animated: false)
    }

    /// Resizes `window` to `height`, keeping the top-left corner stationary.
    private func setWindowHeight(_ height: CGFloat, on window: NSWindow, animated: Bool) {
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - App Entry Point

@main
struct MacOSFileCopyToolApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = FileSyncViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    // Give AppDelegate a reference so it can read ViewModel
                    // state when the window exits full screen.
                    appDelegate.viewModel = viewModel
                }
        }
        .defaultSize(width: AppDelegate.defaultWidth, height: AppDelegate.compactHeight)
        .windowResizability(.contentMinSize)
    }
}
