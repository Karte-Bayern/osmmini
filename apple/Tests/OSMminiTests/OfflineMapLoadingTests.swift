import Foundation
import Testing

@testable import OSMmini

/// Controlled completions prove overlap and cancellation without timing assertions.
@MainActor private final class PendingMapTiles {
  let started = AsyncStream<MapTileKey>.makeStream()
  private let tile: PreparedMapTile
  private var pending: [MapTileKey: CheckedContinuation<PreparedMapTile, any Error>] = [:]
  private var released = false
  private(set) var fetched: [MapTileKey] = []
  private(set) var cancelled: Set<MapTileKey> = []
  private(set) var maximumActive = 0

  init() throws { tile = try PreparedMapTile(VectorTile(features: [])) }

  func fetch(_ key: MapTileKey) async throws -> PreparedMapTile {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      fetched.append(key)
      if released { return tile }
      return try await withCheckedThrowingContinuation { continuation in
        pending[key] = continuation
        maximumActive = max(maximumActive, pending.count)
        started.continuation.yield(key)
      }
    } onCancel: {
      Task { @MainActor in
        self.cancelled.insert(key)
        self.pending.removeValue(forKey: key)?.resume(throwing: CancellationError())
      }
    }
  }

  func finish(_ key: MapTileKey) {
    pending.removeValue(forKey: key)?.resume(returning: tile)
  }

  func finishAll() {
    released = true
    for key in Array(pending.keys) { finish(key) }
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func offlineMapLoadsBoundedTilesAndPublishesWithoutWaitingForSlowNeighbor() async throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let loader = OfflineMapTileLoader()
  let source = try PendingMapTiles()
  let keys = (0..<12).map { MapTileKey(z: 5, x: $0, y: 2) }
  var started = source.started.stream.makeAsyncIterator()
  let task = Task { await loader.load(owner: identity, keys: keys, fetch: source.fetch) }
  for _ in 0..<OfflineMapTileLoader.maximumConcurrentLoads { _ = await started.next() }
  #expect(Set(source.fetched) == Set(keys.prefix(4)))
  #expect(loader.isLoading)
  #expect(loader.cache.tiles.isEmpty)

  // A neighbor completes while the highest-priority tile remains suspended.
  source.finish(keys[1])
  #expect(await started.next() == keys[4])
  #expect(loader.cache.tile(for: keys[1], owner: identity) != nil)
  #expect(loader.cache.tile(for: keys[0], owner: identity) == nil)
  #expect(source.maximumActive == 4)

  source.finishAll()
  await task.value
  #expect(Set(source.fetched) == Set(keys))
  #expect(source.fetched.count == keys.count)
  #expect(source.maximumActive == 4)
  #expect(loader.cache.tiles.count == keys.count)
  #expect(!loader.isLoading)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func offlineMapCancellationStopsActiveAndQueuedTileWork() async throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let loader = OfflineMapTileLoader()
  let source = try PendingMapTiles()
  let keys = (0..<12).map { MapTileKey(z: 5, x: $0, y: 2) }
  var started = source.started.stream.makeAsyncIterator()
  let task = Task { await loader.load(owner: identity, keys: keys, fetch: source.fetch) }
  for _ in 0..<OfflineMapTileLoader.maximumConcurrentLoads { _ = await started.next() }
  task.cancel()
  await task.value
  #expect(Set(source.fetched) == Set(keys.prefix(4)))
  #expect(source.cancelled == Set(keys.prefix(4)))
  #expect(loader.cache.tiles.isEmpty)
  #expect(loader.failures(owner: identity, keys: keys) == 0)
  #expect(!loader.isLoading)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func offlineMapReplacementCancelsRemainingOldWorkWithoutSchedulingMore() async throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let loader = OfflineMapTileLoader()
  let source = try PendingMapTiles()
  let keys = (0..<12).map { MapTileKey(z: 5, x: $0, y: 2) }
  var started = source.started.stream.makeAsyncIterator()
  let previous = Task { await loader.load(owner: identity, keys: keys, fetch: source.fetch) }
  for _ in 0..<OfflineMapTileLoader.maximumConcurrentLoads { _ = await started.next() }
  let newKey = MapTileKey(z: 6, x: 20, y: 20)
  let tile = try PreparedMapTile(VectorTile(features: []))
  await loader.load(owner: identity, keys: [newKey]) { _ in tile }
  source.finish(keys[0])
  await previous.value
  #expect(Set(source.fetched) == Set(keys.prefix(4)))
  #expect(source.cancelled == Set(keys[1..<4]))
  #expect(Set(loader.cache.tiles.keys) == [newKey])
  #expect(loader.failures(owner: identity, keys: [newKey]) == 0)
  #expect(!loader.isLoading)
}

