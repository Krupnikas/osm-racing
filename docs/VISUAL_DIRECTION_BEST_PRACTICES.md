# Visual Direction — Best Practices (systematized)

*Synthesized 2026-07-01 from a 5-stream research pass (art-direction/grade, lighting, sky, horizon, asphalt), each grounded in our real code. Status: 📋 plan/reference — NOT implemented. Per "plan, don't implement".*

## 0. The one big realization

**The "weak vibe" is ~80% cheap configuration, not missing content.** Four of the five subsystems (colour grade, lighting, sky, horizon) are almost entirely `WorldEnvironment` + shader-parameter tuning. Only the **asphalt** needs a real (but bounded) shader pass — and even that reuses mesh data we already carry. There is also one **structural cleanup**: we currently run **two competing grade systems** (WorldEnvironment adjustments + a night-only NFS-style `CanvasLayer` screen shader with teal/orange split-tone) that pull the mood in opposite directions.

**Unifying theme = "one atmosphere."** The vibe emerges when the subsystems *agree*: fog colour = sky-horizon colour (+ aerial perspective) ties grade↔sky↔horizon; the sun/moon disk driven by the real `DirectionalLight` ties sky↔lighting; AgX + one faded LUT + gentle desaturation ties the grade; a consistent roughness band ties the procedural materials. Cohesion, not more assets.

## 1. Current state (confirmed from `main.tscn` + `night_mode_manager.gd`)

| Area | Current | Verdict |
|---|---|---|
| Tonemap | **ACES** (`tonemap_mode=3`), exposure 0.9 / white 4.0 | ACES over-contrasts + skews warm + crushes shadows → fights overcast melancholy; white 4.0 clips sky early |
| Adjustments | contrast 1.08, **saturation 1.15** | +15% sat is the wrong direction for "faded" |
| Colour correction (LUT) | **none** | biggest missed cheap win |
| 2nd grade | night-only `settings/color_grading.gd` + `shaders/color_grading.gdshader` (purple shadows/orange highlights) | off-brief teal-orange; redundant full-screen pass — retire/repurpose |
| Sun | energy **1.3**, warm `(1,0.95,0.86)`, angular 0.6, shadow max **500**, splits 0.1/0.2/0.5, no `blend_splits` | warm+strong = sunny not overcast; 500 m shadow wastes resolution; no seam-hiding |
| Moon | 2nd DirectionalLight, energy 0.2, shadow max 300 | fine; unify disk with light dir |
| Glow day | intensity 0.04, bloom 0, threshold 2.2 | conservative; blend = engine default |
| Glow night | ADDITIVE, intensity 1.8, threshold 0.5, bloom 0.4 | ADDITIVE blows out (esp. now that 4.6 blooms pre-tonemap) |
| Fog | exponential, density **0.0015**, aerial **0.6**, sky_affect 0, **warm** `(0.82,0.78,0.68)` | too thin to hide the load edge; warm vs blue sky = smudge |
| GI | SDFGI off, SSIL off, SSAO on, ambient=Sky | **correct** for streaming — keep |
| Sky | custom `shader_type sky`: day HDRI-blend, night procedural (stars/moon/city-glow) | strongest architecture; but sky is *frozen* (baked HDRI clouds) and sun disk is hardcoded |
| Streaming | chunk 210 m, load 500, unload 700, render/fog-start 400, LOD0 250 | fog starts (400) *inside* load radius (500) → buildings ~55% visible where they pop |
| Roads | `shaders/wet_road.gdshader` (has wear/oil/ruts/puddles/wetness) on merged mesh; **anisotropic road UVs** (`UV.x`=0..1 width, `UV.y`=len·0.1); no vertex colour; 1× 1K asphalt set | not "no system" — it's UV-smear + constant roughness + no detail normal + weak tiling-break |

**Godot 4.6 fact that changes things:** glow now blends **before** tonemapping and the default blend is **SCREEN** (was SOFTLIGHT); **AgX** gained `tonemap_agx_white`/`tonemap_agx_contrast` knobs — so switching off ACES is now controllable.

## 2. THE PRIORITIZED PLAN (de-conflicted, cross-cutting)

