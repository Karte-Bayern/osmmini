import Foundation
import Testing

@testable import OSMmini

private enum TileFailure: Error { case unavailable }

@Test @MainActor func offlineMapContinuesAfterFailureAndRetryKeepsSuccessfulTiles() async throws {
  final class Owner {}
  let owner = Owner()
  let identity = ObjectIdentifier(owner)
  let keys = (0..<3).map { MapTileKey(z: 5, x: $0, y: 2) }
  let tile = try PreparedMapTile(VectorTile(features: []))
  let loader = OfflineMapTileLoader()
  var fetched: [MapTileKey] = []
  await loader.load(owner: identity, keys: keys) { key in
    fetched.append(key)
    if key == keys[0] { throw TileFailure.unavailable }
    return tile
  }
  #expect(Set(fetched) == Set(keys))
  #expect(fetched.count == keys.count)
  #expect(loader.failures(owner: identity, keys: keys) == 1)
  #expect(loader.cache.tiles.count == 2)
  #expect(!loader.isLoading)
  fetched.removeAll()
  await loader.load(owner: identity, keys: keys) { key in
    fetched.append(key)
    return tile
  }
  #expect(fetched == [keys[0]])
  #expect(loader.failures(owner: identity, keys: keys) == 0)
  #expect(loader.cache.tiles.count == 3)
}

@Test @MainActor func offlineMapCancellationDoesNotPublishTileFailure() async {
  final class Owner {}
  let owner = Owner()
  let identity = ObjectIdentifier(owner)
  let keys = [MapTileKey(z: 5, x: 0, y: 2), MapTileKey(z: 5, x: 1, y: 2)]
  let loader = OfflineMapTileLoader()
  let entered = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let task = Task {
    await loader.load(owner: identity, keys: keys) { key in
      if key == keys[0] { throw TileFailure.unavailable }
      // Fetches overlap now; let the first result reach the loader before
      // signalling that this test can inspect its intermediate failure count.
      while loader.failures(owner: identity, keys: keys) == 0 { await Task.yield() }
      entered.continuation.yield(())
      for await _ in release.stream { break }
      throw TileFailure.unavailable
    }
  }
  for await _ in entered.stream { break }
  #expect(loader.failures(owner: identity, keys: keys) == 1)
  task.cancel()
  release.continuation.finish()
  await task.value
  #expect(loader.failures(owner: identity, keys: keys) == 0)
  #expect(!loader.isLoading)
}

@Test @MainActor func offlineMapNewViewportRejectsLateFailureFromPreviousLoad() async throws {
  final class Owner {}
  let owner = Owner()
  let identity = ObjectIdentifier(owner)
  let oldKeys = [MapTileKey(z: 5, x: 0, y: 2)]
  let newKeys = [MapTileKey(z: 5, x: 1, y: 2)]
  let tile = try PreparedMapTile(VectorTile(features: []))
  let loader = OfflineMapTileLoader()
  let entered = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let previous = Task {
    await loader.load(owner: identity, keys: oldKeys) { _ in
      entered.continuation.yield(())
      for await _ in release.stream { break }
      throw TileFailure.unavailable
    }
  }
  for await _ in entered.stream { break }
  await loader.load(owner: identity, keys: newKeys) { _ in tile }
  release.continuation.finish()
  await previous.value
  #expect(loader.failures(owner: identity, keys: oldKeys) == 0)
  #expect(loader.failures(owner: identity, keys: newKeys) == 0)
  #expect(loader.cache.tiles.count == 1)
  #expect(loader.cache.tile(for: newKeys[0], owner: identity) != nil)
  #expect(!loader.isLoading)
}

@Test @MainActor func offlineMapNewViewportRejectsLateTileFromPreviousLoad() async throws {
  final class Owner {}
  let first = Owner()
  let second = Owner()
  let firstID = ObjectIdentifier(first)
  let secondID = ObjectIdentifier(second)
  let keys = [MapTileKey(z: 5, x: 0, y: 2)]
  let tile = try PreparedMapTile(VectorTile(features: []))
  let loader = OfflineMapTileLoader()
  let entered = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let previous = Task {
    await loader.load(owner: firstID, keys: keys) { _ in
      entered.continuation.yield(())
      for await _ in release.stream { break }
      return tile
    }
  }
  for await _ in entered.stream { break }
  await loader.load(owner: secondID, keys: keys) { _ in throw TileFailure.unavailable }
  release.continuation.finish()
  await previous.value
  #expect(loader.cache.tile(for: keys[0], owner: secondID) == nil)
  #expect(loader.failures(owner: secondID, keys: keys) == 1)
}

