import SwiftUI

struct MapTileKey: Hashable, Sendable {
  let z: Int, x: Int, y: Int
}

/// Geometry is immutable and expressed in tile pixels. Preparing it drops the
/// decoded coordinate arrays; frames only translate the graphics context.
struct PreparedMapTile: Sendable {
  /// Paint styles contain no names or other strings. Most cached features are
  /// polygons and unnamed lines, so their records need only a path and one byte.
  enum Style: Sendable, Equatable {
    case water, forest, landcover, building
    case road(major: Bool)
  }

  struct Feature: Sendable {
    let path: Path
    let style: Style
  }

  struct Label: Sendable {
    enum Style: Sendable, Equatable {
      enum Place: Sendable { case city, town, village, other }
      case road(major: Bool)
      case place(Place)
    }
    let name: String
    let key: OfflineMapLabelLayout.Key
    let point: CGPoint
    let style: Style

    init(name: String, point: CGPoint, style: Style) {
      self.name = name
      key = OfflineMapLabelLayout.Key(name)
      self.point = point
      self.style = style
    }
  }

  let features: [Feature]
  let labels: [Label]
  let spatialIndex: PreparedMapTileIndex?

  init(_ tile: VectorTile) throws {
    var geometryCount = 0
    var labelCount = 0
    for feature in tile.features {
      try Task.checkCancellation()
      guard feature.extent > 0 else { continue }
      switch feature.layer {
      case "water", "landcover", "building": geometryCount += 1
      case "transportation":
        geometryCount += 1
        if Self.labelName(feature.name) != nil { labelCount += 1 }
      case "place":
        if Self.labelName(feature.name) != nil { labelCount += 1 }
      default: break
      }
    }
    var prepared: [Feature] = []
    var labels: [Label] = []
    prepared.reserveCapacity(geometryCount)
    labels.reserveCapacity(labelCount)
    for feature in tile.features {
      try Task.checkCancellation()
      guard feature.extent > 0 else { continue }
      let scale = 256 / Double(feature.extent)
      if feature.layer == "place" {
        if let name = Self.labelName(feature.name), let point = feature.paths.first?.first,
          point.count >= 2
        {
          let kind: Label.Style.Place =
            switch feature.class {
            case "city": .city
            case "town": .town
            case "village": .village
            default: .other
            }
          labels.append(
            Label(
              name: name, point: CGPoint(x: Double(point[0]) * scale, y: Double(point[1]) * scale),
              style: .place(kind)))
        }
        // Place points are text anchors, not drawable geometry. In particular,
        // they do not need a retained CoreGraphics path of their own.
        continue
      }
      let style: Style
      switch feature.layer {
      case "water": style = .water
      case "landcover": style = feature.class == "forest" ? .forest : .landcover
      case "building": style = .building
      case "transportation":
        style = .road(major: ["motorway", "trunk", "primary"].contains(feature.class ?? ""))
      default: continue
      }
      var path = Path()
      var count = 0
      for ring in feature.paths {
        for (index, point) in ring.enumerated() where point.count >= 2 {
          if count & 1023 == 0 { try Task.checkCancellation() }
          count += 1
          let position = CGPoint(x: Double(point[0]) * scale, y: Double(point[1]) * scale)
          if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        if feature.kind == 3 { path.closeSubpath() }
      }
      prepared.append(Feature(path: path, style: style))
      if case .road(let major) = style, let name = Self.labelName(feature.name),
        let point = try Self.roadLabelPoint(feature.paths, scale: scale)
      {
        labels.append(Label(name: name, point: point, style: .road(major: major)))
      }
    }
    features = prepared
    self.labels = labels
    spatialIndex = try PreparedMapTileIndex(prepared)
  }

  static func roadWidth(major: Bool, overzoom: Int) -> CGFloat {
    (major ? 3.5 : 1.8) + CGFloat(overzoom) * 0.5
  }

  /// The viewport is expressed in tile coordinates. Padding includes the widest
  /// road casing and antialiasing so lines just beyond the viewport remain visible.
  func featureIndices(in rect: CGRect, padding: CGFloat = 0) -> PreparedMapFeatureIndices {
    let visible = rect.intersection(PreparedMapTileIndex.tileBounds)
    guard !visible.isNull, !visible.isEmpty else { return PreparedMapFeatureIndices(count: 0) }
    guard let spatialIndex, !visible.contains(PreparedMapTileIndex.tileBounds) else {
      return PreparedMapFeatureIndices(count: features.count)
    }
    return spatialIndex.featureIndices(in: visible.insetBy(dx: -padding, dy: -padding))
  }

  private static func labelName(_ name: String?) -> String? {
    guard let name, !name.isEmpty, name.utf8.count <= 256 else { return nil }
    return name
  }

  /// Place the name halfway along the longest line, away from clipped tile
  /// boundaries. Preparing this once avoids path scans during map drawing.
  private static func roadLabelPoint(_ paths: [[[Int]]], scale: Double) throws -> CGPoint? {
    var longest: [[Int]] = []
    var length = 0.0
    for ring in paths {
      var previous: CGPoint?
      var candidate = 0.0
      for (index, point) in ring.enumerated() where point.count >= 2 {
        if index.isMultiple(of: 1024) { try Task.checkCancellation() }
        let current = CGPoint(x: Double(point[0]) * scale, y: Double(point[1]) * scale)
        if let previous { candidate += hypot(current.x - previous.x, current.y - previous.y) }
        previous = current
      }
      if candidate > length {
        longest = ring
        length = candidate
      }
    }
    guard length > 0 else { return nil }
    var remaining = length / 2
    var previous: CGPoint?
    for (index, point) in longest.enumerated() where point.count >= 2 {
      if index.isMultiple(of: 1024) { try Task.checkCancellation() }
      let current = CGPoint(x: Double(point[0]) * scale, y: Double(point[1]) * scale)
      if let previous {
        let segment = hypot(current.x - previous.x, current.y - previous.y)
        if segment > 0, remaining <= segment {
          let fraction = remaining / segment
          return CGPoint(
            x: previous.x + (current.x - previous.x) * fraction,
            y: previous.y + (current.y - previous.y) * fraction)
        }
        remaining -= segment
      }
      previous = current
    }
    return previous
  }

  /// Detached preparation keeps SwiftUI's main actor free. Cancellation is
  /// forwarded explicitly because detached tasks do not inherit cancellation.
  static func prepare(_ tile: VectorTile) async throws -> PreparedMapTile {
    try Task.checkCancellation()
    let preparation = Task.detached(priority: .userInitiated) {
      try PreparedMapTile(tile)
    }
    return try await withTaskCancellationHandler {
      let result = try await preparation.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      preparation.cancel()
    }
  }
}

/// Only the current viewport is retained. An engine identity prevents a region
/// switch from showing another region's geometry at the same z/x/y coordinates.
struct PreparedMapTileCache {
  static let capacity = 128
  private var owner: ObjectIdentifier?
  private var needed: Set<MapTileKey> = []
  private(set) var tiles: [MapTileKey: PreparedMapTile] = [:]

