import SwiftUI

/// The offline object under a map tap. Geometry and descriptive values come
/// from the loaded region; no online lookup is performed.
public struct MapFeature: Sendable, Equatable {
  public let name: String
  public let kind: String
  public let category: String?
  public let sourceIdentity: String?
  public let details: PlaceDetails?

  public init(
    name: String, kind: String, category: String? = nil, sourceIdentity: String? = nil,
    details: PlaceDetails? = nil
  ) {
    self.name = name
    self.kind = kind
    self.category = category
    self.sourceIdentity = sourceIdentity
    self.details = details
  }
}

public struct MapSelection: Sendable, Equatable {
  /// A matching object's position, or the original tap when no object is near.
  /// Street selections use the closest visible point on the street geometry.
  public let coordinate: Coordinate
  public let feature: MapFeature?
  /// All individually positioned places represented by a grouped marker,
  /// including its representative. Empty for a single place, street or free tap.
  public let alternatives: [MapSelection]

  public init(coordinate: Coordinate, feature: MapFeature? = nil, alternatives: [MapSelection] = [])
  {
    self.coordinate = coordinate
    self.feature = feature
    self.alternatives = alternatives
  }
}

enum OfflineMapSelection {
  static let tolerance: CGFloat = 16

  private struct Hit {
    let priority: Int
    let distanceSquared: CGFloat
    let selection: MapSelection
  }

  static func select(
    at tap: CGPoint, center: Coordinate, zoom: Int, size: CGSize,
    placements: [OfflineMapTilePlacement], baseZoom: Int? = nil, poiZoom: Int? = nil,
    labelObstacles: [CGRect] = [], tile: (MapTileKey) -> PreparedMapTile?
  ) -> MapSelection? {
    select(
      at: tap, center: center, displayZoom: Double(zoom), size: size,
      placements: placements, baseZoom: baseZoom, poiZoom: poiZoom,
      labelObstacles: labelObstacles, tile: tile)
  }

  static func select(
    at tap: CGPoint, center: Coordinate, displayZoom: Double, size: CGSize,
    placements: [OfflineMapTilePlacement], baseZoom: Int? = nil, poiZoom: Int? = nil,
    labelObstacles: [CGRect] = [], tile: (MapTileKey) -> PreparedMapTile?
  ) -> MapSelection? {
    guard tap.x.isFinite, tap.y.isFinite, center.lat.isFinite, abs(center.lat) <= 90,
      center.lon.isFinite,
      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      displayZoom.isFinite, (0...30).contains(displayZoom),
      CGRect(origin: .zero, size: size).contains(tap)
    else { return nil }
    let zoom = Int(floor(displayZoom))
    let centerPoint = WebMercator.world(center, displayZoom: displayZoom)
    let tappedCoordinate = WebMercator.coordinate(
      CGPoint(
        x: centerPoint.x + tap.x - size.width / 2,
        y: centerPoint.y + tap.y - size.height / 2), displayZoom: displayZoom)
    var best: Hit?
    let poiTiles = placements.compactMap { placement -> OfflineMapLabelTile? in
      guard (0...zoom).contains(placement.key.z),
        poiZoom == nil || placement.key.z == poiZoom, let prepared = tile(placement.key)
      else { return nil }
      return OfflineMapLabelTile(
        tile: prepared, offset: placement.origin(center: center, displayZoom: displayZoom, size: size),
        scale: placement.scale(atDisplayZoom: displayZoom))
    }
    let poiMarkers = OfflineMapPOILayout.markers(in: poiTiles, zoom: zoom, size: size)
    let tappedLabel = OfflineMapPOILayout.labels(
      for: poiMarkers, zoom: zoom, size: size, excluding: labelObstacles
    )
    .first { $0.frame.contains(tap) }
    for marker in poiMarkers {
      let dx = marker.point.x - tap.x
      let dy = marker.point.y - tap.y
      let distance = tappedLabel?.marker.point == marker.point ? 0 : dx * dx + dy * dy
      guard distance <= 22 * 22,
        distance < (best?.distanceSquared ?? .infinity)
      else { continue }
      func selection(_ member: OfflineMapPOILayout.Member) -> MapSelection {
        MapSelection(
          coordinate: WebMercator.coordinate(
            CGPoint(
              x: centerPoint.x + member.point.x - size.width / 2,
              y: centerPoint.y + member.point.y - size.height / 2), displayZoom: displayZoom),
          feature: member.feature)
      }
      let representative = selection(marker.members[0])
      best = Hit(
        priority: 0, distanceSquared: distance,
        selection: MapSelection(
          coordinate: representative.coordinate, feature: representative.feature,
          alternatives: marker.isGroup ? marker.members.map(selection) : []))
    }

    func consider(
      _ feature: MapFeature, point: CGPoint, priority: Int,
      placement: OfflineMapTilePlacement, origin: CGPoint, scale: CGFloat
    ) {
      let dx = point.x * scale + origin.x - tap.x
      let dy = point.y * scale + origin.y - tap.y
      let distance = dx * dx + dy * dy
      guard distance <= tolerance * tolerance else { return }
      if let best,
        best.priority < priority || (best.priority == priority && best.distanceSquared <= distance)
      {
        return
      }
      let coordinate = WebMercator.coordinate(
        CGPoint(
          x: CGFloat(placement.worldX) * 256 + point.x,
          y: CGFloat(placement.key.y) * 256 + point.y), zoom: placement.key.z)
      best = Hit(
        priority: priority, distanceSquared: distance,
        selection: MapSelection(coordinate: coordinate, feature: feature))
    }

    for placement in placements {
      guard (0...zoom).contains(placement.key.z) else { continue }
      let scale = placement.scale(atDisplayZoom: displayZoom)
      let origin = placement.origin(center: center, displayZoom: displayZoom, size: size)
      let frame = CGRect(origin: origin, size: CGSize(width: 256 * scale, height: 256 * scale))
      guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(tap),
        let tile = tile(placement.key)
      else { continue }
      let visible = CGRect(
        x: -origin.x / scale, y: -origin.y / scale,
        width: size.width / scale, height: size.height / scale
      ).intersection(PreparedMapTileIndex.tileBounds)
      guard !visible.isNull, !visible.isEmpty else { continue }
      let point = CGPoint(x: (tap.x - origin.x) / scale, y: (tap.y - origin.y) / scale)
      for candidate in tile.selectablePoints
      where !candidate.isPOI && visible.contains(candidate.point)
        && (baseZoom == nil || placement.key.z == baseZoom)
      {
        consider(
          candidate.feature, point: candidate.point, priority: candidate.isPOI ? 0 : 1,
          placement: placement, origin: origin, scale: scale)
      }
      guard baseZoom == nil || placement.key.z == baseZoom else { continue }
      // The existing immutable paths are reused. Only named streets retain
      // metadata, and a bounds check avoids walking unrelated line geometry.
      let vicinity = CGRect(
        x: point.x - tolerance / scale, y: point.y - tolerance / scale,
        width: 2 * tolerance / scale, height: 2 * tolerance / scale)
      for candidate in tile.selectableRoads {
        let path = tile.features[candidate.index].path
        guard
          path.boundingRect.insetBy(dx: -tolerance / scale, dy: -tolerance / scale)
            .intersects(vicinity),
          let nearest = OfflineMapHitGeometry.closestPoint(on: path, to: point, clippedTo: visible)
        else { continue }
        consider(
          candidate.feature, point: nearest, priority: 2, placement: placement,
          origin: origin, scale: scale)
      }
    }
    return best?.selection ?? MapSelection(coordinate: tappedCoordinate)
  }
}

