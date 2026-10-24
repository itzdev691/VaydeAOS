import AppKit
import SwiftUI
import VaydeAOSCore

struct TelemetrySidebar: View {
    @ObservedObject var telemetry: SystemTelemetry

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ConsolePanel(title: "HOST VITALS", index: "SYS", status: "LIVE") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("CPU").font(Console.mono(10)).foregroundStyle(Console.muted)
                            Spacer()
                            Text(telemetry.cpuSampleAvailable ? String(format: "%.1f", telemetry.cpuUsage * 100) : "—")
                                .font(Console.mono(30, weight: .light)).foregroundStyle(Console.blue)
                            Text("%").font(Console.mono(11)).foregroundStyle(Console.muted)
                        }
                        TelemetryTraceView(samples: telemetry.cpuHistory, color: Console.blue).frame(height: 48)
                            .accessibilityLabel("CPU usage history, last 60 samples")
                        Rectangle().fill(Console.line).frame(height: 1)
                        InstrumentRow(label: "MEMORY", value: Console.memory(telemetry.memoryUsedBytes), color: Console.green)
                        segmentedMeter(telemetry.memoryUsage, color: Console.green)
                        Text("Active + wired + compressed / \(Console.memory(telemetry.memoryTotalBytes))")
                            .font(Console.mono(8)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
                        InstrumentRow(label: "UPTIME", value: uptime)
                    }.padding(14)
                }
                ConsolePanel(title: "TRAFFIC", index: "NET", status: "1 SEC") {
                    VStack(alignment: .leading, spacing: 10) {
                        trafficHeader("INBOUND", rate: telemetry.receiveBytesPerSecond, color: Console.blue, symbol: "arrow.down.left")
                        TelemetryTraceView(samples: telemetry.receiveHistory, color: Console.blue).frame(height: 60)
                            .accessibilityLabel("Inbound traffic history")
                        HStack { Text("LAST \(telemetry.receiveHistory.count) SAMPLES"); Spacer(); Text("NOW") }.font(Console.mono(8)).foregroundStyle(Console.muted)
                        Rectangle().fill(Console.line).frame(height: 1).padding(.vertical, 3)
                        trafficHeader("OUTBOUND", rate: telemetry.sendBytesPerSecond, color: Console.red, symbol: "arrow.up.right")
                        TelemetryTraceView(samples: telemetry.sendHistory, color: Console.red).frame(height: 60)
                            .accessibilityLabel("Outbound traffic history")
                        Text("\(telemetry.primaryInterfaceName ?? "No primary interface") / independently scaled traces")
                            .font(Console.mono(8)).foregroundStyle(Console.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(14)
                }
                hardwareCard
            }
        }
    }

    private var uptime: String {
        let seconds = Int(telemetry.uptime)
        return String(format: "%02dd %02dh %02dm", seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60)
    }

    private func segmentedMeter(_ fraction: Double, color: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                Rectangle().fill(Double(index) / 24 < fraction ? color.opacity(0.8) : Console.line)
            }
        }.frame(height: 7).accessibilityLabel("Memory usage \(Int(fraction * 100)) percent")
    }

    private func trafficHeader(_ title: String, rate: Double, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(Console.mono(9)).tracking(1).foregroundStyle(color)
            Text(Console.rate(rate)).font(Console.mono(22, weight: .light)).foregroundStyle(Console.text).monospacedDigit()
        }
    }

    private var hardwareCard: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Console.image("vaydenet-hardware", extension: "jpeg").resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }
            LinearGradient(colors: [.clear, Console.background.opacity(0.95)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text("BUILT TO CONNECT.").font(Console.mono(12, weight: .semibold)).tracking(1)
                Text("VAYDENET / HARDWARE INDEPENDENT").font(Console.mono(8)).tracking(0.5).foregroundStyle(Console.blue)
            }.padding(14)
        }
        .frame(height: 135).clipped().overlay(Rectangle().strokeBorder(Console.line, lineWidth: 1))
    }
}

