# Chevrolet Captiva Premier XL 2024 — QUARANTINE report

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` (§8). Quarantine = valid pipeline outcome.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2024_chevrolet_captiva_premier_xl.glb` (49 MB) |
| car_id | `chevrolet_captiva_premier_xl_2024` |
| vertex count | **694,230** (~694 k) |
| mesh parts | 416 |
| measured AABB | raw 0.047 × 0.021 × 0.018 (length axis z; ~1/100 scale family) |
| wheels detected | 106 "wheel"-named parts — but these include the full interior + every door panel fragment (`Ext_wheel_RV8_*`, plus `ext_door_*`, `int_*` mis-grouped), not a clean 4-wheel set |
| body materials | `CarPaint_Mat` present, but buried among 100+ door/interior/leather/stitch materials |
| front / rear lights | 15 / 13 detected |

## Blocking issues
1. **694 k vertices** → over the 500 k "no NPC use unless explicitly approved" ceiling and ~4.6×
   the 150 k common-NPC ceiling.
2. **416 fragmented parts** — full modelled interior (seats, leather, stitching, speakers, door
   cards) + per-door carpaint. The wheel-name filter catches 106 parts, so `CarWheelRig` cannot
   cleanly isolate the four wheels (interior/door fragments would contaminate the quadrant split,
   like the Volga stray emblem but ×100 worse).
3. Heavy material soup (CarPaint split across 8 door meshes + dozens of interior materials) makes a
   single clean body recolour fragile.

## Possible use
- **Player-only:** possible **after decimation**, but 694 k + 416 parts is very heavy for one car
   and the wheel isolation needs manual work first.
- **NPC:** **not as-is** — grossly over budget; would not survive multiple instances.

## Recommended fix
- **Decimate to < 100 k** and strip / merge the interior (it is never seen on a traffic car).
- **Wheel isolation:** delete non-wheel meshes caught by the wheel filter (door/interior carpaint),
  or rename the 4 true wheels so the rig groups only them.
- **Material consolidation:** merge the per-door `CarPaint_Mat` instances into one body-paint
  surface for clean recolour.
- Re-export, then run the standard pipeline (15 front / 13 rear light parts give good lamp anchors).

## Final status: **QUARANTINED** — decimate + strip interior + isolate wheels + consolidate paint, then re-integrate.
