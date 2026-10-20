import SwiftUI

/// A conceptual map of the workspace, not a geolocation or traffic monitor.
struct NetworkGlobeView: View {
    var isActive: Bool
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !isActive)) { timeline in
            Canvas { context, size in
                let phase = reduceMotion || !isActive ? 0 : timeline.date.timeIntervalSinceReferenceDate
                GlobeDrawing.draw(in: &context, size: size, phase: phase)
            }
        }
        .overlay(alignment: .bottom) {
            Text("ILLUSTRATIVE TOPOLOGY  /  ROUTES NOT GEOLOCATED")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Console.muted)
                .padding(.bottom, 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustrative network globe. Routes do not represent measured geographic locations.")
    }
}

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

private enum GlobeDrawing {
    static let blue = Console.blue
    static let dim = Console.muted

    struct ProjectedPoint {
        let position: CGPoint
        let depth: Double
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let center = CGPoint(x: size.width * 0.50, y: size.height * 0.47)
        let radius = min(size.width * 0.28, size.height * 0.395)
        guard radius > 10 else { return }
        let rotation = -18.0 + sin(phase / 40) * 14
        let sphere = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        // Local geometry stays static when the system requests reduced motion.
        let halo = Path(ellipseIn: sphere.insetBy(dx: -radius * 0.22, dy: -radius * 0.22))
        context.fill(halo, with: .radialGradient(Gradient(colors: [blue.opacity(0.07), blue.opacity(0)]), center: center, startRadius: radius * 0.5, endRadius: radius * 1.22))
        context.fill(Path(ellipseIn: sphere), with: .radialGradient(Gradient(colors: [Console.raised.opacity(0.75), Console.background]), center: CGPoint(x: center.x - radius / 3, y: center.y - radius / 3), startRadius: 0, endRadius: radius * 1.5))

        for latitude in stride(from: -75.0, through: 75.0, by: 15) {
            let points = stride(from: -180.0, through: 180.0, by: 3).map { project(latitude: latitude, longitude: $0, rotation: rotation, center: center, radius: radius) }
            strokeVisible(points, in: &context, color: blue.opacity(latitude == 0 ? 0.26 : 0.12))
        }
        for longitude in stride(from: -180.0, to: 180.0, by: 15) {
            let points = stride(from: -90.0, through: 90.0, by: 3).map { project(latitude: $0, longitude: longitude, rotation: rotation, center: center, radius: radius) }
            strokeVisible(points, in: &context, color: blue.opacity(0.13))
        }

        // Coarse, hand-authored land silhouettes create a legible point-cloud world.
        for coordinate in landPoints {
            let point = project(latitude: coordinate.y, longitude: coordinate.x, rotation: rotation, center: center, radius: radius)
            guard point.depth > 0.04 else { continue }
            let dot = max(0.7, radius * 0.0085)
            let rect = CGRect(x: point.position.x - dot / 2, y: point.position.y - dot / 2, width: dot, height: dot)
            context.fill(Path(rect), with: .color(blue.opacity(0.27 + point.depth * 0.48)))
        }

        context.stroke(Path(ellipseIn: sphere), with: .color(blue.opacity(0.40)), lineWidth: 0.7)
        drawOrbit(in: &context, center: center, radius: radius, phase: phase)
        drawRegistration(in: &context, size: size, center: center, radius: radius)

