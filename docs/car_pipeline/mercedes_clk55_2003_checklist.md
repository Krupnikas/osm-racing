# Mercedes-Benz CLK 55 AMG 2003 — verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = mercedes_clk55_2003`
Status: PASS — flat test-track drive (259 m straight @86 km/h) + night lights + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail

## Player (GEVP)
| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | uid `bnqaf7gfy6qoj`, 138,375 verts / 127 parts |
| 2 | Scale (~4.65 m) | ✅ | ×100.3224 → L 4.65 / W 1.89 / H 1.42 |
| 3 | Orientation (front leads) | ✅ | native +Z, rotated 180°; drove 259 m, vel·fwd = full speed |
| 4 | Real model wheels | ✅ | hardened CarWheelRig drops LOD/steering/caliper strays |
| 5 | Wheels spin | ✅ | LIVE: containers on all 4 GEVP nodes; drove 259 m |
| 6 | Front wheels steer | ✅ | rigged onto GEVP steering nodes |
| 7 | Grounded | ✅ | LIVE: all 4 wheels contact, up.y 1.00; `mercedes_clk55_2003_front.png` |
| 8 | Headlights on front blocks | ✅ | emissive `Glass_light_1` + beam; `mercedes_clk55_2003_night_front.png` |
| 9 | Taillights on rear blocks | ✅ | emissive `Light_glass` red; `mercedes_clk55_2003_night_rear.png` |
| 10 | Brake brighten | ✅ | Light_glass emission + brake spot 0.6→2.0 at brake_input>0.1 |
| 11 | Recolor paint only | ✅ | targets `CarPaint` (8 surfaces); Brilliant Silver; glass/lights/chrome untouched |
| 12 | Drivetrain (RWD) | ✅ | `front_torque_split = 0.0`; drove 259 m straight |

## NPC
| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC | ✅ | `npc_clk_scene` + 1% weight (kept low: 138k verts) |
| N2 | Scale/orientation (+Z) | ✅ | no rotation |
| N3 | Wheels rotate | ✅ | 4 `wheelmesh_*` per instance |
| N4 | Grounded | ✅ | LIVE 3× up.y 1.00 on flat track |
| N5 | Headlights/taillights | ✅ | LIVE night: 4 lit lights each; `mercedes_clk55_2003_npc_colors.png` |
| N6 | Colors vary per instance | ✅ | LIVE: Graphite Green / Silver / Silver (per-instance `CarPaint` override) |

## Metadata
| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .82 / speed .85 / handling .76; torque 1000 / RWD |
| M2 | Price | ✅ | 850 000 |
| M3 | Spec line | ✅ | `2003 · 5.4L V8 · 367 HP · RWD · 1635 KG` |
| M4 | NPC weight | ✅ | 1 % very rare (vert-budget conscious) |
| M5 | Report written | ✅ | `mercedes_clk55_2003_integration_report.md` |
