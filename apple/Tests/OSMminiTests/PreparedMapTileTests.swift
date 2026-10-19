import Foundation
import SwiftUI
import Testing

@testable import OSMmini

private func mapFeature(
  _ layer: String = "transportation", kind: Int = 2, extent: Int = 4096,
  classification: String? = "primary", name: String? = "Teststraße", paths: [[[Int]]]
) -> VectorFeature {
  VectorFeature(
    layer: layer, kind: kind, extent: extent, class: classification, name: name, paths: paths)
}

/// The renderer's original per-frame conversion, retained here as a reference.
private func framePath(_ feature: VectorFeature, offset: CGPoint) -> Path {
  var path = Path()
  for ring in feature.paths {
    for (index, point) in ring.enumerated() where point.count >= 2 {
      let position = CGPoint(
        x: offset.x + Double(point[0]) / Double(feature.extent) * 256,
        y: offset.y + Double(point[1]) / Double(feature.extent) * 256)
      if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
    }
    if feature.kind == 3 { path.closeSubpath() }
  }
  return path
}

@Test func preparedMapGeometryPreservesCoordinatesAndPolygonHoles() throws {
  let polygon = mapFeature(
    "water", kind: 3,
    paths: [
      [[-16, -16], [4112, -16], [4112, 4112], [-16, 4112]],
      [[1024, 1024], [3072, 1024], [3072, 3072], [1024, 3072]],
    ])
  let road = mapFeature(paths: [[[0, 0], [2048, 1024], [4096, 4096]]])
  let prepared = try PreparedMapTile(VectorTile(features: [polygon, road]))
  #expect(prepared.features.count == 2)
  #expect(prepared.features[0].style == .water)
  #expect(prepared.features[1].style == .road(major: true))
  #expect(prepared.labels[0].name == "Teststraße")
  let roadLabel = try #require(prepared.labels.first?.point)
  #expect(roadLabel.x > 128 && roadLabel.x < 256)
  #expect(roadLabel.y > 64 && roadLabel.y < 256)
  #expect(prepared.labels.count == 1)
  #expect(prepared.features[0].path.contains(CGPoint(x: 10, y: 10), eoFill: true))
  #expect(!prepared.features[0].path.contains(CGPoint(x: 128, y: 128), eoFill: true))
  for offset in [CGPoint.zero, CGPoint(x: -125.5, y: 67.25), CGPoint(x: 512, y: -256)] {
    let translation = CGAffineTransform(translationX: offset.x, y: offset.y)
    for (feature, original) in zip(prepared.features, [polygon, road]) {
      var translated: [Path.Element] = []
      var reference: [Path.Element] = []
      // Path exposes its elements by callback; it is not a Sequence.
      // swift-format-ignore: ReplaceForEachWithForLoop
      feature.path.applying(translation).forEach { translated.append($0) }
      // swift-format-ignore: ReplaceForEachWithForLoop
      framePath(original, offset: offset).forEach { reference.append($0) }
      #expect(translated == reference)
    }
  }
}

@Test func preparedLabelsUseTheLongestRoadMidpointAndKeepSettlementPoints() throws {
  let road = mapFeature(paths: [
    [[0, 0], [100, 0]], [[1000, 1000], [3000, 1000], [3000, 2000]],
  ])
  let place = mapFeature(
    "place", kind: 1, classification: "town", name: "Dingolfing", paths: [[[2048, 1024]]])
  let prepared = try PreparedMapTile(VectorTile(features: [road, place]))
  #expect(prepared.features.count == 1)
  #expect(prepared.labels.count == 2)
  #expect(prepared.labels[0].point == CGPoint(x: 156.25, y: 62.5))
  #expect(prepared.labels[0].style == .road(major: true))
  #expect(prepared.labels[1].style == .place(.town))
  #expect(prepared.labels[1].name == "Dingolfing")
  #expect(prepared.labels[1].point == CGPoint(x: 128, y: 64))
}

@Test func preparedMapSkipsUnusedLayersAndKeepsDrawOrderAndStyles() throws {
  let paths = [[[0, 0], [4096, 4096]]]
  let tile = VectorTile(features: [
    mapFeature("poi", paths: paths),
    mapFeature("landcover", classification: "forest", paths: paths),
    mapFeature("landcover", classification: "grass", paths: paths),
    mapFeature("building", kind: 3, paths: paths),
    mapFeature(classification: "residential", paths: paths),
    mapFeature(extent: 0, paths: paths),
  ])
  let prepared = try PreparedMapTile(tile)
  #expect(prepared.features.map(\.style) == [.forest, .landcover, .building, .road(major: false)])
}

