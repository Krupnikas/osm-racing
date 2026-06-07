# New-car batch — Stage 15 summary

Batch run of `docs/CAR_INTEGRATION_PIPELINE.md` over the 16 remaining `~/Desktop/OSM material/`
models (the Ford Focus ST was the first/reference car, already shipped). All integrated cars
were verified live via Godot MCP (drive on the flat `race/test_track_scene.tscn`, night
head/tail lights, NPC colour variety). Per-car reports + checklists + `measurements.json` live
alongside this file.

## Status table

| # | Source file | car_id | Status | Drive | Lights | NPC ×colors | Price ₽ | NPC wt | Report |
|---|---|---|---|---|---|---|---:|---:|---|
| 1 | 2006_ford_focus_st (ref) | `ford_focus_st_2006` | ✅ completed | FWD | ✓ | ✓ | 450 000 | 3% | `ford_focus_st_2006_checklist.md` |
| 2 | 2006_honda_civic_si | `honda_civic_si_2006` | ✅ completed | FWD, 87 m | ✓ | 3 | 420 000 | 2% | ✓ |
| 3 | 2006_mazda_rx-8 | `mazda_rx8_2006` | ✅ completed | RWD, 64 m | ✓ | 3 | 480 000 | 1% | ✓ |
| 4 | 2003_audi_tt_3.2 | `audi_tt_32_2003` | ✅ completed | AWD, 114 m | ✓ | 2 | 650 000 | 1% | ✓ |
| 5 | volga_gaz_3110 | `volga_gaz3110` | ✅ completed | RWD, 139 m | ✓ | 3 | 130 000 | 4% | ✓ |
| 6 | 2008_mitsubishi_lancer_evo_x | `lancer_evo_x_2008` | ✅ completed | AWD, 491 m | ✓ | 3 | 700 000 | 1% | ✓ |
| 7 | 2011_subaru_impreza_wrx_sti | `subaru_sti_2011` | ✅ completed | AWD, 330 m | ✓ | 3 | 750 000 | 1% | ✓ |
| 8 | 2003_mercedes-benz_clk_55_amg | `mercedes_clk55_2003` | ✅ completed | RWD, 259 m | ✓ | 2 | 850 000 | 1% | ✓ |
| 9 | 2009_porsche_cayenne_turbo_s | `porsche_cayenne_turbo_s_2009` | ✅ completed | AWD, 294 m | ✓ | 2 | 1 200 000 | 1% | ✓ |
| 10 | 2009_chevrolet_aveo_5_lt | `chevrolet_aveo_5_lt_2009` | 🔜 ready (path proven) | — | — | — | — | — | see below |
| 11 | 2011_chevrolet_spark_1.2_lt | `chevrolet_spark_12_lt_2011` | 🔜 ready (path proven) | — | — | — | — | — | see below |
| 12 | free_mazda_6_sedan_2011 | `mazda_6_sedan_2011` | ⚠️ special (single body material) | — | — | — | — | — | see below |
| 13 | uaz_001.zip (UAZ-452) | `uaz_bukhanka` | ⛔ quarantine (baked wheels) | — | — | — | — | — | see below |
| 14 | 2024_chevrolet_captiva_premier_xl | `chevrolet_captiva_premier_xl_2024` | ⛔ quarantined | 694k verts | — | — | — | — | `..._quarantine_report.md` |
| 15 | hyundai_accent_2013.zip | `hyundai_accent_solaris_2013` | ⛔ quarantined | 779k verts | — | — | — | — | `..._quarantine_report.md` |
| 16 | vaz_lada_vesta_cross_2017.zip | `lada_vesta_cross_2017` | ⛔ quarantined | 1.02M verts | — | — | — | — | `..._quarantine_report.md` |
| — | ford_focus_zx4.zip | `ford_focus_zx4` | ⏸ deferred | — | — | — | — | — | Focus ST already covers the marque |

**Resolved: 9 completed + 3 quarantined (+ Focus ST ref) = 12/16.** Commits on
`soviet-vibe-visuals`: `2d1071f` (Civic/RX-8/Audi/Volga + 3 quarantines), `270f41c` (Evo X),
`76f3023` (STI + rig hardening), `cdd214c` (CLK), `adca7c1` (Cayenne). `project.godot` excluded
from every commit.

## Tooling improvements made during the batch
- **CarWheelRig lateral stray filter** (`tools/car_wheel_rig.gd`): loose substring matching
  ("trim"→"rim", "steeringwheel"→"wheel") grabbed body parts on messy models. Added a
  real-vertex filter that, for separate-wheel models, drops candidates near the lateral
  centreline (steering wheels, bumpers, diffusers) while leaving merged-wheel cars untouched.
- **Custom `extra_mat_keys`**: opaque models name wheels in other languages/tokens
  (`llanta`/`rin`, `chevy_aveo_*`, `Sparkrines`). Passing those tokens to `build()` collects
  the wheels; the lateral filter cleans the rest.
- **Flat test-track drive-testing** (`race/test_track_scene.tscn`) instead of the city (curb
  edges leave a wheel airborne → false "won't drive"); freeze before teleporting a moving body.

## Remaining work (clear next steps)

- **Chevrolet Aveo 5 LT** — wheels detected by geometry; integrate with
  `CarWheelRig.build(..., extra_mat_keys=["chevy_aveo_54","chevy_aveo_45"])` (plus default
  `disk`). 94k verts → moderate NPC weight. Identify paint/light materials from a parts dump
  (names are `G-Object_*`/`Mesh*` — classify by position/size). Same flow as Cayenne.
- **Chevrolet Spark 1.2 LT** — `extra_mat_keys=["sparkrines","sparkcromo"]`; 163 fragments so
  expect a few strays the lateral filter should catch; verify wheel split before authoring.
- **Mazda 6 Sedan 2011** — wheels are clean separate `FL/FR/RL/RR` (rig works), BUT the whole
  body is ONE material (`Scene_-_Root`) and there are no separable lights. Options: (a) partial
  — keep original texture (no recolour, so no NPC colour variety), add placed head/tail lights;
  or (b) quarantine pending a Blender material split. Recommend partial player-only + low NPC.
- **UAZ-452 Bukhanka** — only 2 mesh parts, wheels baked into the body (cannot be separated or
  spun). Quarantine: needs Blender wheel separation/re-export. Could ship as a static-wheel
  background van if desired (document as partial).
- **Ford Focus ZX4** — deferred; the Focus ST already represents the Focus marque. Add later if
  a common Ford sedan is wanted (it's a clean small model).