### Tier 0 — near-free `WorldEnvironment`/light config (one sitting; biggest vibe delta)
1. **Tonemap ACES→AgX** (`tonemap_mode=4`); AgX needs more light → raise `tonemap_exposure` ~0.9→~1.3–1.5, set `tonemap_agx_white ~6–10`. AgX's neutral, gently-desaturated rolloff = the melancholic overcast look.
2. **Saturation 1.15 → ~0.90** *(reconciled — see §4)*: faded, not punchy, not crushed.
3. **Fog cohesion + depth** (fixes horizon *and* ties the whole frame together): cool `fog_light_color` to the sky horizon (~`0.72,0.75,0.80`); raise density 0.0015→~0.004–0.008 **or** switch to depth-fog (`begin≈250`=LOD0, `end≈480`≈`load_distance·0.96`); `fog_aerial_perspective` 0.6→~0.9; add `fog_sun_scatter ~0.3`. **Bind fog end to `load_distance` in code** so they never drift.
4. **Sun cooler + softer** (overcast): color→~`(0.95,0.95,1.0)`, energy 1.3→~1.0 (let sky ambient dominate); keep angular ~0.6 for soft shadows.
5. **Shadows**: `directional_shadow_max_distance` 500→**250** (sharper + faster), splits→`0.06/0.16/0.4`, `blend_splits=true`, `directional_shadow_fade_start≈0.6`; moon light max 300→~200.
6. **Glow → SCREEN** (day+night): day `glow_blend_mode=SCREEN`, threshold 2.2→~1.5, intensity 0.04→~0.15; night ADDITIVE→SCREEN, intensity 1.8→~1.2, threshold 0.5→~0.7, bloom 0.4→~0.2.
7. **`tonemap_white` day 4.0→~6–8** — stop blowing out the sky.