/// The previous cache record retained both a string-bearing style and optional
/// label metadata for every path. This mirrors its layout for a deterministic
/// comparison, independent of allocator noise or operating-system accounting.
private enum PreviousMapStyle {
  case water, forest, landcover, building
  case road(major: Bool)
  case place(kind: String?)
}
private struct PreviousMapFeature {
  let path: Path
  let style: PreviousMapStyle
  let name: String?
  let labelPoint: CGPoint?
}

@Test func mapGeometryDoesNotRetainUnusedLabelsOrPlacePaths() throws {
  let ring = [[[0, 0], [4096, 0], [4096, 4096], [0, 4096]]]
  let buildings = (0..<1024).map { index in
    mapFeature("building", kind: 3, name: "Gebäude \(index)", paths: ring)
  }
  let tile = try PreparedMapTile(VectorTile(features: buildings))
  #expect(tile.features.count == buildings.count)
  #expect(tile.labels.isEmpty)
  let previousBytes = buildings.count * MemoryLayout<PreviousMapFeature>.stride
  let preparedBytes = tile.features.count * MemoryLayout<PreparedMapTile.Feature>.stride
  #expect(preparedBytes * 2 < previousBytes)

  let places = (0..<256).map { index in
    mapFeature(
      "place", kind: 1, classification: "neighbourhood", name: "Ort \(index)",
      paths: [[[index, index]]])
  }
  let placeTile = try PreparedMapTile(VectorTile(features: places))
  #expect(placeTile.features.isEmpty)
  #expect(placeTile.labels.count == places.count)
  #expect(placeTile.labels.allSatisfy { $0.style == .place(.other) })
  let placeBytes = placeTile.labels.count * MemoryLayout<PreparedMapTile.Label>.stride
  #expect(placeBytes < places.count * MemoryLayout<PreviousMapFeature>.stride)
  print(
    "Map metadata: 1024 buildings \(previousBytes) → \(preparedBytes) bytes; "
      + "256 places \(places.count * MemoryLayout<PreviousMapFeature>.stride) → \(placeBytes) bytes; "
      + "path coordinates are unchanged")
}

@Test func mapLabelsDropUnusableNamesWithoutChangingGeometry() throws {
  let paths = [[[0, 0], [4096, 4096]]]
  let tile = try PreparedMapTile(
    VectorTile(features: [
      mapFeature(name: nil, paths: paths),
      mapFeature(name: "", paths: paths),
      mapFeature(name: String(repeating: "ä", count: 129), paths: paths),
      mapFeature(name: "Straße", paths: paths),
      mapFeature("place", kind: 1, name: "", paths: [[[0, 0]]]),
    ]))
  #expect(tile.features.count == 4)
  #expect(tile.labels.count == 1)
  #expect(tile.labels[0].name == "Straße")
}

@Test func preparedLabelKeysKeepDisplayNamesAndCanonicalDuplicates() throws {
  let names = ["  Straẞe \n", "STRAẞE", "Landshut", " LANDSHUT\t", " \n"]
  let tile = try PreparedMapTile(
    VectorTile(
      features: names.map { name in
        mapFeature("place", kind: 1, classification: "city", name: name, paths: [[[1024, 1024]]])
      }))
  #expect(tile.labels.map(\.name) == names)
  #expect(tile.labels[0].key == tile.labels[1].key)
  #expect(tile.labels[2].key == tile.labels[3].key)
  let viewport = CGSize(width: 390, height: 600)
  var layout = OfflineMapLabelLayout(viewport: viewport)
  let reserved = layout.reserve(
    key: tile.labels[0].key, frame: CGRect(x: 20, y: 20, width: 80, height: 20),
    viewport: viewport)
  #expect(reserved)
  #expect(
    !layout.canPlace(key: tile.labels[1].key, at: CGPoint(x: 200, y: 200), viewport: viewport))
  #expect(
    !layout.canPlace(key: tile.labels[4].key, at: CGPoint(x: 200, y: 200), viewport: viewport))
}

