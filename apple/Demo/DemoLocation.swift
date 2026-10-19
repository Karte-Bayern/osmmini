import CoreLocation
import Foundation
import OSMmini
import Observation

@MainActor @Observable final class DemoLocation {
  enum Authorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
  }

  enum State: Equatable {
    case idle, requestingPermission, locating, ready, stale, timedOut, denied, restricted, disabled
    case unavailable, failed
  }

  struct Fix: Sendable {
    let coordinate: Coordinate
    let horizontalAccuracy: Double
    let timestamp: Date
  }

  enum Event: Sendable {
    case authorization(Authorization, servicesEnabled: Bool, precise: Bool)
    case fix(Fix)
    case temporarilyUnavailable, denied, failed
  }

  typealias DriverFactory =
    @MainActor (@escaping @MainActor @Sendable (Event) -> Void) -> any DemoLocationDriver

  private(set) var coordinate: Coordinate?
  private(set) var horizontalAccuracy: Double?
  private(set) var authorization = Authorization.notDetermined
  private(set) var hasPreciseLocation = true
  private(set) var state = State.idle
  private(set) var isUpdating = false
  var isLocating: Bool { state == .requestingPermission || (isUpdating && coordinate == nil) }
  var status: String {
    switch state {
    case .idle: return "Standort ist ausgeschaltet."
    case .requestingPermission:
      return "Standortzugriff erlauben, um die eigene Position anzuzeigen."
    case .locating: return "Aktueller Standort wird ermittelt …"
    case .ready:
      if let horizontalAccuracy {
        let accuracy = horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))
        return hasPreciseLocation
          ? "Standortgenauigkeit: etwa \(accuracy) m."
          : "Ungefährer Standort: etwa \(accuracy) m. Genauen Standort in den Einstellungen erlauben."
      }
      return "Standort gefunden."
    case .stale: return "Standort ist veraltet. Warte auf eine aktuelle Position …"
    case .timedOut: return "Noch kein aktueller Standort. Unter freiem Himmel erneut versuchen."
    case .denied: return "Standortzugriff ist nicht erlaubt. In den App-Einstellungen freigeben."
    case .restricted: return "Standortzugriff ist auf diesem Gerät eingeschränkt."
    case .disabled:
      return "Ortungsdienste sind ausgeschaltet. In den Systemeinstellungen aktivieren."
    case .unavailable: return "Standort vorübergehend nicht verfügbar. Suche läuft weiter …"
    case .failed: return "Standort konnte nicht bestimmt werden. Erneut versuchen."
    }
  }
  var error: String? {
    switch state {
    case .timedOut, .denied, .restricted, .disabled, .failed: return status
    default: return nil
    }
  }

  @ObservationIgnored private var driver: (any DemoLocationDriver)?
  @ObservationIgnored private var session: UUID?
  @ObservationIgnored private var requestedAuthorization = false
  @ObservationIgnored private var fixTimestamp: Date?
  @ObservationIgnored private var minimumFixTimestamp: Date?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored private let driverFactory: DriverFactory
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  private let firstFixTimeout: Duration
  private let maximumFixAge: TimeInterval

  init(
    firstFixTimeout: Duration = .seconds(60), maximumFixAge: TimeInterval = 30,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    driverFactory: @escaping DriverFactory = { DemoCoreLocationDriver(receive: $0) }
  ) {
    self.firstFixTimeout = firstFixTimeout
    self.maximumFixAge = max(1, maximumFixAge)
    self.now = now
    self.sleep = sleep
    self.driverFactory = driverFactory
  }

  // Creating a manager and asking for permission happen only after this user action.
  func start() {
    guard session == nil else { return }
    let id = UUID()
    session = id
    requestedAuthorization = false
    minimumFixTimestamp = nil
    clearFix()
    state = .requestingPermission
    let driver = driverFactory { [weak self] event in self?.receive(event, session: id) }
    self.driver = driver
    driver.checkAuthorization()
  }

  func stop() {
    finish()
    state = .idle
  }

  private func receive(_ event: Event, session id: UUID) {
    guard session == id else { return }
    switch event {
    case .authorization(let authorization, let servicesEnabled, let precise):
      let precisionWasReduced = hasPreciseLocation && !precise
      self.authorization = authorization
      hasPreciseLocation = precise
      guard servicesEnabled else {
        finish()
        state = .disabled
        return
      }
      switch authorization {
      case .notDetermined:
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        state = .requestingPermission
        driver?.requestAuthorization()
      case .authorized:
        if isUpdating {
          guard precisionWasReduced else { return }
          // Do not keep presenting a precise fix after the user limits our access.
          // Wait for a replacement at the currently authorized accuracy instead.
          expiryTask?.cancel()
          expiryTask = nil
          minimumFixTimestamp = now()
          clearFix()
          state = .locating
          beginTimeout(session: id)
          return
        }
        isUpdating = true
        state = .locating
        driver?.startUpdating()
        beginTimeout(session: id)
      case .denied:
        finish()
        state = .denied
      case .restricted:
        finish()
        state = .restricted
      }
    case .fix(let fix):
      guard isUpdating else { return }
      // Delegate callbacks can be queued before a precision change reaches us.
      // Clearing the visible fix must not make an older precise fix usable again.
      if let minimumFixTimestamp, fix.timestamp < minimumFixTimestamp { return }
      let age = now().timeIntervalSince(fix.timestamp)
      guard fix.coordinate.lat.isFinite, fix.coordinate.lon.isFinite,
        (-90...90).contains(fix.coordinate.lat), (-180...180).contains(fix.coordinate.lon),
        fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0, age >= -5
      else { return }
      guard age <= maximumFixAge else {
        if coordinate == nil { state = .stale }
        return
      }
      if let fixTimestamp, fix.timestamp < fixTimestamp { return }
      coordinate = fix.coordinate
      horizontalAccuracy = fix.horizontalAccuracy
      fixTimestamp = fix.timestamp
      state = .ready
      timeoutTask?.cancel()
      timeoutTask = nil
      expiryTask?.cancel()
      let sleep = sleep
      let remainingAge = max(0, maximumFixAge - age)
      expiryTask = Task { [weak self] in
        do {
          try await sleep(.seconds(remainingAge))
          try Task.checkCancellation()
          guard let self, self.session == id, self.fixTimestamp == fix.timestamp else { return }
          self.clearFix()
          self.state = .stale
          self.expiryTask = nil
        } catch {}
      }
    case .temporarilyUnavailable:
      if coordinate == nil, isUpdating { state = .unavailable }
    case .denied:
      authorization = .denied
      finish()
      state = .denied
    case .failed:
      finish()
      state = .failed
    }
  }

  private func beginTimeout(session id: UUID) {
    timeoutTask?.cancel()
    let sleep = sleep
    let duration = firstFixTimeout
    timeoutTask = Task { [weak self] in
      do {
        try await sleep(duration)
        try Task.checkCancellation()
        guard let self, self.session == id, self.coordinate == nil else { return }
        self.finish()
        self.state = .timedOut
      } catch {}
    }
  }

  private func clearFix() {
    coordinate = nil
    horizontalAccuracy = nil
    fixTimestamp = nil
  }

  private func finish() {
    // Invalidate the session before stopping: queued delegate callbacks are ignored.
    session = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    expiryTask?.cancel()
    expiryTask = nil
    driver?.stop()
    driver = nil
    isUpdating = false
    minimumFixTimestamp = nil
    clearFix()
  }
}

