import CryptoKit
import Foundation

public struct OSMExtractRegion: Codable, Sendable, Identifiable, Hashable {
  public let id: String, name: String
  public let parent: String?
  public let pbfURL: URL

  public init(id: String, name: String, parent: String?, pbfURL: URL) {
    self.id = id
    self.name = name
    self.parent = parent
    self.pbfURL = pbfURL
  }
}

/// Compatibility names for clients of the original Geofabrik-only API.
public typealias GeofabrikRegion = OSMExtractRegion
public typealias Geofabrik = OSMExtracts

/// Loads a provider's public machine-readable catalog and retains it offline.
/// Each instance owns one source; downloads and redirects stay with that source.
public actor OSMExtracts {
  public static let catalogURL = OSMExtractSource.geofabrik.catalogURL
  public nonisolated let source: OSMExtractSource
  private let directory: URL
  private let catalogSession: URLSession
  private let downloadConfiguration: @Sendable () -> URLSessionConfiguration
  private var catalog: [OSMExtractRegion]?
  private var catalogResult: Result<[OSMExtractRegion], any Error>?
  private var catalogRevision: UInt64 = 0
  private enum TransferKey: Hashable, Sendable {
    case catalog
    case pbf(String)
  }
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }
  private var active: Set<TransferKey> = []
  private var waiters: [TransferKey: [Waiter]] = [:]
  private var downloadProgress: [TransferKey: GeofabrikDownloadProgress] = [:]

  public init(directory: URL, source: OSMExtractSource = .geofabrik) {
    self.source = source
    self.directory = directory
    catalogSession = .shared
    downloadConfiguration = { .default }
  }
  // Inject sessions without process-wide URLProtocol registration in tests.
  init(
    directory: URL, source: OSMExtractSource = .geofabrik, catalogSession: URLSession,
    downloadConfiguration: @escaping @Sendable () -> URLSessionConfiguration
  ) {
    self.directory = directory
    self.source = source
    self.catalogSession = catalogSession
    self.downloadConfiguration = downloadConfiguration
  }
  private struct Catalog: Decodable {
    struct Feature: Decodable {
      struct Properties: Decodable {
        let id: String, name: String
        let parent: String?
        let urls: [String: String]
      }
      let properties: Properties
    }
    let features: [Feature]
  }
  public func regions(refresh: Bool = false) async throws -> [OSMExtractRegion] {
    try Task.checkCancellation()
    if !refresh, let catalog { return catalog }
    let previousRevision = catalogRevision
    try await acquire(.catalog)
    defer { release(.catalog) }
    try Task.checkCancellation()
    if !refresh, let catalog { return catalog }
    // A refresh already in progress also satisfies callers that arrived while
    // it was running, including errors. Cancellation permits the next caller
    // to retry instead of propagating another caller's cancellation.
    if catalogRevision != previousRevision, let catalogResult {
      return try catalogResult.get()
    }
    let directory = directory
    let session = catalogSession
    let source = source
    let loading = Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let cache = directory.appendingPathComponent(source.cacheFilename)
      let maximumCatalogBytes = 64 * 1024 * 1024
      if !refresh, let size = try? cache.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size > 0, size <= maximumCatalogBytes,
        let cached = try? Data(contentsOf: cache, options: .mappedIfSafe),
        let regions = try? Self.decodeCatalog(cached, source: source)
      {
        try Task.checkCancellation()
        return regions
      }
      var request = URLRequest(url: source.catalogURL)
      request.setValue("OSMmini-Apple/1.0 (offline regional maps)", forHTTPHeaderField: "User-Agent")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (downloaded, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        downloaded.count <= maximumCatalogBytes
      else { throw OSMminiError.native("\(source.displayName) catalog unavailable or too large") }
      let regions = try Self.decodeCatalog(downloaded, source: source)
      try Task.checkCancellation()
      try downloaded.write(to: cache, options: .atomic)
      return regions
    }
    do {
      let regions = try await withTaskCancellationHandler {
        let regions = try await loading.value
        try Task.checkCancellation()
        return regions
      } onCancel: {
        loading.cancel()
      }
      catalog = regions
      catalogResult = .success(regions)
      catalogRevision &+= 1
      return regions
    } catch {
      if Task.isCancelled { throw CancellationError() }
      catalogResult = .failure(error)
      catalogRevision &+= 1
      throw error
    }
  }
  public static func decodeCatalog(_ data: Data) throws -> [OSMExtractRegion] {
    try decodeCatalog(data, source: .geofabrik)
  }

  public static func decodeCatalog(_ data: Data, source: OSMExtractSource) throws -> [OSMExtractRegion] {
    let regions: [OSMExtractRegion]
    switch source {
    case .geofabrik:
      regions = try JSONDecoder().decode(Catalog.self, from: data).features.compactMap { feature in
        let p = feature.properties
        guard let raw = p.urls["pbf"], let url = URL(string: raw), source.permitsDownload(url)
        else { return nil }
        return OSMExtractRegion(id: p.id, name: p.name, parent: p.parent, pbfURL: url)
      }
    case .openStreetMapFrance:
      regions = try decodeFranceCatalog(data)
    }
    guard !regions.isEmpty else {
      throw OSMminiError.native("\(source.displayName) catalog contains no available regions")
    }
    return regions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private static func decodeFranceCatalog(_ data: Data) throws -> [OSMExtractRegion] {
    struct Tree: Decodable {
      struct Entry: Decodable {
        let path: String
        let type: String
        let mode: String?
      }
      let truncated: Bool
      let tree: [Entry]
    }
    let catalog = try JSONDecoder().decode(Tree.self, from: data)
    guard !catalog.truncated else {
      throw OSMminiError.native("OpenStreetMap France catalog is incomplete")
    }
    // The provider's init_extracts_link.sh maps these polygons to the same
    // relative paths under /extracts/, followed by -latest.osm.pbf.
    let prefix = "osc_modif/polygons/"
    var seen: Set<String> = []
    return catalog.tree.compactMap { entry in
      guard entry.type == "blob", entry.mode == nil || entry.mode == "100644"
        || entry.mode == "100755",
        entry.path.hasPrefix(prefix), entry.path.hasSuffix(".poly")
      else { return nil }
      let path = String(entry.path.dropFirst(prefix.count).dropLast(".poly".count))
      guard OSMExtractSource.validRegionPath(path), seen.insert(path).inserted,
        let url = URL(string: "https://download.openstreetmap.fr/extracts/\(path)-latest.osm.pbf"),
        OSMExtractSource.openStreetMapFrance.permitsDownload(url)
      else { return nil }
      let components = path.split(separator: "/")
      let name = String(components.last!)
        .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        .capitalized(with: Locale(identifier: "en_US_POSIX"))
      return OSMExtractRegion(
        id: path, name: name,
        parent: components.count > 1 ? components.dropLast().joined(separator: "/") : nil,
        pbfURL: url)
    }
  }
  public func download(
    _ region: OSMExtractRegion, maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
    progress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> URL {
    try Task.checkCancellation()
    guard source.permitsDownload(region.pbfURL), maximumBytes > 0 else {
      throw OSMminiError.native("Invalid \(source.displayName) download")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Different regions can have the same basename (e.g. Georgia in Europe
    // and the US). Key the cache by the entire validated source URL.
    let filename = Self.cacheFilename(region.pbfURL)
    let target = directory.appendingPathComponent(filename)
    let key = TransferKey.pbf(filename)
    let hub = downloadProgress[key] ?? GeofabrikDownloadProgress()
    downloadProgress[key] = hub
    let subscriber = hub.add(progress)
    defer {
      hub.remove(subscriber)
      if hub.count == 0, downloadProgress[key] === hub { downloadProgress.removeValue(forKey: key) }
    }
    return try await withTaskCancellationHandler {
      try await download(
        region, target: target, key: key, maximumBytes: maximumBytes, progress: hub)
    } onCancel: {
      hub.remove(subscriber)
    }
  }
  private func download(
    _ region: OSMExtractRegion, target: URL, key: TransferKey, maximumBytes: Int64,
    progress: GeofabrikDownloadProgress
  ) async throws -> URL {
    try await acquire(key)
    defer { release(key) }
    try Task.checkCancellation()
    if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) {
      let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        size > 0, size <= maximumBytes
      else { throw OSMminiError.native("Cached PBF exceeds the size limit or is invalid") }
      progress.send(size, size)
      return target
    }
    let transfer = DownloadTransfer(
      url: region.pbfURL, target: target, maximumBytes: maximumBytes,
      providerName: source.displayName, permitsURL: source.permitsDownload,
      progress: { progress.send($0, $1) },
      configuration: downloadConfiguration())
    let downloaded = try await withTaskCancellationHandler {
      try await transfer.run()
    } onCancel: {
      transfer.cancel()
    }
    try Task.checkCancellation()
    return downloaded
  }

  // Serialize only identical resources. Waiting callers can cancel without
  // cancelling the active transfer; after it finishes they reuse the cache.
  // Different region downloads remain independent and concurrent.
  private func acquire(_ key: TransferKey) async throws {
    try Task.checkCancellation()
    if active.insert(key).inserted { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if active.insert(key).inserted {
          continuation.resume()
        } else {
          waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(key, id: id) }
    }
  }
  private func cancelWaiter(_ key: TransferKey, id: UUID) {
    guard var queued = waiters[key], let index = queued.firstIndex(where: { $0.id == id }) else {
      return
    }
    let cancelled = queued.remove(at: index)
    if queued.isEmpty { waiters.removeValue(forKey: key) } else { waiters[key] = queued }
    cancelled.continuation.resume(throwing: CancellationError())
  }
  private func release(_ key: TransferKey) {
    if var queued = waiters[key], !queued.isEmpty {
      let next = queued.removeFirst()
      if queued.isEmpty { waiters.removeValue(forKey: key) } else { waiters[key] = queued }
      next.continuation.resume()
    } else {
      active.remove(key)
    }
  }
  static func cacheFilename(_ url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined() + "-" + url.lastPathComponent
  }
}

/// Shared progress for one resource, already throttled by DownloadTransfer.
/// Callbacks run outside all locks. A busy subscriber keeps only the newest
/// pending update; revision checks prevent an older replay from following it.
final class GeofabrikDownloadProgress: @unchecked Sendable {
  private struct Update {
    let revision: UInt64
    let bytes: Int64, total: Int64
  }
  private final class Subscriber: @unchecked Sendable {
    let callback: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var pending: Update?
    private var active = true
    private var delivering = false
    init(_ callback: (@Sendable (Int64, Int64) -> Void)?) { self.callback = callback }
    func enqueue(_ update: Update) {
      lock.lock()
      guard active, update.revision > revision else {
        lock.unlock()
        return
      }
      revision = update.revision
      pending = update
      if delivering {
        lock.unlock()
        return
      }
      delivering = true
      lock.unlock()
      while true {
        lock.lock()
        guard active, let next = pending else {
          delivering = false
          lock.unlock()
          return
        }
        pending = nil
        lock.unlock()
        callback?(next.bytes, next.total)
      }
    }
    func deactivate() {
      lock.lock()
      active = false
      pending = nil
      lock.unlock()
    }
  }
  private let lock = NSLock()
  private var subscribers: [UUID: Subscriber] = [:]
  private var latest: Update?
  private var revision: UInt64 = 0

  func add(_ callback: (@Sendable (Int64, Int64) -> Void)?) -> UUID {
    let id = UUID()
    let subscriber = Subscriber(callback)
    lock.lock()
    subscribers[id] = subscriber
    let latest = latest
    lock.unlock()
    if let latest { subscriber.enqueue(latest) }
    return id
  }
  func remove(_ id: UUID) {
    lock.lock()
    let subscriber = subscribers.removeValue(forKey: id)
    lock.unlock()
    subscriber?.deactivate()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return subscribers.count
  }
  func send(_ bytes: Int64, _ total: Int64) {
    lock.lock()
    if latest?.bytes == bytes, latest?.total == total {
      lock.unlock()
      return
    }
    revision &+= 1
    let update = Update(revision: revision, bytes: bytes, total: total)
    latest = update
    let recipients = Array(subscribers.values)
    lock.unlock()
    for subscriber in recipients { subscriber.enqueue(update) }
  }
}

struct DownloadProgressThrottle {
  private var lastBytes: Int64?
  private var lastExpected: Int64?
  private var lastTime: TimeInterval = 0
  mutating func shouldReport(bytes: Int64, expected: Int64, now: TimeInterval) -> Bool {
    guard bytes != lastBytes || expected != lastExpected else { return false }
    guard
      lastBytes == nil || expected != lastExpected || now - lastTime >= 0.1
        || (expected > 0 && bytes >= expected)
    else { return false }
    lastBytes = bytes
    lastExpected = expected
    lastTime = now
    return true
  }
}

final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let url: URL, target: URL, maximumBytes: Int64
  let progress: (@Sendable (Int64, Int64) -> Void)?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, any Error>?
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var cancelled = false
  private var failure: String?
  private var resumePending = false
  private var pendingResult: Result<URL, any Error>?
  private var downloadResult: Result<URL, any Error>?
  private var throttle = DownloadProgressThrottle()
  private let configuration: URLSessionConfiguration
  private let providerName: String
  private let permitsURL: @Sendable (URL) -> Bool
  private var resumeURL: URL { target.appendingPathExtension("resume") }
  init(
    url: URL, target: URL, maximumBytes: Int64, providerName: String,
    permitsURL: @escaping @Sendable (URL) -> Bool,
    progress: (@Sendable (Int64, Int64) -> Void)?,
    configuration: URLSessionConfiguration
  ) {
    self.url = url
    self.providerName = providerName
    self.permitsURL = permitsURL
    self.target = target
    self.maximumBytes = maximumBytes
    self.progress = progress
    self.configuration = configuration
  }
  func run() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      self.continuation = continuation
      configuration.httpAdditionalHeaders = [
        "User-Agent": "OSMmini-Apple/1.0 (offline regional maps)"
      ]
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      let task: URLSessionDownloadTask
      if let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
        task = session.downloadTask(withResumeData: data)
      } else {
        task = session.downloadTask(with: url)
      }
      self.task = task
      let stop = cancelled
      lock.unlock()
      task.resume()
      if stop { cancel() }
    }
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let task = task
    let requestResume = task != nil && !resumePending && continuation != nil
    if requestResume { resumePending = true }
    lock.unlock()
    guard requestResume else { return }
    task?.cancel(byProducingResumeData: { [self] data in
      if let data { try? data.write(to: resumeURL, options: .atomic) }
      lock.lock()
      resumePending = false
      let result = pendingResult
      pendingResult = nil
      lock.unlock()
      if let result { finish(result) }
    })
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
      lock.lock()
      failure =
        "Download exceeds the configured size limit. Choose a smaller region or increase maximumBytes."
      lock.unlock()
      downloadTask.cancel()
      return
    }
    reportProgress(totalBytesWritten, expected: totalBytesExpectedToWrite)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(request.url.map(permitsURL) == true ? request : nil)
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      guard let response = downloadTask.response as? HTTPURLResponse,
        (200...299).contains(response.statusCode), response.url.map(permitsURL) == true
      else { throw OSMminiError.native("\(providerName) download returned an HTTP error") }
      let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
      let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      guard bytes > 0, bytes <= maximumBytes else {
        throw OSMminiError.native("Invalid PBF download size")
      }
      lock.lock()
      let stopped = cancelled
      lock.unlock()
      if stopped { throw CancellationError() }
      // A URLSession temporary file can be on another filesystem. Copy/move
      // into the destination directory first, then publish by a local rename.
      let staging = target.appendingPathExtension("download-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: staging) }
      try FileManager.default.moveItem(at: location, to: staging)
      lock.lock()
      let cancelledDuringMove = cancelled
      lock.unlock()
      if cancelledDuringMove { throw CancellationError() }
      try FileManager.default.moveItem(at: staging, to: target)
      reportProgress(bytes, expected: bytes)
      lock.lock()
      downloadResult = .success(target)
      lock.unlock()
    } catch {
      lock.lock()
      downloadResult = .failure(error)
      lock.unlock()
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    if let error,
      let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    {
      try? data.write(to: resumeURL, options: .atomic)
    }
    lock.lock()
    let failure = failure
    let stopped = cancelled
    let downloaded = downloadResult
    lock.unlock()
    // didFinishDownloadingTo precedes this terminal delegate callback. Waiting
    // until here also prevents a late error's resume write from racing the
    // next transfer, even when cancellation overlaps file publication.
    if let error {
      finish(.failure(failure.map(OSMminiError.native) ?? (stopped ? CancellationError() : error)))
    } else {
      finish(downloaded ?? .failure(OSMminiError.invalidResponse))
    }
  }
  private func reportProgress(_ bytes: Int64, expected: Int64) {
    if progress != nil,
      throttle.shouldReport(
        bytes: bytes, expected: expected, now: ProcessInfo.processInfo.systemUptime)
    {
      progress?(bytes, expected)
    }
  }
  private func finish(_ result: Result<URL, any Error>) {
    lock.lock()
    // Do not release the per-URL turn until resume data has reached disk;
    // otherwise a new transfer could start before the old callback writes it.
    if resumePending {
      pendingResult = result
      lock.unlock()
      return
    }
    let continuation = continuation
    self.continuation = nil
    let session = session
    self.session = nil
    self.task = nil
    lock.unlock()
    if case .success = result { try? FileManager.default.removeItem(at: resumeURL) }
    continuation?.resume(with: result)
    session?.finishTasksAndInvalidate()
  }
}
