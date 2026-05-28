import SwiftUI

/// Modal sheet presented before a Mirror sync that lists files to be deleted
/// and requires explicit confirmation before any destructive action is taken.
struct MirrorConfirmationView: View {

    let orphanPaths: [String]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm Mirror Sync")
                        .font(.headline)

                    if orphanPaths.isEmpty {
                        Text("No files will be deleted — the destination is already a mirror of the source.")
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(orphanPaths.count) file\(orphanPaths.count == 1 ? "" : "s") at the destination will be permanently deleted. This cannot be undone.")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Deletion list
            if !orphanPaths.isEmpty {
                GroupBox("Files to be deleted:") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(orphanPaths, id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 200)
                }
            }

            // Action buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(orphanPaths.isEmpty ? "Sync" : "Delete and Sync",
                       role: orphanPaths.isEmpty ? nil : .destructive,
                       action: onConfirm)
            }
        }
        .padding(24)
        .frame(minWidth: 460, maxWidth: 560)
    }
}
