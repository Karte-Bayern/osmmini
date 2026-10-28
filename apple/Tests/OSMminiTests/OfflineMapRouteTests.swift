import Foundation
import SwiftUI
import Testing

@testable import OSMmini

private func routeVertices(_ path: Path) -> [CGPoint] {
  var points: [CGPoint] = []
  // swift-format-ignore: ReplaceForEachWithForLoop
  path.forEach { element in
    switch element {
    case .move(let point), .line(let point): points.append(point)
    default: break
    }
  }
  return points
}

@Test func offlineMapPreparedRoutePreservesEverySegmentAcrossChunks() throws {
  let coordinates = (0...10_000).map {
    Coordinate(lat: 48 + Double($0) * 0.000_01, lon: 10 + Double($0) * 0.000_1)
  }
  let prepared = try PreparedMapRoute(coordinates)
  #expect(prepared.chunks.count == 79)
  #expect(prepared.chunks.reduce(0) { $0 + $1.pointCount - 1 } == coordinates.count - 1)
  for index in 1..<prepared.chunks.count {
    let previousChunk = prepared.chunks[index - 1]
    let previous = try #require(routeVertices(previousChunk.path).last)
    let currentChunk = prepared.chunks[index]
    let current = routeVertices(currentChunk.path)
    #expect(abs(previous.x + previousChunk.origin.x - currentChunk.origin.x) < 0.000_000_1)
    #expect(abs(previous.y + previousChunk.origin.y - currentChunk.origin.y) < 0.000_000_1)
    #expect(current.first == .zero)
    #expect(current.count <= PreparedMapRoute.pointsPerChunk)
  }
  #expect(prepared.chunks[0].origin == WebMercator.world(coordinates[0], zoom: 0))
  let lastChunk = try #require(prepared.chunks.last)
  let lastPoint = try #require(routeVertices(lastChunk.path).last)
  let expected = WebMercator.world(coordinates.last!, zoom: 0)
  #expect(abs(lastPoint.x + lastChunk.origin.x - expected.x) < 0.000_000_1)
  #expect(abs(lastPoint.y + lastChunk.origin.y - expected.y) < 0.000_000_1)
}

@Test func offlineMapPreparedRouteProjectionMatchesMarkersDuringDragAndOverzoom() throws {
  let coordinates = [
    Coordinate(lat: 78, lon: 12), Coordinate(lat: 78.000_1, lon: 12.000_1),
    Coordinate(lat: 78.000_2, lon: 12.000_2),
  ]
  let center = coordinates[1]
  let size = CGSize(width: 390, height: 600)
  let translation = CGSize(width: -37, height: 29)
  let prepared = try PreparedMapRoute(coordinates)
  for zoom in [5, 14, 18] {
    let placement = try #require(
      prepared.visible(center: center, zoom: zoom, size: size, translation: translation).first)
    let vertices = routeVertices(prepared.chunks[placement.index].path)
    for (coordinate, point) in zip(coordinates, vertices) {
      let expected = WebMercator.offset(coordinate, from: center, zoom: zoom)
      #expect(
        abs(
          point.x * placement.scale + placement.origin.x - expected.x - size.width / 2
            - translation.width) < 0.001)
      #expect(
        abs(
          point.y * placement.scale + placement.origin.y - expected.y - size.height / 2
            - translation.height) < 0.001)
    }
  }
}

@Test func offlineMapPreparedRouteCullsDistantLongRouteSections() throws {
  let coordinates = (0...20_000).map {
    Coordinate(lat: 48, lon: -100 + Double($0) * 0.01)
  }
  let prepared = try PreparedMapRoute(coordinates)
  let visible = prepared.visible(
    center: Coordinate(lat: 48, lon: 0), zoom: 18, size: CGSize(width: 390, height: 600))
  #expect(prepared.chunks.count == 158)
  #expect(!visible.isEmpty)
  #expect(visible.count <= 2)
  #expect(visible.reduce(0) { $0 + prepared.chunks[$1.index].pointCount } <= 256)
  #expect(
    prepared.visible(
      center: Coordinate(lat: -48, lon: 0), zoom: 18, size: CGSize(width: 390, height: 600)
    )
    .isEmpty)
}

