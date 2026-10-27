import SwiftUI

/// Geographic backdrop and illustrative connections, independent of measured traffic.
struct ConnectionGlobe: View {
    var isActive: Bool
    @State private var yaw = 0.0
    @State private var tilt = -0.19
    @State private var zoom = 1.0
    @State private var spinning = true
    @State private var dragging = false
    @State private var lastDrag = CGSize.zero
    @State private var spinOffset = 0.4
    @State private var epoch = Date()
    @State private var selectedSite: Int?
    @GestureState private var magnification = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let moving = isActive && !reduceMotion && scenePhase == .active && spinning && !dragging
        GeometryReader { geometry in
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !moving)) { timeline in
            Canvas { context, size in
                let rotation = yaw + spinOffset + (moving ? timeline.date.timeIntervalSince(epoch) * 0.055 : 0)
                GlobeDrawing.draw(in: &context, size: size, rotation: rotation, tilt: tilt,
                                  zoom: zoom * magnification, selectedSite: selectedSite)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                dragging = true
                yaw += Double(value.translation.width - lastDrag.width) * 0.008
                tilt = min(1.2, max(-1.2, tilt + Double(value.translation.height - lastDrag.height) * 0.006))
                lastDrag = value.translation
            }.onEnded { _ in lastDrag = .zero; dragging = false })
        .gesture(MagnificationGesture().updating($magnification) { value, state, _ in state = value }
            .onEnded { zoom = min(1.5, max(0.75, zoom * $0)) })
        .onTapGesture(count: 2) { reset() }
        .onTapGesture { location in selectSite(at: location, size: geometry.size, moving: moving) }
        .clipped()
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 15) {
                Button { spinning.toggle() } label: { Image(systemName: spinning ? "pause" : "play") }
                    .accessibilityLabel(spinning ? "Pause globe rotation" : "Resume globe rotation")
                Button { zoom = max(0.75, zoom / 1.12) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Zoom out globe")
                Button { zoom = min(1.5, zoom * 1.12) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Zoom in globe")
                Button { reset() } label: { Image(systemName: "scope") }.accessibilityLabel("Reset globe view")
            }.buttonStyle(.plain).font(Console.mono(11)).foregroundStyle(Console.blueBright)
                .padding(12).background(Console.panel.opacity(0.9)).padding(8)
        }
        .onChange(of: moving) { active in
            if !active { spinOffset += Date().timeIntervalSince(epoch) * 0.055 }
            epoch = Date()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interactive globe with illustrative connections")
        .help("Drag to rotate and tilt. Pinch or use +/- to zoom. Click a connection node to highlight its links. Double-click or use reset to restore the view.")
    }

    private func selectSite(at location: CGPoint, size: CGSize, moving: Bool) {
        let rotation: Double = yaw + spinOffset + (moving ? Date().timeIntervalSince(epoch) * 0.055 : 0)
        let radius: Double = Double(min(size.width, size.height)) * 0.395 * zoom
        let centerX: Double = Double(size.width) / 2, centerY: Double = Double(size.height) / 2
        let sinTilt: Double = sin(tilt), cosTilt: Double = cos(tilt)
        var nearest: (Int, Double)?
        for (index, site) in GlobeDrawing.sites.enumerated() {
            let a: Double = site.0 * Double.pi / 180 + rotation
            let b: Double = site.1 * Double.pi / 180
            let x: Double = cos(b) * sin(a), y: Double = sin(b), z: Double = cos(b) * cos(a)
            let depth: Double = y * sinTilt + z * cosTilt
            guard depth > 0 else { continue }
            let px: Double = centerX + x * radius
            let py: Double = centerY - (y * cosTilt - z * sinTilt) * radius
            let distance: Double = hypot(px - Double(location.x), py - Double(location.y))
            if distance < 18 && distance < (nearest?.1 ?? .infinity) { nearest = (index, distance) }
        }
        selectedSite = nearest?.0 == selectedSite ? nil : nearest?.0
    }

    private func reset() {
        yaw = 0; tilt = -0.19; zoom = 1; selectedSite = nil
        spinOffset = 0.4; epoch = Date(); spinning = true
    }
}