@Test func preparedMapCacheIsBoundedAndRejectsOldRegionOrViewportWork() throws {
  final class Owner {}
  let first = Owner()
  let second = Owner()
  let firstID = ObjectIdentifier(first)
  let secondID = ObjectIdentifier(second)
  let keys = (0..<300).map { MapTileKey(z: 10, x: $0, y: 1) }
  let tile = try PreparedMapTile(VectorTile(features: []))
  var cache = PreparedMapTileCache()
  cache.updateViewport(owner: firstID, keys: keys)
  for key in keys { cache.insert(tile, for: key, owner: firstID) }
  #expect(cache.tiles.count == PreparedMapTileCache.capacity)
  cache.updateViewport(owner: firstID, keys: [keys[1]])
  cache.insert(tile, for: keys[0], owner: firstID)
  #expect(cache.tiles.count == 1)
  #expect(cache.tile(for: keys[0], owner: firstID) == nil)
  #expect(cache.tile(for: keys[1], owner: secondID) == nil)
  cache.updateViewport(owner: secondID, keys: [keys[1]])
  cache.insert(tile, for: keys[1], owner: firstID)
  #expect(cache.tiles.isEmpty)
  cache.insert(tile, for: keys[1], owner: secondID)
  #expect(cache.tiles.count == 1)
}

@Test func mapPreparationPropagatesCancellation() async throws {
  let tile = VectorTile(features: [mapFeature(paths: [[[0, 0], [4096, 4096]]])])
  let prepared = try await PreparedMapTile.prepare(tile)
  #expect(prepared.features.count == 1)
  let (gate, continuation) = AsyncStream<Void>.makeStream()
  let task = Task {
    // Do not race a tiny preparation against cancel() on another executor.
    for await _ in gate { break }
    return try await PreparedMapTile.prepare(tile)
  }
  task.cancel()
  continuation.finish()
  do {
    _ = try await task.value
    Issue.record("cancelled map preparation returned geometry")
  } catch is CancellationError {}
}

/// Opt in with OSMMINI_MAP_BENCHMARK=1 swift test -c release --filter mapGeometryReplayBenchmark.
/// This measures CPU path construction and CoreGraphics replay, not GPU frame
/// rate. Timings are reported without a fragile pass/fail time threshold.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapGeometryReplayBenchmark() throws {
  let tile = VectorTile(
    features: (0..<128).map { feature in
      let ring = (0..<128).map { vertex in
        [vertex * 32, (feature * 31 + vertex * 37) % 4096]
      }
      return mapFeature(paths: [ring])
    })
  let clock = ContinuousClock()
  let preparationStart = clock.now
  let prepared = try PreparedMapTile(tile)
  let preparationTime = preparationStart.duration(to: clock.now)
  let context = try #require(
    CGContext(
      data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  )
  context.setLineWidth(1.8)
  context.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
  let frames = 120
  var originalCount = 0
  var preparedCount = 0
  let geometryStart = clock.now
  for frame in 0..<frames {
    let offset = CGPoint(x: Double(frame % 8) / 2, y: Double(frame % 6) / 2)
    for feature in tile.features {
      if !framePath(feature, offset: offset).isEmpty { originalCount += 1 }
    }
  }
  let geometryTime = geometryStart.duration(to: clock.now)
  let reuseStart = clock.now
  for _ in 0..<frames {
    for feature in prepared.features {
      if !feature.path.isEmpty { preparedCount += 1 }
    }
  }
  let reuseTime = reuseStart.duration(to: clock.now)
  #expect(originalCount == frames * tile.features.count)
  #expect(preparedCount == originalCount)
  let originalStart = clock.now
  for frame in 0..<frames {
    let offset = CGPoint(x: Double(frame % 8) / 2, y: Double(frame % 6) / 2)
    for feature in tile.features {
      context.addPath(framePath(feature, offset: offset).cgPath)
      context.strokePath()
    }
  }
  let originalTime = originalStart.duration(to: clock.now)
  let preparedStart = clock.now
  for frame in 0..<frames {
    context.saveGState()
    context.translateBy(x: Double(frame % 8) / 2, y: Double(frame % 6) / 2)
    for feature in prepared.features {
      context.addPath(feature.path.cgPath)
      context.strokePath()
    }
    context.restoreGState()
  }
  let preparedTime = preparedStart.duration(to: clock.now)
  #expect(context.makeImage() != nil)
  print(
    "Map geometry: 128 features × 128 vertices, \(frames) frames; "
      + "prepare once \(preparationTime), geometry rebuild \(geometryTime), "
      + "cached access \(reuseTime), rebuild/replay \(originalTime), cached replay \(preparedTime)")
}
