import AppKit
import SwiftUI

struct GraphCanvas: View {
    @ObservedObject var graph: NodeGraph
    @ObservedObject var viewport: CanvasViewport
    @AppStorage("showConnectorHoverHighlight") private var showConnectorHoverHighlight = false
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var pendingWire: PendingWire? = nil
    @State private var liveNodeOffsets: [UUID: CGSize] = [:]
    private let contentPadding: CGFloat = 240
    private let connectionHoverPadding: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let contentRect = canvasContentRect(viewportSize: geo.size)
            ZStack(alignment: .topLeading) {
                // Grid background
                GridBackground(offset: offset, scale: scale)
                    .ignoresSafeArea()
                    .gesture(panGesture)
                    .onTapGesture {
                        // Deselect all
                        for node in graph.nodes { node.isSelected = false }
                    }

                // Canvas content
                ZStack(alignment: .topLeading) {
                    // Wires
                    ConnectionsView(
                        graph: graph,
                        liveNodeOffsets: liveNodeOffsets,
                        canvasOrigin: contentRect.origin,
                        hoveredConnectionID: graph.hoveredConnectionID,
                        showsHoverHighlight: showConnectorHoverHighlight,
                        pendingWire: translatedPendingWire(origin: contentRect.origin)
                    )

                    // Nodes
                    ForEach(graph.nodes) { node in
                        NodeView(
                            node: node,
                            graph: graph,
                            onPortTap: { nodeID, portID, isInput in
                                handlePortTap(nodeID: nodeID, portID: portID, isInput: isInput)
                            },
                            onTap: {
                                let wasSelected = node.isSelected
                                for n in graph.nodes { n.isSelected = false }
                                node.isSelected = !wasSelected
                            },
                            onDelete: {
                                graph.removeNode(node.id)
                            },
                            liveOffset: liveNodeOffsets[node.id] ?? .zero,
                            onDragChanged: { delta in
                                handleNodeDrag(node: node, delta: delta)
                            },
                            onDragEnded: {
                                handleNodeDragEnded(node: node)
                            }
                        )
                        .frame(width: Node.width, height: node.height, alignment: .topLeading)
                        .offset(
                            x: node.position.x - contentRect.minX,
                            y: node.position.y - contentRect.minY
                        )
                        .zIndex(node.isSelected ? 1 : 0)
                    }
                }
                .frame(width: contentRect.width, height: contentRect.height, alignment: .topLeading)
                .scaleEffect(scale)
                .offset(
                    x: offset.width + contentRect.minX * scale,
                    y: offset.height + contentRect.minY * scale
                )
            }
            .clipped()
            .gesture(magnificationGesture)
            .background(
                CanvasHoverTracker(
                    onMove: { mousePoint in
                        updateHoveredConnection(at: mousePoint, contentRect: contentRect)
                    },
                    onExit: {
                        graph.hoveredConnectionID = nil
                    }
                )
            )
            .onAppear {
                syncViewport(size: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                syncViewport(size: newSize)
            }
            .onChange(of: offset) { _, _ in
                syncViewport(size: geo.size)
            }
            .onChange(of: scale) { _, _ in
                syncViewport(size: geo.size)
            }
            // Right-click on canvas to cancel pending wire
            .onTapGesture(count: 1) { pendingWire = nil }
        }
    }

    // MARK: - Pan

    @State private var panStart: CGSize = .zero
    @State private var panOffset: CGSize = .zero

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { val in
                offset = CGSize(
                    width: panOffset.width + val.translation.width,
                    height: panOffset.height + val.translation.height
                )
            }
            .onEnded { _ in panOffset = offset }
    }

    // MARK: - Zoom

    @State private var lastScale: CGFloat = 1.0

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { val in
                scale = max(0.25, min(3.0, lastScale * val))
            }
            .onEnded { _ in lastScale = scale }
    }

    // MARK: - Node Drag

    private func handleNodeDrag(node: Node, delta: CGSize) {
        liveNodeOffsets[node.id] = CGSize(
            width: delta.width / scale,
            height: delta.height / scale
        )
    }

    private func handleNodeDragEnded(node: Node) {
        let live = liveNodeOffsets[node.id] ?? .zero
        node.position = CGPoint(
            x: node.position.x + live.width,
            y: node.position.y + live.height
        )
        liveNodeOffsets.removeValue(forKey: node.id)
    }

    // MARK: - Port Connection

    private func handlePortTap(nodeID: UUID, portID: UUID, isInput: Bool) {
        guard let node = graph.node(id: nodeID) else { return }

        if let wire = pendingWire {
            // Complete connection
            // Must connect output->input
            let (fromNodeID, fromPortID, toNodeID, toPortID): (UUID, UUID, UUID, UUID)
            if wire.isFromInput && !isInput {
                // pending was from input, tapping output
                fromNodeID = nodeID; fromPortID = portID
                toNodeID = wire.fromNodeID; toPortID = wire.fromPortID
            } else if !wire.isFromInput && isInput {
                fromNodeID = wire.fromNodeID; fromPortID = wire.fromPortID
                toNodeID = nodeID; toPortID = portID
            } else {
                // same direction — cancel
                pendingWire = nil
                return
            }
            // Prevent self-loops
            if fromNodeID == toNodeID { pendingWire = nil; return }

            graph.addConnection(Connection(
                fromNodeID: fromNodeID, fromPortID: fromPortID,
                toNodeID: toNodeID, toPortID: toPortID
            ))
            pendingWire = nil
        } else {
            // Start dragging a wire
            let ports = isInput ? node.inputs : node.outputs
            guard let port = ports.first(where: { $0.id == portID }) else { return }
            let index = ports.firstIndex(where: { $0.id == portID })!

            let startPoint = isInput
                ? node.inputPortPosition(index: index, in: graph)
                : node.outputPortPosition(index: index, in: graph)

            pendingWire = PendingWire(
                startPoint: startPoint,
                endPoint: startPoint,
                portType: port.type,
                fromNodeID: nodeID,
                fromPortID: portID,
                isFromInput: isInput
            )
        }
    }

    private func syncViewport(size: CGSize) {
        viewport.size = size
        viewport.offset = offset
        viewport.scale = scale
    }

    private func translatedPendingWire(origin: CGPoint) -> PendingWire? {
        guard let pendingWire else { return nil }
        return PendingWire(
            startPoint: CGPoint(
                x: pendingWire.startPoint.x - origin.x,
                y: pendingWire.startPoint.y - origin.y
            ),
            endPoint: CGPoint(
                x: pendingWire.endPoint.x - origin.x,
                y: pendingWire.endPoint.y - origin.y
            ),
            portType: pendingWire.portType,
            fromNodeID: pendingWire.fromNodeID,
            fromPortID: pendingWire.fromPortID,
            isFromInput: pendingWire.isFromInput
        )
    }

    private func canvasContentRect(viewportSize: CGSize) -> CGRect {
        let viewportRect = CGRect(
            x: -offset.width / scale,
            y: -offset.height / scale,
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )

        var minX = viewportRect.minX
        var minY = viewportRect.minY
        var maxX = viewportRect.maxX
        var maxY = viewportRect.maxY

        for node in graph.nodes {
            let live = liveNodeOffsets[node.id] ?? .zero
            let frame = CGRect(
                x: node.position.x + live.width,
                y: node.position.y + live.height,
                width: Node.width,
                height: node.height
            )
            minX = min(minX, frame.minX)
            minY = min(minY, frame.minY)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }

        if let pendingWire {
            minX = min(minX, pendingWire.startPoint.x, pendingWire.endPoint.x)
            minY = min(minY, pendingWire.startPoint.y, pendingWire.endPoint.y)
            maxX = max(maxX, pendingWire.startPoint.x, pendingWire.endPoint.x)
            maxY = max(maxY, pendingWire.startPoint.y, pendingWire.endPoint.y)
        }

        return CGRect(
            x: minX - contentPadding,
            y: minY - contentPadding,
            width: (maxX - minX) + contentPadding * 2,
            height: (maxY - minY) + contentPadding * 2
        )
    }

    private func updateHoveredConnection(at mousePoint: CGPoint, contentRect: CGRect) {
        let hoveredConnection = graph.connections
            .compactMap { connection -> (UUID, CGFloat)? in
                guard let renderedWire = renderedWire(for: connection, contentRect: contentRect) else {
                    return nil
                }

                let distance = distanceFromPointToWire(mousePoint, wire: renderedWire)
                guard distance <= connectionHoverPadding else {
                    return nil
                }

                return (connection.id, distance)
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }

        graph.hoveredConnectionID = hoveredConnection?.0
    }

    private func renderedWire(for connection: Connection, contentRect: CGRect) -> (from: CGPoint, to: CGPoint)? {
        guard
            let fromNode = graph.node(id: connection.fromNodeID),
            let fromIndex = fromNode.outputs.firstIndex(where: { $0.id == connection.fromPortID }),
            let toNode = graph.node(id: connection.toNodeID),
            let toIndex = toNode.inputs.firstIndex(where: { $0.id == connection.toPortID })
        else {
            return nil
        }

        let fromBase = fromNode.outputPortPosition(index: fromIndex, in: graph)
        let fromLive = liveNodeOffsets[fromNode.id] ?? .zero
        let toBase = toNode.inputPortPosition(index: toIndex, in: graph)
        let toLive = liveNodeOffsets[toNode.id] ?? .zero

        let from = CGPoint(
            x: fromBase.x + fromLive.width - contentRect.origin.x,
            y: fromBase.y + fromLive.height - contentRect.origin.y
        )
        let to = CGPoint(
            x: toBase.x + toLive.width - contentRect.origin.x,
            y: toBase.y + toLive.height - contentRect.origin.y
        )

        return (
            applyCanvasTransform(to: from, contentRect: contentRect),
            applyCanvasTransform(to: to, contentRect: contentRect)
        )
    }

    private func applyCanvasTransform(to point: CGPoint, contentRect: CGRect) -> CGPoint {
        let center = CGPoint(x: contentRect.width / 2, y: contentRect.height / 2)

        return CGPoint(
            x: center.x + (point.x - center.x) * scale + offset.width + contentRect.minX * scale,
            y: center.y + (point.y - center.y) * scale + offset.height + contentRect.minY * scale
        )
    }

    private func distanceFromPointToWire(_ point: CGPoint, wire: (from: CGPoint, to: CGPoint)) -> CGFloat {
        let cpOffset = abs(wire.to.x - wire.from.x) * 0.5 + 30
        let control1 = CGPoint(x: wire.from.x + cpOffset, y: wire.from.y)
        let control2 = CGPoint(x: wire.to.x - cpOffset, y: wire.to.y)
        let sampleCount = 24

        var previous = wire.from
        var minimumDistance = CGFloat.greatestFiniteMagnitude

        for sampleIndex in 1...sampleCount {
            let t = CGFloat(sampleIndex) / CGFloat(sampleCount)
            let next = cubicBezierPoint(
                t: t,
                start: wire.from,
                control1: control1,
                control2: control2,
                end: wire.to
            )
            minimumDistance = min(minimumDistance, distanceFromPointToSegment(point, start: previous, end: next))
            previous = next
        }

        return minimumDistance
    }

    private func cubicBezierPoint(
        t: CGFloat,
        start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        end: CGPoint
    ) -> CGPoint {
        let oneMinusT = 1 - t
        let a = oneMinusT * oneMinusT * oneMinusT
        let b = 3 * oneMinusT * oneMinusT * t
        let c = 3 * oneMinusT * t * t
        let d = t * t * t

        return CGPoint(
            x: a * start.x + b * control1.x + c * control2.x + d * end.x,
            y: a * start.y + b * control1.y + c * control2.y + d * end.y
        )
    }

    private func distanceFromPointToSegment(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let segmentLengthSquared = dx * dx + dy * dy

        guard segmentLengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / segmentLengthSquared
        let clampedProjection = min(1, max(0, projection))
        let projectedPoint = CGPoint(
            x: start.x + clampedProjection * dx,
            y: start.y + clampedProjection * dy
        )

        return hypot(point.x - projectedPoint.x, point.y - projectedPoint.y)
    }
}

