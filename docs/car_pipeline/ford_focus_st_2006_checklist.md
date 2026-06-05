# Ford Focus ST 2006 — integration verification checklist

First car through the new-car pipeline (`docs/CAR_INTEGRATION_PIPELINE.md`).
`car_id = ford_focus_st_2006`. Each item is a hard gate from the task's Stage 13.
Status: ✅ pass · ⚠️ partial · ❌ fail · ⏳ not yet checked. Evidence = MCP runtime
screenshot / measurement.

## Player (GEVP, drivable showroom car)

| # | Check | Status | Evidence |
|---|-------|--------|----------|
| 1 | Imports cleanly | ✅ | uid `elww55pi1lw8`, 17 textures extracted, scene loads |
| 2 | Scale correct (~4.34 m) | ✅ | scaled L=4.34 W=1.96 H=1.66; matches road & NPC on screen |
| 3 | Orientation (drives forward, front leads) | ✅ | vel·forward = +14.3 while accelerating; headlights on front |
| 4 | Uses real model wheels (not virtual) | ✅ | merged Tire/Rim/Disc/Caliper split into 4 containers, reparented onto GEVP wheel nodes |
| 5 | All 4 wheels spin when driving | ✅ | spin_var front 115 / rear 49; wheel_node.rotation.x delta huge |
| 6 | Front wheels steer visually | ✅ | front-left wheel visibly turned in night front-view screenshot |
| 7 | Grounded (not floating / sinking) | ✅ | visible body bottom 116.70 ≈ wheel bottoms 116.75; sits on road |
| 8 | Headlights on real front lamp blocks, beam forward | ✅ | night front-view: both headlights lit + forward beam on asphalt |
| 9 | Taillights on real rear lamp blocks | ✅ | night rear-view: both red_glass clusters glow on the real rear blocks |
| 10 | Brake lights brighten when braking | ✅ | braking → both clusters bright + red pool on road; coasting → dim glow |
| 11 | Body recolour only on paint (glass/lights/tyres untinted) | ✅ | Performance Blue applied to `Paint` material only |
| 12 | Works as player / drivable | ✅ | swapped in as player, drove under throttle, chase cam follows |

## NPC

| # | Check | Status | Evidence |
|---|-------|--------|----------|
| N1 | Spawns as NPC traffic | ✅ | npc_focus_scene preloads cleanly; spawn weight 3% |
| N2 | Correct scale / orientation (front +Z) | ✅ | daytime shot: correct size + recognizable front/rear |
| N3 | Model wheels spin while moving | ✅ | rig → 4 containers; npc_car collects 6 wheel meshes into _wheel_mesh_nodes |
| N4 | Grounded | ✅ | y stable 116.8–117.1; daytime shot wheels on road |
| N5 | Headlights/taillights work (night) | ✅ | night shot: white beams + red taillights on real blocks |
| N6 | Body colour variety from mapping | ✅ | per-instance: Silver/Orange/White, Grey/Blue/Grey runs — `screenshots/ford_focus_st_npc_colors.png` |

## Metadata

| # | Check | Status | Evidence |
|---|-------|--------|----------|
| M1 | Registered in CarSettings.CARS + DISPLAY_STATS | ✅ | accel .78 / speed .80 / handling .78 |
| M2 | Price in CareerState.CAR_PRICES | ✅ | 450 000 (sporty compact, rarer than normal) |
| M3 | Spec line in car_selection | ✅ | "2006 · 2.5L · 225 HP · FWD · 1392 KG" |
| M4 | Showroom preview correct | ✅ | tunnel preview renders Focus (blue, 3/4 view, headlight) — `screenshots/ford_focus_st_showroom_preview.png` |
| M5 | NPC spawn weight plausible | ✅ | 3% (rare hot-hatch); rebalanced box-car 28%→25% |

## Testing notes / gotchas (apply to every car)

- **Headlights:** before judging headlights, CONFIRM night actually engaged (the
  scene visibly went dark). The headlight spotlights are `visible = is_night`, so on
  a daytime frame they are simply off and "no headlights" is a false negative. Check
  the screenshot is dark (lit windows, street lamps, dark sky) first, then verify the
  beam. Drive a few metres so the beam shows on the asphalt.
- **Taillights/brake:** verify TWO states — coasting (dim red glow on both clusters)
  and braking (`brake_input>0.1` → bright clusters + red pool on the road). One
  screenshot can't prove the brake delta; capture both.
- **Grounding:** trust the VISUAL (visible-mesh bottom vs wheel bottom vs the asphalt
  the car rests on), not a single downward raycast — overlapping road-collision layers
  at junctions make a naive `intersect_ray` read ~1 m off even when the car is seated
  correctly (seen here: probe hit a higher residential batch above the surface the car
  actually sits on).
- **Orientation:** confirm with `velocity · (-basis.z) > 0` while accelerating AND a
  front-view screenshot showing headlights/grille at the leading end — not by eye alone.
