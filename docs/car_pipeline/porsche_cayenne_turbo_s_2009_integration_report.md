# Porsche Cayenne Turbo S 2009 — integration report

Ninth car (`docs/CAR_INTEGRATION_PIPELINE.md`). **Tier C** — opaque Spanish material names;
the first "0-wheel-by-default" model integrated, via **custom `extra_mat_keys`** on the rig.
AWD luxury SUV.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2009_porsche_cayenne_turbo_s.glb` |
| imported model | `res://car/models/cayenne/cayenne.glb` (uid `dgq6it2outd0g`) |
| car_id | `porsche_cayenne_turbo_s_2009` |
| display name | Porsche Cayenne Turbo S |
| target length | 4.79 m |
| original real-vertex AABB | L 4.79 × W 2.25 × H 1.67 (axis z); 37,641 verts |
| scale factor | ×99.9004 |
| native forward | +Z (verified: drove forward after 180° rotation) |
| player orientation | rotated 180° → front −Z; diag(−99.9004, +99.9004, −99.9004), y=0.16 |
| NPC orientation | no rotation → front +Z; scale 99.9004, y=0.14 |
| wheel detection | **custom mat keys**: wheels use `llanta` (tyre) + `rin`/`CAYENNE_rin` (rim) + `disk`. `CarWheelRig.build(..., extra_mat_keys=["llanta","rin"])` + hardened lateral filter → clean 4 corners |
| wheel centers (m) | FL/FR (±0.85, +1.42) RL/RR (±0.85, −1.43); radius 0.37 (SUV), wheelbase 2.85, track 1.70 |
| grounding | upright (up.y 1.00), all 4 wheels contact; drove 294 m |
| light detection | shared single `CAYENNE_luz` material (front+rear) → lit via placed white headlight SpotLights + red taillight OmniLights (Evo-style) |
| headlight positions (player frame) | x = ±0.70, y = 0.92, z = −2.20 |
| taillight positions (player frame) | red OmniLights x = ±0.65, y = 0.92, z = +2.20 |
| body materials | `CAYENNE` (paint, recolour target — opaque name), `cromo` (chrome), `CAYENNE_plast`, `bajo`, `CAYENNE_int`, `CAYENNE_luz` |
| colour source | `new_cars_color_mapping.md` (12 colours); player default = Meteor Gray; NPC weighted common |
| player scene | `addons/gevp/scenes/cayenne_car.tscn` |
| NPC scene | `traffic/npc_cayenne.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd`, `car_selection.gd`, `traffic_manager.gd` (var + preload + warmup + 1% weight, box-car 14%→13%), `npc_car_lights.gd` (`PORSCHE_CAYENNE` / `CayenneModel`) |
| price | 1 200 000 ₽ |
| stats | **AWD** (`front_torque_split = 0.4`); torque 1100 / rpm 6000 / FD 3.7 / 6-speed [4.1,2.3,1.5,1.1,0.87,0.69] / drag 0.36 / frontal 2.7; display accel .80 / speed .82 / handling .60; mass 2355 kg |
| NPC spawn weight | 1 % (very rare luxury SUV) |
| MCP test result | flat test track: drove **293.7 m, upright (up.y 1.00), vel·forward = full speed (114 km/h, straight)** — all 4 wheels contact; recolour 4 CAYENNE surfaces; night headlights (beam) + taillights (red omni, brake); 3 NPCs upright, 4 wheel meshes + 4 night lights each, per-instance colours (Basalt Black / Black / Sand White) |
| screenshots | `screenshots/cars/porsche_cayenne_turbo_s_2009_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Key learning — custom `extra_mat_keys` for opaque models
The analyzer reported **0 wheels** because the wheel materials are Spanish (`llanta`=tyre,
`rin`=rim) — not the rig's default keys. The rig already accepts `extra_mat_keys`; passing
`["llanta","rin"]` (plus the default `disk`) collects the wheels, and the hardened lateral
filter trims any strays. **This same technique unblocks Aveo (`chevy_aveo_*` + `disk`) and
Spark (`Sparkrines`/`Sparkcromo`)** — the wheel meshes exist, they just need their material
tokens supplied. Pattern: inspect material names → pass the tyre/rim tokens as extra keys.

## Final pass/fail checklist
See `docs/car_pipeline/porsche_cayenne_turbo_s_2009_checklist.md` — all Definition-of-Done gates pass.
