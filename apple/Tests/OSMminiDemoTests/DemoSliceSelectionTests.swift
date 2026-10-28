import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

@MainActor private final class SliceLocationDriver: DemoLocationDriver {
  let receive: @MainActor @Sendable (DemoLocation.Event) -> Void
  var checks = 0
  var requests = 0
  var starts = 0
  var stops = 0
  var onCheck: (() -> Void)?
  var onStart: (() -> Void)?

  init(receive: @escaping @MainActor @Sendable (DemoLocation.Event) -> Void) {
    self.receive = receive
  }

  func checkAuthorization() {
    checks += 1
    onCheck?()
  }
  func requestAuthorization() { requests += 1 }
  func startUpdating() {
    starts += 1
    onStart?()
  }
  func stop() { stops += 1 }
  func authorize(
    _ authorization: DemoLocation.Authorization = .authorized, enabled: Bool = true,
    precise: Bool = true
  ) {
    receive(.authorization(authorization, servicesEnabled: enabled, precise: precise))
  }
}

private actor SliceLocationSleepGate {
  private var waiters: [CheckedContinuation<Void, any Error>] = []

  func sleep() async throws {
    try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func waitForSleepers(_ count: Int) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while waiters.count < count, clock.now < deadline { await Task.yield() }
    #expect(waiters.count >= count)
  }

  func releaseAll() {
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

@MainActor @Suite(.serialized) struct DemoSliceSelectionTests {
  private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

  private func fix(
    _ coordinate: Coordinate = Coordinate(lat: 48.75, lon: 12.96), accuracy: Double = 8,
    age: TimeInterval = 0
  ) -> DemoLocation.Event {
    .fix(DemoLocation.Fix(
      coordinate: coordinate, horizontalAccuracy: accuracy,
      timestamp: timestamp.addingTimeInterval(-age)))
  }

  @Test func radiusChoicesAndPermissionRequestsRequireAnExplicitAction() {
    var drivers: [SliceLocationDriver] = []
    let selection = DemoSliceSelection(location: DemoLocation(driverFactory: { receive in
      let driver = SliceLocationDriver(receive: receive)
      drivers.append(driver)
      return driver
    }))
    #expect(DemoSliceSelection.Radius.allCases.map(\.rawValue) == [30, 60, 90, 120, 150])
    #expect(DemoSliceSelection.Radius(rawValue: 45) == nil)
    #expect(selection.radiusKM == 30)
    #expect(selection.coordinate == nil)
    #expect(drivers.isEmpty)
    selection.requestLocation()
    selection.requestLocation()
    #expect(drivers.count == 1)
    #expect(drivers[0].checks == 1)
    drivers[0].authorize(.notDetermined)
    #expect(drivers[0].requests == 1)
    #expect(selection.isLocating)
    selection.stopLocating()
    #expect(drivers[0].stops == 1)
    #expect(!selection.isLocating)
  }

  @Test func capturedCenterSurvivesTheLocationExpiryAndQueuedCallbacks() async throws {
    let gate = SliceLocationSleepGate()
    var driver: SliceLocationDriver?
    let timestamp = timestamp
    let selection = DemoSliceSelection(location: DemoLocation(
      now: { timestamp }, sleep: { _ in try await gate.sleep() },
      driverFactory: { receive in
        let value = SliceLocationDriver(receive: receive)
        driver = value
        return value
      }))
    selection.requestLocation()
    let active = try #require(driver)
    active.authorize(precise: false)
    try await gate.waitForSleepers(1)
    active.receive(fix(accuracy: 1_500, age: 60))
    selection.captureLocationIfReady()
    #expect(selection.coordinate == nil)
    active.receive(fix(accuracy: 1_500))
    try await gate.waitForSleepers(2)
    selection.captureLocationIfReady()
    #expect(selection.coordinate == Coordinate(lat: 48.75, lon: 12.96))
    #expect(selection.horizontalAccuracy == 1_500)
    #expect(!selection.hasPreciseLocation)
    #expect(selection.status.contains("Ungefährer Standort"))
    #expect(selection.location.coordinate == nil)
    #expect(!selection.isLocating)
    #expect(active.stops == 1)

    await gate.releaseAll()
    for _ in 0..<100 { await Task.yield() }
    active.receive(fix(Coordinate(lat: 49, lon: 13)))
    selection.captureLocationIfReady()
    selection.radius = .km150
    selection.stopLocating()
    #expect(selection.radiusKM == 150)
    #expect(selection.coordinate == Coordinate(lat: 48.75, lon: 12.96))
    #expect(selection.horizontalAccuracy == 1_500)
  }

  @Test func aSynchronouslyDeliveredFixIsCapturedBeforeTheRequestReturns() throws {
    var driver: SliceLocationDriver?
    let sample = fix()
    let timestamp = timestamp
    let selection = DemoSliceSelection(location: DemoLocation(
      now: { timestamp }, driverFactory: { receive in
        let value = SliceLocationDriver(receive: receive)
        value.onCheck = { [weak value] in value?.authorize() }
        value.onStart = { [weak value] in value?.receive(sample) }
        driver = value
        return value
      }))
    selection.requestLocation()
    #expect(selection.coordinate == Coordinate(lat: 48.75, lon: 12.96))
    #expect(!selection.isLocating)
    #expect(driver?.stops == 1)
    selection.captureLocationIfReady()
    #expect(driver?.stops == 1)
  }

  @Test func failedRequestsRemainActionableAndRetryReplacesThePreviousRequest() throws {
    for (authorization, enabled) in [
      (DemoLocation.Authorization.denied, true), (.restricted, true), (.authorized, false),
    ] {
      var drivers: [SliceLocationDriver] = []
      let timestamp = timestamp
      let selection = DemoSliceSelection(location: DemoLocation(
        now: { timestamp }, driverFactory: { receive in
          let value = SliceLocationDriver(receive: receive)
          drivers.append(value)
          return value
        }))
      selection.requestLocation()
      drivers[0].authorize(authorization, enabled: enabled)
      selection.captureLocationIfReady()
      #expect(selection.error != nil)
      #expect(selection.coordinate == nil)
      #expect(!selection.isLocating)
      #expect(drivers.count == 1)
      selection.requestLocation()
      #expect(drivers.count == 2)
      #expect(selection.error == nil)
      drivers[0].receive(fix())
      selection.captureLocationIfReady()
      #expect(selection.coordinate == nil)
      drivers[1].authorize()
      drivers[1].receive(fix())
      selection.captureLocationIfReady()
      #expect(selection.coordinate != nil)
      #expect(selection.error == nil)
      #expect(drivers[1].stops == 1)
    }
  }

  @Test func stoppingAnExtractRequestLeavesTheMapLocationSessionRunning() throws {
    var mapDriver: SliceLocationDriver?
    let map = DemoLocation(driverFactory: { receive in
      let value = SliceLocationDriver(receive: receive)
      mapDriver = value
      return value
    })
    var extractDriver: SliceLocationDriver?
    let selection = DemoSliceSelection(location: DemoLocation(driverFactory: { receive in
      let value = SliceLocationDriver(receive: receive)
      extractDriver = value
      return value
    }))
    map.start()
    try #require(mapDriver).authorize()
    selection.requestLocation()
    try #require(extractDriver).authorize()
    selection.stopLocating()
    #expect(extractDriver?.stops == 1)
    #expect(mapDriver?.stops == 0)
    #expect(map.isUpdating)
    #expect(selection.coordinate == nil)
    map.stop()
  }

  @Test func anUnavailableFixCanTimeOutWithoutSelectingACenter() async throws {
    let gate = SliceLocationSleepGate()
    var driver: SliceLocationDriver?
    let selection = DemoSliceSelection(location: DemoLocation(
      sleep: { _ in try await gate.sleep() }, driverFactory: { receive in
        let value = SliceLocationDriver(receive: receive)
        driver = value
        return value
      }))
    selection.requestLocation()
    let active = try #require(driver)
    active.authorize()
    try await gate.waitForSleepers(1)
    active.receive(.temporarilyUnavailable)
    #expect(selection.isLocating)
    #expect(selection.error == nil)
    await gate.releaseAll()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while selection.isLocating, clock.now < deadline { await Task.yield() }
    selection.captureLocationIfReady()
    #expect(selection.location.state == .timedOut)
    #expect(selection.coordinate == nil)
    #expect(selection.error != nil)
    #expect(!selection.isLocating)
    #expect(active.stops == 1)
    selection.stopLocating()
  }
}