@MainActor protocol DemoLocationDriver: AnyObject {
  func checkAuthorization()
  func requestAuthorization()
  func startUpdating()
  func stop()
}

@MainActor
private final class DemoCoreLocationDriver: NSObject, CLLocationManagerDelegate, DemoLocationDriver
{
  private let manager = CLLocationManager()
  private let receive: @MainActor @Sendable (DemoLocation.Event) -> Void
  private var authorizationTask: Task<Void, Never>?
  private var authorizationRevision = 0
  private var stopped = false

  init(receive: @escaping @MainActor @Sendable (DemoLocation.Event) -> Void) {
    self.receive = receive
    super.init()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    // Keep an unchanged but current position fresh while the foreground map uses it.
    manager.distanceFilter = kCLDistanceFilterNone
    manager.pausesLocationUpdatesAutomatically = false
    manager.delegate = self
  }

  func checkAuthorization() {
    authorizationTask?.cancel()
    authorizationRevision += 1
    let revision = authorizationRevision
    let authorization: DemoLocation.Authorization
    switch manager.authorizationStatus {
    case .notDetermined: authorization = .notDetermined
    case .authorizedAlways, .authorizedWhenInUse: authorization = .authorized
    case .denied: authorization = .denied
    case .restricted: authorization = .restricted
    @unknown default: authorization = .restricted
    }
    let precise = manager.accuracyAuthorization == .fullAccuracy
    // Core Location's global availability query can block; keep it off the main actor.
    let availability = Task.detached(priority: .utility) {
      CLLocationManager.locationServicesEnabled()
    }
    authorizationTask = Task { [weak self] in
      let enabled = await availability.value
      guard !Task.isCancelled, let self, !self.stopped,
        self.authorizationRevision == revision
      else { return }
      self.receive(.authorization(authorization, servicesEnabled: enabled, precise: precise))
    }
  }

  func requestAuthorization() { manager.requestWhenInUseAuthorization() }
  func startUpdating() { manager.startUpdatingLocation() }

  func stop() {
    stopped = true
    authorizationTask?.cancel()
    authorizationTask = nil
    manager.stopUpdatingLocation()
    manager.delegate = nil
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in
      guard let self, !self.stopped else { return }
      self.checkAuthorization()
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    let fixes = locations.map {
      DemoLocation.Fix(
        coordinate: Coordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude),
        horizontalAccuracy: $0.horizontalAccuracy, timestamp: $0.timestamp)
    }
    Task { @MainActor [weak self] in
      guard let self, !self.stopped else { return }
      for fix in fixes { self.receive(.fix(fix)) }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    let event: DemoLocation.Event
    if let error = error as? CLError {
      switch error.code {
      case .denied: event = .denied
      case .locationUnknown, .network: event = .temporarilyUnavailable
      default: event = .failed
      }
    } else {
      event = .failed
    }
    Task { @MainActor [weak self] in
      guard let self, !self.stopped else { return }
      self.receive(event)
    }
  }
}
