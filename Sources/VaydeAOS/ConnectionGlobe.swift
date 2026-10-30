import SwiftUI
import VaydeAOSCore

/// Geographic backdrop and illustrative connections, independent of measured traffic.
struct ConnectionGlobe: View {
    var isActive: Bool
    @AppStorage("idle.networkWorldMap") private var isWorldMap = false
    @State private var motion = ConnectionMotion(at: Date.timeIntervalSinceReferenceDate)
    @State private var zoom = 1.0
    @State private var spinning = true
    @GestureState private var dragging = false
    @State private var lastDrag = CGSize.zero
    @State private var selectedSite: Int?
    @GestureState private var magnification = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let moving = canAnimate
        GeometryReader { geometry in
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !moving)) { timeline in
            Canvas { context, size in
                let position = motion.position(at: timeline.date.timeIntervalSinceReferenceDate)
                GlobeDrawing.draw(in: &context, size: size, rotation: position.rotation, tilt: position.tilt,
                                  zoom: effectiveZoom, selectedSite: selectedSite, isWorldMap: isWorldMap)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let dx = Double(value.translation.width - lastDrag.width)
                let dy = Double(value.translation.height - lastDrag.height)
                let scale = dragScale(size: geometry.size)
                // macOS gesture timestamps can use system uptime. Motion and
                // TimelineView must share Date's reference clock.
                motion.drag(rotation: dx * scale.width, tilt: dy * scale.height,
                            at: Date.timeIntervalSinceReferenceDate)
                lastDrag = value.translation
            }.onEnded { value in
                let now = Date.timeIntervalSinceReferenceDate
                let scale = dragScale(size: geometry.size)
                motion.drag(rotation: (value.translation.width - lastDrag.width) * scale.width,
                            tilt: (value.translation.height - lastDrag.height) * scale.height,
                            at: now)
                motion.endDrag(at: now)
                clearDrag()
            })
        .gesture(MagnificationGesture().updating($magnification) { value, state, _ in state = value }
            .onEnded { zoom = min(1.5, max(0.75, zoom * $0)) })
        .onTapGesture(count: 2) { reset() }
        .onTapGesture { location in selectSite(at: location, size: geometry.size) }
        .clipped()
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 15) {
                Button { isWorldMap.toggle() } label: {
                    Image(systemName: isWorldMap ? "globe" : "map")
                        .frame(width: 16, height: 16)
                }
                    .accessibilityLabel(isWorldMap ? "Switch to globe" : "Switch to world map")
                    .help(isWorldMap ? "Switch to globe" : "Switch to world map")
                Button { spinning.toggle() } label: { Image(systemName: spinning ? "pause" : "play") }
                    .accessibilityLabel(spinning ? "Pause \(viewName) motion" : "Resume \(viewName) motion")
                Button { zoom = max(0.75, zoom / 1.12) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Zoom out \(viewName)")
                Button { zoom = min(1.5, zoom * 1.12) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Zoom in \(viewName)")
                Button { reset() } label: { Image(systemName: "scope") }.accessibilityLabel("Reset \(viewName) view")
            }.buttonStyle(.plain).font(Console.mono(11)).foregroundStyle(Console.blueBright)
                .padding(12).background(Console.panel.opacity(0.9)).padding(8)
        }
        .onChange(of: moving) { active in
            motion.setAdvancing(active, at: Date.timeIntervalSinceReferenceDate)
        }
        .onChange(of: dragging) { active in
            if !active { motion.endDrag(at: Date.timeIntervalSinceReferenceDate); clearDrag() }
        }
        .onAppear { motion.setAdvancing(moving, at: Date.timeIntervalSinceReferenceDate) }
        .onDisappear {
            motion.endDrag(at: Date.timeIntervalSinceReferenceDate)
            motion.setAdvancing(false, at: Date.timeIntervalSinceReferenceDate)
            clearDrag()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interactive \(viewName) with illustrative connections")
        .help("\(isWorldMap ? "Drag to pan the map." : "Drag to rotate and tilt.") Pinch or use +/- to zoom. Click a connection node to highlight its links. Double-click or use reset to restore the view.")
    }

    private var viewName: String { isWorldMap ? "world map" : "globe" }
    private var canAnimate: Bool { isActive && !reduceMotion && scenePhase == .active && spinning }
    private var effectiveZoom: Double { min(1.5, max(0.75, zoom * magnification)) }

    private func projection(size: CGSize) -> ConnectionProjection {
        let position = motion.position(at: Date.timeIntervalSinceReferenceDate)
        return ConnectionProjection(isWorldMap: isWorldMap, size: size,
                                    rotation: position.rotation, tilt: position.tilt, zoom: effectiveZoom)
    }

    private func dragScale(size: CGSize) -> CGSize {
        guard isWorldMap else { return CGSize(width: 0.006, height: 0.0045) }
        let bounds = projection(size: size).mapBounds
        return CGSize(width: 2 * .pi / max(1, bounds.width), height: .pi / max(1, bounds.height))
    }

    private func clearDrag() {
        lastDrag = .zero
    }

    private func selectSite(at location: CGPoint, size: CGSize) {
        let nearest = projection(size: size).nearestSite(to: location, sites: GlobeDrawing.sites)
        selectedSite = nearest == selectedSite ? nil : nearest
    }

    private func reset() {
        zoom = 1; selectedSite = nil; spinning = true
        motion = ConnectionMotion(at: Date.timeIntervalSinceReferenceDate)
        motion.setAdvancing(canAnimate, at: Date.timeIntervalSinceReferenceDate)
        clearDrag()
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
                     tilt: Double, zoom: Double, selectedSite: Int?, isWorldMap: Bool) {
        let projection = ConnectionProjection(isWorldMap: isWorldMap, size: size, rotation: rotation, tilt: tilt, zoom: zoom)
        let radius = projection.radius
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rim = isWorldMap ? Path(projection.mapBounds) : Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(rim, with: .radialGradient(Gradient(colors: [Console.blue.opacity(0.09), .clear]),
                                               center: center, startRadius: 0, endRadius: radius))
        if !isWorldMap {
            context.stroke(rim, with: .color(Console.blueBright.opacity(0.85)), lineWidth: 0.8)
        }
        var geography = context
        if isWorldMap { geography.clip(to: rim) }
        func project(_ lon: Double, _ lat: Double, lift: Double = 1) -> (CGPoint, Double) {
            projection.project(longitude: lon, latitude: lat, lift: lift)
        }
        func append(_ point: CGPoint, to path: inout Path, previous: CGPoint?) {
            guard let previous else { path.move(to: point); return }
            let bounds = projection.mapBounds
            if isWorldMap && abs(point.x - previous.x) > bounds.width / 2 {
                // Split at the map seam instead of drawing a line across the world.
                let exitsRight = point.x < previous.x
                let edge = exitsRight ? bounds.maxX : bounds.minX
                let wrappedX = point.x + (exitsRight ? bounds.width : -bounds.width)
                let fraction = (edge - previous.x) / (wrappedX - previous.x)
                let y = previous.y + (point.y - previous.y) * fraction
                path.addLine(to: CGPoint(x: edge, y: y))
                path.move(to: CGPoint(x: exitsRight ? bounds.minX : bounds.maxX, y: y))
            }
            path.addLine(to: point)
        }
        func line(_ coordinates: [[Double]], opacity: Double, width: Double) {
            var path = Path(); var previous: CGPoint?
            for pair in coordinates where pair.count >= 2 {
                let (point, depth) = project(pair[0], pair[1])
                if depth < 0 { previous = nil; continue }
                append(point, to: &path, previous: previous)
                previous = point
            }
            geography.stroke(path, with: .color(Console.blueBright.opacity(opacity)), lineWidth: width)
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
            var path = Path(); var previous: CGPoint?
            for step in 0...60 {
                let t = Double(step) / 60
                let p = (u * sin((1-t)*omega) + v * sin(t*omega)) / sin(omega)
                let lon = atan2(p.y, p.x) * 180 / .pi, lat = asin(p.z) * 180 / .pi
                let lift: Double = 1.0 + sin(t * Double.pi) * 0.09
                let (point, depth) = project(lon, lat, lift: lift)
                if depth < -0.03 { previous = nil; continue }
                append(point, to: &path, previous: previous)
                previous = point
            }
            let highlighted = selectedSite == index || selectedSite == (index + 3) % sites.count
            geography.stroke(path, with: .color(highlighted ? Console.white.opacity(0.95) : Console.blue.opacity(selectedSite == nil ? 0.7 : 0.22)),
                           lineWidth: highlighted ? 1.6 : 0.9)
            let (point, depth) = project(a.0, a.1)
            if depth > 0 {
                if selectedSite == index {
                    geography.fill(Path(ellipseIn: CGRect(x: point.x-13, y: point.y-13, width: 26, height: 26)),
                                 with: .color(Console.blueBright.opacity(0.25)))
                }
                for (r, opacity) in [(8.0, 0.3), (4.5, 0.7)] {
                    geography.stroke(Path(ellipseIn: CGRect(x: point.x-r, y: point.y-r, width: r*2, height: r*2)),
                                   with: .color(Console.blueBright.opacity(opacity)), lineWidth: 0.7)
                }
                geography.fill(Path(ellipseIn: CGRect(x: point.x-2, y: point.y-2, width: 4, height: 4)), with: .color(Console.blueBright))
            }
        }
        guard !isWorldMap else { return }
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
