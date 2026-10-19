import Foundation
import Testing

@testable import OSMmini

@Test func doubleTapZoomKeepsTappedCoordinateUnderTheFinger() throws {
  let size = CGSize(width: 390, height: 600)
  for center in [
    Coordinate(lat: 48.5, lon: 12.5), Coordinate(lat: 78, lon: -12),
    Coordinate(lat: 0, lon: 179.999),
  ] {
    for anchor in [CGPoint(x: 40, y: 50), CGPoint(x: 350, y: 550)] {
      let origin = WebMercator.world(center, zoom: 12)
      let coordinate = WebMercator.coordinate(
        CGPoint(x: origin.x + anchor.x - size.width / 2, y: origin.y + anchor.y - size.height / 2),
        zoom: 12)
      let viewport = try #require(
        OfflineMapViewport.zooming(center: center, from: 12, to: 13, at: anchor, size: size))
      let offset = WebMercator.offset(coordinate, from: viewport.center, zoom: viewport.zoom)
      #expect(abs(offset.x + size.width / 2 - anchor.x) < 0.000_01)
      #expect(abs(offset.y + size.height / 2 - anchor.y) < 0.000_01)
    }
  }
}

@Test func anchoredZoomRoundTripAndCenteredZoomKeepTheViewportStable() throws {
  let center = Coordinate(lat: 48.5, lon: 12.5)
  let size = CGSize(width: 844, height: 290)
  let midpoint = CGPoint(x: size.width / 2, y: size.height / 2)
  let centered = try #require(
    OfflineMapViewport.zooming(center: center, from: 14, to: 18, at: midpoint, size: size))
  #expect(abs(centered.center.lat - center.lat) < 0.000_001)
  #expect(abs(centered.center.lon - center.lon) < 0.000_001)
  let anchor = CGPoint(x: 33, y: 270)
  let closer = try #require(
    OfflineMapViewport.zooming(center: center, from: 14, to: 15, at: anchor, size: size))
  let restored = try #require(
    OfflineMapViewport.zooming(center: closer.center, from: 15, to: 14, at: anchor, size: size))
  #expect(abs(restored.center.lat - center.lat) < 0.000_001)
  #expect(abs(restored.center.lon - center.lon) < 0.000_001)
  #expect(
    OfflineMapViewport.zooming(center: center, from: 14, to: 15, at: anchor, size: .zero) == nil)
}

@Test func mapScaleTracksLatitudeAndZoomWithoutExceedingItsAvailableWidth() throws {
  for latitude in [0.0, 48.5, 80.0, 90.0, -80.0] {
    for zoom in 5...18 {
      let scale = try #require(OfflineMapScale.make(latitude: latitude, zoom: zoom))
      let metersPerPixel = try #require(WebMercator.metersPerPixel(latitude: latitude, zoom: zoom))
      #expect(scale.width > 0 && scale.width <= 112.000_001)
      #expect(abs(scale.width * metersPerPixel - scale.meters) < 0.000_001)
      #expect(scale.label.hasSuffix(scale.meters >= 1_000 ? " km" : " m"))
    }
  }
  let equator = try #require(OfflineMapScale.make(latitude: 0, zoom: 12))
  let northern = try #require(OfflineMapScale.make(latitude: 60, zoom: 12))
  let zoomed = try #require(OfflineMapScale.make(latitude: 0, zoom: 13))
  // Rounded 1/2/5 distances can remain the same across one zoom level; their
  // screen width must still track the physical scale exactly.
  #expect(northern.meters <= equator.meters)
  #expect(zoomed.meters <= equator.meters)
  #expect(abs(northern.width / northern.meters - 2 * equator.width / equator.meters) < 0.000_001)
  #expect(abs(zoomed.width / zoomed.meters - 2 * equator.width / equator.meters) < 0.000_001)
  #expect(OfflineMapScale.make(latitude: .nan, zoom: 12) == nil)
  #expect(OfflineMapScale.make(latitude: 100, zoom: 12) == nil)
  #expect(OfflineMapScale.make(latitude: 48, zoom: -1) == nil)
  #expect(OfflineMapScale.make(latitude: 48, zoom: 12, maximumWidth: 0) == nil)
}
