import Foundation
import Testing

@testable import OSMmini

/// Keep the previous linear implementation as an independent behavior oracle.
private struct LinearLabelLayout {
  var occupied: [CGRect]
  var names: Set<String> = []

  func canPlace(name: String, at point: CGPoint, viewport: CGSize) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !name.isEmpty && !names.contains(name) && point.x.isFinite && point.y.isFinite
      && CGRect(origin: .zero, size: viewport).insetBy(dx: 6, dy: 6).contains(point)
      && !occupied.contains(where: { $0.contains(point) })
  }

  mutating func reserve(name: String, frame: CGRect, viewport: CGSize) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !name.isEmpty, !names.contains(name), frame.origin.x.isFinite,
      frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0,
      CGRect(origin: .zero, size: viewport).insetBy(dx: 6, dy: 6).contains(frame)
    else { return false }
    let footprint = frame.insetBy(dx: -4, dy: -3)
    guard !occupied.contains(where: { $0.intersects(footprint) }) else { return false }
    occupied.append(footprint)
    names.insert(name)
    return true
  }
}

private struct LabelCandidate {
  let name: String
  let key: OfflineMapLabelLayout.Key
  let point: CGPoint
  let frame: CGRect

  init(name: String, point: CGPoint, frame: CGRect) {
    self.name = name
    key = OfflineMapLabelLayout.Key(name)
    self.point = point
    self.frame = frame
  }
}

private func labelObstacles(in viewport: CGSize) -> [CGRect] {
  [
    CGRect(x: max(0, viewport.width - 76), y: 0, width: 76, height: 180),
    CGRect(x: 0, y: max(0, viewport.height - 80), width: min(viewport.width, 260), height: 80),
  ]
}

private func labelCandidates(viewport: CGSize, count: Int, duplicateNames: Bool = false)
  -> [LabelCandidate]
{
  var seed: UInt64 = 0x726F_6164_6E61_6D65
  func random(_ limit: Int) -> Int {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((seed >> 32) % UInt64(limit))
  }
  return (0..<count).map { index in
    let point = CGPoint(
      x: Double(random(10_000)) / 10_000 * viewport.width,
      y: Double(random(10_000)) / 10_000 * viewport.height)
    let width = CGFloat(36 + random(120))
    let height = CGFloat(14 + random(12))
    let nameIndex = duplicateNames ? index % 32 : index
    let name = index.isMultiple(of: 3) ? " Straße \(nameIndex) \n" : "STRAẞE \(nameIndex)"
    return LabelCandidate(
      name: name, point: point,
      frame: CGRect(
        x: point.x - width / 2, y: point.y - height / 2, width: width, height: height))
  }
}

@Test func mapLabelGridMatchesLinearPlacementForPhoneAndTabletScenes() {
  for viewport in [CGSize(width: 390, height: 600), CGSize(width: 1024, height: 1366)] {
    for count in [8, 3000] {
      for duplicateNames in [false, true] {
        let obstacles = labelObstacles(in: viewport)
        var expected = LinearLabelLayout(occupied: obstacles)
        var actual = OfflineMapLabelLayout(obstacles: obstacles, viewport: viewport)
        var accepted = 0
        for candidate in labelCandidates(
          viewport: viewport, count: count, duplicateNames: duplicateNames)
        {
          let canPlace = expected.canPlace(
            name: candidate.name, at: candidate.point, viewport: viewport)
          #expect(
            actual.canPlace(key: candidate.key, at: candidate.point, viewport: viewport)
              == canPlace)
          guard canPlace else { continue }
          let reserved = expected.reserve(
            name: candidate.name, frame: candidate.frame, viewport: viewport)
          #expect(
            actual.reserve(key: candidate.key, frame: candidate.frame, viewport: viewport)
              == reserved)
          if reserved { accepted += 1 }
        }
        // Dense scenes pass the small-layout threshold and exercise indexed queries.
        if count == 3000 { #expect(accepted >= 16) }
      }
    }
  }
}

