import SwiftUI
import AppKit

struct ConnectionsView: View {
    @ObservedObject var graph: NodeGraph
    @ObservedObject private var colorStore = PortColorStore.shared
    var liveNodeOffsets: [UUID: CGSize] = [:]
    var canvasOrigin: CGPoint = .zero
    var hoveredConnectionID: UUID? = nil
    var showsHoverHighlight: Bool = false
    /// When user is dragging a new connection, draw a preview wire
    var pendingWire: PendingWire?

    var body: some View {
        Canvas { ctx, size in
            // Draw committed connections
            for conn in graph.connections {
                guard
                    let fromNode = graph.node(id: conn.fromNodeID),
                    let fromIdx  = fromNode.outputs.firstIndex(where: { $0.id == conn.fromPortID }),
                    let toNode   = graph.node(id: conn.toNodeID),
                    let toIdx    = toNode.inputs.firstIndex(where: { $0.id == conn.toPortID })
                else { continue }

                let fromPt   = outputPosition(for: fromNode, index: fromIdx)
                let toPt     = inputPosition(for: toNode, index: toIdx)
                let wireColor = colorStore.color(for: fromNode.outputs[fromIdx].type)
                let isHovered = (showsHoverHighlight && conn.id == hoveredConnectionID)
                    || graph.pressHighlightedConnectionIDs.contains(conn.id)

                drawWire(
                    ctx: ctx,
                    from: fromPt,
                    to: toPt,
                    color: wireColor,
                    opacity: isHovered ? 1.0 : 0.9,
                    lineWidth: isHovered ? 5.5 : 2.5
                )
            }

            // Draw pending wire
            if let wire = pendingWire {
                drawWire(
                    ctx: ctx,
                    from: wire.startPoint,
                    to: wire.endPoint,
                    color: colorStore.color(for: wire.portType),
                    opacity: 0.7,
                    lineWidth: 2.5,
                    dashed: true
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func inputPosition(for node: Node, index: Int) -> CGPoint {
        let base = node.inputPortPosition(index: index, in: graph)
        let live = liveNodeOffsets[node.id] ?? .zero
        return CGPoint(
            x: base.x + live.width - canvasOrigin.x,
            y: base.y + live.height - canvasOrigin.y
        )
    }

    private func outputPosition(for node: Node, index: Int) -> CGPoint {
        let base = node.outputPortPosition(index: index, in: graph)
        let live = liveNodeOffsets[node.id] ?? .zero
        return CGPoint(
            x: base.x + live.width - canvasOrigin.x,
            y: base.y + live.height - canvasOrigin.y
        )
    }

    private func drawWire(
        ctx: GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        color: Color,
        opacity: Double,
        lineWidth: CGFloat,
        dashed: Bool = false
    ) {
        let cpOffset = abs(to.x - from.x) * 0.5 + 30
        var path = Path()
        path.move(to: from)
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + cpOffset, y: from.y),
            control2: CGPoint(x: to.x - cpOffset, y: to.y)
        )

        var style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        if dashed { style.dash = [6, 4] }

        var c = ctx
        c.opacity = opacity
        c.stroke(path, with: .color(color), style: style)
    }
}

struct PendingWire {
    var startPoint: CGPoint
    var endPoint: CGPoint
    var portType: PortType
    var fromNodeID: UUID
    var fromPortID: UUID
    var isFromInput: Bool
}
