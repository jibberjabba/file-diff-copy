import SwiftUI

/// Shows the progress bar, current-file status line, and copied/skipped/error counters.
struct ProgressSection: View {

    let progress:      Double
    let statusMessage: String
    let copiedCount:   Int
    let skippedCount:  Int
    let deletedCount:  Int
    let errorCount:    Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Progress bar
            ProgressView(value: progress)
                .progressViewStyle(.linear)

            // Current file being processed
            Text(statusMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Counters
            HStack(spacing: 20) {
                Label("\(copiedCount) Copied", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)

                Label("\(skippedCount) Skipped", systemImage: "minus.circle.fill")
                    .foregroundColor(.secondary)

                if deletedCount > 0 {
                    Label("\(deletedCount) Deleted", systemImage: "trash.fill")
                        .foregroundColor(.orange)
                }

                Label("\(errorCount) Errors", systemImage: "xmark.circle.fill")
                    .foregroundColor(errorCount > 0 ? .red : .secondary)
            }
            .font(.caption)
        }
    }
}