private func expectRouteInsideViewport(
  _ points: [Coordinate], _ viewport: OfflineMapViewport, size: CGSize, margin: CGFloat = 0
) {
  for point in points {
    let offset = WebMercator.offset(point, from: viewport.center, zoom: viewport.zoom)
    #expect(abs(offset.x) <= size.width / 2 - margin + 0.000_001)
    #expect(abs(offset.y) <= size.height / 2 - margin + 0.000_001)
  }
}

@Test func offlineMapFitsHighLatitudeInProjectedSpace() throws {
  let points = [Coordinate(lat: 72, lon: 12), Coordinate(lat: 84, lon: 20)]
  let size = CGSize(width: 390, height: 600)
  let viewport = try #require(
    OfflineMapViewport.fitting(points, size: size, minZoom: 0, maxZoom: 20))
  expectRouteInsideViewport(points, viewport, size: size, margin: 48)
  #expect(viewport.center.lat > 78)
  let projected = points.map { WebMercator.world($0, zoom: viewport.zoom) }
  let center = WebMercator.world(viewport.center, zoom: viewport.zoom)
  #expect(abs(center.y - (projected[0].y + projected[1].y) / 2) < 0.000_001)
}

@Test func offlineMapFitsDatelineRouteAndDrawsAdjacentWorldTiles() throws {
  let points = [Coordinate(lat: -16.5, lon: 179.5), Coordinate(lat: -16.4, lon: -179.5)]
  let size = CGSize(width: 390, height: 600)
  let viewport = try #require(
    OfflineMapViewport.fitting(points, size: size, minZoom: 0, maxZoom: 20))
  #expect(abs(abs(viewport.center.lon) - 180) < 0.000_001)
  #expect(viewport.zoom >= 8)
  expectRouteInsideViewport(points, viewport, size: size, margin: 48)
  let placements = OfflineMapTilePlacement.visible(
    center: viewport.center, zoom: viewport.zoom, size: size)
  #expect(placements.contains { $0.worldX < 0 })
  #expect(placements.contains { $0.key.x == 0 })
  #expect(placements.contains { $0.key.x == (1 << viewport.zoom) - 1 })
  #expect(placements.allSatisfy { $0.key.x >= 0 && $0.key.x < 1 << viewport.zoom })
}

@Test func offlineMapFitHandlesTinyViewportsAndZoomLimits() throws {
  let size = CGSize(width: 8, height: 10)
  let points = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 48.0001, lon: 12.0001)]
  for tinySize in [size, CGSize(width: 1, height: 1)] {
    let viewport = try #require(
      OfflineMapViewport.fitting(points, size: tinySize, minZoom: 0, maxZoom: 20))
    expectRouteInsideViewport(
      points, viewport, size: tinySize, margin: min(tinySize.width, tinySize.height) / 4)
  }
  let pointFit = try #require(
    OfflineMapViewport.fitting([points[0]], size: size, minZoom: 5, maxZoom: 14))
  #expect(pointFit.zoom == 14)
  #expect(abs(pointFit.center.lat - points[0].lat) < 0.000_001)
  #expect(abs(pointFit.center.lon - points[0].lon) < 0.000_001)
  let largeRoute = [Coordinate(lat: -80, lon: -100), Coordinate(lat: 80, lon: 100)]
  #expect(OfflineMapViewport.fitting(largeRoute, size: size, minZoom: 5, maxZoom: 14)?.zoom == 5)
}

