import SwiftUI

/// Grasshopper-style ribbon node picker: a horizontal category tab strip
/// (one tab per `NodeCategory`) plus, below it, the active category's nodes
/// grouped into named panels by `NodeKind.subcategory` — mirroring
/// Grasshopper's tab → panel layout. Typing in the search field switches to
/// a flat, cross-category filtered list instead (so a node can always be
/// found without knowing its tab).
struct NodeLibraryPanel: View {
    @ObservedObject var graph: NodeGraph
    @ObservedObject var viewport: CanvasViewport
    @State private var searchText = ""
    @State private var selectedCategory: NodeCategory = .params
    @State private var panelHeight: CGFloat = 0
    var is2DMode: Bool = false

    private static let coordinateSpace = "NodeLibraryPanel"

    private func isVisible(_ kind: NodeKind) -> Bool {
        if is2DMode && kind.is3DOnly { return false }
        if !is2DMode && kind.is2DOnly { return false }
        return true
    }

    private var availableCategories: [NodeCategory] {
        NodeCategory.allCases.filter { cat in cat.kinds.contains(where: isVisible) }
    }

    private var searchResults: [(NodeCategory, [NodeKind])] {
        NodeCategory.allCases.compactMap { cat in
            let kinds = cat.kinds.filter { kind in
                isVisible(kind) && kind.defaultLabel.localizedCaseInsensitiveContains(searchText)
            }
            return kinds.isEmpty ? nil : (cat, kinds)
        }
    }

    /// Active category's nodes grouped into named panels by subcategory,
    /// in first-seen order. `nil` subcategory kinds form an unlabeled panel.
    private var groupedActiveCategory: [(String?, [NodeKind])] {
        var order: [String?] = []
        var buckets: [String?: [NodeKind]] = [:]
        for kind in selectedCategory.kinds where isVisible(kind) {
            let key = kind.subcategory
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(kind)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search nodes…", text: $searchText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            if searchText.isEmpty {
                CategoryTabStrip(categories: availableCategories, selected: $selectedCategory)
                Divider()
            }

            // Node list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    if searchText.isEmpty {
                        ForEach(groupedActiveCategory, id: \.0) { subcategory, kinds in
                            Section {
                                ForEach(kinds, id: \.self) { kind in
                                    NodeLibraryRow(kind: kind, coordinateSpace: Self.coordinateSpace) { buttonY in addNode(kind, buttonY: buttonY) }
                                }
                            } header: {
                                if let subcategory {
                                    PanelHeader(title: subcategory, color: selectedCategory.color)
                                }
                            }
                        }
                    } else {
                        ForEach(searchResults, id: \.0) { category, kinds in
                            Section {
                                ForEach(kinds, id: \.self) { kind in
                                    NodeLibraryRow(kind: kind, coordinateSpace: Self.coordinateSpace) { buttonY in addNode(kind, buttonY: buttonY) }
                                }
                            } header: {
                                CategoryHeader(category: category)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 200)
        .background(.regularMaterial)
        .coordinateSpace(name: Self.coordinateSpace)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { panelHeight = $0 }
        .onAppear { ensureValidSelection() }
        .onChange(of: is2DMode) { ensureValidSelection() }
    }

    private func ensureValidSelection() {
        if !availableCategories.contains(selectedCategory) {
            selectedCategory = availableCategories.first ?? .params
        }
    }

    /// - Parameter buttonY: the clicked row's vertical position within the
    ///   panel's coordinate space (see `Self.coordinateSpace`), used to place
    ///   the new node at the same relative height in the canvas so it lands
    ///   next to the button that created it.
    private func addNode(_ kind: NodeKind, buttonY: CGFloat) {
        let prototype = NodeFactory.make(kind, at: .zero)
        let nodeSize = CGSize(width: Node.width, height: prototype.height)
        let anchorYFraction = panelHeight > 0 ? min(max(buttonY / panelHeight, 0), 1) : nil
        prototype.position = viewport.nextNodePosition(nodeSize: nodeSize, anchorYFraction: anchorYFraction)
        graph.addNode(prototype)
    }
}

// MARK: - Category Tab Strip

private struct CategoryTabStrip: View {
    let categories: [NodeCategory]
    @Binding var selected: NodeCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(categories, id: \.self) { category in
                    CategoryTabButton(category: category, isActive: category == selected) {
                        selected = category
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.regularMaterial)
    }
}

private struct CategoryTabButton: View {
    let category: NodeCategory
    let isActive: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? category.color : .secondary)
            .frame(width: 26, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? category.color.opacity(0.15) : (isHovered ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
            .help(category.rawValue)
    }
}

// MARK: - Panel Header (subcategory grouping within a tab)

private struct PanelHeader: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color.opacity(0.6)).frame(width: 4, height: 4)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .background(.regularMaterial)
    }
}

// MARK: - Category Header (used for cross-category search results)

struct CategoryHeader: View {
    let category: NodeCategory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(category.color)
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial)
    }
}

struct NodeLibraryRow: View {
    let kind: NodeKind
    /// Coordinate space (set by the panel) to measure this row's position
    /// in, so its position can be reported back to `onAdd`. `nil` (e.g. in
    /// contexts that don't care where the node lands) skips the measurement.
    var coordinateSpace: String? = nil
    let onAdd: (CGFloat) -> Void
    @State private var isHovered = false
    @State private var midY: CGFloat = 0

    var body: some View {
        Button(action: { onAdd(midY) }) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(kind.category.color)
                    .frame(width: 18)
                Text(kind.defaultLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isHovered ? Color.accentColor.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(RowGeometryTracker(coordinateSpace: coordinateSpace, midY: $midY))
    }
}

/// Tracks a row's vertical center in `coordinateSpace`, if one was given.
private struct RowGeometryTracker: ViewModifier {
    let coordinateSpace: String?
    @Binding var midY: CGFloat

    func body(content: Content) -> some View {
        if let coordinateSpace {
            content.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(coordinateSpace)).midY }) { midY = $0 }
        } else {
            content
        }
    }
}
