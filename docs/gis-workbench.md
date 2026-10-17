# GIS workbench

Open **Werkzeuge → GIS-Werkbank** to prepare vector data directly beside the map.
The workflow is inspired by [Mapshaper](https://mapshaper.org/), which combines
geometry editing, attribute operations and exports in a browser interface
([project documentation](https://github.com/mbloch/mapshaper)). The implementation
in osmmini is original JavaScript with no additional package or network dependency.

## Try the example

1. Load `testdata/workbench/inspection.geojson` with **Lokale GeoJSON-Datei**.
   The three objects contain two inspection sites and one inspection line.
2. Click **Auf Auswahl zoomen** to see the data around Passau.
3. Choose `zone` under **Nach Attribut filtern** and enter `north`. The map and
   table show two matching objects. Filtering uses exact, case-sensitive text
   values. **Alle Objekte** resets the filter.
4. **Nur Auswahl behalten** removes other objects from the working copy.
   **Rückgängig** restores the preceding working copy, up to five operations.
5. Under **CSV verknüpfen**, load `testdata/workbench/inspection.csv`, select
   `code` in both key selectors and click **Alle Objekte verknüpfen**. The
   attributes `csv_team` and `csv_status` appear in the table.
6. Under **Linien vereinfachen**, use a tolerance of 10 metres. The sample line
   loses one redundant coordinate. Point locations stay unchanged.
7. Export the current selection as GeoJSON or its attributes as CSV. Optional
   multi-selection in **Export-Attribute** restricts the exported columns;
   leaving it empty exports all attributes.

## Working copies and privacy

Local files are read and processed entirely in the browser. They are not
uploaded or saved to the server. **Liste aktualisieren** lists existing imported
server layers; **Arbeitskopie laden** reads one into the browser. Both polygon
and point/line imports are available. Edits never replace a server layer.
The workbench overlay survives a basemap style change. It can be hidden with
**Auswahl auf der Karte anzeigen** without discarding the working copy.

The workbench does not persist its session across page reloads. Export before
closing or reloading the page. Existing import functionality under Settings
still converts KML/KMZ and Shapefile ZIPs into server layers; the workbench
itself loads only WGS84 GeoJSON FeatureCollections.

## Attributes and CSV

The table has 25 rows per page and displays the first eight sorted attribute
columns. Every attribute remains available in the filter, edit and export
selectors. Object-number buttons select the target for **Attribut bearbeiten**.
Existing numbers remain numbers and booleans require `true` or `false`.
Nested objects/arrays are displayed as JSON and cannot be edited in the form.
Editing a missing attribute creates a string value. Feature IDs and geometries
are retained by attribute edits and joins.

CSV uses comma delimiters, supports UTF-8 BOMs, quoted commas, double quotes,
CRLF and multiline values. Join keys use exact textual equality without
trimming or numerical coercion: `001` differs from `1`. The CSV key must be
nonblank and unique; repeated GeoJSON keys are allowed and receive the same
CSV record. Joins retain unmatched features and report counts. Additional CSV
columns remain strings and receive a `csv_` prefix. A collision with an existing
attribute aborts the entire operation without changing the working copy.
Joins and simplification operate on the entire working copy, even when a filter
is active. Use **Nur Auswahl behalten** first to restrict their scope.

CSV exports include properties only, without geometry or Feature IDs. They
quote every cell and prefix potential spreadsheet formulas with an apostrophe.
GeoJSON exports preserve the original attribute values, including strings
that happen to start with `=`. Null properties become empty fields in CSV.

## Simplification and limits

LineString and MultiLineString geometries, including those in GeometryCollections,
use iterative Douglas-Peucker simplification. The tolerance is in approximate
metres in a local equirectangular projection. Endpoints and any altitude values
of retained positions are preserved. Closed lines do not collapse to doubled
endpoints. Geometry bounds are removed when simplification makes them stale.

Points and polygons remain unchanged. Shared line geometry and new intersections
are not checked or repaired. This does not offer Mapshaper's topology-aware
polygon simplification, dissolve, clip or projection conversion. Those require
an additional topology engine; independent polygon simplification would risk
gaps between adjacent service zones.

Input and each working copy are limited to 10 MiB, 5000 features and 50000
coordinate positions. CSV has at most 100 columns and 10000 records. Geometry
nesting is limited to ten levels. Simplification accepts 0–1000 metres and
regional lines spanning at most five degrees of latitude/longitude, at
latitudes within ±85°. Dateline crossings are unwrapped before measuring.
A two-million-comparison budget bounds pathological simplification workloads;
an exceeded limit leaves the working copy unchanged. Structural geometry
validation does not check polygon self-intersections or shared boundary topology.

## Lessons for further development

Mapshaper's strongest transferable pattern is to inspect a dataset, transform a
working copy and export a result that can be reused elsewhere. osmmini now
applies that to maintenance inventories, enriched delivery destinations,
municipal field records and smaller line overlays. A future topology engine
could add safe shared-boundary simplification, dissolve and clipping; worker
execution and session snapshots would support larger and longer editing jobs.
