# Bridge System — Debug & Reference

**Status:** Most issues resolved. Remaining: abutment seam (road-polygon edge mismatch).

## Resolved Issues

### 1. Ramp grass gap (RESOLVED)
Grass terrain overlapped the ramp base where the deck descends to ground level.

**Solution (3 parts):**
1. **Ramp base underground** — `_deck_surface_y_at` ramp base Y = `local_elevation - 0.1m`. Deck mesh dips 10cm below terrain at polygon boundary, guaranteeing intersection with road surface.
2. **Asphalt apron patches** — detected from on-deck bridge way endpoints near polygon boundary (`_detect_ramp_junction`). Each junction creates a quad mesh: 6m inward under the ramp + 1m outward, road width + 1m margin each side.
3. **Apron elevation fallback** — apron Y uses `_sample_elevation()` + 5cm. Falls back to `ref_elev` when chunk elevation data isn't loaded yet (race condition with deck building).

### 2. Under-bridge decoration suppression (RESOLVED)
Curbs, footways, lamps, and manholes were rendering under the bridge deck polygon.

**Solution:** `_any_point_on_bridge_deck()` samples up to 5 evenly-spaced points of a polyline. If any point is inside a deck polygon, the feature is skipped:
- Curbs: `_process_curb_queue` — skip non-bridge curbs under deck
- Footways: `_process_footway_incremental` — skip entirely
- Lamps: deferred lamp queue — skip
- Manholes: deferred manhole queue — skip

### 3. Bridge shadows (RESOLVED)
Car and pillar shadows passed through the bridge deck to the ground below.

**Solution:** Changed `cast_shadow` from `SHADOW_CASTING_SETTING_OFF` to `ON` on:
- `BridgeDeck` mesh (line ~6630)
- `BridgeRoad` mesh (line ~5292)

Bridge pillars already use default `cast_shadow = ON`. NPC cars explicitly set `cast_shadow = ON` (npc_car.gd:708).

### 4. NPC waypoint heights on bridge (RESOLVED)
NPC waypoints were at terrain Y instead of bridge deck Y, visible when pressing V.

**Solution:** Added `get_surface_y(x, z)` to `osm_terrain_generator.gd` — returns deck Y via `_deck_surface_y_at()` when point is inside a bridge polygon, otherwise terrain Y. Used by `road_network.gd` for per-waypoint sampling on bridge roads.

### 5. NPC spawn on bridge (RESOLVED)
NPCs spawned under the bridge instead of on it.

**Solution:** Always use raycast for spawn height (hits bridge deck collision on layer 1). Removed separate bridge-height formula. Added `[NPC Spawn]` / `[NPC Despawn]` debug logs with chunk, bridge flag, position, and reason.

### 6. Custom model elevation (RESOLVED)
Bridge pylon (V-shaped cable-stay support) placed at absolute Y instead of terrain-relative Y.

**Solution:** `_place_custom_models_for_chunk` now adds `_sample_elevation()` to `y_offset`:
```gdscript
inst.position = Vector3(pos.x, ground_y + y_offset, pos.y)
```

### 7. `_link` shift gap at abutment (RESOLVED)
2.7m gap between road approach and polygon at south abutment caused by `_link` shift moving road's first vertex away from polygon.

**Solution:** Skip `_link` shift when endpoint touches a bridge polygon — the shift was designed for road-to-road junctions, not road-to-polygon.

### 8. Perp override at bridge endpoints (RESOLVED)
0.11m bare-ground gap / Z-fight at abutment due to road perpendicular (11.3 deg) not matching polygon abutment angle (9.3 deg).

**Solution:** At road's first/last vertex touching a polygon vertex, replace road perpendicular with polygon outline direction. Road's leading edge becomes co-planar with polygon abutment line.

### 9. Lane markings and NPC waypoints under the bridge (RESOLVED)

Lane markings (дорожная разметка) and NPC waypoints on the Oktyabrskiy bridge appeared at terrain ground level — under the deck — instead of on top of it.

**Root cause: ref_elev race condition**

`_deck_surface_y_at_cached()` and `get_surface_y()` both rely on `_deck_polygon_ref_elev[poly_idx]` being populated. This value is computed by `_compute_and_cache_deck_ref_elev()` which requires elevation data for the axis-end chunks of the bridge polygon. That data arrives from the network (OpenTopoData API) — it's not instant.

The bridge deck mesh itself handles this correctly: `_process_terrain_objects_queue` defers `"bridge_deck"` items until `ref_elev != NAN`. But three other consumers didn't wait:

1. **On-deck lane markings** — created inline during road processing (`_create_on_deck_lane_markings` at line ~5126). Called before elevation arrived → `_deck_surface_y_at_cached` returned terrain Y.
2. **On-deck footways** — same path (`_create_on_deck_footway`).
3. **NPC traffic waypoints** — `_deferred_traffic_queue` drained in `_process_deferred_nodes`. For bridge roads, `get_surface_y` fell through to `_sample_elevation` while ref_elev was still NAN.

**Why it was masked before**: cache version bump (v5→v7) invalidated all elevation caches. With a warm cache, elevation arrives from disk instantly and ref_elev is ready before any of the above run. With a cold cache, there's a multi-second network window where ref_elev is NAN.

