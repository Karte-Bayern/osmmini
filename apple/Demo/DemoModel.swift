import Foundation
import OSMmini
import Observation

typealias InstalledRegion = DemoStoredRegion

struct DemoPlace: Equatable, Sendable {
  let coordinate: Coordinate
  let name: String
  let category: String?
  let kind: String?

  init(coordinate: Coordinate, name: String, category: String?, kind: String? = nil) {
    self.coordinate = coordinate
    self.name = name
    self.category = category
    self.kind = kind
  }

  init(_ result: SearchResult) {
    self.init(
      coordinate: result.coordinate, name: result.label, category: result.category,
      kind: result.kind)
  }
}

struct DemoImportFailure: Codable, Sendable {
  let message: String
  let details: String
  let phase: String?
}

@MainActor @Observable final class DemoModel {
  enum Activity { case opening, downloading, importing, routing, deleting }
  enum RoutePoint { case start, destination }

  private(set) var engine: OfflineEngine?
  private(set) var activeDirectory: URL?
  private(set) var installed: [InstalledRegion] = []
  private(set) var storageError: String?
  private(set) var downloadBytes: Int64 = 0
  private(set) var regionError: String?
  private(set) var filteredRegions: [GeofabrikRegion] = []
  private(set) var catalogMatchCount = 0
  private(set) var catalogLoading = false
  private(set) var catalogLoaded = false
  private(set) var catalogError: String?
  var catalogQuery = "Niederbayern" { didSet { filterCatalog() } }
  var query = "" { didSet { search() } }
  private(set) var results: [SearchResult] = []
  private(set) var searching = false
  private(set) var searchError: String?
  private(set) var route: Route?
  private(set) var routeObjective: RouteObjective = .distance
  private(set) var start: Coordinate?
  private(set) var destination: Coordinate?
  private(set) var startLabel: String?
  private(set) var destinationLabel: String?
  private(set) var selectedRoutePoint = RoutePoint.start
  private(set) var routeError: String?
  private(set) var focus: Coordinate?
  private(set) var focusRequest: UUID?
  private(set) var inspectedPlace: DemoPlace?
  var routeSelectionHint: String {
    selectedRoutePoint == .start
      ? "Startpunkt auf der Karte oder in der Suche wählen."
      : "Zielpunkt auf der Karte oder in der Suche wählen."
  }
  var canCalculateRoute: Bool { !busy && engine != nil && start != nil && destination != nil }
  var canCancel: Bool { busy && activity != .deleting }
  var installedBytes: Int64 { installed.reduce(0) { $0 + $1.byteCount } }
  private(set) var status = "Region herunterladen oder eine lokale PBF importieren."
  private(set) var fraction: Double?
  private(set) var activity: Activity?
  private(set) var cancelling = false
  private(set) var pending: ImportOptions?
  private(set) var importFailure: DemoImportFailure?
  private(set) var lastImportPhase: String?
  var busy: Bool { activity != nil }

  @ObservationIgnored private(set) var operation: Task<Void, Never>?
  @ObservationIgnored private var operationID: UUID?
  @ObservationIgnored private var phaseID: UUID?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var searchID: UUID?
  @ObservationIgnored private var searchNeedsResume = false
  @ObservationIgnored private var searchPresentations: Set<UUID> = []
  @ObservationIgnored private var installedID: UUID?
  @ObservationIgnored private var regions: [GeofabrikRegion] = []
  @ObservationIgnored private var catalogByID: [String: GeofabrikRegion] = [:]
  @ObservationIgnored private var started = false
  let root: URL
  let geofabrik: Geofabrik
  private let defaults: UserDefaults

