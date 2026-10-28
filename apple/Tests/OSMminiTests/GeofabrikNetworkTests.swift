import Foundation
import Testing

@testable import OSMmini

private final class GeofabrikURLProtocol: URLProtocol, @unchecked Sendable {
  final class State: @unchecked Sendable {
    let lock = NSLock()
    var requests = 0
    var urls: [URL] = []
    var data = Data()
    var status = 200
    var delay: TimeInterval = 0
    func configure(_ data: Data, status: Int = 200, delay: TimeInterval = 0) {
      lock.lock()
      defer { lock.unlock() }
      self.requests = 0
      self.urls = []
      self.data = data
      self.status = status
      self.delay = delay
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return requests
    }
    var requestedURLs: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return urls
    }
  }
  static let state = State()
  private let lock = NSRecursiveLock()
  private var stopped = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.lock.lock()
    Self.state.requests += 1
    if let url = request.url { Self.state.urls.append(url) }
    let data = Self.state.data
    let status = Self.state.status
    let delay = Self.state.delay
    Self.state.lock.unlock()
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
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
    configuration.protocolClasses = [GeofabrikURLProtocol.self]
    configuration.urlCache = nil
    return configuration
  }
}

private func catalogFixture(_ count: Int = 1) -> Data {
  let features = (0..<count).map { index in
    """
    {"properties":{"id":"test\(index)","name":"Region \(index)","parent":"europe","urls":{"pbf":"https://download.geofabrik.de/europe/test\(index)-latest.osm.pbf"}}}
    """
  }.joined(separator: ",")
  return Data("{\"features\":[\(features)]}".utf8)
}

private func networkDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func networkClient(
  _ directory: URL, source: OSMExtractSource = .geofabrik
) -> (Geofabrik, URLSession) {
  let session = URLSession(configuration: GeofabrikURLProtocol.configuration())
  return (
    Geofabrik(
      directory: directory, source: source, catalogSession: session,
      downloadConfiguration: { GeofabrikURLProtocol.configuration() }), session
  )
}

private func fixtureRegion() -> GeofabrikRegion {
  GeofabrikRegion(
    id: "test", name: "Test", parent: nil,
    pbfURL: URL(string: "https://download.geofabrik.de/test-latest.osm.pbf")!)
}

private func waitForRequest() async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(5))
  while GeofabrikURLProtocol.state.count == 0, clock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(GeofabrikURLProtocol.state.count > 0)
}

private final class DownloadProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [(Int64, Int64)] = []
  func store(_ bytes: Int64, _ total: Int64) {
    lock.lock()
    values.append((bytes, total))
    lock.unlock()
  }
  var snapshot: [(Int64, Int64)] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

@Suite(.serialized) struct GeofabrikNetworkTests {
  private var franceCatalog: Data {
    Data(
      #"{"truncated":false,"tree":[{"path":"osc_modif/polygons/europe.poly","type":"blob"},{"path":"osc_modif/polygons/europe/gibraltar.poly","type":"blob"}]}"#.utf8)
  }

  @Test func franceCatalogUsesOfficialIndexAndSeparatePersistentCache() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try catalogFixture(3).write(to: directory.appendingPathComponent("geofabrik-index.json"))
    GeofabrikURLProtocol.state.configure(franceCatalog)
    let (client, session) = networkClient(directory, source: .openStreetMapFrance)
    defer { session.invalidateAndCancel() }
    #expect(client.source == .openStreetMapFrance)
    #expect(try await client.regions().count == 2)
    #expect(GeofabrikURLProtocol.state.requestedURLs == [OSMExtractSource.openStreetMapFrance.catalogURL])
    let cache = directory.appendingPathComponent("osmfr-index.json")
    #expect(try Data(contentsOf: cache) == franceCatalog)
    let (offline, offlineSession) = networkClient(directory, source: .openStreetMapFrance)
    defer { offlineSession.invalidateAndCancel() }
    #expect(try await offline.regions().count == 2)
    let (legacy, legacySession) = networkClient(directory)
    defer { legacySession.invalidateAndCancel() }
    #expect(try await legacy.regions().count == 3)
    #expect(GeofabrikURLProtocol.state.count == 1)
  }

