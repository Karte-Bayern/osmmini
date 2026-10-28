import Foundation
import SwiftUI
import Testing

@testable import OSMmini

private func continuousCoordinate(
  at point: CGPoint, center: Coordinate, zoom: Double, size: CGSize
) -> Coordinate {
  let origin = WebMercator.world(center, displayZoom: zoom)
  return WebMercator.coordinate(
    CGPoint(x: origin.x + point.x - size.width / 2, y: origin.y + point.y - size.height / 2),
    displayZoom: zoom)
}

@Test func continuousZoomKeepsTheCursorAnchorThroughSmallStepsAndTileBoundaries() throws {
  let size = CGSize(width: 982, height: 671)
  for initialCenter in [
    Coordinate(lat: 48.5, lon: 12.5), Coordinate(lat: 78, lon: -12),
    Coordinate(lat: 0, lon: 179.999), Coordinate(lat: -48, lon: -179.999),
  ] {
    for anchor in [CGPoint(x: 32, y: 44), CGPoint(x: 939, y: 633)] {
      let target = continuousCoordinate(at: anchor, center: initialCenter, zoom: 12.8, size: size)
      var viewport = OfflineMapContinuousViewport(center: initialCenter, zoom: 12.8)
      for zoom in stride(from: 12.85, through: 14.15, by: 0.05) {
        viewport = try #require(
          OfflineMapContinuousViewport.zooming(
            center: viewport.center, from: viewport.zoom, to: zoom, at: anchor, size: size,
            minZoom: 5, maxZoom: 18))
        let offset = WebMercator.offset(target, from: viewport.center, displayZoom: viewport.zoom)
        #expect(abs(offset.x + size.width / 2 - anchor.x) < 0.000_01)
        #expect(abs(offset.y + size.height / 2 - anchor.y) < 0.000_01)
      }
      let restored = try #require(
        OfflineMapContinuousViewport.zooming(
          center: viewport.center, from: viewport.zoom, to: 12.8, at: anchor, size: size))
      let offset = WebMercator.offset(initialCenter, from: restored.center, displayZoom: 12.8)
      #expect(abs(offset.x) < 0.000_01)
      #expect(abs(offset.y) < 0.000_01)
    }
  }
}

@Test func continuousZoomLimitsClampBeforeAnchoringAndRejectInvalidInput() throws {
  let center = Coordinate(lat: 48.5, lon: 12.5)
  let size = CGSize(width: 800, height: 600)
  let anchor = CGPoint(x: 720, y: 90)
  let atMaximum = try #require(
    OfflineMapContinuousViewport.zooming(
      center: center, from: 18, to: 25, at: anchor, size: size, minZoom: 5, maxZoom: 18))
  #expect(atMaximum.center == center && atMaximum.zoom == 18)
  let atMinimum = try #require(
    OfflineMapContinuousViewport.zooming(
      center: center, from: 5, to: -25, at: anchor, size: size, minZoom: 5, maxZoom: 18))
  #expect(atMinimum.center == center && atMinimum.zoom == 5)
  let fixed = continuousCoordinate(at: anchor, center: center, zoom: 17.8, size: size)
  let clamped = try #require(
    OfflineMapContinuousViewport.zooming(
      center: center, from: 17.8, to: 25, at: anchor, size: size, minZoom: 5, maxZoom: 18))
  let offset = WebMercator.offset(fixed, from: clamped.center, displayZoom: clamped.zoom)
  #expect(clamped.zoom == 18)
  #expect(abs(offset.x + size.width / 2 - anchor.x) < 0.000_01)
  #expect(abs(offset.y + size.height / 2 - anchor.y) < 0.000_01)

  for invalid in [Double.nan, .infinity, -.infinity] {
    #expect(
      OfflineMapContinuousViewport.zooming(
        center: center, from: 12, to: invalid, at: anchor, size: size) == nil)
    #expect(
      OfflineMapContinuousViewport.zooming(
        center: center, from: invalid, to: 12, at: anchor, size: size) == nil)
  }
  #expect(
    OfflineMapContinuousViewport.zooming(
      center: center, from: 12, to: 12.1, at: anchor, size: .zero) == nil)
  #expect(
    OfflineMapContinuousViewport.zooming(
      center: center, from: 12, to: 12.1, at: anchor, size: size, minZoom: 19, maxZoom: 18) == nil)
  #expect(
    OfflineMapContinuousViewport.focusing(
      center, currentZoom: 14.37, minZoom: 5, maxZoom: 18)?.zoom == 14.37)
  #expect(
    OfflineMapContinuousViewport.focusing(
      center, currentZoom: 14.37, minimumZoom: 16, minZoom: 5, maxZoom: 18)?.zoom == 16)
}

