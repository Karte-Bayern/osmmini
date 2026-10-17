import CryptoKit
import Foundation

public struct GeofabrikRegion: Codable, Sendable, Identifiable, Hashable {
  public let id: String, name: String
  public let parent: String?
  public let pbfURL: URL
}

/// Uses Geofabrik's public machine-readable catalog, without scraping HTML or
/// hardcoding today's region list. The cached catalog is available offline.
public actor Geofabrik {
  public static let catalogURL = URL(string: "https://download.geofabrik.de/index-v1.json")!
  private let directory: URL
  public init(directory: URL) { self.directory = directory }
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
  public func regions(refresh: Bool = false) async throws -> [GeofabrikRegion] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = directory.appendingPathComponent("geofabrik-index.json")
    var data: Data
    if !refresh, let cached = try? Data(contentsOf: cache) {
      data = cached
    } else {
      let (downloaded, response) = try await URLSession.shared.data(from: Self.catalogURL)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        downloaded.count <= 64 * 1024 * 1024
      else { throw OSMminiError.native("Geofabrik catalog unavailable or too large") }
      _ = try Self.decodeCatalog(downloaded)
      try downloaded.write(to: cache, options: .atomic)
      data = downloaded
    }
    return try Self.decodeCatalog(data)
  }
  public static func decodeCatalog(_ data: Data) throws -> [GeofabrikRegion] {
    try JSONDecoder().decode(Catalog.self, from: data).features.compactMap { feature in
      let p = feature.properties
      guard let raw = p.urls["pbf"], let url = URL(string: raw), permitted(url) else { return nil }
      return GeofabrikRegion(id: p.id, name: p.name, parent: p.parent, pbfURL: url)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func download(
    _ region: GeofabrikRegion, maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
    progress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> URL {
    guard Self.permitted(region.pbfURL), maximumBytes > 0 else {
      throw OSMminiError.native("Invalid Geofabrik download")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Different regions can have the same basename (e.g. Georgia in Europe
    // and the US). Key the cache by the entire validated source URL.
    let filename = Self.cacheFilename(region.pbfURL)
    let target = directory.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: target.path) { return target }
    let transfer = DownloadTransfer(
      url: region.pbfURL, target: target, maximumBytes: maximumBytes, progress: progress)
    return try await withTaskCancellationHandler {
      try await transfer.run()
    } onCancel: {
      transfer.cancel()
    }
  }
  fileprivate static func permitted(_ url: URL) -> Bool {
    url.scheme == "https" && url.host == "download.geofabrik.de" && url.user == nil
      && url.password == nil && url.path.hasSuffix(".osm.pbf")
  }
  static func cacheFilename(_ url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined() + "-" + url.lastPathComponent
  }
}

private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let url: URL, target: URL, maximumBytes: Int64
  let progress: (@Sendable (Int64, Int64) -> Void)?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, any Error>?
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var cancelled = false
  private var failure: String?
  private var resumeURL: URL { target.appendingPathExtension("resume") }
  init(url: URL, target: URL, maximumBytes: Int64, progress: (@Sendable (Int64, Int64) -> Void)?) {
    self.url = url
    self.target = target
    self.maximumBytes = maximumBytes
    self.progress = progress
  }
  func run() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      self.continuation = continuation
      let configuration = URLSessionConfiguration.default
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
    lock.unlock()
    task?.cancel(byProducingResumeData: { [resumeURL] data in
      if let data { try? data.write(to: resumeURL, options: .atomic) }
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
    progress?(totalBytesWritten, totalBytesExpectedToWrite)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(request.url.map(Geofabrik.permitted) == true ? request : nil)
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      guard let response = downloadTask.response as? HTTPURLResponse,
        (200...299).contains(response.statusCode)
      else { throw OSMminiError.native("Geofabrik download returned an HTTP error") }
      let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
      let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      guard bytes > 0, bytes <= maximumBytes else {
        throw OSMminiError.native("Invalid PBF download size")
      }
      lock.lock()
      let stopped = cancelled
      lock.unlock()
      if stopped { throw CancellationError() }
      try FileManager.default.moveItem(at: location, to: target)
      try? FileManager.default.removeItem(at: resumeURL)
      finish(.success(target))
    } catch { finish(.failure(error)) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    guard let error else { return }
    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
      try? data.write(to: resumeURL, options: .atomic)
    }
    lock.lock()
    let failure = failure
    let stopped = cancelled
    lock.unlock()
    finish(.failure(failure.map(OSMminiError.native) ?? (stopped ? CancellationError() : error)))
  }
  private func finish(_ result: Result<URL, any Error>) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    let session = session
    self.session = nil
    lock.unlock()
    continuation?.resume(with: result)
    session?.finishTasksAndInvalidate()
  }
}
