# Lada Vesta Cross 2017 — QUARANTINE report

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` (§8 Quarantine criteria & NPC budget).
Quarantining is a **valid, successful** pipeline outcome — see §8.

| Field | Value |
|---|---|
| source file | `~/Desktop/OSM material/vaz_lada_vesta_cross_2017.zip` → `scene.gltf` |
| car_id | `lada_vesta_cross_2017` |
| vertex count | **1,019,940** (~1.02 M) |
| mesh parts | 109 |
| measured AABB | raw 444 × 153 × 207 (SketchUp units, length axis x) |
| wheels detected | 0 (no nameable wheel meshes) |
| body materials | none classifiable |
| materials | all 11 are SketchUp wireframe swatches: `wire_093093093`, `wire_188075000`, `wire_110012012`, … (RGB-encoded names, no semantic meaning) |
| front/rear lights | 0 / 0 detected |

## Blocking issues
1. **Over 1 M vertices** → per the NPC budget this is **"unusable as-is"** (1M+ tier), and far
   over the 500 k "no NPC use" and 150 k "common NPC" ceilings.
2. **SketchUp `wire_*` materials** — every material is an auto-generated colour swatch. There is
   no `paint`/`glass`/`light`/`tyre` semantics, so geometry classification fails: body recolour,
   glass/lights separation, and wheel identification are all impossible without a full remap.
3. **No separable wheels** (0 wheel meshes detected) → cannot rig spinning wheels.
4. Non-standard scale (SketchUp units) — fixable, but moot given the above.

## Possible use
- **Player-only:** not viable as-is (no recolour, no wheels, 1 M verts is heavy even for a single
  player car, and lamps can't be placed without classification).
- **NPC:** not viable as-is (massively over budget; would tank traffic performance).

## Recommended fix (before any future integration)
- **Re-export / material remap:** open in Blender, replace the `wire_*` swatches with named PBR
  materials (paint / glass / chrome / tyre / lights) so geometry classifies.
- **Heavy decimation / LOD generation:** target < 50 k for NPC use (≈20× reduction) or < 150 k
  for a rare player-only car.
- **Wheel separation:** split the four wheels into nameable meshes (or model new ones) so the
  wheel rig can spin them.
- **Manual light placement** once front/rear lamps are identifiable.

## Final status: **QUARANTINED** — needs Blender cleanup + remap + decimation + re-export.
