import Foundation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

@MainActor struct DemoImportPresetTests {
  private let root: URL
  private let defaults: UserDefaults
  private let suite: String

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    suite = "DemoImportPresetTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func cleanup() {
    try? FileManager.default.removeItem(at: root)
    defaults.removePersistentDomain(forName: suite)
  }

  private func fixture() throws -> URL {
    try #require(
      Bundle.module.url(forResource: "region", withExtension: "osm.pbf", subdirectory: "Fixtures"))
  }

  @Test func newImportSelectionPersistsAndUnknownPreferencesUseTheEverydayDefault() {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    #expect(model.selectedPOIPreset == .everyday)
    #expect(model.operation == nil && model.pending == nil)
    for preset in POIImportPreset.allCases {
      model.selectPOIPreset(preset)
      #expect(defaults.string(forKey: "poiImportPreset") == preset.rawValue)
      let reopened = DemoModel(root: root, defaults: defaults)
      #expect(reopened.selectedPOIPreset == preset)
      #expect(reopened.operation == nil && reopened.pending == nil)
    }
    defaults.set("future-preset", forKey: "poiImportPreset")
    let reopened = DemoModel(root: root, defaults: defaults)
    #expect(reopened.selectedPOIPreset == .everyday)
    #expect(defaults.string(forKey: "poiImportPreset") == "future-preset")
  }

  @Test func legacySliceRequestsKeepAllPOIsIndependentOfTheCurrentSelection() throws {
    defer { cleanup() }
    let legacy = Data(#"{"center":{"lat":48.75,"lon":12.96},"radiusKM":60}"#.utf8)
    defaults.set(legacy, forKey: "pendingSliceDownload")
    defaults.set(POIImportPreset.firefighting.rawValue, forKey: "poiImportPreset")
    let model = DemoModel(root: root, defaults: defaults)
    let request = try #require(model.pendingSlice)
    #expect(model.selectedPOIPreset == .firefighting)
    #expect(request.poiPreset == nil && request.resolvedPOIPreset == .all)
    #expect(request.center == Coordinate(lat: 48.75, lon: 12.96) && request.radiusKM == 60)
    model.selectPOIPreset(.everyday)
    #expect(model.pendingSlice?.resolvedPOIPreset == .all)
    #expect(defaults.data(forKey: "pendingSliceDownload") == legacy)
    #expect(model.operation == nil)
  }

  @Test func legacyPendingImportsPreserveTheirProfileAndLimitsWhenThePreferenceChanges() throws {
    defer { cleanup() }
    var options = ImportOptions(
      pbf: try fixture(), destination: root.appendingPathComponent("resume"), name: "Fortsetzen")
    options.minZoom = 14
    options.maxZoom = 14
    options.maxImportNodes = 12_345
    options.tileMemoryBytes = 32 * 1024 * 1024
    let workspace = URL(fileURLWithPath: options.destination + ".pending")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data("checkpoint".utf8).write(to: workspace.appendingPathComponent("source"))
    var encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
    encoded.removeValue(forKey: "poi_preset")
    let legacy = try JSONSerialization.data(withJSONObject: encoded)
    defaults.set(legacy, forKey: "pendingImport")
    defaults.set(POIImportPreset.firefighting.rawValue, forKey: "poiImportPreset")
    let model = DemoModel(root: root, defaults: defaults)
    let pending = try #require(model.pending)
    #expect(pending.poiPreset == .all)
    #expect(pending.minZoom == 14 && pending.maxZoom == 14)
    #expect(pending.maxImportNodes == 12_345 && pending.tileMemoryBytes == 33_554_432)
    model.selectPOIPreset(.everyday)
    #expect(model.pending?.poiPreset == .all)
    #expect(defaults.data(forKey: "pendingImport") == legacy)
    #expect(model.operation == nil)
  }

  @Test func localImportsCaptureTheProfileAndReuseOnlyTheMatchingPreparedVariant() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    let source = try fixture()
    model.selectPOIPreset(.firefighting)
    model.importFile(source)
    // The copy/import task has not run yet; a later preference must not change it.
    model.selectPOIPreset(.everyday)
    await model.operation?.value
    let fireManifest = try #require(model.engine?.manifest)
    let fireDirectory = try #require(model.activeDirectory)
    #expect(fireManifest.poiPreset == .firefighting)
    #expect(fireManifest.importRevision == 8)
    let fireEngine = try #require(model.engine)
    #expect(!(try await fireEngine.search("cafe")).contains { $0.category == "cafe" })
    let point = WebMercator.world(Coordinate(lat: 48.002, lon: 12.002), zoom: 14)
    let tile = try await fireEngine.tile(z: 14, x: Int(point.x / 256), y: Int(point.y / 256))
    #expect(!tile.features.contains { $0.layer == "poi" && $0.class == "cafe" })
    #expect(model.installed.count == 1 && model.pending == nil)
    #expect(model.selectedPOIPreset == .everyday)
    let graph = fireDirectory.appendingPathComponent("graph.bin")
    let graphData = try Data(contentsOf: graph)

    model.importFile(source)
    await model.operation?.value
    let dailyManifest = try #require(model.engine?.manifest)
    let dailyDirectory = try #require(model.activeDirectory)
    #expect(dailyDirectory != fireDirectory)
    #expect(dailyManifest.poiPreset == .everyday)
    #expect(dailyManifest.importRevision == 8)
    #expect(dailyManifest.sourceSHA256 == fireManifest.sourceSHA256)
    #expect(dailyManifest.nodes == fireManifest.nodes && dailyManifest.edges == fireManifest.edges)
    #expect(!(try await #require(model.engine).search("cafe")).isEmpty)
    #expect(Set(model.installed.compactMap(\.poiPreset)) == [.everyday, .firefighting])

    model.selectPOIPreset(.firefighting)
    model.importFile(source)
    await model.operation?.value
    #expect(model.activeDirectory == fireDirectory)
    #expect(model.engine?.manifest.poiPreset == .firefighting)
    #expect(model.installed.count == 2 && model.pending == nil && model.importFailure == nil)
    #expect(try Data(contentsOf: graph) == graphData)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains {
      $0.hasPrefix("source-") || $0.hasSuffix(".pending")
    })
    #expect(FileManager.default.fileExists(atPath: source.path))
    await model.engine?.close()
  }

  @Test func activityImportsKeepSeparateVariantsAndPreserveRoadsAndAddresses() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    let source = try fixture()
    let presets: [POIImportPreset] = [.outdoor, .cycling, .travel]
    let point = WebMercator.world(Coordinate(lat: 48.002, lon: 12.002), zoom: 14)
    var directories = Set<URL>()
    var manifests: [RegionManifest] = []
    var graphs: [Data] = []

    for preset in presets {
      model.selectPOIPreset(preset)
      model.importFile(source)
      await model.operation?.value
      let engine = try #require(model.engine)
      let manifest = engine.manifest
      let directory = try #require(model.activeDirectory)
      #expect(model.selectedPOIPreset == preset)
      #expect(model.importFailure == nil && model.pending == nil)
      #expect(manifest.poiPreset == preset && manifest.importRevision == 8)
      #expect(manifest.nodes == 3 && manifest.edges == 4)
      #expect(directories.insert(directory).inserted)

      let graph = try Data(contentsOf: directory.appendingPathComponent("graph.bin"))
      if let baseline = manifests.first {
        #expect(manifest.sourceSHA256 == baseline.sourceSHA256)
        #expect(manifest.nodes == baseline.nodes && manifest.edges == baseline.edges)
        #expect(graph == graphs.first)
      }
      manifests.append(manifest)
      graphs.append(graph)

      let streets = try await engine.search("Teststraße")
      #expect(streets.contains { $0.kind == "street" && $0.label == "Teststraße" })
      let addresses = try await engine.search("Teststraße 7")
      let address = try #require(addresses.first { $0.identity == "node/2" })
      #expect(address.details?.address == "Teststraße 7")

      // The fixture's café is also an address: Outdoor retains the address
      // while Radfahren and Reisen expose the café in search and on the map.
      let includesCafe = preset != .outdoor
      let cafes = try await engine.search("cafe")
      #expect(cafes.contains { $0.category == "cafe" } == includesCafe)
      let tile = try await engine.tile(z: 14, x: Int(point.x / 256), y: Int(point.y / 256))
      #expect(
        tile.features.contains { $0.layer == "poi" && $0.class == "cafe" } == includesCafe)
      if !includesCafe {
        #expect(address.category == nil && address.label == "Teststraße 7")
      }
    }

    #expect(model.installed.count == presets.count)
    #expect(Set(model.installed.compactMap(\.poiPreset)) == Set(presets))
    #expect(model.installed.allSatisfy { $0.importRevision == 8 })
    await model.engine?.close()
  }
}
