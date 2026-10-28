import CryptoKit
import Foundation

public enum SliceOSMProgress: Sendable {
  case preparing(fraction: Double?)
  case downloading(bytes: Int64, total: Int64)
}

/// Creates one on-demand extract, waits for it, and downloads its PBF.
/// Cancelling stops this client's work; SliceOSM has no API to cancel server jobs.
public actor SliceOSM {
  public static let apiURL = URL(string: "https://slice.openstreetmap.us/api/")!
  private let directory: URL
  private let session: URLSession
  private let downloadConfiguration: @Sendable () -> URLSessionConfiguration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date
  private let maximumPolls: Int
  private let redirectPolicy = SliceAPIRedirectPolicy()
  private var active = false

  public init(directory: URL) {
    self.directory = directory
    session = .shared
    downloadConfiguration = { .default }
    sleep = { try await Task.sleep(for: $0) }
    now = { Date() }
    maximumPolls = 360
  }

  init(
    directory: URL, session: URLSession,
    downloadConfiguration: @escaping @Sendable () -> URLSessionConfiguration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }, maximumPolls: Int = 360
  ) {
    self.directory = directory
    self.session = session
    self.downloadConfiguration = downloadConfiguration
    self.sleep = sleep
    self.now = now
    self.maximumPolls = max(1, maximumPolls)
  }

  public func download(
    center: Coordinate, radiusKM: Int, name: String,
    maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
    progress: (@Sendable (SliceOSMProgress) -> Void)? = nil
  ) async throws -> URL {
    try Task.checkCancellation()
    let region = try SliceOSMRegion(center: center, radiusKM: radiusKM, name: name)
    guard maximumBytes > 0 else { throw OSMminiError.native("Ungültige Download-Größenbegrenzung.") }
    guard !active else {
      throw OSMminiError.native("Ein SliceOSM-Ausschnitt wird bereits vorbereitet.")
    }
    active = true
    defer { active = false }
    let deadline = now().addingTimeInterval(30 * 60)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let recordURL = directory.appendingPathComponent(Self.jobFilename(region))
    progress?(.preparing(fraction: nil))
    let job: JobRecord
    if let existing = cachedJob(at: recordURL) {
      job = existing
    } else {
      job = try await submit(region)
      // Persist even if cancellation arrives after the server supplied the ID.
      // An explicit retry resumes that job rather than submitting the area again.
      try JSONEncoder().encode(job).write(to: recordURL, options: .atomic)
    }
    try Task.checkCancellation()
    let downloadURL = Self.downloadURL(job.id)
    let target = directory.appendingPathComponent(OSMExtracts.cacheFilename(downloadURL))
    if let cached = try cachedPBF(at: target, maximumBytes: maximumBytes) {
      progress?(.downloading(bytes: cached, total: cached))
      return target
    }
    try await waitForJob(
      job, recordURL: recordURL, maximumBytes: maximumBytes, deadline: deadline, progress: progress)
    try Task.checkCancellation()
    let transfer = DownloadTransfer(
      url: downloadURL, target: target, maximumBytes: maximumBytes, providerName: "SliceOSM",
      permitsURL: { $0 == downloadURL },
      progress: { bytes, total in progress?(.downloading(bytes: bytes, total: total)) },
      configuration: downloadConfiguration())
    return try await withTaskCancellationHandler {
      let result = try await transfer.run()
      try Task.checkCancellation()
      return result
    } onCancel: {
      transfer.cancel()
    }
  }

  private struct JobRecord: Codable {
    let id: UUID
    let created: Date
  }

  private struct Input: Encodable {
    struct Geometry: Encodable {
      let type = "Polygon"
      let coordinates: [[[Double]]]
    }
    let Name: String
    let RegionType = "geojson"
    let RegionData: Geometry
  }

  private struct JobProgress: Decodable {
    let Complete: Bool
    let SizeBytes: Int64?
    let ElemsProg: Int64?
    let ElemsTotal: Int64?

    var fraction: Double? {
      guard let current = ElemsProg, let total = ElemsTotal, current >= 0, total > 0 else {
        return nil
      }
      return min(0.99, Double(current) / Double(total))
    }
  }

  private func submit(_ region: SliceOSMRegion) async throws -> JobRecord {
    var request = URLRequest(url: Self.apiURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(Input(
      Name: region.name, RegionData: Input.Geometry(
        coordinates: [region.boundary.map { [$0.lon, $0.lat] }])))
    let data = try await response(request, expectedStatus: 201)
    guard let text = String(data: data, encoding: .utf8),
      let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw OSMminiError.native("SliceOSM hat keine gültige Auftragsnummer geliefert.") }
    return JobRecord(id: id, created: now())
  }

  private func waitForJob(
    _ job: JobRecord, recordURL: URL, maximumBytes: Int64, deadline: Date,
    progress: (@Sendable (SliceOSMProgress) -> Void)?
  ) async throws {
    let endpoint = Self.apiURL.appendingPathComponent(job.id.uuidString.lowercased())
    for index in 0..<maximumPolls {
      try Task.checkCancellation()
      guard now() < deadline else { break }
      if index > 0 { try await sleep(.seconds(5)) }
      try Task.checkCancellation()
      guard now() < deadline else { break }
      let data: Data
      do {
        data = try await response(URLRequest(url: endpoint), expectedStatus: 200)
      } catch SliceResponseError.expired {
        try? FileManager.default.removeItem(at: recordURL)
        throw OSMminiError.native("Der SliceOSM-Auftrag ist nicht mehr verfügbar. Starte den Download erneut.")
      }
      let state: JobProgress
      do {
        state = try JSONDecoder().decode(JobProgress.self, from: data)
      } catch {
        throw OSMminiError.native("SliceOSM hat einen ungültigen Fortschritt geliefert.")
      }
      if state.Complete {
        guard let bytes = state.SizeBytes, bytes > 0 else {
          throw OSMminiError.native("SliceOSM hat keinen gültigen PBF-Ausschnitt erstellt.")
        }
        guard bytes <= maximumBytes else {
          throw OSMminiError.native("Der Ausschnitt ist zu groß. Wähle einen kleineren Umkreis.")
        }
        return
      }
      progress?(.preparing(fraction: state.fraction))
    }
    throw OSMminiError.native(
      "SliceOSM benötigt zu lange. Versuche es später erneut; der vorhandene Auftrag wird weiterverwendet.")
  }

  private enum SliceResponseError: Error { case expired }

  private func response(_ input: URLRequest, expectedStatus: Int) async throws -> Data {
    var request = input
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("OSMmini-Apple/1.0 (offline regional maps)", forHTTPHeaderField: "User-Agent")
    // A redirect must never replay the submitted location polygon elsewhere.
    let result: (Data, URLResponse)
    do {
      result = try await session.data(for: request, delegate: redirectPolicy)
    } catch {
      try Task.checkCancellation()
      throw error
    }
    let (data, response) = result
    guard let http = response as? HTTPURLResponse, data.count <= 64 * 1024 else {
      throw OSMminiError.native("Ungültige Antwort von SliceOSM.")
    }
    switch http.statusCode {
    case expectedStatus: return data
    case 400:
      throw OSMminiError.native("SliceOSM kann diesen Ausschnitt nicht erstellen. Wähle einen kleineren Umkreis.")
    case 404: throw SliceResponseError.expired
    case 429, 503:
      throw OSMminiError.native("SliceOSM ist momentan ausgelastet. Versuche es später erneut.")
    default:
      throw OSMminiError.native("SliceOSM ist momentan nicht erreichbar (HTTP \(http.statusCode)).")
    }
  }

  private func cachedJob(at url: URL) -> JobRecord? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, (1...4096).contains(size.intValue),
      let data = try? Data(contentsOf: url),
      let job = try? JSONDecoder().decode(JobRecord.self, from: data)
    else { return nil }
    let age = now().timeIntervalSince(job.created)
    return age >= 0 && age < 24 * 60 * 60 ? job : nil
  }

  private func cachedPBF(at url: URL, maximumBytes: Int64) throws -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard attributes[.type] as? FileAttributeType == .typeRegular, size > 0, size <= maximumBytes else {
      throw OSMminiError.native("Der gespeicherte Ausschnitt ist ungültig oder zu groß.")
    }
    return size
  }

  private static func jobFilename(_ region: SliceOSMRegion) -> String {
    // A name change does not change the requested data. Keep coordinates out of
    // metadata files and use their geometry fingerprint only as the cache key.
    let key = "\(region.center.lat),\(region.center.lon),\(region.radiusKM)"
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return "sliceosm-\(digest).json"
  }

  private static func downloadURL(_ id: UUID) -> URL {
    URL(string: "https://slice.openstreetmap.us/files/\(id.uuidString.lowercased()).osm.pbf")!
  }
}

final class SliceAPIRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
