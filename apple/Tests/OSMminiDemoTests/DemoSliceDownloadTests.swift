import Foundation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

private final class SliceModelURLProtocol: URLProtocol, @unchecked Sendable {
  static let jobID = "775cbd21-2487-4dbf-913a-64ae6f402523"

  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var payload = Data()
    private var pending = false
    private var requests: [(String, String)] = []

    func configure(_ payload: Data, pending: Bool = false) {
      lock.lock()
      defer { lock.unlock() }
      self.payload = payload
      self.pending = pending
      requests = []
    }

    func completeJob() {
      lock.lock()
      pending = false
      lock.unlock()
    }

    func response(_ request: URLRequest) -> (Int, Data) {
      lock.lock()
      defer { lock.unlock() }
      let method = request.httpMethod ?? "GET"
      let path = request.url.flatMap {
        URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
      } ?? ""
      requests.append((method, path))
      guard request.url?.host == "slice.openstreetmap.us" else { return (400, Data()) }
      if method == "POST", path == "/api/" {
        return (201, Data(SliceModelURLProtocol.jobID.utf8))
      }
      if method == "GET", path == "/api/" + SliceModelURLProtocol.jobID {
        return (200, Data("{\"Complete\":\(!pending),\"SizeBytes\":\(payload.count)}".utf8))
      }
      if method == "GET", path == "/files/" + SliceModelURLProtocol.jobID + ".osm.pbf" {
        return (200, payload)
      }
      return (404, Data())
    }

    var snapshot: [(String, String)] {
      lock.lock()
      defer { lock.unlock() }
      return requests
    }
  }

  static let state = State()
  private let lock = NSRecursiveLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (status, data) = Self.state.response(request)
    DispatchQueue.global().async { [self] in
      lock.lock()
      defer { lock.unlock() }
      guard !stopped, let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Length": "\(data.count)"])
      else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SliceModelURLProtocol.self]
    configuration.urlCache = nil
    return configuration
  }
}

@MainActor @Suite(.serialized) struct DemoSliceDownloadTests {
  private let root: URL
  private let defaults: UserDefaults
  private let suite: String

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    suite = "DemoSliceDownloadTests.\(UUID().uuidString)"
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

  private func model() -> (DemoModel, URLSession) {
    let session = URLSession(configuration: SliceModelURLProtocol.configuration())
    let client = SliceOSM(
      directory: root.appendingPathComponent("downloads"), session: session,
      downloadConfiguration: { SliceModelURLProtocol.configuration() })
    return (DemoModel(root: root, defaults: defaults, sliceOSM: client), session)
  }

  @Test func completedSliceDownloadsAreImportedAndOpenedAsOfflineRegions() async throws {
    defer { cleanup() }
    SliceModelURLProtocol.state.configure(try Data(contentsOf: fixture()))
    let (model, session) = model()
    defer { session.invalidateAndCancel() }

    model.downloadSlice(center: Coordinate(lat: 48.75, lon: 12.96), radiusKM: 30)
    #expect(model.activity == .downloading)
    let operation = try #require(model.operation)
    await operation.value

    let engine = try #require(model.engine)
    #expect(engine.manifest.name == "Umkreis 30 km")
    #expect(model.installed.count == 1)
    #expect(model.pending == nil)
    #expect(model.pendingSlice == nil)
    #expect(defaults.data(forKey: "pendingSliceDownload") == nil)
    #expect(model.importFailure == nil)
    #expect(!model.busy)
    let requests = SliceModelURLProtocol.state.snapshot
    #expect(requests.filter { $0.0 == "POST" }.count == 1)
    #expect(requests.contains { $0.1 == "/files/" + SliceModelURLProtocol.jobID + ".osm.pbf" })
    #expect(try await engine.search("cafe").count > 0)
    await engine.close()
  }

  @Test func anExistingOperationPreventsSubmittingAnotherSlice() async throws {
    defer { cleanup() }
    SliceModelURLProtocol.state.configure(Data())
    let (model, session) = model()
    defer { session.invalidateAndCancel() }
    model.run(.downloading, status: "Existing operation") { _ in
      try await Task.sleep(for: .seconds(60))
    }
    let operation = try #require(model.operation)

    model.downloadSlice(center: Coordinate(lat: 48.75, lon: 12.96), radiusKM: 150)
    #expect(model.status == "Existing operation")
    #expect(SliceModelURLProtocol.state.snapshot.isEmpty)
    model.cancel()
    await operation.value
  }

