# OSMmini for Apple platforms

A Swift 6 offline engine and SwiftUI map for iPhone, iPad and native macOS.
It shares the Go routing core with the server and needs no local HTTP server,
web view or SQLite dependency.

## Build and run

Requires macOS, full Xcode and Go 1.26.5+. Deployment targets are iOS/iPadOS 17
and macOS 14.

From the repository root:

```sh
make build-apple
open apple/Demo/OSMminiDemo.xcodeproj
```

Choose the **OSMminiDemo** scheme and an iPhone, iPad, Simulator or Mac target.
The generated XCFramework contains iOS arm64, Simulator arm64/x86_64 and macOS
arm64/x86_64. Build it before resolving the local Swift package.

For device signing, create the ignored local configuration from the template
if it does not exist, then replace `YOUR_TEAM_ID`:

```sh
cp apple/Demo/Configuration/Signing.local.xcconfig.example apple/Demo/Configuration/Signing.local.xcconfig
```

Edit an existing local configuration directly. Simulator and unsigned builds
need no signing team.

For macOS-only development:

```sh
make build-apple-macos
swift run --package-path apple OSMminiDemoCLI
swift test --package-path apple
```

This replaces the framework with Mac slices only. Run `make build-apple` again
before an iOS build. No Go installation is needed on the destination device.

## Demo application

1. Download a region from Geofabrik or select a local `.osm.pbf` file.
2. Wait for graph, search and map preparation.
3. Search for a place or select a map position, then choose **Als Start** or
   **Route hierher**. The latter requests your location when no start is set.
   Plan a route by distance or duration and export GPX/GeoJSON.

Save places with the star and find them again in search, including under your
own names. Saved places and the last 20 selected places stay local and survive
region replacement or deletion. GPS updates are not added to this history.
Places outside the current region are marked; open a matching offline map to
use them. Remove individual entries or clear recent selections from the search
sheet.

Tap a named road or a visible POI marker to open its details, save it or use it
as a route endpoint. Road selections use the nearest point on the visible line;
empty areas still select a free map point. POI markers appear from display zoom
14; their detail tiles follow the display zoom independently of the basemap,
with at most 512 POIs per detail tile. Details include address, opening-hours
text, phone and website when retained by the import. Existing regions gain POI
markers from their search catalog without the source PBF; additional source
tags require a new import. Opening hours are stored OSM text, not a live
open/closed status. Website and OSM links open only when selected and require
a network connection.

POIs use category colors, with category symbols from display zoom 16 and
collision-checked names from zoom 17. Nearby markers are spaced apart in screen
coordinates. Crowded markers show a count and expose every member through
`MapSelection.alternatives`, retaining each place's own coordinate and details.
The demo offers a searchable choice list, including for coincident POIs at the
maximum zoom. Drawing and selection share the same group and label layout.
The place inspector shows the address above route/save actions, expands
opening-hours details on demand, displays the website's host and can share a
place as text.
Selecting another place resets the inspector's scroll position and disclosures.
On narrow screens, a compact inspector preserves map space and opens full
details in a separate sheet with route/save actions fixed above the safe area.

Published regions work without the source PBF or a network connection. The app
can reopen the last region, retry interrupted imports, remove installed regions
and clean up downloaded PBFs separately. Completed graph/search phases resume;
an interrupted map build restarts that phase. Background completion while the
app is suspended is not guaranteed.

The map displays local vector geometry, road/place labels, routes and location
accuracy. It supports panning, zooming and fitting the region or route. Enlarging
basemap tiles adds no road or building detail. Location access starts only
after an explicit action and stops in the background.

The location arrow on the map zooms to the current GPS fix at street level.
When no fresh fix exists, the demo requests location access and focuses the map
once a fix arrives. Repeated taps recenter without changing route endpoints.
Outside the installed region, the position remains visible with a prompt to
open a matching offline map. Embedders can supply `onLocate`/`isLocating` to
connect their location provider; with only `userLocation`, the renderer's
location button focuses that coordinate without requesting permissions.

Adaptive split views and map details follow the available window size,
including iPad multitasking and resizable displays. macOS uses native windows
and menus, without Catalyst. Shortcuts: **⌘O** imports, **⌘F** searches and
**⇧⌘R** toggles route planning.

## Swift integration

Add this repository or `apple/` as a local Swift package in Xcode and select the
**OSMmini** library product. Given a readable `sourceURL` and a new
`regionDirectory`:

```swift
import OSMmini

let options = ImportOptions(
    pbf: sourceURL, destination: regionDirectory, name: "Local region")
try await OfflineEngine.importPBF(options) { progress in
    Task { @MainActor in print(progress.phase, progress.fraction) }
}

let engine = try await OfflineEngine.open(regionDirectory)
let places = try await engine.search("Passau", limit: 20)
var routing = RouteOptions()
routing.objective = .duration
let route = try await engine.route(RouteRequest(
    from: Coordinate(lat: 48.574, lon: 13.450),
    to: Coordinate(lat: 48.549, lon: 12.137), options: routing))
let gpx = route.gpx()
let geoJSON = try route.geoJSON()
await engine.close()
```

