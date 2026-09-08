# OSMmini

[![DOI](https://zenodo.org/badge/1116409323.svg)](https://doi.org/10.5281/zenodo.18929953)

Lightweight, open source offline routing server and web UI using OSM PBF
extracts, designed for regional and offline use.

![](https://simonwaldherr.de/gh-pages/osmmini.png)

Features

- Build a routing graph from an OSM PBF and serve offline routes via HTTP API
- Multiple routing engines: `astar`, `dijkstra`, `dijkstra-node` (node-only Dijkstra)
- Map-first web UI (MapLibre GL) in `cmd/web` with floating place search, nearby categories, and separate discovery, routing and tools views
- Search results can be opened on the map or used directly as an exact route destination; responsive bottom panel on mobile
- Trip solver, settings and turn-by-turn maneuvers
- Global raster map profile plus official BayernAtlas vector and WMTS presets
- Local tinyTiles vector profile for an optional fully offline basemap
- Tile proxy with a source-namespaced local cache for proxied sources

Requirements

- Go 1.26.5+
- An OSM PBF extract (e.g. `region.osm.pbf`)

Quick start

1. Build or run the server (example):

```bash
go run ./cmd -pbf region.osm.pbf
```

2. Open the web UI: http://localhost:8080/

The included [`settings.json`](settings.json) is the global profile. It loads
the standard OpenStreetMap raster map directly in the browser, so it works
inside and outside Bavaria without routing public OSM tiles through this
server. The map is global; routing, address search and local POIs are limited
to the PBF extract you loaded.

## Bavaria profile

For a Bavaria-focused deployment, use the included
[`settings.bayern.json`](settings.bayern.json). It uses the official Bayern
vector map and automatically falls back to official Bayern WMTS when WebGL or
MapLibre is unavailable:

```bash
OSMMINI_ADMIN_TOKEN='choose-a-secret' go run ./cmd \
  -pbf bayern.osm.pbf \
  -settings settings.bayern.json
```

This visual basemap is regional. Keep the global profile or select another
global preset when users should browse outside Bavaria.

The default map uses the local tinyTiles style; generate its tiles with
**Offline-Karte erzeugen** after loading a PBF. Online sources remain available
in settings. The offline style distinguishes road classes and paths, while
local labels are spread across the viewport and hidden when they overlap.

Under **Einstellungen → Offline-Karte → Kartenstil anpassen**, choose Natur,
Atlas, Nacht, or Hoher Kontrast, or customize colors, road width, label size,
and the visibility of buildings, paths, and labels. Changes preview immediately
on the local map; **Stil speichern** keeps them in this browser's local storage.
Online sources are unaffected and no tile rebuild is needed.

## Fully offline tinyTiles profile

[`settings.tinytiles.json`](settings.tinytiles.json) activates osmmini's
integrated tinyTiles endpoint. The built-in tinyTiles generator creates local
vector tiles for roads, buildings, water, forest and agricultural land;
osmmini serves both the tiles and matching local MapLibre style.

For a truly offline browser renderer, prepare a PBF extract and vendor
MapLibre locally once while online (see "Frontend / assets" below, or just
run `make offline-prep`), then use the **Offline-Karte erzeugen** action in
the web UI to build the `.ttiles` artifact from the PBF loaded by osmmini.

### Spatial PBF sidecar index

For large source files, create a disk-backed spatial block index once:

```bash
go run ./cmd pbf-index -pbf europe.osm.pbf
```

This streams the PBF one block at a time and atomically writes
`europe.idx`. It records the byte range and node
extent of each OSMData block, plus the source file's size, timestamp and
SHA-256. Tools can use it to select the node-bearing blocks for a geographic
window without another whole-file scan. The index is invalidated when the PBF
changes and is intentionally disk-backed: it never loads the source PBF into
RAM. Use `-output /path/to/index.json` to store the sidecar elsewhere.

OSM PBF is not normally a fully spatially indexed container: ways refer to
nodes that may live in other blocks. The sidecar is therefore the first stage
of a regional streaming builder; it is safe for node-window discovery, while
correctly extracting all intersecting ways still needs the follow-up
disk-backed way/reference stage.

### Large PBF: regional import for routing, search, and offline maps

Use a large source PBF as the archive and create a complete regional PBF for
the area currently needed. This keeps the server's routing graph, address
search, POI index and tinyTiles input bounded to that region, while the large
source remains available for further on-demand regions:

```bash
go run ./cmd region-extract \
  -pbf germany-latest.osm.pbf \
  -bbox 11.7,47.8,14.3,49.3 \
  -output regions/niederbayern.osm.pbf

go run ./cmd -pbf regions/niederbayern.osm.pbf -settings settings.tinytiles.json
```

`region-extract` builds or reuses `germany-latest.idx` by default, then calls
the separately installed [`osmium`](https://osmcode.org/osmium-tool/) streaming
extractor with its `complete_ways` strategy. That preserves ways crossing PBF
block boundaries, so every existing osmmini feature works against the regional
PBF. Use `-index=false` to skip sidecar creation, or create another regional
PBF later for a different area. A matching existing regional PBF is reused
instantly; use `-reuse=false` to force replacement. `osmium` is an external
command-line tool and must be installed on the machine that performs
extraction.
After preparation, the map UI needs no network connection at all — no CDN,
no font/glyph service:

```bash
# One-shot: download a Geofabrik PBF extract and vendor MapLibre locally,
# both while online, so the running server needs no further network access:
make offline-prep GEOFABRIK_URL='https://download.geofabrik.de/europe/germany/bayern-latest.osm.pbf'

OSMMINI_ADMIN_TOKEN='choose-a-secret' go run ./cmd \
  -pbf region.osm.pbf \
  -settings settings.tinytiles.json \
  -listen :8080
```

Enter the same value once in **Einstellungen → Administrationsschutz**, then
start **Offline-Karte erzeugen**. The resulting artifact is kept in
`offline-tiles/basemap.ttiles` and is restored automatically after a restart.

The source is also available as **tinyTiles lokal (offline)** in the
map-source selector. Alongside the compact tile artifact, osmmini generates a
local, viewport-bounded vector sidecar for open OSM waterways: rivers and
canals appear from zoom level 7, streams from 11, and drainage details from
13. This avoids a full regional GeoJSON download in the browser while filling
the main gap of the minimal renderer. Complex multipolygon areas still require
a richer tileset generator.

Existing offline artifacts are upgraded in the background on the next server
start when their source PBF is unchanged; otherwise, start **Offline-Karte
erzeugen** once to create a matching pair. The companion layer is specific to
the osmmini map UI and deliberately remains separate from the upstream
tinyTiles/TileJSON artifact.

When the offline build includes PLZ boundaries, tinyTiles also exposes a
local, cacheable postcode API: `GET /tinytiles/postcode/search?q=940`, `GET
/tinytiles/postcode/94032`, and `GET /tinytiles/postcode/at?lon=13.46&lat=48.57`.
It reads the generated sidecar only and never loads the PBF again.

## Make targets

```bash
make help
make run PBF=region.osm.pbf
make bayern BAYERN_PBF=bayern.osm.pbf ADMIN_TOKEN='choose-a-secret'
make offline PBF=region.osm.pbf ADMIN_TOKEN='choose-a-secret'
make maplibre-assets
make pbf-download GEOFABRIK_URL='https://download.geofabrik.de/europe/germany/bayern-latest.osm.pbf'
make offline-prep
make check
```

By default the server runs with settings updates open (no token needed) so it
works out of the box. `make bayern` and `make offline` deliberately still
require an admin token as a safety net for these more public-facing profiles;
set `-admin-token` (or `OSMMINI_ADMIN_TOKEN`) yourself whenever a deployment
should require a token before accepting settings writes.

### Zustellnachweis und Wartungsprotokoll

**Zustellung & Wartung** führt einen lokalen, mobil nutzbaren Audit-Log. Für
einen Zustellnachweis werden Barcode/QR-Code oder eine Objekt-ID, empfangende
Person, Referenz, Zeit und optional die aktuelle Position erfasst. Für
Wartungen werden Arbeitstyp, Status und durchführende Person ergänzt. Der
Modus **Lage & Check** hält außerdem Verfügbarkeit, Schäden oder Sperrungen
von Ressourcen und Einsatzabschnitten fest. Der Kamera-Scan verwendet die
eingebaute `BarcodeDetector`-Schnittstelle des Browsers; falls sie nicht
verfügbar ist, funktioniert die manuelle Eingabe vollständig weiter.

Die Einträge werden atomar in `operations.json` gespeichert, sind über die
Historie filterbar und als CSV exportierbar. Bei temporärer fehlender
Verbindung merkt der Browser fertige Einträge lokal vor und überträgt sie beim
nächsten Kontakt. Sobald `-admin-token` gesetzt ist, schützt derselbe Token
auch Lesen und Schreiben des Protokolls.

### Betriebsarten

`-deployment-mode` trennt die Datenhaltung klar nach Einsatzumgebung:

- `browser-local`: Zustell-, Wartungs- und Lageprotokolle bleiben im
  `localStorage` des Browsers. Das eignet sich für einen einzelnen, offline
  arbeitenden Laptop oder ein Mobilgerät; CSV exportiert die Daten.
- `single-user` (Standard): Die lokale Serverdatei `operations.json` ist die
  dauerhafte Historie. Ein gesetzter `-admin-token` schützt sie.
- `multi-user`: Eine zentrale Historie für ein Team. Jede Protokollanfrage
  benötigt einen eigenen Bearbeiter-Token; der Server leitet den Bearbeitenden
  aus dem Token ab und speichert ihn im Audit-Eintrag. Startbeispiel:

```bash
cp operators.example.json operators.json
# Tokens durch lange, zufällige Werte ersetzen und die Datei schützen.
go run ./cmd -deployment-mode multi-user -operators-file operators.json
```

`operators.json` wird nicht versioniert. Für externe Bereitstellung gehören
TLS, ein Reverse Proxy und eine sichere Verteilung der persönlichen Tokens
vor den Server.

Flags

- `-pbf`: Path to OSM PBF (default `region.osm.pbf`)
- `-listen`: HTTP listen address (default `:8080`)
- `-tiles-dir`: Tile cache directory
- `-tile-upstream`: Upstream tile URL template
- `-tinytiles-dir`: Directory for the generated local `.ttiles` artifact
- `-tinytiles-max-memory-mb`: Maximum memory (MB) tinyTiles may use while building a `.ttiles` artifact (default `768`); raise this for larger PBF regions
- `-tinytiles-readers`: Concurrent readers for a served offline map (default `4`)
- `-tinytiles-reader-memory-mb`: tinySQL page-cache memory per reader while serving (default `32`); the aggregate reader budget is this value times `-tinytiles-readers`
- `-tinytiles-tile-cache-mb`: Hot immutable tile cache in tinyTiles 2.4 (default `64`; use `-1` to disable it)
- `-operations-file`: Local JSON file for delivery proofs and maintenance records (default `operations.json`)
- `-deployment-mode`: `browser-local`, `single-user` (default) or `multi-user`
- `-operators-file`: JSON map of operator name to token; required in `multi-user` mode
- `pbf-index -pbf FILE`: Stream `FILE` into a reusable spatial block sidecar; use `-output PATH` to override the sidecar path
- `region-extract -pbf FILE -bbox minLon,minLat,maxLon,maxLat -output REGION.osm.pbf`: Create a complete, streaming regional PBF for routing, search, and tinyTiles; uses `osmium`
- `-build-ch`: Build experimental Contraction Hierarchies after graph load (default false)
- `-admin-token`: Optional bearer token (or `OSMMINI_ADMIN_TOKEN`); when set, it is required for settings updates. When unset, settings updates are unauthenticated.

## Project structure and development checks

- The root Go package provides streaming OSM extraction (`extract.go`), the
  routing graph, address search and maneuvers (`router.go`), and territory and
  dispatch calculations (`territory*.go`, `dispatch.go`).
- `cmd/main.go` assembles the server, HTTP API, settings, search and trip solver.
  Feature-specific handlers live beside it; `cmd/route_cache.go` contains the
  bounded route-response cache and its expiry lifecycle.
- `cmd/tinytiles*.go`, `cmd/offline_labels.go` and `cmd/pbf_index.go` provide
  offline map generation, viewport overlays and PBF sidecar integration.
- `cmd/web/index.html`, `app.js` and `style.css` form the embedded browser UI.
  MapLibre assets are vendored separately. Search and route requests cancel
  superseded work and discard late responses, including after a reset.
- `cmd/api/openapi.yaml` documents the API; `cmd/docs` serves its viewer.
  `cmd/wasm` and `cmd/export-graph` provide the separate browser-routing tools.

Run `make check` for Go tests, static analysis, a server build, JavaScript
syntax validation and browser interaction regression tests. This requires Go
and Node.js; the JavaScript tests use Node's built-in test runner with a small
DOM/network harness, without downloading dependencies or map tiles. They
cover request ordering, cancellation, repeated searches and waypoint reset.
Run `make test-race` to check concurrent Go access, or `make test-js` to run
only the browser regression tests.

For a reproducible cache-capacity benchmark:

```bash
go test ./cmd -run '^$' -bench '^BenchmarkRouteCacheEviction$' -benchmem
```

This measures inserting into a full 4,096-entry route cache, excluding fixture
setup. It measures cache maintenance rather than pathfinding or PBF import.

## GIS tools

Open **GIS & Geo-Werkzeuge** in the sidebar to search POIs in the viewport or
within 1–50 km of the map centre, filter by name/category, and download the
shown results as GeoJSON. The UI shows at most 320 points and reports when the
result is truncated. API callers can request up to 1,000 points:

```text
GET /api/v1/geo/pois?bbox=12.0,48.0,12.5,48.5&category=cafe
GET /api/v1/geo/pois?lat=48.7&lon=12.7&radius_m=5000&limit=100
POST /api/v1/geo/measure
{"coordinates":[[12.7,48.7],[12.71,48.71]]}
```

GeoJSON uses `[longitude, latitude]`. OSM nodes and mean way coordinates are
exported as Points; polygon geometries and relations are not part of this
endpoint. Radius results are sorted by spherical distance and support poles
and antimeridian crossings. The spatial index is published with the POI index;
the endpoint returns 503 while that index is still loading.

**Strecke messen** lets you click a polyline independently of route stops,
remove its last point, or clear the measurement. Lengths are sums of
spherical great-circle distances, not driving distances or survey-grade
ellipsoidal measurements. Measurement layers survive map-source switches.

The spatial grid shares existing tag maps and retains one representative point
per POI. It adds index memory in exchange for fast viewport/radius queries;
text search also reuses the precomputed way coordinates. Benchmark:

```bash
go test ./cmd -run '^$' -bench '^BenchmarkGeoViewport100k$' -benchmem
```

## POI search and cache memory

POI text normalization uses a single pass and avoids allocations for text that
is already normalized. Search evaluates text scores before resolving way
centroids and skips candidates that cannot enter the bounded result list.
It does not retain an additional copy of normalized text for every POI.

`cmd/poi_cache.go` reads and writes the existing version-3 JSON cache one entity
at a time. Startup installs the decoded maps directly, avoiding a full-file
JSON buffer and duplicate map tables. Saves use a temporary file and atomic
replacement; a failed encoding leaves the previous cache intact.

```bash
go test ./cmd -run '^$' -bench 'BenchmarkPOINormalization$|BenchmarkPOISearch5000$' -benchmem
```

## Routing and trip optimization

Routing cost queries use bounded initial map reservations that grow with the
visited graph. Node-only Dijkstra skips predecessor storage and path
reconstruction when only a cost is requested. Directed dead ends remain valid
route destinations, and cancelled requests stop before allocating search state.

`cmd/tsp.go` contains the trip optimizers: up to 16 stops use exact subset
Dynamic Programming; 17–60 stops use nearest-neighbor construction followed by
2-opt. Dependencies are checked for cycles before routing. Each solve shares a
directed node-pair cost cache, including between the greedy and 2-opt phases.
The 2-opt search evaluates reversed interior edges as well as endpoints, so it
does not assume symmetric road costs. The larger-tour solver remains a
heuristic and does not guarantee the global optimum.

Additional benchmarks (synthetic graphs, no PBF or map downloads required):

```bash
go test . -run '^$' -bench 'BenchmarkShortRouteCost$' -benchmem
go test ./cmd -run '^$' -bench 'BenchmarkTSPExact12$' -benchmem
```

## Tile sources and production use

`raster-direct` sources are fetched directly by the browser; `raster` and
`wms` sources use the local `/tiles` cache proxy. The OpenStreetMap standard
tiles are intentionally configured as `raster-direct`, because their public
service must not be used as a general server-side tile proxy or offline tile
cache. For a public high-traffic service, configure a suitable commercial or
self-hosted global provider and follow its terms. See the
[OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

Frontend / assets

- The UI lives in `cmd/web`; own JS/CSS is committed, the third-party MapLibre
  GL library is not.
- MapLibre GL is the only map engine (Leaflet was removed). It is **not**
  loaded from a CDN — the browser always loads it from
  `cmd/web/static/maplibre`, which is not committed to the repository. Run
  `make maplibre-assets` once (while online) to vendor a local,
  checksum-verified copy before the first run; without it the map fails to
  load rather than silently falling back to a CDN.
- `make offline-prep` runs `make pbf-download` and `make maplibre-assets`
  together as a one-shot "get everything needed for a fully offline
  deployment" step.

MapLibre GL JS is pinned to **6.7.0**. `make maplibre-assets` downloads and
checksums the local ES module, shared module, worker, and stylesheet. WebGL2
and a modern browser are required; no CDN is used at runtime.
