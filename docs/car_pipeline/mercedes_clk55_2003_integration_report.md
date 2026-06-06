# Mercedes-Benz CLK 55 AMG 2003 — integration report

Eighth car (`docs/CAR_INTEGRATION_PIPELINE.md`). **Tier C** — 127-part model with
LOD-duplicate wheels + steering wheel + calipers; **RWD** luxury coupe. The hardened
CarWheelRig lateral filter handled the wheel strays automatically.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2003_mercedes-benz_clk_55_amg.glb` |
| imported model | `res://car/models/mercedes_clk55/mercedes_clk55.glb` (uid `bnqaf7gfy6qoj`) |
| car_id | `mercedes_clk55_2003` |
| display name | Mercedes CLK 55 AMG |
| target length | 4.65 m |
| original real-vertex AABB | L 4.65 × W 1.89 × H 1.42 (axis z); **138,375 verts** (risky band — kept rare NPC) |
| scale factor | ×100.3224 |
| native forward | +Z (front `Glass_light_1` at +Z; rear `Light_glass` at −Z) |
| player orientation | rotated 180° → front −Z; diag(−100.3224, +100.3224, −100.3224), y=0.14 |
| NPC orientation | no rotation → front +Z; scale 100.3224, y=0.12 |
| wheel detection | LOD-duplicate/steering/caliper clutter → **hardened CarWheelRig** lateral filter → clean 4 corners |
| wheel centers (m) | FL/FR (±0.74, +1.473) RL/RR (±0.74, −1.246); radius ≈0.26 (used tire_radius 0.28), wheelbase 2.72, track 1.49 |
| grounding | upright (up.y 1.00), all 4 wheels contact; drove 259 m |
| light detection | **by material** (node names identical): front headlight = `Glass_light_1` (emissive warm white), rear taillight = `Light_glass` (emissive red, brighten on brake) + white headlight SpotLights + red brake SpotLights |
| headlight positions (player frame) | x = ±0.60, y = 0.50, z = −2.05 |
| taillight positions (player frame) | emissive `Light_glass`; brake SpotLights x = ±0.61, y = 0.66, z = +2.10 |
| body materials | `CarPaint` (paint, recolour target — 8 surfaces), `material`, `EXT_Metal`, `EXT_Plastic`, `Light` |
| colour source | `new_cars_color_mapping.md` (9 colours); player default = Brilliant Silver; NPC weighted common |
| player scene | `addons/gevp/scenes/mercedes_clk55_car.tscn` |
| NPC scene | `traffic/npc_mercedes_clk55.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd`, `car_selection.gd`, `traffic_manager.gd` (var + preload + warmup + 1% weight, box-car 15%→14%), `npc_car_lights.gd` (`MERCEDES_CLK` / `CLKModel`) |
| price | 850 000 ₽ |
| stats | **RWD** (`front_torque_split = 0.0`); torque 1000 / rpm 6100 / FD 2.82 / 5-speed [3.59,2.19,1.41,1.0,0.83] / drag 0.32 / frontal 2.0; display accel .82 / speed .85 / handling .76; mass 1635 kg |
| NPC spawn weight | 1 % (very rare; 138k verts → kept low per budget — "risky 100–150k" band) |
| MCP test result | flat test track: drove **259.4 m, upright (up.y 1.00), vel·forward = full speed (86 km/h, straight)** — all 4 wheels contact; recolour 8 CarPaint surfaces; night headlights (emissive + beam) + taillights (emissive red, brake); 3 NPCs upright, 4 wheel meshes + 4 night lights each, per-instance colours (Graphite Green / Silver / Silver) |
| screenshots | `screenshots/cars/mercedes_clk55_2003_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Notes
- 138k verts is in the "risky 100–150k" NPC band → spawn weight kept at 1 % (it's a very-rare
  AMG anyway). Player use is fine.
- Lamp lenses share node names but differ by material — emissive done by material name
  (`Glass_light_1` / `Light_glass`), a useful pattern for models with non-unique node names.

## Final pass/fail checklist
See `docs/car_pipeline/mercedes_clk55_2003_checklist.md` — all Definition-of-Done gates pass.
