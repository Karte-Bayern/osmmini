import Foundation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_BENCHMARKS"] == "1"))
func reopeningBasemapWithStoredLayersBenchmark() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let suite = "DemoStartupBenchmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let fixture = try #require(
    Bundle.module.url(forResource: "region", withExtension: "osm.pbf", subdirectory: "Fixtures"))
  var options = ImportOptions(pbf: fixture, destination: root.appendingPathComponent("region"), name: "Startup")
  options.minZoom = 14
  options.maxZoom = 14
  try await OfflineEngine.importPBF(options)
  defaults.set("region", forKey: "lastRegion")

  let directory = root.appendingPathComponent("map-layers")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let coordinates = String(repeating: "12,48 12.001,48.001 ", count: 50_000)
  let kml = Data("<kml><Placemark><LineString><coordinates>\(coordinates)</coordinates></LineString></Placemark></kml>".utf8)
  var records: [[String: Any]] = []
  for index in 0..<DemoMapLayers.maximumLayers {
    let id = UUID()
    try kml.write(to: directory.appendingPathComponent(id.uuidString.lowercased() + ".kml"))
    records.append(["id": id.uuidString, "name": "Layer \(index)", "isVisible": true])
  }
  try JSONSerialization.data(withJSONObject: ["version": 1, "entries": records])
    .write(to: directory.appendingPathComponent("manifest.json"))

  let clock = ContinuousClock()
  var samples: [Duration] = []
  for _ in 0..<3 {
    let model = DemoModel(root: root, defaults: defaults)
    let start = clock.now
    let startup = Task { await model.start(arguments: ["--offline"]) }
    let deadline = start.advanced(by: .seconds(30))
    while model.engine == nil, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    samples.append(start.duration(to: clock.now))
    await startup.value
    let engine = try #require(model.engine)
    #expect(model.layers.entries.count == DemoMapLayers.maximumLayers)
    #expect(model.layers.error == nil)
    await engine.close()
  }
  print("Basemap available with eight 100,000-position layers: median/3 \(samples.sorted()[1])")
}
