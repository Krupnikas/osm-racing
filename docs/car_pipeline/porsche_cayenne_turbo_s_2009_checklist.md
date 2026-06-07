# Porsche Cayenne Turbo S 2009 — verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = porsche_cayenne_turbo_s_2009`
Status: PASS — flat test-track drive (294 m straight @114 km/h) + night lights + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail

## Player (GEVP)
| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | uid `dgq6it2outd0g`, 37,641 verts |
| 2 | Scale (~4.79 m SUV) | ✅ | ×99.9004 → L 4.79 / W 2.25 / H 1.67 |
| 3 | Orientation (front leads) | ✅ | native +Z, rotated 180°; drove 294 m, vel·fwd = full speed |
| 4 | Real model wheels | ✅ | custom `extra_mat_keys=["llanta","rin"]` + hardened rig → clean 4 corners |
| 5 | Wheels spin | ✅ | LIVE: containers on all 4 GEVP nodes; drove 294 m |
| 6 | Front wheels steer | ✅ | rigged onto GEVP steering nodes |
| 7 | Grounded | ✅ | LIVE: all 4 wheels contact, up.y 1.00; `porsche_cayenne_turbo_s_2009_front.png` |
| 8 | Headlights on front blocks | ✅ | forward beam; `porsche_cayenne_turbo_s_2009_night_front.png` |
| 9 | Taillights on rear blocks | ✅ | red omni glow; `porsche_cayenne_turbo_s_2009_night_rear.png` |
| 10 | Brake brighten | ✅ | red OmniLights 0.4→3.0 at brake_input>0.1 |
| 11 | Recolor paint only | ✅ | targets `CAYENNE` (4 surfaces); Meteor Gray; chrome/glass untouched |
| 12 | Drivetrain (AWD) | ✅ | `front_torque_split = 0.4`; drove 294 m straight |

## NPC
| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC | ✅ | `npc_cayenne_scene` + 1% weight |
| N2 | Scale/orientation (+Z) | ✅ | no rotation |
| N3 | Wheels rotate | ✅ | 4 `wheelmesh_*` per instance |
| N4 | Grounded | ✅ | LIVE 3× up.y 1.00 on flat track |
| N5 | Headlights/taillights | ✅ | LIVE night: 4 lit lights each; `porsche_cayenne_turbo_s_2009_npc_colors.png` |
| N6 | Colors vary per instance | ✅ | LIVE: Basalt Black / Black / Sand White (per-instance `CAYENNE` override) |

## Metadata
| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .80 / speed .82 / handling .60; torque 1100 / AWD |
| M2 | Price | ✅ | 1 200 000 |
| M3 | Spec line | ✅ | `2009 · 4.8L TT V8 · 550 HP · AWD · 2355 KG` |
| M4 | NPC weight | ✅ | 1 % very rare luxury SUV |
| M5 | Report written | ✅ | `porsche_cayenne_turbo_s_2009_integration_report.md` |
