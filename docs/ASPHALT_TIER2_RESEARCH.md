# Asphalt / Road Rendering — Consolidated Research Digest

Deep-research sweep (2026-07) behind `docs/ASPHALT_TIER2_PLAN.md`. Fan-out of ~15 agents across sim-racing,
arcade/open-world racers, and the graphics literature, each grounded against our shader
(`shaders/wet_road.gdshader`). Legend per item: **[cheap|medium|expensive]** for 3 part-timers on Apple Silicon
Forward+. "CONFIRMED" = documented in a primary source; "INFERRED" = synthesis. All Phase-A techniques reuse existing
`world_pos.xz`/UV/UV2 — no new mesh data, vertex colours, or UV channels.

---

## 1. Tiling-break (kills "one texture / too repetitive") — the #1 lever

Ranked cheapest→dearest for our TBDR Apple GPU (fetch count matters more than ALU):

| Technique | Extra fetches | Cost | Fit |
|---|---|---|---|
| **Macro-variation** (low-freq multiply over tiled base) | +1 | cheap | **Best first move** |
| **Detail maps** (albedo/normal at 2nd scale) | +1–2 | cheap–med | Free-ish; also adds close-up crispness |
| **IQ Technique-3** (low-freq index → 2 offset virtual copies, smoothstep) | ~2 + lowfreq | cheap | Great balance, mip-friendly |
| **Mikkelsen hex-tiling** (JCGT 2022; Godot 4 port exists) | 3 (cull→~1.5) | medium | **Best true tiling-break** |
| **IQ Technique-1** (per-tile random offset/flip) | 4 | medium | Prefer via hex-tiling |
| **Heitz-Neyret / Deliot-Heitz** (histogram-preserving) | 3 + LUTs | med–exp | Needs offline precompute; Mikkelsen is lighter |
| **IQ Technique-2** (Voronoi 3×3) | 9 | expensive | Avoid on TBDR (IQ: "stresses memory bus") |
| **Texture bombing** (GPU Gems 1 ch.20) | ~8 | expensive | For scattered features, not base road |

- **Macro-variation:** sample same/low-contrast texture at ~1/8–1/32 scale, Multiply over base; strength ~0.2–0.35.
  Kills value-periodicity (what the eye catches first). Sources: UE WoLD macro/micro; IQ; Frostbite terrain.
- **IQ "Texture Repetition":** https://iquilezles.org/articles/texturerepetition/ (T1 4-fetch, T2 9-fetch, T3 ~2-fetch).
- **Mikkelsen "Practical Real-Time Hex-Tiling"** JCGT 2022: https://jcgt.org/published/0011/03/05/ ; demo
  https://github.com/mmikk/hextile-demo ; **Godot port** https://godotshaders.com/shader/stochastic-hex-tiling-mikkelsens-adaptation/
  (albedo-only, world `.xz`, `rot_strength=0` for straight lines). Jason Booth height-blend variant → ~1.5 eff. samples
  via weight-culling: https://medium.com/@jasonbooth_86226/stochastic-texturing-3c2e58d76a14
- **Heitz & Neyret 2018** (HPG best paper): https://eheitzresearch.wordpress.com/722-2/ ; Deliot & Heitz / Unity
  productization: https://unity.com/blog/engine-platform/procedural-stochastic-texturing-in-unity
- **Golus caveat (must-do):** feed correct `textureGrad` derivatives + keep anisotropic filtering, or the far road
  shimmers regardless of anti-repeat trick. https://bgolus.medium.com/distinctive-derivative-differences-cce38d36797b

**Our gap:** base albedo is straight `texture(albedo_texture, UV)` — zero break. Wear only modulates brightness over a
repeating pattern. Fix = macro-variation (A1) + optional hex-tiling (B1).

---

## 2. Multi-layer road materials (base + detail + grunge) — "many textures"

- **Assetto Corsa `ksMultilayer_fresnel_nm`:** base diffuse + up to **4 detail textures blended by an RGB(A) mask**;
  diffuse authored **long/narrow (e.g. 1024×4096)** for macro colour, small 512 detail tiled tight for close-up;
  **spec packed in diffuse alpha**. Sources: assettocorsamods "Photo Quality Road Surface"; OverTake shaders list.
