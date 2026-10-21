import Foundation
import Testing

@testable import OSMmini

private func poiTile(_ points: [(String, Int, Int)]) throws -> PreparedMapTile {
  try PreparedMapTile(
    VectorTile(
      features: points.map { id, x, y in
        VectorFeature(
          layer: "poi", kind: 1, extent: 256, class: "cafe", name: "Café \(id)",
          paths: [[[x, y]]], sourceIdentity: "node/\(id)")
      }))
}

@Test func crowdedPOIsHaveStableSpacingAcrossTileOrderAndKeepSeparatePlacesWhenZoomed() throws {
  let first = OfflineMapLabelTile(tile: try poiTile([("1", 120, 120)]), offset: .zero, scale: 1)
  let second = OfflineMapLabelTile(tile: try poiTile([("2", 130, 120)]), offset: .zero, scale: 1)
  let size = CGSize(width: 600, height: 600)
  let markers = OfflineMapPOILayout.markers(in: [first, second], zoom: 16, size: size)
  let reversed = OfflineMapPOILayout.markers(in: [second, first], zoom: 16, size: size)
  #expect(markers.map(\.feature.sourceIdentity) == ["node/1"])
  #expect(markers.map(\.feature) == reversed.map(\.feature))
  #expect(markers.first?.members.count == 2)
  #expect(markers.first?.members.map(\.feature) == reversed.first?.members.map(\.feature))
  let zoomed = [first, second].map {
    OfflineMapLabelTile(tile: $0.tile, offset: .zero, scale: 4)
  }
  #expect(OfflineMapPOILayout.markers(in: zoomed, zoom: 18, size: size).count == 2)
}

@Test func groupedPOITapReturnsEveryPlaceWithItsOwnCoordinate() throws {
  let tile = try poiTile([("1", 128, 128), ("2", 137, 128)])
  let z = 16
  let count = 1 << 15
  let key = MapTileKey(z: z, x: count, y: count)
  let center = WebMercator.coordinate(CGPoint(x: count * 256 + 128, y: count * 256 + 128), zoom: z)
  let result = OfflineMapSelection.select(
    at: CGPoint(x: 137, y: 128), center: center, zoom: z, size: CGSize(width: 256, height: 256),
    placements: [OfflineMapTilePlacement(key: key, worldX: count)], tile: { _ in tile })
  #expect(result?.feature?.sourceIdentity == "node/1")
  #expect(result?.alternatives.map(\.feature?.sourceIdentity) == ["node/1", "node/2"])
  #expect(result?.alternatives.allSatisfy { $0.alternatives.isEmpty } == true)
  #expect(result?.alternatives[0].coordinate != result?.alternatives[1].coordinate)
}

@Test func visiblePOILabelIsTappableAndReturnsTheMarkerCoordinate() throws {
  let tile = try poiTile([("1", 128, 128)])
  let z = 17
  let count = 1 << 16
  let key = MapTileKey(z: z, x: count, y: count)
  let center = WebMercator.coordinate(CGPoint(x: count * 256 + 128, y: count * 256 + 128), zoom: z)
  let size = CGSize(width: 600, height: 600)
  let placement = OfflineMapTilePlacement(key: key, worldX: count)
  let tiles = [
    OfflineMapLabelTile(
      tile: tile, offset: placement.origin(center: center, zoom: z, size: size), scale: 1)
  ]
  let markers = OfflineMapPOILayout.markers(in: tiles, zoom: z, size: size)
  let label = try #require(OfflineMapPOILayout.labels(for: markers, zoom: z, size: size).first)
  let result = try #require(
    OfflineMapSelection.select(
      at: CGPoint(x: label.frame.midX, y: label.frame.midY), center: center, zoom: z, size: size,
      placements: [placement], tile: { _ in tile }))
  #expect(result.feature?.sourceIdentity == "node/1")
  #expect(abs(result.coordinate.lat - center.lat) < 0.000_000_1)
  #expect(abs(result.coordinate.lon - center.lon) < 0.000_000_1)
}

