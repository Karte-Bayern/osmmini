# OSMmini for Swift, iPhone, iPad, iPhone Duo and Mac

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

Select the shared **OSMminiDemo** scheme and an iPhone, iPad, iPhone Duo,
Simulator or Mac.
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

## Native windows and resizable displays

The demo target builds a universal iPhone/iPad app and a native macOS app.
Mac Catalyst is explicitly disabled. iPad multitasking and all interface
orientations are enabled. Building with Xcode 27.1 uses the iOS 27.1 SDK's
full-screen behavior for [iPhone Duo](https://developer.apple.com/iphone-duo/)
while retaining the deployment targets above.

Navigation uses the standard adaptive split view. Route and place details move
beside the map when the actual detail window can retain at least 400 points
for the map and 320–380 points for the inspector. Narrow and shallow windows
keep details below the map; accessibility text uses a wider side panel.
The layout follows available geometry and safe areas, including asymmetric
display insets, rather than device names or interface orientation. `AnyLayout`
retains the map and exporter instances across size changes.

Mac windows start at 1180 × 780 points and resize down to 720 × 500. Native
menu commands act on the focused window: **⌘O** imports a PBF, **⌘F** opens
place search, and **⇧⌘R** toggles route planning. The View menu includes native
sidebar commands. Search/directions sheets have desktop sizes and Escape
closes them. The data engine remains shared between windows; navigation,
location requests and presented panels remain local to each window.

Validation with the complete Niederbayern extract passed all 173 Swift tests,
native macOS and universal iOS Release builds, and the SDK's real-region
search, routing and rendering checks. An iPad UI run retained the selected
Passau route endpoint and 500 m map scale through portrait/landscape changes;
the wide layout was also inspected visually. The iPhone Duo simulator's outer
display rendered the map, search and route-start selection correctly.

Interactive coverage remains limited: the local Duo simulator did not deliver
a usable fold/display-size transition, and macOS UI automation could not start
with the desktop locked. The iPad export-dialog rotation check was interrupted
by a repeatable Simulator Metal/XPC driver crash after calculating the route,
including in an isolated run. These interactions are not claimed as passed.

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
Label collision checks use a bounded grid in screen coordinates to inspect
nearby occupied rectangles. Exact rectangle tests still decide placement;
candidate order, duplicate-name rules and spacing around controls are preserved.
Layouts with fewer than 16 occupied rectangles keep the linear scan.

The map initially fits the region. **Region anzeigen** and **Ganze Route** fit
the corresponding bounds, including after resizing; manual navigation keeps its
position. Display zoom extends to at least level 18 by enlarging existing local
vector tiles, without generating additional detail or requesting missing zooms.
Start and destination use explicit A/B markers, including when a destination is
chosen first. Repeated focus requests can recenter the same coordinate.
The optional `focusMinimumZoom` brings a focused point closer while retaining
any existing nearer zoom. The demo requests level 14 for a place-search
selection, so selecting a city from the regional overview reveals local streets;
map taps retain their current scale. Completed routes still fit both endpoints.
If the nearest endpoint pair has no route, the SDK tries up to eight alternative
pairs from the three nearest nodes within 250 meters of each selected point,
ordered by their combined snapping distance. Existing successful routes retain
their original endpoints. Every attempt uses the same vehicle profile and
routing restrictions, and returns the actual snapping distances. This handles
small disconnected service-road segments near a searched place without
requiring an import or changing graph connectivity.
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
The demo prepares normalized catalog search fields and display order once per
catalog load on a worker. Typing filters those records and counts all matches
while retaining only the first 50 display results. A successful refresh publishes
the prepared catalog in one step; a failed refresh leaves the previous results
usable. Normalized search text remains cached until the next catalog load.

The route panel can collapse while keeping directions and export available.
Start and destination offer search, an explicit cancellable map-picking mode,
and an available in-region GPS fix. Endpoint fields and action rows adapt to
narrow layouts and larger text. A successful GPS fix uses a compact status row;
permission failures and out-of-region positions retain their recovery controls.
Closing the last place-search sheet cancels unfinished work; another open
window can keep using the shared query. Reopening resumes an interrupted query
without clearing settled results. The shared map supports double-tap zoom at
the tapped position, a latitude-aware metric scale, and compact zoom/fit controls.

The bottom panel measures its content directly, so route planning and place
selection appear reliably when a region opens. Start and destination share a
compact two-row group with a separate swap button. Route actions use their
measured width to switch between a row and a column, preserving an active export
while the layout changes. Accessibility text sizes receive more panel space;
map-control icons stay inside their 44-point buttons, while the map scale and
attribution grow up to the largest standard text size. Search status and error
views scroll with the keyboard open. The region list also supports interactive
keyboard dismissal and uses at least 44-point targets for its primary actions.
The map's accessibility description belongs to its Canvas, so zoom controls,
the scale and the attribution link retain their individual VoiceOver labels.

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

Exact settlement names are returned before address and POI matches, including
with `limit: 1`. A small name lookup is prepared during the existing settlement
scan when opening a region; queries do not scan the complete catalog. Results
retain their original OSM identity, and duplicates are removed before applying
the limit. Prefix, multiword and category searches keep their existing behavior.

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
decoded coordinate arrays are not retained by this cache. Visible tiles load
with up to four concurrent fetch/preparation jobs at a time, starting nearest
the displayed map center. Each finished tile appears immediately, even if a
neighbor is slow. Completed tiles survive retries; cancellation stops active
jobs and prevents queued work from starting. Changing loading priority alone
does not change drawing order or restart the current viewport load. Long routes
are projected once on a worker into bounded path chunks; redraws transform cached
paths and skip chunks outside the viewport. Cancellation rejects obsolete route
preparations when the route or region changes. The native vector decoder reuses
its gzip/Deflate reader state across calls without retaining input tiles or
sharing output buffers between callers.

Geometry and labels use separate compact records. Unnamed features carry no
name or label-anchor storage; settlements retain just a label, with no drawing
path. On arm64, geometry metadata occupies 40 bytes per feature instead of 104
bytes. A 1,024-building tile therefore uses 40,960 rather than 106,496 bytes of
record storage, excluding paths and cache overhead. Named roads additionally
use a 56-byte label record, including a prepared name-deduplication key.
The extra 16-byte String value and normalized text storage avoid repeating
Foundation trimming/lowercasing in each frame. Key preparation runs with the
rest of tile preparation on the worker. Display names, geometry precision,
duplicate-name semantics and detail are unchanged.

Dense tiles also prepare a small spatial index on the worker. When panning or
zooming into part of a tile, the renderer skips geometry in invisible cells
before submitting paths to Canvas. Features retain their original paint order;
crossing polygons and roads stay in a containing cell, and selection includes
road casings and antialiasing at viewport edges. The index stores one 32-bit
reference per feature plus 86 32-bit offsets (4,460 bytes for the 1,029-feature
test tile, excluding array overhead). Tiles with fewer than 128 features, or
only paths spanning the entire tile, retain no index. Full-tile views use the
original feature range without allocating a selection array. Bitmap tests
compare indexed and complete drawing at multiple zooms, including polygon
holes, overlapping features, tile edges and road strokes entering the viewport.

Optional Release microbenchmarks report native buffer transfer, map
preparation/rendering and catalog filtering times without timing assertions:

```sh
OSMMINI_BENCHMARKS=1 swift test --package-path apple -c release --filter nativeBufferTransferBenchmark
OSMMINI_MAP_BENCHMARK=1 swift test --package-path apple -c release --filter mapGeometryReplayBenchmark
OSMMINI_MAP_BENCHMARK=1 swift test --package-path apple -c release --filter offlineMapLoadingBenchmark
OSMMINI_MAP_BENCHMARK=1 swift test --package-path apple -c release --filter mapCullingReplayBenchmark
OSMMINI_MAP_BENCHMARK=1 swift test --package-path apple -c release --filter mapLabelLayoutBenchmark
OSMMINI_MAP_BENCHMARK=1 swift test --package-path apple -c release --filter mapLabelKeyBenchmark
OSMMINI_BENCHMARKS=1 swift test --package-path apple -c release --filter catalogPreparedSearchBenchmark
```

An opt-in integration check uses an already prepared, complete Niederbayern
region without downloading or importing data:

```sh
OSMMINI_REAL_REGION=/path/to/niederbayern swift test --package-path apple -c release --filter niederbayernRealRegionIntegration
```

It checks Passau, Landshut, Deggendorf and Straubing, routes Passau–Landshut by
distance and duration, and reads twelve city views at display zooms 12, 14 and
18 (using z14 source tiles for overzoom). Output separates native tile fetching,
geometry preparation and CPU feature selection, with no timing assertions or
GPU frame-rate claims. Files and OS caches remain in place between samples.

The map benchmark measures CPU geometry work and CoreGraphics replay; it does
not measure GPU frame rate or physical-device memory use.
The loading benchmark compares serial loading with the bounded loader using
24 synthetic tiles with 32,768 vertices each. It includes worker JSON decoding,
path preparation and cache publication, alternates execution order across
three passes, and reports timings without a pass/fail threshold. It does not
measure native tile reads, disk I/O, iPhone frame rate or peak device memory.
On macOS arm64 in Release mode (2026-10-19), these three passes took 567–569 ms
serially and 252–270 ms with the bounded loader: median 568 ms versus 256 ms,
about 55% less elapsed time for this synthetic workload.
The culling benchmark replays a synthetic dense tile into a 390 × 600 pixel
CoreGraphics bitmap for 120 moving frames, comparing complete and indexed
drawing at native zoom and four levels of overzoom. It includes index queries
and paint submission, alternates order over three passes, and reports submitted
geometry counts. It does not measure Canvas/GPU frame rate or iPhone power use.
On macOS arm64 in Release mode (2026-10-19), median CPU replay time fell from
125 to 102 ms at native zoom and from 128 to 27 ms at four levels of overzoom
(about 79% less elapsed time in the latter case). Over those 120 overzoomed
frames, submitted geometries fell from 123,480 to 8,160. These are synthetic
CoreGraphics measurements; physical-device rendering still needs profiling.
The label benchmark compares placement with the previous linear scan across
120 frames for sparse phones, dense phones, repeated road names and tablets.
Each frame builds the layout and collision index anew; all accepted-label counts
must agree. It measures layout CPU work rather than text drawing or GPU output.
The catalog benchmark compares 150 mixed queries over 1,000 synthetic regions
with the previous normalization/hierarchy/sort algorithm and reports one-time
preparation separately. Both benchmarks alternate execution order over three
passes and avoid timing assertions.
On macOS arm64 in Release mode (2026-10-19), median label-layout time over
120 frames fell from 32.9 to 23.6 ms for 500 phone candidates per frame (28%),
and from 843 to 467 ms for 3,000 tablet candidates per frame (45%). Sparse
phone layout remained under 1 ms for the complete 120-frame run. Median catalog
filtering time for all 150 queries fell from 1,203 to 155 ms (87%), with 7.8 ms
of one-time preparation. These figures describe synthetic CPU workloads on a Mac.

The prepared-key benchmark isolates the further name-normalization improvement
with the same indexed collision layout on both sides. On macOS arm64 in Release
mode (2026-10-20), three alternating 120-frame samples gave medians of
22.61 → 9.27 ms for 500 phone candidates and 171.92 → 70.29 ms for 3,000 tablet
candidates, about 59% less CPU time. Sparse-phone placement remained under
1 ms for all 120 frames. All accepted-label counts matched. Key construction
is done once outside these redraw measurements; the retained-label storage
tradeoff is described above. These are placement measurements, excluding text
measurement, Canvas/GPU output and whole-app frame rate.

The shared Go router also keeps compact file-graph node indices through
turn-free searches. On the complete Niederbayern graph, full station-to-station
car routes decreased from 177.5 to 107.6 ms (distance objective) and from 272.8
to 159.0 ms (duration objective), with exactly matching paths and metrics.
Cumulative allocation decreased from about 38 to 29 MB per route. These are
alternating desktop query samples; see the [Go measurements](../README.md#shared-go-core-performance).
Existing regions use this search optimization without reimporting.

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
their graph mapping before map generation begins. A retry also removes private
tinyTiles/tinySQL map workspaces left by a terminated app, keeping those
temporary files out of the published package.

## Offline storage

New imports write region format 4, using chain-packed graph, prefix-index and
compressed search files. Format 1–3 regions remain readable. The Swift query API
is unchanged; update the native framework together with the Swift sources.
Older SDKs cannot open format 4 packages.

The graph stores 32-byte nodes, 16-byte edges and 12-byte spatial entries.
Ordinary edges refer to internal node indices and shared 32-byte attribute records.
Long bidirectional degree-two chains share 16-byte chain records and 12-byte
vertices instead of storing two complete edges at every interior node.
Short chains, branches and road-attribute changes retain ordinary edges.
Original signed 64-bit OSM IDs and all coordinate/distance/attribute float bits
are preserved. The graph stays memory-mapped; it does not expand into maps on
opening. Copying an already file-backed graph preserves its existing format.

The complete Niederbayern reimport on 2026-10-20 reduced the graph from
163,090,371 to 140,182,031 bytes and the entire zoom-5–14 package from
267,635,432 to 244,727,092 bytes: **22.91 MB saved**. All 2,096,430 nodes and
4,307,453 logical directed edges remain available. Explicit edge records fall
to 1,252,231 by sharing 191,097 chains. Every coordinate/ordered edge bit and
both Passau Hbf–Landshut Hbf route results matched the previous graph.
Search checksums stayed identical. Query allocations and routing times remain
roughly unchanged; this does not establish physical-iPhone RAM savings.
See the [chain storage measurements](../README.md#lossless-road-chain-storage)
for exact sizes, compatibility and reproducible comparisons. Reimport into a
new destination to obtain this representation.

The search index uses byte-prefix terms and varint offsets/lengths in blocks of
at most 128 postings. A small fixed-width directory stays on disk for binary
lookup; queries decode only the relevant blocks into bounded scratch buffers.
Legacy fixed-width indices remain readable. The existing `search.jsonl` filename
now holds an `OSMSDAT1` container: independently zlib-compressed 32 KiB blocks
and a disk-resident offset directory. Postings still address the original JSON
byte stream. Queries decompress only the needed blocks, and settlement labels
scan them sequentially. Inflaters and fixed-size buffers are reused per query;
records crossing block boundaries use a query-local buffer capped at 1 MiB.
Legacy raw JSONL remains readable. Logical JSON records and vector map detail
are unchanged.

A full import on 2026-10-19 compared commit `0054781` with format 3,
using the same Niederbayern PBF, zooms 5–14 and a 256 MiB tile-writer budget:

| Files | Previous | Compact |
| --- | ---: | ---: |
| Routing graph | 326.1 MB | 163.1 MB |
| Search index | 124.7 MB | 8.2 MB |
| Search records | 55.2 MB | 9.7 MB |
| Map artifact | 86.6 MB | 86.6 MB |
| **Entire region** | **592.6 MB** | **267.6 MB** |

These are decimal logical file sizes and exclude the source PBF. The package
saves 325.0 MB (54.8%). Compressing the records saves another 45.5 MB compared
with the 313.1 MB format-2 package. Imports took about 38 seconds on an M2 Max;
this does not establish iPhone import limits. The same 2,096,430 nodes and
4,307,507 directed edges are retained. Every decompressed search byte matched
the original catalog; graph and index bytes were unchanged from format 2.
Search, route and decoded-tile comparisons also matched.

Compression trades some CPU time for disk space. In a 20,000-record synthetic
catalog, a 20-result category query took about 0.06 ms instead of 0.02 ms, and a
broad two-word query took about 4.8 ms instead of 1.8 ms. Missing-prefix queries
were unchanged. Opening the full Niederbayern package, including its settlement
scan, took about 0.57 seconds instead of 0.44 seconds. These are Mac measurements,
not iPhone latency claims.

Previously installed regions keep their original size until rebuilt. Import
the PBF again into a new destination to use the compact format; a published
destination is never overwritten. The demo reuses existing current-format
packages, but creates a compact package instead of reusing a legacy one. Keep
the original until the replacement opens successfully, then remove the old
region from the list. Source PBF downloads can be removed separately once no
pending import needs them. Old unfinished imports require a new workspace;
their completed phases are not mixed with the new format.

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
run remains necessary.

The Niederbayern extract was also checked on macOS on 2026-10-18 at zooms 5–14:
2,096,300 graph nodes and 4,307,251 directed edges, with graph, search and map
publication completed. The prior importer reproducibly stopped at the
8-million-source-node cap; after filtering road coordinates, the prior
1,000-row tile batch independently failed its 256 MiB budget. The road filter
and smaller publication batches address both failures. This is a desktop
integration check, not a physical-iPhone memory measurement.

The full [Geofabrik Niederbayern extract](https://download.geofabrik.de/europe/germany/bayern/niederbayern.html)
dated 2026-10-18 was checked again on 2026-10-19 (source SHA-256
`aa3ebd4abc87effb460c5c7b984c6d6496247cfaa966590f6929faae791b7cb4`).
Its 95.4 MB PBF produced a 267.6 MB format-3 package with 2,096,430 nodes and
4,307,507 edges at zooms 5–14. The Mac import took 38.2 seconds, with about
2.01 GiB maximum RSS. The opt-in Swift Release check opened it in 0.60 seconds;
100-result searches in the four cities had medians of 1.6–2.9 ms over three
samples. Coordinates near Passau and Landshut stations took about 1.8 seconds
for distance optimization (109.6 km) and 1.0 second for duration optimization
(120.0 km). The actual city search results also produced a 109.5 km car route;
the snapped endpoints were about 86 and 32 meters from the selected places.
All twelve city map views passed, including z18 display using z14 data.
These are macOS measurements with existing files and retained OS caches;
they do not establish physical-iPhone import memory or rendering performance.

The same complete package also passed an iPhone SE simulator interaction check
on iOS 26.4: Passau and Landshut appeared as the first city results, the route,
directions and GPX/GeoJSON menu worked, and selecting Deggendorf changed the
visible scale from 50 km to 500 m. Zoom controls and the scale retained their
individual accessibility labels. Region preparation ran on the Mac; the
simulator exercised the prepared offline package.

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
