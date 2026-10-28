import Foundation
import Testing

@testable import OSMmini

private final class SliceURLProtocol: URLProtocol, @unchecked Sendable {
  struct Reply: Sendable {
    let status: Int
    let data: Data
    init(_ text: String, status: Int = 200) {
      self.status = status
      data = Data(text.utf8)
    }
  }

  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var received: [URLRequest] = []
    func configure(_ replies: [String: [Reply]]) {
      lock.lock()
      self.replies = replies
      received = []
      lock.unlock()
    }
    func respond(_ request: URLRequest) -> Reply {
      var captured = request
      if captured.httpBody == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = stream.read(&buffer, maxLength: buffer.count)
          guard count > 0 else { break }
          body.append(contentsOf: buffer.prefix(count))
        }
        captured.httpBody = body
      }
      lock.lock()
      defer { lock.unlock() }
      received.append(captured)
      let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
      guard var values = replies[key], !values.isEmpty else {
        return Reply("unexpected request", status: 500)
      }
      let response = values.removeFirst()
      replies[key] = values
      return response
    }
    var requests: [URLRequest] {
      lock.lock()
      defer { lock.unlock() }
      return received
    }
  }

  static let state = State()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let reply = Self.state.respond(request)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "\(reply.data.count)"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SliceURLProtocol.self]
    configuration.urlCache = nil
    return configuration
  }
}

