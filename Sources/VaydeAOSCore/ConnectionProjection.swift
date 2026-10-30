import Foundation
import CoreGraphics

/// Shared geographic projection for drawing and selecting connection nodes.
public struct ConnectionProjection {
    public let isWorldMap: Bool
    public let size: CGSize
    public let rotation: Double
    public let tilt: Double
    public let zoom: Double

    public init(isWorldMap: Bool, size: CGSize, rotation: Double, tilt: Double, zoom: Double) {
        self.isWorldMap = isWorldMap
        self.size = size
        self.rotation = rotation
        self.tilt = tilt
        self.zoom = zoom
    }

    public var radius: Double { min(size.width, size.height) * 0.395 * zoom }

    public var mapBounds: CGRect {
        let width: Double = min(size.width * 0.88, size.height * 1.65) * zoom
        let height: Double = width / 2
        let y: Double = (size.height - height) / 2 + (tilt + 0.19) * height / Double.pi
        return CGRect(x: (size.width - width) / 2,
                      y: y,
                      width: width, height: height)
    }

    public func project(longitude: Double, latitude: Double, lift: Double = 1) -> (point: CGPoint, depth: Double) {
        if isWorldMap {
            let bounds = mapBounds
            // Keep a complete longitude range visible while panning across the date line.
            let turns = longitude / 360 + (rotation - 0.4) / (2 * .pi) + 0.5
            let x = turns - floor(turns)
            return (CGPoint(x: bounds.minX + x * bounds.width,
                            y: bounds.midY - latitude / 180 * bounds.height), 1)
        }
        let a = longitude * .pi / 180 + rotation, b = latitude * .pi / 180
        let x = cos(b) * sin(a), y = sin(b), z = cos(b) * cos(a)
        return (CGPoint(x: size.width / 2 + x * radius * lift,
                        y: size.height / 2 - (y * cos(tilt) - z * sin(tilt)) * radius * lift),
                y * sin(tilt) + z * cos(tilt))
    }

    public func nearestSite(to location: CGPoint, sites: [(Double, Double)], within distance: Double = 18) -> Int? {
        var nearest: (index: Int, distance: Double)?
        for (index, site) in sites.enumerated() {
            let projected = project(longitude: site.0, latitude: site.1)
            guard projected.depth > 0 else { continue }
            let separation = Double(hypot(projected.point.x - location.x, projected.point.y - location.y))
            if separation < distance && separation < (nearest?.distance ?? .infinity) {
                nearest = (index, separation)
            }
        }
        return nearest?.index
    }
}