@Test func offlineMapFitRejectsEmptyOrInvalidGeometryWithoutMovingMap() {
  let size = CGSize(width: 390, height: 600)
  #expect(OfflineMapViewport.fitting([], size: size, minZoom: 0, maxZoom: 14) == nil)
  #expect(
    OfflineMapViewport.fitting([Coordinate(lat: .nan, lon: 1)], size: size, minZoom: 0, maxZoom: 14)
      == nil)
  #expect(
    OfflineMapViewport.fitting([Coordinate(lat: 48, lon: 12)], size: .zero, minZoom: 0, maxZoom: 14)
      == nil)
  #expect(
    OfflineMapViewport.fitting([Coordinate(lat: 48, lon: 12)], size: size, minZoom: 15, maxZoom: 14)
      == nil)
}

@Test func offlineMapFitsPolarCoordinatesWithinMercatorLatitudeLimits() throws {
  let points = [Coordinate(lat: 90, lon: -5), Coordinate(lat: 84, lon: 5)]
  let size = CGSize(width: 500, height: 400)
  let viewport = try #require(
    OfflineMapViewport.fitting(points, size: size, minZoom: 0, maxZoom: 20))
  #expect(viewport.center.lat <= WebMercator.maximumLatitude)
  #expect(viewport.center.lat >= 84)
  expectRouteInsideViewport(points, viewport, size: size, margin: 48)
}

@Test func offlineMapRepeatedWorldTilesLoadOnlyOneCanonicalTile() {
  let placements = OfflineMapTilePlacement.visible(
    center: Coordinate(lat: 0, lon: 179), zoom: 0, size: CGSize(width: 1000, height: 200))
  #expect(placements.count > 1)
  #expect(OfflineMapTilePlacement.keys(in: placements) == [MapTileKey(z: 0, x: 0, y: 0)])
  #expect(
    OfflineMapTilePlacement.visible(
      center: Coordinate(lat: 0, lon: 0), zoom: 20, size: CGSize(width: 10000, height: 10000)
    ).count == PreparedMapTileCache.capacity)
}

private actor PendingMapViewport {
  private let started = AsyncStream<Void>.makeStream()
  private var continuation: CheckedContinuation<OfflineMapViewport?, Never>?
  private(set) var observedCancellation = false

  func calculate() async -> OfflineMapViewport? {
    let result = await withCheckedContinuation { continuation in
      self.continuation = continuation
      started.continuation.yield(())
    }
    observedCancellation = Task.isCancelled
    return result
  }

  func waitUntilStarted() async {
    for await _ in started.stream { break }
  }

  func finish(_ viewport: OfflineMapViewport) {
    continuation?.resume(returning: viewport)
    continuation = nil
  }
}

@Test @MainActor func offlineMapFitRunsOnWorkerAndPublishesOnMainActor() async {
  let fitter = OfflineMapViewportFitter()
  let expected = OfflineMapViewport(center: Coordinate(lat: 48, lon: 12), zoom: 10)
  var applied: OfflineMapViewport?
  let task = fitter.start {
    #expect(#isolation == nil)
    return expected
  } apply: { viewport in
    MainActor.preconditionIsolated()
    applied = viewport
  }
  await task.value
  #expect(applied?.center == expected.center)
  #expect(applied?.zoom == expected.zoom)
}

@Test @MainActor func offlineMapFitCancellationRejectsNoncooperativeLateResult() async {
  let fitter = OfflineMapViewportFitter()
  let gate = PendingMapViewport()
  let expected = OfflineMapViewport(center: Coordinate(lat: 48, lon: 12), zoom: 10)
  var applied = false
  let task = fitter.start {
    await gate.calculate()
  } apply: { _ in
    applied = true
  }
  await gate.waitUntilStarted()
  // Panning, zooming, focus changes and disappearance all use this invalidation.
  fitter.cancel()
  await gate.finish(expected)
  await task.value
  #expect(!applied)
  #expect(await gate.observedCancellation)
}

@Test @MainActor func offlineMapNewFitRejectsPreviousRouteOrEngineResult() async {
  let fitter = OfflineMapViewportFitter()
  let gate = PendingMapViewport()
  let oldViewport = OfflineMapViewport(center: Coordinate(lat: 48, lon: 12), zoom: 10)
  let newViewport = OfflineMapViewport(center: Coordinate(lat: 49, lon: 13), zoom: 12)
  var applied: [Coordinate] = []
  let old = fitter.start {
    await gate.calculate()
  } apply: {
    applied.append($0.center)
  }
  await gate.waitUntilStarted()
  let current = fitter.start {
    newViewport
  } apply: {
    applied.append($0.center)
  }
  await current.value
  await gate.finish(oldViewport)
  await old.value
  #expect(applied == [newViewport.center])
}

