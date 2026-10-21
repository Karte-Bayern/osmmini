import Foundation
import Testing

@testable import OSMmini

@Test func mapDetailTilesFollowDisplayZoomWithoutReplacingBasemapGeometry() {
  let center = Coordinate(lat: 48.5, lon: 12.5)
  let size = CGSize(width: 390, height: 600)
  for baseZoom in [5, 14] {
    let plan = OfflineMapTilePlan.make(
      center: center, zoom: 18, size: size, baseMaxZoom: baseZoom)
    #expect(!plan.base.isEmpty && !plan.details.isEmpty)
    #expect(plan.base.allSatisfy { $0.key.z == baseZoom })
    #expect(plan.details.allSatisfy { $0.key.z == 18 })
    #expect(plan.poiZoom == 18 && plan.hasDetailPOIs)
    #expect(Set(plan.keys).count == plan.keys.count)
    #expect(plan.keys.count <= PreparedMapTileCache.capacity)
  }
}

@Test func ordinaryMapZoomUsesOneTileLayerAndDoesNotDuplicatePOIs() {
  let center = Coordinate(lat: 48.5, lon: 12.5)
  let size = CGSize(width: 390, height: 600)
  let standard = OfflineMapTilePlan.make(center: center, zoom: 14, size: size, baseMaxZoom: 14)
  #expect(standard.details.isEmpty && !standard.hasDetailPOIs)
  #expect(standard.poiZoom == 14)
  #expect(standard.placements == standard.base)
  #expect(
    standard.keys
      == OfflineMapTilePlacement.keys(
        in: OfflineMapTilePlacement.visible(center: center, zoom: 14, size: size, tileZoom: 14)))
  let overview = OfflineMapTilePlan.make(center: center, zoom: 13, size: size, baseMaxZoom: 5)
  #expect(overview.poiZoom == nil && overview.details.isEmpty)
}

@Test func basemapAndDetailTilesRespectOneSharedCacheBudget() {
  for size in [CGSize(width: 3_000, height: 3_000), CGSize(width: 100_000, height: 100_000)] {
    for baseZoom in [5, 14] {
      let plan = OfflineMapTilePlan.make(
        center: Coordinate(lat: 48.5, lon: 12.5), zoom: 18, size: size, baseMaxZoom: baseZoom)
      #expect(plan.keys.count <= PreparedMapTileCache.capacity)
      #expect(Set(plan.keys).count == plan.keys.count)
      #expect(Set(plan.base.map(\.key)).isSubset(of: Set(plan.keys)))
      #expect(plan.poiZoom == 18)
    }
  }
}

@Test func mixedZoomLoadOrderMeasuresDistancesInTheSameWorldUnits() {
  let center = Coordinate(lat: 0, lon: 0)
  let coarse = OfflineMapTilePlacement(key: MapTileKey(z: 0, x: 0, y: 0), worldX: 0)
  let fine = OfflineMapTilePlacement(
    key: MapTileKey(z: 18, x: 1 << 17, y: 1 << 17), worldX: 1 << 17)
  let expected = [coarse.key, fine.key]
  #expect(OfflineMapTilePlacement.loadingKeys(in: [fine, coarse], center: center) == expected)
  #expect(OfflineMapTilePlacement.loadingKeys(in: [coarse, fine], center: center) == expected)
}

private func planPOI(_ name: String, point: [Int]) -> VectorFeature {
  VectorFeature(
    layer: "poi", kind: 1, extent: 256, class: "cafe", name: name, paths: [[point]],
    sourceIdentity: "node/\(name)")
}

@Test func missingDetailTilesCannotSelectCoarsePOIsButKeepBasemapStreets() throws {
  let size = CGSize(width: 256, height: 256)
  for baseZoom in [5, 14] {
    let centerTile = 1 << (baseZoom - 1)
    let center = WebMercator.coordinate(
      CGPoint(x: centerTile * 256 + 128, y: centerTile * 256 + 128), zoom: baseZoom)
    let plan = OfflineMapTilePlan.make(
      center: center, zoom: 18, size: size, baseMaxZoom: baseZoom)
    let baseKey = try #require(plan.base.first?.key)
    let point = planPOI("Coarse", point: [128, 128])
    let street = VectorFeature(
      layer: "transportation", kind: 2, extent: 256, class: "residential", name: "Hauptstraße",
      paths: [[[0, 128], [256, 128]]])
    for includeStreet in [false, true] {
      let baseTile = try PreparedMapTile(
        VectorTile(features: includeStreet ? [point, street] : [point]))
      let selection = try #require(
        OfflineMapSelection.select(
          at: CGPoint(x: 130, y: 130), center: center, zoom: 18, size: size,
          placements: plan.placements, baseZoom: plan.baseZoom, poiZoom: plan.poiZoom,
          tile: { $0 == baseKey ? baseTile : nil }))
      #expect(selection.feature?.name == (includeStreet ? "Hauptstraße" : nil))
    }
  }
}

@Test func detailPOIPositionWinsOverCoarsePositionAfterOverzoom() throws {
  let baseZoom = 5
  let centerTile = 1 << (baseZoom - 1)
  let size = CGSize(width: 256, height: 256)
  let center = WebMercator.coordinate(
    CGPoint(x: centerTile * 256 + 128, y: centerTile * 256 + 128), zoom: baseZoom)
  let plan = OfflineMapTilePlan.make(center: center, zoom: 18, size: size, baseMaxZoom: baseZoom)
  let tap = CGPoint(x: 130, y: 130)
  let detail = try #require(
    plan.details.first {
      CGRect(origin: $0.origin(center: center, zoom: 18, size: size), size: size).contains(tap)
    })
  let origin = detail.origin(center: center, zoom: 18, size: size)
  let localPoint = [Int((tap.x - origin.x).rounded()), Int((tap.y - origin.y).rounded())]
  let baseTile = try PreparedMapTile(
    VectorTile(features: [planPOI("Coarse", point: [128, 128])]))
  let detailTile = try PreparedMapTile(
    VectorTile(features: [planPOI("Precise", point: localPoint)]))
  let selection = try #require(
    OfflineMapSelection.select(
      at: tap, center: center, zoom: 18, size: size,
      placements: plan.placements, baseZoom: plan.baseZoom, poiZoom: plan.poiZoom,
      tile: { key in
        if key == detail.key { return detailTile }
        return key.z == baseZoom ? baseTile : nil
      }))
  #expect(selection.feature?.name == "Precise")
  let expected = WebMercator.coordinate(
    CGPoint(x: detail.worldX * 256 + localPoint[0], y: detail.key.y * 256 + localPoint[1]), zoom: 18
  )
  #expect(abs(selection.coordinate.lat - expected.lat) < 0.000_000_1)
  #expect(abs(selection.coordinate.lon - expected.lon) < 0.000_000_1)
}
