import Foundation
import SwiftUI
import Testing

@testable import OSMmini

private func selectionRoad(_ name: String = "Teststraße", paths: [[[Int]]], extent: Int = 256)
  -> VectorFeature
{
  VectorFeature(
    layer: "transportation", kind: 2, extent: extent, class: "residential", name: name,
    paths: paths)
}

private func selectionPOI(
  _ name: String = "Café am Markt", at point: [Int] = [128, 128],
  details: PlaceDetails? = nil
) -> VectorFeature {
  VectorFeature(
    layer: "poi", kind: 1, extent: 256, class: "cafe", name: name, paths: [[point]],
    sourceIdentity: "node/42", details: details)
}

private func selectionContext(sourceZoom: Int = 14) -> (
  key: MapTileKey, center: Coordinate, placement: OfflineMapTilePlacement
) {
  let tile = Int(exp2(Double(sourceZoom - 1)))
  let key = MapTileKey(z: sourceZoom, x: tile, y: tile)
  return (
    key,
    WebMercator.coordinate(CGPoint(x: tile * 256 + 128, y: tile * 256 + 128), zoom: sourceZoom),
    OfflineMapTilePlacement(key: key, worldX: tile)
  )
}

private func selected(
  _ tile: PreparedMapTile, at point: CGPoint, sourceZoom: Int = 14, zoom: Int? = nil
) throws -> MapSelection {
  let context = selectionContext(sourceZoom: sourceZoom)
  return try #require(
    OfflineMapSelection.select(
      at: point, center: context.center, zoom: zoom ?? sourceZoom,
      size: CGSize(width: 256, height: 256), placements: [context.placement],
      tile: { $0 == context.key ? tile : nil }))
}

@Test func streetTapUsesNearestGeometryInsteadOfTheLabelAnchor() throws {
  let tile = try PreparedMapTile(
    VectorTile(features: [selectionRoad(paths: [[[0, 128], [256, 128]]])]))
  let selection = try selected(tile, at: CGPoint(x: 220, y: 140))
  let key = selectionContext().key
  let expected = WebMercator.coordinate(
    CGPoint(x: key.x * 256 + 220, y: key.y * 256 + 128), zoom: key.z)
  #expect(selection.feature?.name == "Teststraße")
  #expect(selection.feature?.kind == "street")
  #expect(selection.feature?.category == "residential")
  #expect(selection.feature?.sourceIdentity == nil)
  #expect(abs(selection.coordinate.lat - expected.lat) < 0.000_000_1)
  #expect(abs(selection.coordinate.lon - expected.lon) < 0.000_000_1)
}

@Test func streetSelectionDoesNotJoinSeparatePathsAndChoosesTheClosestStreet() throws {
  let separated = try PreparedMapTile(
    VectorTile(features: [
      selectionRoad(paths: [[[0, 30], [100, 30]], [[180, 230], [256, 230]]])
    ]))
  #expect(try selected(separated, at: CGPoint(x: 140, y: 130)).feature == nil)

  let parallel = try PreparedMapTile(
    VectorTile(features: [
      selectionRoad("Nordstraße", paths: [[[0, 100], [256, 100]]]),
      selectionRoad("Südstraße", paths: [[[0, 120], [256, 120]]]),
    ]))
  #expect(try selected(parallel, at: CGPoint(x: 128, y: 112)).feature?.name == "Südstraße")
}

@Test func bufferedGeometryAndGeometryOutsideTheViewportCannotBeSelected() throws {
  let outsideTile = try PreparedMapTile(
    VectorTile(features: [selectionRoad(paths: [[[-8, 0], [-8, 256]]])]))
  #expect(try selected(outsideTile, at: CGPoint(x: 2, y: 128)).feature == nil)
  let crossing = try PreparedMapTile(
    VectorTile(features: [selectionRoad(paths: [[[-20, 128], [20, 128]]])]))
  #expect(try selected(crossing, at: CGPoint(x: 2, y: 130)).feature?.name == "Teststraße")

  let outsideViewport = try PreparedMapTile(
    VectorTile(features: [
      selectionRoad(paths: [[[1916, 0], [1916, 4096]]], extent: 4096)
    ]))
  #expect(try selected(outsideViewport, at: CGPoint(x: 2, y: 128), zoom: 18).feature == nil)
}

@Test func streetToleranceStaysInScreenPointsAtEveryOverzoom() throws {
  let tile = try PreparedMapTile(
    VectorTile(features: [selectionRoad(paths: [[[0, 128], [256, 128]]])]))
  for zoom in 14...18 {
    #expect(try selected(tile, at: CGPoint(x: 128, y: 143), zoom: zoom).feature != nil)
    #expect(try selected(tile, at: CGPoint(x: 128, y: 145), zoom: zoom).feature == nil)
  }
}

