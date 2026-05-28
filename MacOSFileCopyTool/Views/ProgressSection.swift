import SwiftUI

/// Shows the progress bar, current-file status line, and copied/skipped/error counters.
/// In dry-run (preview) mode the labels change to "Would Copy", "Would Delete", etc.
struct ProgressSection: View {

    let progress:      Double
    let statusMessage: String
    let copiedCount:   Int
    let skippedCount:  Int
    let warningCount:  Int
    let deletedCount:  Int
    let errorCount:    Int
    var isDryRun:      Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            ProgressView(value: progress)
                .progressViewStyle(.linear)

            Text(statusMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 20) {
                Label(
                    isDryRun ? "\(copiedCount) Would Copy" : "\(copiedCount) Copied",
                    systemImage: isDryRun ? "doc.badge.arrow.up" : "checkmark.circle.fill"
                )
                .foregroundColor(isDryRun ? .blue : .green)

                Label(
                    isDryRun ? "\(skippedCount) Would Skip" : "\(skippedCount) Skipped",
                    systemImage: "minus.circle.fill"
                )
                .foregroundColor(.secondary)

                if warningCount > 0 {
                    Label("\(warningCount) Warnings", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }

                if deletedCount > 0 {
                    Label(
                        isDryRun ? "\(deletedCount) Would Delete" : "\(deletedCount) Deleted",
                        systemImage: "trash.fill"
                    )
                    .foregroundColor(.red)
                }

                Label("\(errorCount) Errors", systemImage: "xmark.circle.fill")
                    .foregroundColor(errorCount > 0 ? .red : .secondary)
            }
            .font(.caption)
        }
    }
}
