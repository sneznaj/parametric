import Combine
import SwiftUI

/// Manages multiple NodeGraph instances as tabs, tracking the active graph
/// and broadcasting preview shapes for the geometry preview window.
final class WorkspaceManager: ObservableObject {
    @Published var graphs: [NodeGraph] = []
    @Published var activeIndex: Int = 0 {
        didSet { rebindActiveGraph() }
    }
    @Published var activePreviewShapes: [GeometricShape] = []
    @Published var activeTrackedShapes: [TrackedShape] = []
    @Published var activeRenderConfig: RenderConfig = .cinematicDefault

    var activeGraph: NodeGraph {
        graphs[activeIndex]
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        graphs.append(NodeGraph())
        rebindActiveGraph()
    }

    // MARK: - Tab Lifecycle

    /// Creates a new empty tab and switches to it.
    func newTab() {
        let graph = NodeGraph()
        graphs.append(graph)
        activeIndex = graphs.count - 1
    }

    /// Closes the tab at the given index.
    /// - Returns: `false` if this is the last remaining tab (cannot close).
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard graphs.count > 1 else { return false }
        graphs.remove(at: index)
        if activeIndex >= graphs.count {
            activeIndex = graphs.count - 1
        } else if activeIndex > index {
            activeIndex -= 1
        }
        // activeIndex unchanged when closing a tab to the right of the active one
        return true
    }

    /// Opens a graph into a new tab, or replaces the current tab if it is empty and untitled.
    func openGraph(_ graph: NodeGraph) {
        if shouldReplaceCurrentTab() {
            graphs[activeIndex] = graph
            rebindActiveGraph()
        } else {
            graphs.append(graph)
            activeIndex = graphs.count - 1
        }
    }

    /// Returns true when the current tab has no nodes and no file URL —
    /// meaning it's a fresh untitled tab that can be replaced by an "Open" action.
    func shouldReplaceCurrentTab() -> Bool {
        activeGraph.nodes.isEmpty && activeGraph.currentFileURL == nil
    }

    // MARK: - Internal

    private func rebindActiveGraph() {
        cancellables.removeAll()

        guard activeIndex < graphs.count else { return }
        let graph = graphs[activeIndex]

        if let mode = graph.impliedViewMode {
            UserDefaults.standard.set(mode.rawValue, forKey: kViewModeKey)
        }

        graph.$previewShapes
            .sink { [weak self] shapes in
                self?.activePreviewShapes = shapes
            }
            .store(in: &cancellables)

        graph.$previewTrackedShapes
            .sink { [weak self] tracked in
                self?.activeTrackedShapes = tracked
            }
            .store(in: &cancellables)

        graph.$renderConfig
            .sink { [weak self] config in
                self?.activeRenderConfig = config
            }
            .store(in: &cancellables)

        graph.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }
}