@Test @MainActor func offlineMapLateFitCannotReleaseOwnershipOfNewPendingFit() async {
  let fitter = OfflineMapViewportFitter()
  let first = PendingMapViewport()
  let second = PendingMapViewport()
  let viewport = OfflineMapViewport(center: Coordinate(lat: 48, lon: 12), zoom: 10)
  var applied = false
  let old = fitter.start {
    await first.calculate()
  } apply: { _ in
    applied = true
  }
  await first.waitUntilStarted()
  let current = fitter.start {
    await second.calculate()
  } apply: { _ in
    applied = true
  }
  await second.waitUntilStarted()
  await first.finish(viewport)
  await old.value
  fitter.cancel()
  await second.finish(viewport)
  await current.value
  #expect(!applied)
  #expect(await second.observedCancellation)
}

@Test func offlineMapFitGeometryStopsWhenWorkerWasCancelled() async {
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return OfflineMapViewport.fitting(
      [Coordinate(lat: 48, lon: 12)], size: CGSize(width: 390, height: 600), minZoom: 0,
      maxZoom: 20)
  }
  #expect(await task.value == nil)
}

@Test func offlineMapFitsTheWholeRegionInPortraitAndLandscape() throws {
  let bounds = RegionBounds(minLat: 48, maxLat: 49.5, minLon: 11.5, maxLon: 14)
  let corners = [
    Coordinate(lat: bounds.minLat, lon: bounds.minLon),
    Coordinate(lat: bounds.maxLat, lon: bounds.maxLon),
  ]
  let portrait = CGSize(width: 390, height: 600)
  let landscape = CGSize(width: 800, height: 300)
  let first = try #require(
    OfflineMapViewport.fitting(bounds, size: portrait, minZoom: 0, maxZoom: 14))
  let resized = try #require(
    OfflineMapViewport.fitting(bounds, size: landscape, minZoom: 0, maxZoom: 14))
  expectRouteInsideViewport(corners, first, size: portrait, margin: 48)
  expectRouteInsideViewport(corners, resized, size: landscape, margin: 48)
  #expect(resized.zoom < first.zoom)
}

@Test func offlineMapRegionFitPreservesWideBoundsAndSupportsDatelineCrossing() throws {
  let size = CGSize(width: 390, height: 600)
  let wide = try #require(
    OfflineMapViewport.fitting(
      RegionBounds(minLat: -10, maxLat: 10, minLon: -170, maxLon: 170), size: size,
      minZoom: 0, maxZoom: 14))
  let crossing = try #require(
    OfflineMapViewport.fitting(
      RegionBounds(minLat: -10, maxLat: 10, minLon: 170, maxLon: -170), size: size,
      minZoom: 0, maxZoom: 14))
  #expect(abs(wide.center.lon) < 0.000_001)
  #expect(wide.zoom == 0)
  #expect(abs(abs(crossing.center.lon) - 180) < 0.000_001)
  #expect(crossing.zoom >= 4)
  #expect(
    OfflineMapViewport.fitting(
      RegionBounds(minLat: 50, maxLat: 48, minLon: 11, maxLon: 14), size: size,
      minZoom: 0, maxZoom: 14) == nil)
}