@Test func zoomingBesideTheWorldKeepsTheProjectedAnchorWithoutClampingItToAPole() throws {
  let size = CGSize(width: 800, height: 600)
  for (center, oldZoom, zoom, anchor) in [
    (Coordinate(lat: 0, lon: 0), 0.0, 0.5, CGPoint(x: 700, y: 10)),
    (Coordinate(lat: 0, lon: 0), 0.0, 0.5, CGPoint(x: 100, y: 590)),
    (Coordinate(lat: 83, lon: 179.9), 3.0, 3.5, CGPoint(x: 700, y: 10)),
    (Coordinate(lat: -83, lon: -179.9), 3.0, 3.5, CGPoint(x: 100, y: 590)),
  ] {
    let origin = WebMercator.world(center, displayZoom: oldZoom)
    let offset = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
    let anchorY = origin.y + offset.y
    #expect(anchorY < 0 || anchorY > 256 * exp2(oldZoom))
    let viewport = try #require(
      OfflineMapContinuousViewport.zooming(
        center: center, from: oldZoom, to: zoom, at: anchor, size: size))
    // A visible point must scale about the pointer even when the pointer itself
    // has no geographic coordinate outside the Mercator world.
    let before = WebMercator.offset(center, from: center, displayZoom: oldZoom)
    let after = WebMercator.offset(center, from: viewport.center, displayZoom: zoom)
    let scale = exp2(zoom - oldZoom)
    #expect(abs(after.x - ((before.x - offset.x) * scale + offset.x)) < 0.000_001)
    #expect(abs(after.y - ((before.y - offset.y) * scale + offset.y)) < 0.000_001)
  }
}

@Test func continuousProjectionKeepsTilesRoutesAndMarkersAlignedAtFractionalZoom() throws {
  let size = CGSize(width: 900, height: 600)
  let key = MapTileKey(z: 14, x: 8760, y: 5670)
  let local = CGPoint(x: 116, y: 144)
  let coordinate = WebMercator.coordinate(
    CGPoint(x: CGFloat(key.x) * 256 + local.x, y: CGFloat(key.y) * 256 + local.y), zoom: key.z)
  let center = Coordinate(lat: coordinate.lat - 0.0001, lon: coordinate.lon + 0.0001)
  let route = try PreparedMapRoute([
    coordinate, Coordinate(lat: coordinate.lat + 0.001, lon: coordinate.lon + 0.001),
  ])
  for zoom in [14.01, 14.25, 14.99, 15.01, 17.625] {
    let plan = OfflineMapTilePlan.make(
      center: center, displayZoom: zoom, size: size, baseMaxZoom: 14)
    let tile = try #require(plan.base.first { $0.key == key })
    let origin = tile.origin(center: center, displayZoom: zoom, size: size)
    let scale = tile.scale(atDisplayZoom: zoom)
    let tilePoint = CGPoint(x: origin.x + local.x * scale, y: origin.y + local.y * scale)
    let offset = WebMercator.offset(coordinate, from: center, displayZoom: zoom)
    let marker = CGPoint(x: offset.x + size.width / 2, y: offset.y + size.height / 2)
    #expect(abs(tilePoint.x - marker.x) < 0.000_001)
    #expect(abs(tilePoint.y - marker.y) < 0.000_001)

    let routePlacement = try #require(
      route.visible(center: center, displayZoom: zoom, size: size).first)
    var firstPoint: CGPoint?
    // swift-format-ignore: ReplaceForEachWithForLoop
    route.chunks[routePlacement.index].path.forEach { element in
      if firstPoint == nil, case .move(let point) = element { firstPoint = point }
    }
    let point = try #require(firstPoint)
    #expect(abs(routePlacement.origin.x + point.x * routePlacement.scale - marker.x) < 0.000_001)
    #expect(abs(routePlacement.origin.y + point.y * routePlacement.scale - marker.y) < 0.000_001)
  }
}

