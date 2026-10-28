import SwiftUI

/// Imported geometry is projected once. Frames translate and scale immutable
/// paths, using the same wrapped Mercator coordinates as the offline basemap.
struct PreparedMapOverlay: Sendable {
  private struct Polygon: Sendable {
    let path: Path
    let origin: CGPoint
    let bounds: CGRect
  }

  private enum Shape: Sendable {
    case point(coordinate: Coordinate, world: CGPoint)
    case line(PreparedMapRoute)
    case polygon(Polygon)
  }

  private struct Item: Sendable {
    let feature: MapFeature
    let label: String?
    let shape: Shape
  }

  private struct Placement {
    let origin: CGPoint
    let scale: CGFloat
  }

  private struct Camera {
    let scale: CGFloat
    let base: CGPoint
    let viewport: CGRect

    init(center: Coordinate, zoom: Double, size: CGSize, translation: CGSize = .zero) {
      scale = exp2(zoom)
      let projected = WebMercator.world(
        Coordinate(lat: center.lat, lon: center.lon.truncatingRemainder(dividingBy: 360)), zoom: 0)
      base = CGPoint(
        x: size.width / 2 + translation.width - projected.x * scale,
        y: size.height / 2 + translation.height - projected.y * scale)
      viewport = CGRect(
        x: -base.x / scale, y: -base.y / scale,
        width: min(size.width / scale, 256 * CGFloat(PreparedMapTileCache.capacity)),
        height: min(size.height / scale, 256 * CGFloat(PreparedMapTileCache.capacity)))
    }
  }

  private let items: [Item]
  private static let tint = Color(red: 0.49, green: 0.25, blue: 0.72)

  init(_ document: KMLDocument) throws {
    var items: [Item] = []
    items.reserveCapacity(document.features.count)
    for feature in document.features {
      try Task.checkCancellation()
      let shape: Shape
      switch feature.geometry {
      case .point(let point):
        shape = .point(coordinate: point, world: WebMercator.world(point, zoom: 0))
      case .lineString(let coordinates):
        shape = .line(try PreparedMapRoute(coordinates))
      case .polygon(let outer, let holes):
        shape = .polygon(try Self.polygon(outer: outer, holes: holes))
      }
      items.append(
        Item(
          feature: MapFeature(
            name: feature.name ?? document.name, kind: "kml", category: "kml",
            sourceIdentity: "kml/\(feature.id.uuidString)"),
          label: feature.name, shape: shape))
    }
    self.items = items
  }

  static func prepare(_ document: KMLDocument) async throws -> Self {
    let worker = Task.detached(priority: .userInitiated) { try Self(document) }
    return try await withTaskCancellationHandler {
      let result = try await worker.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      worker.cancel()
    }
  }

