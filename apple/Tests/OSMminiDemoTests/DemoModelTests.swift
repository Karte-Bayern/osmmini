import Foundation
import OSMmini
import Observation
import Testing

@testable import OSMminiDemoCLI

private final class ChangeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@MainActor @Suite(.serialized) struct DemoModelTests {
  let root: URL
  let defaults: UserDefaults
  let suite: String

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    suite = "OSMminiDemoTests.\(UUID().uuidString)"
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

  private func readyModel() async throws -> DemoModel {
    let region = root.appendingPathComponent("prepared")
    var options = ImportOptions(pbf: try fixture(), destination: region, name: "Testregion")
    options.minZoom = 14
    options.maxZoom = 14
    options.tileMemoryBytes = 64 * 1024 * 1024
    try await OfflineEngine.importPBF(options)
    let model = DemoModel(root: root, defaults: defaults)
    await model.start(arguments: ["demo", "--region", region.path, "--offline"])
    #expect(model.engine != nil)
    return model
  }

  @Test func staleProgressCannotOverwriteNewPhasesCancellationOrCompletion() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    let (events, event) = AsyncStream<UUID>.makeStream()
    let (gate, release) = AsyncStream<Void>.makeStream()
    model.run(.importing, status: "Starting") { id in
      let old = model.beginPhase(id, status: "Download")
      let current = model.beginPhase(id, status: "Import")
      model.receiveProgress(old, fraction: 1, status: "Late download")
      #expect(model.status == "Import")
      model.receiveProgress(current, fraction: 0.5, status: "Halfway")
      event.yield(current)
      for await _ in gate { break }
      try Task.checkCancellation()
    }
    let task = try #require(model.operation)
    var iterator = events.makeAsyncIterator()
    let phase = try #require(await iterator.next())
    #expect(model.fraction == 0.5)
    model.cancel()
    model.receiveProgress(phase, fraction: 1, status: "Late import")
    #expect(model.status == "Halfway")
    release.finish()
    await task.value
    let completed = model.status
    model.receiveProgress(phase, fraction: 1, status: "Even later")
    #expect(model.status == completed)
    #expect(!model.busy)
    #expect(model.fraction == nil)
    #expect(model.operation == nil)
    event.finish()
  }

  @Test func progressAndCatalogTypingDoNotInvalidateMapProperties() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    let changes = ChangeCounter()
    withObservationTracking {
      _ = model.engine
      _ = model.route
      _ = model.start
      _ = model.destination
      _ = model.focus
      _ = model.focusRequest
    } onChange: {
      changes.increment()
    }
    model.run(.downloading, status: "Starting") { id in
      let phase = model.beginPhase(id, status: "Download")
      for index in 0...100 {
        model.receiveProgress(phase, fraction: Double(index) / 100, status: "\(index)")
      }
      model.catalogQuery = "Bayern"
    }
    await model.operation?.value
    #expect(changes.count == 0)
  }

  @Test func regionListUsesManifestNamesAndOmitsUnpublishedOrBrokenDirectories() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let region = try #require(model.activeDirectory)
    try FileManager.default.copyItem(
      at: region, to: root.appendingPathComponent("not-finished.pending"))
    let broken = root.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("invalid".utf8).write(to: broken.appendingPathComponent("manifest.json"))
    await model.refreshInstalled()
    #expect(model.installed.count == 1)
    #expect(model.installed.first?.name == "Testregion")
    #expect(model.installed.first?.nodes == 3)
    #expect(model.installed.first?.directory == region)
    await model.engine?.close()
  }

  @Test func catalogFilteringUsesCachedDataAndTrimsQueries() async throws {
    defer { cleanup() }
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let features = (0..<75).map {
      "{\"properties\":{\"id\":\"europe/test-\($0)\",\"name\":\"Region \($0)\",\"urls\":{\"pbf\":\"https://download.geofabrik.de/test-\($0).osm.pbf\"}}}"
    }.joined(separator: ",")
    try Data("{\"features\":[\(features)]}".utf8).write(
      to: downloads.appendingPathComponent("geofabrik-index.json"))
    let model = DemoModel(root: root, defaults: defaults)
    #expect(!model.catalogLoaded)
    await model.loadCatalog()
    #expect(model.catalogLoaded)
    model.catalogQuery = "  REGION  "
    #expect(model.catalogMatchCount == 75)
    #expect(model.filteredRegions.count == 50)
    model.catalogQuery = " EUROPE/test-74 "
    #expect(model.filteredRegions.map(\.id) == ["europe/test-74"])
    model.catalogQuery = "unknown"
    #expect(model.catalogMatchCount == 0)
    #expect(model.filteredRegions.isEmpty)
  }

  @Test func catalogSearchMatchesHierarchyAndAccentsWithExactRegionsFirst() async throws {
    defer { cleanup() }
    let entries: [(String, String, String?)] = [
      ("europe", "Europa", nil),
      ("germany", "Deutschland", "europe"),
      ("bayern", "Bayern", "germany"),
      ("niederbayern", "Niederbayern", "bayern"),
      ("oberbayern", "Oberbayern", "bayern"),
      ("baden-wuerttemberg", "Baden-Württemberg", "germany"),
      ("cycle-a", "Cycle A", "cycle-b"),
      ("cycle-b", "Cycle B", "cycle-a"),
      ("orphan", "Ohne Elternregion", "unavailable"),
    ]
    let features = entries.map { id, name, parent -> [String: Any] in
      var properties: [String: Any] = [
        "id": id, "name": name,
        "urls": ["pbf": "https://download.geofabrik.de/\(id).osm.pbf"],
      ]
      if let parent { properties["parent"] = parent }
      return ["properties": properties]
    }
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["features": features]).write(
      to: downloads.appendingPathComponent("geofabrik-index.json"))
    let model = DemoModel(root: root, defaults: defaults)
    await model.loadCatalog()

    model.catalogQuery = "BAYERN"
    #expect(model.filteredRegions.map(\.id) == ["bayern", "niederbayern", "oberbayern"])
    model.catalogQuery = "  Niederbayern   EUROPA "
    let niederbayern = try #require(model.filteredRegions.first)
    #expect(model.filteredRegions.map(\.id) == ["niederbayern"])
    #expect(model.catalogContext(for: niederbayern) == "Europa · Deutschland · Bayern")
    model.catalogQuery = "baden wurttemberg"
    #expect(model.filteredRegions.map(\.id) == ["baden-wuerttemberg"])
    model.catalogQuery = "Cycle A"
    let cycle = try #require(model.filteredRegions.first { $0.id == "cycle-a" })
    #expect(model.catalogContext(for: cycle) == "Cycle B")
    model.catalogQuery = "Ohne Elternregion"
    let orphan = try #require(model.filteredRegions.first)
    #expect(model.catalogContext(for: orphan).isEmpty)
  }

  @Test func downloadAndInputFailuresKeepTheirSpecificRecoveryAdvice() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    let error = URLError(.notConnectedToInternet)
    model.run(.downloading, status: "Download") { _ in throw error }
    await model.operation?.value
    let network = try #require(model.importFailure)
    #expect(network.message.contains("Internetverbindung"))
    #expect(network.details == error.localizedDescription)
    #expect(network.message != network.details)
    #expect(model.pending == nil)

    model.importFile(root.appendingPathComponent("map.geojson"))
    await model.operation?.value
    let input = try #require(model.importFailure)
    #expect(input.message.contains("Endung .osm.pbf"))
    #expect(input.message != input.details)
    #expect(model.pending == nil)
  }

  @Test func routeSelectionIsStableWhileBusyAndResetCancelsRouting() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let first = Coordinate(lat: 48, lon: 12)
    model.select(first)
    let (gate, release) = AsyncStream<Void>.makeStream()
    model.run(.routing, status: "Routing") { _ in
      for await _ in gate { break }
      try Task.checkCancellation()
    }
    let task = try #require(model.operation)
    model.select(Coordinate(lat: 48.1, lon: 12.1))
    #expect(model.start == first)
    #expect(model.destination == nil)
    model.clearRoute()
    #expect(task.isCancelled)
    #expect(model.start == nil)
    #expect(model.destination == nil)
    release.finish()
    await task.value
    #expect(model.route == nil)
    #expect(model.status == "Routenberechnung abgebrochen.")
    await model.engine?.close()
  }

  @Test func clearingSearchRemovesResultsImmediatelyAndCancelsPendingSearch() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    model.query = "cafe"
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while model.searching, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.results.isEmpty)
    model.query = "a different query"
    #expect(model.results.isEmpty)
    #expect(model.searching)
    model.query = "  "
    await Task.yield()
    #expect(!model.searching)
    #expect(model.results.isEmpty)
    #expect(model.searchError == nil)
    await model.engine?.close()
  }

  @Test func dismissingAnUnfinishedSearchStopsWorkAndReopeningResumesTheSameQuery() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let presentation = UUID()
    model.resumeSearch(for: presentation)
    model.query = "cafe"
    #expect(model.searching)
    model.suspendSearch(for: presentation)
    #expect(model.query == "cafe")
    #expect(!model.searching)
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.results.isEmpty)
    #expect(model.searchError == nil)

    model.resumeSearch(for: presentation)
    #expect(model.searching)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while model.searching, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.searching)
    #expect(!model.results.isEmpty)
    let rows = model.results
    model.suspendSearch(for: presentation)
    model.resumeSearch(for: presentation)
    #expect(!model.searching)
    #expect(model.results.map(\.identity) == rows.map(\.identity))

    model.retrySearch()
    #expect(model.searching)
    model.suspendSearch(for: presentation)
    model.query = ""
    model.resumeSearch(for: presentation)
    #expect(!model.searching)
    #expect(model.results.isEmpty)
    await model.engine?.close()
  }

  @Test func closingOneSearchWindowDoesNotCancelAnotherWindowsQuery() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let first = UUID()
    let second = UUID()
    model.resumeSearch(for: first)
    model.resumeSearch(for: first)
    model.resumeSearch(for: second)
    model.query = "cafe"
    model.suspendSearch(for: first)
    model.suspendSearch(for: first)
    #expect(model.searching)

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while model.searching, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.searching)
    #expect(!model.results.isEmpty)

    model.query = "school"
    #expect(model.searching)
    model.suspendSearch(for: second)
    #expect(!model.searching)
    model.resumeSearch(for: first)
    #expect(model.searching)
    model.suspendSearch(for: first)
    await model.engine?.close()
  }

  @Test func localImportCleansItsSourceCopyAndReopensWithoutCatalog() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    model.importFile(try fixture())
    await model.operation?.value
    #expect(model.engine?.manifest.name == "region")
    #expect(model.pending == nil)
    #expect(defaults.data(forKey: "pendingImport") == nil)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!files.contains { $0.hasPrefix("source-") })
    // If reopening accidentally consults the catalog, this matching cached
    // entry will become visible. Keep the check independent of the network.
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try Data(
      #"{"features":[{"properties":{"id":"niederbayern","name":"Niederbayern","urls":{"pbf":"https://download.geofabrik.de/test.osm.pbf"}}}]}"#
        .utf8
    ).write(to: downloads.appendingPathComponent("geofabrik-index.json"))
    let reopened = DemoModel(root: root, defaults: defaults)
    await reopened.start(arguments: ["demo"])
    #expect(reopened.engine?.manifest.name == "region")
    #expect(reopened.filteredRegions.isEmpty)
    #expect(!reopened.catalogLoading)
    let engine = reopened.engine
    await reopened.start(arguments: ["demo", "--region", "/does/not/exist"])
    #expect(reopened.engine === engine)
    await model.engine?.close()
    await reopened.engine?.close()
  }

  @Test func importingTheSamePBFTwiceReusesThePublishedRegionWithoutLeavingSourceCopies()
    async throws
  {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    let source = try fixture()
    model.importFile(source)
    await model.operation?.value
    let directory = try #require(model.activeDirectory)
    let original = try #require(model.engine?.manifest)
    #expect(original.minZoom == 5 && original.maxZoom == 14)
    #expect(model.installed.count == 1)
    let files = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    let graph = directory.appendingPathComponent("graph.bin")
    let graphDate = try graph.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let graphData = try Data(contentsOf: graph)

    model.importFile(source)
    await model.operation?.value
    #expect(model.importFailure == nil)
    #expect(model.pending == nil)
    #expect(defaults.data(forKey: "pendingImport") == nil)
    #expect(model.activeDirectory == directory)
    #expect(model.engine?.manifest.sourceSHA256 == original.sourceSHA256)
    #expect(model.engine?.manifest.minZoom == original.minZoom)
    #expect(model.engine?.manifest.maxZoom == original.maxZoom)
    #expect(model.installed.map(\.directory) == [directory])
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    #expect(after == files)
    #expect(!after.contains { $0.hasPrefix("source-") || $0.hasSuffix(".pending") })
    #expect(try Data(contentsOf: graph) == graphData)
    #expect(
      try graph.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        == graphDate)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!(try await #require(model.engine).search("cafe")).isEmpty)
    await model.engine?.close()
  }

  @Test func downloadCleanupWaitsUntilIdleAndPreservesTheActiveOfflineMapAndRoute() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let engine = try #require(model.engine)
    let directory = try #require(model.activeDirectory)
    let graph = directory.appendingPathComponent("graph.bin")
    let manifest = directory.appendingPathComponent("manifest.json")
    let graphData = try Data(contentsOf: graph)
    let manifestData = try Data(contentsOf: manifest)
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let cached = downloads.appendingPathComponent("cached-region.osm.pbf")
    let resume = cached.appendingPathExtension("resume")
    let catalog = downloads.appendingPathComponent("geofabrik-index.json")
    try Data(repeating: 1, count: 19).write(to: cached)
    try Data(repeating: 2, count: 12).write(to: resume)
    let catalogData = Data(#"{"features":[]}"#.utf8)
    try catalogData.write(to: catalog)
    await model.refreshInstalled()
    #expect(model.downloadBytes == 31)
    let installedBytes = model.installedBytes
    model.select(Coordinate(lat: 48.001, lon: 12.001))
    model.select(Coordinate(lat: 48.003, lon: 12.003))
    await model.operation?.value
    let route = try #require(model.route)
    let start = model.start
    let destination = model.destination
    let savedRegion = defaults.string(forKey: "lastRegion")

    let (gate, release) = AsyncStream<Void>.makeStream()
    model.run(.opening, status: "Opening") { _ in
      for await _ in gate { break }
      try Task.checkCancellation()
    }
    let opening = try #require(model.operation)
    model.clearDownloads()
    #expect(model.activity == .opening)
    #expect(!opening.isCancelled)
    #expect(model.downloadBytes == 31)
    #expect(FileManager.default.fileExists(atPath: cached.path))
    #expect(FileManager.default.fileExists(atPath: resume.path))
    model.cancel()
    release.finish()
    await opening.value

    model.clearDownloads()
    #expect(model.activity == .deleting)
    await model.operation?.value
    #expect(!FileManager.default.fileExists(atPath: cached.path))
    #expect(!FileManager.default.fileExists(atPath: resume.path))
    #expect(try Data(contentsOf: catalog) == catalogData)
    #expect(model.downloadBytes == 0)
    #expect(model.installedBytes == installedBytes)
    #expect(model.installed.map(\.directory) == [directory])
    #expect(model.engine === engine)
    #expect(model.activeDirectory == directory)
    #expect(defaults.string(forKey: "lastRegion") == savedRegion)
    #expect(model.start == start && model.destination == destination)
    #expect(model.route?.path == route.path)
    #expect(try Data(contentsOf: graph) == graphData)
    #expect(try Data(contentsOf: manifest) == manifestData)
    #expect(model.regionError == nil)
    #expect(!(try await engine.search("cafe")).isEmpty)
    let after = try await engine.route(
      RouteRequest(from: try #require(start), to: try #require(destination)))
    #expect(after.path == route.path)
    await engine.close()
  }

  @Test func pendingImportPreventsDownloadCleanupFromRemovingItsSourceOrResumeData() async throws {
    defer { cleanup() }
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let source = downloads.appendingPathComponent("cached-region.osm.pbf")
    let resume = source.appendingPathExtension("resume")
    let sourceData = try Data(contentsOf: fixture())
    let resumeData = Data(repeating: 7, count: 12)
    try sourceData.write(to: source)
    try resumeData.write(to: resume)
    let options = try pendingOptions(pbf: source)
    let pendingData = try #require(defaults.data(forKey: "pendingImport"))
    let model = DemoModel(root: root, defaults: defaults)
    await model.refreshInstalled()
    let bytes = Int64(sourceData.count + resumeData.count)
    #expect(model.downloadBytes == bytes)
    model.clearDownloads()
    #expect(model.operation == nil)
    #expect(!model.busy)
    #expect(model.pending?.pbf == options.pbf)
    #expect(defaults.data(forKey: "pendingImport") == pendingData)
    #expect(model.downloadBytes == bytes)
    #expect(try Data(contentsOf: source) == sourceData)
    #expect(try Data(contentsOf: resume) == resumeData)
    #expect(FileManager.default.fileExists(atPath: options.destination + ".pending/sentinel"))
  }

  @Test func cancelledSourceCopyLeavesNoPartialFile() async throws {
    defer { cleanup() }
    let source = try fixture()
    let target = root.appendingPathComponent("copy.osm.pbf")
    let (gate, release) = AsyncStream<Void>.makeStream()
    let task = Task.detached {
      for await _ in gate { break }
      try DemoStorage.copyPBF(source, to: target)
    }
    task.cancel()
    release.finish()
    do {
      try await task.value
      Issue.record("Cancelled copy succeeded")
    } catch is CancellationError {}
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("partial").path))
  }

  @Test func routingAndExportUseTheSelectedEndpoints() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    model.select(Coordinate(lat: 48.001, lon: 12.001))
    model.select(Coordinate(lat: 48.003, lon: 12.003))
    #expect(model.busy)
    #expect(model.fraction == nil)
    await model.operation?.value
    let route = try #require(model.route)
    #expect(route.path.count == 3)
    #expect(try RouteExportFormat.gpx.encode(route) == route.gpx())
    #expect(try RouteExportFormat.geoJSON.encode(route) == route.geoJSON())
    if #available(iOS 18, macOS 15, *) {
      #expect(RouteExportFormat.geoJSON.contentType.preferredFilenameExtension == "geojson")
    }
    let engine = model.engine
    model.openRegion(try #require(model.activeDirectory))
    #expect(model.operation == nil)
    #expect(model.engine === engine)
    #expect(model.route != nil)
    model.clearRoute()
    #expect(model.route == nil)
    await model.engine?.close()
  }

  @Test func routingPreferenceRecalculatesWithoutLosingEndpointsAndPersists() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let start = DemoPlace(
      coordinate: Coordinate(lat: 48.001, lon: 12.001), name: "Start", category: nil)
    let destination = DemoPlace(
      coordinate: Coordinate(lat: 48.003, lon: 12.003), name: "Ziel", category: nil)
    model.usePlace(start, as: .start)
    model.usePlace(destination, as: .destination)
    await model.operation?.value
    #expect(model.route != nil)
    #expect(model.routeObjective == .distance)
    model.setRouteObjective(.duration)
    #expect(model.activity == .routing)
    #expect(model.route == nil)
    #expect(model.routeObjective == .duration)
    let calculation = try #require(model.operation)
    // A second input during calculation must neither alter its options nor cancel it.
    model.setRouteObjective(.distance)
    #expect(model.routeObjective == .duration)
    #expect(!calculation.isCancelled)
    await calculation.value
    let route = try #require(model.route)
    #expect(model.start == start.coordinate && model.startLabel == start.name)
    #expect(
      model.destination == destination.coordinate && model.destinationLabel == destination.name)
    var options = RouteOptions()
    options.objective = .duration
    let expected = try await #require(model.engine).route(
      RouteRequest(from: start.coordinate, to: destination.coordinate, options: options))
    #expect(route.path == expected.path)
    #expect(route.distanceM == expected.distanceM && route.durationS == expected.durationS)
    #expect(defaults.string(forKey: "routeObjective") == "duration")
    #expect(DemoModel(root: root, defaults: defaults).routeObjective == .duration)
    model.setRouteObjective(.duration)
    #expect(model.operation == nil)
    model.setRouteObjective(.economy)
    #expect(model.routeObjective == .duration && model.route?.path == route.path)
    model.clearRoute()
    #expect(model.routeObjective == .duration)
    await model.engine?.close()
  }

  @Test func unsupportedSavedRoutingObjectivesFallBackWithoutStartingWork() throws {
    defer { cleanup() }
    for value in ["invalid", "economy"] {
      defaults.set(value, forKey: "routeObjective")
      let model = DemoModel(root: root, defaults: defaults)
      #expect(model.routeObjective == .distance)
      #expect(model.operation == nil)
    }
  }

  @Test func streetSearchPreviewKeepsItsTypeAndDoesNotSetRouteEndpoints() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let result = try JSONDecoder().decode(
      SearchResult.self,
      from: Data(
        #"{"id":7,"kind":"street","label":"Teststraße","coordinate":{"lat":48.002,"lon":12.002}}"#
          .utf8))
    model.inspect(result)
    let preview = try #require(model.inspectedPlace)
    #expect(preview.kind == "street")
    #expect(preview.name == result.label && preview.coordinate == result.coordinate)
    #expect(DemoPlaceText.category(preview.category, kind: preview.kind) == "Straße")
    #expect(model.start == nil && model.destination == nil)
    await model.engine?.close()
  }

  @Test func sourceCleanupOnlyRemovesOwnedImportCopies() throws {
    defer { cleanup() }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let owned = root.appendingPathComponent("source-\(UUID().uuidString).osm.pbf")
    let original = root.appendingPathComponent("original.osm.pbf")
    let similar = root.appendingPathComponent("source-personal.osm.pbf")
    for file in [owned, original, similar] { try Data([1]).write(to: file) }
    for file in [owned, original, similar] { DemoStorage.removeImportedSource(file.path, in: root) }
    #expect(!FileManager.default.fileExists(atPath: owned.path))
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(FileManager.default.fileExists(atPath: similar.path))
  }

  @Test func routeEndpointsCanBeCorrectedAndErrorsRetriedWithoutLosingTheStart() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let start = Coordinate(lat: 48.001, lon: 12.001)
    let target = Coordinate(lat: 48.003, lon: 12.003)
    model.chooseRoutePoint(.destination)
    #expect(model.selectedRoutePoint == .destination)
    model.chooseRoutePoint(.start)
    model.select(start)
    #expect(model.selectedRoutePoint == .destination)
    model.select(Coordinate(lat: 0, lon: 0))
    await model.operation?.value
    #expect(model.route == nil)
    #expect(model.routeError?.contains("außerhalb") == true)
    #expect(model.start == start)
    #expect(model.canCalculateRoute)
    model.retryRoute()
    await model.operation?.value
    #expect(model.routeError != nil)
    model.select(target)
    await model.operation?.value
    #expect(model.route != nil)
    #expect(model.routeError == nil)
    #expect(model.start == start)
    #expect(model.destination == target)
    let changedStart = Coordinate(lat: 48.002, lon: 12.002)
    model.chooseRoutePoint(.start)
    model.select(changedStart)
    await model.operation?.value
    #expect(model.start == changedStart)
    #expect(model.focus == changedStart)
    #expect(model.destination == target)
    #expect(model.route?.path.count == 2)
    model.clearRoute()
    #expect(model.selectedRoutePoint == .start)
    #expect(model.startLabel == nil && model.destinationLabel == nil)
    #expect(model.routeError == nil)
    await model.engine?.close()
  }

  @Test func selectedSearchResultKeepsItsPlaceNameForTheRoute() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let engine = try #require(model.engine)
    let place = try #require(try await engine.search("cafe").first)
    model.select(place)
    #expect(model.start == place.coordinate)
    #expect(model.startLabel == place.label)
    model.select(Coordinate(lat: 48.003, lon: 12.003))
    await model.operation?.value
    model.chooseRoutePoint(.destination)
    model.select(place)
    await model.operation?.value
    #expect(model.startLabel == place.label)
    #expect(model.destinationLabel == place.label)
    #expect(model.focus == place.coordinate)
    await engine.close()
  }

  @Test func inspectingMapPointsAndSearchResultsPreservesTheExistingRouteAndEndpoints() async throws
  {
    defer { cleanup() }
    let model = try await readyModel()
    let engine = try #require(model.engine)
    let start = DemoPlace(
      coordinate: Coordinate(lat: 48.001, lon: 12.001), name: "Abfahrt", category: nil)
    let destination = DemoPlace(
      coordinate: Coordinate(lat: 48.003, lon: 12.003), name: "Ankunft", category: nil)
    model.usePlace(start, as: .start)
    model.usePlace(destination, as: .destination)
    await model.operation?.value
    let route = try #require(model.route)
    let selectedPoint = model.selectedRoutePoint
    #expect(model.focusRequest != nil)

    let mapPoint = Coordinate(lat: 48.002, lon: 12.002)
    model.inspect(mapPoint)
    #expect(model.inspectedPlace?.coordinate == mapPoint)
    #expect(model.focus == mapPoint)
    #expect(model.start == start.coordinate)
    #expect(model.destination == destination.coordinate)
    #expect(model.startLabel == start.name)
    #expect(model.destinationLabel == destination.name)
    #expect(model.route?.path == route.path)
    #expect(model.route?.distanceM == route.distanceM)
    #expect(model.selectedRoutePoint == selectedPoint)
    #expect(model.operation == nil)

    let result = try #require(try await engine.search("cafe").first)
    model.inspect(result)
    #expect(model.inspectedPlace?.coordinate == result.coordinate)
    #expect(model.inspectedPlace?.name == result.label)
    #expect(model.inspectedPlace?.category == result.category)
    #expect(model.focus == result.coordinate)
    let initialFocus = try #require(model.focusRequest)
    model.focusOn(result.coordinate)
    let repeatedFocus = try #require(model.focusRequest)
    #expect(repeatedFocus != initialFocus)
    model.focusOn(result.coordinate)
    #expect(model.focusRequest != repeatedFocus)
    #expect(model.focus == result.coordinate)
    #expect(model.start == start.coordinate)
    #expect(model.destination == destination.coordinate)
    #expect(model.startLabel == start.name)
    #expect(model.destinationLabel == destination.name)
    #expect(model.route?.path == route.path)
    #expect(model.route?.durationS == route.durationS)
    #expect(model.selectedRoutePoint == selectedPoint)
    #expect(model.operation == nil)
    model.dismissPlace()
    #expect(model.inspectedPlace == nil)
    #expect(model.route?.path == route.path)
    await engine.close()
  }

  @Test func destinationCanBeChosenBeforeStartAndBothPlaceNamesReachTheCalculatedRoute()
    async throws
  {
    defer { cleanup() }
    let model = try await readyModel()
    let destination = DemoPlace(
      coordinate: Coordinate(lat: 48.003, lon: 12.003), name: "Zielort", category: "Ort")
    model.chooseRoutePoint(.destination)
    #expect(model.selectedRoutePoint == .destination)
    model.inspect(destination.coordinate)
    #expect(model.start == nil && model.destination == nil)
    model.usePlace(destination, as: .destination)
    #expect(model.start == nil)
    #expect(model.destination == destination.coordinate)
    #expect(model.destinationLabel == destination.name)
    #expect(model.inspectedPlace == nil)
    #expect(model.selectedRoutePoint == .start)
    #expect(model.route == nil)
    #expect(model.operation == nil)
    #expect(!model.canCalculateRoute)

    let start = DemoPlace(
      coordinate: Coordinate(lat: 48.001, lon: 12.001), name: "Startort", category: "Ort")
    model.usePlace(start, as: .start)
    #expect(model.activity == .routing)
    await model.operation?.value
    #expect(model.start == start.coordinate)
    #expect(model.destination == destination.coordinate)
    #expect(model.startLabel == start.name)
    #expect(model.destinationLabel == destination.name)
    #expect(model.route?.path.count == 3)
    #expect(model.routeError == nil)
    #expect(model.canCalculateRoute)
    await model.engine?.close()
  }

  @Test func swappingEndpointsRecalculatesTheReverseRouteAndKeepsTheirNames() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let start = DemoPlace(
      coordinate: Coordinate(lat: 48.001, lon: 12.001), name: "Bahnhof", category: nil)
    let destination = DemoPlace(
      coordinate: Coordinate(lat: 48.003, lon: 12.003), name: "Rathaus", category: nil)
    model.usePlace(start, as: .start)
    model.usePlace(destination, as: .destination)
    await model.operation?.value
    let original = try #require(model.route)
    model.inspect(Coordinate(lat: 48.002, lon: 12.002))
    model.swapRoutePoints()
    #expect(model.activity == .routing)
    #expect(model.route == nil)
    #expect(model.inspectedPlace == nil)
    #expect(model.start == destination.coordinate)
    #expect(model.destination == start.coordinate)
    #expect(model.startLabel == destination.name)
    #expect(model.destinationLabel == start.name)
    await model.operation?.value
    let reversed = try #require(model.route)
    #expect(reversed.path == Array(original.path.reversed()))
    #expect(abs(reversed.distanceM - original.distanceM) < 0.001)
    #expect(model.routeError == nil)
    #expect(model.selectedRoutePoint == .destination)
    await model.engine?.close()
  }

  @Test func deletingAnInactiveRegionPreservesTheOpenEngineItsRouteAndSavedSelection() async throws
  {
    defer { cleanup() }
    let model = try await readyModel()
    let engine = try #require(model.engine)
    let active = try #require(model.activeDirectory)
    let inactive = root.appendingPathComponent("second")
    try FileManager.default.copyItem(at: active, to: inactive)
    await model.refreshInstalled()
    #expect(model.installed.count == 2)
    let selected = try #require(
      model.installed.first { $0.directory.lastPathComponent == "second" })
    model.select(Coordinate(lat: 48.001, lon: 12.001))
    model.select(Coordinate(lat: 48.003, lon: 12.003))
    await model.operation?.value
    let route = try #require(model.route)
    let savedRegion = try #require(defaults.string(forKey: "lastRegion"))
    let start = model.start
    let destination = model.destination

    model.deleteRegion(selected)
    #expect(model.activity == .deleting)
    #expect(!model.canCancel)
    let deletion = try #require(model.operation)
    model.cancel()
    #expect(!deletion.isCancelled)
    await deletion.value
    #expect(!FileManager.default.fileExists(atPath: inactive.path))
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(model.installed.map(\.directory) == [active])
    #expect(model.engine === engine)
    #expect(model.activeDirectory == active)
    #expect(defaults.string(forKey: "lastRegion") == savedRegion)
    #expect(model.start == start)
    #expect(model.destination == destination)
    #expect(model.route?.path == route.path)
    #expect(model.regionError == nil)
    #expect(!model.busy)
    #expect(!(try await engine.search("cafe")).isEmpty)
    await engine.close()
  }

  @Test func deletingTheActiveRegionClosesItsEngineAndClearsRestorationAndRouteState() async throws
  {
    defer { cleanup() }
    let model = try await readyModel()
    let engine = try #require(model.engine)
    let directory = try #require(model.activeDirectory)
    let region = try #require(model.installed.first { $0.directory == directory })
    model.select(Coordinate(lat: 48.001, lon: 12.001))
    model.select(Coordinate(lat: 48.003, lon: 12.003))
    await model.operation?.value
    #expect(model.route != nil)
    #expect(defaults.string(forKey: "lastRegion") != nil)
    model.inspect(Coordinate(lat: 48.002, lon: 12.002))
    model.query = "cafe"

    model.deleteRegion(region)
    await model.operation?.value
    #expect(model.engine == nil)
    #expect(model.activeDirectory == nil)
    #expect(model.installed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(defaults.string(forKey: "lastRegion") == nil)
    #expect(model.start == nil && model.destination == nil)
    #expect(model.startLabel == nil && model.destinationLabel == nil)
    #expect(model.route == nil)
    #expect(model.routeError == nil)
    #expect(model.inspectedPlace == nil)
    #expect(model.focus == nil)
    #expect(model.query.isEmpty)
    #expect(model.results.isEmpty)
    #expect(!model.searching)
    #expect(model.regionError == nil)
    #expect(model.selectedRoutePoint == .start)
    do {
      _ = try await engine.search("cafe")
      Issue.record("Deleted region's engine still accepted a query")
    } catch {}
  }

  private func pendingOptions(pbf: URL? = nil) throws -> ImportOptions {
    var options = ImportOptions(
      pbf: try pbf ?? fixture(), destination: root.appendingPathComponent("old-import"),
      name: "Fortsetzen")
    options.minZoom = 14
    options.maxZoom = 14
    options.maxImportNodes = 10
    options.tileMemoryBytes = 64 * 1024 * 1024
    let workspace = URL(fileURLWithPath: options.destination + ".pending")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data("legacy checkpoint".utf8).write(to: workspace.appendingPathComponent("source"))
    try Data("preserve".utf8).write(to: workspace.appendingPathComponent("sentinel"))
    defaults.set(try JSONEncoder().encode(options), forKey: "pendingImport")
    return options
  }

  @Test func newImportsNeverReplaceAnExistingResumeEntry() throws {
    defer { cleanup() }
    let original = try pendingOptions()
    let saved = defaults.data(forKey: "pendingImport")
    let model = DemoModel(root: root, defaults: defaults)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    model.importFile(try fixture())
    let region = try JSONDecoder().decode(
      GeofabrikRegion.self,
      from: Data(
        #"{"id":"test","name":"Test","pbfURL":"https://download.geofabrik.de/test.osm.pbf"}"#.utf8))
    model.download(region)
    #expect(model.operation == nil)
    #expect(!model.busy)
    #expect(model.pending?.destination == original.destination)
    #expect(defaults.data(forKey: "pendingImport") == saved)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(files))
  }

  @Test func legacyImportCanRestartWithTheSamePBFWithoutChangingItsOldWorkspace() async throws {
    defer { cleanup() }
    let original = try pendingOptions()
    let saved = defaults.data(forKey: "pendingImport")
    let model = DemoModel(root: root, defaults: defaults)
    model.resumePendingImport()
    await model.operation?.value
    #expect(model.engine == nil)
    #expect(model.pending?.destination == original.destination)
    #expect(defaults.data(forKey: "pendingImport") == saved)
    let failure = try #require(model.importFailure)
    #expect(failure.message.contains("Mit vorhandener PBF neu beginnen"))
    #expect(failure.details.contains("pending import belongs to another source"))
    #expect(failure.phase != nil)
    let restored = DemoModel(root: root, defaults: defaults)
    #expect(restored.importFailure?.details == failure.details)
    #expect(restored.importFailure?.phase == failure.phase)
    #expect(restored.lastImportPhase == model.lastImportPhase)
    model.restartPendingImport()
    #expect(model.importFailure == nil)
    #expect(defaults.data(forKey: "pendingImportFailure") == nil)
    await model.operation?.value
    #expect(model.pending == nil)
    #expect(model.lastImportPhase == nil)
    #expect(defaults.string(forKey: "pendingImportPhase") == nil)
    #expect(defaults.data(forKey: "pendingImportFailure") == nil)
    #expect(model.engine?.manifest.name == original.name)
    #expect(model.engine?.manifest.minZoom == original.minZoom)
    #expect(model.engine?.manifest.maxZoom == original.maxZoom)
    #expect(model.activeDirectory?.path != original.destination)
    let old = URL(fileURLWithPath: original.destination + ".pending")
    #expect(
      try String(contentsOf: old.appendingPathComponent("source"), encoding: .utf8)
        == "legacy checkpoint")
    #expect(
      try String(contentsOf: old.appendingPathComponent("sentinel"), encoding: .utf8) == "preserve")
    #expect(FileManager.default.fileExists(atPath: original.pbf))
    await model.engine?.close()
  }

  @Test func failedRestartPreservesImportLimitsAndRemovingEntryKeepsFiles() async throws {
    defer { cleanup() }
    let original = try pendingOptions(pbf: root.appendingPathComponent("missing.osm.pbf"))
    let model = DemoModel(root: root, defaults: defaults)
    model.restartPendingImport()
    await model.operation?.value
    let restarted = try #require(model.pending)
    #expect(restarted.destination != original.destination)
    #expect(restarted.pbf == original.pbf)
    #expect(restarted.minZoom == original.minZoom && restarted.maxZoom == original.maxZoom)
    #expect(restarted.maxImportNodes == original.maxImportNodes)
    #expect(restarted.tileMemoryBytes == original.tileMemoryBytes)
    let encoded = try #require(defaults.data(forKey: "pendingImport"))
    let stored = try JSONDecoder().decode(ImportOptions.self, from: encoded)
    #expect(stored.pbf == "missing.osm.pbf")
    #expect(stored.destination == URL(fileURLWithPath: restarted.destination).lastPathComponent)
    let (gate, release) = AsyncStream<Void>.makeStream()
    model.run(.opening, status: "Opening") { _ in
      for await _ in gate { break }
      try Task.checkCancellation()
    }
    let task = try #require(model.operation)
    model.removePendingImportFromList()
    model.restartPendingImport()
    #expect(model.pending?.destination == restarted.destination)
    model.cancel()
    release.finish()
    await task.value
    model.removePendingImportFromList()
    #expect(model.pending == nil)
    #expect(defaults.data(forKey: "pendingImport") == nil)
    #expect(model.importFailure == nil && model.lastImportPhase == nil)
    #expect(defaults.data(forKey: "pendingImportFailure") == nil)
    #expect(defaults.string(forKey: "pendingImportPhase") == nil)
    let sentinel = URL(fileURLWithPath: original.destination + ".pending/sentinel")
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
  }

  @Test func failedMapImportRestoresItsReasonAndPhaseWithoutLosingTechnicalDetails() async throws {
    defer { cleanup() }
    _ = try pendingOptions()
    let model = DemoModel(root: root, defaults: defaults)
    let details =
      "tinytiles: publish generated tiles: insufficient memory for tile stream import: need 396901152 bytes, limit 268435456 bytes"
    model.run(.importing, status: "Import") { id in
      let phase = model.beginPhase(id, status: "Offline-Karte wird aufbereitet …")
      model.receiveProgress(phase, fraction: 0.6, status: "Kartendateien werden geprüft …")
      throw OSMminiError.native(details)
    }
    await model.operation?.value
    let failure = try #require(model.importFailure)
    #expect(failure.message.contains("Speicherbudget"))
    #expect(failure.details == details)
    #expect(failure.phase == "Kartendateien werden geprüft …")
    #expect(model.status == failure.message)
    let restored = DemoModel(root: root, defaults: defaults)
    #expect(restored.importFailure?.message == failure.message)
    #expect(restored.importFailure?.details == details)
    #expect(restored.importFailure?.phase == failure.phase)
    #expect(restored.pending?.destination == model.pending?.destination)
  }

  @Test func interruptedImportRemembersItsLastPhaseAndRejectsLateProgress() async throws {
    defer { cleanup() }
    _ = try pendingOptions()
    let model = DemoModel(root: root, defaults: defaults)
    let (events, event) = AsyncStream<UUID>.makeStream()
    let (gate, release) = AsyncStream<Void>.makeStream()
    model.run(.importing, status: "Import") { id in
      let phase = model.beginPhase(id, status: "Straßennetz wird aufbereitet …")
      model.receiveProgress(phase, fraction: 0.35, status: "Lokale Suche wird aufbereitet …")
      event.yield(phase)
      for await _ in gate { break }
      try Task.checkCancellation()
    }
    let task = try #require(model.operation)
    var iterator = events.makeAsyncIterator()
    let phase = try #require(await iterator.next())
    // A new process has no live task, but can still explain the saved import.
    let restored = DemoModel(root: root, defaults: defaults)
    #expect(restored.lastImportPhase == "Lokale Suche wird aufbereitet …")
    #expect(restored.importFailure == nil)
    model.cancel()
    model.receiveProgress(phase, fraction: 1, status: "Zu spät")
    release.finish()
    await task.value
    #expect(model.lastImportPhase == restored.lastImportPhase)
    #expect(model.importFailure == nil)
    #expect(defaults.string(forKey: "pendingImportPhase") == restored.lastImportPhase)
    event.finish()
  }

  @Test func legacyImportResumesAfterItsAppContainerMovesWithoutDownloadingAgain() async throws {
    defer { cleanup() }
    let before = root.appendingPathComponent("Before/Library/Application Support/OSMminiDemo")
    let after = root.appendingPathComponent("After/Library/Application Support/OSMminiDemo")
    let source = before.appendingPathComponent("downloads/cached-niederbayern-latest.osm.pbf")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture(), to: source)
    let region = before.appendingPathComponent("Niederbayern-test")
    var options = ImportOptions(pbf: source, destination: region, name: "Niederbayern")
    options.minZoom = 14
    options.maxZoom = 14
    options.maxImportNodes = 10
    options.tileMemoryBytes = 64 * 1024 * 1024
    try await OfflineEngine.importPBF(options)
    // A fully prepared workspace models interruption immediately before its
    // final publication, retaining real graph/search checkpoints and signatures.
    let workspace = URL(fileURLWithPath: region.path + ".pending")
    try FileManager.default.moveItem(at: region, to: workspace)
    let graph = workspace.appendingPathComponent("graph.bin")
    let graphDate = try graph.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    defaults.set(try JSONEncoder().encode(options), forKey: "pendingImport")
    try FileManager.default.createDirectory(
      at: after.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: before, to: after)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let model = DemoModel(root: after, defaults: defaults)
    #expect(
      model.pending?.pbf
        == after.appendingPathComponent("downloads/cached-niederbayern-latest.osm.pbf").path)
    #expect(
      model.pending?.destination == after.appendingPathComponent(region.lastPathComponent).path)
    model.resumePendingImport()
    await model.operation?.value
    #expect(model.importFailure == nil)
    #expect(model.pending == nil)
    #expect(model.engine?.manifest.name == "Niederbayern")
    let opened = try #require(model.activeDirectory)
    #expect(
      try opened.appendingPathComponent("graph.bin").resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate == graphDate)
    #expect(defaults.string(forKey: "lastRegion") == region.lastPathComponent)
    #expect(
      FileManager.default.fileExists(
        atPath: after.appendingPathComponent("downloads/cached-niederbayern-latest.osm.pbf").path))
    await model.engine?.close()
  }

  @Test func relativePendingPathsSurviveMovingTheRootAndExternalSourcesStayAbsolute() throws {
    defer { cleanup() }
    let before = root.appendingPathComponent("Before")
    let after = root.appendingPathComponent("After")
    var options = ImportOptions(
      pbf: before.appendingPathComponent("downloads/region.osm.pbf"),
      destination: before.appendingPathComponent("region"), name: "Test")
    defaults.set(try DemoStorage.savedImport(options, in: before), forKey: "pendingImport")
    let restored = DemoModel(root: after, defaults: defaults)
    #expect(restored.pending?.pbf == after.appendingPathComponent("downloads/region.osm.pbf").path)
    #expect(restored.pending?.destination == after.appendingPathComponent("region").path)
    options.pbf = try fixture().path
    let external = try DemoStorage.restoredImport(options, in: after)
    #expect(external.pbf == options.pbf)
    #expect(external.destination == after.appendingPathComponent("region").path)
    #expect(throws: (any Error).self) {
      try DemoStorage.restoredPath("../other-app/file.osm.pbf", in: after)
    }
  }

  @Test func lastRegionReopensAfterContainerMoveWithLegacyOrRelativePreferences() async throws {
    defer { cleanup() }
    let model = try await readyModel()
    let original = try #require(model.activeDirectory)
    await model.engine?.close()
    let movedRoot = root.appendingPathComponent("After/Library/Application Support/OSMminiDemo")
    try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
    let movedRegion = movedRoot.appendingPathComponent(original.lastPathComponent)
    try FileManager.default.moveItem(at: original, to: movedRegion)
    for saved in [
      original.lastPathComponent,
      "/var/mobile/Containers/Data/Application/old-id/Library/Application Support/OSMminiDemo/\(original.lastPathComponent)",
    ] {
      defaults.set(saved, forKey: "lastRegion")
      let reopened = DemoModel(root: movedRoot, defaults: defaults)
      await reopened.start(arguments: ["demo", "--offline"])
      #expect(reopened.engine?.manifest.name == "Testregion")
      #expect(reopened.activeDirectory == movedRegion.resolvingSymlinksInPath().standardizedFileURL)
      #expect(!reopened.catalogLoaded)
      #expect(defaults.string(forKey: "lastRegion") == original.lastPathComponent)
      await reopened.engine?.close()
    }
  }
}
