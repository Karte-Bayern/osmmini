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
        Section { ActivityProgress(model: model) }
      }
      if !model.busy, let failure = model.importFailure {
        importFailure(failure)
      }
      if let pending = model.pending, !model.busy {
        pendingImport(pending)
      }
      if !model.installed.isEmpty {
        installedRegions
      } else if !model.busy, model.pending == nil {
        Section {
          VStack(alignment: .leading, spacing: 10) {
            Label("Deine erste Offline-Karte", systemImage: "map")
              .font(.headline)
            Text(
              "Wähle unten eine Region. Nach der einmaligen Aufbereitung kannst du Karte, Suche und Routing ohne Internet nutzen."
            )
            .foregroundStyle(.secondary)
            Text("Für den Einstieg eine kleine Region wählen.")
              .font(.callout)
          }
          .padding(.vertical, 6)
        }
      }
      if let error = model.regionError {
        Section {
          Label("Aktion nicht abgeschlossen", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
          Text(
            "Versuche die Aktion erneut. Bei beschädigten Kartendaten hilft ein erneuter Import der Region."
          )
          .font(.callout).foregroundStyle(.secondary)
          DisclosureGroup("Fehlerdetails") {
            Text(error).font(.caption).textSelection(.enabled)
          }
        }
      }
      CatalogPicker(model: model)
      Section {
        Button("Lokale PBF importieren", systemImage: "doc.badge.plus") {
          importing = true
        }
        .frame(minHeight: 32, alignment: .leading)
        .disabled(model.busy || model.pending != nil)
        .accessibilityHint("Eine bereits gespeicherte .osm.pbf-Datei auf diesem Gerät auswählen.")
      } header: {
        Text("Eigene Datei")
      } footer: {
        Text(
          "Du hast bereits eine .osm.pbf-Datei? Wähle die gespeicherte Datei direkt auf diesem Gerät aus."
        )
      }
      if model.downloadBytes > 0 || model.storageError != nil {
        sourceStorage
      }
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

  private var installedRegions: some View {
    Section {
      ForEach(model.installed) { region in
        let active = model.activeDirectory == region.directory
        Button {
          if active { showMap() } else { model.openRegion(region.directory) }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: active ? "map.fill" : "map")
              .imageScale(.large).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
              Text(region.name).font(.headline).foregroundStyle(.primary)
              Text(
                "\(active ? "Geöffnet" : "Offline verfügbar") · \(region.byteCount.formatted(.byteCount(style: .file)))"
              )
              .font(.caption).foregroundStyle(.secondary)
              if let date = region.importedAt {
                Text("Importiert \(date.formatted(date: .abbreviated, time: .omitted))")
                  .font(.caption2).foregroundStyle(.secondary)
              }
              if region.format < RegionManifest.currentFormat {
                Text("Erneut importieren, um Speicherplatz zu sparen.")
                  .font(.caption2).foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 0)
            Image(systemName: active ? "arrow.up.forward.app" : "chevron.right")
              .font(.callout).accessibilityHidden(true)
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
        }
        .disabled(model.busy)
        .accessibilityElement(children: .combine)
        .accessibilityHint(active ? "Zur Karte wechseln." : "Offline-Karte öffnen.")
        .contextMenu {
          Button("Region löschen", systemImage: "trash", role: .destructive) {
            deletingRegion = region
          }.disabled(model.busy)
        }
        .swipeActions {
          Button("Löschen", systemImage: "trash", role: .destructive) {
            deletingRegion = region
          }.disabled(model.busy)
        }
      }
    } header: {
      Text("Deine Offline-Karten")
    } footer: {
      Text(
        "\(model.installed.count) \(model.installed.count == 1 ? "Region" : "Regionen") · \(model.installedBytes.formatted(.byteCount(style: .file))) auf dem Gerät"
      )
    }
  }

  private func pendingImport(_ options: ImportOptions) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text(options.name).font(.headline)
        if model.importFailure == nil, let phase = model.lastImportPhase {
          Text("Zuletzt: \(phase)").font(.caption).foregroundStyle(.secondary)
        }
        Text(
          "Die Karte ist noch nicht einsatzbereit. Bereits abgeschlossene Importphasen werden weiterverwendet."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      Button {
        model.resumePendingImport()
      } label: {
        Label("Import fortsetzen", systemImage: "play.fill")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      Menu("Weitere Importoptionen", systemImage: "ellipsis.circle") {
        Button("Mit vorhandener PBF neu beginnen") { restartingImport = true }
        Button("Fortsetzung aus Liste entfernen", role: .destructive) { removingImport = true }
      }
      .frame(minHeight: 32, alignment: .leading)
    } header: {
      Label("Unterbrochener Import", systemImage: "pause.circle")
    } footer: {
      Text(
        "Vor einem neuen Download oder Import diese Aufbereitung fortsetzen oder die Fortsetzung aus der Liste entfernen."
      )
    }
  }

  private func importFailure(_ failure: DemoImportFailure) -> some View {
    Section {
      Text(
        failure.message == failure.details
          ? "Download oder Import konnte nicht abgeschlossen werden. Prüfe die Fehlerdetails und versuche es erneut."
          : failure.message
      )
      .font(.callout)
      if let phase = failure.phase {
        Text("Zuletzt: \(phase)").font(.caption).foregroundStyle(.secondary)
      }
      DisclosureGroup("Fehlerdetails") {
        Text(failure.details).font(.caption).textSelection(.enabled)
      }
    } header: {
      Label("Region noch nicht bereit", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    }
  }

  private var sourceStorage: some View {
    Section {
      if model.downloadBytes > 0 {
        LabeledContent(
          "PBF-Downloads", value: model.downloadBytes.formatted(.byteCount(style: .file)))
        Button("Downloads entfernen", systemImage: "trash", role: .destructive) {
          clearingDownloads = true
        }
        .disabled(model.busy || model.pending != nil)
      }
      if let error = model.storageError {
        DisclosureGroup {
          Text(error).font(.caption).textSelection(.enabled)
        } label: {
          Label("Speicherbelegung nicht verfügbar", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Speicher verwalten")
    } footer: {
      Text(
        model.pending == nil
          ? "Heruntergeladene Quelldateien können nach dem Import entfernt werden. Deine Offline-Karten bleiben verfügbar."
          : "Die Quelldatei wird noch für den unterbrochenen Import benötigt.")
    }
  }
}

private struct CatalogPicker: View {
  @Bindable var model: DemoModel
  @State private var selectedRegion: GeofabrikRegion?
  @FocusState private var searchFocused: Bool

  var body: some View {
    Section {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Region oder Land suchen", text: $model.catalogQuery)
          .autocorrectionDisabled()
          .focused($searchFocused)
          .submitLabel(.search)
          .onSubmit { searchFocused = false }
        if !model.catalogQuery.isEmpty {
          Button {
            model.catalogQuery = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
          }
          .buttonStyle(.plain).accessibilityLabel("Regionssuche leeren")
        }
      }
      if model.catalogLoading { ProgressView("Regionenkatalog wird geladen …") }
      if let error = model.catalogError {
        VStack(alignment: .leading, spacing: 8) {
          Label("Katalog momentan nicht erreichbar", systemImage: "wifi.exclamationmark")
            .font(.callout)
          Text("Prüfe die Internetverbindung und versuche es erneut.")
            .font(.caption).foregroundStyle(.secondary)
          DisclosureGroup("Fehlerdetails") {
            Text(error).font(.caption).textSelection(.enabled)
          }
        }
      }
      if !model.catalogLoaded, !model.catalogLoading, model.catalogError == nil {
        Text("Lade den Katalog, um verfügbare Regionen zu durchsuchen.")
          .font(.callout).foregroundStyle(.secondary)
      }
      if model.catalogLoaded, model.catalogMatchCount == 0 {
        let query = model.catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Label(
          query.isEmpty
            ? "Keine verfügbaren Regionen im Katalog."
            : "Keine Region für „\(query)“ gefunden.",
          systemImage: "magnifyingglass"
        )
        .font(.callout).foregroundStyle(.secondary)
        if !query.isEmpty { Button("Alle Regionen anzeigen") { model.catalogQuery = "" } }
      }
      ForEach(model.filteredRegions) { region in
        Button {
          searchFocused = false
          selectedRegion = region
        } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(region.name).foregroundStyle(.primary)
              let context = model.catalogContext(for: region)
              if !context.isEmpty {
                Text(context).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.circle").imageScale(.large).accessibilityHidden(true)
          }
          .padding(.vertical, 4).contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Download und Offline-Aufbereitung dieser Region vorbereiten.")
        .disabled(model.busy || model.pending != nil)
      }
      if model.catalogMatchCount > model.filteredRegions.count {
        Text(
          "\(model.catalogMatchCount) Treffer · \(model.filteredRegions.count) angezeigt. Suche mit einem Regionsnamen eingrenzen."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Button(
        model.catalogError != nil
          ? "Erneut versuchen"
          : model.catalogLoaded ? "Katalog aktualisieren" : "Regionenkatalog laden",
        systemImage: "arrow.clockwise"
      ) {
        searchFocused = false
        Task { await model.loadCatalog(refresh: model.catalogLoaded) }
      }
      .frame(minHeight: 32, alignment: .leading)
      .disabled(model.catalogLoading)
    } header: {
      Text("Region von Geofabrik laden")
    } footer: {
      Text(
        model.busy
          ? "Ein Vorgang läuft. Anschließend kannst du eine weitere Region laden."
          : model.pending != nil
            ? "Schließe zuerst den unterbrochenen Import ab oder entferne seine Fortsetzung aus der Liste."
            : "Zum Herunterladen ist Internet nötig. Die Region wird danach automatisch für die Offline-Nutzung aufbereitet."
      )
    }
    .sheet(item: $selectedRegion) { region in
      CatalogDownloadSheet(model: model, region: region)
    }
  }
}

private struct CatalogDownloadSheet: View {
  let model: DemoModel
  let region: GeofabrikRegion
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label(region.name, systemImage: "map").font(.title2.bold())
            let context = model.catalogContext(for: region)
            if !context.isEmpty { Text(context).foregroundStyle(.secondary) }
          }
          .padding(.vertical, 4)
          Label("PBF von Geofabrik herunterladen", systemImage: "arrow.down.circle")
          Label("Karte, Suche und Routing lokal aufbereiten", systemImage: "gearshape.2")
          Label("Anschließend ohne Internet nutzen", systemImage: "checkmark.circle")
        } footer: {
          Text(
            "Die Aufbereitung kann mehrere Minuten dauern und benötigt zusätzlichen freien Speicher. Für große Regionen empfiehlt sich die Aufbereitung auf einem Mac."
          )
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button {
          dismiss()
          model.download(region)
        } label: {
          Label("Herunterladen und importieren", systemImage: "arrow.down.to.line")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.busy || model.pending != nil)
        .padding()
        .background(.bar)
      }
      .navigationTitle("Offline-Region hinzufügen")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
    }
    .presentationDetents([.medium, .large])
    #if os(macOS)
      .frame(minWidth: 300, minHeight: 400)
    #endif
  }
}

