import Foundation
import SwiftUI
import Testing

@testable import OSMmini

/// Retained implementation for exact selection and paint-order comparisons.
private struct BucketTileIndex {
  private static let levels = [(side: 1, offset: 0), (2, 1), (4, 5), (8, 21)]
  private static let tileBounds = PreparedMapTileIndex.tileBounds
  private static let cells: [CGRect] = levels.flatMap { side, _ in
    let width = 256 / Double(side)
    return (0..<side).flatMap { y in
      (0..<side).map { x in
        CGRect(x: Double(x) * width, y: Double(y) * width, width: width, height: width)
      }
    }
  }
  private let offsets: [UInt32]
  private let indices: [UInt32]

  @inline(never) init?(_ features: [PreparedMapTile.Feature]) throws {
    guard features.count >= 128, features.count <= UInt32.max else { return nil }
    var buckets = Array(repeating: [UInt32](), count: Self.cells.count)
    for (index, feature) in features.enumerated() {
      if index.isMultiple(of: 256) { try Task.checkCancellation() }
      buckets[Self.cell(containing: feature.path.boundingRect)].append(UInt32(index))
    }
    guard buckets[0].count < features.count else { return nil }
    var offsets: [UInt32] = []
    var indices: [UInt32] = []
    offsets.reserveCapacity(buckets.count + 1)
    indices.reserveCapacity(features.count)
    for bucket in buckets {
      try Task.checkCancellation()
      offsets.append(UInt32(indices.count))
      indices.append(contentsOf: bucket)
    }
    offsets.append(UInt32(indices.count))
    self.offsets = offsets
    self.indices = indices
  }

  private static func cell(containing bounds: CGRect) -> Int {
    guard !bounds.isNull, tileBounds.contains(bounds) else { return 0 }
    for (side, offset) in levels.reversed() {
      let width = 256 / Double(side)
      let minX = min(side - 1, Int(bounds.minX / width))
      let minY = min(side - 1, Int(bounds.minY / width))
      let maxX = min(side - 1, Int(bounds.maxX / width))
      let maxY = min(side - 1, Int(bounds.maxY / width))
      if minX == maxX, minY == maxY { return offset + minY * side + minX }
    }
    return 0
  }

  @inline(never) func featureIndices(in rect: CGRect) -> PreparedMapFeatureIndices {
    var selected: [UInt32] = []
    for (cell, bounds) in Self.cells.enumerated() where bounds.intersects(rect) {
      selected.append(contentsOf: indices[Int(offsets[cell])..<Int(offsets[cell + 1])])
    }
    if selected.count == indices.count { return PreparedMapFeatureIndices(count: indices.count) }
    selected.sort()
    return PreparedMapFeatureIndices(selected)
  }
}

private func tileIndexFeatures(_ count: Int) -> [PreparedMapTile.Feature] {
  (0..<count).map { index in
    let x = Double((index * 61) % 260) - 2
    let y = Double((index * 37) % 260) - 2
    let size = index.isMultiple(of: 17) ? 100.0 : 2.0
    let rect = CGRect(x: x, y: y, width: size, height: size)
    return PreparedMapTile.Feature(path: Path(rect), style: .building)
  }
}

private func tileIndexViewports() -> [CGRect] {
  var rects = [CGRect.null, .infinite, .zero, PreparedMapTileIndex.tileBounds]
  rects.append(contentsOf: [
    CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
    CGRect(x: 0, y: CGFloat.nan, width: 10, height: 10),
    CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10),
    CGRect(x: 0, y: 0, width: 10, height: CGFloat.nan),
  ])
  for edge in stride(from: -32.0, through: 288, by: 32) {
    for delta in [-0.001, 0, 0.001] {
      for size in [0.0, 0.001, 32, 64, -32] {
        rects.append(CGRect(x: edge + delta, y: edge + delta, width: size, height: size))
      }
    }
  }
  for index in 0..<500 {
    rects.append(
      CGRect(
        x: Double((index * 37) % 320) - 32.25,
        y: Double((index * 61) % 320) - 32.5,
        width: Double((index * 17) % 270) + 0.25,
        height: Double((index * 23) % 270) + 0.5))
  }
  return rects
}

