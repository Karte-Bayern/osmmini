import OSMmini
import SwiftUI
import UniformTypeIdentifiers

@main struct OSMminiDemoApp: App {
  @State private var model = DemoModel()
  var body: some Scene {
    WindowGroup { DemoView(model: model) }
      #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
          DemoMacCommands()
          SidebarCommands()
        }
      #endif
  }
}

struct DemoMapActions {
  let search: () -> Void
  let plan: () -> Void
  let showRegions: () -> Void
  let isEnabled: Bool
}

private struct DemoMapActionsKey: FocusedValueKey {
  typealias Value = DemoMapActions
}

private struct DemoImportAction {
  let perform: () -> Void
  let isEnabled: Bool
}

private struct DemoImportActionKey: FocusedValueKey {
  typealias Value = DemoImportAction
}

extension FocusedValues {
  var mapActions: DemoMapActions? {
    get { self[DemoMapActionsKey.self] }
    set { self[DemoMapActionsKey.self] = newValue }
  }

  fileprivate var importAction: DemoImportAction? {
    get { self[DemoImportActionKey.self] }
    set { self[DemoImportActionKey.self] = newValue }
  }
}

#if os(macOS)
  private struct DemoMacCommands: Commands {
    @FocusedValue(\.mapActions) private var mapActions
    @FocusedValue(\.importAction) private var importAction

    var body: some Commands {
      CommandGroup(after: .newItem) {
        Button("PBF-Datei importieren …") {
          guard let importAction, importAction.isEnabled else { return }
          importAction.perform()
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(importAction?.isEnabled != true)
      }
      CommandMenu("Karte") {
        Button("Orte suchen …") {
          guard let mapActions, mapActions.isEnabled else { return }
          mapActions.search()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(mapActions?.isEnabled != true)
        Button("Routenplanung ein-/ausblenden") {
          guard let mapActions, mapActions.isEnabled else { return }
          mapActions.plan()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(mapActions?.isEnabled != true)
        Divider()
        Button("Offline-Karten anzeigen") { mapActions?.showRegions() }
          .disabled(mapActions == nil)
      }
    }
  }
#endif

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
      DemoSidebar(model: model, showMap: showMap)
        .navigationTitle("OSMmini")
        .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
    } detail: {
      DemoMapScreen(model: model, location: location) {
        preferredColumn = .sidebar
        columns = .all
      }
    }
    .navigationSplitViewStyle(.balanced)
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 500)
      .focusedSceneValue(
        \.importAction,
        DemoImportAction(
          perform: {
            guard !model.busy, model.pending == nil else { return }
            importing = true
          },
          isEnabled: !model.busy && model.pending == nil))
    #endif
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
    .alert(
      "KML konnte nicht importiert werden",
      isPresented: Binding(
        get: { model.layerImportError != nil },
        set: { if !$0 { model.dismissLayerImportError() } })
    ) {
      Button("OK") { model.dismissLayerImportError() }
    } message: {
      Text(model.layerImportError ?? "")
    }
    .onOpenURL { url in
      guard url.isFileURL, url.pathExtension.lowercased() == "kml" else {
        fileError = "Bitte eine KML-Datei mit der Endung .kml öffnen."
        return
      }
      model.importMapLayer(url)
    }
    .onChange(of: model.layerFocusRequest) { _, _ in showMap() }
    .onChange(of: model.activeDirectory, initial: true) { _, directory in
      if directory == nil {
        location.stop()
        preferredColumn = .sidebar
        columns = .all
      } else {
        showMap()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { location.stop() }
    }
    .onChange(of: model.mapSuspendedForImport) { _, suspended in
      if suspended { location.stop() }
    }
    .onDisappear { location.stop() }
    .task { await model.start() }
  }

  private func showMap() {
    preferredColumn = .detail
    columns = .detailOnly
  }
}