@Test func offlineMapCameraKeepsManualNavigationUntilAnExplicitNewTarget() {
  final class Owner {}
  let owner = Owner()
  let other = Owner()
  let path = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 48.1, lon: 12.1)]
  var camera = OfflineMapCameraIntent()
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: nil, hasExplicitCenter: false) == .engine)
  #expect(camera.framing == .region)
  camera.navigate()
  #expect(camera.framing == .manual)
  // View reappearance or layout changes cannot reset an unchanged route/engine.
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: nil, hasExplicitCenter: false) == .unchanged
  )
  #expect(camera.framing == .manual)
  camera.showRegion()
  #expect(camera.framing == .region)
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: path, hasExplicitCenter: false) == .route)
  #expect(camera.framing == .route)
  camera.navigate()
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: path, hasExplicitCenter: false)
      == .unchanged)
  #expect(camera.framing == .manual)
  camera.showRoute()
  #expect(camera.framing == .route)
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: nil, hasExplicitCenter: false) == .route)
  #expect(camera.framing == .manual)
  #expect(
    camera.update(owner: ObjectIdentifier(other), path: nil, hasExplicitCenter: false) == .engine)
  #expect(camera.framing == .region)
}

@Test func offlineMapCameraHonorsExplicitInitialCentersAndEmptyRoutes() {
  final class Owner {}
  let owner = Owner()
  var camera = OfflineMapCameraIntent()
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: [], hasExplicitCenter: true) == .engine)
  #expect(camera.framing == .manual)
  #expect(
    camera.update(owner: ObjectIdentifier(owner), path: nil, hasExplicitCenter: true) == .unchanged)
  #expect(camera.framing == .manual)
}

@Test @MainActor func offlineMapWholeRegionFitUsesTheSameCancellableWorker() async throws {
  let fitter = OfflineMapViewportFitter()
  let bounds = RegionBounds(minLat: 48, maxLat: 49.5, minLon: 11.5, maxLon: 14)
  let size = CGSize(width: 390, height: 600)
  var applied: OfflineMapViewport?
  let task = fitter.fit(bounds, size: size, minZoom: 0, maxZoom: 14) { viewport in
    MainActor.preconditionIsolated()
    applied = viewport
  }
  await task.value
  let viewport = try #require(applied)
  #expect(
    viewport.zoom == OfflineMapViewport.fitting(bounds, size: size, minZoom: 0, maxZoom: 14)?.zoom)
}

@Test func offlineMapLabelsAvoidCollisionsDuplicatesAndMapControls() {
  let viewport = CGSize(width: 390, height: 600)
  var layout = OfflineMapLabelLayout(
    obstacles: [CGRect(x: 300, y: 0, width: 90, height: 200)])
  let first = layout.reserve(
    name: "Landshut", frame: CGRect(x: 80, y: 80, width: 70, height: 20), viewport: viewport)
  #expect(first)
  #expect(!layout.canPlace(name: "Landshut", at: CGPoint(x: 120, y: 190), viewport: viewport))
  #expect(!layout.canPlace(name: "Neuer Ort", at: CGPoint(x: 330, y: 60), viewport: viewport))
  #expect(layout.canPlace(name: "Neuer Ort", at: CGPoint(x: 240, y: 260), viewport: viewport))
  let duplicate = layout.reserve(
    name: " LANDSHUT ", frame: CGRect(x: 80, y: 180, width: 70, height: 20), viewport: viewport)
  #expect(!duplicate)
  let overlapping = layout.reserve(
    name: "Hauptstraße", frame: CGRect(x: 90, y: 90, width: 80, height: 20), viewport: viewport)
  #expect(!overlapping)
  // A rejected candidate may be placed elsewhere in an adjacent tile.
  let relocated = layout.reserve(
    name: "Hauptstraße", frame: CGRect(x: 80, y: 180, width: 80, height: 20), viewport: viewport)
  #expect(relocated)
  let controlOverlap = layout.reserve(
    name: "Dingolfing", frame: CGRect(x: 310, y: 40, width: 70, height: 20), viewport: viewport)
  #expect(!controlOverlap)
  let outside = layout.reserve(
    name: "Außerhalb", frame: CGRect(x: -5, y: 260, width: 70, height: 20), viewport: viewport)
  #expect(!outside)
}