@Test func poiLabelsAvoidEachOtherControlsAndAttributionAndWaitForCloseZoom() throws {
  let tile = try poiTile([("1", 100, 100), ("2", 140, 100), ("3", 200, 200)])
  let size = CGSize(width: 600, height: 600)
  let markers = OfflineMapPOILayout.markers(
    in: [OfflineMapLabelTile(tile: tile, offset: .zero, scale: 2)], zoom: 17, size: size)
  #expect(OfflineMapPOILayout.labels(for: markers, zoom: 16, size: size).isEmpty)
  let labels = OfflineMapPOILayout.labels(for: markers, zoom: 17, size: size)
  #expect(!labels.isEmpty)
  for (index, label) in labels.enumerated() {
    #expect(CGRect(origin: .zero, size: size).contains(label.frame))
    #expect(!label.frame.intersects(CGRect(x: 524, y: 0, width: 76, height: 232)))
    #expect(!label.frame.intersects(CGRect(x: 0, y: 520, width: 260, height: 80)))
    for other in labels.dropFirst(index + 1) { #expect(!label.frame.intersects(other.frame)) }
  }
}

@Test func poiLayoutExcludesBufferedAndOffscreenPointsAndLowZooms() throws {
  let tile = try poiTile([("1", -1, 100), ("2", 128, 128), ("3", 257, 100)])
  let size = CGSize(width: 256, height: 256)
  let tiles = [OfflineMapLabelTile(tile: tile, offset: .zero, scale: 1)]
  #expect(OfflineMapPOILayout.markers(in: tiles, zoom: 13, size: size).isEmpty)
  #expect(
    OfflineMapPOILayout.markers(in: tiles, zoom: 14, size: size).map(\.feature.sourceIdentity) == [
      "node/2"
    ])
  #expect(
    OfflineMapPOILayout.markers(
      in: [OfflineMapLabelTile(tile: tile, offset: CGPoint(x: 300, y: 0), scale: 1)],
      zoom: 18, size: size
    ).isEmpty)
}

@Test func colocatedPOIsRemainReachableAtMaximumZoomAndDuplicateTilesDoNotInflateCounts() throws {
  let tile = try poiTile((1...1_000).map { (String($0), 128, 128) })
  let placement = OfflineMapLabelTile(tile: tile, offset: .zero, scale: 1)
  let markers = OfflineMapPOILayout.markers(
    in: [placement, placement], zoom: 18,
    size: CGSize(width: 320, height: 400))
  #expect(markers.count == 1)
  let group = try #require(markers.first)
  #expect(group.members.count == 1_000)
  #expect(Set(group.members.compactMap(\.feature.sourceIdentity)).count == 1_000)
  #expect(
    OfflineMapPOILayout.labels(
      for: markers, zoom: 18,
      size: CGSize(width: 320, height: 400)
    ).isEmpty)
}

@Test func groupsCrossTileEdgesAndStayStableWhenTileOrderChanges() throws {
  let first = OfflineMapLabelTile(tile: try poiTile([("1", 250, 128)]), offset: .zero, scale: 1)
  let second = OfflineMapLabelTile(
    tile: try poiTile([("2", 5, 128)]),
    offset: CGPoint(x: 256, y: 0), scale: 1)
  for tiles in [[first, second], [second, first]] {
    let markers = OfflineMapPOILayout.markers(
      in: tiles, zoom: 18,
      size: CGSize(width: 390, height: 400))
    #expect(markers.count == 1)
    #expect(markers.first?.members.map(\.feature.sourceIdentity) == ["node/1", "node/2"])
  }
}

@Test func individualPOITargetIsAtLeast44PointsWideWithoutExpandingStreetTolerance() throws {
  let tile = try poiTile([("1", 128, 128)])
  let count = 1 << 17
  let key = MapTileKey(z: 18, x: count, y: count)
  let center = WebMercator.coordinate(CGPoint(x: count * 256 + 128, y: count * 256 + 128), zoom: 18)
  func select(_ x: CGFloat) -> MapSelection? {
    OfflineMapSelection.select(
      at: CGPoint(x: x, y: 128), center: center, zoom: 18,
      size: CGSize(width: 256, height: 256),
      placements: [OfflineMapTilePlacement(key: key, worldX: count)], tile: { _ in tile })
  }
  #expect(select(149)?.feature?.sourceIdentity == "node/1")
  #expect(select(151)?.feature == nil)
}

@Test func shortPOINamesFitBesideMarkersOnNarrowIPhoneMaps() throws {
  let tile = try poiTile([("1", 120, 128)])
  let size = CGSize(width: 320, height: 400)
  let markers = OfflineMapPOILayout.markers(
    in: [OfflineMapLabelTile(tile: tile, offset: .zero, scale: 1)], zoom: 18, size: size)
  let labels = OfflineMapPOILayout.labels(for: markers, zoom: 18, size: size)
  #expect(labels.count == 1)
  #expect(labels.first?.frame.width ?? 150 < 150)
  #expect(labels.allSatisfy { CGRect(origin: .zero, size: size).contains($0.frame) })
}