- **rFactor2 IBL Road/Curb PBR:** a **"Road Details map" with R=Dust, G=Race-Groove, B=Wear, A=Puddle**; plus
  `MarbleDustMask` (R=marble, G=dust); curb shader blends **two albedo+roughness sets** by road info ("one texture,
  two states"). https://docs.studio-397.com/developers-guide/general-reference/pbr-a-guide-in-rfactor2/pbr-using-road-curb-shader
- **AMS2/PCARS (Madness):** layer0.rgb=diffuse, **layer0.a=wear map** (fades detail normals + base of gloss),
  layer1.rgb=detail normal, layer1.a=gloss/AO; low-res macro diffuse + tiled detail is the anti-blur strategy.
  3 UV channels (UV0 macro, UV1 detail, UV2 racing-line groove); vertex colours blue=groove/red=marbles.
- **NFS/Frostbite & Forza & The Crew (INFERRED, closed engines):** tiling base + low-freq macro variation + detail
  normal at 2nd scale + placed decals for wear; lane paint as **mask maps/decals, not baked** into the tile.

**Takeaway for us:** blend our two sets (Asphalt022 + 026B) by a world-space mask (A2); keep base plain, wear as a
layer. AC's long/narrow diffuse instinct matches our already-anisotropic UV.

---

## 3. Structured wear ("по-русски": rectangular repairs, not just noise)

- **iRacing dynamic-track cells** → static analog: quantize `world_pos.xz` into 2–4 m cells, deterministic hash per
  cell, vary patch darkness/roughness with hard-ish edges → believable **rectangular asphalt-repair boundaries**
  (exactly how Russian roads are patched). Pure shader math, 0 fetches. (A3)
- **iRacing "distance-readable debris":** author wear with enough contrast to survive mip/distance — our current
  0.78–1.05 patch range is too subtle; widen it.
- **rF2 channel-packed wear** → optional hand-authored RGBA Soviet-wear map (C1): R=grime, G=repair-patch,
  B=cracks/potholes, A=puddle-bias, one world-space fetch.
- Base texture must stay **plain** so these read as deliberate — a crack-baked base (our 026B) makes everything look
  broken and can't be dialed down for Dubai/проспект.

---

## 4. Normal detail + roughness variation (the #1 realism tell)

- **Normal-combine math** (Barré-Brisebois & Hill "Blending in Detail" https://blog.selfshadow.com/publications/blending-in-detail/ ;
  Golus https://bgolus.medium.com/normal-mapping-for-a-triplanar-shader-10bf39dca05a):
  - **Whiteout** (Unity `BlendNormals`, practical default): `normalize(vec3(n1.xy+n2.xy, n1.z*n2.z))` (~7 ALU).
  - **RNM** (highest fidelity): `n1+=(0,0,1); n2*=(-1,-1,1); return n1*dot(n1,n2)/n1.z - n2;` (~8 ALU).
  - UDN (5 ALU) cheapest; PD 7. On modern GPUs whiteout≈RNM cost. Use **whiteout** for detail-on-asphalt.
- **Two-frequency normal:** macro base normal + high-freq micro grain, each own scale, combined via whiteout; **fade
  detail→flat at distance** (Catlike mipmap fade) to kill shimmer. Asphalt macro-texture 0.5–50 mm, micro 0.001–0.5 mm
  → two frequencies read correctly near+far. rFactor2 production road shader does exactly this.
- **Godot gotcha:** `StandardMaterial3D` Detail slot can disable the main normal map (issue #85413) → do it in our
  custom shader, not the built-in slot. (We already have a custom shader — fine.)
- **Roughness variation is the single biggest "fake" tell** across every sim report — tie roughness to wear masks;
  drive a low-freq "reflectivity" variation so wet reflections break up patchily (iRacing LIDAR-reflectivity idea).

**Our gap:** single-scale normal that tiles with albedo; subtle roughness. Fix = A4.

---

## 5. Wet surface model (night track, Phase E)

Canonical: **Sébastien Lagarde "Water drop" 1–4** + "Moving Frostbite to PBR" (SIGGRAPH 2014).
- **`DoWetProcess` (the shippable model):**
  ```
  float factor = lerp(1.0, 0.2, (1-Metalness)*Porosity);  // albedo darken toward 0.2·porosity
  Diffuse *= lerp(1.0, factor, WetLevel);
  Gloss    = lerp(1.0, Gloss, lerp(1.0, factor, 0.5*WetLevel)); // roughness down at half rate
  ```
  Porosity from gloss if no map: `saturate(((1-Gloss)-0.5)/0.4)`. Simpler rain form: `Diffuse*=lerp(1,0.3,Wet)`,
  `Gloss=min(Gloss*lerp(1,2.5,Wet),1)`. Sources:
  https://seblagarde.wordpress.com/2013/04/14/water-drop-3b-physically-based-wet-surfaces/
- **Puddles = accumulation masks + flat normal:** `AccumulatedWater = max(min(Flood,1-Height), saturate((Flood-VC.g)/0.4))`;
  blend N→flat vertex normal, F0→0.02, gloss→1 in puddles. **Anchor puddles to geometry low spots** (GT7/AMS2) —
  for us reuse carved `_road_depressions` (potholes fill with water). Sources: Water drop 2b; DeepSpaceBanana;
  Godot rain-puddle shader https://godotshaders.com/shader/rain-puddles-with-ripples-and-reflection/
- **Ripples:** procedural concentric rings gated to up-facing + accumulated-water, scaled by rain intensity (cheap
  flipbook normal is enough for us).

**Our shader already does** albedo×0.35, roughness→low, world-space puddles, fresnel, night boost — E1 just tightens
this toward the Lagarde form.

---

## 6. Reflections for wet night roads (Phase E3)

Hierarchy (Lagarde/Frostbite): **SSR → planar → reflection probe/cubemap → sky**, shared GGX BRDF.
- **Stochastic SSR** (Frostbite; first shipped in **NFS 2015** + Mirror's Edge Catalyst): Hi-Z stackless trace, GGX
  importance sampling (Halton) → the **elongated vertical neon streak** on wet roads; 1/8-res tile classify; ray-reuse
  resolve; temporal clamp; roughness→mip. Emissive neon reflects **for free** from the color buffer. Sources:
  https://www.ea.com/frostbite/news/stochastic-screen-space-reflections ; https://advances.realtimerendering.com/s2015/
- **Godot 4.6 rewrote SSR** (PR #111210): Hi-Z tracing (64 steps default), auto gaussian-blurred mip roughness,
  temporal reprojection with motion vectors, half-res (~0.3×) / full-res modes. **Forward+ only.** Params: Max Steps,
  Fade In/Out, Depth Tolerance, Half Size. https://www.strayspark.studio/blog/godot-46-rendering-deep-dive-ssr-lightmapper-performance
- **Reflection probes:** Godot native; `UPDATE_ONCE` cheap, blanket the city as SSR fallback; 4.6 octahedral probes are
  Metal-friendly. **Planar:** no built-in (plugins only), doubles scene cost — skip except a hero flooded plane.
- **Verdict:** conditional SSR (night+wet, half-res) + `UPDATE_ONCE` probes; benchmark on M-series (4.4 M1 regression
  issue #103723 — pin a known-good build).

---

## 7. Decals (Phase C2, hero details)

- **Families:** deferred/screen-space (reconstruct world pos from depth, clip to box, write G-buffer), mesh decals
  (clipped geometry, Z-fight fixes), volume/projected-box (Humus, wraps curved geo, random rotation), DBuffer
  (forward-friendly). Screen-space edge mip artifact + fix: Bart Wronski
  https://bartwronski.com/2015/03/12/fixing-screen-space-deferred-decals/ ; normal-angle rejection essential.
- **Godot 4 `Decal` node** = projected-box, writes albedo/normal/ORM; **Forward+/Mobile only**; Forward+ clustered
  (512 cluster budget shared w/ lights+probes), Mobile hard cap 8/mesh; cost ∝ **screen coverage** (many small = cheap);
  `albedo_mix=0` for normal/ORM-only; `normal_fade`, `upper/lower_fade`, `distance_fade_*`, `cull_mask`. No parallax.
  https://docs.godotengine.org/en/stable/tutorials/3d/using_decals.html
- **Atlas** many decals into one material (padding to stop mip bleed); bindless (Surge 2) for AAA scale.
- **Markings:** Cities:Skylines proves **swept "line decal networks" are the FPS-heavy option**; per-instance decals
  or bake-into-albedo (straights) + decals (curves/intersections) are cheaper. Our existing
  `tracks/tire_track_manager.gd` CPU-image stamp is already the GTA/RAGE runtime-scratch-decal pattern.
- **POM** for deep cracks/ruts: Godot `heightmap_deep_parallax` (expensive per-sample; **incompatible with triplanar**);
  gate to hero surfaces only.

---

## 8. Road→verge edge blend (Phase D)

- **Height-blend (Mishkinis, canonical)** — interlocking, not linear crossfade (grass grows into asphalt cracks):
  ```
  float ma = max(h1+w1, h2+w2) - depth;  b1=max(h1+w1-ma,0); b2=max(h2+w2-ma,0);
  return (c1*b1 + c2*b2)/(b1+b2);   // depth≈0.2 = transition width
  ```
  https://www.gamedeveloper.com/programming/advanced-terrain-texture-splatting — best quality/cost; reuses height in
  albedo.alpha; ~few ALU over lerp.
- **Vertex-color blend** (free weights from mesh) and **splatmaps** (HTerrain CLASSIC4) for >4 layers; **SDF** for crisp
  painted-line/curb edges (`smoothstep(0.5-fwidth,0.5+fwidth,sdf)`, Valve 2007).
- For us: cheap edge-dirt band via existing UV.x/UV2.x `edge_dist` (crumbling Soviet curb).

---

## 9. Region / location differentiation (per user — Dubai pristine vs Cherepovets worn)

- Runtime knows region: `_detect_facade_city(lat,lon)` → `_facade_city` (cherepovets / dubai_creek_harbour / "");
  `_is_russia_location()` by bbox.
- Design: `REGION_ASPHALT_PROFILES` (data-driven) → `decrepitude_base`, patches on/off, oil/rut, tint, roughness bias,
  which asphalt set(s). Final wear = `region_base × road_class_factor`. AMS2 LiveTrack "Green→Heavy Rubber presets"
  validate a single scalar scaling all wear terms. (Plan A5.)

---

## 10. Dynamic systems we deliberately SKIP (and why)

- **rF2 RealRoad / iRacing Dynamic Track / AMS2 LiveTrack** (per-session rubber/marble/water accumulation) — all need a
  persistent stamped render target; an open-world (non-lap) driver has no session to rubber-in. Static baked wear
  (A1–A4) delivers ~90% of the look at a fraction of the cost. Our `tire_track_manager.gd` is the hook if ever wanted.
- **Planar reflections everywhere**, **RT reflections**, **POM on all roads** — cost not justified; gate to hero cases.

---

## 11. Per-source cluster summaries (one-liners)

- **AC/ACC:** multilayer RGB-mask detail blend; long/narrow macro diffuse + tight detail; spec-in-alpha; visual groove
  overlay is baked & purely visual (grip unaffected) — proves a darkening overlay reads as real wear.
- **rFactor2:** channel-packed R/G/B/A road-details map is the highest-value steal; two-state curb blend.
- **GT7:** puddles in geometric low spots; racing line dries first / stays wettest; PS4 wetness is a fresnel illusion.
- **iRacing:** LIDAR reflectivity → varied base albedo+roughness; grid-cell wear; contrast for distance.
- **AMS2/PCARS:** global wear/wet **preset scalar** (Green→Heavy) = our per-district decrepitude; geometry puddles.
- **NFS Heat/Unbound (Frostbite):** wet-neon = Stochastic SSR of emissive on low-roughness; cracks/oil/manholes =
  G-buffer decals writing local roughness; lane paint = mask/decals; DoWetProcess wet material.
- **Forza/DriveClub:** macro variation on base; SSR + probes (DriveClub SSR+radiosity confirmed).
- **GTA V/RDR2/RAGE:** `.ymap`-placed decal drawables; tire skids/oil = pooled capped FX decals; height/vertex blend.
- **The Crew (Ivory Tower):** proprietary; road pipeline undocumented — retroreflective markings + SSR + FSR2, no RT.
- **Burnout 3/Revenge (RenderWare):** tiling asphalt + per-vertex RGBA colour breakup + MatFX dual-texture; markings =
  baked or thin alpha mesh-decals; roads ~2× width + dense roadside clutter to sell speed.
- **Burnout Paradise:** zone/PVS graph over numbered track units; heavy on-disc compression; roads = authored meshes
  (no runtime spline extruder), network in separate section data. (Streaming lesson, not surface tech.)

---

## 12. Key sources (deduped)
- IQ Texture Repetition https://iquilezles.org/articles/texturerepetition/
- Mikkelsen Hex-Tiling https://jcgt.org/published/0011/03/05/ · Godot port https://godotshaders.com/shader/stochastic-hex-tiling-mikkelsens-adaptation/
- Heitz/Neyret https://eheitzresearch.wordpress.com/722-2/ · Deliot/Heitz (Unity) https://unity.com/blog/engine-platform/procedural-stochastic-texturing-in-unity
- Golus normal/triplanar https://bgolus.medium.com/normal-mapping-for-a-triplanar-shader-10bf39dca05a · Blending in Detail https://blog.selfshadow.com/publications/blending-in-detail/
- Lagarde Water drop 3b https://seblagarde.wordpress.com/2013/04/14/water-drop-3b-physically-based-wet-surfaces/ · 2b https://seblagarde.wordpress.com/2013/01/03/water-drop-2b-dynamic-rain-and-its-effects/
- Frostbite Stochastic SSR https://www.ea.com/frostbite/news/stochastic-screen-space-reflections · SIGGRAPH 2015 https://advances.realtimerendering.com/s2015/
- Godot 4.6 SSR deep-dive https://www.strayspark.studio/blog/godot-46-rendering-deep-dive-ssr-lightmapper-performance · Decals https://docs.godotengine.org/en/stable/tutorials/3d/using_decals.html
- Mishkinis terrain splatting/height-blend https://www.gamedeveloper.com/programming/advanced-terrain-texture-splatting
- AC ksMultilayer https://assettocorsamods.net/threads/photo-quality-road-surface.834/ · rF2 road/curb shader https://docs.studio-397.com/developers-guide/general-reference/pbr-a-guide-in-rfactor2/pbr-using-road-curb-shader
- Bart Wronski decals https://bartwronski.com/2015/03/12/fixing-screen-space-deferred-decals/
- UE macro/micro variation https://www.worldofleveldesign.com/categories/ue4/landscape-macro-tiling-variation.php