@Test func mapLabelGridKeepsReservationsWhenCrossingTheLinearThreshold() {
  let viewport = CGSize(width: 1024, height: 600)
  for initialCount in [0, 15, 16] {
    let obstacles = (0..<initialCount).map { index in
      CGRect(x: CGFloat(index) * 60 + 16, y: 30, width: 40, height: 20)
    }
    var expected = LinearLabelLayout(occupied: obstacles)
    var actual = OfflineMapLabelLayout(obstacles: obstacles, viewport: viewport)
    for index in 0..<20 {
      let rectangle = CGRect(
        x: CGFloat(index % 10) * 80 + 16, y: CGFloat(index / 10) * 100 + 160,
        width: 40, height: 20)
      let name = "Straße \(index)"
      let actualReserved = actual.reserve(name: name, frame: rectangle, viewport: viewport)
      let expectedReserved = expected.reserve(name: name, frame: rectangle, viewport: viewport)
      #expect(actualReserved)
      #expect(expectedReserved)
      for previous in 0...index {
        let x = CGFloat(previous % 10) * 80 + 16
        let y = CGFloat(previous / 10) * 100 + 160
        for point in [
          CGPoint(x: x - 4, y: y - 3), CGPoint(x: x, y: y),
          CGPoint(x: x + 44, y: y + 23), CGPoint(x: 64, y: y),
        ] {
          #expect(
            actual.canPlace(name: "new candidate", at: point, viewport: viewport)
              == expected.canPlace(name: "new candidate", at: point, viewport: viewport))
        }
        let duplicate = " STRAẞE \(previous) \n"
        #expect(
          actual.canPlace(name: duplicate, at: CGPoint(x: 950, y: 500), viewport: viewport)
            == expected.canPlace(name: duplicate, at: CGPoint(x: 950, y: 500), viewport: viewport))
      }
    }
  }
}

@Test func mapLabelGridPreservesEdgesInvalidInputsAndUnusualObstacles() {
  let configuredViewport = CGSize(width: 390, height: 600)
  let base = (0..<20).map { index in
    CGRect(x: 16 + CGFloat(index % 5) * 64, y: 16 + CGFloat(index / 5) * 64, width: 20, height: 12)
  }
  // Separate runs retain meaningful placement tests even when an infinite
  // obstacle occupies the complete map. Degenerate and negative-size obstacles
  // must retain Foundation's exact contains/intersects behavior.
  let unusual = [
    CGRect.null, CGRect.infinite,
    CGRect(x: 64, y: 300, width: 0, height: 30),
    CGRect(x: 192, y: 400, width: -70, height: -20),
    CGRect(x: -100, y: 300, width: 120, height: 20),
    CGRect(x: CGFloat.greatestFiniteMagnitude, y: 20, width: 40, height: 20),
    CGRect(x: CGFloat.nan, y: 100, width: 40, height: 20),
  ]
  for extra in unusual {
    let obstacles = base + [extra]
    var expected = LinearLabelLayout(occupied: obstacles)
    var actual = OfflineMapLabelLayout(obstacles: obstacles, viewport: configuredViewport)
    for viewport in [configuredViewport, CGSize(width: 800, height: 800)] {
      for (index, candidate) in labelCandidates(viewport: viewport, count: 500).enumerated() {
        #expect(
          actual.canPlace(key: candidate.key, at: candidate.point, viewport: viewport)
            == expected.canPlace(name: candidate.name, at: candidate.point, viewport: viewport))
        // Direct reservations also cover callers that skip the point preflight.
        #expect(
          actual.reserve(key: candidate.key, frame: candidate.frame, viewport: viewport)
            == expected.reserve(name: candidate.name, frame: candidate.frame, viewport: viewport))
        let duplicate = "  \(candidate.name.uppercased())\n"
        #expect(
          actual.canPlace(name: duplicate, at: CGPoint(x: 70, y: 500), viewport: viewport)
            == expected.canPlace(name: duplicate, at: CGPoint(x: 70, y: 500), viewport: viewport))
        if index.isMultiple(of: 50) {
          for frame in [
            CGRect(x: 6, y: 450, width: 58, height: 20),
            CGRect(x: 64, y: 480, width: 64, height: 20),
            CGRect(x: 300, y: 560, width: 84, height: 34),
            CGRect(x: 500, y: 600, width: 80, height: 20),
          ] {
            let name = "boundary \(index) \(frame)"
            #expect(
              actual.reserve(name: name, frame: frame, viewport: viewport)
                == expected.reserve(name: name, frame: frame, viewport: viewport))
          }
        }
      }
      for point in [
        CGPoint(x: CGFloat.nan, y: 100), CGPoint(x: 100, y: CGFloat.infinity),
        CGPoint(x: 6, y: 300), CGPoint(x: viewport.width - 6, y: 300),
        CGPoint(x: 64, y: 320), CGPoint(x: 128, y: 320),
      ] {
        for name in ["", " \n\t", "Landshut", " LANDSHUT "] {
          #expect(
            actual.canPlace(name: name, at: point, viewport: viewport)
              == expected.canPlace(name: name, at: point, viewport: viewport))
        }
      }
      for frame in [
        CGRect.null, CGRect.infinite,
        CGRect(x: CGFloat.nan, y: 300, width: 20, height: 20),
        CGRect(x: 200, y: CGFloat.infinity, width: 20, height: 20),
        CGRect(x: 200, y: 300, width: 0, height: 20),
        CGRect(x: 200, y: 300, width: -20, height: 20),
        CGRect(x: 200, y: 300, width: CGFloat.infinity, height: 20),
      ] {
        #expect(
          actual.reserve(name: "invalid", frame: frame, viewport: viewport)
            == expected.reserve(name: "invalid", frame: frame, viewport: viewport))
      }
    }
  }
}

