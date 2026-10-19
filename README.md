# OSMmini

[![DOI](https://zenodo.org/badge/1116409323.svg)](https://doi.org/10.5281/zenodo.18929953)

OSMmini is an open-source routing server and map web UI that can run fully
offline. It builds its routing graph, address search and POI index from one
OpenStreetMap PBF extract, so it works for a single region without any external
service.

![OSMmini web UI](https://simonwaldherr.de/gh-pages/osmmini.png)

**Contents:**
[Features](#features) ·
[Quick start](#quick-start) ·
[Map profiles](#map-profiles) ·
[Large PBF files](#large-pbf-files) ·
[Web UI guide](#web-ui-guide) ·
[HTTP API](#http-api) ·
[Command-line tools](#command-line-tools) ·
[Configuration](#configuration) ·
[Production](#running-in-production) ·
[Development](#development)

## Features

**Routing and trips**
- Routing engines `astar`, `dijkstra` and `dijkstra-node`, optimising for
  distance or duration, with turn-by-turn directions
- Trip solver for up to 60 stops with dependencies ("A before B") and vehicle
  capacity; up to 16 stops are solved exactly
- Multi-resource work planning for deliveries, maintenance teams and municipal
  services: priority, cumulative capacity, required skills and territory rules;
  available through `dispatch plan`, Go and `POST /api/v1/dispatch/plan`
  ([examples and Fleetbase lessons](docs/work-planning.md))
- **Route export as GPX** (for sat navs and GPS apps) **or GeoJSON** (for GIS
  tools), available in the UI, through the API and on the command line

**Search and maps**
- Address, street and POI search with German and English category aliases
  ([category catalog](docs/osm-categories.md))
- Map-first microMap UI (MapLibre GL optional) with a mobile layout and a keyboard shortcut
  (<kbd>Ctrl</kbd>/<kbd>⌘</kbd>+<kbd>K</kbd>) to focus search
- Offline vector basemap generated from your PBF (tinyTiles) with adjustable
  styles; alternatively, OSM raster, BayernAtlas vector/WMTS or your own
  MBTiles/GeoTIFF

**GIS and field work**
- POI export (viewport or radius) as GeoJSON and distance measurement
- Import of GeoJSON, KML/KMZ and Shapefile layers; territory layers with lookup
  and CSV assignment
- Browser-local **GIS workbench** with an attribute table, typed attribute edits,
  filters, CSV joins, line simplification, undo and GeoJSON/CSV export
  ([guide and sample files](docs/gis-workbench.md))
- OSM-Edit: a draft editor for nodes, ways and relations that exports `.osc`
  change files and never uploads anything itself
- Delivery-proof, maintenance and status log with barcode scanning and CSV
  export
- Emergency mode: fire hydrants, fire stations with vehicle rosters, and
  confidential objects that never leave the server

## Quick start

**Requirements:** Go 1.26.5+, Node.js (only for the JS tests), `curl`, and an OSM
PBF extract, for example from [Geofabrik](https://download.geofabrik.de/).

```bash
# 1. Download a PBF and the optional pinned MapLibre assets (one-off, needs network):
make offline-prep GEOFABRIK_URL='https://download.geofabrik.de/europe/germany/bayern/niederbayern-latest.osm.pbf'

# 2. Start the server:
make run                     # same as: go run -tags=sqliteimport ./cmd -pbf region.osm.pbf

# 3. Open http://localhost:8080/
```

The default profile ([`settings.json`](settings.json)) uses the local offline
map. Build it once with **Einstellungen → Offline-Karte erzeugen**. After that,
the map is available without a network connection. Routing, search and POIs
work as soon as the graph is loaded (see the log line `Graph ready: …`).

`osmmini help` lists all commands and flags, and `osmmini version` prints the
build version.

## Map profiles

| Profile | Start | Basemap |
| --- | --- | --- |
| Default | `make run` | Local tinyTiles vector map (offline). OSM raster and other presets can be selected in the settings |
| Bavaria | `make bayern ADMIN_TOKEN=… BAYERN_PBF=bayern.osm.pbf` | Official BayernAtlas vector map. It falls back automatically to BayernAtlas WMTS when WebGL is unavailable. This map only covers Bavaria |
| Fully offline | `make offline ADMIN_TOKEN=… PBF=region.osm.pbf` | tinyTiles only, no online source |

The map can be global, but routing, address search and POIs always cover only
the PBF you loaded.

### Offline map (tinyTiles)

**Offline-Karte erzeugen** builds the `.ttiles` artifact from the loaded PBF.
It includes roads by class, paths, buildings, water, forest and farmland. The
artifact is stored in `offline-tiles/basemap.ttiles` and is loaded again
automatically after a restart. If the same value was passed as `-admin-token`,
first enter it under **Einstellungen → Administrationsschutz**.

- **Style:** **Einstellungen → Offline-Karte → Kartenstil anpassen** has the
  presets Natur, Atlas, Nacht and Hoher Kontrast. You can also change colours,
  road width, label size and which layers are shown. Changes are previewed
  immediately and saved in the browser, and the tiles do not need to be
  rebuilt.
- **Waterways:** a separate local sidecar adds rivers and canals from zoom 7,
  streams from zoom 11 and drainage details from zoom 13. Existing artifacts are
  upgraded in the background at startup if the PBF has not changed.
- **2.5D buildings:** from zoom 14, a local companion layer provides building
  footprints, heights and elevated bases to microMap and MapLibre. Choose
  **Kartenanzeige → Perspektive** (45°) to see the walls; Canvas also works
  without WebGL. Explicit `height`/`building:height` wins, followed by
  `building:levels` × 3 m plus tagged roof height/levels. Missing heights use
  8 m for ordinary buildings, 3 m for garages/sheds/carports/greenhouses, and
  6 m for barns/warehouses/industrial buildings. These are visual estimates,
  identified by `height_source`, not measured heights. Closed building and
  building-part ways are supported; building multipolygon relations are not.
- **Build efficiency:** buildings and waterways share two PBF scans and retain
  only referenced node coordinates. Rebuilds reuse validated companion geometry
  when the source path, size and modification time are unchanged. Viewport
  queries use a spatial grid and bounded responses (3000 buildings/100000
  vertices); existing maps gain the companion layer in the background at
  startup when the source PBF is still available and has not changed.
- **Postcodes:** if the build includes postcode boundaries, you can query them
  with `GET /tinytiles/postcode/search?q=940`, `/tinytiles/postcode/94032` and
  `/tinytiles/postcode/at?lon=13.46&lat=48.57`.
- Complex multipolygon areas need a more detailed tile generator.

The default renderer is [microMap](https://github.com/Karte-Bayern/microMap)
0.3.0. Its bundle and MIT license are included locally and embedded in the
server, so vector maps also work with Canvas 2D when WebGL is unavailable.
Routes, markers, popups, GeoJSON overlays and map controls use its
MapLibre-compatible API.

Choose **Einstellungen → Kartenanzeige → Kartenrenderer** to switch between
microMap and MapLibre GL. **Speichern** persists the selection in `settings.json`
(`map_display`) and reloads the UI when rendering options change, preserving
the map centre and zoom. The setting becomes the default for clients after
reloading; saving requires the configured administrator token, if any.

microMap has the presets **Standard**, **Sparsam** and **Perspektive**, plus
individual settings for rendering resolution (1×, up to 1.5× or 2×), initial
pitch (0°, 45° or 60°), WebGL/Canvas 2D buildings, sky visibility and rotation/
pitch gestures. Its options are retained when switching to MapLibre.
The offline map supplies its own 2.5D building layer; other map sources depend
on the selected style supplying extrusions.

`?renderer=maplibre` or `?renderer=micromap` temporarily overrides the saved
selection; saving the form removes the override. MapLibre's local assets
require `make maplibre-assets`. No renderer loads from a CDN.
`make ensure-micromap-assets` verifies the bundled microMap checksums;
`make micromap-assets` rebuilds the pinned upstream source.

microMap supports a subset of MapLibre styles: terrain, hillshade and globe
projection are unavailable, and labels use browser fonts. Route fitting respects
sidebar padding; microMap does not support persistent camera padding. For map
image export, use a flat, north-facing view (0° pitch and bearing).

## Large PBF files

Load a regional extract rather than a whole country or continent. The routing
graph, POI index and offline map then stay small:

```bash
go run ./cmd region-extract \
  -pbf germany-latest.osm.pbf \
  -bbox 11.7,47.8,14.3,49.3 \
  -output regions/niederbayern.osm.pbf

go run ./cmd -pbf regions/niederbayern.osm.pbf
```

`region-extract` requires the external tool
[`osmium`](https://osmcode.org/osmium-tool/). It uses the `complete_ways`
strategy, so ways that cross PBF block boundaries are kept in full. By default
it creates or reuses the spatial sidecar index `germany-latest.idx`
(`-index=false` skips this). A matching regional PBF that already exists is
reused (`-reuse=false` forces a rebuild).

The sidecar index can also be created on its own:

```bash
go run ./cmd pbf-index -pbf europe.osm.pbf   # writes europe.idx
```

The indexer streams the PBF one block at a time without loading it into memory.
For each block it records the byte range and node extent, together with the
file's size, timestamp and SHA-256. The index becomes invalid when the PBF
changes. Because ways reference nodes in other blocks, the index only selects
node blocks. Extracting complete ways still happens in `region-extract`.

## Web UI guide

### Routes and trips

Enter a start and destination (an address, a POI, `lat,lon`, or a click on the
map) and add stops as needed. With **Reihenfolge optimieren** switched on,
OSMmini calculates the best order of the stops. Once a
route has been calculated, these actions are available:

- **Einpassen / Löschen**: fit the route to the map or remove it
- **GeoJSON**: a LineString with distance and duration, for QGIS, uMap and
  similar tools
- **GPX**: start, stops and destination as waypoints, the turn-by-turn
  directions as `<rte>` and the exact road geometry as `<trk>`. It can be
  imported into Garmin devices, OsmAnd, Komoot, Locus and most GPS apps
- links for handing the route over to Google Maps or Apple Maps

### GIS & Geo-Werkzeuge

- Search POIs in the viewport or within 1–50 km of the map centre, filter them
  by name or category, and download them as GeoJSON. The UI shows at most 320
  points; the API returns up to 1,000.
- **Strecke messen**: draw a polyline independently of the route. The result is
  the sum of great-circle distances, not a driving distance or survey
  measurement.
- **Importieren**: GeoJSON, KML/KMZ and Shapefile ZIPs become map layers.
  Polygon layers are also available as territory layers. Admins can use one
  MBTiles or GeoTIFF file as an extra map source.

### OSM-Edit (draft editor)

OSM-Edit never uploads anything. Drafts stay in the browser (`localStorage`)
and can only be exported as an `.osc` change file or a `.json` backup for manual
upload in a full OSM editor.

1. **Finden**: load the visible OSM working geometry from zoom 16 with **OSM-Ausschnitt laden**, select a place on the map, search for one, add a point, or draw
   a way or area. New vertices snap to existing ones.
2. **Bearbeiten**: typed fields for each place type, hints for common mistakes,
   a change summary and the full tag table. For ways, the editor can move
   vertices (**Punkte bearbeiten**), edit coordinates, insert vertices on a segment, remove vertices without deleting shared OSM nodes, split a way (**Weg teilen**) and join two
   ways (**Mit Weg-ID verbinden**). <kbd>Ctrl</kbd>/<kbd>⌘</kbd>+<kbd>S</kbd>
   saves tags and geometry together; **Verwerfen** discards pending geometry too.
3. **Entwürfe**: undo/redo, compare with the current OSM state, export. If an
   object has changed on OSM in the meantime, the export is blocked.
4. **Relationen**: create a relation or load one by ID, reorder members and
   edit their roles.

The sticky editor toolbar provides point/way/area tools and saved-change undo/redo. Shortcuts: **P**, **L**, **A** to draw, **Enter** to finish, **Escape** to cancel, **Delete** to detach a selected way vertex, and **Ctrl/⌘ Z** / **Ctrl/⌘ Shift Z** for saved-change history. Text inputs keep their native keyboard shortcuts. Loaded working geometry can be hidden and is cleared visually when leaving the editor.

Existing objects can be marked as a reversible **Löschentwurf** after their parent ways/relations have been checked. Used objects cannot be deleted without changing their parents. Untagged support vertices are grouped below their main drafts; removing a new way cleans up only its unused new vertices. Areas that overlap themselves or collapse to a line are rejected. Map reads, full-object loading and parent checks use the [OSM API v0.6](https://wiki.openstreetmap.org/wiki/API_v0.6). Building and road presets include addresses, building levels, height, surface, width, speed limits and direction as applicable.

Objects marked **vertraulich speichern** (for example fire-brigade internals or
access information) are stored only on the server, in
`confidential-objects.json`. They never appear in an OSM export, and they
require `-admin-token`.

Place types are defined in `cmd/web/osm-presets.js`; validation, topology and
export logic is in `cmd/web/osm-editor.js`.

### Zustellung & Wartung (log)

This local audit log is designed for mobile use:

- **Zustellnachweis**: barcode/QR code or object ID, recipient, reference, time
  and optional GPS position
- **Wartung**: work type, status and the person who did the work
- **Lage & Check**: availability, damage or closures of resources and operation
  sectors

Camera scanning uses the browser's `BarcodeDetector`, and manual entry always
works. Entries can be filtered and exported as CSV. When the connection drops,
the browser queues entries and retries them on reconnection and while the page
remains online. Each operation carries a `client_event_id`; repeating the same
request returns the original record, while reusing the ID with different data
returns HTTP 409. The offline queue accepts 100 entries and the browser-local
history accepts 500; reaching either limit shows an error and preserves the
existing entries.
Failed transfers remain queued with the same ID and show an error in the log
status. If browser storage is malformed, the app keeps its raw value instead
of replacing it with an empty log; back up the local browser data before
repairing it.

How the data is stored depends on `-deployment-mode`:

| Mode | Storage | Suitable for |
| --- | --- | --- |
| `browser-local` | Only the browser's `localStorage`, exported as CSV | Single offline laptop or phone |
| `single-user` (default) | `operations.json` on the server, protected by `-admin-token` if set | One user or a trusted team |
| `multi-user` | Central history with a personal token for each operator, who is recorded in every entry | Teams |

```bash
cp operators.example.json operators.json   # replace the tokens with long random values
go run ./cmd -deployment-mode multi-user -operators-file operators.json
```

### Emergency mode (Einsatzmodus)

Map overlays for fire hydrants (`emergency=fire_hydrant`) and fire stations.
Stations can be enriched with vehicle rosters (call sign, equipment) manually or
by CSV import. The rosters are stored only locally in `fire-stations.json`.

## HTTP API

The full specification is in [`cmd/api/openapi.yaml`](cmd/api/openapi.yaml), and
the server also serves it at `/api/v1/openapi.yaml`. Coordinates in GeoJSON are
always `[lon, lat]`.

| Endpoint | Purpose |
| --- | --- |
| `GET /api/v1/health` | Liveness check (`{"ok":true}`) |
| `GET /api/v1/status` | Version, uptime, graph size, bounds, cache statistics |
| `GET /api/v1/search?q=…&limit=…` | Address, street and POI search |
| `POST /api/v1/route[?format=gpx\|geojson]` | Route between two locations |
| `POST /api/v1/trip/solve[?format=gpx\|geojson]` | Multi-stop trip, optionally optimised |
| `GET /api/v1/geo/pois` | POIs as GeoJSON (`bbox` or `lat`/`lon`/`radius_m`, `category`, `q`, `limit`) |
| `POST /api/v1/geo/measure` | Great-circle length of a polyline |
| `GET /api/v1/poi/{id}` | Details and tags for a POI |
| `GET /api/v1/territories[/{layer}]` | Loaded territory layers |
| `GET\|POST /api/v1/operations` | Delivery/maintenance log |
| `GET\|PUT /api/v1/settings` | Settings (writing requires `-admin-token` if set) |
| `POST /api/v1/tinytiles/build` | Build the offline map |

### Examples

```bash
# Search
curl 'http://localhost:8080/api/v1/search?q=Rathaus%20Passau&limit=5'

# Route as JSON; "from"/"to" accept {"lat","lon"} or {"query": "address"}
curl -X POST http://localhost:8080/api/v1/route \
  -H 'Content-Type: application/json' \
  -d '{"from":{"query":"Passau Hauptbahnhof"},"to":{"lat":48.5667,"lon":13.4319}}'

# The same route as a GPX file for a sat nav
curl -X POST 'http://localhost:8080/api/v1/route?format=gpx' \
  -H 'Content-Type: application/json' \
  -d '{"from":{"query":"Passau Hauptbahnhof"},"to":{"lat":48.5667,"lon":13.4319}}' \
  -o route.gpx

# Optimised trip as GeoJSON (route + numbered stops)
curl -X POST 'http://localhost:8080/api/v1/trip/solve?format=geojson' \
  -H 'Content-Type: application/json' \
  -d '{"plan":{"start":{"lat":48.574,"lon":13.46},"loop":true,"optimize":true,
       "stops":[{"id":"A","location":{"lat":48.56,"lon":13.43}},
                {"id":"B","location":{"lat":48.58,"lon":13.48}}]}}' \
  -o tour.geojson

# POIs within 5 km, filtered by category (German aliases work too)
curl 'http://localhost:8080/api/v1/geo/pois?lat=48.57&lon=13.46&radius_m=5000&category=Apotheke'
```

GPX responses use `application/gpx+xml`, GeoJSON responses use
`application/geo+json`, and both come with `Content-Disposition: attachment`.
An unknown `format` returns `400`.

## Command-line tools

All tools are subcommands of the same binary (`go run ./cmd <command>` or
`bin/osmmini <command>`). `osmmini <command> -h` shows their flags.

| Command | Purpose |
| --- | --- |
| `route` | Calculate a route directly from the PBF and print it as JSON, GPX or GeoJSON |
| `territories load` / `territory lookup` | Check a territory layer, or find the territory for a coordinate |
| `dispatch assign` / `dispatch manifests` | Assign CSV addresses to territories, or write one manifest per group |
| `geodata import` | Import GeoJSON, KML/KMZ or Shapefile as a layer |
| `pbf-index` / `region-extract` | Tools for [large PBF files](#large-pbf-files) |
| `version` / `help` | Show the version / overview |

```bash
# Route as GPX without a running server
go run ./cmd route -pbf region.osm.pbf -from 48.574,13.460 -to 48.567,13.432 -format gpx > route.gpx

# Which delivery zone is a coordinate in?
go run ./cmd territory lookup -layer delivery -lat 48.65 -lon 12.65 \
  -territories testdata/territory/delivery-zones.geojson

# Assign parcels (CSV with the columns parcel_id, lat, lon) to delivery zones
go run ./cmd dispatch assign -territories testdata/territory/delivery-zones.geojson \
  -input parcels.csv -output assignments.csv
```

The root Go package can also be used as a library for streaming OSM extraction
and routing; see [`example/main.go`](example/main.go).

## Configuration

### Server flags

| Flag | Default | Description |
| --- | --- | --- |
| `-pbf` | `region.osm.pbf` | OSM PBF for the graph, search and POIs |
| `-listen` | `:8080` | HTTP address |
| `-settings` | `settings.json` | Settings file (profile) |
| `-admin-token` | `$OSMMINI_ADMIN_TOKEN` | Bearer token for writing settings, offline-map builds, imports and confidential objects. Without it, settings can be changed without authentication |
| `-deployment-mode` | `single-user` | `browser-local`, `single-user` or `multi-user` |
| `-operators-file` | – | Operator tokens (required for `multi-user`) |
| `-operations-file` | `operations.json` | Delivery/maintenance log |
| `-confidential-objects-file` | `confidential-objects.json` | Confidential editor objects |
| `-tiles-dir` / `-tile-upstream` | `tiles-cache` / – | Cache and upstream for proxied raster tiles |
| `-tinytiles-dir` | `offline-tiles` | Directory for the offline map |
| `-tinytiles-max-memory-mb` | `768` | Memory limit when building the offline map; raise it for large regions |
| `-tinytiles-readers` | `4` | Concurrent readers of the offline map |
| `-tinytiles-reader-memory-mb` | `32` | Page cache per reader |
| `-tinytiles-tile-cache-mb` | `64` | Hot-tile cache (`-1` = off) |
| `-territories-dir` | `territories` | `*.geojson` territory layers (file name = layer name) |
| `-imported-layers-dir` | `imported-layers` | Layers created by GIS imports |
| `-geodata-tiles-dir` | `geodata-tiles` | Imported MBTiles/GeoTIFF map source |
| `-window` | – | Load only the window `minLat,maxLat,minLon,maxLon` from the PBF |
| `-window-buffer-m` | `0` | Buffer around `-window` in metres |
| `-enforce-window` | `false` | Reject requests outside `-window` |
| `-build-ch` | `false` | Deprecated; startup rejects it because the incomplete CH graph cannot return reliable routes |

### Settings file

The settings file holds the routing defaults (`routing`: engine, objective,
turn penalties, vehicle height and weight), the map source (`tiles`), optional
AI endpoints (`ai`) and `default_highway_speeds` (km/h per `highway` type, as
overrides of the built-in values). Most of these values can also be changed in
the UI under **Einstellungen**. `allowed_highway_types` is applied only when the
graph is built and requires a restart.

The local assistant automatically detects [Ollama](https://ollama.com/)
(`localhost:11434`) or LM Studio (`localhost:1234`). You can also configure any
OpenAI-compatible endpoint with `ai.openai_base_url` and `ai.openai_api_key`.

### Make targets

```text
make help                  list all targets
make run                   start the server (PBF, SETTINGS, LISTEN, ADMIN_TOKEN)
make bayern / offline      start the Bavaria / offline profile (ADMIN_TOKEN required)
make build                 build bin/osmmini
make pbf-download          download a Geofabrik PBF (GEOFABRIK_URL, FORCE=1)
make maplibre-assets       download the pinned MapLibre assets and verify them
make offline-prep          pbf-download + maplibre-assets
make check                 Go tests, vet, build, JS syntax and JS tests
```

## Running in production

- **Protection:** set `-admin-token` (or `OSMMINI_ADMIN_TOKEN`). Without it,
  settings can be changed without authentication. `make bayern` and
  `make offline` refuse to start without a token.
- **TLS:** OSMmini serves plain HTTP. Put a reverse proxy (Caddy, nginx) in
  front of it for public access and distribute personal tokens securely.
- **Shutdown:** `SIGINT`/`SIGTERM` (Ctrl+C, `systemctl stop`, `docker stop`)
  shut the server down cleanly. Open requests get up to 10 s to finish, and
  the offline map is closed properly.
- **Tile sources:** `raster-direct` is loaded by the browser directly, while
  `raster` and `wms` go through the local `/tiles` cache. OSM standard tiles are
  deliberately `raster-direct` and are never proxied or cached; see the
  [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/).
  For heavy traffic, use your own or a commercial tile provider.
- **Local data** (`operations.json`, `operators.json`, `fire-stations.json`,
  `confidential-objects.json`, `territories/`, `imported-layers/`, `*.poi.json`)
  is excluded by `.gitignore` and belongs in backups, not in the repository.

Example systemd unit:

```ini
[Unit]
Description=OSMmini
After=network.target

[Service]
WorkingDirectory=/opt/osmmini
ExecStart=/opt/osmmini/bin/osmmini -pbf /opt/osmmini/region.osm.pbf -listen 127.0.0.1:8080
Environment=OSMMINI_ADMIN_TOKEN=change-me
Restart=on-failure
User=osmmini

[Install]
WantedBy=multi-user.target
```

## Native Apple SDK and offline demo

The same Go core can be embedded in iPhone, iPad and macOS applications through
an importable Swift 6 package. The native demo includes Geofabrik region downloads,
local PBF import, persistent offline maps/search/routing, and GPX/GeoJSON export.
Build with `make build-apple`, then open
`apple/Demo/OSMminiDemo.xcodeproj`. See [Apple SDK setup, integration and current
limits](apple/README.md). No SQLite driver is linked by this build.

`CGO_ENABLED=0 go run ./cmd/prepare-region -pbf region.osm.pbf -output regions/local`
prepares the same portable region format on a server or Mac.

### Shared Go core performance

Server and Swift use the same optimized PBF decoder and routing algorithms.
Without transition penalties, A*/Dijkstra keep one search state per node;
configured turn/crossing penalties retain the turn-aware search. Both paths
use value heaps, and short queries start with small search maps. File-backed
graphs read `OSMMGR01`, `OSMMGR02` and the chain-packed `OSMMGR03`; existing offline regions
remain readable.
Profile restrictions, speed scaling and the target latitude cosine are resolved
once per query. Turn-aware searches also reuse the incoming bearing and crossing
cost for all outgoing edges of a search state. These changes apply to both
in-memory and file-backed graphs.

Node-based queries on compact file graphs now retain their existing 32-bit
table indices throughout the search. They avoid repeated binary searches from
OSM IDs to adjacency/coordinate records and use smaller lazy distance and
predecessor maps. Original OSM IDs are restored in the returned path. Legacy
graphs, territory-cost policies and turn-aware queries retain their existing
search paths; profile access, vehicle limits, cancellation and error semantics
are unchanged. No graph rewrite or new region format is needed.

On the same complete Niederbayern graph, three alternating five-query samples
compared commit `387d4b8` with the indexed search on an M2 Max. Median full-route
measurements for Passau Hbf–Landshut Hbf were:

| Query | Before | Indexed | Reduction |
| --- | ---: | ---: | ---: |
| Car, distance objective | 177.5 ms | 107.6 ms | 39.4% |
| Car, duration objective | 272.8 ms | 159.0 ms | 41.7% |
| Allocated bytes, distance route | 38.04 MB | 28.87 MB | 24.1% |

All returned path IDs, distances, durations and costs matched the previous
implementation exactly. Bytes are cumulative allocations per query, not peak
RSS. These warmed desktop samples do not establish iPhone latency. The opt-in
`BenchmarkRealGraphStorageRouting` below reproduces the query workload.

Swift's prepared map labels also retain their normalized deduplication key.
Drawing reuses it instead of trimming/lowercasing each candidate every frame.
The previous label-placement oracle still checks identical accepted labels.
Three alternating 120-frame Release samples reduced CPU placement time for
500 phone candidates from 22.61 to 9.27 ms and for 3,000 tablet candidates from
171.92 to 70.29 ms (about 59%). This excludes Canvas text measurement/drawing
and GPU work. A cached label retains an additional 16-byte String value plus
normalized text storage; unlabelled feature records do not grow. See the
[Swift map benchmarks](apple/README.md) for the command and memory tradeoff.

PBF graph imports count valid outgoing edges first and allocate one exact-sized
edge buffer, with capped slices per node. This reduces small allocations and
unused capacity for both server and mobile imports. Mobile search preparation
spools POI/address ways to disk and sorts at most 16,384 postings at once,
merging at most 16 runs per pass. Its scratch files are removed on completion,
cancellation or retry. Graph/search preparation closes before map generation,
so those phases no longer retain the graph's mapped pages together.

New offline imports use region format 4. Graph edges reference shared attributes
and internal node indices, preserving the original 64-bit OSM IDs, coordinates,
distances and routing behavior. The search index stores prefix-coded terms and
variable-length offsets in independently readable 128-entry blocks. Search
records are losslessly compressed in individually readable 32 KiB blocks. A
complete Niederbayern package decreased from 592.6 MB to 267.6 MB; see the [storage
measurements and upgrade notes](apple/README.md#offline-storage).

The reusable `osmmini.NewAddressIndex(entries)` prepares search fields once
and supports concurrent `Search`/`FindBest` queries. The HTTP server enables
it with `-address-index`. It is opt-in because it retains additional RAM;
input tag maps must remain read-only until the index is discarded.

Allocation comparisons on an M2 Max, using the included synthetic benchmarks:

| Operation | Before | After |
| --- | ---: | ---: |
| A* cost, 40,000-node grid | 14,009,616 B | 2,387,232 B |
| A* cost, adjacent nodes | 54,736 B | 2,416 B |
| Decode 8,000 untagged DenseNodes | 1,439,872 B | 0 B |
| Mobile multiword search, 20,000 POIs | 100,368 allocations | 8 allocations |
| Repeated address search, 50,000 entries | 100,004 allocations | 4 allocations with AddressIndex |
| Decode vector tile, 264 synthetic features | 1,659,310 B / 4,748 allocations | 307,488 B / 540 allocations |
| Decode Monaco vector tile, 3,304 features | 4,814,446 B / 35,742 allocations | 1,114,097 B / 7,312 allocations |
| Import 40,000-node road grid | 80.29 MB allocated | 20.97 MB allocated |

These are allocated bytes/counts **per call**, not process RSS or peak import
memory. AddressIndex construction additionally allocated about 4.91 MB for the
50,000-entry fixture. CPU timings were affected by substantial simulator load;
physical-iPhone and large-region measurements remain separate validation work.

The included `BenchmarkSearchIndexBuildMemory` compares the former retained
posting list with bounded sorting for 500,000 entries. Sampled live heap after
GC falls from 25.78 MB to 0.79 MB; cumulative allocation falls from 107.49 MB to
39.11 MB. Sorting trades additional temporary disk I/O for lower RAM use.
For whole-import RSS measurements, see the [Apple SDK validation notes](apple/README.md#validation-and-current-scope).

The vector decoder reads protobuf fields without intermediate field/value
slices and allocates exact-sized coordinate storage after validation. The Monaco
tile produced byte-identical JSON before and after this change. On a synthetic
10,000-node grid, five-run routing medians improved by 10–32% depending on the
profile and graph storage; allocations and route costs were unchanged. These
microbenchmarks do not measure end-to-end app performance.

```sh
go test -run '^$' -bench 'Benchmark(Route|ShortRoute|DenseNodes|PBFWay|AddressIndex|SearchAddresses|FileGraph)' -benchmem .
go test -run '^$' -bench 'BenchmarkMobile(Search|Normalize)' -benchmem ./mobile
go test -run '^$' -bench '^BenchmarkRouteProfiles$' -benchmem -count=5 .
go test -run '^$' -bench '^BenchmarkDecodeVectorTile$' -benchmem ./mobile
# Optional: benchmark the center tile of a locally prepared region.
OSMMINI_BENCH_REGION=/path/to/region go test -run '^$' -bench '^BenchmarkDecodeVectorTileRegion$' -benchmem ./mobile
```

#### Imported edge cleanup

The 2026-10-18 Niederbayern extract contained **54 bit-identical duplicate
directed edges among 4,307,507 edges**. Imports now retain the first such edge
in source order. A complete reimport produced **4,307,453 edges**, reducing
`graph.bin` from 163,091,235 to 163,090,371 bytes: **864 bytes saved**. This is a
small cleanup, with no claim of a substantial RAM or routing-speed reduction.
The audit found no self-loops; all 74 parallel edges with different routing
attributes remain.

A streaming comparison verified every node coordinate, retained edge attribute
and order, one-way sink, and street metadata entry. Car routes from Passau Hbf
to Landshut Hbf retained identical node-ID paths, distances, durations and costs
for both distance and duration objectives. Explicit junction penalties can
change where duplicate edges previously inflated the outgoing degree; cleanup
corrects that artificial junction classification.

Two-way road segments need edges in both directions. Also, 82.4% of the original
graph's nodes have two outgoing edges, largely retaining road shape points.
The chain representation below now shares their storage while preserving
geometry, directions and routing attributes. Existing published regions remain
readable; reimporting into a new destination applies the current optimizations.

Run the optional audit and original-versus-reimport comparison on existing
files; neither command downloads or imports data:

```sh
OSMMINI_REAL_GRAPH=/path/to/reimport/graph.bin \
  go test -run '^TestRealGraphEdgeRedundancy$' -count=1 -v .
OSMMINI_ORIGINAL_GRAPH=/path/to/original/graph.bin \
  OSMMINI_REAL_GRAPH=/path/to/reimport/graph.bin \
  go test -run '^TestRealGraphDedupEquivalence$' -count=1 -v .
```

#### Lossless road-chain storage

`OSMMGR03` packs bidirectional chains with at least three interior nodes.
Candidates must have exactly two incoming and two outgoing edges, distinct
neighbors, bit-identical road attributes along the chain, and matching reverse
distances. Branches, one-way entries, restrictions, parallel variants and
attribute changes remain ordinary nodes. Rings retain an ordinary anchor.
Short chains keep the previous representation, so packing never grows the file.

Every original node ID and coordinate remains in the node/spatial tables.
Chain nodes refer to a shared vertex sequence; segment distances are stored
once and attributes once per chain. The reader exposes the original directed
edges in their original order, including exact float bits. Snapping to an
interior point, routing/turn penalties, street lookup and exported route
geometry therefore keep their existing behavior. Opening still uses mmap and
does not expand the chains into an in-memory graph.

A complete reimport of the same Niederbayern PBF on 2026-10-20 packed
**1,527,611 interior nodes into 191,097 chains**. Explicit directed edge records
decreased from **4,307,453 to 1,252,231**; the remaining logical edges are
represented by the shared chains, not deleted road connections.

| Storage | Before chains | With chains | Saved |
| --- | ---: | ---: | ---: |
| Adjacency, including chain records/vertices | 68,919,248 B | 46,010,908 B | 33.2% |
| Entire routing graph | 163,090,371 B | 140,182,031 B | 14.0% |
| Entire offline region, zooms 5–14 | 267,635,432 B | 244,727,092 B | 8.6% |

The **22,908,340-byte** saving preserves all 2,096,430 coordinates, 4,307,453
logical edges, 55 incoming-only sinks and 14,956 street entries. A full streaming
comparison checked every ordered edge bit and coordinate. Both station-to-station
car routes retained their exact paths, distance, duration and cost; the search
files retained their checksums and the map artifact its size.

Three five-route benchmark samples on an M2 Max gave distance-route medians
of 172 ms before versus 176 ms after, and duration-route medians of 280 ms versus
271 ms. Query allocations stayed about 38 MB per route. This is a storage
reduction, not a claim of a routing-speed or query-heap improvement.

New packages use region format 4; readers retain formats 1–3. Update the native
framework with the Swift sources. Published regions and file-backed snapshots
are not rewritten; use a new import destination to obtain packed chains.
Older pending import checkpoints remain untouched and require a new destination.
The optional audits above compare both graph representations. Reproduce the
route benchmark with:

```sh
OSMMINI_ORIGINAL_GRAPH=/path/to/before/graph.bin \
  OSMMINI_REAL_GRAPH=/path/to/packed/graph.bin \
  go test -run '^$' -bench '^BenchmarkRealGraphStorageRouting$' -benchtime=5x -count=3 -benchmem .
```

Large JSON and GeoJSON API responses use pooled, best-speed gzip when the
client accepts it. Responses below 1 KiB normally stay uncompressed; only that small
prefix is buffered. Binary tiles, range/HEAD responses, existing encodings,
ETags, declared trailers and `Cache-Control: no-transform` keep their original
representation. Encoding negotiation preserves `Vary` and handler headers.
An explicit preference for identity is respected; when identity is forbidden,
eligible JSON uses gzip even below the threshold. If neither available
representation is acceptable, the API returns an empty 406 response.
The included 2,000-feature GeoJSON fixture goes from 232,773 to 11,614 wire
bytes; compression adds CPU work and this is not a network-latency benchmark.

The raster/WMS proxy combines simultaneous misses for the same source and
z/x/y into one disk read or upstream fetch. Each caller can cancel independently;
the last cancellation stops the shared download. Cache files are published by
atomic rename. Responses with Content-Length allocate one body buffer; both
declared and actual sizes must fit the 8 MiB tile limit. A 24-caller test verifies
one upstream fetch. Warm in-memory hits decreased from 376 B / 11 allocations
to 64 B / 4; a 64-KiB disk read from 74,440 B / 7 to 65,944 B / 5.

The proxy owns a cloned transport with at least 32 idle connections per host,
preserving the configured proxy, TLS, dialer and HTTP/2 settings. `Close` releases
its idle connections. This idle-pool size does not limit active requests.

Remote AI requests use typed payloads and reuse clients with the existing
timeouts and shared transport. Known-length responses avoid `ReadAll`'s growing
buffers; oversized replies are rejected rather than truncated. Small HTTP error
responses are drained to permit connection reuse. AI/Wikipedia error draining
has byte and time limits. In the synthetic 35-KiB AI-response benchmark,
allocations decreased from 87 to 44 for Ollama and 91 to 48 for OpenAI-compatible
requests; this does not include provider processing or real network traffic.

These choices follow Go's [Client/Transport reuse and timeout contracts](https://pkg.go.dev/net/http#Client),
HTTP [encoding negotiation and Vary](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.3),
and [no-transform](https://www.rfc-editor.org/rfc/rfc9111.html#section-5.2.2.6).
AI POSTs keep a single application-level attempt, consistent with
[HTTP's retry rules](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2).
Tests cover failure, cancellation, connection reuse and two concurrent tile
bursts. Modern Go transports can also drain small bodies automatically on close;
the explicit error-body helper sets a controlled byte/time budget and is not
evidence that every older error path opened a new TCP connection.

```sh
go test ./cmd -run '^$' -bench 'Benchmark(TileProxyMemoryHit|TileDiskCacheRead|RemoteAIRequests|JSONResponseCompression)$' -benchmem
```

Offline OSM data is prepared from regional PBF extracts and local tinyTiles,
following the [OSM data-download guidance](https://wiki.openstreetmap.org/wiki/Downloading_data).
Public `tile.openstreetmap.org` tiles remain browser-direct; the proxy rejects
that host regardless of map type, including cached responses. Offline/prefetch
downloads from that service are prohibited by its [Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/).
New region directories include `NOTICE.txt` with map-data attribution and ODbL
links so the notice travels with the database, as described by the
[OSMF attribution guidelines](https://osmfoundation.org/wiki/Attribution_Guidelines).

The current routing importer has these limits; the performance changes do not
add full OSM routing semantics:

| Area | Current coverage and remaining work |
| --- | --- |
| Access and modes | A shared road graph applies coarse `access`, `vehicle`, `motor_vehicle` and `hgv` exclusions at import. Specific foot/bicycle/motorcar overrides, conditional access and many foot/cycle paths require a mode-aware import model. |
| Direction and turns | Explicit one-way values and implicit roundabouts are supported. Mode-specific one-way exceptions and OSM `no_*`/`only_*` restriction relations are not imported; angle penalties do not enforce those relations. |
| Extract boundaries | Missing endpoint references are skipped, and routing stays inside one package. Import diagnostics and cross-package graph links remain work. |

The relevant source semantics are [access precedence](https://wiki.openstreetmap.org/wiki/Computing_access_restrictions),
[oneway](https://wiki.openstreetmap.org/wiki/Key:oneway) and
[turn restrictions](https://wiki.openstreetmap.org/wiki/Restriction_type).
Prepared graphs retain their imported directions. Import into a new destination
to apply changed import rules; old published packages remain readable. Pending
imports carry a separate import revision so old completed phases cannot silently
override a corrected graph-building rule.
`created_at` records import time, not OSM data freshness; `source_sha256` identifies
the input snapshot. Automatic replication/diff updates are not implemented.

## Development

### Project structure

| Path | Contents |
| --- | --- |
| `extract.go`, `pbf_spatial_index.go` | Streaming PBF extraction and sidecar index |
| `router.go`, `types.go` | Routing graph, A*/Dijkstra, address search, maneuvers |
| `territory*.go`, `dispatch.go`, `imported_layers.go` | Territories, point-in-polygon, assignment |
| `cmd/main.go` | Server, HTTP API, settings, search |
| `cmd/route_export.go` | GPX/GeoJSON route export |
| `cmd/tsp.go`, `cmd/route_cache.go` | Trip optimisation, route cache |
| `cmd/tinytiles*.go`, `cmd/offline_labels.go` | Offline map, waterways, labels |
| `cmd/geo*.go`, `cmd/geodata*.go` | POI geo index, GIS imports |
| `cmd/web/` | Embedded UI (`index.html`, `app.js`, `style.css`, editor modules) |
| `cmd/web_test/` | JS regression tests (Node test runner, no dependencies) |
| `cmd/api/openapi.yaml` | API specification |
| `cmd/wasm`, `cmd/export-graph` | Browser routing tools (built separately) |
| `docs/` | Additional documentation |

### Checks

```bash
make check      # go test, go vet, build, node --check, node --test
make test-race  # Go race detector
make test-js    # JS tests only
```

`make check` needs Go and Node.js. The first run downloads the pinned MapLibre
assets (6.7.0) and verifies their checksums. The JS tests use a small DOM and
network harness and download nothing. CI runs `make check` on every pull
request.

### Performance notes and benchmarks

- **Routing:** search state grows with the visited part of the graph.
  `dijkstra-node` skips predecessors and path reconstruction when only the cost
  is needed. Cancelled requests stop before any search state is allocated.
- **Trips:** up to 16 stops use exact dynamic programming over subsets; 17–60
  stops use nearest neighbour followed by 2-opt (a heuristic, with no guarantee
  of the global optimum). Road costs are treated as directed and cached for each
  solve.
- **POI search:** text normalisation is a single pass without allocations for
  text that is already normalised. The POI cache (`cmd/poi_cache.go`, version 3)
  is streamed entity by entity and replaced atomically.
- **Geo index:** a grid with one representative point per POI provides fast
  viewport and radius queries. It covers the poles and the antimeridian, and it
  returns `503` while it is still loading.

```bash
go test . -run '^$' -bench 'BenchmarkShortRouteCost$' -benchmem
go test ./cmd -run '^$' -bench 'BenchmarkTSPExact12$' -benchmem
go test ./cmd -run '^$' -bench '^BenchmarkRouteCacheEviction$' -benchmem
go test ./cmd -run '^$' -bench '^BenchmarkGeoViewport100k$' -benchmem
go test ./cmd -run '^$' -bench 'BenchmarkPOINormalization$|BenchmarkPOISearch5000$' -benchmem
```

## Citation

If you use OSMmini in academic work, please cite it through the Zenodo DOI
[10.5281/zenodo.18929953](https://doi.org/10.5281/zenodo.18929953).
Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, ODbL.
