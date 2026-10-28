import OSMmini
import SwiftUI
import UniformTypeIdentifiers

struct DemoMapLayersSection: View {
  let model: DemoModel
  let showMap: () -> Void
  @State private var importing = false
  @State private var error: String?

  static let contentType = UTType(importedAs: "com.google.earth.kml", conformingTo: .xml)

  var body: some View {
    Section {
      ForEach(model.layers.entries) { entry in
        HStack(spacing: 8) {
          Button {
            model.focusMapLayer(id: entry.id)
            showMap()
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Label(entry.name, systemImage: "square.3.layers.3d")
                .lineLimit(2)
              Text("\(entry.document.features.count) Objekte · \(entry.isVisible ? "Eingeblendet" : "Ausgeblendet")")
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Auf \(entry.name) zoomen")
            .accessibilityValue(entry.isVisible ? "Eingeblendet" : "Ausgeblendet")
          Menu { actions(for: entry) } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
          }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Aktionen für \(entry.name)")
        }
        .contextMenu { actions(for: entry) }
        .disabled(model.layers.isLoading || model.layers.isImporting)
      }
      ForEach(model.layers.unreadableEntries) { entry in
        VStack(alignment: .leading, spacing: 6) {
          Label(entry.name, systemImage: "exclamationmark.triangle")
            .lineLimit(2)
          Text("Nicht lesbar. Beim Entfernen des Eintrags bleiben vorhandene Dateien erhalten.")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
          Button("Aus Liste entfernen", systemImage: "minus.circle", role: .destructive) {
            change { try model.layers.forgetUnreadable(id: entry.id) }
          }
          .frame(minHeight: 44)
          .accessibilityLabel("\(entry.name) aus der Liste entfernen")
          .accessibilityHint("Vorhandene KML-Dateien bleiben erhalten.")
        }
        .disabled(model.layers.isLoading || model.layers.isImporting)
      }
      if model.layers.isLoading || model.layers.isImporting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(model.layers.isImporting ? "KML wird importiert …" : "Ebenen werden geladen …")
            .font(.callout)
        }
        if model.layers.isImporting {
          Button("KML-Import abbrechen", role: .cancel) { model.cancelMapLayerImport() }
        }
      } else {
        Button { importing = true } label: {
          Label("KML importieren …", systemImage: "doc.badge.plus")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Orte, Linien und Flächen aus einer lokalen KML-Datei anzeigen.")
      }
      if let warning = model.layers.error {
        Text(warning).font(.caption).foregroundStyle(.secondary)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Kartenebenen")
    } footer: {
      if !model.layers.entries.isEmpty {
        Text("KML-Dateien lokal anzeigen. Die Originaldateien bleiben erhalten.")
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [Self.contentType]) { result in
      switch result {
      case .success(let url): model.importMapLayer(url)
      case .failure(let failure): error = FileDialogError.message(for: failure)
      }
    }
    .alert(
      "Kartenebene konnte nicht geändert werden",
      isPresented: Binding(
        get: { error != nil },
        set: { if !$0 { error = nil } })
    ) {
      Button("OK") { error = nil }
    } message: {
      Text(error ?? "")
    }
  }

  @ViewBuilder private func actions(for entry: DemoMapLayers.Entry) -> some View {
    Button("Auf Ebene zoomen", systemImage: "viewfinder") {
      model.focusMapLayer(id: entry.id)
      showMap()
    }
    Button(
      entry.isVisible ? "Ausblenden" : "Einblenden",
      systemImage: entry.isVisible ? "eye.slash" : "eye"
    ) { change { try model.layers.toggleVisible(id: entry.id) } }
    Button("Ebene entfernen", systemImage: "trash", role: .destructive) {
      change { try model.layers.remove(id: entry.id) }
    }
  }

  private func change(_ work: () throws -> Void) {
    do { try work() } catch { self.error = error.localizedDescription }
  }
}
