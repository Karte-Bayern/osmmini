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
  @State private var locationRequest: LocationRequest?
  @State private var mapTarget: DemoModel.RoutePoint?
  @State private var routeDetailsExpanded = true
  @State private var inspectorHeight: CGFloat = 0
  @State private var placeHoursExpanded = false
  @State private var placeMetadataExpanded = false
  @State private var nearbySelection: NearbySelection?
  @State private var nearbyQuery = ""
  @State private var fullPlaceDetails = false

  private struct NearbySelection: Identifiable {
    let id = UUID()
    let places: [MapSelection]
  }

  private var inspectedPlaceKey: String? {
    guard let place = model.inspectedPlace else { return nil }
    return place.sourceIdentity
      ?? "\(place.kind ?? "point")/\(place.coordinate.lat)/\(place.coordinate.lon)"
  }

  private struct LocationRequest {
    let id = UUID()
    let owner: ObjectIdentifier
    let target: DemoModel.RoutePoint?
  }

  private var locationTarget: DemoModel.RoutePoint? { locationRequest?.target }

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
        DemoMapCanvas(
          model: model, location: location, showRegions: showRegions, onSelect: selectMapPoint,
          onLocate: showLocation
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        ScrollViewReader { proxy in
          ScrollView {
            inspector(compactPlaces: metrics.sideWidth == nil)
              .id("inspectorTop")
              .onGeometryChange(for: CGFloat.self) {
                $0.size.height
              } action: {
                inspectorHeight = $0
              }
          }
          .scrollBounceBehavior(.basedOnSize)
          .onChange(of: inspectedPlaceKey) { _, _ in
            placeHoursExpanded = false
            placeMetadataExpanded = false
            proxy.scrollTo("inspectorTop", anchor: .top)
          }
        }
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
          location.isLocating ? "Standort wird ermittelt" : "Auf meinen Standort zoomen"
        )
        .help("Aktuellen GPS-Standort heranzoomen")
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
      DemoPlaceSearch(model: model, target: searchTarget, showRegions: showRegions) { place in
        guard !model.busy, model.contains(place.coordinate) else { return }
        cancelLocationSelection()
        if let searchTarget {
          model.usePlace(place, as: searchTarget, minimumZoom: 14)
          planning = true
        } else {
          model.inspect(place, minimumZoom: 14)
        }
        searching = false
      }
    }
    .sheet(isPresented: $directions) { directionsSheet }
    .sheet(item: $nearbySelection) { nearbyPlacesSheet($0) }
    .sheet(isPresented: $fullPlaceDetails) { fullPlaceDetailsSheet }
    .onChange(of: location.coordinate) { _, _ in updateLocationSelection() }
    .onChange(of: location.state) { _, _ in updateLocationSelection() }
    .onChange(of: locationRequest?.id) { _, _ in updateLocationSelection() }
    .onChange(of: model.activeDirectory) { _, _ in
      planning = false
      searching = false
      searchTarget = nil
      directions = false
      cancelLocationSelection()
      mapTarget = nil
      routeDetailsExpanded = true
      nearbySelection = nil
      fullPlaceDetails = false
    }
    .onChange(of: inspectedPlaceKey) { _, key in
      if key == nil { fullPlaceDetails = false }
    }
    .onChange(of: model.busy) { _, busy in
      if busy {
        nearbySelection = nil
        fullPlaceDetails = false
        mapTarget = nil
        cancelLocationSelection()
      }
    }
    .onChange(of: model.start) { _, _ in
      if locationTarget == .start { cancelLocationSelection() }
    }
    .onChange(of: model.destination) { _, _ in
      if locationTarget == .destination { cancelLocationSelection() }
    }
    .onChange(of: model.start != nil || model.destination != nil, initial: true) { _, hasPoints in
      planning = hasPoints
    }
    .onDisappear { cancelLocationSelection() }
  }

  private var showsExpandedInspector: Bool {
    mapTarget != nil || model.inspectedPlace != nil || (planning && routeDetailsExpanded) || model.busy
      || location.state != .idle
  }

  private func togglePlanning() {
    cancelLocationSelection()
    mapTarget = nil
    if model.inspectedPlace != nil {
      model.dismissPlace()
      planning = true
    } else {
      planning.toggle()
    }
    routeDetailsExpanded = true
  }

  private func inspector(compactPlaces: Bool) -> some View {
    VStack(spacing: 0) {
      if let mapTarget {
        mapSelectionCard(mapTarget)
      } else if let place = model.inspectedPlace {
        placeCard(place, compact: compactPlaces).padding()
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
      if model.engine != nil, !model.places.saved.isEmpty, !showsExpandedInspector {
        Button("Meine Orte", systemImage: "star") {
          model.query = ""
          openSearch(for: nil)
        }.frame(maxWidth: .infinity, minHeight: 44)
      }
    }
  }

  private func openSearch(for point: DemoModel.RoutePoint?) {
    cancelLocationSelection()
    mapTarget = nil
    if let point { model.chooseRoutePoint(point) }
    searchTarget = point
    searching = true
  }

  private func selectMapPoint(_ selection: MapSelection) {
    cancelLocationSelection()
    guard !model.busy else { return }
    if selection.alternatives.count > 1 {
      nearbyQuery = ""
      nearbySelection = NearbySelection(places: selection.alternatives)
      return
    }
    if let mapTarget {
      guard model.contains(selection.coordinate) else {
        self.mapTarget = nil
        model.inspect(selection)
        return
      }
      model.usePlace(DemoPlace(selection), as: mapTarget)
      self.mapTarget = nil
      planning = true
      routeDetailsExpanded = true
    } else {
      model.inspect(selection)
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
    requestLocation(for: nil)
  }

  private func requestLocation(for point: DemoModel.RoutePoint?) {
    guard let engine = model.engine, point == nil || !model.busy else { return }
    mapTarget = nil
    locationRequest = LocationRequest(owner: ObjectIdentifier(engine), target: point)
    if point != nil {
      model.dismissPlace()
      planning = true
      routeDetailsExpanded = true
    }
    if let coordinate = location.coordinate {
      completeLocationSelection(coordinate)
    } else {
      location.start()
    }
  }

  private func completeLocationSelection(_ coordinate: Coordinate) {
    guard let request = locationRequest else { return }
    cancelLocationSelection()
    guard let engine = model.engine, ObjectIdentifier(engine) == request.owner
    else { return }
    if let target = request.target {
      guard model.contains(coordinate) else { return }
      model.usePlace(
        DemoPlace(coordinate: coordinate, name: "Mein Standort", category: nil), as: target,
        minimumZoom: 14, remember: false)
    } else {
      model.focusOn(coordinate, minimumZoom: 16)
    }
  }

  private func updateLocationSelection() {
    guard locationRequest != nil else { return }
    if let coordinate = location.coordinate {
      completeLocationSelection(coordinate)
    } else if !location.isLocating {
      cancelLocationSelection()
    }
  }

  private func cancelLocationSelection() {
    locationRequest = nil
  }

  @ViewBuilder private var locationStatus: some View {
    if location.state == .ready, let coordinate = location.coordinate, model.contains(coordinate) {
      HStack(spacing: 8) {
        Label(location.status, systemImage: "location.fill")
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer(minLength: 0)
        Menu {
          Button("Auf meinen Standort zoomen", systemImage: "location", action: showLocation)
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
    cancelLocationSelection()
    model.usePlace(
      DemoPlace(coordinate: coordinate, name: "Mein Standort", category: nil), as: .start,
      minimumZoom: 14, remember: false)
    planning = true
    routeDetailsExpanded = true
  }

  private func placeCard(_ place: DemoPlace, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        let category = POICategory(place.category)
        Image(
          systemName: place.kind == "street"
            ? "road.lanes" : POICategory.symbolName(for: place.category)
        )
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(category.tint)
        .frame(width: 32, height: 36)
        .background(category.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(place.name).font(.title3.weight(.semibold))
            .lineLimit(compact ? 2 : nil)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
          Text(DemoPlaceText.category(place.category, kind: place.kind)).font(.subheadline)
            .foregroundStyle(.secondary)
          if place.kind == nil {
            Text(DemoPlaceText.coordinates(place.coordinate))
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Spacer()
        Button {
          model.dismissPlace()
        } label: {
          Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(
            Rectangle())
        }.accessibilityLabel("Auswahl schließen").buttonStyle(.plain)
      }
      if let address = DemoPlaceText.detail(place.details?.address) {
        Label(address, systemImage: "mappin.and.ellipse")
          .font(.callout).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if compact {
        compactPlaceActions(place).disabled(model.busy)
      } else {
        placeActions(place).disabled(model.busy)
      }
      if !model.contains(place.coordinate) {
        Text("Dieser Ort liegt außerhalb der geöffneten Offline-Region.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Passende Offline-Karte öffnen", systemImage: "map", action: showRegions)
          .font(.callout).frame(minHeight: 44)
      }
      if compact {
        Button("Alle Ortsdetails", systemImage: "info.circle") { fullPlaceDetails = true }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .accessibilityHint("Zeigt den vollständigen Namen, Öffnungszeiten und Kontaktdaten.")
      } else {
        Divider()
        placeDetails(place)
      }
      if let error = model.places.error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func placeDetails(_ place: DemoPlace) -> some View {
    if let hours = DemoPlaceText.detail(place.details?.openingHours) {
      DisclosureGroup(isExpanded: $placeHoursExpanded) {
        VStack(alignment: .leading, spacing: 6) {
          Text(hours).font(.callout).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "OSM-Angabe aus der Offline-Karte. Feiertage und kurzfristige Änderungen können abweichen."
          )
          .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Label("Öffnungszeiten", systemImage: "clock")
          Text(DemoPlaceText.hoursSummary(hours)).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
        }.frame(minHeight: 44)
      }
    }
    if let phone = DemoPlaceText.detail(place.details?.phone) {
      if let url = DemoPlaceText.phoneURL(phone) {
        Link(destination: url) {
          detailLink(title: "Anrufen", subtitle: phone, symbol: "phone", external: false)
        }.accessibilityLabel("\(place.name) anrufen: \(phone)")
      } else {
        Label(phone, systemImage: "phone").font(.callout).textSelection(.enabled)
      }
    }
    if let website = DemoPlaceText.detail(place.details?.website) {
      if let url = DemoPlaceText.websiteURL(website) {
        Link(destination: url) {
          detailLink(
            title: "Website", subtitle: url.host ?? website, symbol: "globe", external: true)
        }.accessibilityLabel("Website von \(place.name): \(url.host ?? website)")
          .accessibilityHint("Öffnet die Website im Browser und benötigt Internet.")
      } else {
        Label(website, systemImage: "globe").font(.callout).textSelection(.enabled)
      }
    }
    if place.kind == "node" || place.kind == "way", !DemoPlaceText.hasContactDetails(place.details)
    {
      Text("Keine Öffnungszeiten oder Kontaktdaten in dieser Offline-Karte hinterlegt.")
        .font(.caption).foregroundStyle(.secondary)
    }
    ShareLink(item: DemoPlaceText.shareText(place)) {
      Label("Ort teilen", systemImage: "square.and.arrow.up")
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }.font(.callout)
    DisclosureGroup("Koordinaten und Kartendaten", isExpanded: $placeMetadataExpanded) {
      VStack(alignment: .leading, spacing: 6) {
        Text(DemoPlaceText.coordinates(place.coordinate))
          .font(.caption.monospacedDigit()).textSelection(.enabled)
        Text("Kartenquelle: OpenStreetMap · Stand der importierten Karte")
          .font(.caption).foregroundStyle(.secondary)
        if let url = DemoPlaceText.sourceURL(place.sourceIdentity) {
          Link("Auf OpenStreetMap ansehen", destination: url)
            .font(.callout).frame(minHeight: 44)
            .accessibilityHint("Öffnet OpenStreetMap im Browser und benötigt Internet.")
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }.font(.callout)
  }

  private func detailLink(title: String, subtitle: String, symbol: String, external: Bool)
    -> some View
  {
    HStack(spacing: 10) {
      Image(systemName: symbol).frame(width: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 4)
      if external {
        Image(systemName: "arrow.up.right").font(.caption).accessibilityHidden(true)
      }
    }.font(.callout).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
  }

  private func routeToPlace(_ place: DemoPlace) {
    fullPlaceDetails = false
    cancelLocationSelection()
    model.usePlace(place, as: .destination)
    planning = true
    routeDetailsExpanded = true
    if model.start == nil { requestLocation(for: .start) }
  }

  private func startAtPlace(_ place: DemoPlace) {
    fullPlaceDetails = false
    cancelLocationSelection()
    model.usePlace(place, as: .start)
    planning = true
    routeDetailsExpanded = true
  }

  private func savePlaceButton(_ place: DemoPlace, iconOnly: Bool = false) -> some View {
    let saved = model.places.savedEntry(for: place)
    return Button {
      if let saved { model.places.removeSaved(id: saved.id) } else { model.places.save(place) }
    } label: {
      Label(
        saved == nil ? "Speichern" : "Gespeichert", systemImage: saved == nil ? "star" : "star.fill"
      )
      .labelStyle(PlaceActionLabelStyle(iconOnly: iconOnly))
      .frame(maxWidth: iconOnly ? nil : .infinity, minHeight: 44)
      .frame(minWidth: 44)
    }.buttonStyle(.bordered)
      .accessibilityLabel(saved == nil ? "Ort speichern" : "Gespeicherten Ort entfernen")
      .accessibilityHint(
        saved == nil ? "Zu deinen Orten hinzufügen" : "Aus deinen gespeicherten Orten entfernen"
      )
      .disabled(model.places.needsReset)
  }

  private func compactPlaceActions(_ place: DemoPlace) -> some View {
    AdaptiveActionLayout {
      Button {
        routeToPlace(place)
      } label: {
        Label("Route hierher", systemImage: "arrow.triangle.turn.up.right.diamond")
          .frame(maxWidth: .infinity, minHeight: 44)
      }.buttonStyle(.borderedProminent).disabled(!model.contains(place.coordinate))
      HStack(spacing: 8) {
        savePlaceButton(place, iconOnly: true)
        Menu {
          Button("Als Start verwenden", systemImage: "a.circle.fill") { startAtPlace(place) }
            .disabled(!model.contains(place.coordinate))
          ShareLink(item: DemoPlaceText.shareText(place)) {
            Label("Ort teilen", systemImage: "square.and.arrow.up")
          }
        } label: {
          Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.bordered).accessibilityLabel("Weitere Ortsaktionen")
      }
    }.font(.callout)
  }

  private func placeActions(_ place: DemoPlace) -> some View {
    VStack(spacing: 8) {
      Button {
        routeToPlace(place)
      } label: {
        Label("Route hierher", systemImage: "arrow.triangle.turn.up.right.diamond")
          .frame(maxWidth: .infinity, minHeight: 44)
      }.buttonStyle(.borderedProminent).disabled(!model.contains(place.coordinate))
      AdaptiveActionLayout {
        Button {
          startAtPlace(place)
        } label: {
          Label("Als Start", systemImage: "a.circle.fill")
            .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered).disabled(!model.contains(place.coordinate))
        savePlaceButton(place)
      }
    }.font(.callout)
  }

  private func nearbyPlacesSheet(_ selection: NearbySelection) -> some View {
    let matches = selection.places.enumerated().filter { _, candidate in
      let place = DemoPlace(candidate)
      return nearbyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || [
          place.name, place.details?.address ?? "",
          DemoPlaceText.category(place.category, kind: place.kind),
        ]
        .contains {
          $0.localizedStandardContains(nearbyQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    return NavigationStack {
      List {
        Section {
          ForEach(matches, id: \.offset) { _, candidate in
            let place = DemoPlace(candidate)
            Button {
              nearbySelection = nil
              selectMapPoint(candidate)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: POICategory.symbolName(for: place.category))
                  .foregroundStyle(POICategory(place.category).tint).frame(width: 24)
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                  Text(place.name).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                  let category = DemoPlaceText.category(place.category, kind: place.kind)
                  if category != place.name {
                    Text(category).font(.subheadline).foregroundStyle(.secondary)
                  }
                  if let address = DemoPlaceText.detail(place.details?.address) {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                  .accessibilityHidden(true)
              }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Diesen Ort auswählen")
          }
        } footer: {
          Text("Diese Orte liegen auf der Karte eng beieinander. Wähle den gewünschten Ort aus.")
            .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
      }
      .overlay {
        if matches.isEmpty { ContentUnavailableView.search(text: nearbyQuery) }
      }
      .searchable(text: $nearbyQuery, prompt: "In diesen Orten suchen")
      .navigationTitle("\(selection.places.count) Orte hier")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Abbrechen", role: .cancel) { nearbySelection = nil }
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 360, idealWidth: 480, minHeight: 400, idealHeight: 600)
    #else
      .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    #endif
  }

  private var fullPlaceDetailsSheet: some View {
    NavigationStack {
      if let place = model.inspectedPlace {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(place.name).font(.title2.weight(.semibold)).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Label(
              DemoPlaceText.category(place.category, kind: place.kind),
              systemImage: place.kind == "street"
                ? "road.lanes" : POICategory.symbolName(for: place.category)
            )
            .font(.subheadline).foregroundStyle(.secondary)
            if let address = DemoPlaceText.detail(place.details?.address) {
              Label(address, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            placeDetails(place)
            if let error = model.places.error { Text(error).font(.caption).foregroundStyle(.red) }
          }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .safeAreaInset(edge: .bottom) {
          placeActions(place).disabled(model.busy).padding(12).background(.regularMaterial)
        }
        .navigationTitle("Ortsdetails")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Schließen", role: .cancel) { fullPlaceDetails = false }
              .keyboardShortcut(.cancelAction)
          }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 360, idealWidth: 480, minHeight: 400, idealHeight: 640)
    #else
      .presentationDetents([.large]).presentationDragIndicator(.visible)
    #endif
  }

  private var routeSummary: String {
    guard let route = model.route else { return "" }
    return DemoRouteText.summary(distance: route.distanceM, duration: route.durationS)
  }

  private var routeCard: some View {
    let layout = routeDetailsExpanded
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(AdaptiveActionLayout())
    return layout {
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
          cancelLocationSelection()
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
            cancelLocationSelection()
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
        if locationTarget == nil, model.start == nil, !model.busy {
          Button("Mein Standort als Start", systemImage: "location") {
            requestLocation(for: .start)
          }
          .frame(minHeight: 44).buttonStyle(.bordered)
        }
        if model.route == nil, !model.busy, model.routeError == nil, locationTarget == nil {
          Text(model.routeSelectionHint).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let locationTarget {
        AdaptiveActionLayout {
          HStack(spacing: 8) {
            ProgressView()
            Text(
              locationTarget == .start
                ? "Standort als Start ermitteln …" : "Standort als Ziel ermitteln …"
            ).font(.callout)
          }
          Button("Abbrechen", role: .cancel) {
            cancelLocationSelection()
            location.stop()
          }.frame(minHeight: 44)
        }
      }
      if model.busy {
        ActivityProgress(model: model)
      } else if let error = model.routeError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red)
      }
      if model.route == nil, model.canCalculateRoute, locationTarget == nil {
        Button(
          model.routeError == nil ? "Route berechnen" : "Route erneut berechnen",
          systemImage: "arrow.triangle.turn.up.right.diamond"
        ) { model.retryRoute() }
        .frame(minHeight: 44).buttonStyle(.borderedProminent)
      }
      if let route = model.route {
        AdaptiveActionLayout { routeActions(route) }.buttonStyle(.bordered)
        if routeDetailsExpanded, max(route.fromSnapM, route.toSnapM) > 100 {
          Text("Die Route beginnt oder endet an einer nahegelegenen befahrbaren Straße.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if routeDetailsExpanded, model.start != nil || model.destination != nil {
        Button("Route zurücksetzen", systemImage: "arrow.counterclockwise") {
          cancelLocationSelection()
          model.clearRoute()
        }
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
        cancelLocationSelection()
        model.chooseRoutePoint(point)
        model.dismissPlace()
        mapTarget = point
      }
      Button("Meinen Standort verwenden", systemImage: "location") { requestLocation(for: point) }
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: image).foregroundStyle(point == .start ? Color.green : .red)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(point == .start ? "Start" : "Ziel").font(.caption).foregroundStyle(.secondary)
          Text(name ?? title).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .menuStyle(.button).menuIndicator(.hidden)
    .buttonStyle(.plain).frame(maxWidth: .infinity).disabled(model.busy)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(point == .start ? "Start" : "Ziel"): \(name ?? "Noch nicht gewählt")")
    .accessibilityHint("Suche, Kartenpunkt oder eigenen Standort auswählen")
  }

  private var directionsSheet: some View {
    NavigationStack {
      List {
        if let route = model.route {
          Section {
            LabeledContent("Start", value: model.startLabel ?? "Kartenpunkt")
            LabeledContent("Ziel", value: model.destinationLabel ?? "Kartenpunkt")
            Label(routeSummary, systemImage: "car.fill").font(.headline)
            Text("Geschätzte Fahrzeit ohne aktuelle Verkehrslage.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Section {
            ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
              Button {
                model.focusOn(Coordinate(lat: step.lat, lon: step.lon), minimumZoom: 14)
                directions = false
              } label: {
                HStack(alignment: .top) {
                  Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                  Text(step.instruction).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityHint("Diesen Schritt auf der Karte anzeigen")
            }
          } header: {
            Text("\(route.steps.count) Schritte")
          } footer: {
            Text("Einen Schritt antippen, um ihn auf der Karte zu sehen.")
              .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
              .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
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

private struct PlaceActionLabelStyle: LabelStyle {
  let iconOnly: Bool
  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      configuration.icon
    } else {
      HStack {
        configuration.icon
        configuration.title
      }
    }
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
  let showRegions: () -> Void
  let onSelect: (MapSelection) -> Void
  let onLocate: () -> Void
  var body: some View {
    if let engine = model.engine {
      OfflineMap(
        engine: engine, route: model.route,
        focus: model.focus, focusRequest: model.focusRequest,
        focusMinimumZoom: model.focusMinimumZoom,
        routeStart: model.start, routeDestination: model.destination,
        selection: model.inspectedPlace?.coordinate, userLocation: location.coordinate,
        userLocationAccuracy: location.horizontalAccuracy,
        onLocate: onLocate, isLocating: location.isLocating, onFeatureSelect: onSelect
      ).id(ObjectIdentifier(engine))
    } else if model.busy {
      ContentUnavailableView {
        Label("Vorgang läuft", systemImage: "map")
      } description: {
        Text("Der Fortschritt wird bei den Offline-Karten angezeigt.")
      } actions: {
        Button("Fortschritt anzeigen", action: showRegions).buttonStyle(.borderedProminent)
      }
    } else {
      ContentUnavailableView {
        Label("Deine Region offline", systemImage: "map")
      } description: {
        Text(
          "Eine Region laden oder eine lokale PBF importieren. Danach bleiben Karte, Suche und Routing offline verfügbar."
        )
      } actions: {
        Button("Offline-Karte hinzufügen", action: showRegions).buttonStyle(.borderedProminent)
      }
    }
  }
}

enum DemoRouteText {
  static func summary(distance: Double, duration: Double, locale: Locale = .current) -> String {
    "\(self.distance(distance, locale: locale)) · \(self.duration(duration, locale: locale))"
  }

  static func distance(_ meters: Double, locale: Locale = .current) -> String {
    guard meters.isFinite, meters >= 0 else { return "–" }
    if meters.rounded() < 1000 {
      return "\(meters.formatted(.number.precision(.fractionLength(0)).locale(locale))) m"
    }
    return
      "\((meters / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))) km"
  }

  static func duration(_ seconds: Double, locale: Locale = .current) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "–" }
    if seconds < 60 { return "< 1 Min." }
    let minutes = (seconds / 60).rounded(.up)
    let hours = (minutes / 60).rounded(.down)
    let remainder = minutes.truncatingRemainder(dividingBy: 60)
    let minuteText = remainder.formatted(.number.precision(.fractionLength(0)).locale(locale))
    if hours == 0 { return "\(minuteText) Min." }
    let hourText = hours.formatted(.number.precision(.fractionLength(0)).locale(locale))
    return remainder == 0 ? "\(hourText) Std." : "\(hourText) Std. \(minuteText) Min."
  }
}

enum DemoPlaceText {
  static func hoursSummary(_ hours: String) -> String {
    switch hours.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "24/7": "Rund um die Uhr · laut Offline-Karte"
    case "off", "closed": "Als geschlossen eingetragen"
    default: hours
    }
  }

  static func hasContactDetails(_ details: PlaceDetails?) -> Bool {
    [details?.openingHours, details?.phone, details?.website].contains { detail($0) != nil }
  }

  static func shareText(_ place: DemoPlace) -> String {
    [place.name, detail(place.details?.address), coordinates(place.coordinate)]
      .compactMap { $0 }.joined(separator: "\n")
  }

  static func detail(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }

  static func websiteURL(_ value: String) -> URL? {
    guard let value = detail(value), value.utf8.count <= 2048,
      !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0)
          || CharacterSet.controlCharacters.contains($0)
      })
    else { return nil }
    let address = value.contains(":") ? value : "https://" + value
    guard let components = URLComponents(string: address),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil
    else { return nil }
    return components.url
  }

  static func phoneURL(_ value: String) -> URL? {
    guard let value = detail(value), value.utf8.count <= 128 else { return nil }
    let number = value.filter { !" ()-/. ".contains($0) }
    let digits = number.hasPrefix("+") ? number.dropFirst() : number[...]
    guard (3...32).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) })
    else { return nil }
    return URL(string: "tel:" + number)
  }

  static func sourceURL(_ identity: String?) -> URL? {
    guard let identity else { return nil }
    let parts = identity.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, ["node", "way"].contains(String(parts[0])),
      parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
      let id = Int64(parts[1]), id > 0
    else { return nil }
    return URL(string: "https://www.openstreetmap.org/\(parts[0])/\(id)")
  }

  static func coordinates(_ coordinate: Coordinate) -> String {
    String(
      format: "%.5f° %@ · %.5f° %@", locale: Locale(identifier: "en_US_POSIX"),
      abs(coordinate.lat), coordinate.lat < 0 ? "S" : "N",
      abs(coordinate.lon), coordinate.lon < 0 ? "W" : "E")
  }

  static func category(_ category: String?, kind: String? = nil) -> String {
    if kind == "street" {
      return switch category {
      case "motorway": "Autobahn"
      case "trunk": "Schnellstraße"
      case "primary", "secondary": "Hauptstraße"
      case "residential": "Wohnstraße"
      case "living_street": "Verkehrsberuhigter Bereich"
      case "pedestrian": "Fußgängerzone"
      case "service": "Zufahrt"
      case "footway": "Fußweg"
      case "cycleway": "Radweg"
      case "path", "track": "Weg"
      default: "Straße"
      }
    }
    switch category {
    case "city", "town": return "Stadt"
    case "village", "hamlet", "isolated_dwelling": return "Ort"
    case "suburb", "quarter", "neighbourhood": return "Ortsteil"
    case "cafe": return "Café"
    case "bar": return "Bar"
    case "pub": return "Gaststätte"
    case "ice_cream": return "Eisdiele"
    case "convenience": return "Lebensmittelgeschäft"
    case "clothes": return "Bekleidungsgeschäft"
    case "books": return "Buchhandlung"
    case "mall": return "Einkaufszentrum"
    case "dentist": return "Zahnarztpraxis"
    case "clinic": return "Klinik"
    case "hostel": return "Hostel"
    case "guest_house": return "Gästehaus"
    case "motel": return "Motel"
    case "camp_site": return "Campingplatz"
    case "cinema": return "Kino"
    case "theatre": return "Theater"
    case "library": return "Bibliothek"
    case "place_of_worship": return "Gotteshaus"
    case "bus_stop": return "Bushaltestelle"
    case "bicycle_parking": return "Fahrradstellplatz"
    case "artwork": return "Kunstwerk"
    case "recycling": return "Recyclingstelle"
    case "telephone": return "Öffentliches Telefon"
    case "picnic_site": return "Picknickplatz"
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
    case "fast_food": return "Imbiss"
    case "museum": return "Museum"
    case "attraction": return "Sehenswürdigkeit"
    case "viewpoint": return "Aussichtspunkt"
    case "park": return "Park"
    case "playground": return "Spielplatz"
    case "toilets": return "Toilette"
    case "drinking_water": return "Trinkwasser"
    case "bank": return "Bank"
    case "atm": return "Geldautomat"
    case "post_office": return "Post"
    case "station": return "Bahnhof"
    default: return kind == "node" || kind == "way" ? "Adresse oder Ort" : "Kartenpunkt"
    }
  }
}
