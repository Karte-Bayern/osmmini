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

Select the shared **OSMminiDemo** scheme and an iPhone, Simulator or Mac.
For a physical iPhone, configure your signing team once in a local file:

```sh
cp apple/Demo/Configuration/Signing.local.xcconfig.example apple/Demo/Configuration/Signing.local.xcconfig
```

Replace `YOUR_TEAM_ID` in that local file with your Apple Developer team ID.
Existing local files should be edited directly instead of overwritten. Both
Debug and Release automatically load the optional file via `Signing.xcconfig`.
It persists between builds, is ignored by Git, and is excluded from the Apple
ZIP. Edit this file rather than selecting a team in Xcode's Signing &
Capabilities picker, which can write the team back into `project.pbxproj`.
A fresh checkout or distributed package has no configured team; simulator and
unsigned CI builds do not require the local file. For a one-off CLI override,
append `DEVELOPMENT_TEAM=YOUR_TEAM_ID` to `xcodebuild` instead.

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
   The catalog is read from `https://download.geofabrik.de/index-v1-nogeom.json` and
   cached locally. Downloads use HTTPS and show transferred bytes.
2. Wait for graph, search and local tinyTiles map preparation. Start with a small
   region; no claim is made yet about Bavaria/DACH import limits on an iPhone.
3. Open **Orte suchen** on the map or tap a map position to preview a place.
   The preview leaves an existing route unchanged. Choose **Als Start** or
   **Als Ziel** explicitly; either endpoint may be set first. **Route planen**
   provides endpoint search, swapping, retry, a step list and GPX/GeoJSON export.
   Routing uses the car profile; choose **kürzeste Strecke** or **schnellste
   Strecke**. The choice persists across launches and recalculates an existing
   route without losing its endpoints. Closing route details keeps the route
   visible; **Route zurücksetzen** explicitly removes it.
4. Quit and reopen the application, then test without a network connection.
   The published region includes everything needed for map, search and routing;
   neither the PBF nor Geofabrik is needed for this step.

The native `OfflineMap` uses SwiftUI Canvas, local vector geometry and system
fonts. There is no online basemap, CDN, font service, JavaScript or MapLibre
dependency. Pan, pinch/zoom buttons, road and settlement labels, building
footprints, landcover, water, route overlay and attribution are included.
Settlement labels are derived from the region's existing search index when it
opens, so previously imported regions gain names without importing the PBF
again. Road labels use the midpoint of their longest path; collision checks
prioritize settlement names and avoid duplicate labels.

The map initially fits the region. **Region anzeigen** and **Ganze Route** fit
the corresponding bounds, including after resizing; manual navigation keeps its
position. Display zoom extends to at least level 18 by enlarging existing local
vector tiles, without generating additional detail or requesting missing zooms.
Start and destination use explicit A/B markers, including when a destination is
chosen first. Repeated focus requests can recenter the same coordinate.
Missing tiles no longer stop
the remaining viewport from loading; **Erneut laden** retries missing tiles
while keeping successful ones. This is a deliberately small
renderer for the tinyTiles schema; it is not a general MapLibre style engine or
the server web UI's 2.5D renderer.

Downloads retain resume data on cancellation when URLSession/the server provide
it. An interrupted import retains completed graph and search phases in a
`.pending` directory; **Import fortsetzen** reuses them. An interrupted tile
build restarts its tile phase. This release does not register a background
URLSession or guarantee continued importing after iOS suspends or terminates the
app. The resumable files permit retrying when the app runs again.

New imports cannot silently replace the saved pending import. **Mit vorhandener
PBF neu beginnen** uses a new workspace with the same source and import limits
when an old checkpoint cannot resume. **Fortsetzung aus Liste entfernen** clears
only the resume entry after confirmation. It leaves source files and checkpoints
on disk; it is not a disk-cleanup action.

Import failures appear in the region list with their last reported phase and
expandable technical details, including in the iPhone's compact layout. The
pending import retains that diagnostic information across app restarts. If the
app was interrupted without a reported error, the list shows its last saved
phase. Retrying clears the previous error; completing or removing the pending
entry also clears its saved diagnostics.