@Test func offlineMapGPSAccuracyReflectsLatitudeAndZoomAndRejectsInvalidFixes() throws {
  let equator = try #require(OfflineMapLocationAccuracy.radius(10, latitude: 0, zoom: 14))
  let northern = try #require(OfflineMapLocationAccuracy.radius(10, latitude: 60, zoom: 14))
  let zoomed = try #require(OfflineMapLocationAccuracy.radius(10, latitude: 0, zoom: 15))
  #expect(abs(northern - equator * 2) < 0.000_001)
  #expect(abs(zoomed - equator * 2) < 0.000_001)
  #expect(OfflineMapLocationAccuracy.radius(nil, latitude: 48, zoom: 14) == nil)
  #expect(OfflineMapLocationAccuracy.radius(-1, latitude: 48, zoom: 14) == nil)
  #expect(OfflineMapLocationAccuracy.radius(.infinity, latitude: 48, zoom: 14) == nil)
  #expect(OfflineMapLocationAccuracy.radius(10, latitude: .nan, zoom: 14) == nil)
  #expect(OfflineMapLocationAccuracy.radius(10, latitude: 100, zoom: 14) == nil)
}

@Test func offlineMapOverzoomUsesNativeTilesInsteadOfRequestingUnavailableDetail() throws {
  let center = WebMercator.coordinate(CGPoint(x: 8192 * 256 + 128, y: 5500 * 256 + 128), zoom: 14)
  let size = CGSize(width: 390, height: 600)
  let placements = OfflineMapTilePlacement.visible(
    center: center, zoom: 18, size: size, tileZoom: 14)
  let placement = try #require(placements.first)
  #expect(placements.count == 1)
  #expect(placement.key == MapTileKey(z: 14, x: 8192, y: 5500))
  #expect(placement.scale(at: 18) == 16)
  #expect(OfflineMapTilePlacement.keys(in: placements) == [placement.key])
  let origin = placement.origin(center: center, zoom: 18, size: size)
  #expect(abs(origin.x + 128 * 16 - size.width / 2) < 0.000_001)
  #expect(abs(origin.y + 128 * 16 - size.height / 2) < 0.000_001)
  let ordinary = OfflineMapTilePlacement.visible(center: center, zoom: 12, size: size, tileZoom: 14)
  #expect(ordinary.allSatisfy { $0.key.z == 12 && $0.scale(at: 12) == 1 })
  #expect(ordinary == OfflineMapTilePlacement.visible(center: center, zoom: 12, size: size))
}

@Test func offlineMapOverzoomKeepsNativeGeometryLabelsTapsAndPanningAligned() throws {
  let center = WebMercator.coordinate(CGPoint(x: 8192 * 256 + 128, y: 5500 * 256 + 128), zoom: 14)
  let size = CGSize(width: 390, height: 600)
  let placement = try #require(
    OfflineMapTilePlacement.visible(center: center, zoom: 18, size: size, tileZoom: 14).first)
  let origin = placement.origin(center: center, zoom: 18, size: size)
  let centerWorld = WebMercator.world(center, zoom: 18)
  for point in [CGPoint(x: 128, y: 128), CGPoint(x: 135, y: 132), CGPoint(x: 120, y: 122)] {
    let coordinate = WebMercator.coordinate(
      CGPoint(
        x: CGFloat(placement.key.x) * 256 + point.x, y: CGFloat(placement.key.y) * 256 + point.y),
      zoom: 14)
    let expected = WebMercator.offset(coordinate, from: center, zoom: 18)
    let screen = CGPoint(x: origin.x + point.x * 16, y: origin.y + point.y * 16)
    #expect(abs(screen.x - size.width / 2 - expected.x) < 0.000_001)
    #expect(abs(screen.y - size.height / 2 - expected.y) < 0.000_001)
    let selected = WebMercator.coordinate(
      CGPoint(
        x: centerWorld.x + screen.x - size.width / 2, y: centerWorld.y + screen.y - size.height / 2),
      zoom: 18)
    #expect(abs(selected.lat - coordinate.lat) < 0.000_001)
    #expect(abs(selected.lon - coordinate.lon) < 0.000_001)
  }
  let translation = CGSize(width: 80, height: -40)
  let pannedCenter = WebMercator.coordinate(
    CGPoint(x: centerWorld.x - translation.width, y: centerWorld.y - translation.height), zoom: 18)
  let afterPan = placement.origin(center: pannedCenter, zoom: 18, size: size)
  #expect(abs(afterPan.x - origin.x - translation.width) < 0.000_001)
  #expect(abs(afterPan.y - origin.y - translation.height) < 0.000_001)
  let accuracy = try #require(OfflineMapLocationAccuracy.radius(10, latitude: center.lat, zoom: 14))
  let overzoomAccuracy = try #require(
    OfflineMapLocationAccuracy.radius(10, latitude: center.lat, zoom: 18))
  #expect(abs(overzoomAccuracy - accuracy * 16) < 0.000_001)
}

