import Foundation
import Observation

enum WebMercator {
  static let maximumLatitude = 85.0511

  static func world(_ coordinate: Coordinate, zoom: Int) -> CGPoint {
    let scale = exp2(Double(zoom)) * 256
    let latitude = max(-maximumLatitude, min(maximumLatitude, coordinate.lat)) * .pi / 180
    return CGPoint(
      x: (coordinate.lon + 180) / 360 * scale,
      y: (1 - asinh(tan(latitude)) / .pi) / 2 * scale)
  }

  static func coordinate(_ point: CGPoint, zoom: Int) -> Coordinate {
    let scale = exp2(Double(zoom)) * 256
    let latitude = atan(sinh(.pi * (1 - 2 * point.y / scale))) * 180 / .pi
    let longitude =
      ((point.x / scale * 360).truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360) - 180
    return Coordinate(lat: max(-maximumLatitude, min(maximumLatitude, latitude)), lon: longitude)
  }

  static func offset(_ coordinate: Coordinate, from center: Coordinate, zoom: Int) -> CGPoint {
    let point = world(coordinate, zoom: zoom)
    let origin = world(center, zoom: zoom)
    let scale = exp2(Double(zoom)) * 256
    var dx = (point.x - origin.x).truncatingRemainder(dividingBy: scale)
    if dx > scale / 2 { dx -= scale }
    if dx < -scale / 2 { dx += scale }
    return CGPoint(x: dx, y: point.y - origin.y)
  }

  static func metersPerPixel(latitude: Double, zoom: Int) -> Double? {
    guard latitude.isFinite, abs(latitude) <= 90, (0...30).contains(zoom) else { return nil }
    let latitude = min(maximumLatitude, max(-maximumLatitude, latitude))
    return cos(latitude * .pi / 180) * 40_075_016.685_578_49 / (256 * exp2(Double(zoom)))
  }
}

struct OfflineMapViewport: Sendable {
  let center: Coordinate
  let zoom: Int

  /// Keep the coordinate under a double tap fixed while changing zoom.
  static func zooming(
    center: Coordinate, from oldZoom: Int, to zoom: Int, at anchor: CGPoint, size: CGSize
  ) -> Self? {
    guard center.lat.isFinite, abs(center.lat) <= 90, center.lon.isFinite,
      (0...30).contains(oldZoom), (0...30).contains(zoom),
      anchor.x.isFinite, anchor.y.isFinite, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0
    else { return nil }
    let offset = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
    let origin = WebMercator.world(center, zoom: oldZoom)
    let point = WebMercator.coordinate(
      CGPoint(x: origin.x + offset.x, y: origin.y + offset.y), zoom: oldZoom)
    let projected = WebMercator.world(point, zoom: zoom)
    return Self(
      center: WebMercator.coordinate(
        CGPoint(x: projected.x - offset.x, y: projected.y - offset.y), zoom: zoom), zoom: zoom)
  }

  /// Region bounds describe an interval, which may cover more than half the world.
  /// Unlike a route, that interval must not be replaced with the shorter longitude arc.
  static func fitting(
    _ bounds: RegionBounds, size: CGSize, minZoom: Int, maxZoom: Int,
    padding: CGFloat = 48
  ) -> Self? {
    guard bounds.minLat.isFinite, bounds.maxLat.isFinite, bounds.minLon.isFinite,
      bounds.maxLon.isFinite, bounds.minLat >= -90, bounds.maxLat <= 90,
      bounds.minLat <= bounds.maxLat, bounds.minLon >= -180, bounds.minLon <= 180,
      bounds.maxLon >= -180, bounds.maxLon <= 180
    else { return nil }
    let northWest = WebMercator.world(
      Coordinate(lat: bounds.maxLat, lon: bounds.minLon), zoom: 0)
    let southEast = WebMercator.world(
      Coordinate(lat: bounds.minLat, lon: bounds.maxLon), zoom: 0)
    var longitudeSpan = bounds.maxLon - bounds.minLon
    if longitudeSpan < 0 { longitudeSpan += 360 }
    return fitting(
      minX: northWest.x, maxX: northWest.x + longitudeSpan / 360 * 256,
      minY: northWest.y, maxY: southEast.y, size: size, minZoom: minZoom, maxZoom: maxZoom,
      padding: padding)
  }

