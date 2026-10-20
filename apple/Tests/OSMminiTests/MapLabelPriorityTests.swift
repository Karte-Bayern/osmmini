import Foundation
import Testing

@testable import OSMmini

/// The renderer's previous screen-space record, collected and sorted per frame.
private struct PreviousFrameLabel {
  let name: String
  let key: OfflineMapLabelLayout.Key
  let point: CGPoint
  let size: CGFloat
  let priority: Int
  let bold: Bool
}

private struct LabelVisit: Equatable {
  let name: String
  let key: OfflineMapLabelLayout.Key
  let point: CGPoint
  let priority: OfflineMapLabelPriority
}

private func priorityFixture(count: Int, offset: Int) throws
  -> (PreparedMapTile, [PreparedMapTile.Label])
{
  var seed: UInt64 = 0x6C61_6265_6C73
  var features: [VectorFeature] = []
  var original: [PreparedMapTile.Label] = []
  for index in 0..<count {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let priority = Int((seed >> 32) % 6)
    let style: PreparedMapTile.Label.Style =
      switch priority {
      case 0: .place(.city)
      case 1: .place(.town)
      case 2: .place(.village)
      case 3: .place(.other)
      case 4: .road(major: true)
      default: .road(major: false)
      }
    let point = [index % 250, (index * 97) % 250]
    let name = "Straße \((index + offset) % 127)"
    let road = priority >= 4
    features.append(
      VectorFeature(
        layer: road ? "transportation" : "place", kind: road ? 2 : 1, extent: 256,
        class: ["city", "town", "village", "neighbourhood", "primary", "residential"][priority],
        name: name, paths: [road ? [point, [point[0] + 2, point[1]]] : [point]]))
    original.append(
      PreparedMapTile.Label(
        name: name, point: CGPoint(x: point[0] + (road ? 1 : 0), y: point[1]), style: style))
  }
  return (try PreparedMapTile(VectorTile(features: features)), original)
}

private func orderedVisits(_ tiles: [OfflineMapLabelTile], viewport: CGSize) -> [LabelVisit] {
  let bounds = CGRect(origin: .zero, size: viewport)
  var visits: [LabelVisit] = []
  for priority in OfflineMapLabelPriority.allCases {
    for placement in tiles {
      for label in placement.tile.labels(in: priority) {
        let point = CGPoint(
          x: label.point.x * placement.scale + placement.offset.x,
          y: label.point.y * placement.scale + placement.offset.y)
        if bounds.contains(point) {
          visits.append(
            LabelVisit(name: label.name, key: label.key, point: point, priority: priority))
        }
      }
    }
  }
  return visits
}

@Test func preparedLabelPriorityRangesPreserveGlobalStableOrderAndCollisions() throws {
  for count in [0, 1, 12, 500, 3000] {
    var placements: [OfflineMapLabelTile] = []
    var original: [LabelVisit] = []
    let viewport = CGSize(width: 390, height: 600)
    for index in 0..<4 {
      let (tile, labels) = try priorityFixture(count: count, offset: index * 7)
      let scale = CGFloat(index % 2 + 1)
      let offset = CGPoint(x: index * 100 - 20, y: index * 90 - 20)
      placements.append(OfflineMapLabelTile(tile: tile, offset: offset, scale: scale))
      for label in labels {
        let point = CGPoint(
          x: label.point.x * scale + offset.x, y: label.point.y * scale + offset.y)
        if CGRect(origin: .zero, size: viewport).contains(point) {
          original.append(
            LabelVisit(
              name: label.name, key: label.key, point: point, priority: label.style.priority))
        }
      }
      for priority in OfflineMapLabelPriority.allCases {
        #expect(
          tile.labels(in: priority).map(\.name)
            == labels.filter { $0.style.priority == priority }.map(\.name))
        #expect(tile.labels(in: priority).allSatisfy { $0.style.priority == priority })
      }
    }
    let expected = original.sorted { $0.priority.rawValue < $1.priority.rawValue }
    let actual = orderedVisits(placements, viewport: viewport)
    #expect(actual == expected)
    func accepted(_ labels: [LabelVisit]) -> [LabelVisit] {
      var layout = OfflineMapLabelLayout(
        obstacles: [CGRect(x: 300, y: 0, width: 90, height: 180)], viewport: viewport)
      return labels.filter { label in
        guard layout.canPlace(key: label.key, at: label.point, viewport: viewport) else {
          return false
        }
        return layout.reserve(
          key: label.key,
          frame: CGRect(x: label.point.x - 40, y: label.point.y - 10, width: 80, height: 20),
          viewport: viewport)
      }
    }
    #expect(accepted(actual) == accepted(expected))
  }
}

