# Mazda RX-8 2006 — integration verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = mazda_rx8_2006`
Status: PASS — live MCP drive pass (drove 64 m upright, RWD) + night light shots + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail · ⏳ not checked

## Player (GEVP, drivable)

| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | `res://car/models/mazda_rx8/mazda_rx8.glb`, uid `bs0pkwbciebbu`, 31,114 verts |
| 2 | Scale correct (~4.43 m) | ✅ | scale ×99.9189 → L 4.43 / W 1.91 / H 1.32; matches road |
| 3 | Orientation: front leads | ✅ | native +Z, player rotated 180°; drove 63.9 m, front fascia/headlights on −Z |
| 4 | Uses real model wheels | ✅ | merged Tire/Rims/Calipers split by `CarWheelRig` (3 source meshes) |
| 5 | All 4 wheels spin | ✅ | LIVE: containers reparented on all 4 GEVP nodes; rear-wheel spin Δ 1143 rad |
| 6 | Front wheels steer visually | ✅ | rigged containers reparented onto GEVP steering nodes (Focus path) |
| 7 | Grounded | ✅ | LIVE: up.y 1.00, seated on road; `mazda_rx8_2006_front.png` |
| 8 | Headlights on front lamp blocks | ✅ | `mazda_rx8_2006_night_front.png` — white forward beam |
| 9 | Taillights on rear lamp blocks | ✅ | `mazda_rx8_2006_night_rear.png` — both glow red (brake) |
| 10 | Brake lights brighten | ✅ | setup raises red_glass emission + brake spot energy at brake_input>0.1 |
| 11 | Body recolor only on paint | ✅ | targets `CaarPaint`; glass/lights/tyres untouched; Velocity Red |
| 12 | Drivetrain (RWD) correct | ✅ | `front_torque_split = 0.0`; rear wheels drive, drove 64 m |

## NPC

| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC traffic | ✅ | `npc_rx8_scene` preload + 1% spawn weight |
| N2 | Correct scale/orientation (+Z) | ✅ | no rotation; front lights/wheels on +Z |
| N3 | NPC wheels rotate while moving | ✅ | 4 `wheelmesh_*` collected per instance |
| N4 | Grounded | ✅ | LIVE: all 3 up.y 1.00 |
| N5 | NPC headlights/taillights work | ✅ | LIVE night: NPCHeadlightL/R + NPCTaillightL/R lit; `mazda_rx8_2006_npc_colors.png` |
| N6 | NPC colors vary per instance | ✅ | LIVE: Snowflake White / Black Mica / Winning Blue (per-instance `caarpaint` override) |

## Metadata

| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .78 / speed .80 / handling .82; torque 720 / rpm 9000 / RWD |
| M2 | Price | ✅ | `CAR_PRICES["mazda_rx8_2006"] = 480000` |
| M3 | Spec line | ✅ | `2006 · 1.3L Rotary · 232 HP · RWD · 1310 KG` |
| M4 | NPC spawn weight | ✅ | 1 % very rare rotary sports |
| M5 | Integration report written | ✅ | `mazda_rx8_2006_integration_report.md` |