Use `OfflineMap(engine: engine, route: route)` in SwiftUI, or read vector tiles
with `engine.tile(z:x:y:)` for another renderer. `Geofabrik(directory:)` exposes
catalog and download APIs independently; offline engine queries use no network.

Use `onFeatureSelect` for road/POI selection, including snapped coordinates and
optional source metadata:

```swift
OfflineMap(engine: engine, onFeatureSelect: { selection in
    // A nil feature denotes a free map point.
    print(selection.feature?.name ?? "Map point", selection.coordinate)
})
```

The existing `onSelect` callback continues to return the tapped coordinate.
When both callbacks are set, `onFeatureSelect` takes precedence.

Native work runs off the main actor. Progress callbacks run on a worker thread;
UI changes belong on `MainActor`. Task cancellation cancels the native operation.
`close()` is idempotent and waits for active native work. Callers retain access
to security-scoped source URLs during import.

The bridge contains one statically linked Go runtime. Applications embedding
another Go framework must consolidate native entry points into one archive.

## Portable regions

Prepare a region on a server or Mac, then copy the entire directory into the
application's readable sandbox:

```sh
CGO_ENABLED=0 go run ./cmd/prepare-region \
  -pbf region.osm.pbf -output regions/local -name "Local region"
```

| File | Contents |
| --- | --- |
| `manifest.json` | Version, bounds, source hash and file checksums |
| `graph.bin` | Memory-mapped routing graph with shared road-chain storage |
| `routing.alt` | Memory-mapped ALT lower bounds for distance and duration |
| `search.jsonl`, `search.jsonl.idx` | Compressed records and disk-backed prefix index |
| `places.jsonl` | Settlement catalog for faster opening in new imports |
| `.poi-v1.idx` (optional) | Locally derived spatial index referencing search records |
| `basemap.ttiles/` | Local vector-map artifact |
| `NOTICE.txt` | Map-data attribution and licence links |

New imports use region format 4; formats 1–3 remain readable. The settlement
catalog is optional for older regions and validated when declared by the
manifest. Original OSM IDs, coordinates, directed connectivity and road geometry
are preserved by chain packing.

Published map files are immutable. Reimport into a new directory to update
data or obtain the current storage format. A derived POI index may be cached
locally when a region is opened; it is bound to the search-data checksum and
does not replace source files. The first open builds this index; subsequent
opens reuse it. Read-only regions use a temporary index. In writable regions,
interrupted index builds are cleaned up on the next open. Incompatible pending
imports need a new workspace. Keep `NOTICE.txt` with distributed regions.

New imports prepare two directed landmarks per metric using conservative
16-bit cost intervals. Older regions remain usable without this optional
index. Emergency and territory-cost queries use a zero heuristic when their
costs cannot be bounded by the prepared metrics.

The default import cap is eight million referenced road nodes; change it with
`-max-import-nodes`. Tile zooms default to 5–14. Node caps and tile-cache budgets
are not total process-memory limits. Importing large extracts still requires
memory for intermediate map geometry.

## Rendering and scope

The SwiftUI Canvas renderer uses prepared vector paths, visible-feature culling,
cached label priorities and collision checks. Up to four tile jobs run at once;
completed tiles appear independently. Geometry is retained for the current
viewport, with a maximum of 128 cached tiles. Long routes use prepared chunks.

The SDK operates on one region at a time. It does not provide cross-region
routing, continuous turn guidance or automatic data updates. Routing shares the
[core import limitations](../README.md#routing-and-data-limits). Native search
indexes node/way addresses and POIs with prefix/AND matching and a small German
category-alias set; exact settlement names take priority.

## Validation

```sh
make check-mobile
make test-apple
```

`make test-apple` builds a macOS-only framework. For an existing Niederbayern
region, run the optional integration check without downloading data:

```sh
OSMMINI_REAL_REGION=/path/to/niederbayern \
  swift test --package-path apple -c release --filter niederbayernRealRegionIntegration
```

It checks search, routing and local map geometry. Optional CPU benchmarks use
`OSMMINI_MAP_BENCHMARK=1` or `OSMMINI_BENCHMARKS=1`; device launch time, memory
and frame rate require device profiling.

## Distribution

```sh
make build-apple
scripts/package-apple.sh /tmp/OSMmini-Apple.zip
```

The ZIP contains a local Swift package and the framework. Consumers do not need
Go. For remote SwiftPM releases, use
[`prepare-apple-release.sh`](../scripts/prepare-apple-release.sh) to prepare the
framework asset, checksum and matching manifest before publishing them together.

See [LICENSE](LICENSE) and [NOTICE](NOTICE). Software and map-data licences are
separate.