@Test @MainActor func offlineMapFetchesOnlyUniqueCacheableTiles() async throws {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let loader = OfflineMapTileLoader()
  let tile = try PreparedMapTile(VectorTile(features: []))
  let unique = (0..<200).map { MapTileKey(z: 10, x: $0, y: 2) }
  let keys = unique.flatMap { [$0, $0] }
  var fetched: [MapTileKey] = []
  await loader.load(owner: identity, keys: keys) { key in
    fetched.append(key)
    return tile
  }
  let expected = Set(keys.prefix(PreparedMapTileCache.capacity))
  #expect(Set(fetched) == expected)
  #expect(fetched.count == expected.count)
  #expect(loader.cache.tiles.count == expected.count)
  await loader.load(owner: identity, keys: keys) { _ in
    Issue.record("already cached tile was fetched again")
    return tile
  }
  #expect(!loader.isLoading)
}

@Test func offlineMapLoadsTilesNearestTheDisplayedCenterFirst() throws {
  for (center, zoom, tileZoom, size) in [
    (Coordinate(lat: 48, lon: 12), 10, 10, CGSize(width: 800, height: 900)),
    (Coordinate(lat: 0, lon: 179.9), 5, 5, CGSize(width: 900, height: 700)),
    (Coordinate(lat: 0, lon: -179.9), 5, 5, CGSize(width: 900, height: 700)),
    (Coordinate(lat: 0, lon: 179), 0, 0, CGSize(width: 1000, height: 200)),
    (Coordinate(lat: 48, lon: 12), 18, 14, CGSize(width: 1000, height: 1000)),
  ] {
    let placements = OfflineMapTilePlacement.visible(
      center: center, zoom: zoom, size: size, tileZoom: tileZoom)
    let keys = OfflineMapTilePlacement.loadingKeys(in: placements, center: center)
    #expect(Set(keys) == Set(OfflineMapTilePlacement.keys(in: placements)))
    #expect(keys.count == Set(keys).count)
    func distance(_ key: MapTileKey) -> Double {
      placements.filter { $0.key == key }.map { placement in
        let origin = placement.origin(center: center, zoom: zoom, size: size)
        let halfTile = 128 * placement.scale(at: zoom)
        return hypot(origin.x + halfTile - size.width / 2, origin.y + halfTile - size.height / 2)
      }.min() ?? .infinity
    }
    let distances = keys.map(distance)
    #expect(distances == distances.sorted())
  }
}

@Test @MainActor func offlineMapFailuresBelongToViewportRegardlessOfLoadingOrder() async throws {
  enum Unavailable: Error { case tile }
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let loader = OfflineMapTileLoader()
  let keys = (0..<3).map { MapTileKey(z: 5, x: $0, y: 2) }
  await loader.load(owner: identity, keys: keys.reversed()) { _ in throw Unavailable.tile }
  #expect(loader.failures(owner: identity, keys: keys) == keys.count)
  #expect(loader.failures(owner: identity, keys: Array(keys.dropFirst())) == 0)
}

/// Measures worker JSON decoding and path preparation with a dense synthetic
/// tile. No simulated delays, GPU drawing, disk I/O or device-memory claims.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
@MainActor func offlineMapLoadingBenchmark() async throws {
  let tile = VectorTile(
    features: (0..<256).map { feature in
      VectorFeature(
        layer: "transportation", kind: 2, extent: 4096, class: "residential", name: nil,
        paths: [
          (0..<128).map { vertex in
            [vertex * 32, (feature * 31 + vertex * 37) % 4096]
          }
        ])
    })
  let encoded = try JSONEncoder().encode(tile)
  let fetch: @MainActor @Sendable (MapTileKey) async throws -> PreparedMapTile = { _ in
    let worker = Task.detached(priority: .userInitiated) {
      try PreparedMapTile(JSONDecoder().decode(VectorTile.self, from: encoded))
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let keys = (0..<24).map { MapTileKey(z: 5, x: $0, y: 2) }
  let clock = ContinuousClock()
  _ = try await fetch(keys[0])
  for pass in 0..<3 {
    var sequential = Duration.zero
    var concurrent = Duration.zero
    // Alternate order to reduce warm-up and thermal bias.
    for parallel in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
      let start = clock.now
      if parallel {
        let loader = OfflineMapTileLoader()
        await loader.load(owner: identity, keys: keys, fetch: fetch)
        concurrent = start.duration(to: clock.now)
        #expect(loader.cache.tiles.count == keys.count)
        #expect(loader.cache.tiles.values.allSatisfy { $0.features.count == 256 })
      } else {
        var cache = PreparedMapTileCache()
        cache.updateViewport(owner: identity, keys: keys)
        for key in keys { cache.insert(try await fetch(key), for: key, owner: identity) }
        sequential = start.duration(to: clock.now)
        #expect(cache.tiles.count == keys.count)
      }
    }
    print(
      "Tile loading pass \(pass + 1): 24 tiles × 32,768 vertices; serial \(sequential), bounded parallel \(concurrent)"
    )
  }
}
