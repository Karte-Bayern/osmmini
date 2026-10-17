import COSMmini
import Foundation

private final class Cancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var operation: UInt64 = 0
  private var cancelled = false
  func attach(_ id: UInt64) {
    lock.lock()
    operation = id
    let stop = cancelled
    lock.unlock()
    if stop { OSMminiCancel(id) }
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let id = operation
    lock.unlock()
    if id != 0 { OSMminiCancel(id) }
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}
private enum Native {
  struct Start: Decodable { let operation: UInt64?, error: String? }
  struct Envelope<T: Decodable>: Decodable {
    let state: String?, error: String?, progress: ImportProgress?, result: T?
  }
  // Blocking native calls and JSON decoding use a GCD worker, never Swift's
  // main actor or cooperative executor. Cancellation drains the Go job before
  // releasing it, including cancellation that races with successful opening.
  static func perform<T: Decodable & Sendable>(
    _ request: NativeRequest, takingEngine: Bool = false,
    progress: (@Sendable (ImportProgress) -> Void)? = nil
  ) async throws -> (T, UInt64) {
    guard OSMminiABIVersion() == 1 else { throw OSMminiError.incompatibleABI }
    let cancellation = Cancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let decoder = JSONDecoder()
            var input = try JSONEncoder().encode(request)
            input.append(0)
            let started = try input.withUnsafeMutableBytes { bytes in
              guard let base = bytes.baseAddress else { throw OSMminiError.invalidResponse }
              return try decoder.decode(
                Start.self,
                from: NativeJSONBuffer.take(OSMminiStart(base.assumingMemoryBound(to: CChar.self))))
            }
            guard let id = started.operation else {
              throw OSMminiError.native(started.error ?? "Could not start native job")
            }
            cancellation.attach(id)
            defer { OSMminiRelease(id) }
            var previousProgress: ImportProgress?
            while true {
              let envelope = try decoder.decode(
                Envelope<T>.self, from: NativeJSONBuffer.take(OSMminiWait(id, 100)))
              guard let state = envelope.state, ["running", "failed", "complete"].contains(state)
              else { throw OSMminiError.native(envelope.error ?? "Unknown native operation state") }
              if let p = envelope.progress, p != previousProgress {
                progress?(p)
                previousProgress = p
              }
              if envelope.state == "failed" {
                if cancellation.isCancelled { throw CancellationError() }
                throw OSMminiError.native(envelope.error ?? "Native operation failed")
              }
              if envelope.state == "complete" {
                if cancellation.isCancelled { throw CancellationError() }
                guard let result = envelope.result else { throw OSMminiError.invalidResponse }
                let engine = takingEngine ? OSMminiTakeEngine(id) : 0
                continuation.resume(returning: (result, engine))
                return
              }
            }
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

/// Independent region instance. Native handles are protected by Go; queries may
/// run concurrently. Close waits for in-flight operations before unmapping data.
public final class OfflineEngine: Sendable {
  private let handle: UInt64
  public let manifest: RegionManifest
  private init(handle: UInt64, manifest: RegionManifest) {
    self.handle = handle
    self.manifest = manifest
  }
  deinit {
    let id = handle
    DispatchQueue.global(qos: .utility).async { OSMminiClose(id) }
  }

  @discardableResult public static func importPBF(
    _ options: ImportOptions,
    progress: (@Sendable (ImportProgress) -> Void)? = nil
  ) async throws -> RegionManifest {
    let (result, _): (RegionManifest, UInt64) = try await Native.perform(
      NativeRequest(action: "import", importOptions: options), progress: progress)
    return result
  }
  public static func open(_ directory: URL) async throws -> OfflineEngine {
    let (manifest, handle): (RegionManifest, UInt64) = try await Native.perform(
      NativeRequest(action: "open", path: directory.path), takingEngine: true)
    guard handle != 0 else { throw OSMminiError.invalidResponse }
    if Task.isCancelled {
      OSMminiClose(handle)
      throw CancellationError()
    }
    return OfflineEngine(handle: handle, manifest: manifest)
  }
  public func search(_ query: String, limit: Int = 20) async throws -> [SearchResult] {
    let (value, _): ([SearchResult], UInt64) = try await Native.perform(
      NativeRequest(action: "search", engine: handle, query: query, limit: limit))
    return value
  }
  public func route(_ request: RouteRequest) async throws -> Route {
    let (value, _): (Route, UInt64) = try await Native.perform(
      NativeRequest(action: "route", engine: handle, route: request))
    return value
  }
  public func tile(z: Int, x: Int, y: Int) async throws -> VectorTile {
    let (value, _): (VectorTile, UInt64) = try await Native.perform(
      NativeRequest(action: "tile", engine: handle, z: z, x: x, y: y))
    return value
  }
  public func close() async {
    let id = handle
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        OSMminiClose(id)
        continuation.resume()
      }
    }
  }
}
