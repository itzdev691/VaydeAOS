import SwiftUI

struct CircularAudioVisualizer: View {
    var isActive: Bool
    @StateObject private var audio = SystemAudioSpectrum()
    private let ticker = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.43
                func circle(_ fraction: Double) -> Path {
                    Path(ellipseIn: CGRect(x: center.x - radius * fraction, y: center.y - radius * fraction,
                                          width: radius * fraction * 2, height: radius * fraction * 2))
                }
                for fraction in [0.45, 0.49, 0.54, 0.94, 1.0] {
                    context.stroke(circle(fraction), with: .color(Console.blue.opacity(0.4)), lineWidth: 0.7)
                }
                for index in audio.bands.indices {
                    let angle = Double(index) / Double(audio.bands.count) * .pi * 2 - .pi / 2
                    let amplitude = audio.bands[index]
                    let inner = radius * 0.61, outer = radius * (0.625 + amplitude * 0.26)
                    var bar = Path()
                    bar.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    bar.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                    context.stroke(bar, with: .color(Console.blueBright.opacity(0.25 + amplitude * 0.75)),
                                   style: StrokeStyle(lineWidth: max(2, radius * 0.018), lineCap: .butt))
                }
                // Outer segments brighten from measured level, with no fabricated motion.
                for i in 0..<8 {
                    let a = Double(i) / 8 * .pi * 2
                    var arc = Path()
                    arc.addArc(center: center, radius: radius * 0.98,
                               startAngle: .radians(a), endAngle: .radians(a + 0.43), clockwise: false)
                    context.stroke(arc, with: .color(Console.blue.opacity(0.35 + min(1, audio.level * 4) * 0.65)), lineWidth: 3)
                }
                let db = 20 * log10(max(audio.level, 0.000001))
                let value = audio.running ? (audio.level > 0.0001 ? String(format: "%.0f dBFS", db) : "SILENT") : "AUDIO OFF"
                context.draw(Text(value).font(Console.mono(13, weight: .light)).tracking(1.5).foregroundColor(Console.blueBright),
                             at: CGPoint(x: center.x, y: center.y - 7))
                context.draw(Text("SYSTEM OUTPUT").font(Console.mono(7)).tracking(1).foregroundColor(Console.muted),
                             at: CGPoint(x: center.x, y: center.y + 13))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(audio.running ? "System audio spectrum, level \(Int(20 * log10(max(audio.level, 0.000001)))) decibels full scale" : "System audio visualizer off")
            VStack(spacing: 11) {
                Text(audio.status).font(Console.mono(8)).tracking(1).foregroundStyle(Console.blueBright)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { Task { await audio.toggle() } } label: {
                        Label(audio.enabled ? "STOP AUDIO" : "ENABLE AUDIO", systemImage: audio.enabled ? "stop.fill" : "waveform")
                    }.buttonStyle(ConsoleButtonStyle())
                    if audio.needsPermission {
                        Button("SETTINGS") { audio.openPrivacySettings() }.buttonStyle(ConsoleButtonStyle())
                    }
                }
                Text("SYSTEM AUDIO · LOCAL ANALYSIS").font(Console.mono(7)).foregroundStyle(Console.muted).tracking(0.5)
            }.padding(.horizontal, 12).padding(.bottom, 22)
        }
        .onReceive(ticker) { date in if isActive { audio.decayIfQuiet(at: date) } }
        .task(id: isActive) { await audio.setActive(isActive) }
        .onDisappear { Task { await audio.setActive(false) } }
        .help("Circular frequency spectrum of system playback. Enable audio to grant macOS capture access. No microphone, video output, or audio recording is used.")
    }
}
