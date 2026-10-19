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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var searching = false
  @State private var searchTarget: DemoModel.RoutePoint?
  @State private var planning = false
  @State private var directions = false
  @State private var awaitingLocation = false
  @State private var mapTarget: DemoModel.RoutePoint?
  @State private var routeDetailsExpanded = true
  @State private var inspectorHeight: CGFloat = 0

  var body: some View {
    GeometryReader { geometry in
      let metrics = DemoMapLayoutMetrics(
        size: geometry.size, accessibility: dynamicTypeSize.isAccessibilitySize,
        expanded: showsExpandedInspector)
      let layout =
        metrics.sideWidth == nil
        ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
      // AnyLayout keeps the same map and exporter alive when a window resizes
      // or Duo changes displays. Only their placement and proposals change.
      layout {
        DemoMapCanvas(model: model, location: location, onSelect: selectMapPoint)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        ScrollView {
          inspector
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: {
              inspectorHeight = $0
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
          width: metrics.sideWidth,
          height: metrics.sideWidth == nil
            ? min(max(1, inspectorHeight), metrics.maximumBottomHeight) : geometry.size.height
        )
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
          Rectangle().fill(.quaternary).frame(width: metrics.sideWidth == nil ? 0 : 1)
            .allowsHitTesting(false)
        }
      }
    }
    .navigationTitle(model.engine?.manifest.name ?? "Offline-Karte")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Orte suchen", systemImage: "magnifyingglass") {
          openSearch(for: nil)
        }.disabled(model.engine == nil)
        Button(
          planning ? "Routendetails ausblenden" : "Route planen",
          systemImage: "point.topleft.down.to.point.bottomright.curvepath"
        ) { togglePlanning() }.disabled(model.engine == nil)
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
    .focusedSceneValue(
      \.mapActions,
      DemoMapActions(
        search: { openSearch(for: nil) }, plan: togglePlanning, showRegions: showRegions,
        isEnabled: model.engine != nil)
    )
    .sheet(isPresented: $searching) {
      DemoPlaceSearch(model: model, target: searchTarget) { result in
        if let searchTarget {
          model.usePlace(DemoPlace(result), as: searchTarget, minimumZoom: 14)
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
      mapTarget = nil
      routeDetailsExpanded = true
    }
    .onChange(of: model.busy) { _, busy in
      if busy { mapTarget = nil }
    }
    .onChange(of: model.start != nil || model.destination != nil, initial: true) { _, hasPoints in
      planning = hasPoints
    }
  }

  private var showsExpandedInspector: Bool {
    mapTarget != nil || model.inspectedPlace != nil || planning || model.busy
      || location.state != .idle
  }

  private func togglePlanning() {
    mapTarget = nil
    if model.inspectedPlace != nil {
      model.dismissPlace()
      planning = true
    } else {
      planning.toggle()
    }
    routeDetailsExpanded = true
  }

  private var inspector: some View {
    VStack(spacing: 0) {
      if let mapTarget {
        mapSelectionCard(mapTarget)
      } else if let place = model.inspectedPlace {
        placeCard(place).padding()
      } else if planning {
        routeCard.padding()
      } else if model.busy {
        ActivityProgress(model: model).padding()
      } else if model.start != nil || model.destination != nil {
        Button {
          planning = true
          routeDetailsExpanded = true
        } label: {
          Label(
            model.route == nil ? "Routenplanung fortsetzen" : "Route · \(routeSummary)",
            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
          )
          .font(.callout).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).padding(.horizontal)
      } else if model.engine != nil {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            Label("Karte antippen oder Ort suchen", systemImage: "hand.tap")
            Spacer(minLength: 8)
            Label("Offline", systemImage: "checkmark.circle")
          }.fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: 6) {
            Label("Karte antippen oder Ort suchen", systemImage: "hand.tap")
            Label("Offline verfügbar", systemImage: "checkmark.circle")
          }
        }
        .font(.caption).foregroundStyle(.secondary).padding(12)
        .frame(maxWidth: .infinity)
      }
      if location.state != .idle, mapTarget == nil { locationStatus }
    }
  }

  private func openSearch(for point: DemoModel.RoutePoint?) {
    mapTarget = nil
    if let point { model.chooseRoutePoint(point) }
    searchTarget = point
    searching = true
  }

  private func selectMapPoint(_ coordinate: Coordinate) {
    if let mapTarget {
      guard !model.busy else { return }
      model.usePlace(
        DemoPlace(coordinate: coordinate, name: "Punkt auf der Karte", category: nil), as: mapTarget
      )
      self.mapTarget = nil
      planning = true
      routeDetailsExpanded = true
    } else {
      model.inspect(coordinate)
    }
  }

  private func mapSelectionCard(_ point: DemoModel.RoutePoint) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        point == .start ? "Startpunkt auf Karte wählen" : "Zielpunkt auf Karte wählen",
        systemImage: point == .start ? "a.circle.fill" : "b.circle.fill"
      ).font(.headline)
      Text("Karte verschieben und die gewünschte Stelle antippen.")
        .font(.caption).foregroundStyle(.secondary)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { mapSelectionActions(point) }
          .fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: 8) { mapSelectionActions(point) }
      }.font(.callout).buttonStyle(.bordered)
    }.padding().frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func mapSelectionActions(_ point: DemoModel.RoutePoint) -> some View {
    Button("Stattdessen suchen", systemImage: "magnifyingglass") { openSearch(for: point) }
      .frame(minHeight: 44)
    Button("Abbrechen", role: .cancel) { mapTarget = nil }.frame(minHeight: 44)
  }

  private func showLocation() {
    if let coordinate = location.coordinate {
      if model.contains(coordinate) { model.focusOn(coordinate) }
    } else {
      awaitingLocation = true
      location.start()
    }
  }

  @ViewBuilder private var locationStatus: some View {
    if location.state == .ready, let coordinate = location.coordinate, model.contains(coordinate) {
      HStack(spacing: 8) {
        Label(location.status, systemImage: "location.fill")
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer(minLength: 0)
        Menu {
          Button("Standort auf Karte anzeigen", systemImage: "location") {
            model.focusOn(coordinate)
          }
          Button("Standort als Start verwenden", systemImage: "a.circle.fill") {
            useLocationAsStart(coordinate)
          }.disabled(model.busy)
          #if os(iOS)
            if !location.hasPreciseLocation,
              let url = URL(string: UIApplication.openSettingsURLString)
            {
              Button("Genauen Standort erlauben", systemImage: "gear") { openURL(url) }
            }
          #endif
          Button("Standort ausschalten", systemImage: "location.slash") { location.stop() }
        } label: {
          Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
        }.accessibilityLabel("Standortaktionen")
      }.padding(.horizontal, 12)
    } else {
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
            Button("Standort als Start verwenden") { useLocationAsStart(coordinate) }
              .font(.caption).disabled(model.busy)
          }
        }
      }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func useLocationAsStart(_ coordinate: Coordinate) {
    model.usePlace(
      DemoPlace(coordinate: coordinate, name: "Mein Standort", category: nil), as: .start)
    planning = true
    routeDetailsExpanded = true
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
      ViewThatFits(in: .horizontal) {
        HStack { placeActions(place) }.fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading) { placeActions(place) }
      }.buttonStyle(.bordered).disabled(model.busy)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func placeActions(_ place: DemoPlace) -> some View {
    Button("Als Start", systemImage: "a.circle.fill") {
      model.usePlace(place, as: .start)
      planning = true
      routeDetailsExpanded = true
    }.frame(minHeight: 44)
    Button("Als Ziel", systemImage: "b.circle.fill") {
      model.usePlace(place, as: .destination)
      planning = true
      routeDetailsExpanded = true
    }.frame(minHeight: 44)
  }

  private var routeSummary: String {
    guard let route = model.route else { return "" }
    let kilometers = (route.distanceM / 1000).formatted(.number.precision(.fractionLength(1)))
    let minutes = max(1, route.durationS / 60).formatted(.number.precision(.fractionLength(0)))
    return "\(kilometers) km · \(minutes) Min."
  }

  private var routeCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        Button {
          routeDetailsExpanded.toggle()
        } label: {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
              Text(model.route == nil ? "Route planen" : routeSummary).font(.headline)
              if !routeDetailsExpanded {
                Text(model.route == nil ? "Start und Ziel wählen" : "Routendetails und Export")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            Image(systemName: routeDetailsExpanded ? "chevron.down" : "chevron.up")
              .font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          routeDetailsExpanded ? "Routendetails reduzieren" : "Routendetails einblenden"
        )
        .accessibilityValue(
          "\(routeDetailsExpanded ? "Erweitert" : "Reduziert"). \(model.route == nil ? "Autoroute planen" : routeSummary)"
        )
        Button {
          planning = false
        } label: {
          Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(
            Rectangle())
        }.accessibilityLabel("Routenplanung ausblenden").buttonStyle(.plain)
      }
      if routeDetailsExpanded {
        HStack(spacing: 10) {
          VStack(spacing: 8) {
            endpoint(.start, name: model.startLabel, title: "Start wählen", image: "a.circle.fill")
            endpoint(
              .destination, name: model.destinationLabel, title: "Ziel wählen",
              image: "b.circle.fill"
            )
          }
          Button {
            model.swapRoutePoints()
          } label: {
            Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
          .accessibilityLabel("Start und Ziel tauschen")
          .help("Start und Ziel tauschen")
          .disabled(model.busy || model.start == nil || model.destination == nil)
        }
        Picker(
          "Autoroute",
          selection: Binding(
            get: { model.routeObjective }, set: { model.setRouteObjective($0) }
          )
        ) {
          Text("Kürzeste Strecke").tag(RouteObjective.distance)
          Text("Schnellste Strecke").tag(RouteObjective.duration)
        }.pickerStyle(.menu).disabled(model.busy)
        if model.route == nil, !model.busy, model.routeError == nil {
          Text(model.routeSelectionHint).font(.caption).foregroundStyle(.secondary)
        }
      }
      if model.busy {
        ActivityProgress(model: model)
      } else if let error = model.routeError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red)
        if model.canCalculateRoute {
          Button("Route erneut berechnen", systemImage: "arrow.clockwise") { model.retryRoute() }
            .frame(minHeight: 44)
        }
      }
      if let route = model.route {
        AdaptiveActionLayout { routeActions(route) }.buttonStyle(.bordered)
        if routeDetailsExpanded, max(route.fromSnapM, route.toSnapM) > 100 {
          Text("Die Route beginnt oder endet an einer nahegelegenen befahrbaren Straße.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if routeDetailsExpanded, model.start != nil || model.destination != nil {
        Button("Route zurücksetzen", systemImage: "arrow.counterclockwise") { model.clearRoute() }
          .font(.caption).frame(minHeight: 44).disabled(model.busy && model.activity != .routing)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func routeActions(_ route: Route) -> some View {
    if !route.steps.isEmpty {
      Button("Wegbeschreibung", systemImage: "list.bullet") { directions = true }
        .frame(minHeight: 44)
    }
    RouteExporter(route: route).frame(minHeight: 44)
  }

  private func endpoint(_ point: DemoModel.RoutePoint, name: String?, title: String, image: String)
    -> some View
  {
    Menu {
      Button("Ort oder Adresse suchen", systemImage: "magnifyingglass") { openSearch(for: point) }
      Button("Auf der Karte wählen", systemImage: "hand.tap") {
        model.chooseRoutePoint(point)
        model.dismissPlace()
        mapTarget = point
      }
      if let coordinate = location.coordinate, model.contains(coordinate) {
        Button("Meinen Standort verwenden", systemImage: "location") {
          model.usePlace(
            DemoPlace(coordinate: coordinate, name: "Mein Standort", category: nil), as: point)
        }
      }
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: image).foregroundStyle(point == .start ? Color.green : .red)
        VStack(alignment: .leading, spacing: 2) {
          Text(point == .start ? "Start" : "Ziel").font(.caption).foregroundStyle(.secondary)
          Text(name ?? title).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
    .buttonStyle(.bordered).disabled(model.busy)
    .accessibilityLabel("\(point == .start ? "Start" : "Ziel"): \(name ?? "Noch nicht gewählt")")
    .accessibilityHint("Suche, Kartenpunkt oder eigenen Standort auswählen")
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
        ToolbarItem(placement: .cancellationAction) {
          Button("Schließen", role: .cancel) { directions = false }
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, idealWidth: 560, minHeight: 450, idealHeight: 620)
    #else
      .presentationDetents([.medium, .large])
    #endif
  }
}

/// Use the detail window's available size, independent of device name,
/// orientation and display count. Safe areas have already been applied here.
struct DemoMapLayoutMetrics {
  let sideWidth: CGFloat?
  let maximumBottomHeight: CGFloat

  init(size: CGSize, accessibility: Bool, expanded: Bool) {
    let width = size.width.isFinite ? max(0, size.width) : 0
    let height = size.height.isFinite ? max(0, size.height) : 0
    let desiredWidth = accessibility ? 380.0 : min(380, max(320, width / 3))
    sideWidth = expanded && height >= 340 && width - desiredWidth >= 400 ? desiredWidth : nil
    maximumBottomHeight = min(accessibility ? 520 : 340, height * (accessibility ? 0.65 : 0.45))
  }
}

/// Measure the actions' real width, keeping one instance of each child when
/// switching orientation. In particular, an active route export keeps its state.
private struct AdaptiveActionLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let layout = fitting(proposal.width, subviews: subviews)
    var layoutCache = layout.makeCache(subviews: subviews)
    return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &layoutCache)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let layout = fitting(bounds.width, subviews: subviews)
    var layoutCache = layout.makeCache(subviews: subviews)
    layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &layoutCache)
  }

  private func fitting(_ width: CGFloat?, subviews: Subviews) -> AnyLayout {
    let horizontal = AnyLayout(HStackLayout(spacing: 8))
    var cache = horizontal.makeCache(subviews: subviews)
    let size = horizontal.sizeThatFits(proposal: .unspecified, subviews: subviews, cache: &cache)
    if size.width <= (width ?? .infinity) { return horizontal }
    return AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
  }
}

