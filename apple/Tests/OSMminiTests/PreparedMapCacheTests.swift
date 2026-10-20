import Foundation
import Testing

@testable import OSMmini

@Test func preparedMapCacheKeepsSnapshotsAndCurrentTilesAcrossViewportChanges() throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let keys = (0..<4).map { MapTileKey(z: 10, x: $0, y: 2) }
  let tile = try PreparedMapTile(VectorTile(features: []))
  var cache = PreparedMapTileCache()
  cache.updateViewport(owner: identity, keys: Array(keys.prefix(3)))
  for key in keys { cache.insert(tile, for: key, owner: identity) }
  let snapshot = cache

  // Loading order and repeated keys do not change viewport membership.
  cache.updateViewport(owner: identity, keys: [keys[2], keys[1], keys[0], keys[1]])
  #expect(Set(cache.tiles.keys) == Set(keys.prefix(3)))
  cache.updateViewport(owner: identity, keys: Array(keys.suffix(3)))
  cache.insert(tile, for: keys[0], owner: identity)
  cache.insert(tile, for: keys[3], owner: identity)
  #expect(Set(cache.tiles.keys) == Set(keys.suffix(3)))
  #expect(Set(snapshot.tiles.keys) == Set(keys.prefix(3)))

  // Duplicate requests can replace a larger viewport with a single tile.
  cache.updateViewport(owner: identity, keys: [keys[1], keys[1], keys[1]])
  #expect(Set(cache.tiles.keys) == [keys[1]])
  cache.updateViewport(owner: identity, keys: [])
  cache.insert(tile, for: keys[1], owner: identity)
  #expect(cache.tiles.isEmpty)
}

/// The previous update algorithm is retained only as a benchmark reference.
private struct FilteringMapTileCache {
  private var owner: ObjectIdentifier?
  private var needed: Set<MapTileKey> = []
  private(set) var tiles: [MapTileKey: PreparedMapTile] = [:]

  mutating func updateViewport(owner: ObjectIdentifier, keys: [MapTileKey]) {
    needed = Set(keys.prefix(PreparedMapTileCache.capacity))
    if self.owner != owner {
      tiles.removeAll(keepingCapacity: true)
      self.owner = owner
    } else {
      tiles = tiles.filter { needed.contains($0.key) }
    }
  }

  mutating func insert(_ tile: PreparedMapTile, for key: MapTileKey, owner: ObjectIdentifier) {
    guard self.owner == owner, needed.contains(key) else { return }
    tiles[key] = tile
  }
}

/// Opt in with OSMMINI_MAP_BENCHMARK=1. This isolates viewport bookkeeping;
/// geometry loading and GPU drawing are outside the measured interval.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapViewportCacheBenchmark() throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let tile = try PreparedMapTile(
    VectorTile(
      features: [
        VectorFeature(
          layer: "transportation", kind: 2, extent: 4096, class: "primary", name: "Road",
          paths: [[[0, 0], [4096, 4096]]])
      ]))
  let clock = ContinuousClock()
  let iterations = 10_000
  for count in [24, PreparedMapTileCache.capacity] {
    let keys = (0...count).map { MapTileKey(z: 10, x: $0, y: 2) }
    let viewports = [Array(keys.prefix(count)), Array(keys.suffix(count))]
    for moving in [false, true] {
      for pass in 0..<3 {
        var baselineTime = Duration.zero
        var currentTime = Duration.zero
        for optimized in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
          var baseline = FilteringMapTileCache()
          var current = PreparedMapTileCache()
          baseline.updateViewport(owner: identity, keys: viewports[0])
          current.updateViewport(owner: identity, keys: viewports[0])
          for key in viewports[0] {
            baseline.insert(tile, for: key, owner: identity)
            current.insert(tile, for: key, owner: identity)
          }
          var checksum = 0
          let start = clock.now
          for iteration in 0..<iterations {
            let shifted = moving && iteration.isMultiple(of: 2)
            let viewport = viewports[shifted ? 1 : 0]
            let entering = keys[shifted ? count : 0]
            if optimized {
              current.updateViewport(owner: identity, keys: viewport)
              if moving { current.insert(tile, for: entering, owner: identity) }
              checksum += current.tiles.count
            } else {
              baseline.updateViewport(owner: identity, keys: viewport)
              if moving { baseline.insert(tile, for: entering, owner: identity) }
              checksum += baseline.tiles.count
            }
          }
          let elapsed = start.duration(to: clock.now)
          if optimized { currentTime = elapsed } else { baselineTime = elapsed }
          #expect(checksum == iterations * count)
        }
        print(
          "Viewport cache \(count) tiles, \(moving ? "pan" : "same request"), pass \(pass + 1): filter \(baselineTime), incremental \(currentTime)"
        )
      }
    }
  }
}