@Test func visiblePOIsTakePriorityAndRetainTheirOfflineDetails() throws {
  let details = PlaceDetails(
    address: "Marktplatz 3", openingHours: "Mo-Fr 08:00-18:00", phone: "+49 1234 567",
    website: "https://example.org")
  let tile = try PreparedMapTile(
    VectorTile(features: [
      selectionRoad(paths: [[[0, 128], [256, 128]]]),
      selectionPOI(at: [130, 132], details: details),
    ]))
  let selection = try selected(tile, at: CGPoint(x: 128, y: 128))
  #expect(selection.feature?.name == "Café am Markt")
  #expect(selection.feature?.sourceIdentity == "node/42")
  #expect(selection.feature?.kind == "node")
  #expect(selection.feature?.category == "cafe")
  #expect(selection.feature?.details == details)
  #expect(tile.features.count == 1)
  #expect(tile.selectablePoints.count == 1)
}

@Test func poiSelectionUsesDisplayZoomWhenSourceTilesHaveLowerResolution() throws {
  let tile = try PreparedMapTile(
    VectorTile(features: [
      selectionRoad(paths: [[[0, 128], [256, 128]]]), selectionPOI(),
    ]))
  #expect(try selected(tile, at: CGPoint(x: 128, y: 128), sourceZoom: 13).feature?.kind == "street")
  #expect(
    try selected(tile, at: CGPoint(x: 128, y: 128), sourceZoom: 13, zoom: 14).feature?.kind
      == "node")
}

@Test func selectionUsesTheVisibleWorldCopyAcrossTheDateLine() throws {
  let zoom = 14
  let count = Int(exp2(Double(zoom)))
  let key = MapTileKey(z: zoom, x: 0, y: count / 2)
  let placement = OfflineMapTilePlacement(key: key, worldX: count)
  let center = WebMercator.coordinate(
    CGPoint(x: count * 256 - 1, y: key.y * 256 + 128), zoom: zoom)
  let tile = try PreparedMapTile(VectorTile(features: [selectionPOI(at: [1, 128])]))
  let selection = try #require(
    OfflineMapSelection.select(
      at: CGPoint(x: 130, y: 128), center: center, zoom: zoom,
      size: CGSize(width: 256, height: 256), placements: [placement],
      tile: { $0 == key ? tile : nil }))
  let expected = WebMercator.coordinate(
    CGPoint(x: count * 256 + 1, y: key.y * 256 + 128), zoom: zoom)
  #expect(selection.feature?.name == "Café am Markt")
  #expect(selection.coordinate.lon < -179.9)
  #expect(abs(selection.coordinate.lon - expected.lon) < 0.000_000_1)
}

@Test func emptyTilesAndMissingTilesKeepTheOriginalTapCoordinate() throws {
  let context = selectionContext()
  let point = CGPoint(x: 33, y: 220)
  let expected = WebMercator.coordinate(
    CGPoint(x: context.key.x * 256 + 33, y: context.key.y * 256 + 220), zoom: context.key.z)
  let tile = try PreparedMapTile(VectorTile(features: []))
  let empty = try selected(tile, at: point)
  let missing = try #require(
    OfflineMapSelection.select(
      at: point, center: context.center, zoom: context.key.z, size: CGSize(width: 256, height: 256),
      placements: [context.placement], tile: { _ in nil }))
  #expect(empty.feature == nil && missing.feature == nil)
  #expect(abs(empty.coordinate.lat - expected.lat) < 0.000_000_1)
  #expect(abs(empty.coordinate.lon - expected.lon) < 0.000_000_1)
  #expect(empty == missing)
}

@Test func selectableMetadataExcludesPolygonsUnnamedRoadsAndInvalidPOIPoints() throws {
  let tile = try PreparedMapTile(
    VectorTile(features: [
      VectorFeature(layer: "building", kind: 3, extent: 256, name: "Haus", paths: [[[0, 0]]]),
      selectionRoad(" ", paths: [[[0, 0], [256, 256]]]),
      VectorFeature(
        layer: "poi", kind: 2, extent: 256, name: "Keine Punktgeometrie", paths: [[[0, 0]]]),
      VectorFeature(layer: "poi", kind: 1, extent: 0, name: "Kein Maßstab", paths: [[[0, 0]]]),
      selectionPOI(at: [-1, 128]),
    ]))
  #expect(tile.selectableRoads.isEmpty)
  #expect(try selected(tile, at: CGPoint(x: 1, y: 128)).feature == nil)
}
