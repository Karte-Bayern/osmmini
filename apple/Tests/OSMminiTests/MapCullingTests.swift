import Foundation
import SwiftUI
import Testing

@testable import OSMmini

private func cullingFeature(
  _ layer: String = "building", kind: Int = 3, extent: Int = 256,
  classification: String? = nil, paths: [[[Int]]]
) -> VectorFeature {
  VectorFeature(
    layer: layer, kind: kind, extent: extent, class: classification, name: nil, paths: paths)
}

private func cullingFixture() throws -> PreparedMapTile {
  var features = [
    cullingFeature(
      "water",
      paths: [
        [[-8, -8], [264, -8], [264, 264], [-8, 264]],
        [[8, 8], [80, 8], [80, 80], [8, 80]],
      ])
  ]
  for y in 0..<32 {
    for x in 0..<32 {
      let left = x * 8 + 2
      let top = y * 8 + 2
      features.append(
        cullingFeature(paths: [
          [[left, top], [left + 4, top], [left + 4, top + 4], [left, top + 4]]
        ]))
    }
  }
  // Overlapping fills, holes, crossing roads, zero-width bounds, tile overhang
  // and road casings entering a viewport from the neighboring cell.
  features.append(contentsOf: [
    cullingFeature(
      "landcover", classification: "forest",
      paths: [
        [[12, 12], [44, 12], [44, 44], [12, 44]],
        [[20, 20], [36, 20], [36, 36], [20, 36]],
      ]),
    cullingFeature(
      "transportation", kind: 2, classification: "primary",
      paths: [
        [[-10, 20], [270, 200]], [[-10, 128], [270, 128]],
      ]),
    cullingFeature(
      "transportation", kind: 2, extent: 4096, classification: "primary",
      paths: [
        [[511, 16], [511, 496]], [[16, 511], [496, 511]],
      ]),
    cullingFeature(
      "transportation", kind: 2,
      paths: [
        [[256, 0], [256, 256]], [[0, 0], [0, 256]], [[-1, 0], [-1, 32]],
      ]),
  ])
  return try PreparedMapTile(VectorTile(features: features))
}

private func cullingPadding(overzoom: Int) -> CGFloat {
  ((PreparedMapTile.roadWidth(major: true, overzoom: overzoom) + 1) / 2 + 1)
    / exp2(Double(overzoom))
}

@Test func mapCullingKeepsAllPotentiallyVisibleGeometryInPaintOrder() throws {
  let tile = try cullingFixture()
  #expect(tile.spatialIndex != nil)
  for index in 0..<100 {
    let rect = CGRect(
      x: Double((index * 37) % 280) - 12.25,
      y: Double((index * 61) % 280) - 12.5, width: 20, height: 32)
    let padding = cullingPadding(overzoom: index % 5)
    let selected = Array(tile.featureIndices(in: rect, padding: padding))
    #expect(selected == selected.sorted())
    #expect(Set(selected).count == selected.count)
    let clipped = rect.intersection(PreparedMapTileIndex.tileBounds)
    let required = tile.features.indices.filter {
      tile.features[$0].path.boundingRect.insetBy(dx: -padding, dy: -padding).intersects(clipped)
    }
    #expect(Set(required).isSubset(of: Set(selected)))
  }
  let smallView = tile.featureIndices(in: CGRect(x: 9, y: 9, width: 16, height: 16), padding: 1)
  #expect(smallView.count < tile.features.count / 10)
  #expect(
    Array(tile.featureIndices(in: CGRect(x: 0, y: 0, width: 256, height: 256)))
      == Array(tile.features.indices))
  #expect(tile.featureIndices(in: CGRect(x: -50, y: -50, width: 20, height: 20)).isEmpty)
  #expect(tile.featureIndices(in: .zero).isEmpty)
}

@Test func mapCullingAddsCompactStorageOnlyForTilesThatCanBenefit() throws {
  let tile = try cullingFixture()
  let spatialIndex = try #require(tile.spatialIndex)
  #expect(spatialIndex.storageBytes < tile.features.count * 8)
  let small = try PreparedMapTile(
    VectorTile(features: [
      cullingFeature(paths: [[[0, 0], [5, 0], [5, 5], [0, 5]]])
    ]))
  #expect(small.spatialIndex == nil)
  #expect(Array(small.featureIndices(in: CGRect(x: 0, y: 0, width: 10, height: 10))) == [0])
  let broad = try PreparedMapTile(
    VectorTile(
      features: (0..<256).map { _ in
        cullingFeature(paths: [[[-10, -10], [266, -10], [266, 266], [-10, 266]]])
      }))
  #expect(broad.spatialIndex == nil)
  print("Tile culling index: \(tile.features.count) features, \(spatialIndex.storageBytes) bytes")
}

