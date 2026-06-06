# Audi TT 3.2 quattro 2003 — verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = audi_tt_32_2003`
Status: PASS — live MCP drive (114 m upright, AWD) + night light shots + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail

## Player (GEVP)
| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | uid `2ile85ms1tms`, 30,147 verts |
| 2 | Scale (~4.04 m) | ✅ | ×99.8301 → L 4.04 / W 1.80 / H 1.35 |
| 3 | Orientation (front leads) | ✅ | native +Z, rotated 180°; drove 114 m, vel·fwd +0.37; Audi grille on −Z |
| 4 | Real model wheels | ✅ | merged Tire/Rim/Caliper split by CarWheelRig |
| 5 | Wheels spin | ✅ | LIVE: containers on all 4 GEVP nodes; spin Δ large while driving |
| 6 | Front wheels steer | ✅ | rigged onto GEVP steering nodes |
| 7 | Grounded | ✅ | LIVE up.y 1.00 seated; `audi_tt_32_2003_front.png` |
| 8 | Headlights on front blocks | ✅ | `audi_tt_32_2003_night_front.png` — forward beam |
| 9 | Taillights on rear blocks | ✅ | `audi_tt_32_2003_night_rear.png` — brake glow |
| 10 | Brake brighten | ✅ | red_glass emission + brake spot raised at brake_input>0.1 |
| 11 | Recolor paint only | ✅ | targets `phong1`; Brilliant Red |
| 12 | Drivetrain (AWD) | ✅ | `front_torque_split = 0.5`; drove 114 m |

## NPC
| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC | ✅ | `npc_tt_scene` + 1% weight |
| N2 | Scale/orientation (+Z) | ✅ | no rotation |
| N3 | Wheels rotate | ✅ | 4 `wheelmesh_*` per instance |
| N4 | Grounded | ✅ | LIVE 3× up.y 1.00 |
| N5 | Headlights/taillights | ✅ | LIVE night: 4 lit lights each; `audi_tt_32_2003_npc_colors.png` |
| N6 | Colors vary per instance | ✅ | LIVE per-instance `phong1` override (White / Denim Blue / White) |

## Metadata
| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .80 / speed .82 / handling .80; torque 820 / AWD |
| M2 | Price | ✅ | 650 000 |
| M3 | Spec line | ✅ | `2003 · 3.2L VR6 · 250 HP · AWD · 1510 KG` |
| M4 | NPC weight | ✅ | 1 % very rare |
| M5 | Report written | ✅ | `audi_tt_32_2003_integration_report.md` |
