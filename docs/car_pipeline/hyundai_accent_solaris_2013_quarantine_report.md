# Hyundai Accent / Solaris 2013 — QUARANTINE report

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` (§8). Quarantine = valid pipeline outcome.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/hyundai_accent_2013.zip` → `scene.gltf` |
| car_id | `hyundai_accent_solaris_2013` |
| vertex count | **779,148** (~779 k) |
| mesh parts | 64 |
| measured AABB | raw 1.95 × 0.89 × 0.65 (length axis z) |
| wheels detected | 7 wheel parts (`*_TIRE_*`, `vehicle_tire`, `Circle_*`) |
| body materials | single `body` material |
| front / rear lights | 5 / 0 detected |

## Blocking issues
1. **779 k vertices** → over the 500 k "no NPC use unless explicitly approved" ceiling and far over
   the 150 k common-NPC ceiling. The car was specifically called out (batch intelligence + Hyundai
   is meant to be a **very common** NPC) — 779 k common NPCs would destroy traffic performance.
2. **Single `body` material** — like the Mazda 6 case, one baked body material covers most of the
   car, so a clean body-only recolour (without tinting glass/trim) is hard; per-instance NPC colour
   variety would be unreliable.

## Possible use
- **Player-only:** *technically* possible (wheels are separable, scale/orientation verifiable), but
  779 k for a single car is heavy and the single-material recolour is poor. Not recommended without
  cleanup.
- **NPC:** **not as-is** — it is intended to be common traffic, and 779 k × many instances is far
  over budget. Must decimate first.

## Recommended fix
- **Decimate to < 50 k** (≈16× reduction) for NPC use — it is meant to be common, so it needs to be
  light. Generate LODs.
- **Material split:** separate the single `body` material into paint / glass / trim / lights so
  recolour + per-instance NPC colours work.
- Then re-run the standard pipeline (wheels already separable; 5 front-light parts present for lamp
  placement; add rear-light identification).

## Final status: **QUARANTINED for NPC** — decimate + split materials, then re-integrate.
(Player-only is possible after a lighter re-export but is not recommended at 779 k.)