  mutating func updateViewport(owner: ObjectIdentifier, keys: [MapTileKey]) {
    needed = Set(keys.prefix(Self.capacity))
    if self.owner != owner {
      tiles.removeAll(keepingCapacity: true)
      self.owner = owner
    } else {
      tiles = tiles.filter { needed.contains($0.key) }
    }
  }

  func tile(for key: MapTileKey, owner: ObjectIdentifier) -> PreparedMapTile? {
    self.owner == owner ? tiles[key] : nil
  }

  mutating func insert(_ tile: PreparedMapTile, for key: MapTileKey, owner: ObjectIdentifier) {
    guard self.owner == owner, needed.contains(key) else { return }
    tiles[key] = tile
  }
}

/// Routes use immutable zoom-zero geometry, prepared once rather than projecting
/// every coordinate on each drag or GPS update. Small overlapping chunks let
/// drawing skip distant sections without dropping segments at chunk boundaries.
struct PreparedMapRoute: Sendable {
  static let pointsPerChunk = 128

  struct Chunk: Sendable {
    let path: Path
    let origin: CGPoint
    let bounds: CGRect
    let pointCount: Int
  }

  struct Placement {
    let index: Int
    let origin: CGPoint
    let scale: CGFloat
  }

  let chunks: [Chunk]

