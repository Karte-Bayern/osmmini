# OSMmini for Swift, iPhone, iPad and Mac

An embeddable, SQLite-free offline OSM engine with a Swift 6 API, a native
SwiftUI vector map, and a demo application. The Go core is shared with the
existing OSMmini server. No local HTTP server or web view is needed.

## Build and run

Requires macOS, full Xcode, and Go 1.26.5 or later. Development was verified with
Go 1.27.2, Xcode 27.1 and Swift 6.4 in Swift 6 language mode. Deployment targets
are iOS/iPadOS 17 and macOS 14. These targets are independent of the build SDK.

From the repository root:

```sh
make build-apple
open apple/Demo/OSMminiDemo.xcodeproj
```

Select the shared **OSMminiDemo** scheme and an iPhone, Simulator or Mac. For a
physical iPhone, select your development team in Signing & Capabilities.
The framework contains iOS arm64, Simulator arm64/x86_64 and macOS arm64/x86_64.
Generated native binaries are ignored by Git and must be built before resolving
the local Swift package. No Go toolchain is needed on the destination device.

For faster macOS-only development:

```sh
make build-apple-macos
swift run --package-path apple OSMminiDemoCLI
swift test --package-path apple
```

`build-apple-macos` replaces the generated framework with Mac slices only. Run
`make build-apple` again before building for iOS. The build script preserves the
previous complete framework until all requested slices have built successfully.
`GOCACHE`, `GOPROXY`, `GOTOOLCHAIN`, and `DEVELOPER_DIR` may be supplied by CI.
No dependency versions are upgraded by the build.

## Demo workflow

1. Choose a region in the Geofabrik catalog, or select a local `.osm.pbf` file.
   The catalog is read from `https://download.geofabrik.de/index-v1.json` and
   cached locally. Downloads use HTTPS and show transferred bytes.
2. Wait for graph, search and local tinyTiles map preparation. Start with a small
   region; no claim is made yet about Bavaria/DACH import limits on an iPhone.
3. Search an address, street or POI. Select two search results or tap two map
   positions to set start and destination. Export the result as GPX or GeoJSON.
4. Quit and reopen the application, then test without a network connection.
   The published region includes everything needed for map, search and routing;
   neither the PBF nor Geofabrik is needed for this step.

The native `OfflineMap` uses SwiftUI Canvas, local vector geometry and system
fonts. There is no online basemap, CDN, font service, JavaScript or MapLibre
dependency. Pan, pinch/zoom buttons, road labels, building footprints, landcover,
water, route overlay and attribution are included. This is a deliberately small
renderer for the tinyTiles schema; it is not a general MapLibre style engine or
the server web UI's 2.5D renderer.

Downloads retain resume data on cancellation when URLSession/the server provide
it. An interrupted import retains completed graph and search phases in a
`.pending` directory; **Import fortsetzen** reuses them. An interrupted tile
build restarts its tile phase. This release does not register a background
URLSession or guarantee continued importing after iOS suspends or terminates the
app. The resumable files permit retrying when the app runs again.

Download PBFs are retained for future imports. The demo currently reuses a
completed download at the same URL; to fetch a newer revision, remove the cached
PBF from the demo's `downloads` directory first. Updates are published as new
region directories and selected only after successful opening. User-authored
data should be stored outside these immutable directories.

For automated Mac checks, launch the demo with `--region /path/to/region
--offline`. `OSMMINI_DEMO_DIRECTORY` overrides its Application Support directory.

## Import from another Swift application

After building the framework, add this repository (or `apple/`) as a **local
Swift Package** in Xcode and choose the **OSMmini** library product:

```swift
import OSMmini

let options = ImportOptions(pbf: sourceURL,
                            destination: regionDirectory,
                            name: "Niederbayern")
try await OfflineEngine.importPBF(options) { progress in
    // This callback is on a worker thread. Update UI via MainActor.
    Task { @MainActor in print(progress.phase, progress.fraction) }
}

let engine = try await OfflineEngine.open(regionDirectory)
let places = try await engine.search("Passau")
var routing = RouteOptions()
routing.objective = .duration
let route = try await engine.route(RouteRequest(
    from: Coordinate(lat: 48.574, lon: 13.460),
    to: Coordinate(lat: 48.567, lon: 13.432), options: routing))
let gpx = route.gpx()
let geoJSON = try route.geoJSON()
await engine.close()
```