// MARK: - Grid Background

struct GridBackground: View {
    let offset: CGSize
    let scale: CGFloat
    let gridSpacing: CGFloat = 32

    var body: some View {
        Canvas { ctx, size in
            let adjustedSpacing = gridSpacing * scale
            let xOff = offset.width.truncatingRemainder(dividingBy: adjustedSpacing)
            let yOff = offset.height.truncatingRemainder(dividingBy: adjustedSpacing)

            var x = xOff
            while x < size.width {
                var y = yOff
                while y < size.height {
                    let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(0.12)))
                    y += adjustedSpacing
                }
                x += adjustedSpacing
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct CanvasHoverTracker: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onExit: onExit)
    }

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onExit = onExit
    }

    static func dismantleNSView(_ nsView: HoverTrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onMove: (CGPoint) -> Void
        var onExit: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onMove: @escaping (CGPoint) -> Void, onExit: @escaping () -> Void) {
            self.onMove = onMove
            self.onExit = onExit
        }

        func attach(to view: NSView) {
            self.view = view
            startMonitoringIfNeeded()
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            view = nil
        }

        private func startMonitoringIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self, let view = self.view, view.window != nil else {
                    return event
                }

                let frameInWindow = view.convert(view.bounds, to: nil)
                if frameInWindow.contains(event.locationInWindow) {
                    let pointInView = view.convert(event.locationInWindow, from: nil)
                    self.onMove(CGPoint(x: pointInView.x, y: view.bounds.height - pointInView.y))
                } else {
                    self.onExit()
                }

                return event
            }
        }
    }
}

private final class HoverTrackingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
