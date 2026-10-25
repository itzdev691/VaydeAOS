import SwiftUI

/// Procedural artwork. It has no connection to host, model, or network measurements.
struct AmbientGraphic: View {
    enum Style { case field, core }
    let style: Style
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let moving = isActive && scenePhase == .active && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moving)) { timeline in
            Canvas { context, size in
                let phase = moving ? timeline.date.timeIntervalSinceReferenceDate * 0.24 : 0
                switch style {
                case .field: AmbientDrawing.field(in: &context, size: size, phase: phase)
                case .core: AmbientDrawing.core(in: &context, size: size, phase: phase)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style == .field ? "Decorative flowing signal field" : "Decorative orbital core")
        .help("Ambient procedural artwork. Animation is decorative and does not represent telemetry.")
    }
}

private enum AmbientDrawing {
    static func field(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
        glow(in: &context, center: center, radius: size.width * 0.55)

        // Layered ribbons form a shallow wave surface, without chart axes or sample labels.
        for row in 0..<15 {
            let depth = Double(row) / 14
            var ribbon = Path()
            for column in 0...96 {
                let u = Double(column) / 96
                let p = fieldPoint(u: u, depth: depth, size: size, phase: phase)
                if column == 0 { ribbon.move(to: p) } else { ribbon.addLine(to: p) }
            }
            let color = row == 9 ? Console.blue : Console.blue.opacity(0.13 + depth * 0.46)
            context.stroke(ribbon, with: .color(color), lineWidth: row == 9 ? 1.1 : 0.6)
        }
        for column in 0...20 {
            var filament = Path()
            for row in 0...28 {
                let p = fieldPoint(u: Double(column) / 20, depth: Double(row) / 28, size: size, phase: phase)
                if row == 0 { filament.move(to: p) } else { filament.addLine(to: p) }
            }
            context.stroke(filament, with: .color(Console.blue.opacity(0.12)), lineWidth: 0.5)
        }
        for index in 0..<5 {
            let u = (phase * 0.08 + Double(index) * 0.197).truncatingRemainder(dividingBy: 1)
            let p = fieldPoint(u: u, depth: Double(index + 2) / 7, size: size, phase: phase)
            let color = index == 3 ? Console.red : Console.blue
            context.fill(circle(p, radius: 5), with: .color(color.opacity(0.12)))
            context.fill(circle(p, radius: 1.7), with: .color(color))
        }
        brackets(in: &context, size: size)
    }

    private static func fieldPoint(u: Double, depth: Double, size: CGSize, phase: Double) -> CGPoint {
        let envelope = pow(max(0, sin(u * .pi)), 1.3)
        let wave = sin(u * 10 - phase + depth * 2.6) * 0.7
            + cos(u * 17 + phase * 0.6 - depth * 1.5) * 0.3
        return CGPoint(x: size.width * (0.06 + u * 0.88),
                       y: size.height * (0.22 + depth * 0.57 + wave * envelope * 0.18))
    }

    static func core(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width * 0.36, size.height * 0.40)
        glow(in: &context, center: center, radius: radius * 1.8)

        for index in 0..<3 {
            let rotation = Double(index) * .pi / 3 + phase * 0.11
            var orbit = Path()
            for step in 0...120 {
                let p = orbitPoint(center, radius: radius, angle: Double(step) / 120 * .pi * 2, rotation: rotation)
                if step == 0 { orbit.move(to: p) } else { orbit.addLine(to: p) }
            }
            context.stroke(orbit, with: .color(Console.blue.opacity(0.5)), lineWidth: 0.7)
            let node = orbitPoint(center, radius: radius, angle: phase * 0.75 + Double(index) * 2.1, rotation: rotation)
            let color = index == 1 ? Console.red : Console.blue
            context.fill(circle(node, radius: 5), with: .color(color.opacity(0.14)))
            context.fill(circle(node, radius: 2), with: .color(color))
        }
        for ring in 0..<2 {
            var arc = Path()
            let start = phase * (ring == 0 ? 0.2 : -0.15) + Double(ring) * .pi
            arc.addArc(center: center, radius: radius * (ring == 0 ? 1.15 : 1.24),
                       startAngle: .radians(start), endAngle: .radians(start + .pi * 1.25), clockwise: false)
            context.stroke(arc, with: .color(Console.blue.opacity(0.24)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 5]))
        }
        var hub = Path()
        for index in 0..<6 {
            let angle = Double(index) / 6 * .pi * 2 - .pi / 2
            let p = CGPoint(x: center.x + cos(angle) * radius * 0.24, y: center.y + sin(angle) * radius * 0.24)
            if index == 0 { hub.move(to: p) } else { hub.addLine(to: p) }
        }
        hub.closeSubpath()
        context.fill(hub, with: .color(Console.background.opacity(0.9)))
        context.stroke(hub, with: .color(Console.blue.opacity(0.9)), lineWidth: 1)
        context.fill(circle(center, radius: 2.5), with: .color(Console.blue))
        brackets(in: &context, size: size)
    }

    private static func orbitPoint(_ center: CGPoint, radius: Double, angle: Double, rotation: Double) -> CGPoint {
        let x = cos(angle) * radius
        let y = sin(angle) * radius * 0.36
        return CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation),
                       y: center.y + x * sin(rotation) + y * cos(rotation))
    }

    private static func glow(in context: inout GraphicsContext, center: CGPoint, radius: Double) {
        context.fill(circle(center, radius: radius), with: .radialGradient(
            Gradient(colors: [Console.blue.opacity(0.075), .clear]), center: center,
            startRadius: 0, endRadius: radius))
    }

    private static func circle(_ center: CGPoint, radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func brackets(in context: inout GraphicsContext, size: CGSize) {
        var frame = Path()
        for x in [CGFloat(12), size.width - 12] {
            for y in [CGFloat(12), size.height - 12] {
                let dx: CGFloat = x < size.width / 2 ? 7 : -7
                let dy: CGFloat = y < size.height / 2 ? 7 : -7
                frame.move(to: CGPoint(x: x + dx, y: y))
                frame.addLine(to: CGPoint(x: x, y: y))
                frame.addLine(to: CGPoint(x: x, y: y + dy))
            }
        }
        context.stroke(frame, with: .color(Console.blue.opacity(0.3)), lineWidth: 0.7)
    }
}
