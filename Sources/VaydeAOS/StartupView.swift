import SwiftUI

/// Typed wordmark above a perspective data floor.
struct StartupView: View {
    let visibleCharacters: Int
    let isRaised: Bool
    let onSkip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorVisible = true

    private let title = Array("VAYDEAOS")
    private var count: Int { min(max(visibleCharacters, 0), title.count) }

    var body: some View {
        GeometryReader { geometry in
            let fontSize = min(64, max(32, (geometry.size.width - 80) / 10))
            let cellWidth = fontSize * 0.80
            let cellHeight = fontSize * 1.3

            ZStack {
                Console.background
                StartupDataGrid(reduceMotion: reduceMotion)
                    .ignoresSafeArea()
                    .offset(y: reduceMotion || isRaised ? 0 : geometry.size.height * 0.10)
                HStack(spacing: 0) {
                    ForEach(title.indices, id: \.self) { index in
                        Text(String(title[index]))
                            .foregroundStyle(index < 5 ? Console.blue : Console.background)
                            .frame(width: cellWidth, height: cellHeight)
                            .background(index >= 5 && index < count ? Console.blue : .clear)
                            .opacity(index < count ? 1 : 0)
                    }
                    Color.clear.frame(width: cellWidth, height: cellHeight)
                }
                .font(.custom("AvenirNext-DemiBold", fixedSize: fontSize))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Console.red)
                        .frame(width: cellWidth * 0.72, height: fontSize * 0.92)
                        .offset(x: CGFloat(count) * cellWidth + cellWidth * 0.14)
                        .opacity(cursorVisible ? 0.85 : 0)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("VaydeAOS")
                .accessibilityValue(count == title.count ? "Ready" : "Starting")

                VStack {
                    Spacer()
                    Button("ESC TO SKIP", action: onSkip)
                        .font(Console.mono(9))
                        .tracking(1.5)
                        .foregroundStyle(Console.muted)
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                        .padding(.bottom, 28)
                }
            }
        }
        .task(id: count) {
            cursorVisible = true
            guard !reduceMotion, count == title.count else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    cursorVisible.toggle()
                }
            } catch { }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("VaydeAOS startup")
    }
}