struct SessionSidebar: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var telemetry: SystemTelemetry
    @Binding var showingConnectionSettings: Bool
    @State private var showAllInterfaces = false
    @State private var reasoningError: String?

    private var interfaces: [SystemTelemetry.NetworkInterface] {
        let active = telemetry.interfaces.filter { $0.isUp && !$0.addresses.isEmpty }.sorted {
            if ($0.name == telemetry.primaryInterfaceName) != ($1.name == telemetry.primaryInterfaceName) {
                return $0.name == telemetry.primaryInterfaceName
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return showAllInterfaces ? active : Array(active.prefix(3))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ConsolePanel(title: "MODEL UPLINK", index: "AI", status: session.isSending ? "BUSY" : "IDLE") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "cpu").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(Console.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.settings.activeModel).font(Console.mono(13, weight: .medium)).lineLimit(2)
                                Text(session.settings.provider == .chatGPT ? "CHATGPT / AGENT RUNTIME" : "CHAT COMPLETIONS")
                                    .font(Console.mono(8)).tracking(1).foregroundStyle(Console.muted)
                            }
                        }
                        Text(session.settings.connectionLabel).font(Console.mono(10)).foregroundStyle(Console.blue)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Rectangle().fill(Console.line).frame(height: 1)
                        InstrumentRow(label: "REQUEST", value: session.isSending ? "RUNNING" : session.errorMessage != nil ? "ATTENTION" : "STANDBY", color: session.errorMessage != nil ? Console.amber : Console.green)
                        InstrumentRow(label: "CONTEXT", value: "\(session.messages.count) messages")
                        reasoningControl
                        Button { showingConnectionSettings = true } label: {
                            HStack { Text("CONFIGURE UPLINK"); Spacer(); Image(systemName: "arrow.up.right") }
                        }.buttonStyle(ConsoleButtonStyle()).disabled(session.isSending)
                    }.padding(14)
                }
                ConsolePanel(title: "INTERFACES", index: "IO", status: "LOCAL") {
                    VStack(alignment: .leading, spacing: 0) {
                        if interfaces.isEmpty {
                            Text("No active addresses").font(Console.mono(11)).foregroundStyle(Console.muted).padding(14)
                        }
                        ForEach(interfaces) { interface in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Circle().fill(Console.green).frame(width: 4, height: 4)
                                    Text(interface.name).font(Console.mono(12, weight: .medium))
                                    Spacer()
                                    Text(interface.name == telemetry.primaryInterfaceName ? "PRIMARY" : "UP")
                                        .font(Console.mono(8)).foregroundStyle(Console.blue)
                                }
                                Text(interface.addresses.first(where: { !$0.contains(":") }) ?? interface.addresses.first ?? "No address").font(Console.mono(10)).foregroundStyle(Console.muted)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    .help(interface.addresses.joined(separator: "\n"))
                            }
                            .padding(14)
                            .overlay(alignment: .bottom) { Rectangle().fill(Console.line.opacity(0.6)).frame(height: 1) }
                        }
                        Button { showAllInterfaces.toggle() } label: {
                            HStack {
                                Text(showAllInterfaces ? "COLLAPSE INTERFACES" : "SHOW ALL INTERFACES")
                                Spacer()
                                Image(systemName: showAllInterfaces ? "minus" : "plus")
                            }.font(Console.mono(9)).foregroundStyle(Console.blue).padding(14)
                        }.buttonStyle(.plain)
                    }
                }
                ConsolePanel(title: "PHASE CORE", index: "FX", status: "AMBIENT") {
                    AmbientGraphic(style: .core).frame(height: 176)
                }
            }
        }
    }

    private var reasoningControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            InstrumentRow(label: "REASONING MODE", value: session.settings.reasoningEffort.label.uppercased(), color: Console.blue)
            Slider(value: Binding(
                get: { Double(ConnectionSettings.ReasoningEffort.allCases.firstIndex(of: session.settings.reasoningEffort) ?? 0) },
                set: { value in
                    do {
                        try session.setReasoningEffort(ConnectionSettings.ReasoningEffort.allCases[Int(value.rounded())])
                        reasoningError = nil
                    } catch {
                        reasoningError = "Could not save reasoning mode. \(error.localizedDescription)"
                    }
                }
            ), in: 0...Double(ConnectionSettings.ReasoningEffort.allCases.count - 1), step: 1)
            .controlSize(.small)
            .tint(Console.blue)
            .accessibilityLabel("Reasoning mode")
            .accessibilityValue(session.settings.reasoningEffort.label)
            .disabled(session.isSending || session.codex.isChecking || session.codex.isRunning)
            HStack {
                Text("AUTO")
                Spacer()
                Text("MAX")
            }.font(Console.mono(8)).foregroundStyle(Console.muted)
            Text(reasoningError ?? "Auto uses the model default. Available levels depend on the model.")
                .font(Console.mono(8)).foregroundStyle(reasoningError == nil ? Console.muted : Console.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
