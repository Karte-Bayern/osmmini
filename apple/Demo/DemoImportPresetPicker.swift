import OSMmini
import SwiftUI

struct DemoImportPresetPicker: View {
  let model: DemoModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        "Profil",
        selection: Binding(get: { model.selectedPOIPreset }, set: model.selectPOIPreset)
      ) {
        ForEach(POIImportPreset.allCases) { preset in
          Text(preset.displayName).tag(preset)
        }
      }
      .pickerStyle(.menu)
      .disabled(model.busy || model.pending != nil)
      Text(model.selectedPOIPreset.summary)
        .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
      Text("Ein Profilwechsel erfordert einen erneuten Import. Routing bleibt unverändert.")
        .font(.caption2).fontWeight(.regular).foregroundStyle(.secondary)
        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
    }
  }
}
