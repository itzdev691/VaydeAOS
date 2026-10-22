import SwiftUI

/// Stages the workspace reveal while keeping startup input out of the chat draft.
struct StartupContainer<Content: View>: View {
    @Binding var isComplete: Bool
    @ViewBuilder let content: Content
    @StateObject private var sound = StartupSound()
    @State private var visibleCharacters = 0
    @State private var startupRaised = false
    @State private var showingMainScreen = false
    @State private var flashOpacity = 0.0
    @AppStorage("startup.soundEnabled") private var soundEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Console.background
            if isComplete || showingMainScreen {
                content
                    .environment(\.workspaceBootReady, isComplete)
                    .allowsHitTesting(isComplete)
                    .disabled(!isComplete)
                    .accessibilityHidden(!isComplete)
            } else {
                StartupView(visibleCharacters: visibleCharacters,
                            isRaised: startupRaised, onSkip: finish)
            }
            Color.white.opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipped()
        .preferredColorScheme(.dark)
        .task { await runSequence() }
        .onExitCommand { finish() }
        .onChange(of: soundEnabled) { enabled in
            if !enabled { sound.stop() }
        }
        .onChange(of: reduceMotion) { reduced in
            if reduced { finish() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { sound.stop() }
            if phase == .background { finish() }
        }
        .onDisappear { sound.stop() }
    }

    @MainActor
    private func runSequence() async {
        guard !isComplete else { return }
        do {
            try await pause(100)
            if soundEnabled && scenePhase == .active { sound.play() }
            if reduceMotion {
                visibleCharacters = 8
                try await pause(700)
            } else {
                try await pause(400)
                for count in 1...8 {
                    visibleCharacters = count
                    try await pause(160)
                }
                try await pause(400)
                try await pause(40)
                withAnimation(.easeInOut(duration: 0.95)) {
                    startupRaised = true
                }
                for count in stride(from: 7, through: 0, by: -1) {
                    visibleCharacters = count
                    try await pause(100)
                }
                try await pause(150)
                flashOpacity = 1
                try await pause(100)
                // Swap screens at the flash peak without animating the workspace.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { showingMainScreen = true }
                try await pause(60)
                withAnimation(.easeOut(duration: 0.42)) { flashOpacity = 0 }
                try await pause(420)
            }
            finish()
        } catch {
            sound.stop()
        }
    }

    @MainActor
    private func pause(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        try Task.checkCancellation()
        if isComplete { throw CancellationError() }
    }

    @MainActor
    private func finish() {
        guard !isComplete else { return }
        sound.stop()
        flashOpacity = 0
        isComplete = true
    }
}