  /// Fit projected coordinates, using the shortest longitude arc across the dateline.
  /// Small viewports retain at least half their width and height for the route.
  static func fitting(
    _ coordinates: [Coordinate], size: CGSize, minZoom: Int, maxZoom: Int,
    padding: CGFloat = 48
  ) -> Self? {
    guard !Task.isCancelled, size.width.isFinite, size.height.isFinite, size.width > 0,
      size.height > 0,
      minZoom >= 0, maxZoom >= minZoom, maxZoom <= 30
    else { return nil }
    var xs: [CGFloat] = []
    xs.reserveCapacity(coordinates.count)
    var minY = CGFloat.infinity
    var maxY = -CGFloat.infinity
    for (index, coordinate) in coordinates.enumerated() {
      if index.isMultiple(of: 1024), Task.isCancelled { return nil }
      guard coordinate.lat.isFinite, coordinate.lon.isFinite else { continue }
      let point = WebMercator.world(
        Coordinate(lat: coordinate.lat, lon: coordinate.lon.truncatingRemainder(dividingBy: 360)),
        zoom: 0)
      xs.append(
        ((point.x.truncatingRemainder(dividingBy: 256)) + 256)
          .truncatingRemainder(dividingBy: 256))
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }
    guard !xs.isEmpty, !Task.isCancelled else { return nil }
    xs.sort()
    guard !Task.isCancelled else { return nil }
    var largestGap = -Double.infinity
    var start = xs[0]
    for index in xs.indices {
      if index.isMultiple(of: 1024), Task.isCancelled { return nil }
      let next = index + 1 < xs.count ? xs[index + 1] : xs[0] + 256
      let gap = next - xs[index]
      if gap > largestGap {
        largestGap = gap
        start = next.truncatingRemainder(dividingBy: 256)
      }
    }
    let width = max(0, 256 - largestGap)
    return fitting(
      minX: start, maxX: start + width, minY: minY, maxY: maxY,
      size: size, minZoom: minZoom, maxZoom: maxZoom, padding: padding)
  }

  private static func fitting(
    minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat,
    size: CGSize, minZoom: Int, maxZoom: Int, padding: CGFloat
  ) -> Self? {
    guard !Task.isCancelled, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0, padding.isFinite,
      minZoom >= 0, maxZoom >= minZoom, maxZoom <= 30
    else { return nil }
    let width = maxX - minX
    let inset = min(max(0, padding), min(size.width, size.height) / 4)
    let availableWidth = max(CGFloat.leastNormalMagnitude, size.width - 2 * inset)
    let availableHeight = max(CGFloat.leastNormalMagnitude, size.height - 2 * inset)
    let scaleX = width > 0 ? availableWidth / width : .infinity
    let scaleY = maxY > minY ? availableHeight / (maxY - minY) : .infinity
    let scale = min(scaleX, scaleY)
    let fittedZoom = scale.isFinite ? Int(floor(log2(scale))) : maxZoom
    return Self(
      center: WebMercator.coordinate(
        CGPoint(x: minX + width / 2, y: (minY + maxY) / 2), zoom: 0),
      zoom: max(minZoom, min(maxZoom, fittedZoom)))
  }
}

/// Automatic framing follows viewport resizing until the user deliberately moves
/// the map. Clearing a route retains the current view instead of jumping away.
struct OfflineMapCameraIntent {
  enum Framing { case region, route, manual }
  enum Update { case engine, route, unchanged }
  private(set) var framing: Framing = .region
  private(set) var owner: ObjectIdentifier?
  private var path: [Coordinate]?

  mutating func update(
    owner: ObjectIdentifier, path: [Coordinate]?, hasExplicitCenter: Bool
  ) -> Update {
    let path = path.flatMap { $0.isEmpty ? nil : $0 }
    let engineChanged = self.owner != owner
    let routeChanged = self.path != path
    self.owner = owner
    self.path = path
    if engineChanged {
      framing = path != nil ? .route : hasExplicitCenter ? .manual : .region
      return .engine
    }
    if routeChanged {
      framing = path == nil ? .manual : .route
      return .route
    }
    return .unchanged
  }

  mutating func navigate() { framing = .manual }
  mutating func showRegion() { framing = .region }
  mutating func showRoute() { framing = .route }
}

struct OfflineMapFocusRequest: Equatable {
  let coordinate: Coordinate?
  let id: UUID?
}

struct OfflineMapMarker {
  enum Role { case start, destination, other }
  let coordinate: Coordinate
  let label: String
  let role: Role

  static func make(
    legacy: [Coordinate], start: Coordinate?, destination: Coordinate?
  ) -> [Self] {
    if start != nil || destination != nil {
      var markers: [Self] = []
      if let start { markers.append(Self(coordinate: start, label: "A", role: .start)) }
      if let destination {
        markers.append(Self(coordinate: destination, label: "B", role: .destination))
      }
      return markers
    }
    return legacy.enumerated().map { index, coordinate in
      Self(
        coordinate: coordinate,
        label: index == 0 ? "A" : index == 1 ? "B" : "\(index + 1)",
        role: index == 0 ? .start : index == 1 ? .destination : .other)
    }
  }
}

