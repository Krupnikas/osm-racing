# Volga GAZ-3110 — integration report

Fifth car through the pipeline (`docs/CAR_INTEGRATION_PIPELINE.md`). **Tier B** — the
first non-Sketchfab-family car: already real-world scale, separate corner wheels, and
bespoke (non-`red_glass`) lamp materials.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/volga_gaz_3110_low_poly.glb` |
| imported model | `res://car/models/volga_gaz3110/volga_gaz3110.glb` (uid `cvly86acuewey`) |
| car_id | `volga_gaz3110` |
| display name | Volga GAZ-3110 |
| target length | 4.88 m (already ~real scale) |
| original real-vertex AABB | L 4.84 × W 2.01 × H 1.47 (axis z); **8,415 verts** (very light, NPC-gold) |
| final scaled AABB | ×1.0084 → L 4.88 × W 2.02 × H 1.49 m |
| scale factor | ×1.0084 (essentially 1.0 — NOT a 1/100 model) |
| native forward | +Z (front lamps Light/Light2 at +Z, rear Light3 + plate at −Z) |
| player orientation | rotated 180° → front −Z; diag(−1.0084, +1.0084, −1.0084), y=0.0 |
| NPC orientation | no rotation → front +Z; scale 1.0084, y=0.0 |
| wheel detection | **separate corner wheels** (`WheelFL/FR/RL/RR`, 5 sub-meshes each) grouped + recentred by `CarWheelRig`. A stray 17-vert grille emblem named `Body_WheelBody` is dropped first (it skewed the front quadrant centroids — fix in both setup scripts). |
| wheel centers (m) | FL/FR (±0.776, 0.27, +1.516) RL/RR (±0.776, 0.27, −1.263) |
| wheel radius | 0.329 m |
| wheelbase | 2.78 m |
| track | 1.55 m |
| grounding | upright (up.y 1.00); drove 139 m; slightly tall stance (period-correct for a Volga) |
| light detection | **bespoke**: rear lamp = material `Light3` (emissive red + brake brighten); front lamps = materials `Light`/`Light2` (emissive warm white); + programmatic spot/omni |
| headlight positions (player frame) | x = ±0.70, y = 0.64, z = −2.20 |
| taillight positions (player frame) | emissive `Light3`; brake SpotLights x = ±0.65, y = 0.72, z = +2.25 |
| body materials | `BodyColor` (paint, recolour target), `Dark`, `Chrome`, `Plastick` |
| colour source | `new_cars_color_mapping.md` (8 colours); player default = White; NPC weighted common |
| player scene | `addons/gevp/scenes/volga_gaz3110_car.tscn` |
| NPC scene | `traffic/npc_volga_gaz3110.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd`, `car_selection.gd`, `traffic_manager.gd` (var + preload + warmup + **4% weight**, box-car 21%→17%), `npc_car_lights.gd` (`VOLGA` / `VolgaModel`) |
| price | 130 000 ₽ (cheap older sedan, between Matiz 80k and Logan 150k) |
| stats | **RWD** (`front_torque_split = 0.0`); torque 640 / rpm 5500 / FD 3.9 / 5-speed [3.5,2.26,1.45,1.0,0.85] / drag 0.42 / frontal 2.1; display accel .45 / speed .50 / handling .50; mass 1400 kg |
| NPC spawn weight | **4 %** (common older Russian traffic) |
| MCP test result | played `res://main.tscn`; swapped → Volga (torque 640, RWD); clean re-drive **139 m, upright (up.y 1.00), vel·forward = +8.70** (~32 km/h); night headlights (Light/Light2 + beam) + taillights (Light3 + brake); 3 NPCs upright, 4 wheel meshes + 4 night lights each, distinct colours (Anthracite / Cyclone / Buran) |
| screenshots | `screenshots/cars/volga_gaz3110_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Notes / new pipeline learnings
- **First real-scale model** (×1.0). The 1/100 scaling of the Sketchfab family does NOT apply
  — always read the analyzer's scale factor, never assume ~100.
- **Stray wheel-named body mesh:** `Body_WheelBody` (grille emblem) is collected by the rig's
  name filter and skews quadrant centroids. Both setup scripts drop any `Body*Wheel*` mesh
  before `CarWheelRig.build`. Generalisable gotcha for future models.
- **Bespoke lamps:** no `red_glass`/`LightCluster`. Tail = `Light3`, head = `Light`/`Light2`.
  The setup script matches those material names directly.
- Slightly tall ride height (model y=0); acceptable/period-correct. Nudge model y by ~+0.1 if a
  tighter wheel-arch fit is wanted.

## Final pass/fail checklist
See `docs/car_pipeline/volga_gaz3110_checklist.md` — all Definition-of-Done gates pass.