        let endpoints: [(String, Double, Double, CGFloat, CGFloat)] = [
            ("VAULT", 43, -73, -1, -0.62),
            ("AGENT", 51, 18, 1, -0.70),
            ("MEDIA", -12, -49, -1, 0.59),
            ("LOCAL", -25, 25, 1, 0.62),
        ]
        let points = endpoints.map { project(latitude: $0.1, longitude: $0.2, rotation: rotation, center: center, radius: radius).position }
        for index in 1..<points.count {
            let start = points[0]
            let end = points[index]
            let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - radius * 0.23)
            var arc = Path()
            arc.move(to: start)
            arc.addQuadCurve(to: end, control: control)
            context.stroke(arc, with: .color(Console.red.opacity(0.65)), style: StrokeStyle(lineWidth: 0.85, dash: [3, 3]))
            let travel = (phase / 5 + Double(index) * 0.23).truncatingRemainder(dividingBy: 1)
            let t = CGFloat(travel)
            let particle = CGPoint(x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * end.x, y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * end.y)
            context.fill(Path(ellipseIn: CGRect(x: particle.x - 1.5, y: particle.y - 1.5, width: 3, height: 3)), with: .color(Console.red))
        }
        for (index, endpoint) in endpoints.enumerated() {
            let point = points[index]
            let labelX = center.x + endpoint.3 * min(radius * 1.47, size.width * 0.405)
            let labelY = center.y + endpoint.4 * radius
            let elbowX = labelX - endpoint.3 * 12
            var leader = Path()
            leader.move(to: point)
            leader.addLine(to: CGPoint(x: elbowX, y: labelY))
            leader.addLine(to: CGPoint(x: labelX, y: labelY))
            context.stroke(leader, with: .color(blue.opacity(0.25)), lineWidth: 0.6)
            context.stroke(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(blue.opacity(0.6)), lineWidth: 0.7)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(blue))
            context.draw(Text(endpoint.0).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(blue.opacity(0.8)), at: CGPoint(x: labelX, y: labelY - 8), anchor: endpoint.3 < 0 ? .trailing : .leading)
        }
    }

    static func project(latitude: Double, longitude: Double, rotation: Double, center: CGPoint, radius: CGFloat) -> ProjectedPoint {
        let lat = latitude * .pi / 180
        let lon = (longitude - rotation) * .pi / 180
        let tilt = 0.10
        let x = cos(lat) * sin(lon)
        let y = sin(lat)
        let z = cos(lat) * cos(lon)
        return ProjectedPoint(position: CGPoint(x: center.x + radius * x, y: center.y - radius * (y * cos(tilt) - z * sin(tilt))), depth: y * sin(tilt) + z * cos(tilt))
    }

    static func strokeVisible(_ points: [ProjectedPoint], in context: inout GraphicsContext, color: Color) {
        var path = Path()
        var hasStart = false
        for point in points {
            guard point.depth >= 0 else { hasStart = false; continue }
            if hasStart { path.addLine(to: point.position) } else { path.move(to: point.position); hasStart = true }
        }
        context.stroke(path, with: .color(color), lineWidth: 0.6)
    }

    static func drawOrbit(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, phase: Double) {
        var orbit = Path()
        let angle = -0.32
        for step in 0...180 {
            let t = Double(step) / 180 * .pi * 2
            let x = cos(t) * radius * 1.35
            let y = sin(t) * radius * 0.43
            let point = CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
            if step == 0 { orbit.move(to: point) } else { orbit.addLine(to: point) }
        }
        context.stroke(orbit, with: .color(blue.opacity(0.22)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
    }

    static func drawRegistration(in context: inout GraphicsContext, size: CGSize, center: CGPoint, radius: CGFloat) {
        var ticks = Path()
        for step in 0..<72 {
            let angle = Double(step) / 72 * .pi * 2
            let inner = radius * (step % 6 == 0 ? 1.10 : 1.12)
            let outer = radius * 1.15
            ticks.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            ticks.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        context.stroke(ticks, with: .color(dim.opacity(0.55)), lineWidth: 0.6)
        for direction in [-1.0, 1.0] {
            let x = center.x + direction * radius * 1.17
            var line = Path()
            line.move(to: CGPoint(x: x, y: center.y))
            line.addLine(to: CGPoint(x: x + direction * radius * 0.2, y: center.y))
            context.stroke(line, with: .color(blue.opacity(0.4)), lineWidth: 0.7)
        }
    }

    static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = index
        }
        return inside
    }

    static let landPoints: [CGPoint] = {
        var points: [CGPoint] = []
        for latitude in stride(from: -55.0, through: 80.0, by: 3) {
            let longitudeStep = 3.0 / max(0.25, cos(latitude * .pi / 180))
            for longitude in stride(from: -180.0, to: 180.0, by: longitudeStep) {
                let coordinate = CGPoint(x: longitude, y: latitude)
                if land.contains(where: { contains(coordinate, polygon: $0) }) { points.append(coordinate) }
            }
        }
        return points
    }()

    static let land: [[CGPoint]] = [
        [(-168, 68), (-143, 71), (-127, 58), (-108, 72), (-79, 80), (-55, 54), (-62, 45), (-81, 25), (-89, 18), (-99, 21), (-117, 32), (-124, 48), (-146, 60)],
        [(-81, 12), (-66, 10), (-51, 2), (-35, -7), (-43, -24), (-54, -37), (-67, -55), (-76, -47), (-72, -20)],
        [(-17, 35), (2, 37), (11, 32), (31, 31), (43, 12), (51, 11), (41, -4), (34, -19), (20, -35), (12, -24), (10, -4), (-5, 5), (-17, 16)],
        [(-10, 36), (-9, 44), (-1, 49), (7, 55), (4, 62), (18, 71), (31, 70), (44, 60), (60, 55), (49, 42), (29, 41), (24, 35), (16, 41), (4, 43)],
        [(31, 70), (67, 77), (111, 73), (143, 60), (175, 65), (162, 51), (140, 46), (127, 34), (121, 20), (106, 6), (98, 20), (81, 7), (69, 24), (51, 26), (36, 40)],
        [(-53, 59), (-43, 60), (-20, 75), (-35, 83), (-59, 80)],
        [(112, -22), (129, -12), (145, -15), (154, -28), (145, -39), (130, -32), (114, -35)],
        [(-9, 50), (-3, 51), (0, 58), (-5, 59)],
        [(46, -13), (50, -16), (46, -26), (43, -24)],
    ].map { polygon in polygon.map { CGPoint(x: $0.0, y: $0.1) } }
}
