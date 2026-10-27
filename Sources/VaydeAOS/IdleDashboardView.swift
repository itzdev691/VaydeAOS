import SwiftUI
import VaydeAOSCore

enum IdlePalette {
    static let background = Console.background
    static let line = Console.line
}

struct IdleDashboardView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var telemetry: SystemTelemetry
    var isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let left = min(270, max(205, geometry.size.width * 0.20))
            let right = min(355, max(265, geometry.size.width * 0.26))
            let bottom = max(160, geometry.size.height * 0.23)
            HStack(spacing: 12) {
                VStack(spacing: 12) {
                    workspaces.frame(height: geometry.size.height * 0.24)
                    system.frame(maxHeight: .infinity)
                    interfaces.frame(height: geometry.size.height * 0.30)
                }.frame(width: left)
                VStack(spacing: 12) {
                    IdlePanel(title: "NETWORK ORBIT", index: "04") {
                        ConnectionGlobe(isActive: isActive)
                    }.frame(maxHeight: .infinity)
                    HStack(spacing: 12) {
                        traffic.frame(maxWidth: .infinity)
                        model.frame(maxWidth: .infinity)
                    }.frame(height: bottom)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    IdlePanel(title: "AUDIO SPECTRUM", index: "05") {
                        CircularAudioVisualizer(isActive: isActive)
                    }.frame(maxHeight: .infinity)
                    IdlePanel(title: "OPENAI API STATUS", index: "08", detail: "PUBLIC / 60S") {
                        CircularActivityView(isActive: isActive, compact: true)
                    }.frame(height: max(140, geometry.size.height * 0.20))
                }.frame(width: right)
            }
        }
        .background(IdlePalette.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Idle workspace dashboard")
    }

    private var workspaces: some View {
        IdlePanel(title: "WORKSPACES", index: "01") {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(Array(session.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        HStack(spacing: 14) {
                            Text(String(format: "%02d", index + 1)).foregroundStyle(Console.blueBright)
                            Text(workspace.name.uppercased()).tracking(1).lineLimit(1)
                            Spacer(minLength: 2)
                            Circle().fill(workspace.id == session.selectedWorkspaceID ? Console.blue : .clear)
                                .overlay(Circle().stroke(Console.blueBright, lineWidth: 0.8)).frame(width: 8, height: 8)
                        }.font(Console.mono(10)).padding(11)
                            .background(workspace.id == session.selectedWorkspaceID ? Console.blue.opacity(0.10) : .clear)
                            .overlay(Rectangle().strokeBorder(IdlePalette.line, lineWidth: 0.6))
                    }
                }.padding(10)
            }
        }
    }

    private var system: some View {
        IdlePanel(title: "SYSTEM", index: "02", detail: "LIVE") {
            VStack(spacing: 10) {
                meter("CPU", fraction: telemetry.cpuUsage,
                      value: telemetry.cpuSampleAvailable ? String(format: "%.0f%%", telemetry.cpuUsage * 100) : "—")
                meter("MEMORY", fraction: telemetry.memoryUsage, value: String(format: "%.0f%%", telemetry.memoryUsage * 100))
                Text("\(Console.memory(telemetry.memoryUsedBytes)) / \(Console.memory(telemetry.memoryTotalBytes))")
                    .font(Console.mono(8)).foregroundStyle(Console.muted).frame(maxWidth: .infinity, alignment: .leading)
                    .help("Active + wired + compressed physical memory")
                TelemetryTraceView(samples: telemetry.cpuHistory, color: Console.blue).frame(minHeight: 20, maxHeight: .infinity)
                InstrumentRow(label: "UPTIME", value: uptime)
            }.padding(12)
        }
    }

    private func meter(_ label: String, fraction: Double, value: String) -> some View {
        VStack(spacing: 6) {
            HStack { Text(label).tracking(1); Spacer(); Text(value).monospacedDigit() }
                .font(Console.mono(10)).foregroundStyle(Console.blueBright)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Console.blue.opacity(0.05))
                    Rectangle().fill(LinearGradient(colors: [Console.blue, Console.blueBright], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    HStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { _ in
                            Spacer(minLength: 0); Rectangle().fill(IdlePalette.background.opacity(0.55)).frame(width: 1)
                        }
                    }
                }.overlay(Rectangle().strokeBorder(IdlePalette.line, lineWidth: 0.6))
            }.frame(height: 12)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(label) \(value)")
    }

    private var interfaces: some View {
        IdlePanel(title: "INTERFACES", index: "03", detail: telemetry.pathStatus) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(telemetry.interfaces.filter { $0.isUp && !$0.addresses.isEmpty }.sorted {
                        if ($0.name == telemetry.primaryInterfaceName) != ($1.name == telemetry.primaryInterfaceName) {
                            return $0.name == telemetry.primaryInterfaceName
                        }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }) { interface in
                        HStack(spacing: 10) {
                            Image(systemName: interface.name.hasPrefix("en") ? "network" : "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(Console.blueBright).frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(interface.name.uppercased()).font(Console.mono(10)).tracking(1)
                                Text(interface.addresses.first(where: { !$0.contains(":") }) ?? interface.addresses.first ?? "—")
                                    .font(Console.mono(8)).foregroundStyle(Console.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Circle().fill(interface.name == telemetry.primaryInterfaceName ? Console.green : Console.blue.opacity(0.2))
                                .overlay(Circle().stroke(Console.blueBright, lineWidth: 0.7)).frame(width: 8, height: 8)
                        }.padding(8).overlay(Rectangle().strokeBorder(IdlePalette.line.opacity(0.7), lineWidth: 0.5))
                            .help(interface.addresses.joined(separator: "\n"))
                    }
                }.padding(10)
            }
        }
    }

    private var traffic: some View {
        IdlePanel(title: "SIGNAL FLOW", index: "06", detail: telemetry.primaryInterfaceName?.uppercased() ?? "—") {
            VStack(spacing: 10) {
                flow("TX", rate: telemetry.sendBytesPerSecond, history: telemetry.sendHistory, color: Console.blue)
                flow("RX", rate: telemetry.receiveBytesPerSecond, history: telemetry.receiveHistory, color: Console.blueBright)
            }.padding(12)
        }
    }

    private func flow(_ label: String, rate: Double, history: [Double], color: Color) -> some View {
        VStack(spacing: 4) {
            HStack { Text(label); Spacer(); Text(Console.rate(rate)).foregroundStyle(color) }.font(Console.mono(9))
            TelemetryTraceView(samples: history, color: color).frame(minHeight: 20, maxHeight: .infinity)
        }.help("Measured throughput. Traces scale independently across the last 60 samples.")
    }

    private var model: some View {
        IdlePanel(title: "MODEL UPLINK", index: "09") {
            VStack(alignment: .leading, spacing: 9) {
                Text(session.modelSelection.displayName).font(Console.mono(12)).foregroundStyle(Console.blueBright).lineLimit(1)
                Text(session.settings.connectionLabel).font(Console.mono(8)).foregroundStyle(Console.muted).lineLimit(1)
                Spacer(minLength: 0)
                InstrumentRow(label: "REQUEST", value: session.errorMessage != nil ? "ATTENTION" : session.isSending ? "RUNNING" : "STANDBY")
                InstrumentRow(label: "CONTEXT", value: "\(session.messages.count) MESSAGES")
                InstrumentRow(label: "REASONING", value: session.settings.reasoningEffort.label.uppercased())
            }.padding(12)
        }
    }

    private var uptime: String {
        let seconds = Int(telemetry.uptime)
        return String(format: "%02dd %02dh %02dm", seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60)
    }
}

