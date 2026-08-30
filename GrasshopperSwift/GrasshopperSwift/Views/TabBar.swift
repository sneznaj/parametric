import SwiftUI

/// Horizontal tab bar showing open projects, with close buttons and a + button for new tabs.
struct ProjectTabBar: View {
    @EnvironmentObject var workspace: WorkspaceManager
    let onNewTab: () -> Void
    let onCloseTab: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(workspace.graphs.enumerated()), id: \.element.id) { index, graph in
                    TabItem(
                        title: graph.displayTitle,
                        isActive: index == workspace.activeIndex,
                        hasUnsavedChanges: graph.hasUnsavedChanges,
                        onSelect: { workspace.activeIndex = index },
                        onClose: { onCloseTab(index) }
                    )
                }

                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New tab")
                .padding(.leading, 2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 30)
        .background(.regularMaterial)
    }
}

// MARK: - Tab Item

private struct TabItem: View {
    let title: String
    let isActive: Bool
    let hasUnsavedChanges: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            // Unsaved indicator or document icon
            if hasUnsavedChanges {
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text(displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 150)
                .foregroundStyle(isActive ? .primary : .secondary)

            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var displayName: String {
        title.replacingOccurrences(of: " — Edited", with: "")
    }
}