@Test func fractionalMapSelectionKeepsItsStreetToleranceInPhysicalPoints() throws {
  let key = MapTileKey(z: 14, x: 8760, y: 5670)
  let center = WebMercator.coordinate(
    CGPoint(x: key.x * 256 + 128, y: key.y * 256 + 128), zoom: key.z)
  let size = CGSize(width: 300, height: 300)
  let tile = try PreparedMapTile(
    VectorTile(features: [
      VectorFeature(
        layer: "transportation", kind: 2, extent: 256, class: "residential",
        name: "Teststraße", paths: [[[0, 128], [256, 128]]]),
    ]))
  for zoom in [14.01, 14.75, 15.25, 17.875] {
    let placement = OfflineMapTilePlacement(key: key, worldX: key.x)
    for (distance, expected) in [(15.0, "Teststraße" as String?), (17.0, nil)] {
      let selection = try #require(
        OfflineMapSelection.select(
          at: CGPoint(x: size.width / 2, y: size.height / 2 + distance), center: center,
          displayZoom: zoom, size: size, placements: [placement], baseZoom: key.z,
          tile: { $0 == key ? tile : nil }))
      #expect(selection.feature?.name == expected)
      if expected != nil {
        #expect(abs(selection.coordinate.lat - center.lat) < 0.000_001)
        #expect(abs(selection.coordinate.lon - center.lon) < 0.000_001)
      }
    }
  }
}

@Test func fractionalZoomScaleAccuracyAndTileRequestsUseTheSameContinuousProjection() throws {
  let latitude = 48.5
  let base = try #require(WebMercator.metersPerPixel(latitude: latitude, displayZoom: 13.25))
  let closer = try #require(WebMercator.metersPerPixel(latitude: latitude, displayZoom: 13.75))
  #expect(abs(base / closer - sqrt(2)) < 0.000_001)
  let accuracy = try #require(
    OfflineMapLocationAccuracy.radius(35, latitude: latitude, displayZoom: 13.75))
  #expect(abs(accuracy * closer - 35) < 0.000_001)
  let scale = try #require(OfflineMapScale.make(latitude: latitude, displayZoom: 13.75))
  #expect(scale.width <= 112 && abs(scale.width * closer - scale.meters) < 0.000_001)

  for zoom in [0.25, 14.99, 15.01, 18.75] {
    let plan = OfflineMapTilePlan.make(
      center: Coordinate(lat: latitude, lon: 179.999), displayZoom: zoom,
      size: CGSize(width: 3_000, height: 3_000), baseMaxZoom: 14)
    #expect(!plan.base.isEmpty)
    #expect(plan.keys.count <= PreparedMapTileCache.capacity)
    #expect(plan.baseZoom == min(Int(floor(zoom)), 14))
    #expect(plan.base.allSatisfy { $0.key.z == plan.baseZoom })
  }
  #expect(
    OfflineMapTilePlacement.visible(
      center: Coordinate(lat: latitude, lon: 12.5), displayZoom: .nan,
      size: CGSize(width: 500, height: 500)).isEmpty)
  #expect(OfflineMapScale.make(latitude: latitude, displayZoom: .infinity) == nil)
}
