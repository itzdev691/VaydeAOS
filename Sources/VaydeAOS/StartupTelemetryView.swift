import SwiftUI

/// Startup instruments share one opacity layer; measurements are never synthesized.
struct StartupTelemetryView: View {
    let visibleCharacters: Int
    let reduceMotion: Bool
    @StateObject private var telemetry = SystemTelemetry()

    var body: some View {
        GeometryReader { geometry in
            let width = min(300, max(150, geometry.size.width * 0.28))
            let height = min(150, max(92, geometry.size.height * 0.22))
            let travel = min(28, geometry.size.width * 0.025)
            ZStack {
                instrument("01 / PROCESSOR", value: telemetry.cpuSampleAvailable ? String(format: "%.1f %%", telemetry.cpuUsage * 100) : "SAMPLING", samples: telemetry.cpuHistory.map { $0 * 100 })
                    .frame(width: width, height: height)
                    .modifier(StartupDeployment(active: visibleCharacters >= 1, reduceMotion: reduceMotion, x: -travel, y: -12))
                    .position(x: geometry.size.width * 0.25, y: geometry.size.height * 0.23)
                instrument("02 / MEMORY", value: Console.memory(telemetry.memoryUsedBytes) + " / " + Console.memory(telemetry.memoryTotalBytes), samples: nil)
                    .frame(width: width, height: height)
                    .modifier(StartupDeployment(active: visibleCharacters >= 3, reduceMotion: reduceMotion, x: travel, y: -12))
                    .position(x: geometry.size.width * 0.75, y: geometry.size.height * 0.23)
                instrument("03 / RECEIVE", value: telemetry.receiveHistory.isEmpty ? "SAMPLING" : Console.rate(telemetry.receiveBytesPerSecond), samples: telemetry.receiveHistory)
                    .frame(width: width, height: height)
                    .modifier(StartupDeployment(active: visibleCharacters >= 4, reduceMotion: reduceMotion, x: -travel, y: 12))
                    .position(x: geometry.size.width * 0.25, y: geometry.size.height * 0.77)
                instrument("04 / TRANSMIT", value: telemetry.sendHistory.isEmpty ? "SAMPLING" : Console.rate(telemetry.sendBytesPerSecond), samples: telemetry.sendHistory)
                    .frame(width: width, height: height)
                    .modifier(StartupDeployment(active: visibleCharacters >= 6, reduceMotion: reduceMotion, x: travel, y: 12))
                    .position(x: geometry.size.width * 0.75, y: geometry.size.height * 0.77)
            }
            .compositingGroup()
            .opacity(0.5)
        }
        .allowsHitTesting(false)
        .onAppear { telemetry.start() }
        .onDisappear { telemetry.stop() }
    }

    private func instrument(_ title: String, value: String, samples: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).tracking(1.5)
                Spacer(minLength: 4)
                Rectangle().fill(Console.blue).frame(width: 5, height: 5)
            }
            .font(Console.mono(9))
            Text(value).font(Console.mono(16)).lineLimit(1).minimumScaleFactor(0.65)
            if let samples {
                TelemetryTraceView(samples: samples)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        ForEach(0..<24, id: \.self) { index in
                            Rectangle()
                                .fill(Console.blue.opacity(Double(index) / 24 < telemetry.memoryUsage ? 1 : 0.12))
                        }
                    }
                    .frame(height: max(8, geometry.size.height * 0.65))
                }
            }
            Text(title.hasPrefix("0") && (title.contains("RECEIVE") || title.contains("TRANSMIT"))
                 ? "\(telemetry.primaryInterfaceName ?? "--") / \(telemetry.pathStatus)"
                 : "LOCAL HOST / LIVE")
                .font(Console.mono(8)).tracking(1)
        }
        .foregroundStyle(Console.blue)
        .padding(12)
        .background(Console.panel)
        .overlay(Rectangle().stroke(Console.blue, lineWidth: 0.75))
        .clipped()
    }
}

private struct StartupDeployment: ViewModifier {
    let active: Bool
    let reduceMotion: Bool
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let phase = time * 1.8 + (x > 0 ? 1.7 : 0) + (y > 0 ? 2.4 : 0)
            let driftX = reduceMotion ? 0 : sin(phase) * 7
            let driftY = reduceMotion ? 0 : cos(phase * 0.8) * 5
            let expansion = reduceMotion ? 1 : 1 + sin(phase * 0.7) * 0.025
            content
                .overlay {
                    if !reduceMotion {
                        GeometryReader { geometry in
                            let sweep = (time * 0.65).truncatingRemainder(dividingBy: 1)
                            Rectangle()
                                .fill(LinearGradient(colors: [.clear, Console.blue.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                                .frame(height: 24)
                                .offset(y: (geometry.size.height + 24) * sweep - 24)
                        }
                        .clipped()
                        .accessibilityHidden(true)
                    }
                }
                .scaleEffect(expansion)
                .offset(x: driftX, y: driftY)
        }
        .scaleEffect(x: active || reduceMotion ? 1 : 0.45, y: active || reduceMotion ? 1 : 0.025)
        .offset(x: active || reduceMotion ? x : 0, y: active || reduceMotion ? y : 0)
        .opacity(active ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.72), value: active)
    }
}
