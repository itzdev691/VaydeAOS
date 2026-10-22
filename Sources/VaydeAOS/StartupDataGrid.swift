import SwiftUI

/// A perspective floor with sparse decorative traffic moving toward the foreground.
struct StartupDataGrid: View {
    let reduceMotion: Bool
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let horizon = size.height * 0.62
                let depth = size.height - horizon
                func point(_ lane: CGFloat, _ distance: CGFloat) -> CGPoint {
                    let perspective = 0.08 + distance * distance * 0.92
                    return CGPoint(x: size.width / 2 + lane * size.width * perspective,
                                   y: horizon + depth * distance * distance)
                }
                var grid = Path()
                for lane in -10...10 {
                    grid.move(to: point(CGFloat(lane) / 10, 0))
                    grid.addLine(to: point(CGFloat(lane) / 10, 1))
                }
                for row in 0...12 {
                    let distance = CGFloat(row) / 12
                    let y = horizon + depth * distance * distance
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(Console.blue.opacity(0.16)), lineWidth: 0.7)
                let elapsed = reduceMotion ? 0 : max(0, timeline.date.timeIntervalSince(startedAt))
                for packet in 0..<5 {
                    let lane = CGFloat(packet * 4 - 8) / 10
                    let progress = (CGFloat(elapsed) * 0.12 + CGFloat(packet) * 0.21)
                        .truncatingRemainder(dividingBy: 1)
                    var pulse = Path()
                    pulse.move(to: point(lane, max(0, progress - 0.07)))
                    pulse.addLine(to: point(lane, progress))
                    context.stroke(pulse, with: .color(Console.blue.opacity(0.12)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    context.stroke(pulse, with: .color(Console.blue.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