  @Test func franceIncompleteRefreshPreservesOfflineCatalog() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("osmfr-index.json")
    try franceCatalog.write(to: cache)
    let (client, session) = networkClient(directory, source: .openStreetMapFrance)
    defer { session.invalidateAndCancel() }
    #expect(try await client.regions().count == 2)
    GeofabrikURLProtocol.state.configure(Data(#"{"truncated":true,"tree":[]}"#.utf8))
    do {
      _ = try await client.regions(refresh: true)
      Issue.record("incomplete provider index replaced the offline catalog")
    } catch {}
    #expect(try await client.regions().count == 2)
    #expect(try Data(contentsOf: cache) == franceCatalog)
    #expect(GeofabrikURLProtocol.state.count == 1)
  }

  @Test func providerDownloadsKeepEqualBasenamesSeparateAndRejectAnotherSource() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 7, count: 512)
    GeofabrikURLProtocol.state.configure(bytes)
    let (geofabrik, geofabrikSession) = networkClient(directory)
    let (france, franceSession) = networkClient(directory, source: .openStreetMapFrance)
    defer { geofabrikSession.invalidateAndCancel(); franceSession.invalidateAndCancel() }
    let geofabrikRegion = OSMExtractRegion(
      id: "gibraltar", name: "Gibraltar", parent: "europe",
      pbfURL: URL(string: "https://download.geofabrik.de/europe/gibraltar-latest.osm.pbf")!)
    let franceRegion = OSMExtractRegion(
      id: "europe/gibraltar", name: "Gibraltar", parent: "europe",
      pbfURL: URL(string: "https://download.openstreetmap.fr/extracts/europe/gibraltar-latest.osm.pbf")!)
    do {
      _ = try await geofabrik.download(franceRegion)
      Issue.record("Geofabrik client accepted another provider")
    } catch {}
    do {
      _ = try await france.download(geofabrikRegion)
      Issue.record("France client accepted another provider")
    } catch {}
    #expect(GeofabrikURLProtocol.state.count == 0)
    let first = try await geofabrik.download(geofabrikRegion)
    let second = try await france.download(franceRegion)
    #expect(first != second)
    #expect(try Data(contentsOf: first) == bytes)
    #expect(try Data(contentsOf: second) == bytes)
    #expect(GeofabrikURLProtocol.state.count == 2)
    #expect(try await france.download(franceRegion) == second)
    #expect(GeofabrikURLProtocol.state.count == 2)
  }
  @Test func localProtocolDownloadsSmallFixture() async throws {
    let expected = Data("local fixture, no network".utf8)
    GeofabrikURLProtocol.state.configure(expected)
    let session = URLSession(configuration: GeofabrikURLProtocol.configuration())
    defer { session.invalidateAndCancel() }
    let (url, _) = try await session.download(
      from: URL(string: "https://download.geofabrik.de/test.osm.pbf")!)
    #expect(try Data(contentsOf: url) == expected)
    #expect(GeofabrikURLProtocol.state.count == 1)
  }

  @Test func catalogIsDecodedFromDiskOnceAndThenRetainedInMemory() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("geofabrik-index.json")
    try catalogFixture(3).write(to: cache)
    GeofabrikURLProtocol.state.configure(Data())
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    #expect(try await client.regions().count == 3)
    try FileManager.default.removeItem(at: cache)
    #expect(try await client.regions().count == 3)
    #expect(GeofabrikURLProtocol.state.count == 0)
  }

  @Test func catalogUsesOfficialPropertiesOnlyEndpointAndKeepsLegacyCacheFilename() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let propertiesOnly = catalogFixture(3)
    #expect(try Geofabrik.decodeCatalog(propertiesOnly).count == 3)
    GeofabrikURLProtocol.state.configure(propertiesOnly)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    #expect(try await client.regions(refresh: true).count == 3)
    #expect(
      Geofabrik.catalogURL.absoluteString == "https://download.geofabrik.de/index-v1-nogeom.json")
    #expect(GeofabrikURLProtocol.state.requestedURLs == [Geofabrik.catalogURL])
    let legacyCache = directory.appendingPathComponent("geofabrik-index.json")
    #expect(try Data(contentsOf: legacyCache) == propertiesOnly)
    let (offline, secondSession) = networkClient(directory)
    defer { secondSession.invalidateAndCancel() }
    #expect(try await offline.regions().count == 3)
    #expect(GeofabrikURLProtocol.state.count == 1)
  }

  @Test func concurrentCatalogCallersShareTheInFlightRefresh() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(catalogFixture(2), delay: 0.1)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let refreshing = Task { try await client.regions(refresh: true) }
    try await waitForRequest()
    try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<20 { group.addTask { try await client.regions().count } }
      for try await count in group { #expect(count == 2) }
    }
    #expect(try await refreshing.value.count == 2)
    #expect(GeofabrikURLProtocol.state.count == 1)
    #expect(
      try Data(contentsOf: directory.appendingPathComponent("geofabrik-index.json"))
        == catalogFixture(2))
  }

  @Test func corruptCatalogCacheIsReplacedOnlyByValidDownloadedData() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("geofabrik-index.json")
    let original = Data("broken cache".utf8)
    try original.write(to: cache)
    GeofabrikURLProtocol.state.configure(Data("invalid JSON".utf8))
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await client.regions()
      Issue.record("invalid downloaded catalog was accepted")
    } catch {}
    #expect(try Data(contentsOf: cache) == original)
    GeofabrikURLProtocol.state.configure(catalogFixture())
    #expect(try await client.regions().count == 1)
    #expect(try Data(contentsOf: cache) == catalogFixture())
  }

  @Test func failedRefreshPreservesTheValidOfflineCatalog() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("geofabrik-index.json")
    let original = catalogFixture(2)
    try original.write(to: cache)
    GeofabrikURLProtocol.state.configure(Data(), status: 503)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    #expect(try await client.regions().count == 2)
    do {
      _ = try await client.regions(refresh: true)
      Issue.record("HTTP error while refreshing catalog was accepted")
    } catch {}
    #expect(try await client.regions().count == 2)
    #expect(try Data(contentsOf: cache) == original)
    #expect(GeofabrikURLProtocol.state.count == 1)
  }

  @Test func concurrentRegionDownloadsUseOneTransferAndRespectEachSizeLimit() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = Data(repeating: 7, count: 4096)
    GeofabrikURLProtocol.state.configure(payload, delay: 0.1)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let region = fixtureRegion()
    try await withThrowingTaskGroup(of: URL.self) { group in
      for _ in 0..<12 { group.addTask { try await client.download(region, maximumBytes: 8192) } }
      for try await url in group { #expect(try Data(contentsOf: url) == payload) }
    }
    #expect(GeofabrikURLProtocol.state.count == 1)
    do {
      _ = try await client.download(region, maximumBytes: 1024)
      Issue.record("oversized cached download bypassed maximumBytes")
    } catch {}
    #expect(GeofabrikURLProtocol.state.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
  }

  @Test func cancelledWaitingCallerLeavesActiveDownloadRunning() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(Data(repeating: 7, count: 4096), delay: 0.2)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let region = fixtureRegion()
    let first = Task { try await client.download(region) }
    try await waitForRequest()
    let follower = DownloadProgressRecorder()
    let waiting = Task { try await client.download(region) { follower.store($0, $1) } }
    await Task.yield()
    waiting.cancel()
    do {
      _ = try await waiting.value
      Issue.record("cancelled waiting download succeeded")
    } catch is CancellationError {}
    let countAfterCancellation = follower.snapshot.count
    let result = try await first.value
    #expect(FileManager.default.fileExists(atPath: result.path))
    #expect(GeofabrikURLProtocol.state.count == 1)
    #expect(follower.snapshot.count == countAfterCancellation)
  }

  @Test func cancelledActiveDownloadAllowsTheNextCallerToRetry() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(Data(repeating: 7, count: 4096), delay: 0.2)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let region = fixtureRegion()
    let first = Task { try await client.download(region) }
    try await waitForRequest()
    let next = Task { try await client.download(region) }
    first.cancel()
    do {
      _ = try await first.value
      Issue.record("cancelled active download succeeded")
    } catch is CancellationError {}
    let result = try await next.value
    #expect(try Data(contentsOf: result) == Data(repeating: 7, count: 4096))
    #expect(GeofabrikURLProtocol.state.count == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
  }

  @Test func cancellingAllSubscribersDoesNotRemoveTheNextTransfersProgressHub() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(Data(repeating: 7, count: 4096), delay: 0.2)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let region = fixtureRegion()
    let first = Task { try await client.download(region) }
    try await waitForRequest()
    let waiting = Task { try await client.download(region) }
    await Task.yield()
    first.cancel()
    waiting.cancel()
    let progress = DownloadProgressRecorder()
    let retry = Task { try await client.download(region) { progress.store($0, $1) } }
    for task in [first, waiting] {
      do {
        _ = try await task.value
        Issue.record("cancelled download succeeded")
      } catch is CancellationError {}
    }
    _ = try await retry.value
    #expect(progress.snapshot.last?.0 == 4096)
    #expect(progress.snapshot.last?.1 == 4096)
    #expect(GeofabrikURLProtocol.state.count == 2)
  }

  @Test func downloadSizeLimitPreventsPublication() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(Data(repeating: 7, count: 4096))
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await client.download(fixtureRegion(), maximumBytes: 128)
      Issue.record("download exceeding maximumBytes succeeded")
    } catch {}
    let target = directory.appendingPathComponent(Geofabrik.cacheFilename(fixtureRegion().pbfURL))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
        !$0.contains("download-")
      })
  }

  @Test func successfulDownloadAlwaysReportsItsFinalSize() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(Data(repeating: 7, count: 4096))
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let progress = DownloadProgressRecorder()
    _ = try await client.download(fixtureRegion()) { progress.store($0, $1) }
    #expect(progress.snapshot.last?.0 == 4096)
    #expect(progress.snapshot.last?.1 == 4096)
  }

  @Test func coalescedDownloadsAndCacheHitsAllReceiveFinalProgress() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GeofabrikURLProtocol.state.configure(Data(repeating: 7, count: 4096), delay: 0.1)
    let (client, session) = networkClient(directory)
    defer { session.invalidateAndCancel() }
    let region = fixtureRegion()
    let leader = DownloadProgressRecorder()
    let follower = DownloadProgressRecorder()
    let first = Task { try await client.download(region) { leader.store($0, $1) } }
    try await waitForRequest()
    let second = Task { try await client.download(region) { follower.store($0, $1) } }
    _ = try await first.value
    _ = try await second.value
    for progress in [leader, follower] {
      #expect(progress.snapshot.last?.0 == 4096)
      #expect(progress.snapshot.last?.1 == 4096)
    }
    let cached = DownloadProgressRecorder()
    _ = try await client.download(region) { cached.store($0, $1) }
    #expect(cached.snapshot.count == 1)
    #expect(cached.snapshot.last?.0 == 4096)
    #expect(GeofabrikURLProtocol.state.count == 1)
  }

  @Test func progressHubReplaysLatestAndRemovesCancelledSubscribers() {
    let hub = GeofabrikDownloadProgress()
    let first = DownloadProgressRecorder()
    let second = DownloadProgressRecorder()
    let leader = hub.add { first.store($0, $1) }
    hub.send(10, 100)
    let follower = hub.add { second.store($0, $1) }
    #expect(second.snapshot.count == 1)
    #expect(second.snapshot.first?.0 == 10)
    hub.remove(follower)
    hub.send(100, 100)
    hub.send(100, 100)
    #expect(first.snapshot.count == 2)
    #expect(first.snapshot.last?.0 == 100)
    #expect(second.snapshot.count == 1)
    let withoutCallback = hub.add(nil)
    #expect(hub.count == 2)
    hub.remove(withoutCallback)
    hub.remove(leader)
    #expect(hub.count == 0)
  }

  @Test func progressCallbacksCanPublishAgainWithoutDeadlockOrStaleReplay() {
    let hub = GeofabrikDownloadProgress()
    let recorder = DownloadProgressRecorder()
    _ = hub.add { bytes, _ in
      if bytes == 10 { hub.send(20, 100) }
    }
    _ = hub.add { recorder.store($0, $1) }
    hub.send(10, 100)
    let values = recorder.snapshot.map { $0.0 }
    #expect(values.last == 20)
    #expect(values == values.sorted())
  }

  @Test func progressThrottlePreservesFirstChangedTotalAndFinalValues() {
    var throttle = DownloadProgressThrottle()
    var callbacks = 0
    for byte in 0...10_000 {
      if throttle.shouldReport(bytes: Int64(byte), expected: 10_000, now: Double(byte) / 1000) {
        callbacks += 1
      }
    }
    #expect(callbacks <= 102)
    let duplicate = throttle.shouldReport(bytes: 10_000, expected: 10_000, now: 11)
    let changedTotal = throttle.shouldReport(bytes: 10_001, expected: -1, now: 11.001)
    let completed = throttle.shouldReport(bytes: 10_001, expected: 10_001, now: 11.002)
    #expect(!duplicate)
    #expect(changedTotal)
    #expect(completed)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_BENCHMARKS"] == "1"))
  func catalogWarmCacheBenchmark() async throws {
    let directory = try networkDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("geofabrik-index.json")
    try catalogFixture(1000).write(to: cache)
    let client = Geofabrik(directory: directory)
    _ = try await client.regions()
    let clock = ContinuousClock()
    let iterations = 30
    var decodedCount = 0
    var cachedCount = 0
    let decode = try clock.measure {
      for _ in 0..<iterations {
        decodedCount += try Geofabrik.decodeCatalog(Data(contentsOf: cache)).count
      }
    }
    let start = clock.now
    for _ in 0..<iterations { cachedCount += try await client.regions().count }
    let reused = start.duration(to: clock.now)
    #expect(decodedCount == iterations * 1000)
    #expect(cachedCount == decodedCount)
    print(
      "Geofabrik catalog (1000 regions × \(iterations)): disk/decode/sort \(decode), memory reuse \(reused)"
    )
  }
}
