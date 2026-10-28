import Foundation
import OSMmini
import Observation

/// Imported files are copied into app storage; the originals remain untouched.
@MainActor @Observable final class DemoMapLayers {
  struct Entry: Identifiable, Equatable, Sendable {
    let id: UUID
    let document: KMLDocument
    var isVisible: Bool
    var name: String { document.name }
  }

  struct UnreadableEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
  }

  nonisolated static let maximumLayers = 8
  private nonisolated static let maximumFileBytes = 10 * 1024 * 1024
  private nonisolated static let maximumManifestBytes = 64 * 1024

  private struct Record: Codable, Sendable {
    let id: UUID
    let name: String
    let isVisible: Bool
  }

  private struct Snapshot: Codable, Sendable {
    let version: Int
    let entries: [Record]
  }

  private struct Restoration: Sendable {
    let entries: [Entry]
    let unreadableRecords: [Record]
    let error: String?
    let canPersist: Bool
  }

  private(set) var entries: [Entry] = []
  private(set) var error: String?
  private(set) var isLoading = false
  private(set) var isImporting = false
  var visibleDocuments: [KMLDocument] { entries.filter(\.isVisible).map(\.document) }
  var unreadableEntries: [UnreadableEntry] {
    unreadableRecords.map { UnreadableEntry(id: $0.id, name: $0.name) }
  }

  private let directory: URL
  private var restored = false
  private var canPersist = true
  private var unreadableRecords: [Record] = []
  private var restoration: Task<Restoration, Never>?

  init(root: URL) {
    directory = root.standardizedFileURL.resolvingSymlinksInPath()
      .appendingPathComponent("map-layers", isDirectory: true)
  }

  /// Sharing the task makes repeated window startup safe without blocking UI.
  func restore() async {
    guard !restored else { return }
    if restoration == nil {
      isLoading = true
      let directory = directory
      restoration = Task.detached(priority: .userInitiated) {
        Self.readStoredLayers(in: directory)
      }
    }
    guard let restoration else { return }
    let result = await restoration.value
    guard !restored else { return }
    entries = result.entries
    unreadableRecords = result.unreadableRecords
    error = result.error
    canPersist = result.canPersist
    restored = true
    isLoading = false
    self.restoration = nil
  }

  @discardableResult func importFile(_ source: URL) async throws -> UUID {
    try Task.checkCancellation()
    await restore()
    try Task.checkCancellation()
    guard canPersist else { throw LayerError.unreadableStorage }
    guard !isImporting else { throw LayerError.importInProgress }
    guard entries.count + unreadableRecords.count < Self.maximumLayers else {
      throw LayerError.tooManyLayers
    }
    guard source.isFileURL, source.pathExtension.lowercased() == "kml" else {
      throw LayerError.unsupportedFormat
    }
    isImporting = true
    defer { isImporting = false }
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    let id = UUID()
    let directory = directory
    let target = Self.fileURL(for: id, in: directory)
    let worker = Task.detached(priority: .userInitiated) {
      let data = try Self.readRegularFile(source, maximumBytes: Self.maximumFileBytes)
      let fallback = String(source.deletingPathExtension().lastPathComponent.prefix(200))
      let document = try KMLDocument(data: data, name: fallback)
      try Task.checkCancellation()
      try Self.ensureDirectory(directory, create: true)
      try Self.checkRegularFile(target, allowMissing: true)
      try data.write(to: target, options: .atomic)
      return document
    }
    do {
      let document = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      try Task.checkCancellation()
      let updated = entries + [Entry(id: id, document: document, isVisible: true)]
      try persist(updated, unreadableRecords: unreadableRecords)
      entries = updated
      return id
    } catch {
      // Only this operation's generated filename can be removed on failure.
      if (try? Self.ensureDirectory(directory, create: false)) != nil {
        try? FileManager.default.removeItem(at: target)
      }
      throw error
    }
  }

  func toggleVisible(id: UUID) throws {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    var updated = entries
    updated[index].isVisible.toggle()
    try persist(updated, unreadableRecords: unreadableRecords)
    entries = updated
  }

  func remove(id: UUID) throws {
    guard entries.contains(where: { $0.id == id }) else { return }
    try Self.ensureDirectory(directory, create: false)
    let target = Self.fileURL(for: id, in: directory)
    try Self.checkRegularFile(target, allowMissing: true)
    let updated = entries.filter { $0.id != id }
    try persist(updated, unreadableRecords: unreadableRecords)
    entries = updated
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
  }

  /// Forget an unavailable layer without deleting any of its existing files.
  func forgetUnreadable(id: UUID) throws {
    guard unreadableRecords.contains(where: { $0.id == id }) else { return }
    let updated = unreadableRecords.filter { $0.id != id }
    try persist(entries, unreadableRecords: updated)
    unreadableRecords = updated
    error = Self.unreadableMessage(count: updated.count)
  }

  func dismissError() { error = nil }

  private func persist(_ entries: [Entry], unreadableRecords: [Record]) throws {
    guard restored, canPersist else { throw LayerError.unreadableStorage }
    try Self.ensureDirectory(directory, create: true)
    let manifest = directory.appendingPathComponent("manifest.json")
    try Self.checkRegularFile(manifest, allowMissing: true)
    let snapshot = Snapshot(
      version: 1,
      entries: entries.map { Record(id: $0.id, name: $0.name, isVisible: $0.isVisible) }
        + unreadableRecords)
    let data = try JSONEncoder().encode(snapshot)
    try data.write(to: manifest, options: .atomic)
  }

  private nonisolated static func readStoredLayers(in directory: URL) -> Restoration {
    do {
      guard FileManager.default.fileExists(atPath: directory.path) else {
        return Restoration(entries: [], unreadableRecords: [], error: nil, canPersist: true)
      }
      try ensureDirectory(directory, create: false)
      let manifest = directory.appendingPathComponent("manifest.json")
      guard FileManager.default.fileExists(atPath: manifest.path) else {
        return Restoration(entries: [], unreadableRecords: [], error: nil, canPersist: true)
      }
      let data = try readRegularFile(manifest, maximumBytes: maximumManifestBytes)
      let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
      guard snapshot.version == 1, snapshot.entries.count <= maximumLayers,
        Set(snapshot.entries.map(\.id)).count == snapshot.entries.count
      else { throw LayerError.unreadableStorage }
      var entries: [Entry] = []
      var unreadableRecords: [Record] = []
      for record in snapshot.entries {
        try Task.checkCancellation()
        let source = fileURL(for: record.id, in: directory)
        guard let data = try? readRegularFile(source, maximumBytes: maximumFileBytes),
          let document = try? KMLDocument(data: data, name: record.name)
        else {
          unreadableRecords.append(record)
          continue
        }
        entries.append(Entry(id: record.id, document: document, isVisible: record.isVisible))
      }
      return Restoration(
        entries: entries,
        unreadableRecords: unreadableRecords,
        error: unreadableMessage(count: unreadableRecords.count),
        canPersist: true)
    } catch {
      return Restoration(
        entries: [], unreadableRecords: [], error: LayerError.unreadableStorage.localizedDescription,
        canPersist: false)
    }
  }

  private nonisolated static func unreadableMessage(count: Int) -> String? {
    count == 0 ? nil :
      "\(count) gespeicherte Kartenebenen konnten nicht geladen werden. Ihre Dateien bleiben erhalten."
  }

  private nonisolated static func fileURL(for id: UUID, in directory: URL) -> URL {
    directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("kml")
  }

  private nonisolated static func ensureDirectory(_ directory: URL, create: Bool) throws {
    guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path
    else { throw LayerError.invalidFile }
    if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path
    else { throw LayerError.invalidFile }
  }

  private nonisolated static func checkRegularFile(_ url: URL, allowMissing: Bool = false) throws {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw LayerError.invalidFile
      }
    } catch let error as NSError {
      if allowMissing, error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
        return
      }
      throw error
    }
  }

  private nonisolated static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
    try Task.checkCancellation()
    try checkRegularFile(url)
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, size > 0, size <= maximumBytes else {
      throw LayerError.fileTooLarge
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(size)
    while let chunk = try handle.read(upToCount: min(256 * 1024, maximumBytes - data.count + 1)),
      !chunk.isEmpty
    {
      try Task.checkCancellation()
      guard chunk.count <= maximumBytes - data.count else { throw LayerError.fileTooLarge }
      data.append(chunk)
    }
    return data
  }

  private enum LayerError: LocalizedError {
    case unsupportedFormat, tooManyLayers, importInProgress, unreadableStorage, invalidFile,
      fileTooLarge

    var errorDescription: String? {
      switch self {
      case .unsupportedFormat: "Bitte eine KML-Datei auswählen."
      case .tooManyLayers: "Du kannst bis zu acht Kartenebenen laden. Entferne zuerst eine Ebene."
      case .importInProgress: "Eine Kartenebene wird bereits geladen."
      case .unreadableStorage:
        "Gespeicherte Kartenebenen konnten nicht gelesen werden. Die vorhandenen Dateien bleiben erhalten."
      case .invalidFile: "Die Datei oder der Speicherort ist keine reguläre lokale Datei."
      case .fileTooLarge: "KML-Dateien dürfen bis zu 10 MiB groß sein und müssen Daten enthalten."
      }
    }
  }

}
