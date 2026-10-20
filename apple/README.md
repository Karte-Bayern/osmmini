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
   **Als Ziel**. Plan a route by distance or duration and export GPX/GeoJSON.

Published regions work without the source PBF or a network connection. The app
can reopen the last region, retry interrupted imports, remove installed regions
and clean up downloaded PBFs separately. Completed graph/search phases resume;
an interrupted map build restarts that phase. Background completion while the
app is suspended is not guaranteed.

The map displays local vector geometry, road/place labels, routes and location
accuracy. It supports panning, zooming and fitting the region or route. Enlarging
source tiles adds no detail. Location access starts only after an explicit
action and stops in the background.

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
| `search.jsonl`, `search.jsonl.idx` | Compressed records and disk-backed prefix index |
| `places.jsonl` | Settlement catalog for faster opening in new imports |
| `basemap.ttiles/` | Local vector-map artifact |
| `NOTICE.txt` | Map-data attribution and licence links |

New imports use region format 4; formats 1–3 remain readable. The settlement
catalog is optional for older regions and validated when declared by the
manifest. Original OSM IDs, coordinates, directed connectivity and road geometry
are preserved by chain packing.

Published destinations are immutable. Reimport into a new directory to update
data or obtain the current storage format. Incompatible pending imports need a
new workspace. Keep `NOTICE.txt` with distributed regions.

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
