# Subaru WRX STI 2011 — verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = subaru_sti_2011`
Status: PASS — flat test-track drive (330 m straight @121 km/h) + night lights + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail

## Player (GEVP)
| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | uid `dog45bdr568vd`, 46,312 verts / 139 parts |
| 2 | Scale (~4.42 m) | ✅ | ×100.2589 → L 4.42 / W 1.99 / H 1.67 |
| 3 | Orientation (front leads) | ✅ | native +Z, rotated 180°; drove 330 m, vel·fwd = full speed |
| 4 | Real model wheels | ✅ | hardened CarWheelRig drops steering/bumper strays, clean 4 corners |
| 5 | Wheels spin | ✅ | LIVE: containers on all 4 GEVP nodes; drove 330 m |
| 6 | Front wheels steer | ✅ | rigged onto GEVP steering nodes |
| 7 | Grounded | ✅ | LIVE: all 4 wheels contact, up.y 1.00; `subaru_sti_2011_front.png` |
| 8 | Headlights on front blocks | ✅ | emissive `HeadLight*` meshes + beam; `subaru_sti_2011_night_front.png` |
| 9 | Taillights on rear blocks | ✅ | emissive `TailLight*` meshes red; `subaru_sti_2011_night_rear.png` |
| 10 | Brake brighten | ✅ | TailLight emission + brake spot 0.6→2.0 at brake_input>0.1 |
| 11 | Recolor paint only | ✅ | targets `wrxM_CarPaint_Max1`; World Rally Blue |
| 12 | Drivetrain (AWD) | ✅ | `front_torque_split = 0.5`; drove 330 m straight |

## NPC
| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC | ✅ | `npc_sti_scene` + 1% weight |
| N2 | Scale/orientation (+Z) | ✅ | no rotation |
| N3 | Wheels rotate | ✅ | 4 `wheelmesh_*` per instance |
| N4 | Grounded | ✅ | LIVE 3× up.y 1.00 on flat track |
| N5 | Headlights/taillights | ✅ | LIVE night: 4 lit lights each; `subaru_sti_2011_npc_colors.png` |
| N6 | Colors vary per instance | ✅ | LIVE: Obsidian Black / World Rally Blue / Lightning Red |

## Metadata
| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .86 / speed .83 / handling .87; torque 950 / AWD |
| M2 | Price | ✅ | 750 000 |
| M3 | Spec line | ✅ | `2011 · 2.5L Turbo · 305 HP · AWD · 1505 KG` |
| M4 | NPC weight | ✅ | 1 % very rare |
| M5 | Report written | ✅ | `subaru_sti_2011_integration_report.md` |
