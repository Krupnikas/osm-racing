# Mitsubishi Lancer Evo X MR 2008 — integration report

Sixth car (`docs/CAR_INTEGRATION_PIPELINE.md`). Tier B — real-scale, separate corner
wheels, **AWD**. First car drive-tested on the flat **test track** (`race/test_track_scene.tscn`)
instead of the city (see learnings).

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2008_mitsubishi_lancer_evolution_x_mr_cz4a.glb` |
| imported model | `res://car/models/lancer_evo_x/lancer_evo_x.glb` (uid `cjmjqfwecd57u`) |
| car_id | `lancer_evo_x_2008` |
| display name | Mitsubishi Lancer Evo X |
| target length | 4.50 m (already real scale) |
| original real-vertex AABB | L 4.49 × W 2.06 × H 1.59 (axis z); 43,497 verts |
| scale factor | ×1.0013 (real scale) |
| native forward | +Z (rear logo/muffler at −Z) |
| player orientation | rotated 180° → front −Z; diag(−1.0013, +1.0013, −1.0013), y=0.0 |
| NPC orientation | no rotation → front +Z; scale 1.0013, y=0.0 |
| wheel detection | separate corner wheels (FL/FR/RL/RR: misc/tyre/wheel/rotor) grouped by CarWheelRig (clean, no stray) |
| wheel centers (m) | FL/FR (±0.769, 0.316, +1.334) RL/RR (±0.769, 0.316, −1.316) |
| wheel radius | 0.315 m · wheelbase 2.65 m · track 1.54 m |
| grounding | upright (up.y 1.00), all 4 wheels contact on flat ground; drove 491 m straight |
| light detection | **shared single `Vehicle_Exterior_mm_lights` material across front+rear lenses** → NOT mesh-emissive; lit via placed white headlight SpotLights (front) + red taillight OmniLights (rear, baseline at night + brighten on brake) |
| headlight positions (player frame) | x = ±0.66, y = 0.72, z = −1.95 |
| taillight positions (player frame) | red OmniLights x = ±0.62, y = 0.78, z = +1.95 |
| body materials | `Vehicle_Exterior_mm_ext` (paint, recolour target), `_cab`, `_chassis`, `_misc`, `_badges` |
| colour source | `new_cars_color_mapping.md` (6 colours); player default = Octane Blue Pearl (confirmed albedo applied); NPC weighted common |
| player scene | `addons/gevp/scenes/lancer_evo_x_car.tscn` |
| NPC scene | `traffic/npc_lancer_evo_x.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd`, `car_selection.gd`, `traffic_manager.gd` (var + preload + warmup + 1% weight, box-car 17%→16%), `npc_car_lights.gd` (`LANCER_EVO` / `EvoModel`) |
| price | 700 000 ₽ |
| stats | **AWD** (`front_torque_split = 0.5`); torque 900 / rpm 7000 / FD 4.06 / 6-speed [3.65,2.37,1.69,1.32,1.06,0.84] / drag 0.35 / frontal 2.1; display accel .85 / speed .82 / handling .88; mass 1560 kg |
| NPC spawn weight | 1 % (very rare performance sedan) |
| MCP test result | flat test track: drove **491.6 m, upright (up.y 1.00), vel·forward = 36.7 = full speed (132 km/h, perfectly straight)** — all 4 wheels contact; night white headlights (forward beam) + red taillights (brake); 3 NPCs upright, 4 wheel meshes + 4 night lights each, distinct colours (Graphite Gray / Apex Silver / Rally Red) |
| screenshots | `screenshots/cars/lancer_evo_x_2008_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Notes / learnings
- **Test track for drive-tests:** city residential roads have curbs/edges that leave a wheel
  airborne and kill traction. `race/test_track_scene.tscn` has a perfectly flat ground + a
  swappable `Car` node (named "Car", found directly by `CarSpawner`) — drive/orientation tests
  are clean there (Evo hit 132 km/h in a straight line).
- **Don't teleport a fast RigidBody:** teleporting at 36 m/s glitched the body to y=530. Set
  `freeze = true`, move, zero velocity, then `freeze = false` to settle — or brake to a stop first.
- **Shared lamp material:** the model's single `Vehicle_Exterior_mm_lights` covers front+rear, so
  the rear lens can't be made red via emission; red rear effect comes from placed OmniLights.

## Final pass/fail checklist
See `docs/car_pipeline/lancer_evo_x_2008_checklist.md` — all Definition-of-Done gates pass.
