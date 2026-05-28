import SwiftUI

/// A reusable row showing a folder label, its selected path, and a Choose button.
struct FolderPickerRow: View {

    /// Display label shown to the left of the path field (e.g. "Source:").
    let label: String
    /// The currently selected folder URL, or nil if nothing is selected.
    let url: URL?
    /// Called when the user taps "Choose…".
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 95, alignment: .trailing)
                .foregroundColor(.secondary)

            // Path display field
            Text(url?.path ?? "No folder selected")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(url == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            Button("Choose…", action: action)
        }
    }
}
