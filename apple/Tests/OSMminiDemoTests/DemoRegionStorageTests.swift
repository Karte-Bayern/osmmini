import CryptoKit
import Foundation
import Testing

@testable import OSMminiDemoCLI

struct DemoRegionStorageTests {
  private func workspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @discardableResult private func makeRegion(
    _ directory: URL, name: String = "Testregion", createdAt: String? = nil,
    sourceSHA256: String = "abc", minZoom: Int = 5, maxZoom: Int = 14
  ) throws -> Int64 {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var manifest: [String: Any] = [
      "format": 1, "name": name, "nodes": 3, "edges": 4,
      "bounds": ["min_lat": 48, "max_lat": 49, "min_lon": 12, "max_lon": 13],
      "min_zoom": minZoom, "max_zoom": maxZoom, "source_sha256": sourceSHA256,
    ]
    if let createdAt { manifest["created_at"] = createdAt }
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("manifest.json"))
    return Int64(data.count)
  }

  @Test func scanCountsNestedAndHiddenFilesWithoutFollowingSymlinks() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    let region = root.appendingPathComponent("region")
    let manifestBytes = try makeRegion(region, createdAt: "2026-10-19T08:15:30.123456789Z")
    let nested = region.appendingPathComponent("map")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 19).write(to: nested.appendingPathComponent("tiles"))
    try Data(repeating: 2, count: 7).write(to: region.appendingPathComponent(".metadata"))
    let outsideFile = external.appendingPathComponent("large")
    try Data(repeating: 3, count: 1000).write(to: outsideFile)
    try FileManager.default.createSymbolicLink(
      at: region.appendingPathComponent("external-file"), withDestinationURL: outsideFile)
    try FileManager.default.createSymbolicLink(
      at: region.appendingPathComponent("external-directory"), withDestinationURL: external)

    let stored = try #require(DemoRegionStorage.regions(in: root).first)
    #expect(stored.directory == region.resolvingSymlinksInPath())
    #expect(stored.id == stored.directory)
    #expect(stored.name == "Testregion")
    #expect(stored.nodes == 3)
    #expect(stored.byteCount == manifestBytes + 26)
    let expected = Date(timeIntervalSince1970: 1_792_397_730.1234567)
    #expect(abs(try #require(stored.importedAt).timeIntervalSince(expected)) < 0.001)
  }

  @Test func scanSortsManifestNamesAndRejectsUnpublishedInvalidOrLinkedManifests() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    try makeRegion(root.appendingPathComponent("c"), name: "Region 10")
    try makeRegion(root.appendingPathComponent("b"), name: "Region 2", createdAt: "invalid")
    try makeRegion(
      root.appendingPathComponent("a"), name: "Region 2", createdAt: "2026-10-19T08:15:30Z")
    try makeRegion(root.appendingPathComponent("unfinished.pending"))
    try makeRegion(root.appendingPathComponent("downloads"))
    try makeRegion(external)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked-region"), withDestinationURL: external)
    let broken = root.appendingPathComponent("broken")
    try makeRegion(broken)
    try Data("{}".utf8).write(to: broken.appendingPathComponent("manifest.json"))
    let large = root.appendingPathComponent("large")
    try makeRegion(large)
    try Data(repeating: 32, count: 1024 * 1024 + 1).write(
      to: large.appendingPathComponent("manifest.json"))
    let linkedManifest = root.appendingPathComponent("linked-manifest")
    try FileManager.default.createDirectory(at: linkedManifest, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedManifest.appendingPathComponent("manifest.json"),
      withDestinationURL: external.appendingPathComponent("manifest.json"))

    let stored = try DemoRegionStorage.regions(in: root)
    #expect(stored.map(\.directory.lastPathComponent) == ["a", "b", "c"])
    #expect(stored.map(\.name) == ["Region 2", "Region 2", "Region 10"])
    #expect(stored[0].importedAt != nil)
    #expect(stored[1].importedAt == nil)
    #expect(stored[2].importedAt == nil)
  }

  @Test func removingPublishedRegionPreservesNeighboursAndLinkedExternalData() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    let region = root.appendingPathComponent("remove")
    let neighbour = root.appendingPathComponent("keep")
    let pending = root.appendingPathComponent("unfinished.pending")
    try makeRegion(region)
    try makeRegion(neighbour)
    try makeRegion(pending)
    let sentinel = external.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
      at: region.appendingPathComponent("external"), withDestinationURL: external)

    try DemoRegionStorage.removeRegion(region, in: root)
    #expect(!FileManager.default.fileExists(atPath: region.path))
    #expect(FileManager.default.fileExists(atPath: neighbour.path))
    #expect(FileManager.default.fileExists(atPath: pending.path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
  }

  @Test func deletionRejectsRootExternalNestedDownloadsPendingAndSymlinkTargets() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    try makeRegion(root)
    try makeRegion(external)
    let published = root.appendingPathComponent("published")
    let nested = published.appendingPathComponent("nested")
    let downloads = root.appendingPathComponent("downloads")
    let pending = root.appendingPathComponent("unfinished.pending")
    try makeRegion(published)
    try makeRegion(nested)
    try makeRegion(downloads)
    try makeRegion(pending)
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    let internalLink = root.appendingPathComponent("linked-published")
    try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: published)
    let unpublished = root.appendingPathComponent("unpublished")
    try FileManager.default.createDirectory(at: unpublished, withIntermediateDirectories: true)
    let broken = root.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: broken.appendingPathComponent("manifest.json"))

    for candidate in [
      root, external, nested, downloads, pending, link, internalLink, unpublished, broken,
    ] {
      #expect(throws: (any Error).self) {
        try DemoRegionStorage.removeRegion(candidate, in: root)
      }
      #expect(FileManager.default.fileExists(atPath: candidate.path))
    }
    #expect(FileManager.default.fileExists(atPath: published.path))
  }

  @Test func matchingRegionUsesFullSourceContentAndZoomInsteadOfNames() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.osm.pbf")
    var content = Data(repeating: 42, count: 3 * 1024 * 1024 + 17)
    try content.write(to: source)
    let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let sameNameDifferentSource = root.appendingPathComponent("other-source")
    let otherNameSameSource = root.appendingPathComponent("same-source")
    try makeRegion(sameNameDifferentSource, name: "Niederbayern", sourceSHA256: "different")
    try makeRegion(otherNameSameSource, name: "Andere Bezeichnung", sourceSHA256: digest)
    #expect(
      try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 5, maxZoom: 14)
        == otherNameSameSource.resolvingSymlinksInPath())
    #expect(
      try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 6, maxZoom: 14) == nil)
    #expect(
      try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 5, maxZoom: 13) == nil)

    // Changing only the final chunk must defeat a duplicate match; retaining
    // or hashing only an initial prefix would incorrectly reuse the region.
    content[content.count - 1] = 43
    try content.write(to: source)
    #expect(
      try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 5, maxZoom: 14) == nil)
  }

  @Test func matchingRegionIgnoresUnpublishedAndLinkedCandidates() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    let source = root.appendingPathComponent("source.osm.pbf")
    let data = Data("same PBF content".utf8)
    try data.write(to: source)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try makeRegion(root.appendingPathComponent("unfinished.pending"), sourceSHA256: digest)
    try makeRegion(root.appendingPathComponent("downloads"), sourceSHA256: digest)
    try makeRegion(external, sourceSHA256: digest)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked"), withDestinationURL: external)
    #expect(
      try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 5, maxZoom: 14) == nil)
    let actual = root.appendingPathComponent("actual")
    try makeRegion(actual, sourceSHA256: digest)
    #expect(
      try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 5, maxZoom: 14)
        == actual.resolvingSymlinksInPath())
  }

  @Test func downloadCleanupCountsOnlyManagedFilesAndPreservesCatalogAndUnrelatedData() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let managed = [
      "region.osm.pbf": 11, "region.osm.pbf.resume": 7, "unfinished.osm.pbf.resume": 13,
    ]
    for (name, count) in managed {
      try Data(repeating: 1, count: count).write(to: downloads.appendingPathComponent(name))
    }
    let preserved = [
      "geofabrik-index.json", "notes.txt", "unrelated.resume", "image.jpg",
      "region.osm.pbf.download-staging", ".hidden.pbf",
    ]
    for name in preserved {
      try Data("keep".utf8).write(to: downloads.appendingPathComponent(name))
    }
    let nested = downloads.appendingPathComponent("nested.pbf")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("keep nested".utf8).write(to: nested.appendingPathComponent("child.osm.pbf"))
    let sentinel = external.appendingPathComponent("outside.osm.pbf")
    try Data("keep external".utf8).write(to: sentinel)
    let linkedFile = downloads.appendingPathComponent("linked.osm.pbf")
    let linkedDirectory = downloads.appendingPathComponent("linked-directory.pbf")
    try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: sentinel)
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: external)
    let source = root.appendingPathComponent("source-external-to-downloads.osm.pbf")
    try Data("keep source".utf8).write(to: source)
    let region = root.appendingPathComponent("installed")
    try makeRegion(region)

    #expect(try DemoRegionStorage.downloadBytes(in: root) == 31)
    try DemoRegionStorage.removeDownloads(in: root)
    #expect(try DemoRegionStorage.downloadBytes(in: root) == 0)
    for name in managed.keys {
      #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent(name).path))
    }
    for name in preserved {
      #expect(
        try String(contentsOf: downloads.appendingPathComponent(name), encoding: .utf8) == "keep")
    }
    #expect(
      FileManager.default.fileExists(atPath: nested.appendingPathComponent("child.osm.pbf").path))
    #expect(FileManager.default.fileExists(atPath: linkedFile.path))
    #expect(FileManager.default.fileExists(atPath: linkedDirectory.path))
    #expect(
      FileManager.default.fileExists(atPath: region.appendingPathComponent("manifest.json").path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep external")
    #expect(try String(contentsOf: source, encoding: .utf8) == "keep source")
    try DemoRegionStorage.removeDownloads(in: root)
  }

  @Test func downloadHelpersHandleMissingDirectoriesAndRejectLinkedDownloadRoots() throws {
    let root = try workspace()
    let external = try workspace()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }
    #expect(try DemoRegionStorage.downloadBytes(in: root) == 0)
    try DemoRegionStorage.removeDownloads(in: root)
    let sentinel = external.appendingPathComponent("outside.osm.pbf")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("downloads"), withDestinationURL: external)
    #expect(throws: (any Error).self) { try DemoRegionStorage.downloadBytes(in: root) }
    #expect(throws: (any Error).self) { try DemoRegionStorage.removeDownloads(in: root) }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
  }

  @Test func cancelledStorageWorkDoesNotHashOrRemoveDownloads() async throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.osm.pbf")
    try Data("source".utf8).write(to: source)
    try makeRegion(root.appendingPathComponent("region"))
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let cached = downloads.appendingPathComponent("cached.osm.pbf")
    try Data("keep".utf8).write(to: cached)
    for operation in 0..<3 {
      let (gate, release) = AsyncStream<Void>.makeStream()
      let task = Task.detached {
        for await _ in gate { break }
        switch operation {
        case 0:
          _ = try DemoRegionStorage.matchingRegion(for: source, in: root, minZoom: 5, maxZoom: 14)
        case 1: _ = try DemoRegionStorage.downloadBytes(in: root)
        default: try DemoRegionStorage.removeDownloads(in: root)
        }
      }
      task.cancel()
      release.finish()
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    #expect(try String(contentsOf: cached, encoding: .utf8) == "keep")
  }
}
