import Foundation

public struct Coordinate: Codable, Sendable, Hashable {
  public var lat: Double
  public var lon: Double
  public init(lat: Double, lon: Double) {
    self.lat = lat
    self.lon = lon
  }
}
public struct RegionBounds: Codable, Sendable {
  public let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
  enum CodingKeys: String, CodingKey {
    case minLat = "min_lat"
    case maxLat = "max_lat"
    case minLon = "min_lon"
    case maxLon = "max_lon"
  }
  public var center: Coordinate {
    Coordinate(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
  }
}
public struct RegionManifest: Codable, Sendable {
  public let format: Int, name: String, nodes: Int, edges: Int
  public let bounds: RegionBounds
  public let minZoom: Int, maxZoom: Int
  public let sourceSHA256: String
  enum CodingKeys: String, CodingKey {
    case format, name, nodes, edges, bounds
    case minZoom = "min_zoom"
    case maxZoom = "max_zoom"
    case sourceSHA256 = "source_sha256"
  }
}
public struct ImportProgress: Codable, Sendable, Equatable {
  public let phase: String
  public let fraction: Double
}
public struct ImportOptions: Codable, Sendable {
  public var pbf: String, destination: String, name: String
  public var minZoom = 5, maxZoom = 14, maxImportNodes = 8_000_000
  public var tileMemoryBytes: Int64 = 256 * 1024 * 1024
  public init(pbf: URL, destination: URL, name: String) {
    self.pbf = pbf.path
    self.destination = destination.path
    self.name = name
  }
  enum CodingKeys: String, CodingKey {
    case pbf, destination, name
    case minZoom = "min_zoom"
    case maxZoom = "max_zoom"
    case maxImportNodes = "max_import_nodes"
    case tileMemoryBytes = "tile_memory_bytes"
  }
}
public struct SearchResult: Codable, Sendable, Identifiable {
  public let id: Int64
  public let kind: String, label: String
  public let coordinate: Coordinate
  public let category: String?
  public var identity: String { "\(kind)/\(id)" }
}
public enum RoutingEngine: String, Codable, Sendable {
  case astar, dijkstra
  case dijkstraNode = "dijkstra-node"
}
public enum RouteObjective: String, Codable, Sendable { case distance, duration, economy }
public enum VehicleProfile: String, Codable, Sendable {
  case car, delivery, truck, travel, firefighting, emergency, thw, cycling, walking
}
public struct RouteOptions: Codable, Sendable {
  public var engine: RoutingEngine = .astar
  public var objective: RouteObjective = .distance
  public var profile: VehicleProfile = .car
  public init() {}
}
public struct RouteRequest: Codable, Sendable {
  public var from: Coordinate, to: Coordinate
  public var options: RouteOptions
  public init(from: Coordinate, to: Coordinate, options: RouteOptions = RouteOptions()) {
    self.from = from
    self.to = to
    self.options = options
  }
}
public struct Maneuver: Codable, Sendable {
  public let instruction: String
  public let lat: Double, lon: Double
}
public struct Route: Codable, Sendable {
  public let path: [Coordinate]
  public let distanceM: Double, durationS: Double, fromSnapM: Double, toSnapM: Double
  public let steps: [Maneuver]
  enum CodingKeys: String, CodingKey {
    case path, steps
    case distanceM = "distance_m"
    case durationS = "duration_s"
    case fromSnapM = "from_snap_m"
    case toSnapM = "to_snap_m"
  }
  public func geoJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(RouteGeoJSONFeature(route: self))
  }
  public func gpx() -> Data {
    var data = Data()
    data.reserveCapacity(256 + path.count * 64)
    data.append(
      contentsOf:
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"OSMmini\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>OSMmini route</name><trkseg>"
        .utf8)
    for coordinate in path {
      data.append(
        contentsOf:
          "<trkpt lat=\"\(coordinate.lat)\" lon=\"\(coordinate.lon)\"/>".utf8)
    }
    data.append(contentsOf: "</trkseg></trk></gpx>".utf8)
    return data
  }
}

private struct RouteGeoJSONFeature: Encodable {
  let route: Route
  enum CodingKeys: String, CodingKey { case type, properties, geometry }

  func encode(to encoder: any Encoder) throws {
    var feature = encoder.container(keyedBy: CodingKeys.self)
    try feature.encode("Feature", forKey: .type)
    try feature.encode(
      Properties(distanceM: route.distanceM, durationS: route.durationS), forKey: .properties)
    try feature.encode(Geometry(path: route.path), forKey: .geometry)
  }

  private struct Properties: Encodable {
    let distanceM: Double, durationS: Double
    enum CodingKeys: String, CodingKey {
      case distanceM = "distance_m"
      case durationS = "duration_s"
    }
  }

  private struct Geometry: Encodable {
    let path: [Coordinate]
    enum CodingKeys: String, CodingKey { case type, coordinates }

    func encode(to encoder: any Encoder) throws {
      var geometry = encoder.container(keyedBy: CodingKeys.self)
      try geometry.encode("LineString", forKey: .type)
      var coordinates = geometry.nestedUnkeyedContainer(forKey: .coordinates)
      for coordinate in path {
        var position = coordinates.nestedUnkeyedContainer()
        try position.encode(coordinate.lon)
        try position.encode(coordinate.lat)
      }
    }
  }
}

public struct VectorFeature: Codable, Sendable {
  public let layer: String, kind: Int, extent: Int
  public let `class`: String?, name: String?
  public let paths: [[[Int]]]
}
public struct VectorTile: Codable, Sendable { public let features: [VectorFeature] }
public enum OSMminiError: Error, LocalizedError, Sendable {
  case native(String)
  case incompatibleABI, invalidResponse
  public var errorDescription: String? {
    switch self {
    case .native(let message): message
    case .incompatibleABI: "Incompatible OSMmini native framework"
    case .invalidResponse: "Invalid native response"
    }
  }
}