private final class SliceProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SliceOSMProgress] = []
  func receive(_ value: SliceOSMProgress) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
  var all: [SliceOSMProgress] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private final class SliceTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_000_000)
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    value.addTimeInterval(seconds)
    lock.unlock()
  }
  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@Suite(.serialized) struct SliceOSMTests {
  private let center = Coordinate(lat: 48.5, lon: 12.5)
  private let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  private var pending: String { #"{"Complete":false,"ElemsProg":25,"ElemsTotal":100}"# }
  private var completed: String { #"{"Complete":true,"SizeBytes":11}"# }
  private var payload: String { "PBF fixture" }

  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func client(
    _ directory: URL, maximumPolls: Int = 3,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> (SliceOSM, URLSession) {
    let session = URLSession(configuration: SliceURLProtocol.configuration())
    return (SliceOSM(
      directory: directory, session: session,
      downloadConfiguration: { SliceURLProtocol.configuration() }, sleep: sleep,
      now: now, maximumPolls: maximumPolls), session)
  }

  @Test func submitsOneGeoJSONCirclePollsAndDownloadsTheExactResultURL() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    SliceURLProtocol.state.configure([
      "POST /api": [.init(id, status: 201)],
      "GET /api/\(id)": [.init(pending), .init(completed)],
      "GET /files/\(id).osm.pbf": [.init(payload)],
    ])
    let (client, session) = client(directory)
    defer { session.invalidateAndCancel() }
    let progress = SliceProgressRecorder()
    let file = try await client.download(center: center, radiusKM: 30, name: "Umkreis") {
      progress.receive($0)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == payload)
    let requests = SliceURLProtocol.state.requests
    #expect(requests.map { $0.httpMethod! } == ["POST", "GET", "GET", "GET"])
    #expect(requests.allSatisfy { $0.url?.host == "slice.openstreetmap.us" })
    let data = try #require(requests.first?.httpBody)
    let input = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(input["RegionType"] as? String == "geojson")
    #expect(input["Name"] as? String == "Umkreis")
    let geometry = try #require(input["RegionData"] as? [String: Any])
    let rings = try #require(geometry["coordinates"] as? [[[Double]]])
    #expect(geometry["type"] as? String == "Polygon")
    #expect(rings.count == 1)
    #expect(rings[0].count == 73)
    #expect(rings[0].first == rings[0].last)
    #expect(abs(rings[0][0][0] - center.lon) < 0.000_001)
    #expect(rings[0][0][1] > center.lat)
    #expect(progress.all.contains {
      if case .preparing(let fraction) = $0 { return fraction == 0.25 }
      return false
    })
    #expect(progress.all.contains {
      if case .downloading(let bytes, let total) = $0 { return bytes == 11 && total == 11 }
      return false
    })
    let count = requests.count
    _ = try await client.download(center: center, radiusKM: 30, name: "Anderer Name")
    #expect(SliceURLProtocol.state.requests.count == count)
  }

  @Test func retryAfterTimeoutReusesThePersistedJobInAnotherClient() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    SliceURLProtocol.state.configure([
      "POST /api": [.init(id, status: 201)],
      "GET /api/\(id)": [.init(pending), .init(completed)],
      "GET /files/\(id).osm.pbf": [.init(payload)],
    ])
    let (first, firstSession) = client(directory, maximumPolls: 1)
    defer { firstSession.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
      try await first.download(center: center, radiusKM: 60, name: "Umkreis")
    }
    let (second, secondSession) = client(directory)
    defer { secondSession.invalidateAndCancel() }
    let file = try await second.download(center: center, radiusKM: 60, name: "Umkreis")
    #expect(try String(contentsOf: file, encoding: .utf8) == payload)
    #expect(SliceURLProtocol.state.requests.filter { $0.httpMethod == "POST" }.count == 1)
  }

  @Test func expiredJobFailsWithoutAutomaticallySubmittingAnotherExtract() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    SliceURLProtocol.state.configure([
      "POST /api": [.init(id, status: 201)],
      "GET /api/\(id)": [.init(pending), .init("expired", status: 404)],
    ])
    let (client, session) = client(directory, maximumPolls: 1)
    defer { session.invalidateAndCancel() }
    for _ in 0..<2 {
      await #expect(throws: (any Error).self) {
        try await client.download(center: center, radiusKM: 90, name: "Umkreis")
      }
    }
    #expect(SliceURLProtocol.state.requests.filter { $0.httpMethod == "POST" }.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func serviceLimitsMalformedRepliesAndOversizedResultsNeverDownload() async throws {
    for (create, state) in [
      (SliceURLProtocol.Reply("too large", status: 400), completed),
      (.init("busy", status: 503), completed),
      (.init("not-a-job", status: 201), completed),
      (.init(id, status: 201), #"{"Complete":true,"SizeBytes":2147483649}"#),
      (.init(id, status: 201), #"{"Complete":true,"SizeBytes":0}"#),
      (.init(id, status: 201), #"{"not":"a progress response"}"#),
    ] {
      let directory = try directory()
      defer { try? FileManager.default.removeItem(at: directory) }
      SliceURLProtocol.state.configure([
        "POST /api": [create], "GET /api/\(id)": [.init(state)],
      ])
      let (client, session) = client(directory)
      defer { session.invalidateAndCancel() }
      await #expect(throws: (any Error).self) {
        try await client.download(center: center, radiusKM: 120, name: "Umkreis")
      }
      #expect(!SliceURLProtocol.state.requests.contains { $0.url!.path.hasPrefix("/files/") })
    }
  }

  @Test func invalidGeometryDoesNotSendAnyLocationToTheServer() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    SliceURLProtocol.state.configure([:])
    let (client, session) = client(directory)
    defer { session.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
      try await client.download(center: Coordinate(lat: 90, lon: 0), radiusKM: 150, name: "Umkreis")
    }
    #expect(SliceURLProtocol.state.requests.isEmpty)
  }

  @Test func elapsedDeadlineStopsPollingEvenBeforeThePollCountLimit() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    SliceURLProtocol.state.configure([
      "POST /api": [.init(id, status: 201)], "GET /api/\(id)": [.init(pending)],
    ])
    let clock = SliceTestClock()
    let (client, session) = client(
      directory, maximumPolls: 360, sleep: { _ in clock.advance(1801) }, now: { clock.now() })
    defer { session.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
      try await client.download(center: center, radiusKM: 30, name: "Umkreis")
    }
    #expect(SliceURLProtocol.state.requests.count == 2)
  }

  @Test func anExplicitRequestAfterOneDayCreatesAFreshJobInsteadOfReusingExpiredData() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = SliceTestClock()
    SliceURLProtocol.state.configure([
      "POST /api": [.init(id, status: 201)],
      "GET /api/\(id)": [.init(completed)],
      "GET /files/\(id).osm.pbf": [.init(payload)],
    ])
    let (first, firstSession) = client(directory, now: { clock.now() })
    defer { firstSession.invalidateAndCancel() }
    let original = try await first.download(center: center, radiusKM: 30, name: "Umkreis")
    clock.advance(24 * 60 * 60 + 1)
    let nextID = "11111111-2222-4333-8444-555555555555"
    SliceURLProtocol.state.configure([
      "POST /api": [.init(nextID, status: 201)],
      "GET /api/\(nextID)": [.init(completed)],
      "GET /files/\(nextID).osm.pbf": [.init(payload)],
    ])
    let (second, secondSession) = client(directory, now: { clock.now() })
    defer { secondSession.invalidateAndCancel() }
    let refreshed = try await second.download(center: center, radiusKM: 30, name: "Umkreis")
    #expect(refreshed != original)
    #expect(SliceURLProtocol.state.requests.filter { $0.httpMethod == "POST" }.count == 1)
    #expect(try String(contentsOf: refreshed, encoding: .utf8) == payload)
  }

  @Test func apiRedirectsNeverReplayLocationBodies() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let original = SliceOSM.apiURL
    let task = session.dataTask(with: original)
    let response = try #require(HTTPURLResponse(
      url: original, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil))
    let recorder = SliceProgressRecorder()
    for target in [
      URL(string: "https://example.com/capture")!,
      URL(string: "http://slice.openstreetmap.us/api/")!,
      original,
    ] {
      SliceAPIRedirectPolicy().urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: target)
      ) { redirected in
        #expect(redirected == nil)
        recorder.receive(.preparing(fraction: nil))
      }
    }
    #expect(recorder.all.count == 3)
  }

  @Test func cancellationStopsPollingAndRetainsTheJobForAnExplicitRetry() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    SliceURLProtocol.state.configure([
      "POST /api": [.init(id, status: 201)], "GET /api/\(id)": [.init(pending)],
    ])
    let (client, session) = client(directory, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
    defer { session.invalidateAndCancel() }
    let task = Task { try await client.download(center: center, radiusKM: 150, name: "Umkreis") }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while SliceURLProtocol.state.requests.count < 2, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(SliceURLProtocol.state.requests.count == 2)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(SliceURLProtocol.state.requests.count == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
  }
}
