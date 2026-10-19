import Foundation
import SwiftUI
import Testing

@testable import OSMmini

/// Previous scalar construction, independent of the batched implementation.
private func scalarMapPath(_ paths: [[[Int]]], kind: Int, scale: Double) -> Path {
  var path = Path()
  for ring in paths {
    for (index, point) in ring.enumerated() where point.count >= 2 {
      let position = CGPoint(x: Double(point[0]) * scale, y: Double(point[1]) * scale)
      if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
    }
    if kind == 3 { path.closeSubpath() }
  }
  return path
}

private func pathElements(_ path: Path) -> [Path.Element] {
  var elements: [Path.Element] = []
  // swift-format-ignore: ReplaceForEachWithForLoop
  path.forEach { elements.append($0) }
  return elements
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"] != nil))
func batchedRealRegionPathsMatchScalarGeometry() async throws {
  let directory = try #require(ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"])
  let engine = try await OfflineEngine.open(URL(fileURLWithPath: directory))
  do {
    var checked = 0
    for center in [
      Coordinate(lat: 48.5667, lon: 13.4319), Coordinate(lat: 48.5442, lon: 12.1469),
      Coordinate(lat: 48.8353, lon: 12.9630), Coordinate(lat: 48.8813, lon: 12.5739),
    ] {
      for z in [12, 14] {
        let point = WebMercator.world(center, zoom: z)
        let tile = try await engine.tile(
          z: z, x: Int(floor(point.x / 256)), y: Int(floor(point.y / 256)))
        let prepared = try PreparedMapTile(tile)
        var index = 0
        for feature in tile.features
        where feature.extent > 0
          && ["water", "landcover", "building", "transportation"].contains(feature.layer)
        {
          let expected = scalarMapPath(
            feature.paths, kind: feature.kind, scale: 256 / Double(feature.extent))
          #expect(pathElements(prepared.features[index].path) == pathElements(expected))
          index += 1
          checked += 1
        }
        #expect(index == prepared.features.count)
      }
    }
    #expect(checked > 0)
    print("Real map path equivalence: \(checked) feature paths in eight Niederbayern city tiles")
    await engine.close()
  } catch {
    await engine.close()
    throw error
  }
}

@Test func batchedMapPathsMatchScalarGeometryAndRetainOwnedCoordinates() throws {
  let fixtures = [
    [], [[]], [[[1, 2]]], [[[0, 0], [4, 4], [4, 4], [8, 0]]],
    [[[-8, -8], [264, -8], [264, 264], [-8, 264]], [[8, 8], [80, 8], [80, 80], [8, 80]]],
    [[[0, 0], [10, 0]], [[], [20, 20], [30, 30]], [], [[50], [60, 60]], [[]]],
  ]
  var points: [CGPoint] = []
  var retained: [(Path, [Path.Element])] = []
  for kind in [1, 2, 3] {
    for scale in [0.0625, 256.0 / 1001, 1, 16] {
      for paths in fixtures {
        let expected = pathElements(scalarMapPath(paths, kind: kind, scale: scale))
        let actual = try PreparedMapTile.preparePath(
          paths, kind: kind, scale: scale, points: &points)
        #expect(pathElements(actual) == expected)
        retained.append((actual, expected))
      }
    }
  }
  points.removeAll(keepingCapacity: true)
  points.append(CGPoint(x: 10000, y: 10000))
  for (path, expected) in retained { #expect(pathElements(path) == expected) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapPathPreparationBenchmark() throws {
  let clock = ContinuousClock()
  for (name, features, vertices, rings, kind) in [
    ("roads", 200, 128, 1, 2), ("multipart", 100, 96, 4, 2), ("buildings", 1000, 5, 1, 3),
  ] {
    let geometry = (0..<features).map { feature in
      (0..<rings).map { ring in
        (0..<vertices).map { vertex in
          [vertex * 32 + ring * 11, (feature * 31 + vertex * 37 + ring * 7) % 4096]
        }
      }
    }
    for pass in 0..<3 {
      var counts: [Int] = []
      for batch in pass.isMultiple(of: 2) ? [false, true] : [true, false] {
        var points: [CGPoint] = []
        var count = 0
        let begin = clock.now
        for _ in 0..<20 {
          for paths in geometry {
            let path =
              try batch
              ? PreparedMapTile.preparePath(paths, kind: kind, scale: 0.0625, points: &points)
              : scalarMapPath(paths, kind: kind, scale: 0.0625)
            if !path.isEmpty { count += 1 }
          }
        }
        counts.append(count)
        print(
          "Map path pass \(pass+1), \(name), batch=\(batch): \(begin.duration(to:clock.now)); \(count) paths"
        )
      }
      #expect(counts[0] == counts[1])
    }
  }
}
