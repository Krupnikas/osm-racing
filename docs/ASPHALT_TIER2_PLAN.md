# Asphalt / Road Surface — Tier 2 Plan (consolidated, detailed)

**Goal:** fix the user complaint — *"не похож на реальный, одна текстура, слишком повторяемая, не по-русски"*,
and (added) *"текущая текстура слишком тёмная и растрескавшаяся — в Череповце такое встречается крайне редко."*
**Constraint:** Godot 4.6 Forward+, Apple Silicon/Metal, 3 part-timers, perf-sensitive. Extend the existing
`shaders/wet_road.gdshader` + `night_mode/wet_road_material.gd` — **do not rewrite**.
**Vibe:** worn post-Soviet asphalt (patched / occasional cracks / tar seams / potholes) is *on-brand* — but wear must
be a **controllable layer**, not baked into the base, so Dubai reads pristine and Cherepovets проспект reads clean-ish.

Companion doc with all the research and citations: `docs/ASPHALT_TIER2_RESEARCH.md`.

---

## 0. Current state (grounded in code — read, not assumed)

### Shader `shaders/wet_road.gdshader`
- Anisotropic UVs (UV.x=0..1 across width, UV.y=length·0.1), `varying vec3 world_pos` from vertex ([L76-L80](../shaders/wet_road.gdshader#L76-L80)).
- Base albedo: **straight `texture(albedo_texture, UV)`** ([L86](../shaders/wet_road.gdshader#L86)) — **no tiling-break.**
- 2 noise fetches (`noise_micro_tex` @ `micro_scale`, `noise_macro_tex` @ `macro_scale`) ([L98-L99](../shaders/wet_road.gdshader#L98-L99)).
- Soviet wear (`asphalt_wear`, default 0.55): world-space patches ~55 m (`world_pos.xz*0.018`) + stains ~8 m
  (`*0.05`) → modulate `dry_albedo` (×0.78..1.05, ×0.90..1.02) + roughness (×0.95..1.08) ([L116-L123](../shaders/wet_road.gdshader#L116-L123)).
- Wheel ruts via UV2.x, constant metres, only if `road_width_m >= 5.5` ([L128-L140](../shaders/wet_road.gdshader#L128-L140)).
- Wet: `albedo*0.35`, roughness→low, world-space puddles (`world_pos.xz*puddle_world_scale`) + curb bias,
  fresnel specular, night boost ([L143-L168](../shaders/wet_road.gdshader#L143-L168)).
- Marking overlay; **single-scale normal** `texture(normal_texture, UV)` ([L193](../shaders/wet_road.gdshader#L193)).

### Material config `night_mode/wet_road_material.gd`
- `create_road_shader_material(...)` builds the ShaderMaterial and sets the samplers/params.
- `apply_road_type_params(mat, road_type, road_width)` ([L186](../night_mode/wet_road_material.gd#L186)) is the central
  per-road-type hook. Existing keys: `intersection`/`crossing`, `ow*`/`bi*` (lane roads), `tram*`, `path`.
  It already varies `macro_roughness_dry`, `macro_albedo_dry`, `micro_scale`, `wheel_wear`, `curb_puddle_bias`,
  `road_width_m`. **This is where the region×road-class decrepitude (A5) and the A2 second-set selection plug in.**

### Textures (both already loaded)
- `osm_terrain_generator.gd:1139-1141` — **Asphalt026B = roads**, **Asphalt022 = sidewalks**; normals at 1296-1298.
- On disk: `textures/road/Asphalt022_1K-JPG_{Color,NormalGL,Roughness}.jpg` and `...Asphalt026B...`.
- Noise: `texture_generator.create_noise_micro(256)` / `create_noise_macro(512)`.

### Region detection (already exists — the hook for location-based asphalt)
- `osm_terrain_generator._detect_facade_city(lat,lon)` ([L29864](../osm/osm_terrain_generator.gd#L29864)) →
  `_facade_city` ∈ {`"cherepovets"`, `"dubai_creek_harbour"`, `""`} by **real OSM coords**.
- `_is_russia_location()` ([L29905](../osm/osm_terrain_generator.gd#L29905)) by start-coord bbox.

---

## 1. Root causes of the complaint (confirmed by reading shader + viewing textures)

1. **No tiling-break on base albedo** — [L86](../shaders/wet_road.gdshader#L86) tiles identically; wear only modulates
   *brightness* over a still-repeating pattern → the eye still catches the repeat. **#1 offender.**
2. **Base texture is wrong for Cherepovets** (viewed 2026-07: `Asphalt026B_Color` is near-**charcoal with a full
   macro-crack web baked in** → looks like broken old tarmac *everywhere*; `Asphalt022_Color` is a lighter mid-grey,
   more concrete-ish, finer cracks). Real Cherepovets road asphalt is a **plainer mid-grey** with aggregate and only
   *occasional* cracks/patches. Baked-in cracks also fight the region system (they'd show in Dubai too). See §2.
3. **Only one set used per surface** (own two, not blended).
4. **Wear is pure noise** — no *structured* rectangular repair patches / tar seams.
5. **Normal single-scale & tiles** with albedo; roughness variation subtle.
6. **No region / road-class variation** — same look for проспект, окраина, and Dubai alike.

---

## 2. Base-texture decision (NEW — from user feedback)

**Principle:** the base albedo/normal must be a **neutral, plain, mid-grey asphalt with visible aggregate and MINIMAL
baked cracking**. All cracks / darkening / patches / oil come from the **procedural wear layer** (A3), gated by
**region × road-class** (A5). This is the only way one base serves Dubai (pristine) *and* Cherepovets (проспект
clean-ish, окраина cracked). A crack-heavy base (current 026B) is unusable for that — it forces "broken everywhere."

**Options (recommended order):**
- **(a) Adopt a plainer mid-grey base** and demote cracks to the wear layer. Candidates are all CC0 1K JPG from
  AmbientCG (same source/pipeline as our current two, drop-in `textures/road/`): review **Asphalt025, Asphalt031,
  Asphalt014, Asphalt016, Asphalt023** for the flattest mid-grey with fine aggregate and least macro-cracking.
  → **Needs a fetch + visual pick (user-gated per "confirm artwork" rule). Recommended.**
- **(b) Interim, zero-download:** point roads at the lighter **Asphalt022** (currently sidewalks) and give sidewalks
  the darker 026B, or lift the road base via `base_color`/a grade. Quick A/B to validate "lighter+plainer reads
  better" before spending on a new asset.
- **(c) Keep 026B only as the high-decrepitude окраина set** in the A2 two-set blend (its crack web is fine when it
  *should* look broken), with a clean mid-grey as the проспект/Dubai base.

**Chosen direction (DECIDED 2026-07, user):** two-set system from the AmbientCG CC0 comparison set —
- **Default / everyday Russian (Cherepovets) road base = `Asphalt031`** (mid-grey, aggregate, intact — fixes
  "too dark & cracked").
- **Clean / Dubai (fresh) set = `Asphalt014`** (light, plain, near crack-free).
- **High-wear окраина blend set = keep `Asphalt026B`** (its crack web is fine where it *should* look broken;
  `Asphalt016` is an alternate).
- **`Asphalt012` rejected** (red crack veins / off-colour).
- **Fallback:** if `Asphalt031` underwhelms in-engine, use **`Asphalt014` as the Russian base too**.
Candidates downloaded to `scratchpad/asphalt_candidates/` (012/014/016/031; 023/025 don't exist on AmbientCG).

---

## 3. Cross-research consensus (cheapest first; full detail + sources in RESEARCH.md)

- **Macro-variation** (low-freq world multiply over the tiled base) — cheapest, biggest "not flat". +1 fetch.
- **Multi-detail blend** of 2+ sets by a world-space mask (AC ksMultilayer, rF2 R/G/B/A details map).
- **Structured wear**: rectangular-patch cell quantization → deliberate Soviet tar-seam repairs (iRacing cells).
- **Detail normal (2-freq, whiteout blend) + roughness variation** — roughness is the #1 "fake" tell.
- **True tiling-break** if still visible: IQ Technique-3 (~2 fetch) or Mikkelsen hex-tiling (Godot port).
- **Geometry-anchored puddles** — reuse carved `_road_depressions` as puddle sites (GT7/AMS2).
- **Region × road-class decrepitude** (AMS2 LiveTrack presets idea) — see A5.
- **Road→verge edge blend** (Mishkinis height-blend / UV edge) — crumbling Soviet curb.
- **Wet-night reflections** (Godot 4.6 SSR, conditional) + reflection probes — separate night track.
- **Decals** for hero details (manholes / potholes / crosswalks) — Godot Decal node, later, art-gated.

All of Phase A–B reuse existing `world_pos.xz` / UV / UV2 — **no new mesh data, no vertex colours, no new UV channels.**

---

## 4. Phased plan (prioritised, de-conflicted)

**Per-step protocol:** edit → headless lint (`Godot --headless --check-only --script`/shader load) → in-engine
screenshot via MCP (spawn Pionerskaya 59.149827,37.948859, day) → **stop scene** → before/after → commit to `aas-vibe`
on approval. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

### Phase A — Daytime "not flat / not one texture / is Russian" (cheap, shader-only) ← START HERE

- **A0. Base texture fix (see §2).** Pick a plain mid-grey base; wire roads to it; keep 026B for high-wear blend.
  *Files:* `osm_terrain_generator.gd:1139-1141,1296-1298`. *Cost:* asset swap, 0 shader cost. *Gate:* user picks asset.

- **A1. World-space macro-variation on base albedo.** Multiply `dry_albedo` by a low-freq `noise_macro_tex` sample at
  `world_pos.xz * macro_var_scale` (≈0.01 → ~100 m period), strength `macro_var_strength` (≈0.12 around 1.0).
  *Shader:* add after [L114](../shaders/wet_road.gdshader#L114). New uniforms `macro_var_scale`, `macro_var_strength`.
  *Cost:* +1 fetch. *Expected:* value-periodicity broken — the "flat single texture" read largely gone.

- **A2. Blend two asphalt sets by world mask.** Add `albedo_texture2`/`normal_texture2` (+ optional `roughness2`);
  blend base vs set2 by `smoothstep` on a low-freq world mask (reuse the A1 macro sample or a second scale). Which two
  sets + blend amount come from the region profile (A5)/`apply_road_type_params`.
  *Shader:* new samplers + blend right after albedo fetch [L86](../shaders/wet_road.gdshader#L86); combine normals via
  whiteout (shared with A4). *Material:* set `albedo_texture2`/`normal_texture2` in `create_road_shader_material`.
  *Cost:* +1–2 fetches. *Expected:* macro material variety ("many textures"). *Optional if A1+A3 already suffice.*

- **A3. Structured rectangular repair patches ("Soviet tar-seam cuts").** Quantize `world_pos.xz` into ~2–4 m cells
  (`floor(world_pos.xz / cell)`), hash per cell → per-cell darken/roughen with hard-ish edges, layered over the
  existing organic `asphalt_wear`. Also **widen** the current patch contrast (0.78–1.05 is subtle) so variation
  survives at distance (iRacing "distance-readable"). Gated by decrepitude (A5) — off in Dubai.
  *Shader:* extend the `asphalt_wear` block [L116-L123](../shaders/wet_road.gdshader#L116-L123). New uniforms
  `patch_cell_m`, `patch_strength`. *Cost:* 0 fetches (hash math). *Expected:* deliberate Russian rectangular repairs.

- **A4. Detail normal + roughness variation.** Sample a finely-tiled detail normal (reuse `normal_texture` at a second
  non-integer world scale, or a dedicated detail map) and combine with base normal via **whiteout**
  `normalize(vec3(n1.xy+n2.xy, n1.z*n2.z))`; fade detail→flat with distance to avoid horizon shimmer. Tie a touch more
  roughness to the wear masks. *Shader:* replace [L193-L194](../shaders/wet_road.gdshader#L193-L194) with a blended
  normal; new uniforms `detail_normal_scale`, `detail_normal_strength`, `detail_fade_dist`. *Cost:* +1 fetch.

- **A5. Two-axis decrepitude = REGION × road-class.** Final wear = `region_base × road_class_factor`.
  - **Region axis (per user):** small data-driven `REGION_ASPHALT_PROFILES` (in `wet_road_material.gd` next to
    `apply_road_type_params`) keyed by region (from `_facade_city` / country), fields:
    `decrepitude_base`, `patches_on` (A3), `oil_amount`, `rut_strength`, `base_tint`, `roughness_bias`, `set_a`/`set_b`
    (A2 selection).
    - **Dubai (uae):** `decrepitude_base≈0.05`, `patches_on=false`, minimal oil/ruts, lighter/warmer sun-baked tint,
      low roughness variation, clean set → pristine even on окраина.
    - **Cherepovets (russia):** `decrepitude_base≈0.7`, `patches_on=true`, oil/ruts/cracks on, darker oilier tint.
    - **Unknown (`""`):** neutral middle default.
  - **Road-class axis:** `road_class_factor` (~0.5 fresh проспект … ~1.2 убитая окраина) from OSM road type in
    `apply_road_type_params`, multiplies the region base.
  - *Wiring:* terrain generator passes the region into material creation; `apply_road_type_params` reads region +
    road_type → sets `asphalt_wear`, `patch_strength`, `wheel_wear`, tint, and the A2 set choice.
  - *Cost:* uniform wiring, 0 extra shader cost.

**Checkpoint after A:** screenshot. If long straights still read as tiling → Phase B. If good → skip B.

### Phase B — Kill residual tiling on long straights (only if still visible)
- **B1.** Add **IQ Technique-3** (cheap ~2 fetch, mip-friendly: low-freq index picks among offset virtual copies) OR
  **Mikkelsen hex-tiling** (Godot 4 GDShader port exists; 3 fetch, cull to ~1.5) on the *albedo* only, keeping the A4
  detail normal. Must use `textureGrad` derivatives + keep anisotropic filtering so the far road doesn't shimmer at
  speed (Golus caveat). *Cost:* medium.

### Phase C — Russian wear as art-directed content (medium; art-gated)
- **C1.** Optional channel-packed RGBA "Soviet-wear" map (R=grime, G=repair-patch, B=cracks/potholes, A=puddle-bias),
  sampled once world-space — upgrades A3's procedural wear to hand-authored potholes/manhole rings/tar seams.
  **Confirm before enabling by default; report if artwork missing** (per project rule).
- **C2.** Godot `Decal` nodes for hero details (manholes, pothole patches, crosswalks) — clustered, Forward+ (512
  cluster budget), screen-coverage cost. Later; art-gated.

### Phase D — Road ↔ verge edge (cheap-medium)
- **D1.** Dirty/darker crumbling band on the outer ~0.4 m via UV.x / UV2.x edge distance (Mishkinis height-blend feel)
  — "советский разбитый бордюр". Reuses existing `edge_dist` ([L102](../shaders/wet_road.gdshader#L102)).

### Phase E — Wet-night reflections (medium; separate night track, after daytime is right)
- **E1.** Formalise Lagarde `DoWetProcess` (porosity-driven albedo darken toward 0.2·porosity·(1−metal),
  roughness→low, normal→flat in puddles); we already do most of this — tighten it.
- **E2.** Geometry-anchored puddles: feed carved `_road_depressions` footprints as authoritative puddle sites
  (potholes fill with water — peak post-Soviet), instead of pure world noise.
- **E3.** Conditional **Godot 4.6 SSR** (Hi-Z, GGX, temporal, half-res) enabled only at night+wet, + a few
  `UPDATE_ONCE` ReflectionProbes at lit intersections as the off-screen fallback. Emissive neon reflects for free via
  the color buffer (NFS Heat/Unbound). Perf-gate hard; benchmark on the M-series.

---

## 5. Order of work & recommendation
1. **A0 base texture** (user picks a plain mid-grey — the biggest single lever for "not Cherepovets").
2. **A1** macro-variation (cheapest big win), then **A3** structured patches, **A4** detail normal, **A5** region×class,
   **A2** two-set blend (optional if A1+A3 already read well).
3. Screenshot → decide **B** (tiling-break). C/D/E are separate follow-on tracks (art-gated / night).
All per-step, committed to `aas-vibe`, MCP-verified (Pionerskaya, day). Nothing enabled-by-default that generates
art without confirmation.