@Test func offlineMapPreparedRouteKeepsCrossingSegmentsWhoseEndpointsAreOffscreen() throws {
  let prepared = try PreparedMapRoute([
    Coordinate(lat: 48, lon: -1), Coordinate(lat: 48, lon: 1),
  ])
  #expect(
    prepared.visible(
      center: Coordinate(lat: 48, lon: 0), zoom: 12, size: CGSize(width: 390, height: 600)
    )
    .count == 1)
  let vertical = try PreparedMapRoute([
    Coordinate(lat: 47, lon: 0), Coordinate(lat: 49, lon: 0),
  ])
  #expect(
    vertical.visible(
      center: Coordinate(lat: 48, lon: 0), zoom: 12, size: CGSize(width: 390, height: 600)
    )
    .count == 1)
}

@Test func offlineMapPreparedRouteWrapsDatelineWithoutDrawingThroughOtherCountries() throws {
  let prepared = try PreparedMapRoute([
    Coordinate(lat: 48, lon: 179.99), Coordinate(lat: 48, lon: -179.99),
  ])
  #expect(prepared.chunks.count == 1)
  #expect(prepared.chunks[0].bounds.width < 0.02)
  let size = CGSize(width: 390, height: 600)
  for longitude in [179.999, -179.999] {
    let placement = try #require(
      prepared.visible(center: Coordinate(lat: 48, lon: longitude), zoom: 12, size: size).first)
    for point in routeVertices(prepared.chunks[0].path) {
      let x = point.x * placement.scale + placement.origin.x
      #expect(x > 100 && x < 290)
    }
  }
  #expect(
    prepared.visible(center: Coordinate(lat: 48, lon: 0), zoom: 12, size: size).isEmpty)
}

@Test func offlineMapPreparedRouteRepeatsWithWrappedWorldTilesAtLowZoom() throws {
  let prepared = try PreparedMapRoute([
    Coordinate(lat: 0, lon: 179), Coordinate(lat: 0, lon: -179),
  ])
  let placements = prepared.visible(
    center: Coordinate(lat: 0, lon: 0), zoom: 0, size: CGSize(width: 600, height: 300))
  #expect(placements.count == 2)
  #expect(abs(placements[1].origin.x - placements[0].origin.x - 256) < 0.000_001)
}

@Test func offlineMapPreparedRouteBreaksInvalidCoordinatesInsteadOfConnectingAcrossThem() throws {
  let prepared = try PreparedMapRoute([
    Coordinate(lat: 48, lon: 10), Coordinate(lat: 48, lon: 11),
    Coordinate(lat: .nan, lon: 12),
    Coordinate(lat: 48, lon: 13), Coordinate(lat: 48, lon: 14),
  ])
  #expect(prepared.chunks.map(\.pointCount) == [2, 2])
  #expect(prepared.chunks.allSatisfy { $0.bounds.width < 1 })
  #expect(
    prepared.visible(
      center: Coordinate(lat: 48, lon: 12), zoom: 12, size: CGSize(width: CGFloat.nan, height: 600)
    )
    .isEmpty)
}

@Test func offlineMapRoutePreparationStopsWhenCancelled() async {
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    do {
      _ = try PreparedMapRoute([Coordinate(lat: 48, lon: 12)])
      Issue.record("Cancelled route preparation completed")
    } catch {
      #expect(error is CancellationError)
    }
  }
  await task.value
}

private actor PendingPreparedRoute {
  private let started = AsyncStream<Void>.makeStream()
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var observedCancellation = false

  func prepare(_ coordinates: [Coordinate]) async throws -> PreparedMapRoute {
    // Prepare before suspension so tests can simulate a worker which ignores
    // cancellation and still returns an obsolete result.
    let prepared = try PreparedMapRoute(coordinates)
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started.continuation.yield(())
    }
    observedCancellation = Task.isCancelled
    return prepared
  }

  func waitUntilStarted() async {
    for await _ in started.stream { break }
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

@Test @MainActor func offlineMapPreparedRouteRunsOffMainActorAndNeverReusesAnotherPathOrRegion()
  async
{
  final class Owner {}
  let first = Owner()
  let second = Owner()
  let firstID = ObjectIdentifier(first)
  let secondID = ObjectIdentifier(second)
  let coordinates = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 13)]
  let different = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 14)]
  let loader = OfflineMapRouteLoader()
  await loader.load(owner: firstID, coordinates: coordinates) { path in
    #expect(#isolation == nil)
    return try PreparedMapRoute(path)
  }
  #expect(loader.route(owner: firstID, coordinates: coordinates)?.chunks.count == 1)
  #expect(loader.route(owner: firstID, coordinates: different) == nil)
  #expect(loader.route(owner: secondID, coordinates: coordinates) == nil)
  await loader.load(owner: firstID, coordinates: nil)
  #expect(loader.route(owner: firstID, coordinates: coordinates) == nil)
}

