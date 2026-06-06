# Audi TT 3.2 DSG Quattro 2003 — integration report

Fourth car through the pipeline (`docs/CAR_INTEGRATION_PIPELINE.md`). Tier A — same
Sketchfab "F_M_*_High" family, **AWD** (quattro).

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/2003_audi_tt_3.2_dsg_quattro.glb` |
| imported model | `res://car/models/audi_tt/audi_tt.glb` (uid `2ile85ms1tms`) |
| car_id | `audi_tt_32_2003` |
| display name | Audi TT 3.2 quattro |
| target length | 4.04 m |
| original real-vertex AABB | L 0.0405 × W 0.0180 × H 0.0135 (axis z) |
| final scaled AABB | L 4.04 × W 1.80 × H 1.35 m |
| scale factor | ×99.8301 |
| native forward | +Z (rear `red_glass` z −1.62, plate z −1.86) |
| player orientation | rotated 180° → front −Z; transform diag(−99.8301, +99.8301, −99.8301), y=0.14 |
| NPC orientation | no rotation → front +Z; scale 99.8301, y=0.12 |
| wheel detection | merged-wheel split (`CarWheelRig`), 4 source meshes (Tire/Rim/Caliper + brake disc) |
| wheel centers (m) | FL(−0.75, 0.157, +1.214) FR(+0.75, …) RL(−0.75, 0.133, −1.209) RR(+0.75, …) |
| wheel radius | 0.314 m |
| wheelbase | 2.42 m (short coupe) |
| track | 1.50 m |
| grounding | upright on road (up.y 1.00), seated, no float/sink |
| light detection | taillight `red_glass`; headlight emissive meshes `LightCluster`/`LightRefracted` |
| headlight positions (player frame) | x = ±0.60, y = 0.62, z = −1.85 |
| taillight positions (player frame) | emissive `red_glass`; brake SpotLights x = ±0.55, y = 0.64, z = +1.70 |
| body materials | `phong1` (paint, recolour target), `chassis` |
| colour source | `new_cars_color_mapping.md` (12 colours); player default = Brilliant Red; NPC weighted common |
| player scene | `addons/gevp/scenes/audi_tt_car.tscn` |
| NPC scene | `traffic/npc_audi_tt.tscn` |
| registry changes | `car_settings.gd` (CARS + DISPLAY_STATS), `career_state.gd`, `car_selection.gd`, `traffic_manager.gd` (var + preload + warmup + 1% weight, box-car 22%→21%), `npc_car_lights.gd` (`AUDI_TT` / `TTModel`) |
| price | 650 000 ₽ |
| stats | **AWD** (`front_torque_split = 0.5`); torque 820 / rpm 6500 / FD 4.06 / 6-speed [3.5,2.3,1.6,1.2,0.95,0.78] / drag 0.32 / frontal 1.90; display accel .80 / speed .82 / handling .80; mass 1510 kg |
| NPC spawn weight | 1 % (very rare) |
| MCP test result | played `res://main.tscn`; swapped player → TT (torque 820, AWD 0.5); first drive pinned on an obstacle (4 m), **clean re-drive 114 m staying upright (up.y 1.00), vel·forward = +0.37**; night headlights (forward beam) + taillights (brake); 3 NPCs upright, 4 wheel meshes + 4 night lights each, per-instance colours (White / Denim Blue / White) |
| screenshots | `screenshots/cars/audi_tt_32_2003_front.png`, `_night_front.png`, `_night_rear.png`, `_npc_colors.png` |

## Notes / known limitations
- **AWD** (`front_torque_split = 0.5`); verified the car drives 114 m forward, upright.
- First throttle test pinned the car against a building (4 m, heavy wheelspin) — environmental,
  not a config fault; the clean re-drive on open road covered 114 m.
- Short wheelbase (2.42 m) — TT is a small coupe; wheel z at ±1.21.
- Day rear/showroom not separately captured; night front/rear cover lamp placement.

## Final pass/fail checklist
See `docs/car_pipeline/audi_tt_32_2003_checklist.md` — all Definition-of-Done gates pass.
