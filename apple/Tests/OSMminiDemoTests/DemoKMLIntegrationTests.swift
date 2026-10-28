import Foundation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

@MainActor struct DemoKMLIntegrationTests {
  private let root: URL
  private let defaults: UserDefaults
  private let suite: String

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DemoKMLIntegrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    suite = "DemoKMLIntegrationTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func cleanup() {
    try? FileManager.default.removeItem(at: root)
    defaults.removePersistentDomain(forName: suite)
  }

  private func source() throws -> URL {
    let file = root.appendingPathComponent("Ausflug.kml")
    let xml = """
      <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Ausflug</name>
      <Placemark><name>Aussichtspunkt</name><Point><coordinates>12.5,48.5,0</coordinates></Point></Placemark>
      </Document></kml>
      """
    try Data(xml.utf8).write(to: file)
    return file
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
      try #require(clock.now < deadline, "KML import did not finish")
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func importedModel() async throws -> DemoModel {
    let model = DemoModel(root: root, defaults: defaults)
    await model.start(arguments: ["--offline"])
    model.importMapLayer(try source())
    try await waitUntil { model.layerFocusRequest != nil || model.layerImportError != nil }
    try #require(model.layerImportError == nil)
    return model
  }

  @Test func aKMLFileCanBeImportedFocusedAndInspectedWithoutAnOfflineRegion() async throws {
    defer { cleanup() }
    let model = try await importedModel()
    #expect(model.engine == nil && model.installed.isEmpty)
    let document = try #require(model.layers.visibleDocuments.first)
    #expect(document.name == "Ausflug")
    #expect(model.layerFocus == document)
    #expect(model.layerFocusRequest != nil)
    let coordinate = Coordinate(lat: 48.5, lon: 12.5)
    let prepared = try PreparedMapOverlay(document)
    let selection = try #require(
      prepared.select(
        at: CGPoint(x: 200, y: 150), center: coordinate, displayZoom: 14.5,
        size: CGSize(width: 400, height: 300)))
    #expect(selection.feature?.name == "Aussichtspunkt")
    model.inspect(selection)
    let place = try #require(model.inspectedPlace)
    #expect(place.name == "Aussichtspunkt")
    #expect(place.coordinate == coordinate)
    #expect(model.focus == coordinate && model.focusRequest != nil)
    model.usePlace(place, as: .start)
    model.usePlace(place, as: .destination)
    model.select(coordinate)
    #expect(model.start == nil && model.destination == nil)
    #expect(model.route == nil && model.operation == nil && !model.busy)
    #expect(model.inspectedPlace == place)
  }

  @Test func focusingAHiddenLayerShowsItAgainAndPersistsThatChoice() async throws {
    defer { cleanup() }
    let model = try await importedModel()
    let id = try #require(model.layers.entries.first?.id)
    try model.layers.toggleVisible(id: id)
    #expect(model.layers.visibleDocuments.isEmpty)
    let reopened = DemoModel(root: root, defaults: defaults)
    await reopened.start(arguments: ["--offline"])
    #expect(reopened.engine == nil && reopened.layers.visibleDocuments.isEmpty)
    #expect(reopened.layers.entries.first?.id == id)
    reopened.focusMapLayer(id: id)
    let request = try #require(reopened.layerFocusRequest)
    #expect(reopened.layers.entries.first?.isVisible == true)
    #expect(reopened.layerFocus?.name == "Ausflug")
    #expect(reopened.focus == nil && reopened.inspectedPlace == nil)
    reopened.focusMapLayer(id: id)
    #expect(reopened.layerFocusRequest != request)
    let restored = DemoModel(root: root, defaults: defaults)
    await restored.start(arguments: ["--offline"])
    #expect(restored.layers.entries.first?.id == id)
    #expect(restored.layers.entries.first?.isVisible == true)
    #expect(restored.engine == nil && restored.route == nil)
  }

  @Test func aRejectedKMLImportKeepsTheDisplayedLayerAndItsFocus() async throws {
    defer { cleanup() }
    let model = try await importedModel()
    let ids = model.layers.entries.map(\.id)
    let request = model.layerFocusRequest
    let document = model.layerFocus
    let invalid = root.appendingPathComponent("broken.kml")
    try Data("<kml><Placemark>".utf8).write(to: invalid)
    model.importMapLayer(invalid)
    try await waitUntil { model.layerImportError != nil }
    #expect(model.layers.entries.map(\.id) == ids)
    #expect(model.layerFocusRequest == request && model.layerFocus == document)
    #expect(model.layers.visibleDocuments.count == 1)
    #expect(model.engine == nil && model.pending == nil && model.operation == nil)
    model.dismissLayerImportError()
    #expect(model.layerImportError == nil)
  }

  @Test func aDocumentOpenedBeforeStartupIsReframedAfterStartupFinishes() async throws {
    defer { cleanup() }
    let model = DemoModel(root: root, defaults: defaults)
    model.importMapLayer(try source())
    try await waitUntil { model.layerFocusRequest != nil || model.layerImportError != nil }
    try #require(model.layerImportError == nil)
    let firstRequest = try #require(model.layerFocusRequest)
    let document = model.layerFocus
    await model.start(arguments: ["--offline"])
    #expect(model.layerFocus == document)
    #expect(model.layerFocusRequest != nil && model.layerFocusRequest != firstRequest)
    #expect(model.layers.visibleDocuments == [document].compactMap { $0 })
  }

  @Test func savedPlacesCanBeRevisitedOnAKMLMapWithoutEnablingRouting() async throws {
    defer { cleanup() }
    let model = try await importedModel()
    let document = try #require(model.layers.visibleDocuments.first)
    let feature = try #require(document.features.first)
    let place = DemoPlace(
      coordinate: Coordinate(lat: 48.5, lon: 12.5), name: "Aussichtspunkt",
      category: nil, kind: "kml", sourceIdentity: "kml/\(feature.id.uuidString)")
    #expect(model.places.save(place))
    let mapPoint = DemoPlace(
      coordinate: Coordinate(lat: 48.51, lon: 12.51), name: "Treffpunkt", category: nil)
    #expect(model.places.save(mapPoint))

    let reopened = DemoModel(root: root, defaults: defaults)
    await reopened.start(arguments: ["--offline"])
    let saved = try #require(reopened.places.saved.first?.place)
    #expect(reopened.canDisplayPlaces)
    #expect(reopened.canSelectPlace(saved, target: nil))
    #expect(!reopened.canSelectPlace(saved, target: .start))
    #expect(!reopened.canSelectPlace(saved, target: .destination))
    let savedPoint = try #require(reopened.places.saved.first(where: { $0.place.kind == nil })?.place)
    #expect(reopened.canSelectPlace(savedPoint, target: nil))
    #expect(!reopened.canSelectPlace(savedPoint, target: .start))
    #expect(!reopened.canSelectPlace(savedPoint, target: .destination))

    reopened.inspect(saved, minimumZoom: 14)
    #expect(reopened.inspectedPlace == saved)
    #expect(reopened.focus == saved.coordinate && reopened.focusRequest != nil)
    reopened.usePlace(saved, as: .start)
    reopened.usePlace(saved, as: .destination)
    #expect(reopened.start == nil && reopened.destination == nil && reopened.operation == nil)
    reopened.inspect(savedPoint, minimumZoom: 14)
    #expect(reopened.inspectedPlace == savedPoint && reopened.focus == savedPoint.coordinate)
    reopened.usePlace(savedPoint, as: .start)
    reopened.usePlace(savedPoint, as: .destination)
    #expect(reopened.start == nil && reopened.destination == nil && reopened.operation == nil)

    let id = try #require(reopened.layers.entries.first?.id)
    try reopened.layers.toggleVisible(id: id)
    #expect(!reopened.canDisplayPlaces)
    #expect(!reopened.canSelectPlace(saved, target: nil))
    #expect(!reopened.canSelectPlace(savedPoint, target: nil))
  }

  @Test func aSavedKMLPlaceOutsideTheBasemapCanBeDisplayedButCannotBecomeARouteEndpoint() async throws {
    defer { cleanup() }
    let model = try await importedModel()
    let feature = try #require(model.layers.visibleDocuments.first?.features.first)
    let place = DemoPlace(
      coordinate: Coordinate(lat: 48.5, lon: 12.5), name: "Aussichtspunkt",
      category: nil, kind: "kml", sourceIdentity: "kml/\(feature.id.uuidString)")
    #expect(model.places.save(place))
    let fixture = try #require(
      Bundle.module.url(forResource: "region", withExtension: "osm.pbf", subdirectory: "Fixtures"))
    model.importFile(fixture)
    await model.operation?.value
    _ = try #require(model.engine)
    let saved = try #require(model.places.saved.first?.place)
    #expect(!model.contains(saved.coordinate))
    #expect(model.canSelectPlace(saved, target: nil))
    #expect(!model.canSelectPlace(saved, target: .start))
    #expect(!model.canSelectPlace(saved, target: .destination))

    model.inspect(saved, minimumZoom: 14)
    #expect(model.inspectedPlace == saved && model.focus == saved.coordinate)
    model.usePlace(saved, as: .start)
    model.usePlace(saved, as: .destination)
    #expect(model.start == nil && model.destination == nil && model.operation == nil)
    let ordinary = DemoPlace(
      coordinate: saved.coordinate, name: "OSM-Ort", category: nil,
      kind: "node", sourceIdentity: "node/42")
    #expect(!model.canSelectPlace(ordinary, target: nil))
    await model.engine?.close()
  }
}
