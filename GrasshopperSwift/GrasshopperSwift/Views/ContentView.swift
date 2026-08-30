import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workspace: WorkspaceManager
    @Environment(\.graphFileActions) private var fileActions
    @AppStorage("showConnectorHoverHighlight") private var showConnectorHoverHighlight = true
    @AppStorage(kViewModeKey) private var storedViewMode: String = ViewMode.perspective.rawValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.openWindow) var openWindow

    // Per-tab viewports keyed by graph identity
    @State private var viewports: [UUID: CanvasViewport] = [:]

    // Close-tab alert state
    @State private var showCloseTabAlert = false
    @State private var tabToCloseIndex: Int?

    @State private var deleteKeyMonitor: Any?

    private var graph: NodeGraph { workspace.activeGraph }

    private var activeViewport: CanvasViewport {
        let id = graph.id
        if let existing = viewports[id] { return existing }
        let vp = CanvasViewport()
        viewports[id] = vp
        return vp
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectTabBar(
                onNewTab: { workspace.newTab() },
                onCloseTab: { index in requestCloseTab(at: index) }
            )

            NavigationSplitView(columnVisibility: $columnVisibility) {
                NodeLibraryPanel(graph: graph, viewport: activeViewport, is2DMode: is2DMode)
                    .navigationSplitViewColumnWidth(200)
            } detail: {
                GraphCanvas(graph: graph, viewport: activeViewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        fileActions.new()
                    } label: {
                        Label("New", systemImage: "doc.badge.plus")
                    }
                    .help("New graph (⌘N)")

                    Button {
                        fileActions.open()
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    .help("Open graph (⌘O)")

                    Button {
                        fileActions.save()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .help("Save graph (⌘S)")

                    Divider()

                    Button {
                        openWindow(id: "geometry-preview")
                    } label: {
                        Label("Preview", systemImage: "square.3.layers.3d")
                    }
                    .help("Open geometry preview window")

                    if canSwitch2D3D {
                        Button {
                            toggle2DMode()
                        } label: {
                            Label(is2DMode ? "2D Mode" : "3D Mode", systemImage: is2DMode ? "square.fill" : "cube.fill")
                        }
                        .help(is2DMode ? "Switch to 3D perspective (⌘5)" : "Switch to 2D mode (⌘1)")
                    }

                    Divider()

                    Toggle(isOn: $showConnectorHoverHighlight) {
                        Label("Wire Hover", systemImage: "dot.scope")
                    }
                    .toggleStyle(.button)
                    .help("Show connector hover highlight")

                    Button(role: .destructive) {
                        deleteSelectedNode()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedNode == nil)
                    .help("Delete selected node")

                    Button {
                        clearGraph()
                    } label: {
                        Label("Clear", systemImage: "clear")
                    }
                    .help("Clear all nodes")
                }
            }
            .navigationTitle(graph.displayTitle)
        }
        .alert("Unsaved Changes", isPresented: $showCloseTabAlert) {
            Button("Save") { saveAndCloseTab() }
            Button("Discard Changes", role: .destructive) { discardAndCloseTab() }
            Button("Cancel", role: .cancel) { tabToCloseIndex = nil }
        } message: {
            Text("The project has unsaved changes. Do you want to save before closing?")
        }
        .onAppear {
            loadSampleGraphIfNeeded()
            updateDocumentEdited()
            installDeleteKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeDeleteKeyMonitor()
        }
        .onChange(of: graph.hasUnsavedChanges) { _, _ in updateDocumentEdited() }
        .onChange(of: graph.currentFileURL) { _, _ in updateDocumentEdited() }
        .onReceive(NotificationCenter.default.publisher(for: .closeTabRequested)) { notification in
            if let index = notification.userInfo?["index"] as? Int {
                requestCloseTab(at: index)
            }
        }
    }

    private func clearGraph() {
        graph.nodes.removeAll()
        graph.connections.removeAll()
    }

    private var is2DMode: Bool {
        storedViewMode == ViewMode.twoD.rawValue
    }

    /// 2D and 3D nodes can't be mixed in the same project, so the pipeline can only be
    /// switched while the active graph is empty.
    private var canSwitch2D3D: Bool {
        graph.nodes.isEmpty
    }

    private func toggle2DMode() {
        guard canSwitch2D3D else { return }
        storedViewMode = is2DMode ? ViewMode.perspective.rawValue : ViewMode.twoD.rawValue
    }

    private var selectedNode: Node? {
        graph.nodes.first { $0.isSelected }
    }

    private var hoveredNode: Node? {
        guard let hoveredNodeID = graph.hoveredNodeID else { return nil }
        return graph.node(id: hoveredNodeID)
    }

    private var hoveredConnection: Connection? {
        guard let hoveredConnectionID = graph.hoveredConnectionID else { return nil }
        return graph.connections.first { $0.id == hoveredConnectionID }
    }

    private func deleteSelectedNode() {
        guard let selectedNode else { return }
        graph.removeNode(selectedNode.id)
    }

    private func deleteActiveItem() {
        if let hoveredConnection {
            graph.removeConnection(hoveredConnection.id)
            return
        }

        if let hoveredNode {
            graph.removeNode(hoveredNode.id)
            return
        }

        deleteSelectedNode()
    }

    /// Installs the global Delete/Forward-Delete monitor at most once per
    /// `ContentView` lifecycle — without this guard, every `onAppear` (tab
    /// switches, window refocus) stacked another monitor on top of the last,
    /// each one independently deleting the hovered/selected item on the same
    /// keypress.
    private func installDeleteKeyMonitorIfNeeded() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Delete (backspace) = 51, Forward Delete = 117
            if event.keyCode == 51 || event.keyCode == 117 {
                // AppKit's default text-editing behavior hides the system
                // pointer on keystrokes routed to a focused NSText field
                // (setHiddenUntilMouseMoves). Backspace should never leave
                // the pointer hidden over the canvas, so cancel that here
                // regardless of which branch below handles the key.
                NSCursor.setHiddenUntilMouseMoves(false)

                // Let an in-progress text edit (Math Expression, slider range
                // fields, etc.) handle its own backspace instead of hijacking
                // the keystroke to delete whatever the mouse happens to be
                // resting on.
                if NSApp.keyWindow?.firstResponder is NSText {
                    return event
                }
                if hoveredConnection != nil || hoveredNode != nil || selectedNode != nil {
                    deleteActiveItem()
                    return nil
                }
            }
            return event
        }
    }

    private func removeDeleteKeyMonitor() {
        if let deleteKeyMonitor {
            NSEvent.removeMonitor(deleteKeyMonitor)
        }
        deleteKeyMonitor = nil
    }

    private func loadSampleGraphIfNeeded() {
        guard graph.nodes.isEmpty else { return }
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        guard !hasLaunchedBefore else { return }
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        loadSampleGraph()
    }

    private func updateDocumentEdited() {
        NSApplication.shared.keyWindow?.isDocumentEdited = graph.hasUnsavedChanges
    }

    // MARK: - Tab Close

    private func requestCloseTab(at index: Int) {
        let g = workspace.graphs[index]
        if g.hasUnsavedChanges {
            tabToCloseIndex = index
            showCloseTabAlert = true
        } else {
            viewports.removeValue(forKey: g.id)
            workspace.closeTab(at: index)
        }
    }

    private func saveAndCloseTab() {
        guard let index = tabToCloseIndex else { return }
        let g = workspace.graphs[index]
        if let url = g.currentFileURL {
            do {
                try g.save(to: url)
                viewports.removeValue(forKey: g.id)
                workspace.closeTab(at: index)
            } catch {
                NSAlert(error: error).runModal()
            }
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.grasshopperGraph]
            panel.nameFieldStringValue = "Untitled.ghs"
            panel.canCreateDirectories = true
            panel.title = "Save Graph"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try g.save(to: url)
                viewports.removeValue(forKey: g.id)
                workspace.closeTab(at: index)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        tabToCloseIndex = nil
    }

    private func discardAndCloseTab() {
        guard let index = tabToCloseIndex else { return }
        viewports.removeValue(forKey: workspace.graphs[index].id)
        workspace.closeTab(at: index)
        tabToCloseIndex = nil
    }

    private func loadSampleGraph() {
        // ── Math subgraph ──────────────────────────────────
        let numberInput = NodeFactory.make(.numberInput, at: CGPoint(x: 40, y: 20))
        numberInput.outputs[0].value = .number(12)
        let sliderA = NodeFactory.make(.numberSlider, at: CGPoint(x: 40, y: 60))
        sliderA.outputs[0].value = .number(5)
        let sliderB = NodeFactory.make(.numberSlider, at: CGPoint(x: 40, y: 190))
        sliderB.outputs[0].value = .number(3)
        let multiply = NodeFactory.make(.multiply, at: CGPoint(x: 260, y: 110))
        let out = NodeFactory.make(.output, at: CGPoint(x: 460, y: 110))

        // ── Geometry subgraph ───────────────────────────────
        // Radius slider → Circle
        let radiusSlider = NodeFactory.make(.numberSlider, at: CGPoint(x: 40, y: 340))
        radiusSlider.outputs[0].value = .number(6)

        let circleNode = NodeFactory.make(.geoCircle, at: CGPoint(x: 260, y: 330))
        let materialNode = NodeFactory.make(.materialAnodizedAluminum, at: CGPoint(x: 40, y: 430))
        let geoOut = NodeFactory.make(.output, at: CGPoint(x: 500, y: 400))

        // Sides slider → Polygon
        let sidesSlider = NodeFactory.make(.numberSlider, at: CGPoint(x: 40, y: 490))
        sidesSlider.outputs[0].value = .number(6)
        let polyNode = NodeFactory.make(.geoPolygon, at: CGPoint(x: 260, y: 470))

        // Grid
        let gridW = NodeFactory.make(.numberSlider, at: CGPoint(x: 40, y: 640))
        gridW.outputs[0].value = .number(20)
        let gridNode = NodeFactory.make(.geoGrid, at: CGPoint(x: 260, y: 620))

        graph.nodes = [numberInput, sliderA, sliderB, multiply, out,
                       radiusSlider, circleNode,
                       materialNode, geoOut,
                       sidesSlider, polyNode,
                       gridW, gridNode]

        // Math connections
        graph.addConnection(Connection(fromNodeID: sliderA.id,   fromPortID: sliderA.outputs[0].id,
                                       toNodeID: multiply.id,   toPortID: multiply.inputs[0].id))
        graph.addConnection(Connection(fromNodeID: sliderB.id,   fromPortID: sliderB.outputs[0].id,
                                       toNodeID: multiply.id,   toPortID: multiply.inputs[1].id))
        graph.addConnection(Connection(fromNodeID: multiply.id,  fromPortID: multiply.outputs[0].id,
                                       toNodeID: out.id,        toPortID: out.inputs[0].id))

        // Circle: radius slider → radius port
        graph.addConnection(Connection(fromNodeID: radiusSlider.id, fromPortID: radiusSlider.outputs[0].id,
                                       toNodeID: circleNode.id,     toPortID: circleNode.inputs[1].id))
        graph.addConnection(Connection(fromNodeID: circleNode.id, fromPortID: circleNode.outputs[0].id,
                                       toNodeID: geoOut.id,        toPortID: geoOut.inputs[0].id))
        if let matPort = geoOut.inputs.first(where: { $0.type == .material }) {
            graph.addConnection(Connection(fromNodeID: materialNode.id, fromPortID: materialNode.outputs[0].id,
                                           toNodeID: geoOut.id,          toPortID: matPort.id))
        }

        // Polygon: radius slider → radius, sides slider → sides
        graph.addConnection(Connection(fromNodeID: radiusSlider.id, fromPortID: radiusSlider.outputs[0].id,
                                       toNodeID: polyNode.id,       toPortID: polyNode.inputs[1].id))
        graph.addConnection(Connection(fromNodeID: sidesSlider.id,  fromPortID: sidesSlider.outputs[0].id,
                                       toNodeID: polyNode.id,       toPortID: polyNode.inputs[2].id))

        // Grid: width slider → width & height
        graph.addConnection(Connection(fromNodeID: gridW.id, fromPortID: gridW.outputs[0].id,
                                       toNodeID: gridNode.id, toPortID: gridNode.inputs[0].id))
        graph.addConnection(Connection(fromNodeID: gridW.id, fromPortID: gridW.outputs[0].id,
                                       toNodeID: gridNode.id, toPortID: gridNode.inputs[1].id))

        graph.evaluate()
    }
}