private func verifyTileIndex(_ features: [PreparedMapTile.Feature]) throws {
  let reference = try BucketTileIndex(features)
  let actual = try PreparedMapTileIndex(features)
  #expect((reference == nil) == (actual == nil))
  guard let reference, let actual else { return }
  for viewport in tileIndexViewports() {
    #expect(
      Array(actual.featureIndices(in: viewport))
        == Array(reference.featureIndices(in: viewport)), "Different paint order at \(viewport)")
  }
}

@Test func tileIndexRetainsExactSelectionAtGridAndTileBoundaries() throws {
  try verifyTileIndex(tileIndexFeatures(127))
  try verifyTileIndex(tileIndexFeatures(128))
  try verifyTileIndex(tileIndexFeatures(4096))
  try verifyTileIndex(
    Array(repeating: PreparedMapTile.Feature(path: Path(), style: .water), count: 128))
}

private func regionalIndexFeatures() async throws -> [[PreparedMapTile.Feature]] {
  let path = try #require(ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"])
  let engine = try await OfflineEngine.open(URL(fileURLWithPath: path, isDirectory: true))
  do {
    var tiles: [[PreparedMapTile.Feature]] = []
    for center in [
      Coordinate(lat: 48.574, lon: 13.450), Coordinate(lat: 48.549, lon: 12.137),
      Coordinate(lat: 48.832, lon: 12.960), Coordinate(lat: 48.881, lon: 12.573),
    ] {
      for zoom in [12, 14] {
        let point = WebMercator.world(center, zoom: zoom)
        let tile = try await engine.tile(z: zoom, x: Int(point.x / 256), y: Int(point.y / 256))
        tiles.append(try PreparedMapTile(tile).features)
      }
    }
    await engine.close()
    return tiles
  } catch {
    await engine.close()
    throw error
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"] != nil))
func tileIndexRetainsExactRegionalPaintOrder() async throws {
  let tiles = try await regionalIndexFeatures()
  for features in tiles { try verifyTileIndex(features) }
  print(
    "Exact tile-index selection: \(tiles.count) real tiles, \(tiles.reduce(0) { $0 + $1.count }) paths"
  )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func tileIndexPreparationAndSelectionBenchmark() async throws {
  var fixtures = [("synthetic", [tileIndexFeatures(4096)])]
  if ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"] != nil {
    fixtures.append(("regional", try await regionalIndexFeatures()))
  }
  let clock = ContinuousClock()
  for (name, tiles) in fixtures {
    let viewports = tileIndexViewports().filter { !$0.isEmpty && !$0.isNull && !$0.isInfinite }
    for pass in 0..<3 {
      for optimized in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
        var prepared = 0
        let preparation = try clock.measure {
          for _ in 0..<100 {
            for features in tiles {
              if optimized {
                prepared += try PreparedMapTileIndex(features)?.storageBytes ?? 0
              } else {
                prepared += try BucketTileIndex(features) == nil ? 0 : features.count * 4 + 344
              }
            }
          }
        }
        var selected = 0
        let selection: Duration
        if optimized {
          let indices = try tiles.compactMap { try PreparedMapTileIndex($0) }
          selection = clock.measure {
            for _ in 0..<10 {
              for viewport in viewports {
                for index in indices {
                  for feature in index.featureIndices(in: viewport) { selected += feature }
                }
              }
            }
          }
        } else {
          let indices = try tiles.compactMap { try BucketTileIndex($0) }
          selection = clock.measure {
            for _ in 0..<10 {
              for viewport in viewports {
                for index in indices {
                  for feature in index.featureIndices(in: viewport) { selected += feature }
                }
              }
            }
          }
        }
        print(
          "Tile index \(name) pass \(pass + 1) \(optimized ? "contiguous" : "buckets"): prepare \(preparation), select \(selection), checksum \(prepared)/\(selected)"
        )
      }
    }
  }
}