@inline(never)
private func replayLabelPriority(
  _ tiles: [OfflineMapLabelTile], viewport: CGSize, cached: Bool, frames: Int
) -> Int {
  let bounds = CGRect(origin: .zero, size: viewport)
  var checksum = 0
  for _ in 0..<frames {
    if cached {
      for priority in OfflineMapLabelPriority.allCases {
        for placement in tiles {
          for label in placement.tile.labels(in: priority) {
            let point = CGPoint(
              x: label.point.x * placement.scale + placement.offset.x,
              y: label.point.y * placement.scale + placement.offset.y)
            if bounds.contains(point) { checksum = checksum &* 16_777_619 ^ Int(point.x) }
          }
        }
      }
    } else {
      var labels: [PreviousFrameLabel] = []
      for placement in tiles {
        for label in placement.tile.labels {
          let point = CGPoint(
            x: label.point.x * placement.scale + placement.offset.x,
            y: label.point.y * placement.scale + placement.offset.y)
          guard bounds.contains(point) else { continue }
          labels.append(
            PreviousFrameLabel(
              name: label.name, key: label.key, point: point, size: 12,
              priority: label.style.priority.rawValue, bold: label.style.priority.rawValue < 3))
        }
      }
      for label in labels.sorted(by: { $0.priority < $1.priority }) {
        checksum = checksum &* 16_777_619 ^ Int(label.point.x)
      }
    }
  }
  return checksum
}

private func measureLabelPriority(
  _ tiles: [OfflineMapLabelTile], viewport: CGSize, name: String
) {
  let clock = ContinuousClock()
  let count = orderedVisits(tiles, viewport: viewport).count
  for pass in 0..<3 {
    var checksums: [Int] = []
    for cached in pass.isMultiple(of: 2) ? [false, true] : [true, false] {
      let begin = clock.now
      checksums.append(replayLabelPriority(tiles, viewport: viewport, cached: cached, frames: 120))
      print(
        "Label priority pass \(pass+1), \(name), \(count) labels, cached=\(cached): \(begin.duration(to:clock.now)) / 120 frames"
      )
    }
    #expect(checksums[0] == checksums[1])
  }
  print("Previous transient frame labels: \(count * MemoryLayout<PreviousFrameLabel>.stride) bytes")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapLabelPriorityBenchmark() throws {
  for (name, count) in [("sparse phone", 12), ("phone", 500), ("dense tablet", 3000)] {
    let (tile, _) = try priorityFixture(count: count, offset: 0)
    measureLabelPriority(
      [OfflineMapLabelTile(tile: tile, offset: .zero, scale: 1)],
      viewport: CGSize(width: 1024, height: 1366), name: name)
  }
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"
      && ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"] != nil))
func realRegionMapLabelPriorityBenchmark() async throws {
  let directory = try #require(ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"])
  let engine = try await OfflineEngine.open(URL(fileURLWithPath: directory))
  do {
    let zoom = min(14, engine.manifest.maxZoom)
    for (city, center) in [
      ("Passau", Coordinate(lat: 48.5667, lon: 13.4319)),
      ("Landshut", Coordinate(lat: 48.5442, lon: 12.1469)),
    ] {
      for (scene, viewport) in [
        ("phone", CGSize(width: 390, height: 600)),
        ("tablet", CGSize(width: 1024, height: 1366)),
      ] {
        var tiles: [OfflineMapLabelTile] = []
        let placements = OfflineMapTilePlacement.visible(center: center, zoom: zoom, size: viewport)
        for placement in placements {
          let key = placement.key
          let tile = try await PreparedMapTile.prepare(engine.tile(z: key.z, x: key.x, y: key.y))
          tiles.append(
            OfflineMapLabelTile(
              tile: tile, offset: placement.origin(center: center, zoom: zoom, size: viewport),
              scale: 1))
        }
        #expect(!orderedVisits(tiles, viewport: viewport).isEmpty)
        measureLabelPriority(tiles, viewport: viewport, name: "\(city) \(scene)")
      }
    }
    await engine.close()
  } catch {
    await engine.close()
    throw error
  }
}
