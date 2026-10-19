import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

@MainActor private final class FakeLocationDriver: DemoLocationDriver {
  var checks = 0
  var requests = 0
  var starts = 0
  var stops = 0
  let receive: @MainActor @Sendable (DemoLocation.Event) -> Void

  init(receive: @escaping @MainActor @Sendable (DemoLocation.Event) -> Void) {
    self.receive = receive
  }

  func checkAuthorization() { checks += 1 }
  func requestAuthorization() { requests += 1 }
  func startUpdating() { starts += 1 }
  func stop() { stops += 1 }
  func authorize(
    _ authorization: DemoLocation.Authorization = .authorized,
    enabled: Bool = true, precise: Bool = true
  ) {
    receive(.authorization(authorization, servicesEnabled: enabled, precise: precise))
  }
}

private actor LocationSleepGate {
  private var waiters: [CheckedContinuation<Void, Error>] = []

  func sleep(_ duration: Duration) async throws {
    try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func waitForSleepers(_ count: Int) async {
    while waiters.count < count { await Task.yield() }
  }

  func release(_ count: Int? = nil) {
    let count = min(count ?? waiters.count, waiters.count)
    let released = Array(waiters.prefix(count))
    waiters.removeFirst(count)
    for waiter in released { waiter.resume() }
  }
}

@MainActor @Suite(.serialized) struct DemoLocationTests {
  private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

  private func fix(
    age: TimeInterval = 0, accuracy: Double = 8,
    coordinate: Coordinate = Coordinate(lat: 48.75, lon: 12.96)
  ) -> DemoLocation.Event {
    .fix(
      DemoLocation.Fix(
        coordinate: coordinate, horizontalAccuracy: accuracy,
        timestamp: timestamp.addingTimeInterval(-age)))
  }

  private func flush() async {
    for _ in 0..<100 { await Task.yield() }
  }

  @Test func permissionIsRequestedOnlyAfterStartAndOnlyOncePerSession() {
    var drivers: [FakeLocationDriver] = []
    let location = DemoLocation(driverFactory: { receive in
      let driver = FakeLocationDriver(receive: receive)
      drivers.append(driver)
      return driver
    })
    #expect(drivers.isEmpty)
    #expect(location.coordinate == nil)
    #expect(!location.isLocating)
    location.start()
    location.start()
    #expect(drivers.count == 1)
    let driver = drivers[0]
    #expect(driver.checks == 1)
    #expect(driver.requests == 0)
    driver.authorize(.notDetermined)
    driver.authorize(.notDetermined)
    #expect(driver.requests == 1)
    #expect(driver.starts == 0)
    #expect(location.isLocating)
    driver.authorize()
    driver.authorize()
    #expect(driver.starts == 1)
    #expect(location.isUpdating)
    location.stop()
    #expect(driver.stops == 1)
    #expect(!location.isUpdating)
  }

  @Test func deniedRestrictedAndDisabledServicesExplainTheProblemWithoutRequestingAgain() {
    for (authorization, enabled, expected) in [
      (DemoLocation.Authorization.denied, true, DemoLocation.State.denied),
      (.restricted, true, .restricted),
      (.authorized, false, .disabled),
    ] {
      var driver: FakeLocationDriver?
      let location = DemoLocation(driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
      location.start()
      driver?.authorize(authorization, enabled: enabled)
      #expect(location.state == expected)
      #expect(location.error != nil)
      #expect(!location.isUpdating)
      #expect(!location.isLocating)
      #expect(driver?.requests == 0)
      #expect(driver?.starts == 0)
      #expect(driver?.stops == 1)
    }
  }

  @Test func invalidStaleFutureAndOutOfOrderFixesCannotReplaceTheCurrentLocation() {
    var driver: FakeLocationDriver?
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp },
      driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
    location.start()
    driver?.authorize()
    for invalid in [
      fix(accuracy: -1), fix(accuracy: .infinity), fix(age: -60),
      fix(coordinate: Coordinate(lat: .nan, lon: 12)),
      fix(coordinate: Coordinate(lat: 91, lon: 12)),
      fix(coordinate: Coordinate(lat: 48, lon: -181)),
    ] {
      driver?.receive(invalid)
      #expect(location.coordinate == nil)
    }
    driver?.receive(fix(age: 60))
    #expect(location.state == .stale)
    #expect(location.coordinate == nil)
    driver?.receive(fix())
    #expect(location.coordinate == Coordinate(lat: 48.75, lon: 12.96))
    #expect(location.horizontalAccuracy == 8)
    #expect(location.state == .ready)
    driver?.receive(fix(age: 2, coordinate: Coordinate(lat: 49, lon: 13)))
    driver?.receive(fix(age: 60))
    #expect(location.coordinate == Coordinate(lat: 48.75, lon: 12.96))
    #expect(location.state == .ready)
    location.stop()
    #expect(location.coordinate == nil)
    #expect(location.horizontalAccuracy == nil)
  }

  @Test func approximateFixIsUsableAndReportedWithoutDemandingAnotherPermission() {
    var driver: FakeLocationDriver?
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp },
      driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
    location.start()
    driver?.authorize(precise: false)
    driver?.receive(fix(accuracy: 1_500))
    #expect(location.coordinate != nil)
    #expect(!location.hasPreciseLocation)
    #expect(location.status.contains("Ungefährer Standort"))
    #expect(location.error == nil)
    #expect(driver?.requests == 0)
    location.stop()
  }

  @Test func reducingPrecisionHidesThePreviousFixAndWaitsForAnApproximateReplacement() async {
    let gate = LocationSleepGate()
    var driver: FakeLocationDriver?
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp }, sleep: { try await gate.sleep($0) },
      driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
    location.start()
    driver?.authorize()
    await gate.waitForSleepers(1)
    driver?.receive(fix())
    await gate.waitForSleepers(2)

    driver?.authorize(precise: false)
    await gate.waitForSleepers(3)
    #expect(!location.hasPreciseLocation)
    #expect(location.coordinate == nil)
    #expect(location.horizontalAccuracy == nil)
    #expect(location.state == .locating)
    #expect(location.isUpdating)
    #expect(driver?.starts == 1)
    #expect(driver?.requests == 0)

    // Cancelled timers for the precise fix cannot clear or stop the new request.
    await gate.release(2)
    await flush()
    #expect(location.state == .locating)
    #expect(location.isUpdating)
    // A still-fresh precise fix may have been queued before authorization changed.
    // It must not restore the precise marker while we wait for a replacement.
    driver?.receive(fix(age: 1, accuracy: 4))
    #expect(location.coordinate == nil)
    #expect(location.horizontalAccuracy == nil)
    #expect(location.state == .locating)
    driver?.receive(fix(accuracy: 1_500, coordinate: Coordinate(lat: 48.8, lon: 13)))
    await gate.waitForSleepers(2)
    #expect(location.state == .ready)
    #expect(location.horizontalAccuracy == 1_500)
    driver?.authorize(precise: false)
    #expect(location.coordinate == Coordinate(lat: 48.8, lon: 13))
    #expect(location.status.contains("Ungefährer Standort"))

    location.stop()
    await flush()
    await gate.release()
  }

  @Test func replacementFixAfterPrecisionReductionHasItsOwnTimeout() async {
    let gate = LocationSleepGate()
    var driver: FakeLocationDriver?
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp }, sleep: { try await gate.sleep($0) },
      driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
    location.start()
    driver?.authorize()
    await gate.waitForSleepers(1)
    driver?.receive(fix())
    await gate.waitForSleepers(2)
    driver?.authorize(precise: false)
    await gate.waitForSleepers(3)
    await gate.release(2)
    await flush()
    #expect(location.state == .locating)
    await gate.release()
    await flush()
    #expect(location.state == .timedOut)
    #expect(!location.isUpdating)
    #expect(location.coordinate == nil)
    #expect(driver?.stops == 1)
  }

  @Test func transientFailureContinuesSearchingAndFirstFixTimeoutCanBeRetried() async {
    let gate = LocationSleepGate()
    var drivers: [FakeLocationDriver] = []
    let location = DemoLocation(
      sleep: { try await gate.sleep($0) },
      driverFactory: { receive in
        let driver = FakeLocationDriver(receive: receive)
        drivers.append(driver)
        return driver
      })
    location.start()
    drivers[0].authorize()
    drivers[0].receive(.temporarilyUnavailable)
    #expect(location.state == .unavailable)
    #expect(location.isUpdating)
    await gate.waitForSleepers(1)
    await gate.release()
    await flush()
    #expect(location.state == .timedOut)
    #expect(!location.isUpdating)
    #expect(drivers[0].stops == 1)
    location.start()
    #expect(drivers.count == 2)
    #expect(location.isLocating)
    location.stop()
  }

  @Test func cancelledSessionCannotPublishLateFixPermissionErrorOrTimeout() async {
    let gate = LocationSleepGate()
    var drivers: [FakeLocationDriver] = []
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp }, sleep: { try await gate.sleep($0) },
      driverFactory: { receive in
        let driver = FakeLocationDriver(receive: receive)
        drivers.append(driver)
        return driver
      })
    location.start()
    let old = drivers[0]
    old.authorize()
    await gate.waitForSleepers(1)
    location.stop()
    location.start()
    let current = drivers[1]
    current.authorize()
    old.receive(fix())
    old.authorize(.denied)
    old.receive(.failed)
    await gate.release(1)
    await flush()
    #expect(location.state == .locating)
    #expect(location.authorization == .authorized)
    #expect(location.coordinate == nil)
    #expect(current.stops == 0)
    location.stop()
    await flush()
    await gate.release()
  }

  @Test func expiredFixIsHiddenAndOlderExpiryCannotClearANewerFix() async {
    let gate = LocationSleepGate()
    var driver: FakeLocationDriver?
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp }, sleep: { try await gate.sleep($0) },
      driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
    location.start()
    driver?.authorize()
    await gate.waitForSleepers(1)
    driver?.receive(fix(age: 1))
    await gate.waitForSleepers(2)
    driver?.receive(fix())
    await gate.waitForSleepers(3)
    await gate.release(2)
    await flush()
    #expect(location.state == .ready)
    #expect(location.coordinate != nil)
    await gate.release()
    await flush()
    #expect(location.state == .stale)
    #expect(location.coordinate == nil)
    #expect(location.horizontalAccuracy == nil)
    #expect(location.isUpdating)
    driver?.receive(fix())
    #expect(location.state == .ready)
    location.stop()
    await flush()
    await gate.release()
  }

  @Test func permissionRevocationClearsTheVisibleFixAndStopsUpdates() {
    var driver: FakeLocationDriver?
    let timestamp = timestamp
    let location = DemoLocation(
      now: { timestamp },
      driverFactory: { receive in
        let value = FakeLocationDriver(receive: receive)
        driver = value
        return value
      })
    location.start()
    driver?.authorize()
    driver?.receive(fix())
    #expect(location.coordinate != nil)
    driver?.receive(.denied)
    #expect(location.authorization == .denied)
    #expect(location.state == .denied)
    #expect(location.coordinate == nil)
    #expect(!location.isUpdating)
    #expect(driver?.stops == 1)
  }

  @Test func authorizationChangesClearTheVisibleFixForRevokedOrDisabledServices() {
    let timestamp = timestamp
    for (authorization, enabled, expected) in [
      (DemoLocation.Authorization.denied, true, DemoLocation.State.denied),
      (.restricted, true, .restricted),
      (.authorized, false, .disabled),
    ] {
      var driver: FakeLocationDriver?
      let location = DemoLocation(
        now: { timestamp },
        driverFactory: { receive in
          let value = FakeLocationDriver(receive: receive)
          driver = value
          return value
        })
      location.start()
      driver?.authorize()
      driver?.receive(fix())
      #expect(location.coordinate != nil)
      driver?.authorize(authorization, enabled: enabled)
      #expect(location.state == expected)
      #expect(location.coordinate == nil)
      #expect(location.horizontalAccuracy == nil)
      #expect(!location.isUpdating)
      #expect(driver?.stops == 1)
    }
  }
}
