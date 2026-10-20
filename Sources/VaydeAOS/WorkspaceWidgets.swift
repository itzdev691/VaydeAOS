import SwiftUI

struct WorkspaceWidgets: View {
    @ObservedObject var telemetry: SystemTelemetry
    let events: [WorkspaceEvent]
    let interrupt: (String?) -> Void
    let record: (String) -> Void
    @AppStorage("workspace.scratchpad") private var scratchpad = ""
    @State private var signal = 0
    @State private var duration = 25
    @State private var remaining: TimeInterval = 25 * 60
    @State private var deadline: Date?
    @State private var now = Date()
    @FocusState private var editingNotes: Bool
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var seconds: Int { max(0, Int(ceil(deadline?.timeIntervalSince(now) ?? remaining))) }
    private var samples: [Double] { signal == 0 ? telemetry.cpuHistory : signal == 1 ? telemetry.receiveHistory : telemetry.sendHistory }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                signalCard
                timerCard
            }
            HStack(alignment: .top, spacing: 12) {
                notesCard
                activityCard
            }
        }
        .onReceive(ticker) { date in
            now = date
            if let deadline, date >= deadline {
                self.deadline = nil
                remaining = 0
                record("Focus interval complete")
            }
        }
    }

    private var signalCard: some View {
        ConsolePanel(title: "SIGNAL INSPECTOR", index: "03", status: "LIVE") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ForEach(Array(["CPU", "RX", "TX"].enumerated()), id: \.offset) { index, label in
                        Button { signal = index } label: {
                            Text(label).font(Console.mono(10)).foregroundStyle(signal == index ? Console.blue : Console.muted)
                                .padding(.bottom, 5).overlay(alignment: .bottom) {
                                    if signal == index { Rectangle().fill(Console.red).frame(height: 1) }
                                }
                        }.buttonStyle(.plain).accessibilityAddTraits(signal == index ? .isSelected : [])
                    }
                    Spacer()
                    Text(signal == 0 ? String(format: "%.1f %%", telemetry.cpuUsage * 100) : Console.rate(signal == 1 ? telemetry.receiveBytesPerSecond : telemetry.sendBytesPerSecond))
                        .font(Console.mono(14)).foregroundStyle(Console.blue).monospacedDigit()
                }
                TelemetryTraceView(samples: samples, color: signal == 2 ? Console.red : Console.blue).frame(height: 60)
                HStack {
                    Text("\(samples.count) SAMPLES")
                    Spacer()
                    Text(signal == 0 ? "HOST CPU" : telemetry.primaryInterfaceName?.uppercased() ?? "NO INTERFACE")
                }.font(Console.mono(8)).foregroundStyle(Console.muted)
            }.padding(14)
        }.frame(maxWidth: .infinity)
    }

    private var timerCard: some View {
        ConsolePanel(title: "FOCUS TIMER", index: "04", status: deadline == nil ? "READY" : "COUNTING") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(Console.mono(33, weight: .light)).monospacedDigit()
                    Spacer()
                    Menu("\(duration) MIN") {
                        ForEach([5, 15, 25, 50], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                duration = minutes; remaining = Double(minutes * 60); deadline = nil
                            }
                        }
                    }.font(Console.mono(9)).fixedSize().disabled(deadline != nil)
                }
                ProgressView(value: Double(seconds), total: Double(duration * 60)).tint(Console.blue)
                HStack(spacing: 8) {
                    Button {
                        if let deadline {
                            remaining = max(0, deadline.timeIntervalSinceNow); self.deadline = nil
                            record("Focus timer paused")
                        } else {
                            if remaining <= 0 { remaining = Double(duration * 60) }
                            now = Date(); deadline = now.addingTimeInterval(remaining)
                            record("Focus timer started")
                        }
                    } label: { Label(deadline == nil ? "START" : "PAUSE", systemImage: deadline == nil ? "play" : "pause") }
                        .buttonStyle(ConsoleButtonStyle())
                    Button { deadline = nil; remaining = Double(duration * 60); record("Focus timer reset") } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Reset focus timer")
                    Spacer(minLength: 0)
                }
            }.padding(14)
        }.frame(maxWidth: .infinity)
    }

    private var notesCard: some View {
        ConsolePanel(title: "SCRATCHPAD", index: "05", status: "SAVED LOCALLY") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if scratchpad.isEmpty {
                        Text("Capture a thought before it disappears…").foregroundStyle(Console.muted)
                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                    if editingNotes {
                        TextEditor(text: $scratchpad).scrollContentBackground(.hidden).focused($editingNotes)
                            .accessibilityLabel("Scratchpad")
                    } else {
                        Text(scratchpad.isEmpty ? " " : scratchpad)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(5).contentShape(Rectangle()).onTapGesture { editingNotes = true }
                    }
                }.font(Console.mono(11)).frame(height: 88)
                HStack {
                    Text("\(scratchpad.count) CHARACTERS").font(Console.mono(8)).foregroundStyle(Console.muted)
                    Spacer()
                    Button(editingNotes ? "DONE" : "EDIT") { editingNotes.toggle() }
                        .buttonStyle(ConsoleButtonStyle())
                    Button { editingNotes = false; interrupt("Help me work through these notes:\n\n" + scratchpad) } label: {
                        Label("TO CHAT", systemImage: "arrow.up.right")
                    }.buttonStyle(ConsoleButtonStyle()).disabled(scratchpad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(14)
        }.frame(maxWidth: .infinity)
    }

    private var activityCard: some View {
        ConsolePanel(title: "ACTIVITY LOG", index: "06", status: "THIS SESSION") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(events.reversed()) { event in
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(Console.blue).frame(width: 4, height: 4).padding(.top, 4)
                            Text(event.date, style: .time).foregroundStyle(Console.muted).monospacedDigit()
                            Text(event.title).foregroundStyle(Console.text).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(Console.mono(9))
                    }
                }.padding(14)
            }.frame(height: 146)
        }.frame(maxWidth: .infinity)
    }
}