  func draw(
    in context: inout GraphicsContext, center: Coordinate, displayZoom: Double,
    size: CGSize, translation: CGSize = .zero
  ) {
    guard Self.valid(center: center, zoom: displayZoom, size: size) else { return }
    let camera = Camera(center: center, zoom: displayZoom, size: size, translation: translation)
    var labels: [(String, CGPoint)] = []
    for item in items {
      switch item.shape {
      case .point(_, let point):
        for placement in Self.placements(
          origin: point, bounds: CGRect(origin: point, size: .zero), camera: camera)
        {
          let frame = CGRect(
            x: placement.origin.x - 6, y: placement.origin.y - 6, width: 12, height: 12)
          context.fill(Path(ellipseIn: frame), with: .color(Self.tint))
          context.stroke(Path(ellipseIn: frame), with: .color(.white), lineWidth: 2)
          if let label = item.label, labels.count < 100 { labels.append((label, placement.origin)) }
        }
      case .line(let route):
        for chunk in route.chunks {
          for placement in Self.placements(
            origin: chunk.origin, bounds: chunk.bounds, camera: camera)
          {
            var drawing = context
            drawing.translateBy(x: placement.origin.x, y: placement.origin.y)
            drawing.scaleBy(x: placement.scale, y: placement.scale)
            drawing.stroke(
              chunk.path, with: .color(Self.tint),
              style: StrokeStyle(lineWidth: 3 / placement.scale, lineCap: .round, lineJoin: .round))
          }
        }
      case .polygon(let polygon):
        for placement in Self.placements(
          origin: polygon.origin, bounds: polygon.bounds, camera: camera)
        {
          var drawing = context
          drawing.translateBy(x: placement.origin.x, y: placement.origin.y)
          drawing.scaleBy(x: placement.scale, y: placement.scale)
          drawing.fill(
            polygon.path, with: .color(Self.tint.opacity(0.16)), style: FillStyle(eoFill: true))
          drawing.stroke(
            polygon.path, with: .color(Self.tint),
            style: StrokeStyle(lineWidth: 2 / placement.scale, lineJoin: .round))
        }
      }
    }
    var reserved: [CGRect] = []
    let viewport = CGRect(origin: .zero, size: size)
    for (label, point) in labels {
      let text = context.resolve(
        Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.black))
      let measured = text.measure(in: CGSize(width: 180, height: 20))
      let frame = CGRect(
        x: point.x + 10, y: point.y - measured.height / 2, width: measured.width,
        height: measured.height)
      guard viewport.contains(frame), !reserved.contains(where: { $0.intersects(frame) }) else {
        continue
      }
      reserved.append(frame.insetBy(dx: -3, dy: -2))
      context.fill(
        Path(roundedRect: frame.insetBy(dx: -3, dy: -2), cornerRadius: 3),
        with: .color(.white.opacity(0.94)))
      context.draw(text, in: frame)
    }
  }

  func select(at tap: CGPoint, center: Coordinate, displayZoom: Double, size: CGSize)
    -> MapSelection?
  {
    guard Self.valid(center: center, zoom: displayZoom, size: size),
      CGRect(origin: .zero, size: size).contains(tap)
    else { return nil }
    let camera = Camera(center: center, zoom: displayZoom, size: size)
    var best: (priority: Int, distance: CGFloat, selection: MapSelection)?
    func consider(
      _ item: Item, point: CGPoint, priority: Int, placement: Placement,
      coordinate suppliedCoordinate: Coordinate? = nil
    ) {
      let screen = CGPoint(
        x: placement.origin.x + point.x * placement.scale,
        y: placement.origin.y + point.y * placement.scale)
      let distance = hypot(screen.x - tap.x, screen.y - tap.y)
      guard distance <= 18 else { return }
      if let best,
        best.priority < priority || (best.priority == priority && best.distance <= distance)
      {
        return
      }
      let coordinate = WebMercator.coordinate(
        CGPoint(
          x: (screen.x - camera.base.x) / camera.scale,
          y: (screen.y - camera.base.y) / camera.scale), zoom: 0)
      best = (
        priority, distance,
        MapSelection(coordinate: suppliedCoordinate ?? coordinate, feature: item.feature)
      )
    }
    for item in items {
      switch item.shape {
      case .point(let coordinate, let point):
        for placement in Self.placements(
          origin: point, bounds: CGRect(origin: point, size: .zero), camera: camera)
        { consider(item, point: .zero, priority: 0, placement: placement, coordinate: coordinate) }
      case .line(let route):
        for chunk in route.chunks {
          for placement in Self.placements(
            origin: chunk.origin, bounds: chunk.bounds, camera: camera)
          {
            let local = CGPoint(
              x: (tap.x - placement.origin.x) / placement.scale,
              y: (tap.y - placement.origin.y) / placement.scale)
            let clip = CGRect(
              x: -placement.origin.x / placement.scale, y: -placement.origin.y / placement.scale,
              width: size.width / placement.scale, height: size.height / placement.scale)
            if let point = OfflineMapHitGeometry.closestPoint(
              on: chunk.path, to: local, clippedTo: clip)
            {
              consider(
                item, point: point, priority: 1,
                placement: Placement(origin: placement.origin, scale: placement.scale))
            }
          }
        }
      case .polygon(let polygon):
        for placement in Self.placements(
          origin: polygon.origin, bounds: polygon.bounds, camera: camera)
        {
          let local = CGPoint(
            x: (tap.x - placement.origin.x) / placement.scale,
            y: (tap.y - placement.origin.y) / placement.scale)
          if polygon.path.contains(local, eoFill: true) {
            consider(item, point: local, priority: 2, placement: placement)
          }
        }
      }
    }
    return best?.selection
  }

  private static func polygon(outer: [Coordinate], holes: [[Coordinate]]) throws -> Polygon {
    var origin: CGPoint?
    var path = Path()
    var minX = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var minY = CGFloat.infinity
    var maxY = -CGFloat.infinity
    for ring in [outer] + holes {
      var points: [CGPoint] = []
      var previous: CGPoint?
      for (index, coordinate) in ring.enumerated() {
        if index.isMultiple(of: 1024) { try Task.checkCancellation() }
        var point = WebMercator.world(coordinate, zoom: 0)
        if let reference = previous ?? origin {
          point.x += ((reference.x - point.x) / 256).rounded() * 256
        }
        if origin == nil { origin = point }
        previous = point
        minX = min(minX, point.x)
        maxX = max(maxX, point.x)
        minY = min(minY, point.y)
        maxY = max(maxY, point.y)
        points.append(CGPoint(x: point.x - origin!.x, y: point.y - origin!.y))
      }
      guard !points.isEmpty else { continue }
      path.move(to: points[0])
      for point in points.dropFirst() { path.addLine(to: point) }
      path.closeSubpath()
    }
    guard let origin else { throw OSMminiError.native("Die KML-Fläche enthält keine Koordinaten.") }
    return Polygon(
      path: path, origin: origin,
      bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
  }

  private static func valid(center: Coordinate, zoom: Double, size: CGSize) -> Bool {
    center.lat.isFinite && abs(center.lat) <= 90 && center.lon.isFinite && zoom.isFinite
      && (0...30).contains(zoom) && size.width.isFinite && size.height.isFinite
      && size.width > 0 && size.height > 0
  }

  private static func placements(
    origin: CGPoint, bounds: CGRect, camera: Camera
  ) -> [Placement] {
    let scale = camera.scale
    let viewport = camera.viewport
    let bounds = bounds.insetBy(dx: -18 / scale, dy: -18 / scale)
    guard bounds.minY <= viewport.maxY, bounds.maxY >= viewport.minY else { return [] }
    let first = ceil((viewport.minX - bounds.maxX) / 256)
    let last = floor((viewport.maxX - bounds.minX) / 256)
    guard first.isFinite, last.isFinite, first <= last else { return [] }
    return (0...min(PreparedMapTileCache.capacity, Int(last - first))).map { copy in
      Placement(
        origin: CGPoint(
          x: camera.base.x + (origin.x + first * 256 + CGFloat(copy) * 256) * scale,
          y: camera.base.y + origin.y * scale), scale: scale)
    }
  }
}