enum OfflineMapHitGeometry {
  /// Paths produced by the tile decoder contain straight segments. A small
  /// viewport clip excludes buffered geometry that Canvas does not draw.
  static func closestPoint(on path: Path, to point: CGPoint, clippedTo clip: CGRect) -> CGPoint? {
    var current: CGPoint?
    var start: CGPoint?
    var nearest: CGPoint?
    var distance = CGFloat.infinity
    func segment(_ a: CGPoint, _ b: CGPoint) {
      guard let (a, b) = clipped(a, b, to: clip) else { return }
      let dx = b.x - a.x
      let dy = b.y - a.y
      let lengthSquared = dx * dx + dy * dy
      let fraction =
        lengthSquared > 0
        ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
      let candidate = CGPoint(x: a.x + fraction * dx, y: a.y + fraction * dy)
      let offsetX = candidate.x - point.x
      let offsetY = candidate.y - point.y
      let distanceSquared = offsetX * offsetX + offsetY * offsetY
      if distanceSquared < distance {
        distance = distanceSquared
        nearest = candidate
      }
    }
    // Path exposes elements by callback rather than conforming to Sequence.
    // swift-format-ignore: ReplaceForEachWithForLoop
    path.forEach { element in
      switch element {
      case .move(let point):
        current = point
        start = point
      case .line(let point):
        if let current { segment(current, point) }
        current = point
      case .closeSubpath:
        if let current, let start { segment(current, start) }
        current = start
      case .quadCurve(let point, _), .curve(let point, _, _):
        // Curves are not part of vector-tile line geometry. Never replace a
        // hypothetical curve by its chord and report a false street hit.
        current = point
      }
    }
    return nearest
  }

  private static func clipped(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
    let dx = b.x - a.x
    let dy = b.y - a.y
    var first: CGFloat = 0
    var last: CGFloat = 1
    func limit(_ p: CGFloat, _ q: CGFloat) -> Bool {
      if p == 0 { return q >= 0 }
      let fraction = q / p
      if p < 0 { first = max(first, fraction) } else { last = min(last, fraction) }
      return first <= last
    }
    guard limit(-dx, a.x - rect.minX), limit(dx, rect.maxX - a.x),
      limit(-dy, a.y - rect.minY), limit(dy, rect.maxY - a.y)
    else { return nil }
    return (
      CGPoint(x: a.x + first * dx, y: a.y + first * dy),
      CGPoint(x: a.x + last * dx, y: a.y + last * dy)
    )
  }
}
