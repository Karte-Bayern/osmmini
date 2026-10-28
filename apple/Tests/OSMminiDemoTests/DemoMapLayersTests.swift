import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

@MainActor struct DemoMapLayersTests {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DemoMapLayersTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func source(in directory: URL, filename: String = "Wanderung.kml") throws -> URL {
    let source = directory.appendingPathComponent(filename)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
      <Placemark><name>Aussichtspunkt</name><Point><coordinates>12.5,48.5,0</coordinates></Point></Placemark>
      </Document></kml>
      """
    try Data(xml.utf8).write(to: source)
    return source
  }

  @Test func importingCopiesLocalKMLAndRestoresVisibilityAndTheOriginalName() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try source(in: root)
    let originalData = try Data(contentsOf: original)
    let store = DemoMapLayers(root: root)
    #expect(store.entries.isEmpty && !store.isLoading)
    let id = try await store.importFile(original)
    #expect(store.entries.count == 1)
    #expect(store.entries.first?.id == id)
    #expect(store.entries.first?.name == "Wanderung")
    #expect(store.visibleDocuments.count == 1)
    #expect(store.entries.first?.document.coordinates == [Coordinate(lat: 48.5, lon: 12.5)])
    try store.toggleVisible(id: id)
    #expect(store.visibleDocuments.isEmpty)
    let reopened = DemoMapLayers(root: root)
    async let first: Void = reopened.restore()
    async let second: Void = reopened.restore()
    await first
    await second
    #expect(!reopened.isLoading && reopened.error == nil)
    #expect(reopened.entries.map(\.id) == [id])
    #expect(reopened.entries.first?.name == "Wanderung")
    #expect(reopened.visibleDocuments.isEmpty)
    #expect(try Data(contentsOf: original) == originalData)
    try reopened.remove(id: id)
    #expect(reopened.entries.isEmpty)
    #expect(FileManager.default.fileExists(atPath: original.path))
    let removed = DemoMapLayers(root: root)
    await removed.restore()
    #expect(removed.entries.isEmpty && removed.error == nil)
  }

  @Test func malformedAndCancelledImportsPreserveExistingLayersAndManifest() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try source(in: root)
    let store = DemoMapLayers(root: root)
    let id = try await store.importFile(original)
    let manifest = root.appendingPathComponent("map-layers/manifest.json")
    let snapshot = try Data(contentsOf: manifest)
    let invalid = root.appendingPathComponent("broken.kml")
    try Data("<kml><Placemark>".utf8).write(to: invalid)
    await #expect(throws: (any Error).self) { try await store.importFile(invalid) }
    let task = Task { try await store.importFile(original) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(store.entries.map(\.id) == [id])
    #expect(!store.isImporting)
    #expect(try Data(contentsOf: manifest) == snapshot)
    let names = try FileManager.default.contentsOfDirectory(atPath: manifest.deletingLastPathComponent().path)
    #expect(names.count == 2)
  }

  @Test func layerLimitAndInputFileValidationDoNotReplaceLoadedData() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try source(in: root, filename: "Test.KML")
    let link = root.appendingPathComponent("link.kml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    let store = DemoMapLayers(root: root)
    await #expect(throws: (any Error).self) { try await store.importFile(link) }
    let unsupported = try source(in: root, filename: "Test.kmz")
    await #expect(throws: (any Error).self) { try await store.importFile(unsupported) }
    let large = root.appendingPathComponent("large.kml")
    #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
    let file = try FileHandle(forWritingTo: large)
    try file.truncate(atOffset: UInt64(10 * 1024 * 1024 + 1))
    try file.close()
    await #expect(throws: (any Error).self) { try await store.importFile(large) }
    #expect(store.entries.isEmpty)
    for _ in 0..<DemoMapLayers.maximumLayers { try await store.importFile(original) }
    let ids = store.entries.map(\.id)
    await #expect(throws: (any Error).self) { try await store.importFile(original) }
    #expect(store.entries.map(\.id) == ids)
    let unreadable = root.appendingPathComponent(
      "map-layers/\(ids[0].uuidString.lowercased()).kml")
    try Data("invalid".utf8).write(to: unreadable)
    let reopened = DemoMapLayers(root: root)
    await reopened.restore()
    #expect(reopened.entries.count == DemoMapLayers.maximumLayers - 1)
    await #expect(throws: (any Error).self) { try await reopened.importFile(original) }
  }

  @Test func restorationSkipsCorruptFilesWithoutChangingTheSavedManifest() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try source(in: root)
    let store = DemoMapLayers(root: root)
    let first = try await store.importFile(original)
    let second = try await store.importFile(original)
    let layerDirectory = root.appendingPathComponent("map-layers")
    let manifest = layerDirectory.appendingPathComponent("manifest.json")
    let snapshot = try Data(contentsOf: manifest)
    let corrupted = layerDirectory.appendingPathComponent(first.uuidString.lowercased() + ".kml")
    try Data("invalid".utf8).write(to: corrupted)
    let reopened = DemoMapLayers(root: root)
    await reopened.restore()
    #expect(reopened.entries.map(\.id) == [second])
    #expect(reopened.error != nil)
    #expect(FileManager.default.fileExists(atPath: corrupted.path))
    #expect(try Data(contentsOf: manifest) == snapshot)
    try reopened.toggleVisible(id: second)
    let third = try await reopened.importFile(original)
    // References to unreadable files survive edits to healthy layers, so a
    // repaired file can reappear with its original ID and visibility later.
    try Data(contentsOf: original).write(to: corrupted)
    let repaired = DemoMapLayers(root: root)
    await repaired.restore()
    #expect(repaired.error == nil)
    #expect(Set(repaired.entries.map(\.id)) == Set([first, second, third]))
    #expect(repaired.entries.first(where: { $0.id == first })?.isVisible == true)
    #expect(repaired.entries.first(where: { $0.id == second })?.isVisible == false)
  }

  @Test func replacedStorageSymlinkCannotWriteOrRemoveFilesOutsideAppStorage() async throws {
    let root = try directory()
    let outside = try directory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let original = try source(in: root)
    let store = DemoMapLayers(root: root)
    let id = try await store.importFile(original)
    let layerDirectory = root.appendingPathComponent("map-layers")
    try FileManager.default.moveItem(at: layerDirectory, to: root.appendingPathComponent("kept-layers"))
    try FileManager.default.createSymbolicLink(at: layerDirectory, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try store.toggleVisible(id: id) }
    #expect(throws: (any Error).self) { try store.remove(id: id) }
    await #expect(throws: (any Error).self) { try await store.importFile(original) }
    #expect(store.entries.map(\.id) == [id])
    #expect(store.entries.first?.isVisible == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func forgettingAnUnreadableLayerFreesASlotAndPreservesFilesAndOtherRecords() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try source(in: root)
    let originalData = try Data(contentsOf: original)
    let store = DemoMapLayers(root: root)
    for _ in 0..<DemoMapLayers.maximumLayers { try await store.importFile(original) }
    let ids = store.entries.map(\.id)
    let layerDirectory = root.appendingPathComponent("map-layers")
    let manifest = layerDirectory.appendingPathComponent("manifest.json")
    let snapshot = try Data(contentsOf: manifest)
    let healthy = try #require(ids.last)
    let missing = ids[ids.count - 2]
    let corruptedData = Data("invalid KML".utf8)
    func file(_ id: UUID) -> URL {
      layerDirectory.appendingPathComponent(id.uuidString.lowercased() + ".kml")
    }
    for id in ids.dropLast(2) { try corruptedData.write(to: file(id)) }
    try FileManager.default.removeItem(at: file(missing))

    let reopened = DemoMapLayers(root: root)
    await reopened.restore()
    #expect(reopened.entries.map(\.id) == [healthy])
    #expect(reopened.unreadableEntries.map(\.id) == Array(ids.dropLast()))
    #expect(reopened.unreadableEntries.allSatisfy { $0.name == "Wanderung" })
    await #expect(throws: (any Error).self) { try await reopened.importFile(original) }
    #expect(try Data(contentsOf: manifest) == snapshot)

    let forgotten = try #require(reopened.unreadableEntries.first?.id)
    let before = reopened.unreadableEntries
    let keptManifest = layerDirectory.appendingPathComponent("kept-manifest.json")
    try FileManager.default.moveItem(at: manifest, to: keptManifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try reopened.forgetUnreadable(id: forgotten) }
    #expect(reopened.unreadableEntries == before)
    #expect(reopened.entries.map(\.id) == [healthy])
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.moveItem(at: keptManifest, to: manifest)

    try reopened.forgetUnreadable(id: forgotten)
    #expect(reopened.unreadableEntries.map(\.id) == Array(ids.dropFirst().dropLast()))
    #expect(reopened.entries.map(\.id) == [healthy])
    #expect(try Data(contentsOf: file(forgotten)) == corruptedData)
    #expect(!FileManager.default.fileExists(atPath: file(missing).path))
    let replacement = try await reopened.importFile(original)
    #expect(reopened.entries.map(\.id) == [healthy, replacement])
    #expect(try Data(contentsOf: original) == originalData)
    #expect(try Data(contentsOf: file(healthy)) == originalData)

    let restored = DemoMapLayers(root: root)
    await restored.restore()
    #expect(restored.entries.map(\.id) == [healthy, replacement])
    #expect(restored.unreadableEntries == reopened.unreadableEntries)
    #expect(restored.error != nil)
    #expect(try Data(contentsOf: file(forgotten)) == corruptedData)
    for id in ids.dropFirst().dropLast(2) {
      #expect(try Data(contentsOf: file(id)) == corruptedData)
    }
  }
}
