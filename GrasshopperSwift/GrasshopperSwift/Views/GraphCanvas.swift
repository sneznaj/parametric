import AppKit
import SwiftUI

let kShowNodesBackgroundDotsKey = "showNodesBackgroundDots"
let kNodesBackgroundDotSizeKey = "nodesBackgroundDotSize"

struct GraphCanvas: View {
    @ObservedObject var graph: NodeGraph
    @ObservedObject var viewport: CanvasViewport
    @ObservedObject private var colorStore = PortColorStore.shared
    @AppStorage("showConnectorHoverHighlight") private var showConnectorHoverHighlight = true
    @AppStorage("enableWireClickColorPicker") private var enableWireClickColorPicker = true
    @AppStorage(kShowNodesBackgroundDotsKey) private var showNodesBackgroundDots = true
    @AppStorage(kNodesBackgroundDotSizeKey) private var nodesBackgroundDotSize = 2.0
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var pendingWire: PendingWire? = nil
    @State private var liveNodeOffsets: [UUID: CGSize] = [:]
    @State private var currentMousePoint: CGPoint = .zero
    @State private var wireColorPickerType: PortType? = nil
    @State private var wireColorPickerAnchor: CGPoint = .zero
    private let contentPadding: CGFloat = 240
    private let connectionHoverPadding: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let contentRect = canvasContentRect(viewportSize: geo.size)
            ZStack(alignment: .topLeading) {
                // Grid background. Solid fill covers the full viewport (including under any
                // safe-area insets); the dots are drawn in world space and pushed through the
                // exact same scale/offset transform as the node content below, so the grid
                // stays pixel-locked to the nodes at every pan/zoom level instead of drifting.
                Color(nsColor: .underPageBackgroundColor)
                    .ignoresSafeArea()

                GridBackground(
                    worldRect: visibleWorldRect(viewportSize: geo.size),
                    offset: offset,
                    scale: scale,
                    showDots: showNodesBackgroundDots,
                    dotSize: nodesBackgroundDotSize
                )
                    .gesture(panGesture.simultaneously(with: magnificationGesture))

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
                // Anchor at topLeading: the pan/zoom math below (and GridBackground's own
                // drawing) both assume scaling pivots around the container's top-left corner.
                // The default .center anchor made nodes scale around the content bounding
                // box's center instead, which is why zoom drifted toward a corner and the
                // grid (drawn independently, always top-left-anchored) fell out of sync with
                // the nodes.
                .scaleEffect(scale, anchor: .topLeading)
                .offset(
                    x: offset.width + contentRect.minX * scale,
                    y: offset.height + contentRect.minY * scale
                )

                // Invisible anchor for the wire-click color picker popover — repositioned to the
                // click point so the popover appears next to the wire the user clicked.
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(wireColorPickerAnchor)
                    .popover(item: $wireColorPickerType, arrowEdge: .top) { type in
                        WireColorPickerPopover(type: type, colorStore: colorStore)
                    }
            }
            .clipped()
            .background(
                CanvasHoverTracker(
                    onMove: { mousePoint in
                        currentMousePoint = mousePoint
                        updateHoveredConnection(at: mousePoint, contentRect: contentRect)
                    },
                    onExit: {
                        graph.hoveredConnectionID = nil
                    },
                    onScroll: { deltaX, deltaY, isZoomModifierDown, point in
                        if isZoomModifierDown {
                            handleZoomScroll(deltaY: deltaY, at: point)
                        } else {
                            handlePanScroll(deltaX: deltaX, deltaY: deltaY)
                        }
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
        }
    }

    // MARK: - Pan

    @State private var panStart: CGSize = .zero
    @State private var panOffset: CGSize = .zero

    private var panGesture: some Gesture {
        // A non-zero minimumDistance matters beyond feel: with 0, this gesture (which spans
        // the whole canvas, behind every node) claims the mouse-down instantly on every click,
        // winning the gesture race against port taps and other foreground controls before they
        // ever get a chance to recognize — which is what silently broke wire connecting. Keep
        // this small enough to still feel responsive; a click vs. a pan is distinguished below,
        // from the total distance traveled.
        DragGesture(minimumDistance: 2)
            .onChanged { val in
                FileHandle.standardError.write("DEBUG: panGesture changed translation=\(val.translation)\n".data(using: .utf8)!)
                offset = CGSize(
                    width: panOffset.width + val.translation.width,
                    height: panOffset.height + val.translation.height
                )
            }
            .onEnded { val in
                panOffset = offset
                let distance = hypot(val.translation.width, val.translation.height)
                if distance < 3 {
                    if enableWireClickColorPicker,
                       let type = clickedWireType(at: val.startLocation) {
                        pendingWire = nil
                        wireColorPickerAnchor = val.startLocation
                        wireColorPickerType = type
                        return
                    }
                    // Treat as a click on empty canvas: deselect nodes and cancel any pending wire.
                    for node in graph.nodes { node.isSelected = false }
                    pendingWire = nil
                }
            }
    }

    // MARK: - Zoom

    @State private var lastScale: CGFloat = 1.0

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = max(0.1, min(5.0, lastScale * value.magnification))
                let cursor = currentMousePoint

                // Zoom toward cursor: keep the content point under the cursor fixed
                let ratio = newScale / scale
                offset = CGSize(
                    width: cursor.x - (cursor.x - offset.width) * ratio,
                    height: cursor.y - (cursor.y - offset.height) * ratio
                )
                scale = newScale
            }
            .onEnded { _ in
                lastScale = scale
                panOffset = offset
            }
    }

    /// Two-finger trackpad swipe (no modifier): pans the canvas, matching other macOS apps
    /// (Figma, Preview, Maps) where plain two-finger scroll pans and pinch/Ctrl-scroll zooms.
    private func handlePanScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard deltaX != 0 || deltaY != 0 else { return }
        offset = CGSize(width: offset.width + deltaX, height: offset.height + deltaY)
        panOffset = offset
    }

    /// Ctrl+scroll wheel zoom (the system-wide macOS zoom convention), keeping the point
    /// under the cursor fixed.
    private func handleZoomScroll(deltaY: CGFloat, at point: CGPoint) {
        guard deltaY != 0 else { return }

        let zoomFactor = exp(-deltaY * 0.01)
        let newScale = max(0.1, min(5.0, scale * zoomFactor))
        guard newScale != scale else { return }

        let ratio = newScale / scale
        offset = CGSize(
            width: point.x - (point.x - offset.width) * ratio,
            height: point.y - (point.y - offset.height) * ratio
        )
        scale = newScale
        lastScale = newScale
        panOffset = offset
    }

    // MARK: - Node Drag

    private func handleNodeDrag(node: Node, delta: CGSize) {
        // NSPanGestureRecognizer.translation(in:) already reports in the view's
        // coordinate system, which is affected by the parent's scaleEffect.
        // No need to divide by scale — the delta is already in the correct space.
        liveNodeOffsets[node.id] = delta
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
        FileHandle.standardError.write("DEBUG: handlePortTap nodeID=\(nodeID) isInput=\(isInput) pendingWire=\(pendingWire != nil)\n".data(using: .utf8)!)
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

    /// The portion of world space currently visible in the viewport.
    private func visibleWorldRect(viewportSize: CGSize) -> CGRect {
        CGRect(
            x: -offset.width / scale,
            y: -offset.height / scale,
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )
    }

    private func canvasContentRect(viewportSize: CGSize) -> CGRect {
        let viewportRect = visibleWorldRect(viewportSize: viewportSize)

        var minX = viewportRect.minX
        var minY = viewportRect.minY
        var maxX = viewportRect.maxX
        var maxY = viewportRect.maxY

        for node in graph.nodes {
            let frame = CGRect(
                x: node.position.x,
                y: node.position.y,
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
        graph.hoveredConnectionID = connection(at: mousePoint, contentRect: contentRect)
    }

    /// Same hit-test used for hover highlighting: finds the nearest wire within
    /// `connectionHoverPadding` of `point`, if any.
    private func connection(at point: CGPoint, contentRect: CGRect) -> UUID? {
        graph.connections
            .compactMap { connection -> (UUID, CGFloat)? in
                guard let renderedWire = renderedWire(for: connection, contentRect: contentRect) else {
                    return nil
                }

                let distance = distanceFromPointToWire(point, wire: renderedWire)
                guard distance <= connectionHoverPadding else {
                    return nil
                }

                return (connection.id, distance)
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    /// The data type of the wire under `point` (in view-local coordinates), if any —
    /// used to open the click-to-recolor popover on the correct `PortType`.
    private func clickedWireType(at point: CGPoint) -> PortType? {
        let contentRect = canvasContentRect(viewportSize: viewport.size)
        guard
            let connectionID = connection(at: point, contentRect: contentRect),
            let conn = graph.connections.first(where: { $0.id == connectionID }),
            let fromNode = graph.node(id: conn.fromNodeID),
            let fromPort = fromNode.outputs.first(where: { $0.id == conn.fromPortID })
        else { return nil }
        return fromPort.type
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

    /// Mirrors the real render transform applied to wires/nodes: `.scaleEffect(scale,
    /// anchor: .topLeading)` followed by the offset — i.e. scaling pivots around the
    /// content's top-left corner, not its center. `point` must already be relative to
    /// `contentRect.origin` (as `renderedWire` provides), matching node/wire placement.
    private func applyCanvasTransform(to point: CGPoint, contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: point.x * scale + offset.width + contentRect.minX * scale,
            y: point.y * scale + offset.height + contentRect.minY * scale
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

// MARK: - Wire Color Picker Popover

/// Shown when clicking a wire (if enabled in Settings). Recoloring here updates
/// `PortColorStore`, so every point and wire of this data type recolors at once.
private struct WireColorPickerPopover: View {
    let type: PortType
    @ObservedObject var colorStore: PortColorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(type.displayName) Color")
                .font(.headline)
            ColorPicker("Wire color", selection: colorStore.binding(for: type), supportsOpacity: false)
                .labelsHidden()
            Button("Reset to Default") {
                colorStore.resetColor(for: type)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 180)
    }
}

// MARK: - Grid Background

struct GridBackground: View {
    /// The visible slice of world space this grid should cover, in world (pre-scale) units.
    let worldRect: CGRect
    let offset: CGSize
    let scale: CGFloat
    var showDots: Bool = true
    /// On-screen dot diameter in points, independent of zoom level.
    var dotSize: Double = 2
    private let gridSpacing: CGFloat = 32

    var body: some View {
        Canvas { ctx, size in
            guard showDots else { return }
            // Keep dots a constant size on screen: draw them larger than `dotSize` here so
            // that, after the scaleEffect below shrinks/grows everything uniformly, they
            // render back to `dotSize` pt regardless of zoom level.
            let screenDotSize = max(0.5, dotSize / scale)

            let startX = (worldRect.minX / gridSpacing).rounded(.down) * gridSpacing
            let startY = (worldRect.minY / gridSpacing).rounded(.down) * gridSpacing

            var worldX = startX
            while worldX <= worldRect.maxX {
                var worldY = startY
                while worldY <= worldRect.maxY {
                    let localX = worldX - worldRect.minX
                    let localY = worldY - worldRect.minY
                    let rect = CGRect(x: localX - screenDotSize / 2, y: localY - screenDotSize / 2, width: screenDotSize, height: screenDotSize)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(0.12)))
                    worldY += gridSpacing
                }
                worldX += gridSpacing
            }
        }
        .frame(width: max(0, worldRect.width), height: max(0, worldRect.height))
        // Identical transform pipeline (anchor + offset formula) as the node content ZStack
        // below, so dots stay pixel-locked to nodes at every pan/zoom level.
        .scaleEffect(scale, anchor: .topLeading)
        .offset(
            x: offset.width + worldRect.minX * scale,
            y: offset.height + worldRect.minY * scale
        )
    }
}

private struct CanvasHoverTracker: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void
    let onScroll: (CGFloat, CGFloat, Bool, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onExit: onExit, onScroll: onScroll)
    }

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onExit = onExit
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: HoverTrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onMove: (CGPoint) -> Void
        var onExit: () -> Void
        var onScroll: (CGFloat, CGFloat, Bool, CGPoint) -> Void
        private weak var view: NSView?
        private var moveMonitor: Any?
        private var scrollMonitor: Any?

        init(onMove: @escaping (CGPoint) -> Void, onExit: @escaping () -> Void, onScroll: @escaping (CGFloat, CGFloat, Bool, CGPoint) -> Void) {
            self.onMove = onMove
            self.onExit = onExit
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            self.view = view
            startMonitoringIfNeeded()
        }

        func detach() {
            if let moveMonitor {
                NSEvent.removeMonitor(moveMonitor)
                self.moveMonitor = nil
            }
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
            view = nil
        }

        private func startMonitoringIfNeeded() {
            guard moveMonitor == nil else { return }

            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
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

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, view.window != nil else {
                    return event
                }

                let frameInWindow = view.convert(view.bounds, to: nil)
                guard frameInWindow.contains(event.locationInWindow) else {
                    return event
                }

                let pointInView = view.convert(event.locationInWindow, from: nil)
                self.onScroll(
                    event.scrollingDeltaX,
                    event.scrollingDeltaY,
                    event.modifierFlags.contains(.control),
                    CGPoint(x: pointInView.x, y: view.bounds.height - pointInView.y)
                )
                return nil
            }
        }
    }
}

private final class HoverTrackingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit windows don't generate mouseMoved events by default, and this view
        // has no NSTrackingArea of its own (it's hit-test-transparent) to force them
        // on locally — so the window must opt in directly, or the local event monitor
        // in CanvasHoverTracker never sees anything over empty canvas.
        window?.acceptsMouseMovedEvents = true
    }
}