**Fix (3 parts):**

1. **Lane markings** — instead of calling `_create_on_deck_lane_markings` directly, push item into `_terrain_objects_queue` as type `"on_deck_lane_markings"`. Queue processor finds the containing polygon via `Geometry2D.is_point_in_polygon` and defers until `_compute_and_cache_deck_ref_elev` returns a non-NAN value.

2. **On-deck footways** — same: queued as `"on_deck_footway"`, processed only when ref_elev available.

3. **NPC waypoints** — in the traffic queue drain loop, bridge roads whose midpoint is inside a deck polygon are re-pushed to the front of `_deferred_traffic_queue` if ref_elev is still NAN. They retry next frame.

All three now share the same invariant as the deck mesh: **build only after ref_elev is available**.

## Remaining Issue

### Abutment lateral width mismatch
Polygon at vertex 17 is 12.28m wide (sidewalks + railings), road approach is 7m wide. The 2.5-3m wedges on each side are covered by polygon mesh (asphalt texture) but create a visible "narrowing" from deck width to road width. West sidewalk is missing in OSM data.

This is a data issue — bridge deck IS wider than carriageway. Would need sidewalk way rendering at deck Y to fill the lateral wedge with proper sidewalk surface.

## Flyover Test for Bridge Ramp Debugging

### Running the test

```bash
# Октябрьский мост — start south of south abutment
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --test-lat=59.1195566 --test-lon=37.9037360 --no-chess --with-all
```

**Full bridge ramp inspection** — fly from north abutment to south abutment:

```bash
# North->South: all ramps visible
/Applications/Godot.app/Contents/MacOS/Godot --path . tests/elevation_flyover_test.tscn \
  -- --path=59.1190,37.9025:59.1080,37.9055 \
  --no-chess --with-all --cam-height=40
```

What to check at each ramp:
1. **North ramps** (~59.1181): ways 82697420 + 78314252 meet ground roads 39643699 + 39643698
2. **NE lateral exit** (~59.1171, 37.9010): way 78314250 arm tip
3. **South lateral exit** (~59.1172, 37.9035): way 43844912 meets 43844947 (cutting=yes)
4. **South ramps** (~59.1089): ways 82697419 + 116079419 meet ground roads 39644855 + 45481836

Look for: grass gap at ramp base, Z-fight, deck mesh covering road approach.

### Drive test — spawn at north ramps

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --autostart 0
```
Location select: "Октябрьский мост" -> spawns at 59.118453, 37.902972 (north ramp area).

### Key flags

- `--no-chess` — load ALL chunks (chess pattern skips every other)
- `--with-all` — enable buildings, lamps, curbs, vegetation
- `--cam-height=N` — camera height above terrain (default 38)
- `--path=deck` — fly the deck polygon perimeter
- `--reverse` — fly path in reverse
- `--path=lat1,lon1:lat2,lon2:...` — fly custom waypoints

### Filtering diagnostic output

```bash
# Ramp apron creation
... 2>&1 | grep -E "RampApron|RampJunction"

# Lateral exit detection
... 2>&1 | grep "LateralExit"

# Standalone bridge road vertex dump
... 2>&1 | grep "BridgeRoad"

# All bridge diagnostics + errors
... 2>&1 | grep -E "LateralExit|BridgeRoad|RampApron|SCRIPT ERROR"
```

### Key diagnostic print tags

| Tag | Source function | What it shows |
|-----|----------------|---------------|
| `[LateralExitScan]` | `_detect_deck_lateral_exits` | Every `_link` bridge way evaluated |
| `[LateralExit]` | `_detect_deck_lateral_exits` | Registered exit: way_id, position, base_elev |
| `[BridgeRoadDump]` | `_create_bridge_road` | Road summary: ref_elev, deck_top, shared endpoints |
| `[BridgeRoadVert]` | `_create_bridge_road` | Per-vertex 3D coords (left/right) |
| `[RampJunction]` | `_register_ramp_junction` | Detected ramp junction at polygon boundary |
| `[RampApron]` | `_create_single_ramp_apron` | Apron mesh created with Y range |
| `[BridgeDispatch]` | road processing | Way dispatch: on_deck vs standalone |
| `[NPC Spawn]` | `traffic_manager.gd` | NPC spawn with bridge flag and position |

### Key ways at Октябрьский мост

| Way ID | Type | Role |
|--------|------|------|
| 78314250 | secondary, bridge=yes | Main carriageway (on_deck) |
| 43844912 | secondary_link, bridge=yes | South exit ramp (on_deck, lateral exit) |
| 43844947 | secondary, cutting=yes | South approach road (ground level) |
| 82697420 | primary, bridge=yes | North carriageway (on_deck) |
| 78314252 | primary, bridge=yes | North carriageway (on_deck) |

### In-game debug overlay (F9)

Press F9 to toggle bridge ramp debug overlay (`bridge_ramp_detector.gd`). Shows ramp zones, shared/free endpoints, and detected ramp corridors as colored markers.

### NPC waypoint overlay (V)

Press V to toggle NPC waypoint visualization. Waypoints on bridges should be at deck height, not terrain height.
