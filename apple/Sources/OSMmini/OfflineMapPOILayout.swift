import SwiftUI

/// Drawing and hit testing share the same spatial groups. Every visible POI
/// belongs to one marker; grouped places remain individually selectable.
enum OfflineMapPOILayout {
  struct Member {
    let feature: MapFeature
    let point: CGPoint
  }

  struct Marker {
    let feature: MapFeature
    let point: CGPoint
    var members: [Member]
    var isGroup: Bool { members.count > 1 }
    func radius(at zoom: Int) -> CGFloat { isGroup ? 14 : OfflineMapPOILayout.radius(at: zoom) }
  }

  struct Label {
    let marker: Marker
    let frame: CGRect
  }

  /// Fixed one-line frames are shared with hit testing, including truncated
  /// titles. Text itself is drawn with the system font inside these frames.
  static func labels(
    for markers: [Marker], zoom: Int, size: CGSize, excluding exclusions: [CGRect] = []
  ) -> [Label] {
    guard zoom >= 17 else { return [] }
    let radius = radius(at: zoom)
    var obstacles =
      exclusions
      + markers.map {
        let radius = $0.radius(at: zoom)
        return CGRect(
          x: $0.point.x - radius - 2, y: $0.point.y - radius - 2,
          width: radius * 2 + 4, height: radius * 2 + 4)
      }
    let controls =
      size.height >= 232 ? CGSize(width: 76, height: 232) : CGSize(width: 232, height: 76)
    obstacles.append(
      CGRect(
        x: max(0, size.width - controls.width), y: 0,
        width: controls.width, height: controls.height))
    obstacles.append(
      CGRect(x: 0, y: max(0, size.height - 80), width: min(260, size.width), height: 80))
    var layout = OfflineMapLabelLayout(obstacles: obstacles, viewport: size)
    var labels: [Label] = []
    for marker in markers where !marker.isGroup {
      // Short names no longer occupy a fixed 150-point strip on narrow maps.
      let width = min(150, max(44, CGFloat(marker.feature.name.count) * 6.5))
      for x in [marker.point.x + radius + 12, marker.point.x - radius - 12 - width] {
        let frame = CGRect(x: x, y: marker.point.y - 9, width: width, height: 18)
        if layout.reserve(name: marker.feature.name, frame: frame, viewport: size) {
          labels.append(Label(marker: marker, frame: frame))
          break
        }
      }
    }
    return labels
  }

  private struct Cell: Hashable {
    let x: Int
    let y: Int
  }

  static func radius(at zoom: Int) -> CGFloat { zoom >= 16 ? 10 : 5 }

  static func markers(
    in tiles: [OfflineMapLabelTile], zoom: Int, size: CGSize
  ) -> [Marker] {
    guard zoom >= 14, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0
    else { return [] }
    let viewport = CGRect(origin: .zero, size: size)
    var candidates: [Member] = []
    for tile in tiles {
      for candidate in tile.tile.selectablePoints where candidate.isPOI {
        let point = CGPoint(
          x: candidate.point.x * tile.scale + tile.offset.x,
          y: candidate.point.y * tile.scale + tile.offset.y)
        guard point.x.isFinite, point.y.isFinite, viewport.contains(point),
          PreparedMapTileIndex.tileBounds.contains(candidate.point)
        else { continue }
        candidates.append(Member(feature: candidate.feature, point: point))
      }
    }
    // Independent of tile completion order, keeping crowded markers stable
    // when the same loaded tiles are visited in a different order.
    candidates.sort {
      let lhs = $0.feature.sourceIdentity ?? $0.feature.name
      let rhs = $1.feature.sourceIdentity ?? $1.feature.name
      if lhs != rhs { return lhs < rhs }
      if $0.point.x != $1.point.x { return $0.point.x < $1.point.x }
      return $0.point.y < $1.point.y
    }
    // Group badges need 28 points even at overview zoom. Reserve enough room
    // for them before grouping, so adding members never overlaps a neighbor.
    let spacing: CGFloat = 34
    var cells: [Cell: [Int]] = [:]
    var result: [Marker] = []
    var previous: Member?
    for candidate in candidates {
      if let previous, let identity = candidate.feature.sourceIdentity,
        identity == previous.feature.sourceIdentity && candidate.point == previous.point
      {
        continue
      }
      previous = candidate
      let cell = Cell(x: Int(candidate.point.x / spacing), y: Int(candidate.point.y / spacing))
      var closest: Int?
      var nearest = spacing * spacing
      for y in (cell.y - 1)...(cell.y + 1) {
        for x in (cell.x - 1)...(cell.x + 1) {
          for index in cells[Cell(x: x, y: y)] ?? [] {
            let point = result[index].point
            let dx = point.x - candidate.point.x
            let dy = point.y - candidate.point.y
            let distance = dx * dx + dy * dy
            if distance < nearest {
              closest = index
              nearest = distance
            }
          }
        }
      }
      if let closest {
        result[closest].members.append(candidate)
      } else {
        cells[cell, default: []].append(result.count)
        result.append(
          Marker(feature: candidate.feature, point: candidate.point, members: [candidate]))
      }
    }
    return result
  }
}
