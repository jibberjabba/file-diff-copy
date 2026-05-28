import SwiftUI

/// A scrollable, color-coded list of log entries produced during a sync run.
///
/// - Green      → COPIED
/// - Blue       → WOULD COPY (dry-run preview)
/// - Gray       → SKIPPED / NOTE
/// - Orange     → DELETED, WOULD DEL, NEWER DST, SIZE DIFF
/// - Red        → ERROR
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
            .onChange(of: entries.count, perform: { _ in
                if let last = entries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            })
        }
    }

    // MARK: - Private

    private func rowColor(for action: FileSyncAction) -> Color {
        switch action {
        case .copied(_):        return .green
        case .wouldCopy(_):     return .blue
        case .skipped:          return .secondary
        case .deleted:          return .orange
        case .wouldDelete:      return .orange
        case .newerDestination: return .orange
        case .sizeMismatch:     return .orange
        case .notice(_):        return .secondary
        case .error(_):         return .red
        }
    }
}
