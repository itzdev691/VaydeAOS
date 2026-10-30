import Foundation
import CoreGraphics
import Testing
@testable import VaydeAOSCore

@Suite("Connection geography")
struct ConnectionProjectionTests {
    private let size = CGSize(width: 600, height: 400)

    @Test func fullWorldFitsBothWideAndTallPanels() {
        for size in [size, CGSize(width: 320, height: 700), CGSize(width: 900, height: 220)] {
            let projection = ConnectionProjection(isWorldMap: true, size: size, rotation: 0.4, tilt: -0.19, zoom: 1)
            let bounds = projection.mapBounds
            #expect(bounds.width == bounds.height * 2)
            #expect(bounds.minX >= 0 && bounds.maxX <= size.width)
            #expect(bounds.minY >= 0 && bounds.maxY <= size.height)
            let north = projection.project(longitude: 0, latitude: 90)
            let south = projection.project(longitude: 0, latitude: -90)
            #expect(abs(north.point.y - bounds.minY) < 0.000_001)
            #expect(abs(south.point.y - bounds.maxY) < 0.000_001)
        }
    }

    @Test func mapWrapsLongitudeAfterMultipleTurns() {
        let original = ConnectionProjection(isWorldMap: true, size: size, rotation: 0.4, tilt: -0.19, zoom: 1)
        for turns in [-7.0, -1, 0, 1, 8] {
            let rotated = ConnectionProjection(isWorldMap: true, size: size, rotation: 0.4 + turns * 2 * .pi, tilt: -0.19, zoom: 1)
            for longitude in [-179.0, -87, 0, 139, 179] {
                let a = original.project(longitude: longitude, latitude: 42)
                let b = rotated.project(longitude: longitude, latitude: 42)
                #expect(abs(a.point.x - b.point.x) < 0.000_001)
                #expect(b.point.x >= rotated.mapBounds.minX && b.point.x <= rotated.mapBounds.maxX)
            }
        }
    }

    @Test func mapSelectionFollowsPanAndZoomForEverySite() {
        let sites = [(-87.0, 42.0), (139, 36), (151, -34), (18, -34)]
        for zoom in [0.75, 1, 1.5] {
            let projection = ConnectionProjection(isWorldMap: true, size: size, rotation: 2.1, tilt: 0.6, zoom: zoom)
            for (index, site) in sites.enumerated() {
                let projected = projection.project(longitude: site.0, latitude: site.1)
                #expect(projected.depth > 0)
                #expect(projection.nearestSite(to: projected.point, sites: sites) == index)
            }
            #expect(projection.nearestSite(to: CGPoint(x: -100, y: -100), sites: sites) == nil)
        }
    }

    @Test func globeSelectionExcludesFarHemisphere() {
        let projection = ConnectionProjection(isWorldMap: false, size: size, rotation: 0, tilt: 0, zoom: 1.5)
        let sites = [(0.0, 0.0), (180, 0), (45, 20)]
        let hidden = projection.project(longitude: 180, latitude: 0)
        #expect(hidden.depth < 0)
        #expect(projection.nearestSite(to: hidden.point, sites: [sites[1]]) == nil)
        let visible = projection.project(longitude: 45, latitude: 20)
        #expect(projection.nearestSite(to: visible.point, sites: sites) == 2)
    }
}
