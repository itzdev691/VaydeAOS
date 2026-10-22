import Foundation
import SwiftUI
import VaydeAOSCore

/// Request performance observed by this app; no background probes or synthetic samples.
struct CircularActivityView: View {
    @ObservedObject var session: ChatSession
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previous: [RequestPerformance] = []
    @State private var current: [RequestPerformance] = []
    @State private var sampleTime = Date.timeIntervalSinceReferenceDate

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let progress = reduceMotion ? 1 : min(1, max(0, (time - sampleTime) / 0.8))
                PerformanceDrawing.draw(in: &context, size: size, previous: previous, current: current,
                    blend: progress * progress * (3 - 2 * progress),
                    phase: reduceMotion || !isActive ? 0 : time)
            }
        }
        .clipped()
        .overlay(alignment: .leading) { readout.frame(width: 175, alignment: .leading).padding(.leading, 22) }
        .overlay(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: 10) {
                legend("LATENCY", color: Console.blue)
                legend("OUTPUT RATE", color: Console.green)
                legend("FAILED", color: Console.red)
                legend("CANCELLED", color: Console.amber)
            }.padding(.trailing, 22).allowsHitTesting(false)
        }
        .onAppear { current = session.performanceHistory; previous = current }
        .onChange(of: session.performanceHistory) { history in
            previous = current
            current = history
            sampleTime = Date.timeIntervalSinceReferenceDate
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vayde Pulse model performance. \(session.performanceHistory.count) requests observed this session. Blue: end-to-end request time. Green: reported completion tokens per wall second. Red: failed. Amber: cancelled. Oldest at top, clockwise. \(session.isSending ? "Request in progress." : "")")
        .help("Last 60 requests for the configured endpoint and model. Latency includes network, queueing, and model work. Output rate is API-reported completion tokens divided by total request time, including non-visible tokens; it is not generation-only speed. Each metric uses its own logarithmic scale. Missing usage leaves a gap. Bounce is decorative.")
    }

    @ViewBuilder private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let start = session.performanceRequestStartedAt {
                Text("REQUEST ELAPSED").font(Console.mono(8)).tracking(1).foregroundStyle(Console.muted)
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(String(format: "%.1f s", max(0, ProcessInfo.processInfo.systemUptime - start)))
                        .font(Console.mono(18, weight: .light)).monospacedDigit().foregroundStyle(Console.blue)
                }
            } else if let last = session.performanceHistory.last {
                Text("LAST REQUEST / \(last.outcome.rawValue.uppercased())")
                    .font(Console.mono(8)).foregroundStyle(PerformanceDrawing.color(last.outcome))
                Text(String(format: "%.2f s", last.elapsed)).font(Console.mono(18, weight: .light))
                    .monospacedDigit().foregroundStyle(Console.blue)
                if let rate = last.outputTokensPerWallSecond {
                    Text(String(format: "%.1f TOKENS / WALL SEC", rate))
                        .font(Console.mono(9)).foregroundStyle(Console.green).monospacedDigit()
                } else {
                    Text("OUTPUT RATE UNAVAILABLE").font(Console.mono(8)).foregroundStyle(Console.muted)
                }
                Text("IN \(last.inputTokens.map(String.init) ?? "—") / OUT \(last.outputTokens.map(String.init) ?? "—") TOKENS")
                    .font(Console.mono(8)).foregroundStyle(Console.muted)
            } else {
                Text("AWAITING REQUEST").font(Console.mono(12, weight: .medium)).foregroundStyle(Console.blue)
                Text("Metrics appear as model requests finish.")
                    .font(Console.mono(9)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Console.mono(7)).foregroundStyle(color)
            Rectangle().fill(color).frame(width: 12, height: 1)
        }
    }
}

private enum PerformanceDrawing {
    static func color(_ outcome: RequestPerformance.Outcome) -> Color {
        switch outcome {
        case .success: return Console.blue
        case .failed: return Console.red
        case .cancelled: return Console.amber
        }
    }

