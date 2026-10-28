import Foundation
import Testing

@testable import OSMmini

private func fallbackCache(
  owner: ObjectIdentifier, loaded: [MapTileKey], requested: [OfflineMapTilePlacement]
) throws -> PreparedMapTileCache {
  var cache = PreparedMapTileCache()
  cache.updateViewport(owner: owner, keys: loaded + requested.map(\.key))
  let tile = try PreparedMapTile(VectorTile(features: []))
  for key in loaded { cache.insert(tile, for: key, owner: owner) }
  return cache
}

@Test func zoomingInKeepsTheLoadedParentOnlyUnderMissingChildren() throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let parent = MapTileKey(z: 1, x: 1, y: 1)
  let missing = OfflineMapTilePlacement(key: MapTileKey(z: 2, x: 2, y: 2), worldX: 2)
  let complete = OfflineMapTilePlacement(key: MapTileKey(z: 2, x: 3, y: 2), worldX: 3)
  let cache = try fallbackCache(owner: identity, loaded: [parent, complete.key], requested: [missing, complete])
  let size = CGSize(width: 512, height: 256)
  let center = WebMercator.coordinate(CGPoint(x: 768, y: 640), zoom: 2)
  let regions = OfflineMapTileFallback.regions(
    for: [missing, complete], cache: cache, owner: identity, center: center, displayZoom: 2, size: size)
  #expect(regions.count == 1)
  #expect(regions.first?.placement == OfflineMapTilePlacement(key: parent, worldX: 1))
  #expect(regions.first?.clips == [CGRect(x: 0, y: 0, width: 256, height: 256)])
}

@Test func zoomingOutUsesLoadedChildrenWithinTheirCurrentParent() throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let missing = OfflineMapTilePlacement(key: MapTileKey(z: 1, x: 1, y: 1), worldX: 1)
  let children = [MapTileKey(z: 2, x: 2, y: 2), MapTileKey(z: 2, x: 3, y: 2)]
  let unrelated = MapTileKey(z: 2, x: 0, y: 0)
  let cache = try fallbackCache(owner: identity, loaded: children + [unrelated], requested: [missing])
  let center = WebMercator.coordinate(CGPoint(x: 384, y: 384), zoom: 1)
  let regions = OfflineMapTileFallback.regions(
    for: [missing], cache: cache, owner: identity, center: center,
    displayZoom: 1, size: CGSize(width: 256, height: 256))
  #expect(regions.map(\.placement.key) == children)
  #expect(regions.flatMap(\.clips) == [
    CGRect(x: 0, y: 0, width: 128, height: 128),
    CGRect(x: 128, y: 0, width: 128, height: 128),
  ])
}

@Test func fallbackKeepsNegativeWorldCopiesAlignedAcrossTheDateline() throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let parent = MapTileKey(z: 1, x: 1, y: 0)
  let missing = OfflineMapTilePlacement(key: MapTileKey(z: 2, x: 3, y: 1), worldX: -1)
  let cache = try fallbackCache(owner: identity, loaded: [parent], requested: [missing])
  let center = WebMercator.coordinate(CGPoint(x: 0, y: 384), zoom: 2)
  let regions = OfflineMapTileFallback.regions(
    for: [missing], cache: cache, owner: identity, center: center,
    displayZoom: 2.25, size: CGSize(width: 256, height: 256))
  #expect(regions.count == 1)
  #expect(regions.first?.placement.worldX == -1)
  let clip = try #require(regions.first?.clips.first)
  #expect(clip == CGRect(x: 0, y: 0, width: 128, height: 256))
}

@Test func fallbackNeverDrawsAnotherRegionOrInvalidViewport() throws {
  let owner = NSObject(), otherOwner = NSObject()
  let identity = ObjectIdentifier(owner)
  let missing = OfflineMapTilePlacement(key: MapTileKey(z: 2, x: 2, y: 2), worldX: 2)
  let cache = try fallbackCache(
    owner: identity, loaded: [MapTileKey(z: 1, x: 1, y: 1)], requested: [missing])
  let center = Coordinate(lat: -20, lon: 20)
  for (candidateOwner, zoom, size) in [
    (ObjectIdentifier(otherOwner), 2.5, CGSize(width: 256, height: 256)),
    (identity, .nan, CGSize(width: 256, height: 256)),
    (identity, 2.5, .zero),
  ] {
    #expect(OfflineMapTileFallback.regions(
      for: [missing], cache: cache, owner: candidateOwner, center: center,
      displayZoom: zoom, size: size).isEmpty)
  }
}

@Test func retainedZoomTilesShareTheExistingCacheBudgetAndNeverCrossRegions() throws {
  let owner = NSObject(), replacement = NSObject()
  let identity = ObjectIdentifier(owner)
  var cache = PreparedMapTileCache()
  let tile = try PreparedMapTile(VectorTile(features: []))
  for step in 0..<200 {
    let keys = (step..<(step + 4)).map { MapTileKey(z: 8, x: $0, y: 1) }
    cache.updateViewport(owner: identity, keys: keys, retainingPreviousTiles: true)
    if step > 0 {
      #expect(cache.tile(for: MapTileKey(z: 8, x: step - 1, y: 1), owner: identity) != nil)
    }
    for key in keys { cache.insert(tile, for: key, owner: identity) }
    #expect(cache.tiles.count <= PreparedMapTileCache.capacity)
  }
  let full = (0..<PreparedMapTileCache.capacity).map { MapTileKey(z: 8, x: $0, y: 2) }
  cache.updateViewport(owner: identity, keys: full, retainingPreviousTiles: true)
  #expect(cache.tiles.isEmpty)
  for key in full { cache.insert(tile, for: key, owner: identity) }
  #expect(cache.tiles.count == PreparedMapTileCache.capacity)
  cache.updateViewport(
    owner: ObjectIdentifier(replacement), keys: full, retainingPreviousTiles: true)
  #expect(cache.tiles.isEmpty)
  #expect(cache.tile(for: full[0], owner: identity) == nil)
}
