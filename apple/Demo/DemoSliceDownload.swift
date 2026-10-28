import OSMmini
import SwiftUI

#if os(iOS)
  import UIKit
#endif

struct DemoSliceDownload: View {
  let model: DemoModel
  @State private var selection = DemoSliceSelection()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        Section {
          if let coordinate = selection.coordinate {
            Label("Mittelpunkt festgelegt", systemImage: "location.fill")
              .font(.headline)
            Text(DemoPlaceText.coordinates(coordinate))
              .font(.callout.monospacedDigit()).textSelection(.enabled)
            Text(selection.status).font(.caption).foregroundStyle(.secondary)
              .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
          } else if selection.isLocating {
            HStack(spacing: 12) {
              ProgressView().controlSize(.small)
              Text(selection.status).font(.callout)
            }
          } else {
            Label(
              selection.error == nil ? "Wähle deinen aktuellen Standort als Mittelpunkt." : selection.status,
              systemImage: selection.error == nil ? "location.circle" : "location.slash"
            )
            .font(.callout).foregroundStyle(.secondary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
          }
          Button(
            selection.coordinate == nil ? "Standort ermitteln" : "Standort neu ermitteln",
            systemImage: "location"
          ) { selection.requestLocation() }
          .frame(minHeight: 44)
          .disabled(selection.isLocating || model.busy)
          if selection.isLocating {
            Button("Standortsuche abbrechen", role: .cancel) { selection.stopLocating() }
              .frame(minHeight: 44)
          }
          #if os(iOS)
            if selection.location.state == .denied,
              let url = URL(string: UIApplication.openSettingsURLString)
            {
              Link("App-Einstellungen öffnen", destination: url).frame(minHeight: 44)
            }
          #endif
        } header: {
          Text("Mittelpunkt")
        }
        Section {
          Picker("Radius", selection: $selection.radius) {
            ForEach(DemoSliceSelection.Radius.allCases) { radius in
              Text("\(radius.rawValue) km").tag(radius)
            }
          }.pickerStyle(.menu)
          Text("\(selection.radiusKM) km in jede Richtung · \(selection.radiusKM * 2) km Durchmesser")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        } header: {
          Text("Umkreis")
        }
        Section {
          DemoImportPresetPicker(model: model)
        } header: {
          Text("Importprofil")
        }
        Section {
          Label("SliceOSM erstellt den kreisförmigen Ausschnitt.", systemImage: "circle.dashed")
          Label("Karte, Suche und Routing werden auf diesem Gerät aufbereitet.", systemImage: "map")
          VStack(alignment: .leading, spacing: 8) {
            Text("Mittelpunkt und Umkreis werden beim Start an SliceOSM übertragen.")
            Text(
              "Große Umkreise benötigen mehr Datenvolumen und Speicher. In dicht besiedelten Gebieten kann ein kleinerer Umkreis nötig sein."
            )
          }
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
      }
      .environment(\.lineLimit, nil)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button {
          guard let coordinate = selection.coordinate else { return }
          let radius = selection.radiusKM
          selection.stopLocating()
          dismiss()
          model.downloadSlice(center: coordinate, radiusKM: radius)
        } label: {
          Label("Ausschnitt erstellen und laden", systemImage: "arrow.down.to.line")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selection.coordinate == nil || selection.isLocating || model.busy || model.pending != nil)
        .padding().background(.bar)
      }
      .navigationTitle("Umkreis herunterladen")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, idealWidth: 500, minHeight: 560, idealHeight: 640)
    #else
      .presentationDetents([.large]).presentationDragIndicator(.visible)
    #endif
    .onChange(of: selection.location.state) { _, _ in selection.captureLocationIfReady() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { selection.stopLocating() }
    }
    .onChange(of: model.busy) { _, busy in
      if busy { selection.stopLocating() }
    }
    .onDisappear { selection.stopLocating() }
  }
}
