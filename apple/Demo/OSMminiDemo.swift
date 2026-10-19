import OSMmini
import SwiftUI
import UniformTypeIdentifiers

@main struct OSMminiDemoApp: App {
  @State private var model = DemoModel()
  var body: some Scene { WindowGroup { DemoView(model: model) } }
}

struct DemoView: View {
  let model: DemoModel
  @State private var location = DemoLocation()
  @Environment(\.scenePhase) private var scenePhase
  @State private var importing = false
  @State private var columns = NavigationSplitViewVisibility.all
  @State private var preferredColumn = NavigationSplitViewColumn.sidebar
  @State private var fileError: String?

  var body: some View {
    NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $preferredColumn) {
      DemoSidebar(model: model, importing: $importing) { preferredColumn = .detail }
        .navigationTitle("OSMmini")
        .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
    } detail: {
      DemoMapScreen(model: model, location: location) {
        preferredColumn = .sidebar
        columns = .all
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): model.importFile(url)
      case .failure(let error): fileError = FileDialogError.message(for: error)
      }
    }
    .alert(
      "Datei konnte nicht geöffnet werden",
      isPresented: Binding(
        get: { fileError != nil }, set: { if !$0 { fileError = nil } }
      )
    ) {
      Button("OK") { fileError = nil }
    } message: {
      Text(fileError ?? "")
    }
    .onChange(of: model.activeDirectory, initial: true) { _, directory in
      if directory == nil {
        location.stop()
        preferredColumn = .sidebar
      } else {
        preferredColumn = .detail
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { location.stop() }
    }
    .onDisappear { location.stop() }
    .task { await model.start() }
  }
}

private struct DemoSidebar: View {
  let model: DemoModel
  @Binding var importing: Bool
  let showMap: () -> Void
  @State private var restartingImport = false
  @State private var removingImport = false
  @State private var deletingRegion: InstalledRegion?
  @State private var clearingDownloads = false

