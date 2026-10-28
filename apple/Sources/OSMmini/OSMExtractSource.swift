import Foundation

public enum OSMExtractSource: String, CaseIterable, Codable, Sendable, Identifiable {
  case geofabrik
  case openStreetMapFrance

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .geofabrik: "Geofabrik"
    case .openStreetMapFrance: "OpenStreetMap France"
    }
  }

  public var catalogURL: URL {
    switch self {
    case .geofabrik:
      URL(string: "https://download.geofabrik.de/index-v1-nogeom.json")!
    case .openStreetMapFrance:
      URL(
        string:
          "https://api.github.com/repos/osm-fr/osm-extract-replication/git/trees/master?recursive=1")!
    }
  }

  public var cacheFilename: String {
    switch self {
    case .geofabrik: "geofabrik-index.json"
    case .openStreetMapFrance: "osmfr-index.json"
    }
  }

  func permitsDownload(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "https", components.user == nil, components.password == nil,
      components.port == nil, components.query == nil, components.fragment == nil,
      components.percentEncodedPath == url.path, url.path.hasSuffix(".osm.pbf")
    else { return false }
    let host: String
    let prefix: String
    switch self {
    case .geofabrik:
      host = "download.geofabrik.de"
      prefix = "/"
    case .openStreetMapFrance:
      host = "download.openstreetmap.fr"
      prefix = "/extracts/"
    }
    guard components.host == host, url.path.hasPrefix(prefix) else { return false }
    let path = String(url.path.dropFirst(prefix.count).dropLast(".osm.pbf".count))
    return Self.validRegionPath(path)
  }

  static func validRegionPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { part in
      !part.isEmpty && part.utf8.allSatisfy {
        (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0)
          || $0 == 45 || $0 == 95
      }
    }
  }
}
