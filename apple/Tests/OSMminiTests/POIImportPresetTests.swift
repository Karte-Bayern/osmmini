import Foundation
import Testing

@testable import OSMmini

@Test func newImportsEncodeTheirSelectedPOIPresetAndLegacyImportsKeepAllPOIs() throws {
  let source = URL(fileURLWithPath: "/tmp/region.osm.pbf")
  let destination = URL(fileURLWithPath: "/tmp/region")
  var options = ImportOptions(pbf: source, destination: destination, name: "Region")
  #expect(options.poiPreset == .everyday)
  for preset in POIImportPreset.allCases {
    options.poiPreset = preset
    let data = try JSONEncoder().encode(options)
    let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(encoded["poi_preset"] as? String == preset.rawValue)
    #expect(encoded["poiPreset"] == nil)
    #expect(try JSONDecoder().decode(ImportOptions.self, from: data).poiPreset == preset)
  }
  let legacy = Data(
    #"{"pbf":"/tmp/source.pbf","destination":"/tmp/prepared","name":"Existing","min_zoom":6,"max_zoom":13,"max_import_nodes":1234,"tile_memory_bytes":33554432}"#.utf8)
  let restored = try JSONDecoder().decode(ImportOptions.self, from: legacy)
  #expect(restored.poiPreset == .all)
  #expect(restored.minZoom == 6 && restored.maxZoom == 13)
  #expect(restored.maxImportNodes == 1234 && restored.tileMemoryBytes == 33_554_432)
  let minimalLegacy = Data(#"{"pbf":"a","destination":"b","name":"c"}"#.utf8)
  let defaults = try JSONDecoder().decode(ImportOptions.self, from: minimalLegacy)
  #expect(defaults.poiPreset == .all)
  #expect(defaults.minZoom == 5 && defaults.maxZoom == 14)
  #expect(defaults.maxImportNodes == 8_000_000 && defaults.tileMemoryBytes == 268_435_456)
  let unknown = Data(#"{"pbf":"a","destination":"b","name":"c","poi_preset":"future"}"#.utf8)
  #expect(throws: DecodingError.self) { try JSONDecoder().decode(ImportOptions.self, from: unknown) }
}

@Test func regionManifestsDistinguishLegacyUnspecifiedAndExplicitPOIPresets() throws {
  var manifest: [String: Any] = [
    "format": 4, "name": "Region", "nodes": 3, "edges": 4,
    "bounds": ["min_lat": 48, "max_lat": 49, "min_lon": 12, "max_lon": 13],
    "min_zoom": 5, "max_zoom": 14, "source_sha256": "source",
  ]
  let legacy = try JSONSerialization.data(withJSONObject: manifest)
  let oldRegion = try JSONDecoder().decode(RegionManifest.self, from: legacy)
  #expect(oldRegion.poiPreset == nil && oldRegion.importRevision == nil)
  for preset in POIImportPreset.allCases {
    manifest["poi_preset"] = preset.rawValue
    manifest["import_revision"] = RegionManifest.currentImportRevision
    let data = try JSONSerialization.data(withJSONObject: manifest)
    let region = try JSONDecoder().decode(RegionManifest.self, from: data)
    #expect(region.poiPreset == preset)
    #expect(region.importRevision == RegionManifest.currentImportRevision)
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(region)) as? [String: Any])
    #expect(encoded["import_revision"] as? Int == 8)
    #expect(encoded["importRevision"] == nil)
  }
}

@Test func activityPresetsHaveStableWireValuesAndDistinctLocalizedNames() {
  #expect(POIImportPreset.outdoor.rawValue == "outdoor")
  #expect(POIImportPreset.cycling.rawValue == "cycling")
  #expect(POIImportPreset.travel.rawValue == "travel")
  #expect(POIImportPreset.outdoor.displayName == "Outdoor")
  #expect(POIImportPreset.cycling.displayName == "Radfahren")
  #expect(POIImportPreset.travel.displayName == "Reisen")
  #expect(Set(POIImportPreset.allCases.map(\.rawValue)).count == 6)
  #expect(Set(POIImportPreset.allCases.map(\.displayName)).count == 6)
}

@Test func emergencySourceDetailsKeepRawUnitsAndDecodeOlderPlaces() throws {
  let details = EmergencyDetails(
    reference: "H-42", hydrantType: "underground", diameter: "100", pressure: "3 bar",
    waterSource: "water_works", waterVolume: "50 m³")
  let place = PlaceDetails(address: "Markt 1", emergency: details)
  let data = try JSONEncoder().encode(place)
  let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let emergency = try #require(encoded["emergency"] as? [String: String])
  #expect(emergency["hydrant_type"] == "underground")
  #expect(emergency["water_source"] == "water_works")
  #expect(emergency["water_volume"] == "50 m³")
  #expect(emergency["pressure"] == "3 bar")
  #expect(try JSONDecoder().decode(PlaceDetails.self, from: data) == place)
  let legacy = Data(#"{"address":"Markt 1","opening_hours":"24/7"}"#.utf8)
  let restored = try JSONDecoder().decode(PlaceDetails.self, from: legacy)
  #expect(restored.address == "Markt 1" && restored.emergency == nil)
}
