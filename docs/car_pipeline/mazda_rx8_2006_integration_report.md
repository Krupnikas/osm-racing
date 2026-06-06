# Mazda RX-8 2006 — integration report

Third car through the new-car pipeline (`docs/CAR_INTEGRATION_PIPELINE.md`).
Tier A — same Sketchfab "F_M_*_High" family as Focus ST / Civic Si, but **RWD** (the
first rear-drive car in the batch).

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2006_mazda_rx-8.glb` |
| imported model | `res://car/models/mazda_rx8/mazda_rx8.glb` |
| car_id | `mazda_rx8_2006` |
| display name | Mazda RX-8 |
| target length | 4.43 m |
| original real-vertex AABB | L 0.0443 × W 0.0192 × H 0.0132 (length axis = z) |
| final scaled AABB | L 4.43 × W 1.91 × H 1.32 m |
| scale factor | ×99.9189 |
| native forward direction | +Z (rear `red_glass` at z −2.00, plate at z −2.21) |
| final player orientation | rotated 180° → front = −Z; transform diag(−99.9189, +99.9189, −99.9189), y=0.14 |
| final NPC orientation | no rotation → front = +Z; scale 99.9189, y=0.12 |
| wheel detection method | **merged-wheel split** (`CarWheelRig`), 3 source meshes: Tire/Rims/Calipers |
| wheel centers (m) | FL(−0.75, 0.158, +1.349) FR(+0.75, …) RL(−0.75, 0.158, −1.349) RR(+0.75, …) |
| wheel radius | 0.332 m |
| wheelbase | 2.698 m |
| track width | 1.50 m |
| grounding | upright on road (up.y 1.00), seated, no float/sink |
| light detection method | taillight material `red_glass`; headlight emissive mesh name `Light_C` (matcher also accepts `lightcluster`/`lightrefracted`); spotlights added programmatically |
| headlight positions (player frame) | x = ±0.62, y = 0.60, z = −1.95 (low sports stance) |
| taillight positions (player frame) | emissive `red_glass`; brake SpotLights x = ±0.60, y = 0.62, z = +1.95 |
| body material names | `CaarPaint` (paint, recolour target), `Chassis` |
| colour source | `new_cars_color_mapping.md` (8 colours); player default = Velocity Red Mica; NPC weighted common |
| player scene path | `addons/gevp/scenes/mazda_rx8_car.tscn` |
| NPC scene path | `traffic/npc_mazda_rx8.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd` (CAR_PRICES), `car_selection.gd` (CAR_SPEC_LINES), `traffic_manager.gd` (var + preload + warmup + 1% weight, box-car 23%→22%), `npc_car_lights.gd` (`MAZDA_RX8`: detection by `RX8Model`, split head/tail/reverse + meshes) |
| price | 480 000 ₽ |
| stats | **RWD** (`front_torque_split = 0.0`); torque 720 / rpm 9000 (rotary redline) / FD 4.44 / 6-speed [3.76,2.27,1.65,1.32,1.0,0.84] / drag 0.31 / frontal 1.95; display accel .78 / speed .80 / handling .82; mass 1310 kg |
| NPC spawn weight | 1 % (very rare rotary sports) |
| MCP test result | played `res://main.tscn`; swapped player → RX-8; reset upright then drove **63.9 m staying upright (up.y 1.00)**, rear-wheel spin Δ **1143 rad** (RWD); night headlights (forward beam) + taillights (brake brightening); 3 NPCs → 3 distinct colours (Snowflake White / Black Mica / Winning Blue), all upright, 4 wheel meshes each, all night head+tail lights lit |
| screenshots | `screenshots/cars/mazda_rx8_2006_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Notes / known limitations
- **First RWD car:** `front_torque_split = 0.0` on the player vehicle so torque goes to the
  rear wheels; verified the rear wheels spin (1143 rad) and the car drives 64 m upright.
- Headlight emissive mesh is the model's single `Light_C` lens which spans the whole car
  (front + rear lenses). It is glowed warm-white; the rear portion is visually overridden
  by the separate `red_glass` taillight glow, exactly as on Civic's `LightCluster`.
- Day rear/showroom shots not separately captured (night front/rear cover lamp placement);
  capture later if desired. The car is in `CarSettings.CARS` (selection UI auto-discovers).
- Swap-tumble avoidance: this pass reset the car upright immediately after `replace_player_car`
  (lesson from Civic) — no flip occurred.

## Final pass/fail checklist
See `docs/car_pipeline/mazda_rx8_2006_checklist.md` — all Definition-of-Done gates pass.