@Test func offlineMapOverzoomWrapsNativeTilesAtTheDatelineAndKeepsTheCacheBounded() throws {
  let center = Coordinate(lat: 0, lon: 179.9999)
  let across = Coordinate(lat: 0, lon: -179.9999)
  let size = CGSize(width: 390, height: 600)
  let placements = OfflineMapTilePlacement.visible(
    center: center, zoom: 18, size: size, tileZoom: 14)
  #expect(placements.contains { $0.key.x == 16383 && $0.worldX == 16383 })
  let placement = try #require(placements.first { $0.key.x == 0 && $0.worldX == 16384 })
  let nativePoint = WebMercator.world(across, zoom: 14)
  let offset = WebMercator.offset(across, from: center, zoom: 18)
  let origin = placement.origin(center: center, zoom: 18, size: size)
  #expect(abs(origin.x + nativePoint.x * 16 - size.width / 2 - offset.x) < 0.000_001)
  #expect(placements.allSatisfy { $0.key.z == 14 && (0..<16384).contains($0.key.x) })
  let enormous = OfflineMapTilePlacement.visible(
    center: center, zoom: 18, size: CGSize(width: 1_000_000, height: 1_000_000), tileZoom: 14)
  #expect(enormous.count == PreparedMapTileCache.capacity)
  #expect(
    OfflineMapTilePlacement.visible(center: center, zoom: 18, size: size, tileZoom: -1).isEmpty)
}

@Test func offlineMapDestinationOnlyKeepsItsBMarkerAndExplicitEndpointsReplaceLegacyMarkers() throws
{
  let start = Coordinate(lat: 48.1, lon: 12.1)
  let destination = Coordinate(lat: 48.2, lon: 12.2)
  let legacy = Coordinate(lat: 49, lon: 13)
  let onlyDestination = OfflineMapMarker.make(
    legacy: [legacy], start: nil, destination: destination)
  #expect(onlyDestination.count == 1)
  let marker = try #require(onlyDestination.first)
  #expect(marker.coordinate == destination)
  #expect(marker.label == "B")
  #expect(marker.role == .destination)
  let both = OfflineMapMarker.make(legacy: [legacy], start: start, destination: destination)
  #expect(both.map(\.coordinate) == [start, destination])
  #expect(both.map(\.label) == ["A", "B"])
  #expect(both.map(\.role) == [.start, .destination])
}

@Test func offlineMapLegacyMarkersRetainTheirExistingOrderAndRoles() {
  let coordinates = [
    Coordinate(lat: 48, lon: 12), Coordinate(lat: 48.1, lon: 12.1),
    Coordinate(lat: 48.2, lon: 12.2),
  ]
  let markers = OfflineMapMarker.make(legacy: coordinates, start: nil, destination: nil)
  #expect(markers.map(\.coordinate) == coordinates)
  #expect(markers.map(\.label) == ["A", "B", "3"])
  #expect(markers.map(\.role) == [.start, .destination, .other])
}

@Test func offlineMapCanRepeatFocusAtTheSameCoordinateWithoutChangingEngineOrRoute() {
  let coordinate = Coordinate(lat: 48, lon: 12)
  let firstID = UUID()
  let request = OfflineMapFocusRequest(coordinate: coordinate, id: firstID)
  #expect(request == OfflineMapFocusRequest(coordinate: coordinate, id: firstID))
  #expect(request != OfflineMapFocusRequest(coordinate: coordinate, id: UUID()))
  #expect(
    OfflineMapFocusRequest(coordinate: coordinate, id: nil)
      == OfflineMapFocusRequest(coordinate: coordinate, id: nil))
  #expect(request != OfflineMapFocusRequest(coordinate: nil, id: firstID))
}