  var body: some View {
    List {
      if model.busy {
        Section("Fortschritt") { ActivityProgress(model: model) }
      }
      if !model.busy, let failure = model.importFailure {
        Section {
          Text(failure.message).foregroundStyle(.red).textSelection(.enabled)
          if let phase = failure.phase {
            Text("Phase: \(phase)").font(.caption).foregroundStyle(.secondary)
          }
          if failure.details != failure.message {
            DisclosureGroup("Fehlerdetails") {
              Text(failure.details).font(.caption).textSelection(.enabled)
            }
          }
        } header: {
          Label("Import nicht abgeschlossen", systemImage: "exclamationmark.triangle")
        }
      }
      Section("Offline-Regionen") {
        if model.installed.isEmpty {
          Text("Noch keine Region installiert.").foregroundStyle(.secondary)
        }
        ForEach(model.installed) { region in
          Button {
            if model.activeDirectory == region.directory {
              showMap()
            } else {
              model.openRegion(region.directory)
            }
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(region.name)
                Text(
                  "\(region.nodes.formatted()) Straßenknoten · \(region.byteCount.formatted(.byteCount(style: .file)))"
                )
                .font(.caption).foregroundStyle(.secondary)
                if let date = region.importedAt {
                  Text("Importiert \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if model.activeDirectory == region.directory {
                Image(systemName: "checkmark.circle.fill")
                  .accessibilityLabel("Geöffnete Region")
              }
            }
          }.disabled(model.busy)
            .contextMenu {
              Button("Region löschen", systemImage: "trash", role: .destructive) {
                deletingRegion = region
              }
              .disabled(model.busy)
            }
            .swipeActions {
              Button("Löschen", systemImage: "trash", role: .destructive) {
                deletingRegion = region
              }
              .disabled(model.busy)
            }
        }
        if !model.installed.isEmpty {
          Text("Offline-Karten: \(model.installedBytes.formatted(.byteCount(style: .file)))")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let error = model.regionError {
          Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
        if let error = model.storageError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        Button("Lokale PBF importieren", systemImage: "square.and.arrow.down") {
          importing = true
        }.disabled(model.busy || model.pending != nil)
        if let pending = model.pending {
          Text("Unterbrochener Import: \(pending.name)").font(.callout)
          if !model.busy, model.importFailure == nil, let phase = model.lastImportPhase {
            Text("Zuletzt: \(phase)").font(.caption).foregroundStyle(.secondary)
          }
          Button("Import fortsetzen", systemImage: "play.fill") { model.resumePendingImport() }
            .disabled(model.busy)
          Menu("Weitere Importoptionen") {
            Button("Mit vorhandener PBF neu beginnen") { restartingImport = true }
            Button("Fortsetzung aus Liste entfernen") { removingImport = true }
          }.disabled(model.busy)
          Text(
            "Vor einem weiteren Import diese Aufbereitung fortsetzen oder die Fortsetzung aus der Liste entfernen."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      if model.downloadBytes > 0 {
        Section("Quelldateien") {
          Text("PBF-Downloads: \(model.downloadBytes.formatted(.byteCount(style: .file)))")
          Button("Downloads entfernen", systemImage: "trash", role: .destructive) {
            clearingDownloads = true
          }
          .disabled(model.busy || model.pending != nil)
          Text(
            model.pending == nil
              ? "Installierte Offline-Karten benötigen die heruntergeladenen PBF-Dateien nicht mehr."
              : "Die PBF wird noch für den unterbrochenen Import benötigt."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      CatalogPicker(model: model)
    }
    .confirmationDialog(
      "Offline-Region löschen?",
      isPresented: Binding(
        get: { deletingRegion != nil }, set: { if !$0 { deletingRegion = nil } }),
      titleVisibility: .visible
    ) {
      if let region = deletingRegion {
        Button("\(region.name) löschen", role: .destructive) {
          model.deleteRegion(region)
          deletingRegion = nil
        }
      }
      Button("Abbrechen", role: .cancel) { deletingRegion = nil }
    } message: {
      Text(
        "Die Offline-Karte wird vom Gerät entfernt. Für die spätere Nutzung muss sie erneut importiert werden."
      )
    }
    .confirmationDialog(
      "PBF-Downloads entfernen?", isPresented: $clearingDownloads, titleVisibility: .visible
    ) {
      Button("Downloads entfernen", role: .destructive) { model.clearDownloads() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Entfernt heruntergeladene PBF-Dateien und angefangene Downloads. Installierte Offline-Karten bleiben verfügbar."
      )
    }
    .confirmationDialog(
      "Import neu beginnen?", isPresented: $restartingImport, titleVisibility: .visible
    ) {
      Button("Mit vorhandener PBF neu aufbereiten") { model.restartPendingImport() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Verwendet dieselbe PBF in einem neuen Arbeitsverzeichnis. Bisherige Importdateien bleiben erhalten."
      )
    }
    .confirmationDialog(
      "Fortsetzung aus Liste entfernen?", isPresented: $removingImport, titleVisibility: .visible
    ) {
      Button("Aus Liste entfernen", role: .destructive) { model.removePendingImportFromList() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Entfernt nur den Fortsetzungseintrag. Quelldatei und angefangene Importdaten bleiben gespeichert und belegen weiterhin Speicherplatz."
      )
    }
  }
}

private struct CatalogPicker: View {
  @Bindable var model: DemoModel
  var body: some View {
    Section("Geofabrik") {
      TextField("Region suchen", text: $model.catalogQuery)
        .autocorrectionDisabled()
      if model.catalogLoading { ProgressView("Katalog wird geladen …") }
      if let error = model.catalogError {
        Text("Katalog konnte nicht aktualisiert werden: \(error)").font(.caption).foregroundStyle(
          .red)
      }
      if !model.catalogLoaded, !model.catalogLoading, model.catalogError == nil {
        Text("Katalog laden und eine Region für den Download auswählen.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if model.catalogLoaded, model.catalogMatchCount == 0 {
        let query = model.catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Text(
          query.isEmpty
            ? "Der Katalog enthält keine verfügbaren Regionen."
            : "Keine Region für „\(query)“ gefunden."
        )
        .font(.callout).foregroundStyle(.secondary)
        if !query.isEmpty { Button("Alle Regionen anzeigen") { model.catalogQuery = "" } }
      }
      ForEach(model.filteredRegions) { region in
        Button {
          model.download(region)
        } label: {
          HStack {
            VStack(alignment: .leading) {
              Text(region.name)
              Text(region.parent ?? region.id).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.down.circle")
          }
        }
        .accessibilityHint("Region herunterladen und für die Offline-Nutzung aufbereiten.")
        .disabled(model.busy || model.pending != nil)
      }
      if model.catalogMatchCount > model.filteredRegions.count {
        Text("\(model.catalogMatchCount) Treffer · Suche für weitere Regionen eingrenzen.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button(
        model.catalogLoaded ? "Online aktualisieren" : "Regionenkatalog laden",
        systemImage: "arrow.clockwise"
      ) {
        Task { await model.loadCatalog(refresh: model.catalogLoaded) }
      }.disabled(model.catalogLoading)
      Text(
        "Download benötigt Internet. Nach dem Import funktionieren Karte, Suche und Routing offline. Für den ersten Test eine kleine Region wählen."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct ActivityProgress: View {
  let model: DemoModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let fraction = model.fraction { ProgressView(value: fraction) } else { ProgressView() }
      Text(model.cancelling ? "Vorgang wird abgebrochen …" : model.status)
        .font(.callout).textSelection(.enabled)
      if model.canCancel {
        Button("Abbrechen", role: .cancel) { model.cancel() }.disabled(model.cancelling)
      }
    }
  }
}
