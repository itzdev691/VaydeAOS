import SwiftUI

/// Renders supplied measurements only; missing samples remain gaps in the trace.
struct TelemetryTraceView: View {
    var samples: [Double]
    var color: Color = Console.blue

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 3
            let bounds = CGRect(x: inset, y: inset, width: max(0, size.width - inset * 2), height: max(0, size.height - inset * 2))
            guard bounds.width > 0, bounds.height > 0 else { return }
            var grid = Path()
            for row in 0...3 {
                let y = bounds.minY + bounds.height * CGFloat(row) / 3
                grid.move(to: CGPoint(x: bounds.minX, y: y))
                grid.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            for column in 0...8 {
                let x = bounds.minX + bounds.width * CGFloat(column) / 8
                grid.move(to: CGPoint(x: x, y: bounds.minY))
                grid.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
            context.stroke(grid, with: .color(color.opacity(0.10)), lineWidth: 0.5)

            let finiteSamples = samples.filter(\.isFinite)
            guard let maximum = finiteSamples.max(), let minimum = finiteSamples.min() else {
                context.draw(Text("AWAITING SAMPLES").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(color.opacity(0.45)), at: CGPoint(x: bounds.midX, y: bounds.midY))
                return
            }
            let floor = min(0, minimum)
            let ceiling = max(maximum, floor + 1)
            let span = ceiling - floor
            var segments: [[CGPoint]] = []
            var segment: [CGPoint] = []
            for (index, sample) in samples.enumerated() {
                guard sample.isFinite else {
                    if !segment.isEmpty { segments.append(segment); segment = [] }
                    continue
                }
                let x = bounds.minX + bounds.width * CGFloat(index) / CGFloat(max(samples.count - 1, 1))
                let y = bounds.maxY - bounds.height * CGFloat((sample - floor) / span)
                segment.append(CGPoint(x: x, y: y))
            }
            if !segment.isEmpty { segments.append(segment) }
            for points in segments {
                guard let first = points.first, let last = points.last else { continue }
                var trace = Path()
                trace.move(to: first)
                points.dropFirst().forEach { trace.addLine(to: $0) }
                var area = trace
                area.addLine(to: CGPoint(x: last.x, y: bounds.maxY))
                area.addLine(to: CGPoint(x: first.x, y: bounds.maxY))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0.01)]), startPoint: CGPoint(x: 0, y: bounds.minY), endPoint: CGPoint(x: 0, y: bounds.maxY)))
                context.stroke(trace, with: .color(color.opacity(0.12)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                context.stroke(trace, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                context.fill(Path(ellipseIn: CGRect(x: last.x - 1.8, y: last.y - 1.8, width: 3.6, height: 3.6)), with: .color(color))
            }
        }
        .accessibilityLabel(samples.contains(where: \.isFinite) ? "Telemetry trace with \(samples.filter(\.isFinite).count) measurements" : "Awaiting telemetry samples")
    }
}
