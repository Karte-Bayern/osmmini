import OSMmini
import SwiftUI
import UniformTypeIdentifiers

@main struct OSMminiDemoApp: App {
  var body: some Scene { WindowGroup { DemoView() } }
}

@MainActor final class DemoModel: ObservableObject {
  @Published var engine: OfflineEngine?
  @Published var installed: [URL] = []
  @Published var regions: [GeofabrikRegion] = []
  @Published var catalogQuery = "Niederbayern"
  @Published var query = ""
  @Published var results: [SearchResult] = []
  @Published var route: Route?
  @Published var start: Coordinate?
  @Published var destination: Coordinate?
  @Published var status = "Region herunterladen oder eine lokale PBF importieren."
  @Published var fraction: Double = 0
  @Published var busy = false
  @Published var pending: ImportOptions?
  var operation: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  let root: URL
  let geofabrik: Geofabrik
  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    root =
      ProcessInfo.processInfo.environment["OSMMINI_DEMO_DIRECTORY"].map { URL(fileURLWithPath: $0) }
      ?? support.appendingPathComponent("OSMminiDemo", isDirectory: true)
    geofabrik = Geofabrik(directory: root.appendingPathComponent("downloads", isDirectory: true))
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = UserDefaults.standard.data(forKey: "pendingImport") {
      pending = try? JSONDecoder().decode(ImportOptions.self, from: data)
    }
    refreshInstalled()
  }
  func refreshInstalled() {
    installed =
      ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? [])
      .filter {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
      }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
  func loadCatalog(refresh: Bool = false) async {
    do { regions = try await geofabrik.regions(refresh: refresh) } catch {
      if engine == nil {
        status =
          "Geofabrik: \(error.localizedDescription). Lokale Regionen funktionieren weiterhin offline."
      }
    }
  }
  func run(_ work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    operation = Task {
      defer {
        busy = false
        refreshInstalled()
      }
      do { try await work() } catch is CancellationError {
        status = "Abgebrochen. Downloads und abgeschlossene Importphasen können fortgesetzt werden."
      } catch { status = error.localizedDescription }
    }
  }
  func open(_ url: URL) async throws {
    status = "Offline-Region wird geöffnet …"
    let next = try await OfflineEngine.open(url)
    searchTask?.cancel()
    searchTask = nil
    let previous = engine
    engine = next
    route = nil
    results = []
    start = nil
    destination = nil
    UserDefaults.standard.set(url.path, forKey: "lastRegion")
    if let previous { await previous.close() }
    status =
      "\(next.manifest.name) bereit · \(next.manifest.nodes.formatted()) Straßenknoten · vollständig lokal"
  }
  func download(_ region: GeofabrikRegion) {
    run { [self] in
      status = "\(region.name) wird von Geofabrik geladen …"
      fraction = 0
      let source = try await geofabrik.download(region) { [weak self] bytes, total in
        Task { @MainActor in
          self?.fraction = total > 0 ? Double(bytes) / Double(total) : 0
          self?.status =
            "Download: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
      }
      try await prepare(source, name: region.name)
    }
  }
  func importFile(_ source: URL) {
    run { [self] in
      guard source.pathExtension.lowercased() == "pbf" else {
        throw OSMminiError.native("Eine .osm.pbf-Datei auswählen.")
      }
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      let copy = root.appendingPathComponent("source-\(UUID().uuidString).osm.pbf")
      status = "PBF wird in den lokalen App-Speicher übernommen …"
      try await Task.detached(priority: .utility) {
        try FileManager.default.copyItem(at: source, to: copy)
      }.value
      try await prepare(copy, name: source.deletingPathExtension().lastPathComponent)
    }
  }
  func prepare(_ source: URL, name: String) async throws {
    let options = ImportOptions(
      pbf: source,
      destination: root.appendingPathComponent(
        "\(name.replacingOccurrences(of: "/", with: "-"))-\(UUID().uuidString.prefix(8))"),
      name: name)
    pending = options
    UserDefaults.standard.set(try JSONEncoder().encode(options), forKey: "pendingImport")
    try await resumeImport(options)
  }
  func resumeImport(_ options: ImportOptions) async throws {
    _ = try await OfflineEngine.importPBF(options) { [weak self] progress in
      Task { @MainActor in
        self?.fraction = progress.fraction
        self?.status = Self.phaseLabel(progress.phase)
      }
    }
    pending = nil
    UserDefaults.standard.removeObject(forKey: "pendingImport")
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
    default: "Lokale Karte wird erzeugt …"
    }
  }
  func select(_ coordinate: Coordinate) {
    if start == nil || destination != nil {
      start = coordinate
      destination = nil
      route = nil
      status = "Start gesetzt. Jetzt das Ziel auswählen."
    } else {
      destination = coordinate
      calculate()
    }
  }
  func calculate() {
    guard let engine, let start, let destination else { return }
    run { [self] in
      route = try await engine.route(RouteRequest(from: start, to: destination))
      status =
        "Route: \(((route?.distanceM ?? 0) / 1000).formatted(.number.precision(.fractionLength(1)))) km · \(((route?.durationS ?? 0) / 60).formatted(.number.precision(.fractionLength(0)))) min"
    }
  }
  func search() {
    searchTask?.cancel()
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let engine, !query.isEmpty else {
      results = []
      return
    }
    searchTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(200))
        let found = try await engine.search(query)
        try Task.checkCancellation()
        guard self.engine === engine else { return }
        results = found
      } catch is CancellationError {} catch {
        guard !Task.isCancelled, self.engine === engine else { return }
        status = error.localizedDescription
      }
    }
  }
}

