import CryptoKit
import Foundation
import OSMmini

struct DemoStoredRegion: Identifiable, Sendable, Equatable {
  let directory: URL
  let name: String
  let nodes: Int
  /// Logical size of the region's regular files, including its manifest.
  let byteCount: Int64
  let importedAt: Date?
  var id: URL { directory }
}

enum DemoRegionStorage {
  static func regions(in root: URL) throws -> [DemoStoredRegion] {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    return try manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { directory in
      guard let manifest = try? publishedManifest(directory, in: root) else { return nil }
      return DemoStoredRegion(
        directory: directory.standardizedFileURL,
        name: manifest.region.name,
        nodes: manifest.region.nodes,
        byteCount: try byteCount(in: directory),
        importedAt: manifest.importedAt)
    }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame
        ? $0.directory.path < $1.directory.path : order == .orderedAscending
    }
  }

  /// The caller must close any engine using this region before removing it.
  /// Source downloads and unfinished imports are deliberately outside this API.
  static func removeRegion(_ directory: URL, in root: URL) throws {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    _ = try publishedManifest(directory, in: root)
    try FileManager.default.removeItem(at: directory)
  }

  /// Call from a worker, as with the other storage operations. Hashing retains
  /// at most one MiB of PBF data and checks cancellation between reads.
  static func matchingRegion(
    for source: URL, in root: URL, minZoom: Int, maxZoom: Int
  ) throws -> URL? {
    try Task.checkCancellation()
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let candidates = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.path < $1.path }.compactMap { directory -> (URL, String)? in
      try Task.checkCancellation()
      guard let manifest = try? publishedManifest(directory, in: root),
        manifest.region.minZoom == minZoom, manifest.region.maxZoom == maxZoom
      else { return nil }
      return (directory.standardizedFileURL, manifest.region.sourceSHA256)
    }
    try Task.checkCancellation()
    guard !candidates.isEmpty else { return nil }
    let digest = try sourceSHA256(source)
    try Task.checkCancellation()
    return candidates.first { $0.1 == digest }?.0
  }

  /// Completed PBFs and URLSession resume data can be removed independently
  /// of installed maps. The caller must prevent active or pending imports.
  static func downloadBytes(in root: URL) throws -> Int64 {
    try Task.checkCancellation()
    var count: Int64 = 0
    for file in try managedDownloads(in: root) {
      try Task.checkCancellation()
      let (sum, overflow) = count.addingReportingOverflow(file.size)
      guard !overflow else { throw CocoaError(.fileReadTooLarge) }
      count = sum
    }
    return count
  }

  static func removeDownloads(in root: URL) throws {
    try Task.checkCancellation()
    for file in try managedDownloads(in: root) {
      try Task.checkCancellation()
      // Recheck before deletion: never turn a stale scan into recursive
      // removal of a directory or a symbolic link.
      let values = try file.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      try FileManager.default.removeItem(at: file.url)
    }
  }

  private static func sourceSHA256(_ source: URL) throws -> String {
    try Task.checkCancellation()
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw OSMminiError.native("Die PBF-Quelldatei ist keine reguläre Datei.")
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    var hash = SHA256()
    while true {
      try Task.checkCancellation()
      let consumed = try autoreleasepool {
        guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
        hash.update(data: data)
        return true
      }
      if !consumed { break }
    }
    try Task.checkCancellation()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func managedDownloads(in root: URL) throws -> [(url: URL, size: Int64)] {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let directory = root.appendingPathComponent("downloads", isDirectory: true)
    let values: URLResourceValues
    do {
      values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw OSMminiError.native("Das Downloadverzeichnis gehört nicht zum lokalen App-Speicher.")
    }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).compactMap { file in
      try Task.checkCancellation()
      let name = file.lastPathComponent
      // An interrupted URLSession download has only <name>.pbf.resume;
      // it need not have a completed PBF next to it yet.
      guard name.hasSuffix(".pbf") || name.hasSuffix(".pbf.resume") else { return nil }
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size >= 0
      else { return nil }
      return (file, Int64(size))
    }
  }

  private struct Manifest: Decodable {
    let region: RegionManifest
    let importedAt: Date?

    private enum CodingKeys: String, CodingKey { case createdAt = "created_at" }

    init(from decoder: any Decoder) throws {
      region = try RegionManifest(from: decoder)
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let createdAt = try? values.decode(String.self, forKey: .createdAt)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let createdAt {
        if let date = formatter.date(from: createdAt) {
          importedAt = date
        } else {
          formatter.formatOptions = [.withInternetDateTime]
          importedAt = formatter.date(from: createdAt)
        }
      } else {
        importedAt = nil
      }
    }
  }

  private static func publishedManifest(_ directory: URL, in root: URL) throws -> Manifest {
    let directory = directory.standardizedFileURL
    let name = directory.lastPathComponent
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard directory.deletingLastPathComponent().resolvingSymlinksInPath() == root,
      directory.resolvingSymlinksInPath() == root.appendingPathComponent(name),
      name != "downloads", !name.hasSuffix(".pending"),
      values.isDirectory == true, values.isSymbolicLink != true
    else { throw invalidRegion() }
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let manifestValues = try manifestURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
      let size = manifestValues.fileSize, size > 0, size <= 1024 * 1024
    else { throw invalidRegion() }
    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
  }

  private static func byteCount(in directory: URL) throws -> Int64 {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    var directories = [directory]
    var count: Int64 = 0
    while let current = directories.popLast() {
      try Task.checkCancellation()
      for file in try FileManager.default.contentsOfDirectory(
        at: current, includingPropertiesForKeys: Array(keys))
      {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { continue }
        if values.isDirectory == true {
          directories.append(file)
        } else if values.isRegularFile == true, let size = values.fileSize {
          let (sum, overflow) = count.addingReportingOverflow(Int64(size))
          guard size >= 0, !overflow else { throw CocoaError(.fileReadTooLarge) }
          count = sum
        }
      }
    }
    return count
  }

  private static func invalidRegion() -> OSMminiError {
    .native("Diese Datei gehört nicht zu den installierten Offline-Regionen der App.")
  }
}
