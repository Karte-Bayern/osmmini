import Foundation
import SwiftUI
import Testing

@testable import OSMmini

/// Scalar route construction retained independently of the batched path builder.
private func scalarRouteChunks(_ coordinates: [Coordinate]) throws -> [PreparedMapRoute.Chunk] {
  var chunks: [PreparedMapRoute.Chunk] = []
  var points: [CGPoint] = []
  points.reserveCapacity(PreparedMapRoute.pointsPerChunk)
  var previous: CGPoint?
  func flush() {
    guard points.count > 1 else { return }
    let origin = points[0]
    var path = Path()
    var minX = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var minY = CGFloat.infinity
    var maxY = -CGFloat.infinity
    for (index, point) in points.enumerated() {
      let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
      if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }
    chunks.append(
      PreparedMapRoute.Chunk(
        path: path, origin: origin,
        bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
        pointCount: points.count))
  }
  for (index, coordinate) in coordinates.enumerated() {
    if index.isMultiple(of: 1024) { try Task.checkCancellation() }
    guard coordinate.lat.isFinite, coordinate.lon.isFinite else {
      flush()
      points.removeAll(keepingCapacity: true)
      previous = nil
      continue
    }
    var point = WebMercator.world(
      Coordinate(lat: coordinate.lat, lon: coordinate.lon.truncatingRemainder(dividingBy: 360)),
      zoom: 0)
    if let previous { point.x += ((previous.x - point.x) / 256).rounded() * 256 }
    points.append(point)
    previous = point
    if points.count == PreparedMapRoute.pointsPerChunk {
      flush()
      points.removeAll(keepingCapacity: true)
      points.append(point)
    }
  }
  try Task.checkCancellation()
  flush()
  return chunks
}

private func routeElements(_ path: Path) -> [Path.Element] {
  var elements: [Path.Element] = []
  // swift-format-ignore: ReplaceForEachWithForLoop
  path.forEach { elements.append($0) }
  return elements
}

@Test func batchedRoutePathsMatchScalarGeometryAcrossChunksAndBreaks() throws {
  let dense = (0..<1291).map {
    Coordinate(lat: 78 + Double($0) * 0.000_001, lon: 12 + Double($0) * 0.000_003)
  }
  let dateline = (0..<390).map {
    Coordinate(lat: 48 + Double($0) * 0.000_003, lon: $0.isMultiple(of: 2) ? 179.99 : -179.99)
  }
  for coordinates in [
    [], [Coordinate(lat: 0, lon: 0)], Array(dense.prefix(127)), Array(dense.prefix(128)),
    Array(dense.prefix(129)), dense, dateline,
    dense + [Coordinate(lat: .nan, lon: 12)] + dateline,
    [Coordinate(lat: .infinity, lon: 12)] + dateline + [Coordinate(lat: 48, lon: .infinity)],
  ] {
    let expected = try scalarRouteChunks(coordinates)
    let actual = try PreparedMapRoute(coordinates)
    #expect(actual.chunks.count == expected.count)
    for (chunk, reference) in zip(actual.chunks, expected) {
      #expect(chunk.origin == reference.origin)
      #expect(chunk.bounds == reference.bounds)
      #expect(chunk.pointCount == reference.pointCount)
      #expect(routeElements(chunk.path) == routeElements(reference.path))
    }
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapRoutePreparationBenchmark() throws {
  let coordinates = (0..<50_000).map {
    Coordinate(lat: 48 + Double($0) * 0.000_01, lon: 12 + Double($0) * 0.000_03)
  }
  let clock = ContinuousClock()
  for pass in 0..<3 {
    var counts: [Int] = []
    for batch in pass.isMultiple(of: 2) ? [false, true] : [true, false] {
      var count = 0
      let elapsed = try clock.measure {
        for _ in 0..<20 {
          let chunks =
            try batch ? PreparedMapRoute(coordinates).chunks : scalarRouteChunks(coordinates)
          for chunk in chunks { count += chunk.pointCount }
        }
      }
      counts.append(count)
      print("Map route preparation pass \(pass + 1), batch=\(batch): \(elapsed); \(count) points")
    }
    #expect(counts[0] == counts[1])
  }
}