struct OfflineMapLabelLayout {
  private var occupied: [CGRect]
  private var names: Set<String> = []

  init(obstacles: [CGRect] = []) { occupied = obstacles }

  /// Reject cheap cases before resolving and measuring Canvas text.
  func canPlace(name: String, at point: CGPoint, viewport: CGSize) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !name.isEmpty && !names.contains(name) && point.x.isFinite && point.y.isFinite
      && CGRect(origin: .zero, size: viewport).insetBy(dx: 6, dy: 6).contains(point)
      && !occupied.contains(where: { $0.contains(point) })
  }

  /// A viewport-wide layout keeps adjacent tiles from drawing duplicate or
  /// overlapping names. Only successfully placed labels claim their name.
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

enum OfflineMapLocationAccuracy {
  static func radius(_ accuracy: Double?, latitude: Double, zoom: Int) -> CGFloat? {
    guard let accuracy, accuracy.isFinite, accuracy > 0,
      let metersPerPixel = WebMercator.metersPerPixel(latitude: latitude, zoom: zoom)
    else { return nil }
    let radius = accuracy / metersPerPixel
    return radius.isFinite ? radius : nil
  }
}

struct OfflineMapScale {
  let meters: Double
  let width: CGFloat

  var label: String {
    let value = meters >= 1_000 ? meters / 1_000 : meters
    return
      "\(value.formatted(.number.precision(.significantDigits(1...3)))) \(meters >= 1_000 ? "km" : "m")"
  }

  static func make(latitude: Double, zoom: Int, maximumWidth: CGFloat = 112) -> Self? {
    guard maximumWidth.isFinite, maximumWidth > 0,
      let metersPerPixel = WebMercator.metersPerPixel(latitude: latitude, zoom: zoom)
    else { return nil }
    let available = metersPerPixel * maximumWidth
    guard available.isFinite, available > 0 else { return nil }
    let magnitude = pow(10, floor(log10(available)))
    let factor = [5.0, 2.0, 1.0].first { $0 * magnitude <= available } ?? 1
    let meters = factor * magnitude
    return Self(meters: meters, width: meters / metersPerPixel)
  }
}

/// Owns one fit calculation. Explicit user navigation or a newer route invalidates
/// both the awaiting task and any late result from a noncooperative calculation.
@MainActor final class OfflineMapViewportFitter {
  private var task: Task<Void, Never>?
  private var revision: UInt64 = 0

  @discardableResult
  func fit(
    _ bounds: RegionBounds, size: CGSize, minZoom: Int, maxZoom: Int,
    apply: @escaping @MainActor (OfflineMapViewport) -> Void
  ) -> Task<Void, Never> {
    start(
      calculate: {
        OfflineMapViewport.fitting(bounds, size: size, minZoom: minZoom, maxZoom: maxZoom)
      }, apply: apply)
  }

  @discardableResult
  func fit(
    _ coordinates: [Coordinate], size: CGSize, minZoom: Int, maxZoom: Int,
    apply: @escaping @MainActor (OfflineMapViewport) -> Void
  ) -> Task<Void, Never> {
    start(
      calculate: {
        OfflineMapViewport.fitting(coordinates, size: size, minZoom: minZoom, maxZoom: maxZoom)
      }, apply: apply)
  }

  @discardableResult
  func start(
    calculate: @escaping @Sendable () async -> OfflineMapViewport?,
    apply: @escaping @MainActor (OfflineMapViewport) -> Void
  ) -> Task<Void, Never> {
    cancel()
    let currentRevision = revision
    let worker = Task.detached(priority: .userInitiated) { await calculate() }
    let waiter = Task { [weak self] in
      let viewport = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self, self.revision == currentRevision, !Task.isCancelled else { return }
      self.task = nil
      if let viewport { apply(viewport) }
    }
    task = waiter
    return waiter
  }

  func cancel() {
    revision &+= 1
    task?.cancel()
    task = nil
  }
}

/// A route replacement or region switch owns its own preparation. Cancellation
/// propagates to the detached work; late results cannot draw a previous route.
@MainActor @Observable final class OfflineMapRouteLoader {
  private var owner: ObjectIdentifier?
  private var coordinates: [Coordinate]?
  private var prepared: PreparedMapRoute?
  private var revision: UInt64 = 0

  func route(owner: ObjectIdentifier, coordinates: [Coordinate]?) -> PreparedMapRoute? {
    self.owner == owner && self.coordinates == coordinates ? prepared : nil
  }

