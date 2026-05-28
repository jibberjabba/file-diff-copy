import SwiftUI
import AppKit

/// Main application window.
///
/// Layout strategy:
/// - Compact on launch: folder pickers + action buttons only.
/// - Expands automatically (animated) when a sync starts to reveal the
///   progress section and live copy log.
struct ContentView: View {

    @EnvironmentObject private var vm: FileSyncViewModel

    // Heights used for the two window states — must match AppDelegate constants.
    private let compactHeight:  CGFloat = AppDelegate.compactHeight
    private let expandedHeight: CGFloat = AppDelegate.expandedHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Folder pickers ────────────────────────────────────────────
            GroupBox {
                VStack(spacing: 10) {
                    FolderPickerRow(label: "Source:", url: vm.sourceURL) {
                        vm.chooseSourceFolder()
                    }
                    FolderPickerRow(label: "Destination:", url: vm.destinationURL) {
                        vm.chooseDestinationFolder()
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Text("Compare:")
                            .frame(width: 95, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Picker("", selection: $vm.comparisonMode) {
                            ForEach(ComparisonMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode).help(mode.tooltip)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .disabled(vm.isRunning)
                    }
                    // Always in layout so GroupBox height is constant; only visible for Mirror.
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Mirror permanently deletes destination files not in source.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(vm.comparisonMode == .mirror ? 1 : 0)
                }
                .padding(4)
            }

            // ── Action buttons ────────────────────────────────────────────
            HStack {
                Button(vm.isScanning ? "Scanning…"
                       : vm.comparisonMode == .mirror ? "Start Mirror" : "Start Copy") {
                    vm.startSync()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStartSync)

                Spacer()

                Button("Cancel") {
                    vm.cancelSync()
                }
                .disabled(!vm.isRunning)
            }

            // ── Progress (slides in when sync starts) ─────────────────────
            if vm.isRunning || vm.isComplete {
                GroupBox("Progress") {
                    ProgressSection(
                        progress:      vm.progress,
                        statusMessage: vm.statusMessage,
                        copiedCount:   vm.copiedCount,
                        skippedCount:  vm.skippedCount,
                        deletedCount:  vm.deletedCount,
                        errorCount:    vm.errorCount
                    )
                    .padding(4)
                }
                .transition(.move(edge: .top).combined(with: .opacity))

                // Error banner shown after completion when errors occurred.
                if vm.isComplete && vm.errorCount > 0 {
                    Label(
                        "\(vm.errorCount) error(s) occurred — see the log for details.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(.red)
                    .font(.callout)
                    .transition(.opacity)
                }
            }

            // ── Copy log ──────────────────────────────────────────────────
            if !vm.logEntries.isEmpty {
                GroupBox("Copy Log") {
                    LogView(entries: vm.logEntries)
                        .frame(minHeight: 180)
                }
                .transition(.move(edge: .top).combined(with: .opacity))

                HStack {
                    Spacer()
                    Button("Save Log…") {
                        vm.saveLog()
                    }
                    .disabled(vm.isRunning)
                }
                .transition(.opacity)
            }

            // Pushes all content to the top when the window is taller than
            // the natural content height (e.g. maximised / full-screen).
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: compactHeight)
        // Every time a window is created (first launch, red-dot reopen,
        // File → New Window) reset the ViewModel and shrink to compact.
        // onAppear fires on a new view hierarchy — it does NOT fire when
        // an already-open window comes back to the foreground, so an
        // in-progress sync is never disturbed.
        .onAppear {
            vm.resetForNextSession()
            Task { @MainActor in
                setWindowHeight(compactHeight, animated: false)
            }
        }
        // Expand the window the moment a sync begins.
        .onChange(of: vm.isRunning) { _, isRunning in
            if isRunning {
                // Skip the resize if the window is already maximised or in
                // full-screen — let it stay that way. windowDidExitFullScreen
                // in AppDelegate will pick the right height on the way back out.
                if let window = NSApp.keyWindow ?? NSApp.windows.first,
                   !window.styleMask.contains(.fullScreen),
                   !window.isZoomed {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        setWindowHeight(expandedHeight, animated: true)
                    }
                }
            }
        }
        .sheet(isPresented: $vm.pendingMirrorConfirmation) {
            MirrorConfirmationView(
                orphanPaths: vm.orphanedFiles,
                onConfirm:   { vm.confirmMirror() },
                onCancel:    { vm.cancelMirror() }
            )
        }
    }

    // MARK: - Window helpers

    /// Resizes the window to `height`, keeping the top-left corner stationary.
    /// Uses AppKit's built-in animator for a smooth native macOS feel.
    private func setWindowHeight(_ height: CGFloat, animated: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }

        var frame = window.frame
        // Adjust the Y origin so the top of the window stays fixed.
        frame.origin.y = frame.maxY - height
        frame.size.height = height

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: false)
        }
    }
}
