import SwiftUI

struct ContentView: View {
    @EnvironmentObject var graph: NodeGraph
    @AppStorage("showConnectorHoverHighlight") private var showConnectorHoverHighlight = false
    @StateObject private var canvasViewport = CanvasViewport()
    @State private var showLibrary = true
    @State private var showInspector = true
    @Environment(\.openWindow) var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            NodeLibraryPanel(graph: graph, viewport: canvasViewport)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            HStack(spacing: 0) {
                GraphCanvas(graph: graph, viewport: canvasViewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    Divider()
                    InspectorPanel(graph: graph)
                        .frame(width: 220)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation { showLibrary.toggle() }
                } label: {
                    Label("Library", systemImage: "sidebar.left")
                }
                .help("Toggle node library")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "geometry-preview")
                } label: {
                    Label("Preview", systemImage: "square.3.layers.3d")
                }
                .help("Open geometry preview window")

                Divider()

                Button {
                    graph.evaluate()
                } label: {
                    Label("Evaluate", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Re-evaluate graph (⌘R)")

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
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear all nodes")

                Button {
                    withAnimation { showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle inspector")
            }
        }
        .navigationTitle("Grasshopper Swift")
        .onAppear {
            loadSampleGraph()
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Delete (backspace) = 51, Forward Delete = 117
                if event.keyCode == 51 || event.keyCode == 117 {
                    if hoveredConnection != nil || hoveredNode != nil || selectedNode != nil {
                        deleteActiveItem()
                        return nil
                    }
                }
                return event
            }
        }
    }

    private func clearGraph() {
        graph.nodes.removeAll()
        graph.connections.removeAll()
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
        let colorNode = NodeFactory.make(.colorPicker, at: CGPoint(x: 40, y: 430))
        colorNode.outputs[0].value = .color(.mint)
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
                       colorNode, geoOut,
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
        graph.addConnection(Connection(fromNodeID: colorNode.id,  fromPortID: colorNode.outputs[0].id,
                                       toNodeID: geoOut.id,       toPortID: geoOut.inputs[1].id))

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

// MARK: - Inspector Panel

struct InspectorPanel: View {
    @ObservedObject var graph: NodeGraph

    var selectedNode: Node? {
        graph.nodes.first { $0.isSelected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.headline)
                .padding()

            Divider()

            if let node = selectedNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Node info
                        GroupBox("Node") {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Type", value: node.kind.defaultLabel)
                                LabeledContent("Category", value: node.kind.category.rawValue)
                                LabeledContent("ID", value: node.id.uuidString.prefix(8) + "…")
                            }
                            .font(.system(size: 12))
                        }

                        // Inputs
                        if !node.inputs.isEmpty {
                            GroupBox("Inputs") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(node.inputs) { port in
                                        PortRow(port: port)
                                    }
                                }
                                .font(.system(size: 12))
                            }
                        }

                        // Outputs
                        if !node.outputs.isEmpty {
                            GroupBox("Outputs") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(node.outputs) { port in
                                        PortRow(port: port)
                                    }
                                }
                                .font(.system(size: 12))
                            }
                        }

                        // Connections
                        let nodeConns = graph.connections.filter {
                            $0.fromNodeID == node.id || $0.toNodeID == node.id
                        }
                        if !nodeConns.isEmpty {
                            GroupBox("Connections") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(nodeConns) { conn in
                                        ConnectionRow(conn: conn, graph: graph, currentNodeID: node.id)
                                    }
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                    .padding()
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "cursorarrow.click")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Select a node to inspect")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .background(.regularMaterial)
    }
}

struct PortRow: View {
    let port: Port
    var body: some View {
        HStack {
            Circle()
                .fill(port.type.color)
                .frame(width: 8, height: 8)
            Text(port.name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(port.value?.displayString ?? "—")
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

struct ConnectionRow: View {
    let conn: Connection
    let graph: NodeGraph
    let currentNodeID: UUID

    var body: some View {
        let isOut = conn.fromNodeID == currentNodeID
        HStack(spacing: 4) {
            Image(systemName: isOut ? "arrow.right" : "arrow.left")
                .foregroundStyle(isOut ? .green : .blue)
                .font(.system(size: 10))
            let otherID = isOut ? conn.toNodeID : conn.fromNodeID
            if let other = graph.node(id: otherID) {
                Text(other.title)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button(role: .destructive) {
                graph.removeConnection(conn.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}
