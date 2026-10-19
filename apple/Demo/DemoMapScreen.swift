import OSMmini
import SwiftUI

#if os(iOS)
  import UIKit
#endif

struct DemoMapScreen: View {
  let model: DemoModel
  let location: DemoLocation
  let showRegions: () -> Void
  @Environment(\.openURL) private var openURL
  @State private var searching = false
  @State private var searchTarget: DemoModel.RoutePoint?
  @State private var planning = false
  @State private var directions = false
  @State private var awaitingLocation = false

  var body: some View {
    GeometryReader { geometry in
      DemoMapCanvas(model: model, location: location)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          ViewThatFits(in: .vertical) {
            inspector.fixedSize(horizontal: false, vertical: true)
            ScrollView { inspector }.scrollBounceBehavior(.basedOnSize)
          }
          .frame(maxHeight: min(340, geometry.size.height * 0.45))
          .background(.regularMaterial)
        }
    }
    .navigationTitle(model.engine?.manifest.name ?? "Offline-Karte")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Orte suchen", systemImage: "magnifyingglass") {
          searchTarget = nil
          searching = true
        }.disabled(model.engine == nil)
        Button(
          planning ? "Routendetails ausblenden" : "Route planen",
          systemImage: "point.topleft.down.to.point.bottomright.curvepath"
        ) {
          if model.inspectedPlace != nil {
            model.dismissPlace()
            planning = true
          } else {
            planning.toggle()
          }
        }.disabled(model.engine == nil)
        Button {
          showLocation()
        } label: {
          if location.isLocating {
            ProgressView()
          } else {
            Image(systemName: location.isUpdating ? "location.fill" : "location")
          }
        }
        .accessibilityLabel(
          location.isLocating ? "Standort wird ermittelt" : "Meinen Standort anzeigen"
        )
        .help("Standort ermitteln und auf der Offline-Karte anzeigen")
        .disabled(model.engine == nil)
      }
    }
    .sheet(isPresented: $searching) {
      DemoPlaceSearch(model: model, target: searchTarget) { result in
        if let searchTarget {
          model.usePlace(DemoPlace(result), as: searchTarget)
          planning = true
        } else {
          model.inspect(result)
        }
        searching = false
      }
    }
    .sheet(isPresented: $directions) { directionsSheet }
    .onChange(of: location.coordinate) { _, coordinate in
      guard awaitingLocation, let coordinate else { return }
      awaitingLocation = false
      if model.contains(coordinate) { model.focusOn(coordinate) }
    }
    .onChange(of: location.isUpdating) { _, updating in
      if !updating { awaitingLocation = false }
    }
    .onChange(of: model.activeDirectory) { _, _ in
      planning = false
      searching = false
      searchTarget = nil
      directions = false
      awaitingLocation = false
    }
    .onChange(of: model.start != nil || model.destination != nil, initial: true) { _, hasPoints in
      planning = hasPoints
    }
  }

  private var inspector: some View {
    VStack(spacing: 0) {
      if location.state != .idle { locationStatus }
      if let place = model.inspectedPlace {
        placeCard(place).padding()
      } else if planning {
        routeCard.padding()
      } else if model.busy {
        ActivityProgress(model: model).padding()
      } else if model.start != nil || model.destination != nil {
        Button {
          planning = true
        } label: {
          Label(
            model.route == nil ? "Routenplanung fortsetzen" : "Route · \(routeSummary)",
            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
          )
          .font(.callout).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).padding(.horizontal)
      } else if model.engine != nil {
        Label(
          "Ort antippen oder suchen · Karte und Routing offline", systemImage: "checkmark.circle"
        )
        .font(.caption).foregroundStyle(.secondary).padding(10)
        .frame(maxWidth: .infinity)
      }
    }
  }

  private func showLocation() {
    if let coordinate = location.coordinate {
      if model.contains(coordinate) { model.focusOn(coordinate) }
    } else {
      awaitingLocation = true
      location.start()
    }
  }

  private var locationStatus: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        Label(location.status, systemImage: "location")
          .font(.caption).foregroundStyle(location.error == nil ? Color.secondary : .red)
        Spacer()
        if location.isUpdating {
          Button("Stoppen") { location.stop() }.font(.caption).frame(minHeight: 44)
        } else if location.coordinate == nil {
          Button("Erneut versuchen") { showLocation() }.font(.caption).frame(minHeight: 44)
        }
      }
      #if os(iOS)
        if location.state == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
          Button("App-Einstellungen öffnen") { openURL(url) }.font(.caption)
        }
      #endif
      if let coordinate = location.coordinate {
        if !model.contains(coordinate) {
          Text("Dein Standort liegt außerhalb der geöffneten Offline-Region.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Andere Region auswählen", action: showRegions).font(.caption)
        } else {
          Button("Standort als Start verwenden") {
            model.usePlace(
              DemoPlace(coordinate: coordinate, name: "Mein Standort", category: nil), as: .start)
            planning = true
          }.font(.caption).disabled(model.busy)
        }
      }
    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
  }

  private func placeCard(_ place: DemoPlace) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(place.name).font(.headline).lineLimit(2)
          Text(DemoPlaceText.category(place.category, kind: place.kind)).font(.caption)
            .foregroundStyle(.secondary)
          Text(DemoPlaceText.coordinates(place.coordinate))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Spacer()
        Button {
          model.dismissPlace()
        } label: {
          Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(
            Rectangle())
        }.accessibilityLabel("Auswahl schließen").buttonStyle(.plain)
      }
      HStack {
        Button("Als Start", systemImage: "a.circle.fill") {
          model.usePlace(place, as: .start)
          planning = true
        }
        Button("Als Ziel", systemImage: "b.circle.fill") {
          model.usePlace(place, as: .destination)
          planning = true
        }
      }.buttonStyle(.bordered).disabled(model.busy)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var routeSummary: String {
    guard let route = model.route else { return "" }
    let kilometers = (route.distanceM / 1000).formatted(.number.precision(.fractionLength(1)))
    let minutes = max(1, route.durationS / 60).formatted(.number.precision(.fractionLength(0)))
    return "\(kilometers) km · \(minutes) Min."
  }

  private var routeCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        if let route = model.route {
          Text("\((route.distanceM / 1000).formatted(.number.precision(.fractionLength(1)))) km")
            .font(.headline)
          Text(
            "\(max(1, route.durationS / 60).formatted(.number.precision(.fractionLength(0)))) Min."
          )
          .foregroundStyle(.secondary)
        } else {
          Text("Route planen").font(.headline)
        }
        Spacer()
        Button {
          planning = false
        } label: {
          Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(
            Rectangle())
        }.accessibilityLabel("Routendetails schließen").buttonStyle(.plain)
      }
      HStack {
        endpoint(.start, name: model.startLabel, title: "Start wählen", image: "a.circle.fill")
        Button {
          model.swapRoutePoints()
        } label: {
          Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44).contentShape(
            Rectangle())
        }
        .accessibilityLabel("Start und Ziel tauschen").disabled(
          model.busy || model.start == nil || model.destination == nil)
        endpoint(
          .destination, name: model.destinationLabel, title: "Ziel wählen", image: "b.circle.fill")
      }
      Picker(
        "Routenberechnung",
        selection: Binding(
          get: { model.routeObjective }, set: { model.setRouteObjective($0) }
        )
      ) {
        Text("Auto · kürzeste Strecke").tag(RouteObjective.distance)
        Text("Auto · schnellste Strecke").tag(RouteObjective.duration)
      }.pickerStyle(.menu).font(.caption).disabled(model.busy)
      if model.start != nil || model.destination != nil {
        Button("Route zurücksetzen", systemImage: "arrow.counterclockwise") { model.clearRoute() }
          .font(.caption).disabled(model.busy && model.activity != .routing)
      }
      if model.busy {
        ActivityProgress(model: model)
      } else if let error = model.routeError {
        Text(error).font(.callout).foregroundStyle(.red)
      } else if model.route == nil {
        Text(model.routeSelectionHint).font(.caption).foregroundStyle(.secondary)
      }
      if let route = model.route {
        HStack {
          if !route.steps.isEmpty {
            Button("Wegbeschreibung", systemImage: "list.bullet") { directions = true }
          }
          RouteExporter(route: route)
        }
        if max(route.fromSnapM, route.toSnapM) > 100 {
          Text("Die Route beginnt oder endet an einer nahegelegenen befahrbaren Straße.")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else if model.canCalculateRoute {
        Button("Route erneut berechnen", systemImage: "arrow.clockwise") { model.retryRoute() }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func endpoint(_ point: DemoModel.RoutePoint, name: String?, title: String, image: String)
    -> some View
  {
    Button {
      model.chooseRoutePoint(point)
      searchTarget = point
      searching = true
    } label: {
      Label(name ?? title, systemImage: image).font(.subheadline).lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(.bordered).disabled(model.busy)
  }

  private var directionsSheet: some View {
    NavigationStack {
      List {
        if let route = model.route {
          ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
            Button {
              model.focusOn(Coordinate(lat: step.lat, lon: step.lon))
              directions = false
            } label: {
              HStack(alignment: .top) {
                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                Text(step.instruction).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      }
      .navigationTitle("Wegbeschreibung")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Schließen") { directions = false } }
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 450)
    #endif
    .presentationDetents([.medium, .large])
  }
}

private struct DemoMapCanvas: View {
  let model: DemoModel
  let location: DemoLocation
  var body: some View {
    if let engine = model.engine {
      OfflineMap(
        engine: engine, route: model.route,
        focus: model.focus, focusRequest: model.focusRequest,
        routeStart: model.start, routeDestination: model.destination,
        selection: model.inspectedPlace?.coordinate, userLocation: location.coordinate,
        userLocationAccuracy: location.horizontalAccuracy, onSelect: model.inspect
      ).id(ObjectIdentifier(engine))
    } else {
      ContentUnavailableView {
        Label("Deine Region offline", systemImage: "map")
      } description: {
        Text(
          "Eine Region laden oder eine lokale PBF importieren. Danach bleiben Karte, Suche und Routing offline verfügbar."
        )
      }
    }
  }
}

private struct DemoPlaceSearch: View {
  @Bindable var model: DemoModel
  let target: DemoModel.RoutePoint?
  let selected: (SearchResult) -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        TextField("Ort, Straße, Adresse oder POI", text: $model.query)
          .textFieldStyle(.roundedBorder).autocorrectionDisabled().submitLabel(.search)
          .focused($focused).padding().onSubmit { focused = false }
        List {
          if model.searching { ProgressView("Suche in der Offline-Region …") }
          if let error = model.searchError { Text(error).foregroundStyle(.red) }
          if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(
              "Suche in \(model.engine?.manifest.name ?? "der geöffneten Region"). Es wird keine Internetverbindung benötigt."
            )
            .foregroundStyle(.secondary)
          } else if !model.searching, model.results.isEmpty, model.searchError == nil {
            ContentUnavailableView.search(text: model.query)
          }
          ForEach(model.results, id: \.identity) { result in
            Button {
              selected(result)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(result.label).foregroundStyle(.primary)
                Text(DemoPlaceText.category(result.category, kind: result.kind))
                  .font(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(model.busy)
          }
        }.listStyle(.plain)
      }
      .navigationTitle(
        target == .start ? "Start suchen" : target == .destination ? "Ziel suchen" : "Orte suchen"
      )
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 450)
    #endif
    .presentationDetents([.medium, .large])
    .task { focused = true }
  }
}

enum DemoPlaceText {
  static func coordinates(_ coordinate: Coordinate) -> String {
    String(
      format: "%.5f° %@ · %.5f° %@", locale: Locale(identifier: "en_US_POSIX"),
      abs(coordinate.lat), coordinate.lat < 0 ? "S" : "N",
      abs(coordinate.lon), coordinate.lon < 0 ? "W" : "E")
  }

  static func category(_ category: String?, kind: String? = nil) -> String {
    if kind == "street" { return "Straße" }
    switch category {
    case "city", "town": return "Stadt"
    case "village", "hamlet", "isolated_dwelling": return "Ort"
    case "suburb", "quarter", "neighbourhood": return "Ortsteil"
    case "cafe": return "Café"
    case "restaurant": return "Restaurant"
    case "pharmacy": return "Apotheke"
    case "hospital": return "Krankenhaus"
    case "doctors": return "Arztpraxis"
    case "supermarket": return "Supermarkt"
    case "bakery": return "Bäckerei"
    case "school": return "Schule"
    case "kindergarten": return "Kindergarten"
    case "parking": return "Parkplatz"
    case "fuel": return "Tankstelle"
    case "charging_station": return "Ladestation"
    case "hotel": return "Hotel"
    case "station": return "Bahnhof"
    default: return kind == "node" || kind == "way" ? "Adresse oder Ort" : "Kartenpunkt"
    }
  }
}