Use `OfflineMap(engine: engine, route: route)` in a SwiftUI view, or supply your
own renderer with `engine.tile(z:x:y:)`. A host renderer may also be implemented
independently of this package. The vector response has extent, layer, class,
name and local integer path coordinates. Engine configuration belongs to an
instance; the wrapper does not modify the server's global routing settings.

`Geofabrik(directory:)` exposes catalog and download APIs separately from the
offline engine. The engine itself performs no network requests. Callers own
source security-scoped URL access during imports; the demo copies selected
sources into its app directory. Cancel a Swift Task to cancel the corresponding
Go operation. `close()` is idempotent and waits for in-flight native work.

Native jobs notify the GCD worker directly on completion or changed progress
through the additive `OSMminiWait` entry point. The UI thread stays unblocked;
ABI 1 and the original polling entry point remain available. The repository's
root README documents the shared Go-core benchmarks and optional server address
index.

## Prepare on a server or Mac

```sh
CGO_ENABLED=0 go run ./cmd/prepare-region \
  -pbf niederbayern.osm.pbf -output regions/niederbayern -name Niederbayern
```

Copy the entire output directory to the app's readable sandbox and call
`OfflineEngine.open`. The format has no absolute source paths and uses explicit
little-endian fields, SHA-256 checksums and a versioned manifest. No PBF parsing
is performed on reopening. Large desktop builds can increase
`-max-import-nodes`; the default is 8 million retained source coordinates.

The file-backed graph uses read-only memory mapping on Apple/Unix platforms;
coordinates, edge records and spatial lookup entries are not expanded to Go
maps. Street metadata, routing search state, OS-resident mapped pages, decoded
tiles and rendering still consume memory. The import node cap and tinySQL tile
cache budget are **not** hard limits on the whole process. PBF generation still
uses intermediate in-memory geometry and requires separate device measurements.

## Package publication

```sh
make build-apple
scripts/package-apple.sh /tmp/OSMmini-Apple.zip
```

The ZIP is a self-contained local Swift package: extract it and add its directory
in Xcode. No Go installation is required by that consumer. To publish a remote
SwiftPM package, use `scripts/prepare-apple-release.sh VERSION RELEASE_BASE_URL`.
It prepares a framework ZIP, its checksum, and a root `Package.swift` referring
to that immutable release asset. Review and commit that manifest for the release
tag, then publish the matching asset. No release is uploaded automatically and
no nonexistent release/checksum is advertised in the development manifest.

## Validation and current scope

`make check-mobile` tests the Go paths without cgo/SQLite; `make test-apple`
builds the Mac framework and runs Swift integration tests. The tests import a
synthetic PBF, remove it, reopen the package, search, route, read vector tiles,
export, and close the engine. Go tests also cover file graph equivalence,
truncation, cancellation, import bounds and corrupt-package rejection.

A separate Swift consumer was also checked with the live Geofabrik Monaco
extract on 2026-10-17: 6,827 graph nodes, 10,311 directed edges, local avenue
search, a 1,144 m route and a tile containing 3,304 vector features. These queries
succeeded after deleting the downloaded PBF. This was a macOS check with zoom
14 tiles, not an iPhone memory or large-region benchmark. iOS device/simulator
and macOS application builds were checked without signing; a physical-device
run and visual interaction review remain necessary.

The first SDK operates on one region at a time. Cross-package routing,
hierarchical long-distance acceleration, a fully disk-streamed PBF importer,
continuous turn-by-turn navigation and automatic map updates are further work.
Routing has the same OSM access/profile/turn-restriction limitations documented
for the existing core; the new wrapper does not make it a validated emergency
navigation system. Address/POI search uses a disk-backed prefix index with AND
filtering, currently node/way POIs and a small German category alias set;
relations and the web server's full category catalog are not indexed here yet.

The native bridge owns a single statically linked Go runtime. If an application
also embeds tinySQL's separate Go XCFramework, consolidate the native entry
points into one archive rather than assuming two Go runtimes can coexist.
See [NOTICE](NOTICE) and [LICENSE](LICENSE) before distribution.