### Tier 1 — cheap, hours
8. **One faded colour-correction LUT** (`adjustment_color_correction` Texture3D, 33³): cool-neutral, low-chroma, slightly lifted blacks. **Day + night LUT pair.** **Retire/repurpose the NFS canvas shader** — move all grading onto WorldEnvironment+LUT (cheaper, unified, swappable).
9. **Moving 2D clouds** in the day sky — salvage the already-written `sky/day_sky.gdshader` `clouds()`/`fbm()`, render at quarter-res, gate under `!AT_CUBEMAP_PASS`. Kills the frozen-HDRI feel. ~0 cost.
10. **Sun/moon disk from `LIGHT0/LIGHT1_DIRECTION`** (delete hardcoded `sun_direction`) → the painted sun always matches the shadow direction (the #1 "pasted sky" tell).
11. **Painted horizon band** in the sky (low, desaturated Soviet treeline/skyline silhouette) → fills the empty far edge. ~0 runtime.
12. **Neon via emissive energy >1.0** on lamp/sign/window materials — makes night lights bloom cleanly instead of cranking global glow.
13. **Dithered chunk fade-in** aligned to load radius (`DISTANCE_FADE_PIXEL_DITHER`, min=`load_distance`, max=`render_distance`) — smooths remaining pop (fine for a moving racer).
14. **Subtle vignette + film grain** (toggleable) — analog/melancholic seasoning. Keep chromatic aberration off.

### Tier 2 — medium (one focused pass each)
15. **Asphalt shader overhaul** — the single real material job (all reuse existing `world_pos`/`UV2`/noise, no new mesh attrs to start):
    - **Sample asphalt in isotropic world-space** `world_pos.xz*~0.7` (not the stretched road UV) — *biggest single road win*; also fixes seams/intersections for free.
    - **Real roughness texture + 2-octave world-space variation** (±0.12–0.18) — flat/constant roughness is the #1 "fake" tell.
    - **One distance-faded detail normal** at ~25 cm, blended via **RNM/Whiteout** (not linear add) — aggregate sparkle up close.
    - **IQ 2-sample tiling break** (albedo/normal) — kills repetition on long straights, cheaper than hex-tiling.
    - **Edge-blend road↔verge** via the existing `UV.x` band (gravelly crumble; no mesh change) → later true vertex-colour feather if needed.
    - **Tar crack-seams + stronger patches** (noise masks, on-brand Soviet); **puddle normal-flatten + low-spot bias** (reuse carved-pit mask).
16. **Curve-driven time-of-day** — unify `NightModeManager`'s two-endpoint tweens into one `t` through `Curve`/`Gradient` resources → dusk/golden-hour for free, one tuning surface.
17. **Player-locked horizon ring** mesh (one draw call, painted silhouette, fog-tinted) — only if the painted band isn't enough.
18. **Enforce a project-wide roughness/albedo band** in the material scripts — cohesion across procedural facades/props/cars.

### Tier 3 — gate behind graphics tiers / measure first / avoid
- **Optional (measure on M-series):** SSIL (high tier only), targeted `ReflectionProbe` (tunnels, Update=Once), SSR (wet roads only), local `FogVolume` for night lamp glow.
- **Avoid** for our streaming/Mac profile: SDFGI / VoxelGI / LightmapGI (break on runtime-streamed procedural geometry, crush frame budget), **global volumetric fog**, triplanar on roads (3× samples, roads are flat), runtime impostor baking, **auto-exposure on the game camera** (it "breathes" and alters unshaded sky/rain/billboard materials), blanket decals (512-clustered / 8-per-mesh-mobile limits — hero wear only).

## 3. Reconciled conflicts (§4)

- **Saturation.** Art-direction said desaturate (→0.85 for melancholy); lighting said bump (→1.20 to offset AgX's slight desaturation). **Resolution:** the *mood goal wins* but AgX + the faded LUT already carry most of it, so land at **~0.90** (down from 1.15) and fine-tune live — don't over-crush to 0.85, don't compensate up to 1.20.
- **Tonemapper.** Current is **ACES** (confirmed `tonemap_mode=3`; one stream mislabeled it "Filmic"). Both streams agree the move is **AgX**.
- **Fog.** Unanimous: cool it, match the sky horizon, raise aerial perspective, bind its end to the load radius. (Depth-fog vs higher-density-exponential are two valid ways to get the opaque edge; depth-fog is the more *guaranteed* one, exponential the more *atmospheric*.)

## 4. Recommended "first session" quick-win batch
Do **Tier 0 (items 1–7)** in one sitting and screenshot before/after. It's all `main.tscn` Environment + the `DirectionalLight` + a few night values in `night_mode_manager.gd`, ~30–45 min, revertible, and it is where the "post-Soviet overcast melancholy" actually comes from. Then Tier 1 #8 (LUT) + #9 (clouds) + #11 (horizon band). Asphalt (#15) is its own session.

## 5. Consolidated mistakes to avoid
Boosting saturation for "pop"; teal-orange split-tone; crushing blacks (ACES default) instead of a *faded/lifted* look; warm fog against a cool sky; two competing grade systems; over-bloom via ADDITIVE + low threshold; hardcoded sun/moon direction diverging from the real light; leaving the sky in REALTIME/QUALITY when it isn't animating (match the mode to motion); radiance cubemap >256 for a driver; treating roughness as constant; linear-adding detail normals; keeping the anisotropic road-UV scale for asphalt; raising SPECULAR/METALLIC to fake shine (wetness does it); bumpy puddles; carpeting the map in decals; turning on SDFGI/volumetric "because realistic" on Apple Silicon; auto-exposure on the racing camera; grading your way out of flat asphalt (it's a material job).

## 6. Files that matter
`main.tscn` (Environment `Environment_main` ~L44-91; `DirectionalLight3D` ~L154-163) · `night_mode/night_mode_manager.gd` (day/night tweens, glow, moon, sky swap) · `sky/panorama_blend_sky.gdshader` (day) + salvageable `sky/day_sky.gdshader` (clouds) · `settings/color_grading.gd` + `shaders/color_grading.gdshader` (retire/repurpose) · `shaders/wet_road.gdshader` + `night_mode/wet_road_material.gd` (asphalt) · `osm/chunk_roads.gd` + `osm/osm_terrain_generator.gd` (road UVs/merge; streaming radii).

## 7. Sources
Per-topic source lists are in the research transcripts. Key anchors: Godot Environment/post-processing, Sky-shader, Lights-and-shadows, Visibility-ranges, Volumetric-fog, Decals docs; Godot 4.6 release notes (glow pre-tonemap, SCREEN default, AgX white/contrast); AgX PRs #87260/#106940; custom-sky-shaders article; Inigo Quilez "texture repetition"; self-shadow "blending in detail" (RNM/Whiteout); Lagarde "physically based wet surfaces"; Sucker Punch/inFamous open-world horizon talks; Andrei Rublev / Pathologic 2 for the post-Soviet mood reference.
