import SwiftUI

/// A scrollable, color-coded list of log entries produced during a sync run.
///
/// - Green  → COPIED
/// - Gray   → SKIPPED
/// - Red    → ERROR
struct LogView: View {

    let entries: [LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        Text(entry.displayText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(rowColor(for: entry.action))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            // Auto-scroll to the newest entry as the log grows.
            .onChange(of: entries.count) {
                if let last = entries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func rowColor(for action: FileSyncAction) -> Color {
        switch action {
        case .copied:  return .green
        case .skipped: return .secondary
        case .deleted: return .orange
        case .error:   return .red
        }
    }
}
