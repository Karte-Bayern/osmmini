import Foundation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

private enum ResourceImportFailure: Error { case expected }

@MainActor private final class ImportResourceState {
  weak var model: DemoModel?
  var previousEngine: OfflineEngine?
  var imported = false
  var drained = false
}

@MainActor private final class ImportDrainGate {
  private var continuation: CheckedContinuation<Void, Never>?
  var isWaiting: Bool { continuation != nil }

  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor struct DemoImportResourcesTests {
  private let root: URL
  private let defaults: UserDefaults
  private let suite: String

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    suite = "DemoImportResourcesTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func cleanup() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  private func preparedModel(importRegion: @escaping DemoModel.RegionImporter) async throws -> DemoModel {
    let fixture = try #require(
      Bundle.module.url(forResource: "region", withExtension: "osm.pbf", subdirectory: "Fixtures"))
    let directory = root.appendingPathComponent("previous")
    var options = ImportOptions(pbf: fixture, destination: directory, name: "Previous")
    options.minZoom = 14
    options.maxZoom = 14
    try await OfflineEngine.importPBF(options)
    options.destination = root.appendingPathComponent("next").path
    options.name = "Next"
    defaults.set(try DemoStorage.savedImport(options, in: root), forKey: "pendingImport")
    let model = DemoModel(root: root, defaults: defaults, importRegion: importRegion)
    await model.start(arguments: ["demo", "--region", directory.path, "--offline"])
    model.usePlace(
      DemoPlace(coordinate: Coordinate(lat: 48.001, lon: 12.001), name: "Abfahrt", category: nil),
      as: .start)
    model.usePlace(
      DemoPlace(coordinate: Coordinate(lat: 48.003, lon: 12.003), name: "Ankunft", category: nil),
      as: .destination)
    await model.operation?.value
    return model
  }

  @Test func importReleasesThePreviousEngineBeforeStartingAndRestoresItsRouteAfterFailure() async throws {
    defer { cleanup() }
    let state = ImportResourceState()
    let model = try await preparedModel { _, _ in
      state.imported = true
      let current = try #require(state.model)
      #expect(current.mapSuspendedForImport && current.engine == nil)
      #expect(!current.canDisplayPlaces)
      let previous = try #require(state.previousEngine)
      await #expect(throws: OSMminiError.self) { try await previous.search("cafe") }
      throw ResourceImportFailure.expected
    }
    state.model = model
    state.previousEngine = model.engine
    let directory = try #require(model.activeDirectory)
    let route = try #require(model.route)
    let pending = defaults.data(forKey: "pendingImport")
    let lastRegion = defaults.string(forKey: "lastRegion")
    model.resumePendingImport()
    await model.operation?.value
    let restored = try #require(model.engine)
    #expect(state.imported)
    #expect(restored !== state.previousEngine)
    #expect(!model.mapSuspendedForImport && model.canDisplayPlaces)
    #expect(model.activeDirectory == directory)
    #expect(defaults.string(forKey: "lastRegion") == lastRegion)
    #expect(defaults.data(forKey: "pendingImport") == pending)
    #expect(model.route?.path == route.path && model.route?.distanceM == route.distanceM)
    #expect(model.startLabel == "Abfahrt" && model.destinationLabel == "Ankunft")
    #expect(model.importFailure != nil)
    #expect(!(try await restored.search("cafe")).isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    await restored.close()
  }

  @Test func cancellationDrainsTheImportBeforeReopeningThePreviousRegion() async throws {
    defer { cleanup() }
    let gate = ImportDrainGate()
    let state = ImportResourceState()
    let model = try await preparedModel { _, _ in
      await gate.wait()
      state.drained = true
      try Task.checkCancellation()
      throw ResourceImportFailure.expected
    }
    let previous = try #require(model.engine)
    let directory = model.activeDirectory
    let route = try #require(model.route)
    let pending = defaults.data(forKey: "pendingImport")
    model.resumePendingImport()
    let task = try #require(model.operation)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !gate.isWaiting, model.busy, clock.now < deadline { await Task.yield() }
    try #require(gate.isWaiting)
    model.cancel()
    #expect(!state.drained && model.engine == nil && model.mapSuspendedForImport)
    await #expect(throws: OSMminiError.self) { try await previous.search("cafe") }
    gate.finish()
    await task.value
    let restored = try #require(model.engine)
    #expect(state.drained && restored !== previous)
    #expect(!model.busy && !model.mapSuspendedForImport)
    #expect(model.status.contains("Abgebrochen"))
    #expect(model.activeDirectory == directory)
    #expect(defaults.data(forKey: "pendingImport") == pending)
    #expect(model.route?.path == route.path && model.route?.durationS == route.durationS)
    #expect(model.startLabel == "Abfahrt" && model.destinationLabel == "Ankunft")
    #expect(!(try await restored.search("cafe")).isEmpty)
    await restored.close()
  }

  @Test func successfulReplacementPublishesTheNewRegionAndKeepsTheOldRegionOnDisk() async throws {
    defer { cleanup() }
    let state = ImportResourceState()
    let model = try await preparedModel { options, progress in
      let previous = try #require(state.previousEngine)
      await #expect(throws: OSMminiError.self) { try await previous.search("cafe") }
      return try await OfflineEngine.importPBF(options, progress: progress)
    }
    state.previousEngine = model.engine
    let previousDirectory = try #require(model.activeDirectory)
    model.resumePendingImport()
    await model.operation?.value
    #expect(model.engine?.manifest.name == "Next")
    #expect(model.activeDirectory == root.appendingPathComponent("next"))
    #expect(!model.mapSuspendedForImport && model.pending == nil)
    #expect(model.importFailure == nil && model.regionError == nil)
    #expect(model.route == nil && model.start == nil && model.destination == nil)
    #expect(FileManager.default.fileExists(atPath: previousDirectory.appendingPathComponent("manifest.json").path))
    await model.engine?.close()
  }
}