App-owned import and last-region paths are stored relative to the demo's data
directory. Legacy absolute paths are rebased when the iOS data container moves,
including the source download and its pending workspace. External source paths
remain absolute. A missing PBF reports how to download or select it again.

The region list shows each installed map's import date and logical file size.
Regions can be deleted through their context menu or swipe action after a
confirmation; deleting the open region closes its engine first. **Downloads
entfernen** removes cached PBFs and download resume data, while installed maps
remain usable. This action is unavailable during an operation or while a saved
import still needs its source. It preserves the catalog and unrelated files.
Unfinished import workspaces are not included in this cleanup.

Completed downloads are reused at the same URL. To fetch a newer revision,
remove downloads in the app first. Importing an identical PBF with the same zoom
range opens the existing package instead of creating another copy; identity is
a cancellable, streamed SHA256 comparison, not the file or region name. Changed
sources are published as new directories and selected only after successful
opening. User-authored data should be stored outside these immutable directories.

**Meinen Standort anzeigen** starts Core Location only after a user action.
The demo requests foreground access, displays a blue position and accuracy
circle, and can use an in-region fix as the route's start. If location precision
is reduced, the previous precise fix is discarded immediately and pre-change
queued fixes cannot republish it. GPS works without a map network request;
denied permissions, disabled services, approximate fixes, stale coordinates, a
first-fix timeout and positions outside the installed region
have explicit states. Tracking stops when the app enters the background or its
window closes. It does not provide background navigation or live turn guidance.
Permissions, timeout/cancellation and stale-fix handling have injected-driver
tests; actual satellite reception and device battery use require an iPhone test.

For automated Mac checks, launch the demo with `--region /path/to/region
--offline`. `OSMMINI_DEMO_DIRECTORY` overrides its Application Support directory.

The demo uses property-level [SwiftUI Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)
and separate map, search, catalog and progress views. Progress updates do not
invalidate the map's model dependencies or repeat catalog filtering. Demo
windows share one model and open engine, avoiding duplicate graph instances.
Region manifests, file-size scans, source hashing, cancellable PBF copies,
route export encoding and route-fit calculations run off the main actor. Manual map navigation cancels a pending
automatic fit. Successful local imports remove their temporary source copy.
The source copy for an interrupted import remains available for retry, including
after removing its resume entry from the list. Geofabrik downloads remain cached
for reuse.