    static func draw(in context: inout GraphicsContext, size: CGSize,
                     previous: [RequestPerformance], current: [RequestPerformance], blend: Double, phase: Double) {
        let radius = min(size.height * 0.62, size.width * 0.34)
        guard radius > 10 else { return }
        let center = CGPoint(x: size.width * 0.62, y: size.height / 2 + sin(phase * 1.6) * 1.4)
        let r = radius * (1 + sin(phase * 1.15) * 0.004)
        context.fill(circle(center, r * 1.2), with: .radialGradient(
            Gradient(colors: [Console.blue.opacity(0.07), .clear]), center: center,
            startRadius: r * 0.3, endRadius: r * 1.2))
        for fraction in [0.32, 0.43, 0.54, 0.65, 0.76, 0.87, 1.0] {
            context.stroke(circle(center, r * fraction), with: .color(Console.blue.opacity(fraction == 1 ? 0.28 : 0.13)), lineWidth: 0.5)
        }
        var grid = Path()
        for index in 0..<120 {
            let angle = -.pi / 2 + Double(index) / 120 * .pi * 2
            grid.move(to: point(center, r * (index % 5 == 0 ? 0.32 : 0.67), angle))
            grid.addLine(to: point(center, r, angle))
        }
        context.stroke(grid, with: .color(Console.blue.opacity(0.12)), lineWidth: 0.45)

        let latencyPeak = max(1, (previous + current).map(\.elapsed).max() ?? 1)
        let ratePeak = max(1, (previous + current).compactMap(\.outputTokensPerWallSecond).max() ?? 1)
        for series in 0...1 {
            let seriesColor = series == 0 ? Console.blue : Console.green
            var lastPoint: CGPoint?
            for (index, record) in current.enumerated() {
                let measured = series == 0 ? record.elapsed : record.outputTokensPerWallSecond
                guard let measured else { lastPoint = nil; continue }
                let old = previous.indices.contains(index) ? previous[index] : record
                let oldValue = series == 0 ? old.elapsed : old.outputTokensPerWallSecond ?? measured
                let magnitude = log1p(max(0, interpolate(oldValue, measured, blend))) / log1p(series == 0 ? latencyPeak : ratePeak)
                let angle = -.pi / 2 + Double(index) / Double(max(current.count, 1)) * .pi * 2
                    + (series == 0 ? -0.006 : 0.006)
                let base = r * (series == 0 ? 0.60 : 0.46)
                let end = point(center, base + r * 0.33 * magnitude, angle)
                let sampleColor = series == 0 ? color(record.outcome) : seriesColor
                var spoke = Path()
                spoke.move(to: point(center, base, angle))
                spoke.addLine(to: end)
                context.stroke(spoke, with: .color(sampleColor.opacity(0.65)), lineWidth: 0.7)
                if let lastPoint {
                    var trace = Path()
                    trace.move(to: lastPoint)
                    trace.addLine(to: end)
                    context.stroke(trace, with: .color(seriesColor.opacity(0.10)), lineWidth: 4)
                    context.stroke(trace, with: .color(seriesColor.opacity(0.8)), lineWidth: 0.8)
                }
                context.fill(circle(end, 1.3), with: .color(sampleColor))
                context.stroke(circle(end, 2.8), with: .color(sampleColor.opacity(0.45)), lineWidth: 0.5)
                var tick = Path()
                tick.move(to: point(center, r * 1.015, angle))
                tick.addLine(to: point(center, r * (1.035 + magnitude * 0.05), angle))
                context.stroke(tick, with: .color(sampleColor.opacity(0.75)), lineWidth: 0.8)
                lastPoint = end
            }
        }
        context.draw(Text("VAYDE").font(Console.mono(10, weight: .medium)).tracking(2).foregroundColor(Console.text),
                     at: CGPoint(x: center.x, y: center.y - 4))
        context.draw(Text("PULSE").font(Console.mono(6)).tracking(1).foregroundColor(Console.blue),
                     at: CGPoint(x: center.x, y: center.y + 9))
    }

    private static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func point(_ center: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    private static func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