@Test @MainActor func offlineMapPreparedRouteRejectsLateReplacementAndCancelledResults()
  async throws
{
  final class Owner {}
  let owner = Owner()
  let identity = ObjectIdentifier(owner)
  let oldPath = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 13)]
  let newPath = [Coordinate(lat: 50, lon: 12), Coordinate(lat: 51, lon: 13)]
  let loader = OfflineMapRouteLoader()
  let gate = PendingPreparedRoute()
  let old = Task {
    await loader.load(owner: identity, coordinates: oldPath) { try await gate.prepare($0) }
  }
  await gate.waitUntilStarted()
  await loader.load(owner: identity, coordinates: newPath)
  await gate.finish()
  await old.value
  #expect(loader.route(owner: identity, coordinates: oldPath) == nil)
  #expect(loader.route(owner: identity, coordinates: newPath)?.chunks.count == 1)

  let cancelledGate = PendingPreparedRoute()
  let cancelled = Task {
    await loader.load(owner: identity, coordinates: oldPath) { try await cancelledGate.prepare($0) }
  }
  await cancelledGate.waitUntilStarted()
  cancelled.cancel()
  await cancelledGate.finish()
  await cancelled.value
  #expect(await cancelledGate.observedCancellation)
  #expect(loader.route(owner: identity, coordinates: oldPath) == nil)
  await loader.load(owner: identity, coordinates: oldPath)
  #expect(loader.route(owner: identity, coordinates: oldPath)?.chunks.count == 1)
}

@Test @MainActor func cancelledStaleRouteRequestCannotClearThePublishedRoute() async {
  let currentOwner = NSObject(), obsoleteOwner = NSObject()
  let identity = ObjectIdentifier(currentOwner)
  let coordinates = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 13)]
  let loader = OfflineMapRouteLoader()
  await loader.load(owner: identity, coordinates: coordinates)
  let stale = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await loader.load(owner: ObjectIdentifier(obsoleteOwner), coordinates: nil)
  }
  await stale.value
  #expect(loader.route(owner: identity, coordinates: coordinates)?.chunks.count == 1)
}

@Test @MainActor func cancelledStaleRouteRequestCannotInvalidateTheCurrentWorker() async {
  let owner = NSObject()
  let identity = ObjectIdentifier(owner)
  let coordinates = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 13)]
  let loader = OfflineMapRouteLoader()
  let gate = PendingPreparedRoute()
  let current = Task {
    await loader.load(owner: identity, coordinates: coordinates) { try await gate.prepare($0) }
  }
  await gate.waitUntilStarted()
  let stale = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await loader.load(owner: identity, coordinates: nil)
  }
  await stale.value
  await gate.finish()
  await current.value
  #expect(loader.route(owner: identity, coordinates: coordinates)?.chunks.count == 1)
}

private actor RoutePreparationCounter {
  private(set) var count = 0
  func prepare(_ coordinates: [Coordinate]) throws -> PreparedMapRoute {
    count += 1
    return try PreparedMapRoute(coordinates)
  }
}

@Test @MainActor func mapReappearanceReusesOnlyTheSamePreparedRouteAndRegion() async {
  let first = NSObject(), second = NSObject()
  let firstID = ObjectIdentifier(first), secondID = ObjectIdentifier(second)
  let coordinates = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 13)]
  let changed = [Coordinate(lat: 48, lon: 12), Coordinate(lat: 49, lon: 14)]
  let loader = OfflineMapRouteLoader()
  let preparations = RoutePreparationCounter()
  for _ in 0..<3 {
    await loader.load(owner: firstID, coordinates: coordinates) { try await preparations.prepare($0) }
    #expect(loader.route(owner: firstID, coordinates: coordinates)?.chunks.count == 1)
  }
  #expect(await preparations.count == 1)
  await loader.load(owner: firstID, coordinates: changed) { try await preparations.prepare($0) }
  #expect(await preparations.count == 2)
  #expect(loader.route(owner: firstID, coordinates: changed)?.chunks.count == 1)
  #expect(loader.route(owner: firstID, coordinates: coordinates) == nil)
  await loader.load(owner: secondID, coordinates: changed) { try await preparations.prepare($0) }
  #expect(await preparations.count == 3)
  #expect(loader.route(owner: secondID, coordinates: changed)?.chunks.count == 1)
  #expect(loader.route(owner: firstID, coordinates: changed) == nil)
}
