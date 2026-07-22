import SwiftUI

struct NodeLibraryPanel: View {
    @ObservedObject var graph: NodeGraph
    @ObservedObject var viewport: CanvasViewport
    @State private var searchText = ""

    var filteredCategories: [(NodeCategory, [NodeKind])] {
        NodeCategory.allCases.compactMap { cat in
            let kinds = cat.kinds.filter {
                searchText.isEmpty || $0.defaultLabel.localizedCaseInsensitiveContains(searchText)
            }
            return kinds.isEmpty ? nil : (cat, kinds)
        }
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

            // Node list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(filteredCategories, id: \.0) { (category, kinds) in
                        Section {
                            ForEach(kinds, id: \.self) { kind in
                                NodeLibraryRow(kind: kind) {
                                    addNode(kind)
                                }
                            }
                        } header: {
                            CategoryHeader(category: category)
                        }
                    }
                }
            }
        }
        .frame(width: 200)
        .background(.regularMaterial)
    }

    private func addNode(_ kind: NodeKind) {
        let prototype = NodeFactory.make(kind, at: .zero)
        let nodeSize = CGSize(width: Node.width, height: prototype.height)
        prototype.position = viewport.nextNodePosition(nodeSize: nodeSize)
        let node = prototype
        graph.addNode(node)
    }
}

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
    let onAdd: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onAdd) {
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
    }
}