private func cullingContext(width: Int, height: Int) throws -> CGContext {
  try #require(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  )
}

/// Match the Canvas geometry operations using an inspectable bitmap target.
@discardableResult
private func replayCullingTile(
  _ tile: PreparedMapTile, in context: CGContext, viewport: CGRect, overzoom: Int, culled: Bool
) -> Int {
  let scale = exp2(Double(overzoom))
  context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
  context.saveGState()
  defer { context.restoreGState() }
  context.translateBy(x: -viewport.minX * scale, y: -viewport.minY * scale)
  context.scaleBy(x: scale, y: scale)
  context.clip(to: CGRect(x: 0, y: 0, width: 256, height: 256))
  context.setLineCap(.round)
  context.setLineJoin(.round)
  let indices =
    culled
    ? tile.featureIndices(in: viewport, padding: cullingPadding(overzoom: overzoom))
    : PreparedMapFeatureIndices(count: tile.features.count)
  for index in indices {
    let feature = tile.features[index]
    if case .road(let major) = feature.style {
      let width = PreparedMapTile.roadWidth(major: major, overzoom: overzoom)
      context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.45))
      context.setLineWidth((width + 1) / scale)
      context.addPath(feature.path.cgPath)
      context.strokePath()
      context.setStrokeColor(
        major ? CGColor(red: 0.96, green: 0.79, blue: 0.51, alpha: 1) : CGColor(gray: 1, alpha: 1))
      context.setLineWidth(width / scale)
      context.addPath(feature.path.cgPath)
      context.strokePath()
    } else {
      let color: CGColor
      switch feature.style {
      case .water: color = CGColor(red: 0.66, green: 0.82, blue: 0.88, alpha: 1)
      case .forest: color = CGColor(red: 0.77, green: 0.85, blue: 0.72, alpha: 1)
      case .landcover: color = CGColor(red: 0.89, green: 0.90, blue: 0.79, alpha: 1)
      default: color = CGColor(red: 0.83, green: 0.79, blue: 0.75, alpha: 1)
      }
      context.setFillColor(color)
      context.addPath(feature.path.cgPath)
      context.fillPath(using: .evenOdd)
    }
  }
  return indices.count
}

@Test func mapCullingProducesIdenticalPixelsAtDifferentZoomsAndViewportEdges() throws {
  let tile = try cullingFixture()
  let reference = try cullingContext(width: 160, height: 224)
  let optimized = try cullingContext(width: 160, height: 224)
  for overzoom in [0, 1, 2, 4] {
    let scale = exp2(Double(overzoom))
    for origin in [
      CGPoint.zero, CGPoint(x: 32.05, y: 1), CGPoint(x: 1, y: 32.05),
      CGPoint(x: 127.5, y: 127.5), CGPoint(x: 250, y: 250), CGPoint(x: -20, y: -10),
    ] {
      let viewport = CGRect(origin: origin, size: CGSize(width: 160 / scale, height: 224 / scale))
      replayCullingTile(tile, in: reference, viewport: viewport, overzoom: overzoom, culled: false)
      replayCullingTile(tile, in: optimized, viewport: viewport, overzoom: overzoom, culled: true)
      let expected = Data(
        bytes: try #require(reference.data), count: reference.bytesPerRow * reference.height)
      let actual = Data(
        bytes: try #require(optimized.data), count: optimized.bytesPerRow * optimized.height)
      #expect(expected == actual, "Different pixels at zoom +\(overzoom), origin \(origin)")
    }
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapCullingReplayBenchmark() throws {
  let tile = try cullingFixture()
  let context = try cullingContext(width: 390, height: 600)
  let frames = 120
  let clock = ContinuousClock()
  for overzoom in [0, 4] {
    let scale = exp2(Double(overzoom))
    for pass in 0..<3 {
      var full = Duration.zero
      var culled = Duration.zero
      var selected = 0
      for optimized in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
        let begin = clock.now
        for frame in 0..<frames {
          let viewport = CGRect(
            x: 40 + Double(frame % 16) / scale, y: 40 + Double(frame % 12) / scale,
            width: 390 / scale, height: 600 / scale)
          let count = replayCullingTile(
            tile, in: context, viewport: viewport, overzoom: overzoom, culled: optimized)
          if optimized { selected += count }
        }
        let elapsed = begin.duration(to: clock.now)
        if optimized { culled = elapsed } else { full = elapsed }
      }
      print(
        "Culling pass \(pass + 1), zoom +\(overzoom), \(frames) frames: all \(full), indexed \(culled); geometry submissions \(tile.features.count * frames) → \(selected)"
      )
    }
  }
}
