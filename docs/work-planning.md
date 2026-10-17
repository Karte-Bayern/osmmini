# Work planning and lessons from Fleetbase

Fleetbase combines configurable logistics workflows, resource dispatch and
integration APIs in a modular platform ([repository](https://github.com/fleetbase/fleetbase)).
Its [module structure](https://github.com/fleetbase/fleetbase/blob/main/.gitmodules)
separates Fleet-Ops, commerce, core API and identity management. For osmmini,
the useful lesson is to make geographic capabilities composable across jobs,
vehicles and teams while keeping the regional, offline deployment lightweight.
This implementation is original Go code and introduces no Fleetbase dependency.

## Use cases

| Operation | Resource | Demand unit | Skills | Existing next step |
| --- | --- | --- | --- | --- |
| Parcel or grocery delivery | Van or cargo bike | kg, volume or parcel count | refrigerated, cargo-bike | Trip solver, GPX and delivery proof |
| Maintenance and inspections | Technician or crew | Estimated working minutes | electrician, water, inspection | Trip solver and maintenance log |
| Waste collection | Collection vehicle | Estimated collection volume | recycling, hazardous-waste | Territory layers and route export |
| Municipal field work | Team | Estimated working minutes | hydrant-inspection, surveying | GIS layers and check records |

Use one consistent scalar demand unit per plan. These are planning estimates;
the planner does not validate vehicle dimensions, road restrictions or service
feasibility. Emergency response requires additional operational validation.

## Try a complete example

From the repository root, without loading a PBF:

```sh
go run -tags=sqliteimport ./cmd dispatch plan --input testdata/dispatch/maintenance.json
```

With a running server, the same JSON works over HTTP:

```sh
curl -sS http://localhost:8080/api/v1/dispatch/plan \
  -H 'Content-Type: application/json' \
  --data-binary @testdata/dispatch/maintenance.json
```

The example assigns the urgent electrical repair to `electrical-team` and the
water inspection to `water-team`. The roof inspection remains unassigned
because neither team has the required qualification.

The endpoint is stateless and uses the same public access policy as routing.
It saves no jobs, locations or manifests. Input is limited to 4 MiB, 256 resources
and 5000 jobs. The Go library exposes `PlanWork(ctx, request, constraints...)`
with the same resource/job count limits and request cancellation.

## Assignment contract

- Jobs are considered by descending integer `priority`, then ascending job ID.
- Each job goes to the eligible resource with the smallest great-circle distance
  from its supplied location. Equal costs choose the ascending resource ID.
- All `required_skills` must appear in the resource's `skills`; matching is exact
  and case sensitive. IDs must be nonblank and unique within resources or jobs.
- Nonnegative finite `demand` consumes cumulative `capacity`. Zero capacity
  allows only zero-demand jobs. Optional `max_jobs` limits the number of jobs;
  zero means unlimited. Coordinates must be finite WGS84 latitude/longitude.
- Every resource appears in `manifests`, including unused resources. A manifest
  includes `job_ids`, `load` and `remaining_capacity`. The output also reports
  `algorithm: priority-greedy` and `distance_model: great-circle-from-resource`.
- Every rejected job appears in `unassigned` with `no_eligible_resource` (skills
  or custom/territory rules) or `capacity_exceeded` (demand or job count limit).
- Inputs are not reordered or modified. Input array order does not affect output.

This greedy heuristic does not guarantee the greatest assigned job count or a
globally optimal allocation. It does not enforce time windows, pickup/drop-off
dependencies, multidimensional capacities or travel time budgets. Job IDs in a
manifest are in assignment order, not driving order. Resolve those IDs back to
the input locations and call `/api/v1/trip/solve` for each resource, respecting
its 60-stop limit and its own request contract. Routing stays within the loaded
PBF region.

## Territory rules and extensions

For HTTP, add `"layer": "delivery"` to the request to use a loaded territory
layer. Each resource's `properties.territory_id` must match the destination's
territory ID. `"vehicle_key": "service_area"` selects a different property.
An unknown layer is rejected; an outside destination remains unassigned.

For CLI, supply `--territories zones.geojson --layer delivery`; optionally
`--vehicle-key service_area`. CLI input contains only `resources` and `jobs`.
For Go callers, pass `TerritoryConstraint` or another `AssignmentConstraint`.
All constraints must accept the pairing; their finite nonnegative costs are
added to distance in metres. Constraints should be pure and use properties for
domain-specific rules. Capacity is enforced by the planner itself.

## Further development

The next useful steps are travel-time cost matrices, time windows and
multi-dimensional capacity, followed by a configurable job lifecycle linked to
the existing idempotent operations log. Tracking/geofence events and an outbox
for reliable integrations should build on that lifecycle. These are future
extensions, not capabilities of the current planner. Keep domain-specific UI
modules optional and keep planning APIs usable from external dispatch software.
