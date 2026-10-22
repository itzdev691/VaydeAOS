import SwiftUI

private struct WorkspaceBootReadyKey: EnvironmentKey {
    static let defaultValue = true
}
private struct WorkspaceBootStepKey: EnvironmentKey {
    static let defaultValue = 11
}
extension EnvironmentValues {
    var workspaceBootReady: Bool {
        get { self[WorkspaceBootReadyKey.self] }
        set { self[WorkspaceBootReadyKey.self] = newValue }
    }
    var workspaceBootStep: Int {
        get { self[WorkspaceBootStepKey.self] }
        set { self[WorkspaceBootStepKey.self] = newValue }
    }
}

/// Reveals existing instruments in place; boot labels describe presentation only.
private struct WorkspaceBootReveal: ViewModifier {
    let stage: Int
    let label: String
    @Environment(\.workspaceBootStep) private var step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let ready = reduceMotion || step > stage
        content
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().frame(width: ready ? geometry.size.width : 0)
                }
            }
            .overlay {
                if !ready {
                    ZStack(alignment: .topLeading) {
                        Rectangle().strokeBorder(Console.blue.opacity(step >= stage ? 0.45 : 0.1), lineWidth: 1)
                        if step >= stage {
                            Text("> INITIALIZING \(label)_")
                                .font(Console.mono(9)).tracking(1)
                                .foregroundStyle(Console.blue)
                                .padding(12)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: ready)
            .allowsHitTesting(ready)
            .accessibilityHidden(!ready)
    }
}
extension View {
    func workspaceBoot(stage: Int, label: String) -> some View {
        modifier(WorkspaceBootReveal(stage: stage, label: label))
    }
}
