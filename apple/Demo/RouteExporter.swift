import OSMmini
import SwiftUI
import UniformTypeIdentifiers

enum FileDialogError {
  static func message(for error: any Error) -> String? {
    if error is CancellationError { return nil }
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain, failure.code == NSUserCancelledError { return nil }
    return error.localizedDescription
  }
}

struct RouteDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json, .xml, .data] }
  // fileExporter requires the exact selected type in this list. A conforming
  // parent such as .xml is insufficient; otherwise it falls back to JSON.
  static var writableContentTypes: [UTType] {
    [RouteExportFormat.geoJSON.contentType, RouteExportFormat.gpx.contentType]
  }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let contents = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    data = contents
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

enum RouteExportFormat: Sendable {
  case geoJSON, gpx
  var name: String { self == .gpx ? "GPX" : "GeoJSON" }
  var filename: String { self == .gpx ? "route.gpx" : "route.geojson" }
  var contentType: UTType {
    if self == .geoJSON {
      if #available(iOS 18, macOS 15, *) { return .geoJSON }
      return UTType(filenameExtension: "geojson") ?? .data
    }
    // Preserve .gpx even on systems without a registered GPX type: advertising
    // generic XML there would let the save panel append an unwanted .xml.
    return UTType(filenameExtension: "gpx") ?? .data
  }
  func encode(_ route: Route) throws -> Data {
    switch self {
    case .geoJSON:
      do {
        return try route.geoJSON()
      } catch EncodingError.invalidValue(_, _) {
        throw ExportError.invalidValues
      }
    case .gpx:
      guard route.path.allSatisfy({ $0.lat.isFinite && $0.lon.isFinite }) else {
        throw ExportError.invalidValues
      }
      return route.gpx()
    }
  }

  func preparedData(for route: Route) async throws -> Data {
    try Task.checkCancellation()
    let encoding = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let data = try encode(route)
      try Task.checkCancellation()
      return data
    }
    return try await withTaskCancellationHandler {
      let data = try await encoding.value
      try Task.checkCancellation()
      return data
    } onCancel: {
      encoding.cancel()
    }
  }

  private enum ExportError: LocalizedError {
    case invalidValues
    var errorDescription: String? {
      "Die Route enthält ungültige Zahlenwerte. Bitte die Route neu berechnen."
    }
  }
}

struct RouteExporter: View {
  let route: Route
  @State private var document: RouteDocument?
  @State private var format = RouteExportFormat.geoJSON
  @State private var preparing = false
  @State private var exporting = false
  @State private var error: String?
  @State private var information: String?
  @State private var preparationID: UUID?
  @State private var active = true
  @State private var task: Task<Void, Never>?

  var body: some View {
    let completionID = preparationID
    VStack(alignment: .leading, spacing: 4) {
      Menu(preparing ? "Export wird vorbereitet …" : "Route exportieren") {
        Button("GeoJSON") { prepare(.geoJSON) }
        Button("GPX") { prepare(.gpx) }
      }
      .disabled(preparing || exporting)
      if preparing {
        Button("Export abbrechen", role: .cancel) { cancelPreparation() }
          .font(.caption)
      }
      if let information {
        Text(information).font(.caption).foregroundStyle(.secondary)
      }
    }
    .fileExporter(
      isPresented: $exporting, document: document,
      contentType: format.contentType, defaultFilename: format.filename
    ) { result in
      guard active, let completionID, preparationID == completionID else { return }
      preparationID = nil
      document = nil
      switch result {
      case .success: information = "\(format.name) gespeichert."
      case .failure(let failure): error = FileDialogError.message(for: failure)
      }
    }
    .alert(
      "Export fehlgeschlagen",
      isPresented: Binding(
        get: { error != nil }, set: { if !$0 { error = nil } }
      )
    ) {
      Button("OK") { error = nil }
    } message: {
      Text(error ?? "")
    }
    .onAppear { active = true }
    .onDisappear {
      active = false
      cancelPreparation()
      exporting = false
      document = nil
    }
  }

  private func prepare(_ format: RouteExportFormat) {
    guard active, !preparing, !exporting else { return }
    let id = UUID()
    preparationID = id
    preparing = true
    information = nil
    error = nil
    let route = route
    task = Task {
      defer {
        if preparationID == id {
          preparing = false
          task = nil
        }
      }
      do {
        let data = try await format.preparedData(for: route)
        try Task.checkCancellation()
        guard active, preparationID == id else { return }
        self.format = format
        document = RouteDocument(data: data)
        exporting = true
      } catch {
        guard active, preparationID == id else { return }
        self.error = FileDialogError.message(for: error)
      }
    }
  }

  private func cancelPreparation() {
    preparationID = nil
    task?.cancel()
    task = nil
    preparing = false
  }
}
