import SwiftUI
import AppKit

struct ContentView: View {

    @EnvironmentObject private var vm: FileSyncViewModel

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

                    // All four comparison modes in one unified radio group.
                    // Uses a binding no-op during sync instead of .disabled() so
                    // AppKit tooltip tracking areas are never torn down.
                    HStack(spacing: 12) {
                        Text("Compare:")
                            .frame(width: 95, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { vm.comparisonMode },
                            set: { if !vm.isRunning { vm.comparisonMode = $0 } }
                        )) {
                            ForEach(ComparisonMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode).help(mode.tooltip)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .opacity(vm.isRunning ? 0.5 : 1.0)
                    }

                    // Thorough performance warning (always in layout; visible only when Thorough is selected).
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("SHA-256 checksums every file on both sides — may be slow on large folders.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(vm.comparisonMode == .thorough ? 1 : 0)

                    // Mirror warning (always in layout; visible only when Mirror is selected).
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

            // Bookmark unavailability warnings (shown when a volume is not mounted).
            if vm.sourceBookmarkUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Source folder unavailable — the volume may not be mounted.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            if vm.destinationBookmarkUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Destination folder unavailable — the volume may not be mounted.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // ── Action buttons ────────────────────────────────────────────
            HStack {
                Button(vm.isScanning ? "Scanning…"
                       : vm.comparisonMode == .mirror ? "Start Mirror" : "Start Copy") {
                    vm.startSync()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStartSync)

                Button("Preview") {
                    vm.startPreview()
                }
                .disabled(!vm.canStartSync)
                .help("Run comparison without copying or deleting any files")

                Spacer()

                Button("Cancel") {
                    vm.cancelSync()
                }
                .disabled(!vm.isRunning)
            }

            // ── Progress ──────────────────────────────────────────────────
            if vm.isRunning || vm.isComplete {
                GroupBox(vm.isDryRun ? "Preview" : "Progress") {
                    ProgressSection(
                        progress:      vm.progress,
                        statusMessage: vm.statusMessage,
                        copiedCount:   vm.copiedCount,
                        skippedCount:  vm.skippedCount,
                        warningCount:  vm.warningCount,
                        deletedCount:  vm.deletedCount,
                        errorCount:    vm.errorCount,
                        isDryRun:      vm.isDryRun
                    )
                    .padding(4)
                }
                .transition(.move(edge: .top).combined(with: .opacity))

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
                GroupBox(vm.isDryRun ? "Preview Log" : "Copy Log") {
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

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: compactHeight)
        .onAppear {
            vm.resetForNextSession()
            Task { @MainActor in
                setWindowHeight(compactHeight, animated: false)
            }
        }
        .onChange(of: vm.isRunning, perform: { isRunning in
            if isRunning {
                if let window = NSApp.keyWindow ?? NSApp.windows.first,
                   !window.styleMask.contains(.fullScreen),
                   !window.isZoomed {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        setWindowHeight(expandedHeight, animated: true)
                    }
                }
            }
        })
        .sheet(isPresented: $vm.pendingMirrorConfirmation) {
            MirrorConfirmationView(
                orphanPaths: vm.orphanedFiles,
                onConfirm:   { vm.confirmMirror() },
                onCancel:    { vm.cancelMirror() }
            )
        }
    }

    // MARK: - Window helpers

    private func setWindowHeight(_ height: CGFloat, animated: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }

        var frame = window.frame
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
