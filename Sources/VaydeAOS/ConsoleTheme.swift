import AppKit
import SwiftUI

enum Console {
    // App bundles keep SwiftPM resources under Contents/Resources; swift run
    // uses SwiftPM's generated development bundle location.
    static let assets: Bundle = {
        if let url = Bundle.main.url(forResource: "VaydeAOS_VaydeAOS", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for (name, ext) in [("vayde-mark", "png"), ("vaydenet-hardware", "jpeg")] {
            if let url = assets.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) { images[name] = image }
        }
        return images
    }()

    static func image(_ name: String, extension ext: String) -> Image {
        if let image = images[name] { return Image(nsImage: image) }
        return Image(systemName: "photo")
    }

    // Logo palette: dominant blue family, supporting white, restrained red accents.
    // Brighter blue is reserved for selected, hovered, and focused controls.
    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
    static let background = hex(0x050b18)
    static let panel = hex(0x09162e)
    static let raised = hex(0x0d2852)
    static let blue = hex(0x007bfd)
    static let border = hex(0x1c4380)
    static let blueStrong = hex(0x005dd7)
    static let blueBright = hex(0x3b98ff)
    static let red = hex(0xff3e32)
    static let redStrong = hex(0xf52c24)
    static let green = hex(0x00e997)
    static let amber = hex(0xffdf00)
    static let white = hex(0xfdfdfd)
    static let text = hex(0xf1f4fa)
    static let muted = hex(0xb0bacb)
    static let line = hex(0x1c3b6b).opacity(0.75)
    static let brandGradient = LinearGradient(
        stops: [.init(color: blueStrong, location: 0),
                .init(color: blueBright, location: 0.72),
                .init(color: redStrong, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func rate(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.2f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }
    static func memory(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

struct ConsolePanel<Content: View>: View {
    let title: String
    var index: String = ""
    var status: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !index.isEmpty { Text(index).foregroundStyle(Console.red) }
                Text(title).tracking(1.4).foregroundStyle(Console.text)
                Spacer(minLength: 4)
                Text(status).foregroundStyle(Console.muted)
            }
            .font(Console.mono(10, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Console.raised.opacity(0.35))
            Rectangle().fill(Console.line).frame(height: 1)
            content
        }
        .background(Console.panel.opacity(0.92))
        .overlay(Rectangle().strokeBorder(Console.line, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Rectangle().fill(Console.red.opacity(0.8)).frame(width: 22, height: 1)
        }
        .workspaceBoot(stage: min(9, (Int(index) ?? 0) + 3), label: title)
    }
}

struct ConsoleButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        ConsoleButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
    private struct ConsoleButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Console.mono(compact ? 9 : 11, weight: .medium))
                .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 0 : 9)
                .foregroundStyle(Console.white)
                .background {
                    RoundedRectangle(cornerRadius: compact ? 3 : 0)
                        .fill(prominent ? Console.blueStrong : Console.raised.opacity(hovering || focused ? 0.75 : 0.25))
                    if hovering || focused {
                        RoundedRectangle(cornerRadius: compact ? 3 : 0).fill(Console.blueBright.opacity(0.10))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: compact ? 3 : 0)
                    .strokeBorder(hovering || focused ? Console.blueBright.opacity(0.8) : Console.border, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if prominent { Rectangle().fill(Console.brandGradient).frame(height: 2) }
                }
                .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.65 : 1)
                .onHover { hovering = $0 }
        }
    }
}

struct ConsoleGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: CGFloat(0), to: size.width, by: 30) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat(0), to: size.height, by: 30) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Console.blueBright.opacity(0.10)), lineWidth: 0.5)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct InstrumentRow: View {
    let label: String
    let value: String
    var color: Color = Console.text
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Console.muted)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
        }.font(Console.mono(10))
    }
}
