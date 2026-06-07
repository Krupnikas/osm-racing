# Subaru Impreza WRX STI 2011 (hatchback) — integration report

Seventh car (`docs/CAR_INTEGRATION_PIPELINE.md`). **Tier C** — 139-part messy model with
duplicate/LOD wheel fragments. Unblocked by a **CarWheelRig hardening** (lateral stray
filter) rather than a per-car hack.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2011_subaru_impreza_wrx_sti_hatchback.glb` |
| imported model | `res://car/models/subaru_sti/subaru_sti.glb` (uid `dog45bdr568vd`) |
| car_id | `subaru_sti_2011` |
| display name | Subaru WRX STI |
| target length | 4.42 m |
| original real-vertex AABB | L 4.42 × W 1.99 × H 1.67 (axis z); 46,312 verts, 139 parts |
| scale factor | ×100.2589 |
| native forward | +Z (rear TailLight/bumper at −Z) |
| player orientation | rotated 180° → front −Z; diag(−100.2589, +100.2589, −100.2589), y=0.14 |
| NPC orientation | no rotation → front +Z; scale 100.2589, y=0.12 |
| wheel detection | merged/fragmented → **hardened CarWheelRig**: the broad name filter grabbed the steering wheel ("wheel") and rear bumper ("CarPaint_Trim" → "rim"); the new real-vertex lateral filter drops these centreline strays automatically (no per-car code). Clean 4 corners. |
| wheel centers (m) | FL/FR (±0.74, +1.28) RL/RR (±0.74, −1.35); radius 0.329, wheelbase 2.63, track 1.48 |
| grounding | upright (up.y 1.00), all 4 wheels contact on flat ground; drove 330 m |
| light detection | **named meshes**: `HeadLightL6/R6` (front, emissive warm white) + `TailLightL6/R6` (rear, emissive red, brighten on brake); + white headlight SpotLights (beam) + red brake SpotLights |
| headlight positions (player frame) | x = ±0.55, y = 0.64, z = −1.94 |
| taillight positions (player frame) | emissive `TailLight*`; brake SpotLights x = ±0.68, y = 0.85, z = +1.88 |
| body materials | `wrxM_CarPaint_Max1` (paint, recolour target), `wrxM_Chassis_Max1`, `wrxM_Opaque_*`, `wrxM_Engine_Max1` |
| colour source | `new_cars_color_mapping.md` (7 colours); player default = World Rally Blue; NPC weighted common |
| player scene | `addons/gevp/scenes/subaru_sti_car.tscn` |
| NPC scene | `traffic/npc_subaru_sti.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd`, `car_selection.gd`, `traffic_manager.gd` (var + preload + warmup + 1% weight, box-car 16%→15%), `npc_car_lights.gd` (`SUBARU_STI` / `STIModel`) |
| price | 750 000 ₽ |
| stats | **AWD** (`front_torque_split = 0.5`); torque 950 / rpm 6500 / FD 3.9 / 6-speed [3.64,2.24,1.59,1.16,0.97,0.76] / drag 0.36 / frontal 2.1; display accel .86 / speed .83 / handling .87; mass 1505 kg |
| NPC spawn weight | 1 % (very rare performance hatch) |
| MCP test result | flat test track: drove **330.6 m, upright (up.y 1.00), vel·forward = full speed (121 km/h, straight)** — all 4 wheels contact; night headlights (emissive + beam) + taillights (emissive red, brake); 3 NPCs upright, 4 wheel meshes + 4 night lights each, distinct colours (Obsidian Black / World Rally Blue / Lightning Red) |
| screenshots | `screenshots/cars/subaru_sti_2011_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Key learning — CarWheelRig hardening (benefits all messy models)
The rig's `_collect_wheel_meshes` matches wheel keys as substrings, so it grabbed body parts
on this model: the **steering wheel** ("…SteeringWheel…" → "wheel") and the **rear bumper**
("…CarPaint_Trim…" → "rim"). Added a **real-vertex lateral stray filter** to `build()`:
detect separate-wheel models (outermost candidate well off-centre vs track width) and drop
candidates near the lateral centreline (where steering wheels, bumpers, diffusers, exhausts
cluster). Merged-wheel cars (single mesh centred on x≈0) are detected and left untouched.
Verified no regression on Civic/RX-8/Audi/Focus (merged) or Volga/Evo (separate). This
single fix is what makes STI — and the remaining Tier-C cars — integrate cleanly.

## Final pass/fail checklist
See `docs/car_pipeline/subaru_sti_2011_checklist.md` — all Definition-of-Done gates pass.