  init(root: URL? = nil, defaults: UserDefaults = .standard, geofabrik: Geofabrik? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    self.root =
      root
      ?? ProcessInfo.processInfo.environment["OSMMINI_DEMO_DIRECTORY"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? support.appendingPathComponent("OSMminiDemo", isDirectory: true)
    self.defaults = defaults
    if let raw = defaults.string(forKey: "routeObjective"),
      let objective = RouteObjective(rawValue: raw),
      objective == .distance || objective == .duration
    {
      routeObjective = objective
    }
    self.geofabrik =
      geofabrik
      ?? Geofabrik(directory: self.root.appendingPathComponent("downloads", isDirectory: true))
    if let data = defaults.data(forKey: "pendingImport") {
      if let saved = try? JSONDecoder().decode(ImportOptions.self, from: data) {
        pending = try? DemoStorage.restoredImport(saved, in: self.root)
      }
    }
    if pending != nil {
      lastImportPhase = defaults.string(forKey: "pendingImportPhase")
      if let data = defaults.data(forKey: "pendingImportFailure") {
        importFailure = try? JSONDecoder().decode(DemoImportFailure.self, from: data)
      }
    }
  }

  func start(arguments: [String] = CommandLine.arguments) async {
    guard !started else { return }
    started = true
    await refreshInstalled()
    let explicitRegion = arguments.firstIndex(of: "--region").flatMap {
      $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
    }
    let lastRegion = defaults.string(forKey: "lastRegion").flatMap {
      try? DemoStorage.restoredPath($0, in: root)
    }
    if let path = explicitRegion ?? lastRegion, engine == nil {
      openRegion(URL(fileURLWithPath: path))
      await operation?.value
    }
    // Reopening a local region needs no catalog request. The catalog can still
    // be loaded explicitly in the sidebar when choosing another region.
    if engine == nil, !arguments.contains("--offline") { await loadCatalog() }
  }

  func refreshInstalled() async {
    let id = UUID()
    installedID = id
    let root = root
    let scan = Task.detached(priority: .utility) {
      (try DemoStorage.regions(in: root), try DemoRegionStorage.downloadBytes(in: root))
    }
    do {
      let found = try await scan.value
      guard installedID == id else { return }
      installed = found.0
      downloadBytes = found.1
      storageError = nil
    } catch {
      guard installedID == id else { return }
      storageError = error.localizedDescription
    }
  }

  func loadCatalog(refresh: Bool = false) async {
    guard !catalogLoading else { return }
    catalogLoading = true
    catalogError = nil
    defer { catalogLoading = false }
    do {
      regions = try await geofabrik.regions(refresh: refresh)
      catalogByID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      catalogLoaded = true
      filterCatalog()
    } catch is CancellationError {} catch { catalogError = error.localizedDescription }
  }

  private func filterCatalog() {
    let words = Self.catalogWords(catalogQuery)
    let query = words.joined(separator: " ")
    let matches = regions.compactMap { region -> (GeofabrikRegion, Int)? in
      let name = Self.catalogWords(region.name).joined(separator: " ")
      let id = Self.catalogWords(region.id).joined(separator: " ")
      let context =
        name + " " + id + " "
        + Self.catalogWords(catalogContext(for: region)).joined(separator: " ")
      guard words.allSatisfy({ context.contains($0) }) else { return nil }
      let rank = !query.isEmpty && (name == query || id == query) ? 0 : 1
      return (region, rank)
    }.sorted {
      if $0.1 != $1.1 { return $0.1 < $1.1 }
      let order = $0.0.name.localizedStandardCompare($1.0.name)
      return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
    }
    catalogMatchCount = matches.count
    filteredRegions = matches.prefix(50).map(\.0)
  }

  func catalogContext(for region: GeofabrikRegion) -> String {
    var names: [String] = []
    var visited: Set<String> = [region.id]
    var parent = region.parent
    while let id = parent, names.count < 16, visited.insert(id).inserted,
      let ancestor = catalogByID[id]
    {
      names.append(ancestor.name)
      parent = ancestor.parent
    }
    return names.reversed().joined(separator: " · ")
  }

  private static func catalogWords(_ value: String) -> [String] {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  func run(
    _ activity: Activity, status: String,
    work: @escaping @MainActor (UUID) async throws -> Void
  ) {
    guard !busy else { return }
    let id = UUID()
    operationID = id
    self.activity = activity
    self.status = status
    fraction = nil
    cancelling = false
    if activity == .opening || activity == .deleting { regionError = nil }
    if activity == .importing || activity == .downloading {
      importFailure = nil
      defaults.removeObject(forKey: "pendingImportFailure")
    }
    operation = Task {
      do {
        try Task.checkCancellation()
        try await work(id)
      } catch {
        if Task.isCancelled || error is CancellationError {
          self.status =
            switch activity {
            case .routing: "Routenberechnung abgebrochen."
            case .opening: "Öffnen abgebrochen."
            default:
              "Abgebrochen. Downloads und abgeschlossene Importphasen können fortgesetzt werden."
            }
        } else {
          if activity == .routing {
            routeError = Self.routeErrorMessage(error)
            self.status = "Route nicht verfügbar. Punkte anpassen oder erneut versuchen."
          } else if activity == .importing || activity == .downloading {
            let message = error.localizedDescription
            let failure = DemoImportFailure(
              message: Self.importErrorMessage(error), details: message, phase: lastImportPhase)
            importFailure = failure
            self.status = failure.message
            if pending != nil, let data = try? JSONEncoder().encode(failure) {
              defaults.set(data, forKey: "pendingImportFailure")
            }
          } else {
            self.status = error.localizedDescription
            regionError = error.localizedDescription
          }
        }
      }
      operationID = nil
      phaseID = nil
      self.activity = nil
      fraction = nil
      cancelling = false
      operation = nil
      if activity == .importing || activity == .downloading || activity == .deleting {
        await refreshInstalled()
      }
    }
  }

  func cancel() {
    guard canCancel, !cancelling else { return }
    cancelling = true
    phaseID = nil
    operation?.cancel()
  }

  // A phase token also rejects queued download callbacks after import starts.
  func beginPhase(_ operation: UUID, status: String) -> UUID {
    let phase = UUID()
    if operationID == operation {
      phaseID = phase
      self.status = status
      fraction = nil
      recordImportPhase(status)
    }
    return phase
  }

  func receiveProgress(_ phase: UUID, fraction: Double?, status: String) {
    guard phaseID == phase, busy, !cancelling else { return }
    self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.status = status
    recordImportPhase(status)
  }

  private func recordImportPhase(_ phase: String) {
    guard pending != nil, lastImportPhase != phase,
      activity == .importing || activity == .downloading
    else { return }
    lastImportPhase = phase
    defaults.set(phase, forKey: "pendingImportPhase")
  }

  private func clearImportDiagnostics() {
    importFailure = nil
    lastImportPhase = nil
    defaults.removeObject(forKey: "pendingImportFailure")
    defaults.removeObject(forKey: "pendingImportPhase")
  }

  private static func importErrorMessage(_ error: any Error) -> String {
    let message = error.localizedDescription
    if let networkError = error as? URLError {
      switch networkError.code {
      case .notConnectedToInternet, .networkConnectionLost:
        return
          "Der Download benötigt eine Internetverbindung. Prüfe die Verbindung und versuche es erneut."
      case .timedOut:
        return "Der Download hat zu lange nicht geantwortet. Versuche es später erneut."
      default:
        return
          "Der Download konnte nicht abgeschlossen werden. Prüfe die Verbindung und versuche es erneut."
      }
    }
    if message == "Eine .osm.pbf-Datei auswählen." {
      return
        "Wähle eine Datei mit der Endung .osm.pbf. Andere Dateiformate können nicht importiert werden."
    }
    if message.hasPrefix("pending import belongs to another source/options/import version") {
      return
        "Dieser Importstand kann mit dieser Version nicht fortgesetzt werden. Wähle „Mit vorhandener PBF neu beginnen“."
    }
    if message.hasPrefix("open "), message.contains(".pbf: no such file or directory") {
      return
        "Die gespeicherte PBF-Datei ist nicht mehr vorhanden. Entferne die Fortsetzung über „Weitere Importoptionen“ aus der Liste und lade die Region erneut herunter oder importiere die PBF-Datei neu."
    }
    if message.hasPrefix("graph import exceeds ") {
      return
        "Das Straßennetz überschreitet das Importlimit. Wähle eine kleinere Region oder bereite sie auf dem Mac auf."
    }
    if message.contains("insufficient memory") {
      return
        "Die Kartenaufbereitung überschreitet das Speicherbudget. Wähle eine kleinere Region oder bereite sie auf dem Mac auf."
    }
    if message.contains("insufficient disk space") {
      return
        "Für die Offline-Karte ist nicht genügend Speicherplatz frei. Gib Speicherplatz frei und setze den Import fort."
    }
    return message
  }

  func openRegion(_ url: URL) {
    guard activeDirectory != url || engine == nil else { return }
    run(.opening, status: "Offline-Region wird geöffnet …") { [self] _ in try await open(url) }
  }

  private func open(_ url: URL) async throws {
    phaseID = nil
    fraction = nil
    status = "Offline-Region wird geöffnet …"
    let directory = await Task.detached(priority: .utility) {
      url.resolvingSymlinksInPath().standardizedFileURL
    }.value
    let next = try await OfflineEngine.open(directory)
    if Task.isCancelled {
      await next.close()
      throw CancellationError()
    }
    searchTask?.cancel()
    searchID = nil
    searchTask = nil
    let previous = engine
    engine = next
    activeDirectory = directory
    route = nil
    results = []
    start = nil
    destination = nil
    startLabel = nil
    destinationLabel = nil
    routeError = nil
    inspectedPlace = nil
    focus = nil
    focusRequest = nil
    selectedRoutePoint = .start
    query = ""
    defaults.set(DemoStorage.savedPath(directory.path, in: root), forKey: "lastRegion")
    status =
      "\(next.manifest.name) bereit · \(next.manifest.nodes.formatted()) Straßenknoten · vollständig lokal"
    if let previous { await previous.close() }
  }

  func download(_ region: GeofabrikRegion) {
    guard canStartImport() else { return }
    run(.downloading, status: "\(region.name) wird von Geofabrik geladen …") { [self] id in
      let phase = beginPhase(id, status: "\(region.name) wird von Geofabrik geladen …")
      let source = try await geofabrik.download(region) { [weak self] bytes, total in
        Task { @MainActor in
          self?.receiveProgress(
            phase, fraction: total > 0 ? Double(bytes) / Double(total) : nil,
            status:
              "Download: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        }
      }
      try Task.checkCancellation()
      try await prepare(source, name: region.name, operation: id)
    }
  }

  func importFile(_ source: URL) {
    guard canStartImport() else { return }
    run(.importing, status: "PBF wird in den lokalen App-Speicher übernommen …") { [self] id in
      guard source.pathExtension.lowercased() == "pbf" else {
        throw OSMminiError.native("Eine .osm.pbf-Datei auswählen.")
      }
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      let copy = root.appendingPathComponent("source-\(UUID().uuidString).osm.pbf")
      // Retain only copies needed by a pending import. Published regions do
      // not need the PBF; failed/cancelled copies must not consume disk space.
      defer { if pending?.pbf != copy.path { try? FileManager.default.removeItem(at: copy) } }
      let copying = Task.detached(priority: .utility) { try DemoStorage.copyPBF(source, to: copy) }
      try await withTaskCancellationHandler {
        try await copying.value
      } onCancel: {
        copying.cancel()
      }
      try Task.checkCancellation()
      let name = source.deletingPathExtension().lastPathComponent
      try await prepare(
        copy, name: name.hasSuffix(".osm") ? String(name.dropLast(4)) : name, operation: id)
    }
  }

  private func prepare(_ source: URL, name: String, operation: UUID) async throws {
    guard pending == nil else {
      throw OSMminiError.native(
        "Zuerst den unterbrochenen Import fortsetzen oder aus der Liste entfernen.")
    }
    let options = ImportOptions(
      pbf: source,
      destination: root.appendingPathComponent(
        "\(name.replacingOccurrences(of: "/", with: "-"))-\(UUID().uuidString.prefix(8))"),
      name: name)
    let root = root
    let checking = Task.detached(priority: .utility) {
      try DemoRegionStorage.matchingRegion(
        for: source, in: root, minZoom: options.minZoom, maxZoom: options.maxZoom)
    }
    let existing = try await withTaskCancellationHandler {
      try await checking.value
    } onCancel: {
      checking.cancel()
    }
    try Task.checkCancellation()
    if let existing {
      try await open(existing)
      status = "Diese PBF ist bereits importiert. Vorhandene Offline-Region geöffnet."
      return
    }
    let encoded = try DemoStorage.savedImport(options, in: root)
    clearImportDiagnostics()
    pending = options
    defaults.set(encoded, forKey: "pendingImport")
    try await resumeImport(options, operation: operation)
  }

  func resumePendingImport() {
    guard let pending else { return }
    run(.importing, status: "Import wird fortgesetzt …") { [self] id in
      try await resumeImport(pending, operation: id)
    }
  }

  private func canStartImport() -> Bool {
    guard !busy else { return false }
    guard pending == nil else {
      status =
        "Ein unterbrochener Import ist vorhanden. Fortsetzen oder die Fortsetzung aus der Liste entfernen."
      return false
    }
    return true
  }

  // Start with a new workspace when an older checkpoint cannot be resumed.
  // Keep its files intact and retain all user-selected import limits.
  func restartPendingImport() {
    guard !busy, var options = pending else { return }
    options.destination =
      root.appendingPathComponent(
        "\(options.name.replacingOccurrences(of: "/", with: "-"))-\(UUID().uuidString.prefix(8))"
      ).path
    run(.importing, status: "Region wird mit der vorhandenen PBF neu aufbereitet …") { [self] id in
      let encoded = try DemoStorage.savedImport(options, in: root)
      clearImportDiagnostics()
      pending = options
      defaults.set(encoded, forKey: "pendingImport")
      try await resumeImport(options, operation: id)
    }
  }

  // This action only removes the resume entry. It never deletes map files,
  // source PBFs or checkpoints; the UI explicitly describes that distinction.
  func removePendingImportFromList() {
    guard !busy, pending != nil else { return }
    pending = nil
    defaults.removeObject(forKey: "pendingImport")
    clearImportDiagnostics()
    status = "Fortsetzung aus der Liste entfernt. Die Importdateien bleiben erhalten."
  }

  private func resumeImport(_ options: ImportOptions, operation: UUID) async throws {
    let phase = beginPhase(operation, status: "Offline-Region wird aufbereitet …")
    _ = try await OfflineEngine.importPBF(options) { [weak self] progress in
      Task { @MainActor in
        self?.receiveProgress(
          phase, fraction: progress.fraction, status: Self.phaseLabel(progress.phase))
      }
    }
    pending = nil
    defaults.removeObject(forKey: "pendingImport")
    clearImportDiagnostics()
    let root = root
    await Task.detached(priority: .utility) {
      DemoStorage.removeImportedSource(options.pbf, in: root)
    }.value
    try Task.checkCancellation()
    try await open(URL(fileURLWithPath: options.destination))
  }

  private static func phaseLabel(_ phase: String) -> String {
    switch phase {
    case "checking": "Quelldatei wird geprüft …"
    case "building_graph": "Straßennetz wird aufbereitet …"
    case "loading_graph": "Vorbereitetes Straßennetz wird fortgesetzt …"
    case "indexing_search": "Adressen und Orte werden für die Suche aufbereitet …"
    case "validating": "Offline-Region wird abschließend geprüft …"
    case "ready": "Offline-Region ist bereit."
    case "building_map", "map_generate": "Geometrie für die Offline-Karte wird aufbereitet …"
    case "map_generated", "map_preflight": "Kartendateien werden zur Speicherung geprüft …"
    case "map_import": "Kartenkacheln werden gespeichert …"
    case "map_published": "Offline-Karte gespeichert."
    default: "Lokale Karte wird erzeugt …"
    }
  }

  func select(_ coordinate: Coordinate) {
    select(coordinate, label: nil)
  }

  func select(_ result: SearchResult) {
    select(result.coordinate, label: result.label)
  }

  func chooseRoutePoint(_ point: RoutePoint) {
    guard !busy, engine != nil else { return }
    selectedRoutePoint = point
    status = routeSelectionHint
  }

  private func select(_ coordinate: Coordinate, label: String?) {
    guard !busy, engine != nil else { return }
    route = nil
    routeError = nil
    focusOn(coordinate)
    if selectedRoutePoint == .start {
      start = coordinate
      startLabel = label ?? "Punkt auf der Karte"
      selectedRoutePoint = .destination
      if destination != nil {
        calculate()
      } else {
        status = "Start gesetzt. Jetzt das Ziel auswählen."
      }
    } else {
      destination = coordinate
      destinationLabel = label ?? "Punkt auf der Karte"
      if start != nil {
        calculate()
      } else {
        selectedRoutePoint = .start
        status = "Ziel gesetzt. Jetzt den Start auswählen."
      }
    }
  }

  func inspect(_ coordinate: Coordinate) {
    inspect(DemoPlace(coordinate: coordinate, name: "Ausgewählter Kartenpunkt", category: nil))
  }

  func inspect(_ result: SearchResult) {
    inspect(DemoPlace(result))
  }

  private func inspect(_ place: DemoPlace) {
    guard !busy, engine != nil else { return }
    inspectedPlace = place
    focusOn(place.coordinate)
  }

  func dismissPlace() { inspectedPlace = nil }

  func usePlace(_ place: DemoPlace, as point: RoutePoint) {
    guard !busy, engine != nil else { return }
    selectedRoutePoint = point
    inspectedPlace = nil
    select(place.coordinate, label: place.name)
  }

  func focusOn(_ coordinate: Coordinate) {
    guard engine != nil else { return }
    focus = coordinate
    focusRequest = UUID()
  }

  func contains(_ coordinate: Coordinate) -> Bool {
    guard let bounds = engine?.manifest.bounds else { return false }
    return coordinate.lat >= bounds.minLat && coordinate.lat <= bounds.maxLat
      && coordinate.lon >= bounds.minLon && coordinate.lon <= bounds.maxLon
  }

  func swapRoutePoints() {
    guard !busy, let start, let destination else { return }
    self.start = destination
    self.destination = start
    (startLabel, destinationLabel) = (destinationLabel, startLabel)
    route = nil
    routeError = nil
    inspectedPlace = nil
    selectedRoutePoint = .destination
    calculate()
  }

  func clearDownloads() {
    guard !busy, pending == nil else { return }
    run(.deleting, status: "PBF-Downloads werden entfernt …") { [self] _ in
      let root = root
      try await Task.detached(priority: .utility) {
        try DemoRegionStorage.removeDownloads(in: root)
      }.value
      status = "PBF-Downloads entfernt. Offline-Karten bleiben verfügbar."
    }
  }

  func deleteRegion(_ region: InstalledRegion) {
    guard !busy, installed.contains(where: { $0.directory == region.directory }) else { return }
    run(.deleting, status: "\(region.name) wird entfernt …") { [self] _ in
      if activeDirectory == region.directory {
        searchTask?.cancel()
        searchID = nil
        searchTask = nil
        query = ""
        results = []
        searching = false
        searchError = nil
        clearRoute()
        let previous = engine
        engine = nil
        activeDirectory = nil
        defaults.removeObject(forKey: "lastRegion")
        await previous?.close()
      }
      let root = root
      try await Task.detached(priority: .utility) {
        try DemoRegionStorage.removeRegion(region.directory, in: root)
      }.value
      status = "\(region.name) entfernt."
    }
  }

  func clearRoute() {
    if activity == .routing { cancel() }
    start = nil
    destination = nil
    startLabel = nil
    destinationLabel = nil
    routeError = nil
    inspectedPlace = nil
    selectedRoutePoint = .start
    focus = nil
    route = nil
    if !busy { status = "Zwei Kartenpunkte oder Suchtreffer für eine Route auswählen." }
  }

  func setRouteObjective(_ objective: RouteObjective) {
    guard !busy, objective != routeObjective, objective == .distance || objective == .duration
    else { return }
    routeObjective = objective
    defaults.set(objective.rawValue, forKey: "routeObjective")
    route = nil
    routeError = nil
    calculate()
  }

  private func calculate() {
    guard canCalculateRoute, let engine, let start, let destination else { return }
    var options = RouteOptions()
    options.objective = routeObjective
    routeError = nil
    run(.routing, status: "Route wird berechnet …") { [self] _ in
      let result = try await engine.route(
        RouteRequest(from: start, to: destination, options: options))
      try Task.checkCancellation()
      guard self.engine === engine, self.start == start, self.destination == destination else {
        return
      }
      route = result
      status =
        "Route: \((result.distanceM / 1000).formatted(.number.precision(.fractionLength(1)))) km · \((result.durationS / 60).formatted(.number.precision(.fractionLength(0)))) min"
    }
  }

  func retryRoute() {
    calculate()
  }

  private static func routeErrorMessage(_ error: any Error) -> String {
    switch error.localizedDescription {
    case "no path found":
      "Zwischen diesen Punkten wurde keine befahrbare Verbindung gefunden. Wähle einen anderen Start- oder Zielpunkt."
    case "location is outside the installed region":
      "Ein Punkt liegt außerhalb der installierten Region. Wähle Start und Ziel innerhalb dieser Karte."
    case "no start road", "start node missing in graph":
      "Am Start wurde keine befahrbare Straße gefunden. Wähle einen anderen Startpunkt."
    case "no destination road", "target node missing in graph":
      "Am Ziel wurde keine befahrbare Straße gefunden. Wähle einen anderen Zielpunkt."
    default: error.localizedDescription
    }
  }

  // Stop work when the last search sheet closes; another window may still use
  // the shared query. Preserve settled rows and the query across presentations.
  func suspendSearch(for presentation: UUID) {
    guard searchPresentations.remove(presentation) != nil, searchPresentations.isEmpty else {
      return
    }
    searchNeedsResume = searchNeedsResume || searching
    searchTask?.cancel()
    searchTask = nil
    searchID = nil
    searching = false
  }

  func resumeSearch(for presentation: UUID) {
    searchPresentations.insert(presentation)
    guard searchNeedsResume else { return }
    search()
  }

  func retrySearch() { search() }

  private func search() {
    searchTask?.cancel()
    searchTask = nil
    searchID = nil
    searchNeedsResume = false
    results = []
    searchError = nil
    searching = false
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let engine, !query.isEmpty else { return }
    let id = UUID()
    searchID = id
    searching = true
    searchTask = Task {
      defer {
        if searchID == id {
          searching = false
          searchTask = nil
        }
      }
      do {
        try await Task.sleep(for: .milliseconds(200))
        let found = try await engine.search(query)
        try Task.checkCancellation()
        guard searchID == id, self.engine === engine else { return }
        results = found
      } catch is CancellationError {} catch {
        guard searchID == id, !Task.isCancelled, self.engine === engine else { return }
        searchError = error.localizedDescription
      }
    }
  }
}

enum DemoStorage {
  // Persist app-owned paths relative to Application Support. An iOS app update
  // can change its container prefix while preserving the files inside it.
  static func savedPath(_ path: String, in root: URL) -> String {
    relativePath(URL(fileURLWithPath: path), in: root) ?? path
  }

  static func savedImport(_ options: ImportOptions, in root: URL) throws -> Data {
    var saved = options
    saved.pbf = savedPath(options.pbf, in: root)
    saved.destination = savedPath(options.destination, in: root)
    return try JSONEncoder().encode(saved)
  }

  static func restoredImport(_ saved: ImportOptions, in root: URL) throws -> ImportOptions {
    // Legacy demo destinations were always direct children of its app root.
    // Rebase the source only when it belonged to that same root; external
    // source files keep their original paths.
    let previousRoot =
      saved.destination.hasPrefix("/")
      ? URL(fileURLWithPath: saved.destination).deletingLastPathComponent() : nil
    var options = saved
    options.pbf = try restoredPath(saved.pbf, in: root, previousRoot: previousRoot)
    options.destination = try restoredPath(
      saved.destination, in: root, previousRoot: previousRoot)
    return options
  }

  static func restoredPath(_ saved: String, in root: URL, previousRoot: URL? = nil) throws -> String
  {
    if !saved.hasPrefix("/") {
      let url = root.appendingPathComponent(saved).standardizedFileURL
      guard !saved.isEmpty, relativePath(url, in: root) != nil else {
        throw OSMminiError.native("Ungültiger gespeicherter Pfad im lokalen App-Speicher.")
      }
      return url.path
    }
    let url = URL(fileURLWithPath: saved)
    if let previousRoot, let relative = relativePath(url, in: previousRoot) {
      return root.appendingPathComponent(relative).path
    }
    // Restore legacy lastRegion values even when no pending import remains.
    // Match the complete app-specific suffix, not an arbitrary file basename.
    let marker = "/Library/Application Support/OSMminiDemo/"
    let path = url.standardizedFileURL.path
    if root.lastPathComponent == "OSMminiDemo",
      let range = path.range(of: marker, options: .backwards)
    {
      return root.appendingPathComponent(String(path[range.upperBound...])).path
    }
    return saved
  }

  private static func relativePath(_ url: URL, in root: URL) -> String? {
    let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard components.count > base.count, components.starts(with: base) else { return nil }
    return components.dropFirst(base.count).joined(separator: "/")
  }

  static func regions(in root: URL) throws -> [InstalledRegion] {
    try DemoRegionStorage.regions(in: root)
  }

  static func copyPBF(_ source: URL, to target: URL) throws {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = target.appendingPathExtension("partial")
    defer { try? FileManager.default.removeItem(at: staging) }
    guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
      throw OSMminiError.native("Die lokale PBF-Kopie konnte nicht angelegt werden.")
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: staging)
    defer { try? output.close() }
    while true {
      try Task.checkCancellation()
      let copied = try autoreleasepool {
        guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
        try output.write(contentsOf: data)
        return true
      }
      if !copied { break }
    }
    try output.synchronize()
    try output.close()
    try Task.checkCancellation()
    try FileManager.default.moveItem(at: staging, to: target)
  }

  static func removeImportedSource(_ path: String, in root: URL) {
    let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let filename = source.lastPathComponent
    guard source.deletingLastPathComponent() == root.resolvingSymlinksInPath(),
      filename.hasPrefix("source-"), filename.hasSuffix(".osm.pbf"),
      UUID(uuidString: String(filename.dropFirst(7).dropLast(8))) != nil
    else { return }
    try? FileManager.default.removeItem(at: source)
  }
}
