import Foundation
import SwiftUI
import VaydeAOSCore

/// OpenAI's public aggregate API health, independent of this app's model requests.
struct CircularActivityView: View {
    var isActive: Bool
    @StateObject private var status = PublicAPIStatus()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { timeline in
            Canvas { context, size in
                StatusDrawing.draw(in: &context, size: size, history: status.history,
                    phase: reduceMotion || !isActive ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .clipped()
        .overlay(alignment: .leading) {
            readout.frame(width: 175, alignment: .leading).padding(.leading, 22)
        }
        .overlay(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: 10) {
                legend("OPERATIONAL", color: Console.blue)
                legend("DEGRADED", color: Console.amber)
                legend("OUTAGE", color: Console.red)
                legend("MAINTENANCE", color: Console.muted)
            }.padding(.trailing, 22).allowsHitTesting(false)
        }
        .task(id: isActive) {
            if isActive { await status.poll() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenAI public API status. Inner band: Chat Completions. Outer band: Responses. One-hour history clockwise, newest at top. Outward spikes indicate disruption. \(status.history.count) observations.")
        .help("Source: status.openai.com, refreshed every 60 seconds while visible. Aggregate availability across models and tiers, not per-model latency, throughput, or benchmark performance. Inner band: Chat Completions; outer band: Responses. Outward spikes: degraded, partial outage, major outage. Missing data leaves gaps. Vertical bounce is decorative.")
    }

    private var readout: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 8) {
                Text("OPENAI / PUBLIC HEALTH")
                    .font(Console.mono(8)).tracking(1).foregroundStyle(Console.muted)
                if status.history.isEmpty {
                    Text("FETCHING STATUS").font(Console.mono(11)).foregroundStyle(Console.blue)
                } else {
                    service("CHAT COMPLETIONS / INNER", state: status.snapshot?.chatCompletions ?? .unknown)
                    service("RESPONSES / OUTER", state: status.snapshot?.responses ?? .unknown)
                }
                Text("AGGREGATE ACROSS MODELS")
                    .font(Console.mono(7)).foregroundStyle(Console.muted)
                if status.feedFailed {
                    Text("FEED UNAVAILABLE / RETRY 60S")
                        .font(Console.mono(7)).foregroundStyle(Console.amber)
                } else if let lastSuccess = status.lastSuccess {
                    Text("\(status.isStale(at: timeline.date) ? "STALE" : "FETCHED") \(max(0, Int(timeline.date.timeIntervalSince(lastSuccess))))S AGO")
                        .font(Console.mono(8)).foregroundStyle(status.isStale(at: timeline.date) ? Console.amber : Console.muted)
                }
                Link("STATUS.OPENAI.COM", destination: URL(string: "https://status.openai.com")!)
                    .font(Console.mono(8)).foregroundStyle(Console.blue)
            }
        }
    }

    private func service(_ title: String, state: OpenAIServiceStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Console.mono(7)).foregroundStyle(Console.muted)
            Text(state.label).font(Console.mono(11, weight: .medium)).foregroundStyle(StatusDrawing.color(state))
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Console.mono(7)).foregroundStyle(color)
            Rectangle().fill(color).frame(width: 12, height: 1)
        }
    }
}

private enum StatusDrawing {
    static func color(_ status: OpenAIServiceStatus) -> Color {
        switch status {
        case .operational: return Console.blue
        case .degradedPerformance: return Console.amber
        case .partialOutage, .majorOutage: return Console.red
        case .maintenance, .unknown: return Console.muted
        }
    }

    static func draw(in context: inout GraphicsContext, size: CGSize,
                     history: [OpenAIStatusSample], phase: Double) {
        let radius = min(size.height * 0.62, size.width * 0.34)
        guard radius > 10 else { return }
        let center = CGPoint(x: size.width * 0.62, y: size.height / 2 + sin(phase * 1.6) * 1.4)
        let r = radius * (1 + sin(phase * 1.15) * 0.004)
        context.fill(circle(center, r * 1.2), with: .radialGradient(
            Gradient(colors: [Console.blue.opacity(0.07), .clear]), center: center,
            startRadius: r * 0.3, endRadius: r * 1.2))
        for fraction in [0.32, 0.43, 0.50, 0.57, 0.64, 0.71, 0.78, 0.85, 0.92, 1.0] {
            context.stroke(circle(center, r * fraction), with: .color(Console.blue.opacity(fraction == 1 ? 0.28 : 0.13)), lineWidth: 0.5)
        }
        var grid = Path()
        for index in 0..<120 {
            let angle = -.pi / 2 + Double(index) / 120 * .pi * 2
            grid.move(to: point(center, r * (index % 5 == 0 ? 0.32 : 0.67), angle))
            grid.addLine(to: point(center, r, angle))
        }
        context.stroke(grid, with: .color(Console.blue.opacity(0.12)), lineWidth: 0.45)

        // Fixed ordinal bands: a larger radius always means greater reported disruption.
        // The angular distance reflects observation time, leaving gaps while suspended.
        let endTime = history.last?.observedAt ?? Date()
        let startTime = endTime.addingTimeInterval(-3600)
        for series in 0...1 {
            var previous: (point: CGPoint, date: Date)?
            for sample in history where sample.observedAt >= startTime {
                let state = (series == 0 ? sample.snapshot?.chatCompletions : sample.snapshot?.responses) ?? .unknown
                guard state != .unknown else { previous = nil; continue }
                let angle = -Double.pi / 2 + sample.observedAt.timeIntervalSince(startTime) / 3600 * Double.pi * 2
                let base = r * (series == 0 ? 0.43 : 0.71)
                let end = point(center, base + r * 0.07 * (state.disruptionLevel ?? 0), angle)
                let sampleColor = color(state)
                var spoke = Path()
                spoke.move(to: point(center, base, angle))
                spoke.addLine(to: end)
                context.stroke(spoke, with: .color(sampleColor.opacity(0.65)), lineWidth: 0.7)
                if let previous, sample.observedAt.timeIntervalSince(previous.date) < 90 {
                    var trace = Path()
                    trace.move(to: previous.point)
                    trace.addLine(to: end)
                    context.stroke(trace, with: .color(sampleColor.opacity(0.10)), lineWidth: 4)
                    context.stroke(trace, with: .color(sampleColor.opacity(0.8)), lineWidth: 0.8)
                }
                context.fill(circle(end, 1.8), with: .color(sampleColor))
                context.stroke(circle(end, 3.2), with: .color(sampleColor.opacity(0.45)), lineWidth: 0.5)
                previous = (end, sample.observedAt)
            }
        }
        context.draw(Text("VAYDE").font(Console.mono(10, weight: .medium)).tracking(2).foregroundColor(Console.text),
                     at: CGPoint(x: center.x, y: center.y - 4))
        context.draw(Text("API HEALTH").font(Console.mono(6)).tracking(1).foregroundColor(Console.blue),
                     at: CGPoint(x: center.x, y: center.y + 9))
    }

    private static func point(_ center: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    private static func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
