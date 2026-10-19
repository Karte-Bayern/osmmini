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

  /// A focus request can bring an overview closer without losing existing detail.
  /// A missing minimum preserves the current zoom; display limits always apply.
  static func focusing(
    _ coordinate: Coordinate?, currentZoom: Int, minimumZoom: Int? = nil,
    minZoom: Int, maxZoom: Int
  ) -> Self? {
    guard let coordinate, coordinate.lat.isFinite, abs(coordinate.lat) <= 90,
      coordinate.lon.isFinite, (0...30).contains(currentZoom),
      minZoom >= 0, maxZoom >= minZoom, maxZoom <= 30
    else { return nil }
    return Self(
      center: coordinate,
      zoom: max(minZoom, min(maxZoom, max(currentZoom, minimumZoom ?? currentZoom))))
  }

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
  var minimumZoom: Int? = nil
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
  private let viewport: CGSize?
  private var collisionIndex: CollisionIndex?

  init(obstacles: [CGRect] = [], viewport: CGSize? = nil) {
    occupied = obstacles
    self.viewport = viewport
    if obstacles.count >= 16, let viewport {
      collisionIndex = CollisionIndex(obstacles, viewport: viewport)
    }
  }

  /// Reject cheap cases before resolving and measuring Canvas text.
  func canPlace(name: String, at point: CGPoint, viewport: CGSize) -> Bool {
    guard point.x.isFinite, point.y.isFinite,
      CGRect(origin: .zero, size: viewport).insetBy(dx: 6, dy: 6).contains(point),
      !(collisionIndex?.contains(point, in: occupied)
        ?? occupied.contains(where: { $0.contains(point) }))
    else { return false }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !name.isEmpty && !names.contains(name)
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
    guard
      !(collisionIndex?.intersects(footprint, in: occupied)
        ?? occupied.contains(where: { $0.intersects(footprint) }))
    else { return false }
    occupied.append(footprint)
    if collisionIndex != nil {
      collisionIndex?.insert(footprint, at: occupied.count - 1)
    } else if occupied.count == 16, let viewport = self.viewport {
      collisionIndex = CollisionIndex(occupied, viewport: viewport)
    }
    names.insert(name)
    return true
  }

  /// Small layouts keep their linear scan. Larger ones use a bounded grid with
  /// flat linked lists, retaining each exact rectangle only once. Rectangles
  /// outside the grid remain in a fallback list, including unusual obstacles.
  private struct CollisionIndex {
    private struct Entry {
      let rectangle: UInt32
      let next: UInt32
    }

    private let bounds: CGRect
    private let cellSize: CGFloat
    private let columns: Int
    private let rows: Int
    private var heads: [UInt32]
    private var entries: [Entry] = []
    private var fallback: [Int] = []

    init?(_ rectangles: [CGRect], viewport: CGSize) {
      guard viewport.width.isFinite, viewport.height.isFinite,
        viewport.width > 0, viewport.height > 0
      else { return nil }
      bounds = CGRect(origin: .zero, size: viewport)
      // At most 32 × 32 heads, even for unusually large viewports.
      cellSize = max(64, ceil(max(viewport.width, viewport.height) / 32))
      columns = max(1, Int(ceil(viewport.width / cellSize)))
      rows = max(1, Int(ceil(viewport.height / cellSize)))
      heads = Array(repeating: .max, count: columns * rows)
      entries.reserveCapacity(rectangles.count * 2)
      for (index, rectangle) in rectangles.enumerated() { insert(rectangle, at: index) }
    }

    private func cells(for rectangle: CGRect) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
      let minX = rectangle.minX
      let minY = rectangle.minY
      let maxX = rectangle.maxX
      let maxY = rectangle.maxY
      guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
        minX >= 0, minY >= 0, maxX <= bounds.width, maxY <= bounds.height,
        minX <= maxX, minY <= maxY
      else { return nil }
      return (
        min(columns - 1, Int(minX / cellSize))...min(columns - 1, Int(maxX / cellSize)),
        min(rows - 1, Int(minY / cellSize))...min(rows - 1, Int(maxY / cellSize))
      )
    }

    mutating func insert(_ rectangle: CGRect, at index: Int) {
      guard let rectangleIndex = UInt32(exactly: index), let cells = cells(for: rectangle),
        entries.count <= Int(UInt32.max) - cells.x.count * cells.y.count
      else {
        fallback.append(index)
        return
      }
      for y in cells.y {
        for x in cells.x {
          let cell = y * columns + x
          entries.append(Entry(rectangle: rectangleIndex, next: heads[cell]))
          heads[cell] = UInt32(entries.count - 1)
        }
      }
    }

    func contains(_ point: CGPoint, in rectangles: [CGRect]) -> Bool {
      guard point.x.isFinite, point.y.isFinite,
        point.x >= 0, point.y >= 0, point.x <= bounds.width, point.y <= bounds.height
      else { return rectangles.contains(where: { $0.contains(point) }) }
      if fallback.contains(where: { rectangles[$0].contains(point) }) { return true }
      let x = min(columns - 1, Int(point.x / cellSize))
      let y = min(rows - 1, Int(point.y / cellSize))
      var entry = heads[y * columns + x]
      while entry != .max {
        let node = entries[Int(entry)]
        if rectangles[Int(node.rectangle)].contains(point) { return true }
        entry = node.next
      }
      return false
    }

    func intersects(_ rectangle: CGRect, in rectangles: [CGRect]) -> Bool {
      guard let cells = cells(for: rectangle) else {
        return rectangles.contains(where: { $0.intersects(rectangle) })
      }
      if fallback.contains(where: { rectangles[$0].intersects(rectangle) }) { return true }
      for y in cells.y {
        for x in cells.x {
          var entry = heads[y * columns + x]
          while entry != .max {
            let node = entries[Int(entry)]
            if rectangles[Int(node.rectangle)].intersects(rectangle) { return true }
            entry = node.next
          }
        }
      }
      return false
    }
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

  /// Load the center first, while leaving drawing order and task identity stable.
  /// Distance uses the displayed world copy, including across the date line.
  static func loadingKeys(in placements: [Self], center: Coordinate) -> [MapTileKey] {
    guard let zoom = placements.first?.key.z else { return [] }
    let origin = WebMercator.world(
      Coordinate(lat: center.lat, lon: center.lon.truncatingRemainder(dividingBy: 360)), zoom: zoom)
    var ranked = placements.enumerated().map { index, placement in
      let dx = (Double(placement.worldX) + 0.5) * 256 - Double(origin.x)
      let dy = (Double(placement.key.y) + 0.5) * 256 - Double(origin.y)
      return (placement: placement, distance: dx * dx + dy * dy, index: index)
    }
    ranked.sort {
      $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance
    }
    return keys(in: ranked.map(\.placement))
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
  static let maximumConcurrentLoads = 4

  private enum Outcome: Sendable {
    case loaded(PreparedMapTile)
    case failed, cancelled
  }

  private(set) var cache = PreparedMapTileCache()
  private var owner: ObjectIdentifier?
  private var keys: Set<MapTileKey> = []
  private var revision = 0
  private var failureCount = 0
  private(set) var isLoading = false

  func failures(owner: ObjectIdentifier, keys: [MapTileKey]) -> Int {
    self.owner == owner && self.keys == Set(keys) ? failureCount : 0
  }

  func load(
    owner: ObjectIdentifier, keys: [MapTileKey],
    fetch: @escaping @MainActor @Sendable (MapTileKey) async throws -> PreparedMapTile
  ) async {
    guard !Task.isCancelled else { return }
    revision += 1
    let currentRevision = revision
    self.owner = owner
    self.keys = Set(keys)
    failureCount = 0
    cache.updateViewport(owner: owner, keys: keys)
    var seen: Set<MapTileKey> = []
    let missing = keys.prefix(PreparedMapTileCache.capacity).filter {
      seen.insert($0).inserted && cache.tile(for: $0, owner: owner) == nil
    }
    isLoading = !missing.isEmpty
    defer {
      if revision == currentRevision {
        isLoading = false
        if Task.isCancelled { failureCount = 0 }
      }
    }
    // Bound both native decoding and detached path preparation. Publish each
    // completed tile immediately; a slow tile must not hold up its neighbors.
    await withTaskGroup(of: (MapTileKey, Outcome).self) { group in
      var pending = missing.makeIterator()
      func enqueue(_ key: MapTileKey) {
        group.addTask {
          do {
            try Task.checkCancellation()
            return (key, .loaded(try await fetch(key)))
          } catch is CancellationError {
            return (key, .cancelled)
          } catch {
            return (key, .failed)
          }
        }
      }
      for _ in 0..<Self.maximumConcurrentLoads {
        if let key = pending.next() { enqueue(key) }
      }
      while let (key, outcome) = await group.next() {
        guard !Task.isCancelled, revision == currentRevision else {
          group.cancelAll()
          return
        }
        switch outcome {
        case .loaded(let tile): cache.insert(tile, for: key, owner: owner)
        case .failed: failureCount += 1
        case .cancelled:
          failureCount = 0
          group.cancelAll()
          return
        }
        if let key = pending.next() { enqueue(key) }
      }
    }
  }
}
