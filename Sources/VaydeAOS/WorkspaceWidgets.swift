import SwiftUI
import VaydeAOSCore

struct WorkspaceWidgets: View {
    @ObservedObject var session: ChatSession
    var isActive: Bool
    let interrupt: (String?) -> Void
    @State private var now = Date()
    @FocusState private var editingNotes: Bool
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timer: WorkspaceFocusTimer { session.workspaceConsole.timer }
    private var seconds: Int { timer.seconds(at: now) }
    private var scratchpad: String { session.workspaceConsole.scratchpad }
    private var events: [WorkspaceEvent] { session.workspaceConsole.events }

    private func completeTimer(at date: Date) {
        guard let deadline = timer.deadline, date >= deadline else { return }
        session.updateWorkspaceConsole {
            if $0.timer.complete(at: date) { $0.record("Focus interval complete") }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                signalField
                timerCard
            }
            HStack(alignment: .top, spacing: 12) {
                notesCard
                activityCard
            }
        }
        .onAppear { now = Date(); completeTimer(at: now) }
        .onReceive(ticker) { date in
            now = date
            completeTimer(at: date)
        }
    }

    private var signalField: some View {
        ConsolePanel(title: "SIGNAL FIELD", index: "03", status: "AMBIENT") {
            AmbientGraphic(style: .field, isActive: isActive).frame(height: 140)
        }.frame(maxWidth: .infinity)
    }

    private var timerCard: some View {
        ConsolePanel(title: "FOCUS TIMER", index: "04", status: timer.deadline == nil ? "READY" : "COUNTING") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(Console.mono(33, weight: .light)).monospacedDigit()
                    Spacer()
                    Menu("\(timer.duration) MIN") {
                        ForEach([5, 15, 25, 50], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                session.updateWorkspaceConsole { $0.timer.reset(minutes: minutes) }
                            }
                        }
                    }.font(Console.mono(9)).fixedSize().disabled(timer.deadline != nil)
                }
                ProgressView(value: Double(seconds), total: Double(timer.duration * 60)).tint(Console.blue)
                HStack(spacing: 8) {
                    Button {
                        now = Date()
                        session.updateWorkspaceConsole {
                            $0.timer.toggle(at: now)
                            $0.record($0.timer.deadline == nil ? "Focus timer paused" : "Focus timer started")
                        }
                    } label: { Label(timer.deadline == nil ? "START" : "PAUSE", systemImage: timer.deadline == nil ? "play" : "pause") }
                        .buttonStyle(ConsoleButtonStyle())
                    Button { session.updateWorkspaceConsole { $0.timer.reset(); $0.record("Focus timer reset") } } label: {
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
                        TextEditor(text: Binding(get: { scratchpad }, set: { value in
                            session.updateWorkspaceConsole { $0.scratchpad = value }
                        })).scrollContentBackground(.hidden).focused($editingNotes)
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
        ConsolePanel(title: "ACTIVITY LOG", index: "06", status: "SAVED IN WORKSPACE") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if events.isEmpty {
                        Text("No activity in this workspace yet.").font(Console.mono(10)).foregroundStyle(Console.muted)
                    }
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
