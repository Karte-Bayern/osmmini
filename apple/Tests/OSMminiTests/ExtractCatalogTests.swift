import Foundation
import Testing

@testable import OSMmini

@Test func franceCatalogUsesProviderPathsAndKeepsParentRegions() throws {
  let data = Data(
    #"""
    {"truncated":false,"tree":[
      {"path":"README.md","type":"blob"},
      {"path":"osc_modif/polygons/europe.poly","type":"blob","mode":"100644"},
      {"path":"osc_modif/polygons/europe/germany.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe/germany/nordrhein_westfalen.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe/vatican_city.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe/vatican_city.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe/../foreign.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe//foreign.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe/encoded%2fpath.poly","type":"blob"},
      {"path":"osc_modif/polygons/europe/link.poly","type":"blob","mode":"120000"},
      {"path":"osc_modif/polygons/europe/directory.poly","type":"tree"}
    ]}
    """#.utf8)
  let regions = try OSMExtracts.decodeCatalog(data, source: .openStreetMapFrance)
  #expect(regions.count == 4)
  let region = try #require(regions.first { $0.id == "europe/germany/nordrhein_westfalen" })
  #expect(region.name == "Nordrhein Westfalen")
  #expect(region.parent == "europe/germany")
  #expect(
    region.pbfURL.absoluteString
      == "https://download.openstreetmap.fr/extracts/europe/germany/nordrhein_westfalen-latest.osm.pbf")
  #expect(regions.first { $0.id == "europe" }?.parent == nil)
  #expect(regions.contains { $0.name == "Vatican City" })
}

@Test func franceCatalogRejectsIncompleteMalformedAndEmptyIndexes() {
  for raw in [
    #"{"truncated":true,"tree":[{"path":"osc_modif/polygons/europe.poly","type":"blob"}]}"#,
    #"{"truncated":false,"tree":[]}"#,
    #"{"message":"API rate limit exceeded"}"#,
    #"{"truncated":false,"tree":[{"path":"outside/europe.poly","type":"blob"}]}"#,
    "not JSON",
  ] {
    #expect(throws: (any Error).self) {
      try OSMExtracts.decodeCatalog(Data(raw.utf8), source: .openStreetMapFrance)
    }
  }
}

@Test func extractProvidersAcceptOnlyTheirOwnOfficialPBFLocations() throws {
  let france = try #require(
    URL(string: "https://download.openstreetmap.fr/extracts/europe/gibraltar-latest.osm.pbf"))
  let geofabrik = try #require(
    URL(string: "https://download.geofabrik.de/europe/gibraltar-latest.osm.pbf"))
  #expect(OSMExtractSource.geofabrik.permitsDownload(geofabrik))
  #expect(OSMExtractSource.openStreetMapFrance.permitsDownload(france))
  #expect(!OSMExtractSource.geofabrik.permitsDownload(france))
  #expect(!OSMExtractSource.openStreetMapFrance.permitsDownload(geofabrik))
  for raw in [
    "http://download.openstreetmap.fr/extracts/europe/gibraltar-latest.osm.pbf",
    "https://download.openstreetmap.fr/other/gibraltar-latest.osm.pbf",
    "https://download.openstreetmap.fr:443/extracts/europe/gibraltar-latest.osm.pbf",
    "https://user:secret@download.openstreetmap.fr/extracts/europe/gibraltar-latest.osm.pbf",
    "https://download.openstreetmap.fr/extracts/europe/gibraltar-latest.osm.pbf?other=1",
    "https://download.openstreetmap.fr/extracts/europe/gibraltar-latest.osm.pbf#fragment",
    "https://download.openstreetmap.fr/extracts/europe/../gibraltar-latest.osm.pbf",
    "https://download.openstreetmap.fr/extracts/europe/%2e%2e/gibraltar-latest.osm.pbf",
    "https://download.openstreetmap.fr.example.com/extracts/europe/gibraltar-latest.osm.pbf",
  ] {
    let url = try #require(URL(string: raw))
    #expect(!OSMExtractSource.openStreetMapFrance.permitsDownload(url), "\(raw)")
  }
}