  @Test func aPendingImportPreventsSubmittingASliceAndKeepsItsResumeData() throws {
    defer { cleanup() }
    let options = ImportOptions(
      pbf: try fixture(), destination: root.appendingPathComponent("old-import"), name: "Fortsetzen")
    let workspace = URL(fileURLWithPath: options.destination + ".pending")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data("checkpoint".utf8).write(to: workspace.appendingPathComponent("source"))
    let saved = try JSONEncoder().encode(options)
    defaults.set(saved, forKey: "pendingImport")
    SliceModelURLProtocol.state.configure(Data())
    let (model, session) = model()
    defer { session.invalidateAndCancel() }
    #expect(model.pending != nil)

    model.downloadSlice(center: Coordinate(lat: 48.75, lon: 12.96), radiusKM: 30)
    #expect(model.operation == nil)
    #expect(SliceModelURLProtocol.state.snapshot.isEmpty)
    #expect(model.pending?.destination == options.destination)
    #expect(defaults.data(forKey: "pendingImport") == saved)
  }

  @Test func cancelledSlicePreparationResumesAfterReopeningWithoutSubmittingAnotherJob() async throws {
    defer { cleanup() }
    let prepared = root.appendingPathComponent("prepared")
    var options = ImportOptions(pbf: try fixture(), destination: prepared, name: "Vorhandene Karte")
    options.minZoom = 14
    options.maxZoom = 14
    try await OfflineEngine.importPBF(options)
    SliceModelURLProtocol.state.configure(try Data(contentsOf: fixture()), pending: true)
    let (model, session) = model()
    defer { session.invalidateAndCancel() }
    await model.start(arguments: ["demo", "--region", prepared.path, "--offline"])
    let engine = try #require(model.engine)

    let center = Coordinate(lat: 48.75, lon: 12.96)
    model.selectPOIPreset(.firefighting)
    model.downloadSlice(center: center, radiusKM: 60)
    model.selectPOIPreset(.everyday)
    let operation = try #require(model.operation)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !SliceModelURLProtocol.state.snapshot.contains(where: {
      $0.0 == "GET" && $0.1.hasPrefix("/api/")
    }), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(SliceModelURLProtocol.state.snapshot.contains { $0.0 == "GET" && $0.1.hasPrefix("/api/") })
    model.cancel()
    await operation.value

    #expect(model.engine === engine)
    #expect(model.activeDirectory == prepared.resolvingSymlinksInPath().standardizedFileURL)
    #expect(model.pending == nil)
    #expect(model.pendingSlice?.center == center)
    #expect(model.pendingSlice?.radiusKM == 60)
    #expect(model.pendingSlice?.poiPreset == .firefighting)
    #expect(model.selectedPOIPreset == .everyday)
    #expect(defaults.data(forKey: "pendingSliceDownload") != nil)
    #expect(model.importFailure == nil)
    #expect(!model.busy)
    #expect(SliceModelURLProtocol.state.snapshot.filter { $0.0 == "POST" }.count == 1)
    #expect(try await engine.search("cafe").count > 0)

    // A new model and client must reuse the persisted center and the SDK's job
    // record, even though a newly acquired GPS fix could differ slightly.
    let (resumed, resumedSession) = self.model()
    defer { resumedSession.invalidateAndCancel() }
    #expect(resumed.pendingSlice?.center == center)
    #expect(resumed.pendingSlice?.radiusKM == 60)
    #expect(resumed.pendingSlice?.resolvedPOIPreset == .firefighting)
    #expect(resumed.selectedPOIPreset == .everyday)
    SliceModelURLProtocol.state.completeJob()
    resumed.resumeSliceDownload()
    let resumedOperation = try #require(resumed.operation)
    await resumedOperation.value

    let resumedEngine = try #require(resumed.engine)
    #expect(resumedEngine.manifest.name == "Umkreis 60 km")
    #expect(resumedEngine.manifest.poiPreset == .firefighting)
    #expect(resumed.pendingSlice == nil)
    #expect(resumed.pending == nil)
    #expect(resumed.importFailure == nil)
    #expect(defaults.data(forKey: "pendingSliceDownload") == nil)
    #expect(SliceModelURLProtocol.state.snapshot.filter { $0.0 == "POST" }.count == 1)
    #expect(!(try await resumedEngine.search("cafe")).contains { $0.category == "cafe" })
    await resumedEngine.close()
    await engine.close()
  }

  @Test func malformedAndUnsupportedSavedSliceRequestsAreIgnoredWithoutNetworkWork() throws {
    defer { cleanup() }
    SliceModelURLProtocol.state.configure(Data())
    for raw in [
      "not JSON",
      #"{"center":{"lat":91,"lon":12},"radiusKM":30}"#,
      #"{"center":{"lat":48.75,"lon":12.96},"radiusKM":45}"#,
      #"{"center":{"lat":48.75,"lon":12.96},"radiusKM":0}"#,
      #"{"center":{},"radiusKM":30}"#,
    ] {
      defaults.set(Data(raw.utf8), forKey: "pendingSliceDownload")
      let (model, session) = self.model()
      defer { session.invalidateAndCancel() }
      #expect(model.pendingSlice == nil, "\(raw)")
      #expect(model.operation == nil)
    }
    #expect(SliceModelURLProtocol.state.snapshot.isEmpty)
  }
}