struct ActivityProgress: View {
  let model: DemoModel

  private var title: String {
    if model.cancelling { return "Vorgang wird beendet …" }
    return switch model.activity {
    case .downloading: model.pending == nil ? "Region herunterladen" : "Offline-Karte vorbereiten"
    case .importing: "Offline-Karte vorbereiten"
    case .opening: "Karte öffnen"
    case .routing: "Route berechnen"
    case .deleting: "Dateien entfernen"
    case nil: "Fortschritt"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      if let fraction = model.fraction, !model.cancelling {
        ProgressView(value: fraction) {
          Text(
            model.activity == .downloading && model.pending == nil ? "Download" : "Aktuelle Phase")
        } currentValueLabel: {
          Text(fraction, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
        }
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
      } else {
        ProgressView().accessibilityLabel(title)
      }
      Text(
        model.cancelling ? "Bitte kurz warten, bis der Vorgang sicher beendet ist." : model.status
      )
      .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      #if os(iOS)
        if !model.cancelling, model.activity == .importing || model.activity == .downloading {
          Text("Für die Aufbereitung die App im Vordergrund lassen.")
            .font(.caption).foregroundStyle(.secondary)
        }
      #endif
      if model.canCancel {
        Button(
          model.activity == .importing || (model.activity == .downloading && model.pending != nil)
            ? "Import unterbrechen" : "Abbrechen",
          role: .cancel
        ) { model.cancel() }
        .frame(minHeight: 32, alignment: .leading)
        .disabled(model.cancelling)
      }
    }
    .padding(.vertical, 4)
  }
}