  func load(
    owner: ObjectIdentifier, coordinates: [Coordinate]?,
    prepare: @escaping @Sendable ([Coordinate]) async throws -> PreparedMapRoute = {
      try PreparedMapRoute($0)
    }
  ) async {
    revision &+= 1
    let currentRevision = revision
    self.owner = owner
    self.coordinates = coordinates
    prepared = nil
    guard let coordinates, !coordinates.isEmpty, !Task.isCancelled else { return }
    let worker = Task.detached(priority: .userInitiated) { try await prepare(coordinates) }
    do {
      let result = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard revision == currentRevision, !Task.isCancelled else { return }
      prepared = result
    } catch {
      // Preparation only throws cancellation. A replacement owns subsequent UI.
    }
  }
}

struct OfflineMapTilePlacement: Hashable {
  let key: MapTileKey
  let worldX: Int

  func scale(at zoom: Int) -> CGFloat {
    exp2(Double(zoom - key.z))
  }

  /// Source geometry remains in 256-pixel tile coordinates, even when the
  /// display zoom exceeds the finest tile available in the offline region.
  func origin(center: Coordinate, zoom: Int, size: CGSize) -> CGPoint {
    let projected = WebMercator.world(
      Coordinate(lat: center.lat, lon: center.lon.truncatingRemainder(dividingBy: 360)), zoom: zoom)
    let tileSize = 256 * scale(at: zoom)
    return CGPoint(
      x: Double(worldX) * tileSize - projected.x + size.width / 2,
      y: Double(key.y) * tileSize - projected.y + size.height / 2)
  }

  static func keys(in placements: [Self]) -> [MapTileKey] {
    var seen: Set<MapTileKey> = []
    return placements.compactMap { seen.insert($0.key).inserted ? $0.key : nil }
  }

  static func visible(
    center: Coordinate, zoom: Int, size: CGSize, tileZoom: Int? = nil
  ) -> [Self] {
    let sourceZoom = min(zoom, tileZoom ?? zoom)
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      zoom >= 0, zoom <= 30, sourceZoom >= 0, center.lat.isFinite, center.lon.isFinite
    else { return [] }
    let origin = WebMercator.world(
      Coordinate(lat: center.lat, lon: center.lon.truncatingRemainder(dividingBy: 360)), zoom: zoom)
    let count = Int(exp2(Double(sourceZoom)))
    let tileSize = 256 * exp2(Double(zoom - sourceZoom))
    let halfWidth = min(size.width / 2, CGFloat(PreparedMapTileCache.capacity) * tileSize)
    let halfHeight = min(size.height / 2, CGFloat(PreparedMapTileCache.capacity) * tileSize)
    let minX = Int(floor((origin.x - halfWidth) / tileSize))
    let maxX = Int(floor((origin.x + halfWidth) / tileSize))
    let minY = max(0, Int(floor((origin.y - halfHeight) / tileSize)))
    let maxY = min(count - 1, Int(floor((origin.y + halfHeight) / tileSize)))
    guard minY <= maxY else { return [] }
    var placements: [Self] = []
    for y in minY...maxY {
      for x in minX...maxX {
        guard placements.count < PreparedMapTileCache.capacity else { return placements }
        placements.append(
          Self(key: MapTileKey(z: sourceZoom, x: (x % count + count) % count, y: y), worldX: x))
      }
    }
    return placements
  }
}

/// A failed tile must not prevent the remaining viewport from loading. Retrying
/// preserves successfully prepared tiles; a newer load owns all subsequent UI changes.
@MainActor @Observable final class OfflineMapTileLoader {
  private(set) var cache = PreparedMapTileCache()
  private var owner: ObjectIdentifier?
  private var keys: [MapTileKey] = []
  private var revision = 0
  private var failureCount = 0
  private(set) var isLoading = false

  func failures(owner: ObjectIdentifier, keys: [MapTileKey]) -> Int {
    self.owner == owner && self.keys == keys ? failureCount : 0
  }

  func load(
    owner: ObjectIdentifier, keys: [MapTileKey],
    fetch: (MapTileKey) async throws -> PreparedMapTile
  ) async {
    guard !Task.isCancelled else { return }
    revision += 1
    let currentRevision = revision
    self.owner = owner
    self.keys = keys
    failureCount = 0
    isLoading = true
    cache.updateViewport(owner: owner, keys: keys)
    defer {
      if revision == currentRevision {
        isLoading = false
        if Task.isCancelled { failureCount = 0 }
      }
    }
    for key in keys where cache.tile(for: key, owner: owner) == nil {
      guard !Task.isCancelled, revision == currentRevision else { return }
      do {
        let tile = try await fetch(key)
        guard !Task.isCancelled, revision == currentRevision else { return }
        cache.insert(tile, for: key, owner: owner)
      } catch is CancellationError {
        if revision == currentRevision { failureCount = 0 }
        return
      } catch {
        guard !Task.isCancelled, revision == currentRevision else { return }
        failureCount += 1
      }
    }
  }
}