private struct DemoSidebar: View {
  let model: DemoModel
  let showMap: () -> Void
  @State private var restartingImport = false
  @State private var removingImport = false
  @State private var deletingRegion: InstalledRegion?
  @State private var clearingDownloads = false
  @State private var showingPlaces = false
  @State private var showingAddMap = false
  @State private var regionDetails: InstalledRegion?
  @State private var storageExpanded = false

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
      if let request = model.pendingSlice, !model.busy, model.pending == nil {
        Section {
          Button("Ausschnitt fortsetzen", systemImage: "arrow.clockwise") {
            model.resumeSliceDownload()
          }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          Text("\(request.radiusKM) km · \(request.resolvedPOIPreset.displayName)")
            .font(.caption).foregroundStyle(.secondary)
        } header: {
          Text("Unterbrochener Ausschnitt")
        }
      }
      if !model.installed.isEmpty {
        installedRegions
      } else if !model.busy, model.pending == nil {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
              Image(systemName: "map.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(
                  Color.accentColor.opacity(0.12),
                  in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityHidden(true)
              Text("Deine erste Offline-Karte")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            }
            Text(
              "Lade eine Region und nutze Karte, Suche und Routen nach der Aufbereitung ohne Internet."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("Starte mit einer kleinen Region. Sie ist schneller bereit.")
              .font(.callout.weight(.medium))
          }
          .padding(.vertical, 10)
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
      Section {
        Button {
          showingAddMap = true
        } label: {
          Label("Karte hinzufügen", systemImage: "plus.circle")
            .fontWeight(.medium).foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(model.busy || model.pending != nil)
        if !model.places.saved.isEmpty || !model.places.recent.isEmpty || model.places.needsReset {
          Button("Meine Orte", systemImage: "star") {
            model.query = ""
            showingPlaces = true
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle()).disabled(model.busy)
        }
      }
      Section {
        Text("OSMmini ist ein Projekt von Karte.Bayern.")
          .font(.callout).foregroundStyle(.secondary)
        Link(destination: URL(string: "https://karte.bayern/")!) {
          Label("Karte.Bayern öffnen", systemImage: "safari")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        Link(destination: URL(string: "https://github.com/Karte-Bayern/osmmini")!) {
          Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
      } header: {
        Text("Karte.Bayern")
      }
      DemoMapLayersSection(model: model, showMap: showMap)
      if !model.installed.isEmpty || model.downloadBytes > 0 || model.storageError != nil {
        sourceStorage
      }
    }
    .listStyle(.sidebar)
    .buttonStyle(.plain)
    .scrollDismissesKeyboard(.interactively)
    .sheet(isPresented: $showingAddMap) {
      DemoAddMapSheet(model: model)
    }
    .sheet(item: $regionDetails) { region in
      DemoRegionDetails(region: region)
    }
    .sheet(isPresented: $showingPlaces) {
      DemoPlaceSearch(model: model, target: nil, showRegions: { showingPlaces = false }) { place in
        guard !model.busy, model.canSelectPlace(place, target: nil) else { return }
        model.inspect(place, minimumZoom: 14)
        showingPlaces = false
        showMap()
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
      if let region = deletingRegion {
        Text(
          "„\(region.name)“ wird entfernt und gibt \(region.byteCount.formatted(.byteCount(style: .file))) frei. Für die spätere Nutzung muss die Region erneut importiert werden."
        )
      }
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
        HStack(spacing: 8) {
          Button {
            if active { showMap() } else { model.openRegion(region.directory) }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: active ? "map.fill" : "map")
                .imageScale(.large).foregroundStyle(.tint)
                .frame(width: 24).accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 4) {
                Text(region.name).font(.body.weight(active ? .semibold : .regular))
                  .foregroundStyle(.primary).lineLimit(2)
                Text(region.byteCount.formatted(.byteCount(style: .file))
                  + (region.poiPreset.map { " · \($0.displayName)" } ?? ""))
                  .font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
              Spacer(minLength: 0)
              if active {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.tint).accessibilityHidden(true)
              }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .combine)
          .accessibilityValue(active ? "Geöffnet" : "Offline verfügbar")
          .accessibilityHint(active ? "Zur Karte wechseln." : "Offline-Karte öffnen.")
          Menu {
            Button(active ? "Karte anzeigen" : "Karte öffnen", systemImage: "map") {
              if active { showMap() } else { model.openRegion(region.directory) }
            }
            Button("Kartendetails", systemImage: "info.circle") { regionDetails = region }
            Button("Region löschen …", systemImage: "trash", role: .destructive) {
              deletingRegion = region
            }
          } label: {
            Image(systemName: "ellipsis")
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .accessibilityLabel("Aktionen für \(region.name)")
        }
        .listRowBackground(
          RoundedRectangle(cornerRadius: 8)
            .fill(active ? Color.accentColor.opacity(0.10) : .clear))
        .disabled(model.busy)
        .contextMenu {
          Button("Kartendetails", systemImage: "info.circle") { regionDetails = region }
          Button("Region löschen …", systemImage: "trash", role: .destructive) {
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
      Text("Offline-Karten")
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
      Text("Importprofil: \(options.poiPreset.displayName)")
        .font(.caption).foregroundStyle(.secondary)
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
      .frame(minHeight: 44, alignment: .leading)
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
    } footer: {
      if model.pending == nil {
        Text(
          "Wähle die Region oder die lokale PBF-Datei erneut aus, um es noch einmal zu versuchen.")
      }
    }
  }

  private var sourceStorage: some View {
    Section {
      DisclosureGroup(isExpanded: $storageExpanded) {
        if !model.installed.isEmpty {
          LabeledContent(
            "Offline-Karten", value: model.installedBytes.formatted(.byteCount(style: .file)))
        }
        if model.downloadBytes > 0 {
          LabeledContent(
            "PBF-Downloads", value: model.downloadBytes.formatted(.byteCount(style: .file)))
          Button("Downloads entfernen …", systemImage: "trash", role: .destructive) {
            clearingDownloads = true
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .disabled(model.busy || model.pending != nil)
          Text(
            model.pending == nil
              ? "Quelldateien können nach dem Import entfernt werden. Deine Karten bleiben verfügbar."
              : "Die Quelldatei wird noch für den unterbrochenen Import benötigt.")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
      } label: {
        Label("Speicher", systemImage: "internaldrive")
      }
      if let error = model.storageError {
        DisclosureGroup {
          Text(error).font(.caption).textSelection(.enabled)
        } label: {
          Label("Speicherbelegung nicht verfügbar", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct DemoRegionDetails: View {
  let region: InstalledRegion
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(region.name, systemImage: "map").font(.title3.weight(.semibold))
          LabeledContent("Speicher", value: region.byteCount.formatted(.byteCount(style: .file)))
          LabeledContent("Importprofil", value: region.poiPreset?.displayName ?? "Bisheriger Import")
          if let date = region.importedAt {
            LabeledContent("Importiert", value: date.formatted(date: .abbreviated, time: .omitted))
          }
        }
        if region.poiPreset != nil,
          (region.importRevision ?? 0) < RegionManifest.currentImportRevision
        {
          Text("Erneut importieren, um aktuelle Importregeln zu nutzen.")
            .font(.callout).foregroundStyle(.secondary)
        }
        if region.format < RegionManifest.currentFormat {
          Text("Erneut importieren, um Speicherplatz zu sparen.")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Kartendetails")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Schließen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 400, idealWidth: 460, minHeight: 320)
    #else
      .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    #endif
  }
}

private struct DemoAddMapSheet: View {
  let model: DemoModel
  @Environment(\.dismiss) private var dismiss
  @State private var showingSliceDownload = false
  @State private var importing = false
  @State private var fileError: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          DemoImportPresetPicker(model: model)
        } header: {
          Text("Importprofil")
        }
        Section {
          Button {
            showingSliceDownload = true
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text("Umkreis herunterladen")
                Text("30 bis 150 km um deinen Standort · SliceOSM")
                  .font(.caption).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "location.circle")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Button {
            importing = true
          } label: {
            Label("Lokale PBF importieren …", systemImage: "doc.badge.plus")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Eine gespeicherte .osm.pbf-Datei auf diesem Gerät auswählen.")
        } header: {
          Text("Umkreis oder Datei")
        }.disabled(model.busy || model.pending != nil)
        CatalogPicker(model: model)
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Karte hinzufügen")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Schließen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 440, idealWidth: 520, minHeight: 560, idealHeight: 680)
      .focusedSceneValue(
        \.importAction,
        DemoImportAction(
          perform: { importing = true },
          isEnabled: !model.busy && model.pending == nil))
    #else
      .presentationDetents([.large]).presentationDragIndicator(.visible)
    #endif
    .sheet(isPresented: $showingSliceDownload) { DemoSliceDownload(model: model) }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): model.importFile(url)
      case .failure(let error): fileError = FileDialogError.message(for: error)
      }
    }
    .alert(
      "Datei konnte nicht geöffnet werden",
      isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })
    ) {
      Button("OK") { fileError = nil }
    } message: {
      Text(fileError ?? "")
    }
    .onChange(of: model.busy) { _, busy in
      if busy { dismiss() }
    }
  }
}

private struct CatalogPicker: View {
  @Bindable var model: DemoModel
  @State private var selectedRegion: CatalogSelection?
  @FocusState private var searchFocused: Bool

  private struct CatalogSelection: Identifiable {
    let region: OSMExtractRegion
    let source: OSMExtractSource
    let context: String
    var id: String { source.rawValue + "/" + region.id }
  }

  var body: some View {
    Section {
      Picker("Quelle", selection: Binding(
        get: { model.catalogSource },
        set: {
          searchFocused = false
          model.selectCatalogSource($0)
          Task { await model.loadCatalog() }
        }
      )) {
        ForEach(OSMExtractSource.allCases) { source in
          Text(source.displayName).tag(source)
        }
      }
      .pickerStyle(.menu)
      Text("Die Quellen bieten unterschiedliche Regionszuschnitte.")
        .font(.caption).foregroundStyle(.secondary).lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Region oder Land suchen", text: $model.catalogQuery)
          .autocorrectionDisabled()
          .accessibilityLabel("Region oder Land suchen")
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
          Label(
            model.catalogLoaded
              ? "Katalog konnte nicht aktualisiert werden" : "Katalog momentan nicht erreichbar",
            systemImage: "wifi.exclamationmark"
          )
          .font(.callout)
          Text(
            model.catalogLoaded
              ? "Die bereits geladenen Regionen werden weiter angezeigt. Versuche die Aktualisierung später erneut."
              : "Prüfe die Internetverbindung und versuche es erneut."
          )
          .font(.caption).foregroundStyle(.secondary)
          DisclosureGroup("Fehlerdetails") {
            Text(error).font(.caption).textSelection(.enabled)
          }
        }
      }
      if !model.catalogLoaded, !model.catalogLoading, model.catalogError == nil {
        Text("Lade den Katalog, um verfügbare Regionen zu durchsuchen.")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        if !query.isEmpty {
          Button("Alle Regionen anzeigen") { model.catalogQuery = "" }.buttonStyle(.plain)
        }
      }
      ForEach(model.filteredRegions) { region in
        Button {
          searchFocused = false
          selectedRegion = CatalogSelection(
            region: region, source: model.catalogSource, context: model.catalogContext(for: region))
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
        .buttonStyle(.plain)
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
      .frame(minHeight: 44, alignment: .leading)
      .buttonStyle(.plain)
      .disabled(model.catalogLoading)
    } header: {
      Text("Region herunterladen")
    } footer: {
      Text(
        model.busy
          ? "Ein Vorgang läuft. Anschließend kannst du eine weitere Region laden."
          : model.pending != nil
            ? "Schließe zuerst den unterbrochenen Import ab oder entferne seine Fortsetzung aus der Liste."
            : "Zum Herunterladen ist Internet nötig. Die Region wird danach automatisch für die Offline-Nutzung aufbereitet."
      )
      .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
      .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
    }
    .sheet(item: $selectedRegion) { selection in
      CatalogDownloadSheet(
        model: model, region: selection.region, source: selection.source, context: selection.context)
    }
  }
}

private struct CatalogDownloadSheet: View {
  let model: DemoModel
  let region: OSMExtractRegion
  let source: OSMExtractSource
  let context: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label(region.name, systemImage: "map").font(.title2.bold())
            if !context.isEmpty { Text(context).foregroundStyle(.secondary) }
          }
          .padding(.vertical, 4)
          Label("PBF von \(source.displayName) herunterladen", systemImage: "arrow.down.circle")
          Label("Karte, Suche und Routing lokal aufbereiten", systemImage: "gearshape.2")
          Label("Anschließend ohne Internet nutzen", systemImage: "checkmark.circle")
        } footer: {
          Text(
            "Die Aufbereitung kann mehrere Minuten dauern und benötigt zusätzlichen freien Speicher. Für große Regionen empfiehlt sich die Aufbereitung auf einem Mac."
          )
          .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button {
          dismiss()
          model.download(region, source: source)
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
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Abbrechen") { dismiss() }
            .frame(minHeight: 44)
        }
      }
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
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            Text(
              model.activity == .downloading && model.pending == nil ? "Download" : "Aktuelle Phase"
            )
            Spacer(minLength: 8)
            Text(fraction, format: .percent.precision(.fractionLength(0)))
              .monospacedDigit()
          }
          .font(.caption)
          .accessibilityHidden(true)
          ProgressView(value: fraction)
            .accessibilityLabel(
              model.activity == .downloading && model.pending == nil ? "Download" : "Aktuelle Phase"
            )
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
        }
      } else {
        ProgressView().accessibilityLabel(title)
      }
      Text(
        model.cancelling ? "Bitte kurz warten, bis der Vorgang sicher beendet ist." : model.status
      )
      .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      if !model.cancelling, model.pending != nil,
        model.activity == .importing || model.activity == .downloading
      {
        Text("Die Aufbereitung läuft in mehreren Phasen. Jede Phase hat ihren eigenen Fortschritt.")
          .font(.caption).foregroundStyle(.secondary)
      }
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
        .frame(minHeight: 44, alignment: .leading)
        .disabled(model.cancelling)
      }
    }
    .padding(.vertical, 4)
  }
}