struct RouteDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct DemoView: View {
  @StateObject private var model = DemoModel()
  @State private var importing = false
  @State private var exporting = false
  @State private var document: RouteDocument?
  @State private var exportName = "route.geojson"
  var body: some View {
    NavigationSplitView {
      List {
        if model.busy {
          Section("Fortschritt") {
            ProgressView(value: model.fraction)
            Text(model.status)
            Button("Abbrechen") { model.operation?.cancel() }
          }
        }
        Section("Offline-Regionen") {
          ForEach(model.installed, id: \.path) { url in
            Button(url.lastPathComponent) { model.run { try await model.open(url) } }.disabled(
              model.busy)
          }
          Button("Lokale PBF importieren", systemImage: "square.and.arrow.down") {
            importing = true
          }.disabled(model.busy)
          if let pending = model.pending {
            Button("Import fortsetzen: \(pending.name)") {
              model.run { try await model.resumeImport(pending) }
            }.disabled(model.busy)
          }
        }
        Section("Geofabrik") {
          TextField("Region suchen", text: $model.catalogQuery)
          ForEach(
            model.regions.filter {
              model.catalogQuery.isEmpty
                || $0.name.localizedCaseInsensitiveContains(model.catalogQuery)
                || $0.id.localizedCaseInsensitiveContains(model.catalogQuery)
            }.prefix(50)
          ) { region in
            Button {
              model.download(region)
            } label: {
              VStack(alignment: .leading) {
                Text(region.name)
                Text(region.parent ?? region.id).font(.caption).foregroundStyle(.secondary)
              }
            }.disabled(model.busy)
          }
          Button("Katalog aktualisieren") { Task { await model.loadCatalog(refresh: true) } }
          Text(
            "Download benötigt Internet. Karte, Suche und Routing funktionieren nach dem Import offline. Für den ersten Test eine kleine Region wählen."
          ).font(.caption).foregroundStyle(.secondary)
        }
        if model.engine != nil {
          Section("Lokale Suche") {
            TextField("Adresse, Straße oder POI", text: $model.query).onChange(of: model.query) {
              _, _ in model.search()
            }
            ForEach(model.results, id: \.identity) { result in
              Button(result.label) { model.select(result.coordinate) }
            }
          }
        }
      }.navigationTitle("OSMmini")
    } detail: {
      VStack(spacing: 0) {
        if let engine = model.engine {
          OfflineMap(
            engine: engine, route: model.route,
            markers: [model.start, model.destination].compactMap { $0 },
            focus: model.destination ?? model.start, onSelect: model.select
          ).id(ObjectIdentifier(engine))
        } else {
          ContentUnavailableView(
            "Deine Region offline", systemImage: "map",
            description: Text(
              "Eine PBF von Geofabrik laden oder eine Datei importieren. Die Region bleibt nach dem Neustart verfügbar."
            ))
        }
        VStack(alignment: .leading, spacing: 8) {
          if model.busy {
            ProgressView(value: model.fraction)
            Button("Abbrechen") { model.operation?.cancel() }
          }
          Text(model.status).font(.callout).textSelection(.enabled)
          if model.engine != nil {
            Text("Zwei Kartenpunkte oder Suchtreffer wählen: Start, dann Ziel.").font(.caption)
              .foregroundStyle(.secondary)
            HStack {
              Button("Route zurücksetzen") {
                model.start = nil
                model.destination = nil
                model.route = nil
              }
              if let route = model.route {
                Menu("Route exportieren") {
                  Button("GeoJSON") {
                    if let data = try? route.geoJSON() {
                      document = RouteDocument(data: data)
                      exportName = "route.geojson"
                      exporting = true
                    }
                  }
                  Button("GPX") {
                    document = RouteDocument(data: route.gpx())
                    exportName = "route.gpx"
                    exporting = true
                  }
                }
              }
            }
          }
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
      }.navigationTitle(model.engine?.manifest.name ?? "Offline-Karte")
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): model.importFile(url)
      case .failure(let error): model.status = error.localizedDescription
      }
    }
    .fileExporter(
      isPresented: $exporting, document: document, contentType: .data, defaultFilename: exportName
    ) { result in if case .failure(let error) = result { model.status = error.localizedDescription }
    }
    .task {
      let arguments = CommandLine.arguments
      let explicitRegion = arguments.firstIndex(of: "--region").flatMap {
        $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
      }
      if let path = explicitRegion ?? UserDefaults.standard.string(forKey: "lastRegion"),
        model.engine == nil
      {
        model.run { try await model.open(URL(fileURLWithPath: path)) }
      }
      if !arguments.contains("--offline") { await model.loadCatalog() }
    }
  }
}