private enum GlobeDrawing {
    static let sites: [(Double, Double)] = [(-87, 42), (-122, 38), (-74, 41), (-46, -24), (0, 52), (14, 50), (78, 23), (139, 36), (151, -34), (18, -34), (104, 1)]
    private static let land: [[[Double]]] = {
        guard let url = Console.assets.url(forResource: "land", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rings = try? JSONDecoder().decode([[[Double]]].self, from: data) else { return [] }
        return rings
    }()

    static func draw(in context: inout GraphicsContext, size: CGSize, rotation: Double,
                     tilt: Double, zoom: Double, selectedSite: Int?) {
        let radius: Double = Double(min(size.width, size.height)) * 0.395 * zoom
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rim = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(rim, with: .radialGradient(Gradient(colors: [Console.blue.opacity(0.09), .clear]),
                                               center: center, startRadius: 0, endRadius: radius))
        context.stroke(rim, with: .color(Console.blueBright.opacity(0.85)), lineWidth: 0.8)
        func project(_ lon: Double, _ lat: Double, lift: Double = 1) -> (CGPoint, Double) {
            let a = lon * .pi / 180 + rotation, b = lat * .pi / 180
            let x = cos(b) * sin(a), y = sin(b), z = cos(b) * cos(a)
            return (CGPoint(x: center.x + x * radius * lift,
                            y: center.y - (y * cos(tilt) - z * sin(tilt)) * radius * lift),
                    y * sin(tilt) + z * cos(tilt))
        }
        func line(_ coordinates: [[Double]], opacity: Double, width: Double) {
            var path = Path(); var penDown = false
            for pair in coordinates where pair.count >= 2 {
                let (point, depth) = project(pair[0], pair[1])
                if depth < 0 { penDown = false; continue }
                if penDown { path.addLine(to: point) } else { path.move(to: point); penDown = true }
            }
            context.stroke(path, with: .color(Console.blueBright.opacity(opacity)), lineWidth: width)
        }
        for latitude in stride(from: -60.0, through: 60, by: 30) {
            line(stride(from: -180.0, through: 180, by: 3).map { [$0, latitude] }, opacity: 0.28, width: 0.6)
        }
        for longitude in stride(from: -180.0, to: 180, by: 30) {
            line(stride(from: -90.0, through: 90, by: 3).map { [longitude, $0] }, opacity: 0.28, width: 0.6)
        }
        for ring in Self.land { line(ring, opacity: 0.85, width: 0.65) }
        // Spherical great-circle arcs share the rotation of the land and grid.
        let sites = Self.sites
        for index in sites.indices {
            let a = sites[index], b = sites[(index + 3) % sites.count]
            func vector(_ p: (Double, Double)) -> SIMD3<Double> {
                let lon = p.0 * .pi / 180, lat = p.1 * .pi / 180
                return SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
            }
            let u = vector(a), v = vector(b)
            let omega = acos(min(1, max(-1, u.x * v.x + u.y * v.y + u.z * v.z)))
            var path = Path(); var down = false
            for step in 0...60 {
                let t = Double(step) / 60
                let p = (u * sin((1-t)*omega) + v * sin(t*omega)) / sin(omega)
                let lon = atan2(p.y, p.x) * 180 / .pi, lat = asin(p.z) * 180 / .pi
                let lift: Double = 1.0 + sin(t * Double.pi) * 0.09
                let (point, depth) = project(lon, lat, lift: lift)
                if depth < -0.03 { down = false; continue }
                if down { path.addLine(to: point) } else { path.move(to: point); down = true }
            }
            let highlighted = selectedSite == index || selectedSite == (index + 3) % sites.count
            context.stroke(path, with: .color(highlighted ? Console.white.opacity(0.95) : Console.blue.opacity(selectedSite == nil ? 0.7 : 0.22)),
                           lineWidth: highlighted ? 1.6 : 0.9)
            let (point, depth) = project(a.0, a.1)
            if depth > 0 {
                if selectedSite == index {
                    context.fill(Path(ellipseIn: CGRect(x: point.x-13, y: point.y-13, width: 26, height: 26)),
                                 with: .color(Console.blueBright.opacity(0.25)))
                }
                for (r, opacity) in [(8.0, 0.3), (4.5, 0.7)] {
                    context.stroke(Path(ellipseIn: CGRect(x: point.x-r, y: point.y-r, width: r*2, height: r*2)),
                                   with: .color(Console.blueBright.opacity(opacity)), lineWidth: 0.7)
                }
                context.fill(Path(ellipseIn: CGRect(x: point.x-2, y: point.y-2, width: 4, height: 4)), with: .color(Console.blueBright))
            }
        }
        var ticks = Path()
        for i in 0..<120 {
            let angle = Double(i) / 120 * .pi * 2
            let inner = radius * 1.06, outer = radius * (i % 5 == 0 ? 1.083 : 1.068)
            let dx: Double = cos(angle), dy: Double = sin(angle)
            let innerPoint = CGPoint(x: Double(center.x) + dx * inner, y: Double(center.y) + dy * inner)
            let outerPoint = CGPoint(x: Double(center.x) + dx * outer, y: Double(center.y) + dy * outer)
            ticks.move(to: innerPoint)
            ticks.addLine(to: outerPoint)
        }
        context.stroke(ticks, with: .color(Console.blueBright.opacity(0.6)), lineWidth: 0.7)
    }
}
