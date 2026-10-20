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

    // Experimental VaydeNet palette, sampled from the live site stylesheet.
    // https://vaydenet.duckdns.org/css/tokens.css
    // Navy foundation / blue structure / restrained red accents.
    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
    static let background = hex(0x070b18)
    static let panel = hex(0x0b1020)
    static let raised = hex(0x172554)
    static let blue = hex(0x60a5fa)
    static let blueStrong = hex(0x1d4ed8)
    static let blueBright = hex(0x3b82f6)
    static let red = hex(0xff4c5b)
    static let redStrong = hex(0xff2235)
    static let green = hex(0x34d399)
    static let amber = hex(0xe8ba73)
    static let white = hex(0xf8fbff)
    static let text = hex(0xdbeafe)
    static let muted = hex(0x94a3b8)
    static let line = blue.opacity(0.16)
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
    }
}

struct ConsoleButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        ConsoleButtonBody(configuration: configuration, prominent: prominent)
    }
    private struct ConsoleButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Console.mono(11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(prominent ? Console.white : Console.blue)
                .background(prominent ? Console.blueStrong : Console.raised.opacity(hovering ? 0.75 : 0.35))
                .overlay(Rectangle().strokeBorder(Console.blue.opacity(hovering ? 0.8 : 0.3), lineWidth: 1))
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
            for x in stride(from: CGFloat(0), to: size.width, by: 32) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat(0), to: size.height, by: 32) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Console.blue.opacity(0.025)), lineWidth: 0.5)
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