private struct DemoMapCanvas: View {
  let model: DemoModel
  let location: DemoLocation
  let onSelect: (Coordinate) -> Void
  var body: some View {
    if let engine = model.engine {
      OfflineMap(
        engine: engine, route: model.route,
        focus: model.focus, focusRequest: model.focusRequest,
        focusMinimumZoom: model.focusMinimumZoom,
        routeStart: model.start, routeDestination: model.destination,
        selection: model.inspectedPlace?.coordinate, userLocation: location.coordinate,
        userLocationAccuracy: location.horizontalAccuracy, onSelect: onSelect
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
  @State private var presentationID = UUID()

  private var trimmedQuery: String {
    model.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Ort, Straße, Adresse oder POI", text: $model.query)
              .autocorrectionDisabled().submitLabel(.search)
              .focused($focused).onSubmit { focused = false }
              .accessibilityLabel("In der Offline-Region suchen")
            if !model.query.isEmpty {
              Button {
                model.query = ""
                focused = true
              } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                  .frame(minWidth: 44, minHeight: 44)
              }.buttonStyle(.plain).accessibilityLabel("Suchtext löschen")
            }
          }
          .padding(.leading, 12).frame(minHeight: 48)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
          Label(
            model.engine?.manifest.name ?? "Geöffnete Region", systemImage: "checkmark.circle"
          ).font(.caption).foregroundStyle(.secondary)
        }.padding()
        searchContent
      }
      .navigationTitle(
        target == .start ? "Start suchen" : target == .destination ? "Ziel suchen" : "Orte suchen"
      )
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
      .frame(minWidth: 420, idealWidth: 560, minHeight: 450, idealHeight: 620)
    #else
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    #endif
    .onAppear {
      model.resumeSearch(for: presentationID)
      focused = true
    }
    .onDisappear { model.suspendSearch(for: presentationID) }
  }

  @ViewBuilder private var searchContent: some View {
    if !trimmedQuery.isEmpty, !model.searching, model.searchError == nil, !model.results.isEmpty {
      searchResults
    } else {
      GeometryReader { geometry in
        ScrollView {
          searchStatus.frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
      }
    }
  }

  @ViewBuilder private var searchStatus: some View {
    if trimmedQuery.isEmpty {
      ContentUnavailableView {
        Label("Was suchst du?", systemImage: "magnifyingglass")
      } description: {
        Text(
          "Orte, Straßen, Hausnummern oder zum Beispiel Cafés suchen. Alle Ergebnisse stammen aus der geöffneten Offline-Region."
        )
      }
    } else if model.searching {
      VStack(spacing: 12) {
        ProgressView()
        Text("Offline-Region wird durchsucht …").font(.callout).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    } else if let error = model.searchError {
      ContentUnavailableView {
        Label("Suche nicht möglich", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        Button("Erneut suchen", systemImage: "arrow.clockwise") { model.retrySearch() }
          .buttonStyle(.bordered)
      }
    } else if model.results.isEmpty {
      ContentUnavailableView {
        Label("Keine passenden Orte", systemImage: "magnifyingglass")
      } description: {
        Text(
          "Für „\(trimmedQuery)“ gibt es hier keine Treffer. Versuche einen kürzeren Namen oder eine andere Schreibweise."
        )
      } actions: {
        Button("Suchbegriff ändern") { focused = true }.buttonStyle(.bordered)
      }
    }
  }

  private var searchResults: some View {
    List {
      Section("\(model.results.count) Treffer in der Offline-Region") {
        ForEach(model.results, id: \.identity) { result in
          Button {
            focused = false
            selected(result)
          } label: {
            HStack(alignment: .center, spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(result.label).foregroundStyle(.primary)
                Text(DemoPlaceText.category(result.category, kind: result.kind))
                  .font(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 4).frame(minHeight: 44)
          }
          .disabled(model.busy)
          .accessibilityHint(
            target == .start
              ? "Als Start übernehmen"
              : target == .destination ? "Als Ziel übernehmen" : "Auf der Karte anzeigen"
          )
        }
      }
    }.listStyle(.plain).scrollDismissesKeyboard(.interactively)
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