  init(_ coordinates: [Coordinate]) throws {
    var chunks: [Chunk] = []
    var points: [CGPoint] = []
    points.reserveCapacity(Self.pointsPerChunk)
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
        // SwiftUI Path can compress coordinates to floats. Keeping them local
        // avoids magnifying world-coordinate rounding when zooming far in.
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
        minX = min(minX, point.x)
        maxX = max(maxX, point.x)
        minY = min(minY, point.y)
        maxY = max(maxY, point.y)
      }
      chunks.append(
        Chunk(
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
      if let previous {
        // Unwrap consecutive points, so a crossing of ±180° stays connected
        // locally instead of producing a line across the entire map.
        point.x += ((previous.x - point.x) / 256).rounded() * 256
      }
      points.append(point)
      previous = point
      if points.count == Self.pointsPerChunk {
        flush()
        points.removeAll(keepingCapacity: true)
        points.append(point)
      }
    }
    try Task.checkCancellation()
    flush()
    self.chunks = chunks
  }

  /// Only chunk bounds and one camera projection are examined during a frame.
  /// World copies keep routes aligned with wrapped tiles on either dateline side.
  func visible(
    center: Coordinate, zoom: Int, size: CGSize, translation: CGSize = .zero
  ) -> [Placement] {
    guard center.lat.isFinite, center.lon.isFinite, (0...30).contains(zoom),
      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      translation.width.isFinite, translation.height.isFinite
    else { return [] }
    let scale = exp2(Double(zoom))
    let center = WebMercator.world(
      Coordinate(lat: center.lat, lon: center.lon.truncatingRemainder(dividingBy: 360)), zoom: 0)
    let origin = CGPoint(
      x: size.width / 2 + translation.width - center.x * scale,
      y: size.height / 2 + translation.height - center.y * scale)
    let padding = 4 / scale
    let viewport = CGRect(
      x: -origin.x / scale, y: -origin.y / scale,
      width: min(size.width / scale, 256 * CGFloat(PreparedMapTileCache.capacity)),
      height: min(size.height / scale, 256 * CGFloat(PreparedMapTileCache.capacity)))
    var placements: [Placement] = []
    for (index, chunk) in chunks.enumerated() {
      let bounds = chunk.bounds.insetBy(dx: -padding, dy: -padding)
      guard bounds.minY <= viewport.maxY, bounds.maxY >= viewport.minY else { continue }
      let firstCopy = ceil((viewport.minX - bounds.maxX) / 256)
      let lastCopy = floor((viewport.maxX - bounds.minX) / 256)
      guard firstCopy.isFinite, lastCopy.isFinite, firstCopy <= lastCopy else { continue }
      // At most a viewport's worth of world copies can be visible. Keeping this
      // bounded also protects callers that supply an unreasonably large canvas.
      for copy
        in 0...min(PreparedMapTileCache.capacity + Self.pointsPerChunk, Int(lastCopy - firstCopy))
      {
        placements.append(
          Placement(
            index: index,
            origin: CGPoint(
              x: origin.x + (chunk.origin.x + (firstCopy + CGFloat(copy)) * 256) * scale,
              y: origin.y + chunk.origin.y * scale),
            scale: scale))
      }
    }
    return placements
  }
}