struct IdlePanel<Content: View>: View {
    let title: String
    let index: String
    var detail = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(index).foregroundStyle(Console.red)
                Text(title).tracking(1.7).lineLimit(1)
                Spacer(minLength: 0)
                Text("—").foregroundStyle(Console.blueBright)
            }.font(Console.mono(11)).padding(.horizontal, 13).frame(height: 35)
                .background(Console.raised.opacity(0.35))
            Rectangle().fill(IdlePalette.line.opacity(0.4)).frame(height: 0.5).padding(.horizontal, 9)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !detail.isEmpty {
                Text(detail).font(Console.mono(7)).tracking(0.8).foregroundStyle(Console.blueBright.opacity(0.8))
                    .lineLimit(1).padding(.horizontal, 10).padding(.bottom, 7).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Console.panel.opacity(0.92))
        .overlay(Rectangle().strokeBorder(IdlePalette.line, lineWidth: 0.6))
        .overlay {
            GeometryReader { proxy in
                Path { path in
                    for x in [CGFloat(0), proxy.size.width] {
                        for y in [CGFloat(0), proxy.size.height] {
                            let dx: CGFloat = x == 0 ? 15 : -15, dy: CGFloat = y == 0 ? 15 : -15
                            path.move(to: CGPoint(x: x + dx, y: y)); path.addLine(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x, y: y + dy))
                        }
                    }
                }.stroke(Console.blue, lineWidth: 1.2)
            }.allowsHitTesting(false)
        }
    }
}