Installed regions use manifest names, and selecting the current region keeps
the open graph and route. A restored local region does not trigger an automatic
catalog request. Search clears stale results as soon as the query changes;
errors stay with the search/catalog that produced them. Routing selection stays
fixed during a calculation; resetting cancels it. Phase tokens reject delayed
progress after cancellation, completion or a change from download to import.
Failed or cancelled routes retain their endpoints and can be retried or edited.
The catalog distinguishes an unloaded list from a filter with no matches, and
its first load can use the offline cache. File-dialog cancellation is silent;
successful exports receive a short confirmation and real failures stay visible.
GeoJSON uses typed JSON encoding so invalid numbers produce a Swift error
instead of an Objective-C JSON serialization exception.
Opening a region or choosing a search result reveals the map in compact layouts
using [NavigationSplitView's preferred compact column](https://developer.apple.com/documentation/swiftui/navigationsplitview).

Installed maps, unfinished imports and source-file storage have separate sections.
Selecting a Geofabrik region opens a download/import summary with a persistent
primary action. Catalog search matches multiple words across names and ancestor
regions, ignores accents and ranks exact names first. Technical error details
remain available in disclosures while recovery actions stay visible.

The route panel can collapse while keeping directions and export available.
Start and destination offer search, an explicit cancellable map-picking mode,
and an available in-region GPS fix. Endpoint fields and action rows adapt to
narrow layouts and larger text. A successful GPS fix uses a compact status row;
permission failures and out-of-region positions retain their recovery controls.
Closing the last place-search sheet cancels unfinished work; another open
window can keep using the shared query. Reopening resumes an interrupted query
without clearing settled results. The shared map supports double-tap zoom at
the tapped position, a latitude-aware metric scale, and compact zoom/fit controls.

Demo regression tests run with `swift test --package-path apple --filter DemoModelTests`.
They use a tiny local PBF and cached catalog fixtures. Observation checks verify
invalidation boundaries; they do not measure frame rate on an iPhone.

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

Requests are encoded directly on the worker. Response decoding takes ownership
of the native UTF-8 buffer, avoiding a temporary Swift string and a second large
byte buffer. GPX export appends to one output buffer. `OfflineMap` prepares
tile-local drawing paths on a worker once per loaded tile, then reuses them as
the viewport moves. Its cache retains prepared geometry and label candidates for the current
viewport (at most 128 tiles), and discards it when the engine changes. Raw
decoded coordinate arrays are not retained by this cache. Long routes are
projected once on a worker into bounded path chunks; redraws transform cached
paths and skip chunks outside the viewport. Cancellation rejects obsolete route
preparations when the route or region changes. The native vector decoder reuses
its gzip/Deflate reader state across calls without retaining input tiles or
sharing output buffers between callers.

Geometry and labels use separate compact records. Unnamed features carry no
name or label-anchor storage; settlements retain just a label, with no drawing
path. On arm64, geometry metadata occupies 40 bytes per feature instead of 104
bytes. A 1,024-building tile therefore uses 40,960 rather than 106,496 bytes of
record storage, excluding paths and cache overhead. Named roads additionally
use a 40-byte label record. Geometry precision and detail are unchanged.

Optional Release microbenchmarks report native buffer transfer and path
preparation/reuse times without timing assertions:

```sh
OSMMINI_BENCHMARKS=1 swift test --package-path apple -c release --filter nativeBufferTransferBenchmark
OSMMINI_MAP_BENCHMARK=1 swift test --package-path apple -c release --filter mapGeometryReplayBenchmark
```

The map benchmark measures CPU geometry work and CoreGraphics replay; it does
not measure GPU frame rate or physical-device memory use.

`Geofabrik` retains its decoded catalog in memory after the first load. Overlapping
catalog refreshes share the result. Concurrent downloads of the same PBF URL
wait for the active transfer and reuse its completed file, with each caller's
size limit checked independently. Different URLs can still download concurrently.
All callers, including those waiting for an existing download, receive progress
and the final byte count; cancelled callers are removed from that subscription.
Cancelling a waiting caller leaves the active transfer running; cancelling the
active transfer saves resume data before the next caller may retry. Downloads
are staged beside the destination before publication, so partially moved files
are never mistaken for a completed PBF.

Download progress is normally reported at 100 ms intervals, with the initial,
final and changed-size values reported immediately. Local URLProtocol tests
verify request coalescing and cancellation without accessing Geofabrik. The
optional `catalogWarmCacheBenchmark` compares repeated disk/decode/sort with
the retained catalog using `OSMMINI_BENCHMARKS=1`.
The catalog uses Geofabrik's [official properties-only variant](https://download.geofabrik.de/technical.html),
since the region picker does not use boundary geometries. Existing full-index
cache files remain readable.

The downloader follows Apple's [file-download lifecycle](https://developer.apple.com/documentation/foundation/downloading-files-from-websites)
and [resume-data rules](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads):
move temporary files before the download delegate returns, finish from the
terminal task callback, save available resume data, and invalidate each
delegate-owning session. Shared catalog requests use a reusable session;
large PBF transfers keep separate sessions to isolate their delegate and
cancellation lifecycle. Request coalescing and caching also follow Apple's
[guidance on reducing networking power usage](https://developer.apple.com/documentation/xcode/reducing-networking-and-bluetooth-power-usage).

## Prepare on a server or Mac

```sh
CGO_ENABLED=0 go run ./cmd/prepare-region \
  -pbf niederbayern.osm.pbf -output regions/niederbayern -name Niederbayern
```

Copy the entire output directory to the app's readable sandbox and call
`OfflineEngine.open`. The format has no absolute source paths and uses explicit
little-endian fields, SHA-256 checksums and a versioned manifest. No PBF parsing
is performed on reopening. Large desktop builds can increase
`-max-import-nodes`; the default is 8 million referenced road nodes. The graph
importer reads roads first, then retains only their coordinates; unrelated
building, landcover and POI nodes do not consume that limit. Address extraction
for Go callers still includes address nodes outside the road graph.

New region directories also include `NOTICE.txt` with OSM attribution and ODbL
links. Keep it when copying or distributing the package; the map displays a
visible link to OpenStreetMap's copyright page. Software and map-data licences
remain separate.

The file-backed graph uses read-only memory mapping on Apple/Unix platforms;
coordinates, edge records and spatial lookup entries are not expanded to Go
maps. Street metadata, routing search state, OS-resident mapped pages, decoded
tiles and rendering still consume memory. The import node cap and tinySQL tile
cache budget are **not** hard limits on the whole process. PBF generation still
uses intermediate in-memory geometry and requires separate device measurements.
Tile publication uses 32-row batches so large compressed tiles fit the configured
writer budget without increasing that limit. The default upstream 1,000-row
batch can exceed 256 MiB even for a regional extract. Tile-writing progress
advances with the number of rows saved.

Search preparation streams way metadata to temporary files and uses compact
coordinate arrays instead of retaining way tag maps. The prefix index is sorted
in chunks of 16,384 postings with at most 16 open input runs per merge. Temporary
files consume additional disk space during import and are cleaned up on success,
cancellation and retry after termination. Graph and search preparation close
their graph mapping before map generation begins. The published region format
and normal query APIs are unchanged; existing regions remain readable.

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

The Niederbayern extract was also checked on macOS on 2026-10-18 at zooms 5–14:
2,096,300 graph nodes and 4,307,251 directed edges, with graph, search and map
publication completed. The prior importer reproducibly stopped at the
8-million-source-node cap; after filtering road coordinates, the prior
1,000-row tile batch independently failed its 256 MiB budget. The road filter
and smaller publication batches address both failures. This is a desktop
integration check, not a physical-iPhone memory measurement.

A before/after RAM check on 2026-10-19 used the same Niederbayern PBF, zooms
5–14, a 256 MiB tile-writer budget and Go 1.27.2 on macOS arm64. Compared with
commit `6ad1fa3`, a complete import's maximum RSS (`/usr/bin/time -l`) decreased
from 2,673,737,728 to 2,428,862,464 bytes (2.49 to 2.26 GiB, about 9%). Wall time
was about 39 versus 41 seconds in these individual runs. Graph and search files
were byte-identical, with 2,096,430 nodes and 4,307,507 directed edges. The
remaining peak is dominated by tinyTiles' in-memory map generation. This is a
desktop measurement; the 256 MiB writer setting does not cap the total importer
or establish a safe iPhone region size.

The first SDK operates on one region at a time. Cross-package routing,
hierarchical long-distance acceleration, a fully disk-streamed PBF importer,
continuous turn-by-turn navigation and automatic map updates are further work.
Re-import into a new destination to apply changed routing-import rules. Existing
published regions stay readable; a pending workspace from an older import
revision is preserved and requires a new destination.
Routing has the same OSM access/profile/turn-restriction limitations documented
in the root README's coverage table; the new wrapper does not make it a validated emergency
navigation system. Address/POI search uses a disk-backed prefix index with AND
filtering, currently node/way POIs and a small German category alias set;
relations and the web server's full category catalog are not indexed here yet.

The native bridge owns a single statically linked Go runtime. If an application
also embeds tinySQL's separate Go XCFramework, consolidate the native entry
points into one archive rather than assuming two Go runtimes can coexist.
See [NOTICE](NOTICE) and [LICENSE](LICENSE) before distribution.