@Test func mapLabelGridHandlesInvalidAndExtremelyLargeConfiguredViewports() {
  for configuredViewport in [
    CGSize.zero, CGSize(width: -1, height: 600), CGSize(width: CGFloat.infinity, height: 600),
    CGSize(width: CGFloat.nan, height: 600),
    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
  ] {
    let viewport = CGSize(width: 390, height: 600)
    let obstacles = labelObstacles(in: viewport)
    var expected = LinearLabelLayout(occupied: obstacles)
    var actual = OfflineMapLabelLayout(obstacles: obstacles, viewport: configuredViewport)
    for candidate in labelCandidates(viewport: viewport, count: 500) {
      #expect(
        actual.canPlace(key: candidate.key, at: candidate.point, viewport: viewport)
          == expected.canPlace(name: candidate.name, at: candidate.point, viewport: viewport))
      #expect(
        actual.reserve(key: candidate.key, frame: candidate.frame, viewport: viewport)
          == expected.reserve(name: candidate.name, frame: candidate.frame, viewport: viewport))
    }
  }
}

private func replayLabelLayout(
  candidates: [LabelCandidate], viewport: CGSize, frames: Int, indexed: Bool,
  cachedKeys: Bool = false
) -> Int {
  var accepted = 0
  for frame in 0..<frames {
    let obstacles = labelObstacles(in: viewport)
    var reference = LinearLabelLayout(occupied: obstacles)
    var optimized = OfflineMapLabelLayout(obstacles: obstacles, viewport: indexed ? viewport : nil)
    let offset = CGFloat(frame % 7) - 3
    for candidate in candidates {
      let point = CGPoint(x: candidate.point.x + offset, y: candidate.point.y + offset)
      let rectangle = candidate.frame.offsetBy(dx: offset, dy: offset)
      let canPlace =
        indexed
        ? (cachedKeys
          ? optimized.canPlace(key: candidate.key, at: point, viewport: viewport)
          : optimized.canPlace(name: candidate.name, at: point, viewport: viewport))
        : reference.canPlace(name: candidate.name, at: point, viewport: viewport)
      guard canPlace else { continue }
      let reserved =
        indexed
        ? (cachedKeys
          ? optimized.reserve(key: candidate.key, frame: rectangle, viewport: viewport)
          : optimized.reserve(name: candidate.name, frame: rectangle, viewport: viewport))
        : reference.reserve(name: candidate.name, frame: rectangle, viewport: viewport)
      if reserved { accepted += 1 }
    }
  }
  return accepted
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapLabelKeyBenchmark() {
  let clock = ContinuousClock()
  for (name, viewport, count, duplicates) in [
    ("sparse phone", CGSize(width: 390, height: 600), 12, false),
    ("phone", CGSize(width: 390, height: 600), 500, false),
    ("phone repeated roads", CGSize(width: 390, height: 600), 500, true),
    ("dense tablet", CGSize(width: 1024, height: 1366), 3000, false),
  ] {
    let candidates = labelCandidates(viewport: viewport, count: count, duplicateNames: duplicates)
    for pass in 0..<3 {
      var counts: [Int] = []
      for cached in pass.isMultiple(of: 2) ? [false, true] : [true, false] {
        let begin = clock.now
        counts.append(
          replayLabelLayout(
            candidates: candidates, viewport: viewport, frames: 120, indexed: true,
            cachedKeys: cached))
        print(
          "Label keys pass \(pass+1), \(name), cached=\(cached): \(begin.duration(to:clock.now)) / 120 frames"
        )
      }
      #expect(counts[0] == counts[1])
    }
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func mapLabelLayoutBenchmark() {
  let clock = ContinuousClock()
  let frames = 120
  for (name, viewport, count, duplicateNames) in [
    ("sparse phone", CGSize(width: 390, height: 600), 12, false),
    ("phone", CGSize(width: 390, height: 600), 500, false),
    ("phone repeated roads", CGSize(width: 390, height: 600), 500, true),
    ("dense tablet", CGSize(width: 1024, height: 1366), 3000, false),
  ] {
    let candidates = labelCandidates(
      viewport: viewport, count: count, duplicateNames: duplicateNames)
    for pass in 0..<3 {
      var linear = Duration.zero
      var indexed = Duration.zero
      var linearCount = 0
      var indexedCount = 0
      for optimized in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
        let begin = clock.now
        let count = replayLabelLayout(
          candidates: candidates, viewport: viewport, frames: frames, indexed: optimized)
        let elapsed = begin.duration(to: clock.now)
        if optimized {
          indexed = elapsed
          indexedCount = count
        } else {
          linear = elapsed
          linearCount = count
        }
      }
      #expect(linearCount == indexedCount)
      print(
        "Label layout pass \(pass + 1), \(name), \(frames) frames × \(count) candidates: linear \(linear), indexed \(indexed); accepted \(indexedCount)"
      )
    }
  }
}
