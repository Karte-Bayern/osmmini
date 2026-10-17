import SwiftUI

struct MapTileKey: Hashable, Sendable {
  let z: Int, x: Int, y: Int
}

/// Geometry is immutable and expressed in tile pixels. Preparing it drops the
/// decoded coordinate arrays; frames only translate the graphics context.
struct PreparedMapTile: Sendable {
  enum Style: Sendable, Equatable {
    case water, forest, landcover, building
    case road(major: Bool)
  }

  struct Feature: Sendable {
    let path: Path
    let style: Style
    let name: String?
    let labelPoint: CGPoint?
  }

  let features: [Feature]

  init(_ tile: VectorTile) throws {
    var prepared: [Feature] = []
    prepared.reserveCapacity(tile.features.count)
    for feature in tile.features {
      try Task.checkCancellation()
      let style: Style
      switch feature.layer {
      case "water": style = .water
      case "landcover": style = feature.class == "forest" ? .forest : .landcover
      case "building": style = .building
      case "transportation":
        style = .road(major: ["motorway", "trunk", "primary"].contains(feature.class ?? ""))
      default: continue
      }
      guard feature.extent > 0 else { continue }
      let scale = 256 / Double(feature.extent)
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
      let labelPoint: CGPoint?
      if case .road = style, let point = feature.paths.first?.first, point.count >= 2 {
        labelPoint = CGPoint(x: Double(point[0]) * scale, y: Double(point[1]) * scale)
      } else {
        labelPoint = nil
      }
      prepared.append(
        Feature(path: path, style: style, name: feature.name, labelPoint: labelPoint))
    }
    features = prepared
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
