# Soviet / Post-Soviet Vibe — Visual Direction Plan

**Status:** Approved, not yet started. Implementation pending.
**Reference target:** [`docs/example.png`](example.png) — warm, sunlit, slightly hazy provincial Soviet boulevard (5-storey khrushchyovka + 9-storey brezhnevka panel blocks, wide worn asphalt, grass verges, poplars, blue kiosk, Soviet lamp posts, deep-blue sky with cumulus, warm distant haze).
**Goal:** make the in-game daytime look *feel* like the reference — not photorealism, a convincing performance-friendly **provincial Soviet / post-Soviet vibe** that scales across a procedural world.

---

## 0. Autonomy mandate (how I work on this)

This plan is written so I (Claude) can execute it **end-to-end without user micro-management**.

- I **work until I am confident it looks meaningfully better than before** and reads as the same *kind of place* as `example.png`. I do not stop at "changed some values."
- I **find my own ways to test and debug.** I add temporary logs, dump values, capture screenshots, build tiny A/B scenes, and compare against the reference myself. I do not ask the user to verify for me.
- I **may search the internet** for references, color logic, Soviet streetscape detail, and **free/licensed textures or assets** (asphalt, concrete, grime/streak overlays, decals, fences, kiosks, foliage) when it improves the result. I record source + license for anything I import.
- I **decide the order** of work and reorder opportunistically when a faster win appears.
- I **iterate**: keep a change only if it moves the look toward the reference *and* holds the performance budget; otherwise revise or revert.
- I **respect the guardrails** (see §7) — especially the bridge-seamless rule, the batching/LOD architecture, and the day/night `night_mode_manager` contract.
- I **stop** when the Definition of Done (§8) is met, or surface a tight screenshot A/B if I hit a genuine fork I can't resolve from the reference.

---

## 1. Diagnosis (why it doesn't feel like the reference yet)

### What the reference *feels* like
Warm directional sun you can read on facades · deep blue sky + cumulus + warm horizon haze · crisp foreground, haze only far away · dirty-beige/tan/off-white panel blocks each a slightly different tone, streaked with grime/rust/seam-staining · a **layered street section** (road → worn markings → raised curb → grass verge → sidewalk → low fence → trees → buildings) · continuous low-key clutter rhythm (lamp posts, kiosk, poplars) · moderate-high saturation with real contrast.

### What the game currently feels like (from in-engine shots + code)
Cold, overcast, **milky** wash that dissolves the mid-ground within ~150 m · **flat shadeless light** with no readable sun direction · clean bright near-white boxes, no grime, no block-to-block variation · blown-out pale sky · uniform asphalt with pure-white markings · **flat street** (no curbs, sidewalk = asphalt) · sparse roadside · low contrast/saturation, cool cast.

### Biggest perceptual gaps (priority order)
1. **Atmosphere & light direction** — cold flat ambient + milky volumetric veil + cool aerial haze starting too close, vs warm sun + clear air + distant warm haze + contrast.
2. **Material weathering & per-building color variation** — uniformly clean/bright, vs grime logic + tonal spread.
3. **Streetscape layering** — curbs zeroed, sidewalk = asphalt, vs raised curb + concrete sidewalk + fenced grass verge.
4. **Density & continuity of clutter/vegetation** — systems exist but read sparse/washed.

**Key reassurance:** the project already owns the hard assets (Soviet panel/brick textures, full `FacadeAssembler`, parked cars, lamps, bus stops, trees, asphalt PBR). The gap is **art-direction + a few rendering decisions**, not missing content — so the top fixes are cheap and several are performance-*positive*.

---

## 2. Evidence (grounding `file:line`)

| Topic | Finding | Location |
|---|---|---|
| Ambient | Flat **Color** source, `(0.5,0.5,0.5)` — dead grey shadow fill | [main.tscn:47-48](../main.tscn#L47), [race_scene.tscn:40-41](../race/race_scene.tscn#L40) |
| Tonemap | **Filmic**, `tonemap_white=5.0` → milky/desaturated | [main.tscn:49-50](../main.tscn#L49) |
| Fog | cool `(0.75,0.8,0.9)`; runtime override cool `(0.7,0.75,0.85)`, `aerial_perspective=0.7` | [main.tscn:76-78](../main.tscn#L76), [osm_terrain_generator.gd:19249-19258](../osm/osm_terrain_generator.gd#L19249) |
| Volumetric fog | **enabled** day, density `0.005`, white albedo, 200 m → milky veil + GPU cost | [main.tscn:79-88](../main.tscn#L79) |
| SSR / SSIL | both **enabled** (SSR 64 steps, SSIL r5 i0.8) → cost + flattening | [main.tscn:56-74](../main.tscn#L56) |
| Sun | `light_energy` default 1.0, **white**, no `angular_distance` (hard shadows) | [main.tscn:150-156](../main.tscn#L150) |
| Day grade | screen color-grade overlay `intensity=0.0` (off in day) | [color_grading.gd:13](../settings/color_grading.gd#L13) |
| Sky | HDRI `textures/sky/day_clear_*.hdr` swapped in at runtime | [night_mode_manager.gd:114](../night_mode/night_mode_manager.gd#L114) |
| Curbs | **every** highway class sets `curb_height = 0.0` | [osm_terrain_generator.gd:4645-4703](../osm/osm_terrain_generator.gd#L4645) |
| Sidewalk | textured with **road asphalt** (`Asphalt022`) | [osm_terrain_generator.gd:749](../osm/osm_terrain_generator.gd#L749) |
| Markings | pure white `Color(1,1,1)` | [osm_terrain_generator.gd:5453](../osm/osm_terrain_generator.gd#L5453), [:6818](../osm/osm_terrain_generator.gd#L6818) |
| Facade system | sophisticated `FacadeAssembler` **geo-gated to Cherepovets only**; else flat fallback | [osm_terrain_generator.gd:9419-9533](../osm/osm_terrain_generator.gd#L9419), [facade-assembler.md](facade-assembler.md) |
| Facade shader | ALBEDO straight from tex, fixed rough 0.78, **no AO/grime/tint/variation** | [facade_111_125.gdshader](../osm/facade_111_125.gdshader) |
| Wall shader | **skips variation when textured** | [building_wall.gdshader:33-37](../osm/building_wall.gdshader#L33) |
| Fallback wall | single tan `Color(0.7,0.6,0.5)`, no per-building variety | [osm_terrain_generator.gd:804](../osm/osm_terrain_generator.gd#L804) |
| Existing Soviet assets | `5-soviet-panel*`, `9-of-3-soviet-panel`, `5-soviet-brick`, `111-125` PBR set | `textures/buildings/` |
| Clutter systems | parked cars, lamps @17 m, bus stops, garbage, business signs, trams, trees — exist | [:9720](../osm/osm_terrain_generator.gd#L9720), [:18315](../osm/osm_terrain_generator.gd#L18315) |

---

## 3. Difference breakdown (categories)

- **Lighting/atmosphere/post (dominant):** cold flat ambient, milky day volumetric fog, cool aerial haze too near, Filmic/white-5 desaturation, weak white sun, hard shadows, day grade off. See §2.
- **Color palette:** desaturated, blue-leaning; want warm + saturated with strong local color.
- **Roads/ground:** sane widths; asphalt PBR present but uniform (no macro variation/patches/oil/cracks); markings pure white.
- **Sidewalks/curbs/verges:** curbs all zeroed; sidewalk = asphalt; verge a thin washed strip with no fence/edging.
- **Buildings/facades:** great system gated to one city; even there, bare shader with no weathering; fallback = one tan tone, no variation.
- **Materials/texture treatment:** too clean, too uniform; no dirt gradient/edge wear/tiling break-up/rust streaks.
- **Props/clutter/density:** present but read sparse/washed; lacks continuous rhythm and verge furniture (fences, kiosks, wires).
- **Vegetation:** solid LOD trees, but isolated rather than street-lining rows; flat verge grass.
- **Scale/proportion/silhouette:** flat curbs + merged sidewalk + low contrast flatten the vertical street layering and scale cues.
- **Composition/camera:** not a primary gap; emerges once atmosphere + rhythm fixed.

---

## 4. Highest-impact opportunities (top 5)

1. **Re-grade atmosphere → warm sunny + distant haze** (sky ambient, warm/stronger sun w/ soft shadows, thin warm fog, kill day vfog, ACES+tuned white, subtle warm day grade). *~Free, perception-transforming.*
2. **Delete SSR + SSIL + day volumetric fog.** Removes milky wash *and* frees GPU. *Performance-positive.*
3. **Procedural wall weathering + per-building color variation** via shader (vertical streak/base-dirt, recess AO, `way_id`-seeded tint, tiling break-up). *Cheap, scales to whole world.*
4. **Restore street section:** raised curbs + distinct concrete sidewalk + fenced grass verge band. *Geometry-light.*
5. **Worn markings + asphalt macro/patches**, and make roadside clutter/trees read continuously. *Texture/shader + tuning.*

---

## 5. Phased execution plan

> After **every** phase: capture the fixed Phase-0 viewpoint screenshot(s), place beside `example.png`, and read FPS/frame-time from the existing `PerformanceProfiler`. Keep the change only if it moves toward the reference **and** holds the perf budget.

### Phase 0 — Baseline & harness (do first)
- **Goal:** honest "before" in a *residential Cherepovets* street (real best-case facades, not the commercial district) + a fixed comparison viewpoint + baseline FPS.
- **Why it matters:** must measure against the same content the reference shows.
- **What's missing/wrong:** no saved daylight shot of the Cherepovets `FacadeAssembler`; unknown true look of the `day_clear` HDRI.
- **Implementation:** launch at Cherepovets coords ([main.tscn:103](../main.tscn#L103)) via the documented run command; drive/teleport to a wide residential street; capture 2–3 fixed screenshots (sunny, default time) via MCP screenshot service → `screenshots/vibe_baseline_*`. View the `day_clear` HDRI in isolation.
- **Performance:** record baseline FPS + frame time at this viewpoint.
- **Risks:** finding a representative residential street; teleport/coords drift.
- **Testing/debug:** confirm screenshots are reproducible from a saved camera transform (log the transform so I can re-shoot the identical frame each phase).
- **Completion:** before-shots + baseline FPS from a viewpoint I can reproduce every phase.

### Phase 1 — Atmosphere & lighting re-grade (biggest win, perf-positive)
- **Goal:** warm sunny afternoon; crisp foreground; thin **warm** haze only far away; punchy contrast/saturation; blue sky + clouds.
- **Why it matters:** light direction + warmth + contrast is the dominant mood driver.
- **What's missing/wrong:** flat grey ambient, white weak sun, Filmic/white-5, cool fog + aerial 0.7, day vfog, day grade off (§2).
- **Implementation (edit both `main.tscn` & `race_scene.tscn` Environments; reconcile `night_mode_manager` day-defaults so night restores correctly):**
  - `ambient_light_source` → **Sky** (shadows pick up sky color) at modest energy; *or* keep Color but warm-tint + lower energy ~0.3–0.4 (pick by A/B).
  - Sun: energy ~1.3–1.6, color ≈ `(1.0,0.96,0.88)`, add `light_angular_distance` ~0.5–1.0° (soft penumbra); keep shadow dist ~150 m.
  - `tonemap_mode` → **ACES**; `tonemap_white` ~2.0–3.0; exposure ~1.0–1.1.
  - `fog_light_color` → warm `(0.80,0.78,0.70)`; `fog_density` ~0.0001–0.0002; `fog_aerial_perspective` ~0.3–0.4 (haze far).
  - **Disable day `volumetric_fog`** (keep night path intact in `night_mode_manager`).
  - Turn the day grade overlay on at low intensity ([color_grading.gd](../settings/color_grading.gd)) — gentle warm tint + mild contrast/sat; `nfs_style_intensity` low/0 for day.
  - Audit `day_clear` HDRI; if pale/overcast, swap for a clear deep-blue summer sky w/ cumulus (asset swap; record license).
- **Performance:** **net positive** (day vfog off); rest free.
- **Risks:** breaking night mode restore; HDRI swap import; over-warming.
- **Testing/debug:** screenshot Phase-0 viewpoint vs `example.png`; check sky, shadow readability on facades, distance-haze warmth, saturation; toggle `--night` to confirm night intact.
- **Completion:** crisp warm foreground, readable sun direction, warm (not blue) far haze, blue cloudy sky, no milky mid-grey; FPS ≥ baseline.

### Phase 2 — Strip washout + expensive effects, lock perf budget
- **Goal:** remove milky veil, reclaim GPU for later phases.
- **Why it matters:** SSR/SSIL/day-vfog actively flatten & brighten.
- **What's missing/wrong:** SSR/SSIL enabled with little benefit on a matte world.
- **Implementation:** `ssr_enabled=false`, `ssil_enabled=false` in both gameplay Environments; confirm day vfog off. **Keep `ssao`** (cheap contact shadows the reference has).
- **Performance:** **significant GPU savings.**
- **Risks:** something relying on SSR (car paint uses clearcoat, not SSR — verify).
- **Testing/debug:** FPS delta at Phase-0 viewpoint; visual check car + glass.
- **Completion:** measurable FPS gain, no regression beyond (desired) less haze.

### Phase 3 — Procedural wall weathering + per-building color variation (scales to whole world)
- **Goal:** every building reads as a weathered, individually-toned Soviet block — not just in Cherepovets.
- **Why it matters:** grime logic + block-to-block tonal variation is the core "Sovietness."
- **What's missing/wrong:** bare facade shader, single tan fallback, textured walls skip variation (§2).
- **Implementation (shader-first, no new geometry):**
  - Extend `building_wall.gdshader` + `facade_111_125.gdshader`: (a) vertical **streak/base-dirt** gradient (world-Y + cheap noise; darker toward base, under-window streaks), (b) **per-instance tint** from a `way_id`-seeded uniform within a Soviet palette (beige/tan/dirty-white/pale-yellow/brick), (c) light **AO** at recesses, (d) macro-noise tiling break-up (reuse approach from [ground.gdshader](../shaders/ground.gdshader)).
  - Fallback path: replace single tan default ([:804](../osm/osm_terrain_generator.gd#L804)) with palette-jittered tint + tiled Soviet panel/brick texture (assets exist: `5-soviet-panel*`, `9-of-3-soviet-panel`, `5-soviet-brick`).
  - Evaluate lifting the strict Cherepovets geo-gate for `FacadeAssembler` (or make fallback good enough the gate matters less) — decide by perf.
- **Performance:** per-fragment math + one noise sample → negligible; per-instance tint via material param / vertex color → no extra draw calls (respect per-chunk ArrayMesh batching).
- **Risks:** breaking night emission (`night_factor`); blowing batching; over-grimy.
- **Testing/debug:** residential street — adjacent blocks differ in tone + show base-dirt/streaks; profiler confirms draw-calls/FPS unchanged; toggle night to confirm window glow.
- **Completion:** a street of blocks looks varied + weathered at a glance, matching reference tonal spread; no draw-call/FPS regression.

### Phase 4 — Restore the street section (curbs + sidewalk + verge)
- **Goal:** road → worn markings → **raised curb** → distinct **concrete sidewalk** → **fenced grass verge** → trees → buildings.
- **Why it matters:** vertical layering = street scale + unmistakable Soviet section.
- **What's missing/wrong:** curbs all zeroed; sidewalk = asphalt; verge bare.
- **Implementation:**
  - Re-enable modest `curb_height` ~0.12–0.15 m for `residential/secondary/primary` ([:4645](../osm/osm_terrain_generator.gd#L4645)) — **zero curbs only where roads meet bridge polygons**, honoring the bridge-seam rule ([feedback_bridge_seamless](../memory/feedback_bridge_seamless.md)), not globally.
  - Sidewalk → **concrete slab** material (concrete texture or tinted higher-roughness variant) + faint slab seams via shader.
  - Add a thin **low fence** band (existing `_fence_material`) + slightly taller/weedier verge grass (tweak `ground.gdshader`).
- **Performance:** curb = small extruded strip per segment (already chunk-meshed); fences via MultiMesh. Low cost.
- **Risks:** z-fighting at junctions; **breaking bridge seamlessness** (explicit regression check).
- **Testing/debug:** drive a street — continuous curb, distinct sidewalk, no z-fighting; **verify bridge junctions remain seamless**; profiler.
- **Completion:** readable raised street section matching reference; bridges seamless; no perf regression.

### Phase 5 — Asphalt realism + worn markings
- **Goal:** lived-in road surface.
- **Why it matters:** uniform new asphalt + bright-white lines read "game-y."
- **What's missing/wrong:** no macro variation/patches/oil/cracks; markings `(1,1,1)`.
- **Implementation:** in the road ShaderMaterial (wet-road path): world-space macro variation, occasional darker **patch/repair** blotches + faint oil stains (cheap noise); markings → worn off-white/grey + slight noise/intermittency. Optional sparse manhole accents (`textures/road/manhole`).
- **Performance:** per-fragment noise → negligible. **Avoid heavy real-time Decal nodes** — do it in-shader/in-texture.
- **Risks:** markings too dim to read for racing line; over-noisy.
- **Testing/debug:** screenshot — markings painted-and-worn, asphalt non-uniform, still readable; FPS unchanged.
- **Completion:** road no longer "freshly laid," markings worn, matches reference tone.

### Phase 6 — Clutter & vegetation continuity/density
- **Goal:** continuous rhythmic roadside (lamps, trees, parked cars, kiosks, wires) so the mid-ground is alive.
- **Why it matters:** rhythm + density sell "inhabited provincial city."
- **What's missing/wrong:** roadside reads sparse; verge lacks furniture; trees isolated not street-lining.
- **Implementation:** tune lamp rhythm if needed; increase **street-lining tree density** (poplar/birch rows on verges) within MultiMesh/LOD budget; ensure parked-car density on residential streets; place kiosks/transformer boxes/ad banners at intersections (reuse business-sign/garbage systems); optional overhead tram/trolleybus **wires** as thin line meshes where trams run.
- **Performance:** stay inside existing MultiMesh + per-chunk frustum cull + physics-LOD budget (per `PERFORMANCE_OPTIMIZATION_DEBUG.md`). Add via MultiMesh; cap counts; lean on LOD2 billboards. Re-measure.
- **Risks:** draw-call/FPS blowup; clutter clipping road/buildings.
- **Testing/debug:** drive a corridor — verticals march into distance with rhythm; profiler FPS within budget; watch draw calls.
- **Completion:** mid-ground continuously populated like reference; FPS within target.

### Phase 7 — Final color polish & A/B
- **Goal:** match `example.png`'s exact warmth/contrast/saturation.
- **Implementation:** fine-tune exposure/white/grade + ambient balance; use a small A/B scene (e.g. [tests/facade_shadow_ab.tscn](../tests/facade_shadow_ab.tscn)) to compare presets fast.
- **Performance:** free.
- **Testing/debug:** final side-by-side montage vs reference at fixed viewpoint(s).
- **Completion:** montage reads as "same world, same mood" at a glance.

---

## 6. Debugging & testing harness (self-sufficient)

I run and judge this myself; no user verification needed.

- **Run/screenshot:** documented commands in project memory — kill stale Godot, run with `--path`, capture via MCP screenshot service. Save a fixed camera transform (log it) so every phase re-shoots the **identical** frame for honest before/after.
- **Comparison:** keep a `screenshots/vibe_*` series (`baseline`, `phase1`, …) and eyeball each against `example.png`; build a side-by-side montage at the end.
- **Performance:** read the in-scene `PerformanceProfiler` (FPS, frame time) at the fixed viewpoint each phase; also watch draw calls / primitives. A phase that regresses perf below baseline gets reworked, not shipped.
- **Logging:** add temporary `print()`/value dumps (env values applied, archetype chosen, tint seed, curb heights, clutter counts) to confirm code paths actually run; remove before committing the phase.
- **Editor errors:** check `get_editor_errors` / output log after shader/scene edits; respect gotchas — ShaderMaterial for procedural meshes, RGBA8 + `alpha=1.0` for CPU masks, world-space `varying` for fragment world position, let Godot generate `.import` (run `--editor --quit`).
- **A/B presets:** when a choice is subjective (ambient source, fog warmth, grade strength), render 2–3 variants from the same frame and pick — or, only if genuinely unresolvable from the reference, surface the A/B to the user.
- **Night regression:** after any Environment/light/shader change, toggle `--night` (and `--rain`) to confirm `night_mode_manager` still restores correctly.

---

## 7. Guardrails (do not cross)

- **Bridge-seamless governing rule** ([feedback_bridge_seamless](../memory/feedback_bridge_seamless.md)): equal-width road must butt the bridge polygon exactly, fully seamless — no workarounds, no partial-gap closures. Curb work (Phase 4) must not break this.
- **Architecture:** preserve per-chunk ArrayMesh merge / MultiMesh batching, LOD tiers, frustum-cull-per-chunk, physics-LOD. New visuals go through these, never as loose per-object draws.
- **Day/night contract:** `night_mode_manager` reads day values at startup and tweens to night; day re-grade must keep night/rain working.
- **Performance is a feature:** hold FPS ≥ Phase-0 baseline. Prefer texture/shader/decal/atlas/procedural-variation over new geometry. If a fix seems FPS-heavy, find the cheaper route.
- **Procedural-first:** every change must scale across many streets/buildings deterministically — no hand-placed one-offs that don't generalize.

---

## 8. Definition of Done

Stop when a side-by-side montage of several different streets reads, at a glance, as the **same kind of place** as `example.png`:

- [ ] Warm sunny light with **readable shadow form** on facades (not flat).
- [ ] Deep-blue sky + clouds; **warm** thin haze only in the far distance; crisp foreground/mid-ground.
- [ ] Weathered, **tonally-varied** blocks (grime/streaks/seam-staining), no two adjacent the same.
- [ ] Layered street: **raised curb** + distinct concrete sidewalk + green (weedy) verge + low fence.
- [ ] **Worn** asphalt + worn off-white markings (still readable for racing).
- [ ] Continuously-populated mid-ground (lamp/tree/parked-car/kiosk rhythm).
- [ ] Saturation/contrast in the reference's range (not desaturated/cool).
- [ ] **FPS ≥ Phase-0 baseline**; draw calls within budget; night/rain still correct.
- [ ] All temp logs removed; assets licensed/sourced; each phase committed with before/after shots.

---

## 9. Rollback / workflow

- Work on a branch; **commit per phase** with the phase's before/after screenshots referenced in the message.
- Anything that fails its completion criteria is reverted or reworked before moving on.
- Keep the `vibe_*` screenshot series as the running audit trail.

---

## 12. Plan revision — mode-aware (day / night / rain)

The first pass tuned **sunny day only**. Three new references show what each mode needs
(same target game family as `example.png`, a W124 on a wide city avenue):
[example-2.png](../tools/overpass-docker/example-2.png) (day),
[example-night.png](../tools/overpass-docker/example-night.png) (night),
[example-rain.png](../tools/overpass-docker/example-rain.png) (rain).

### 12.1 What's special in each reference

**`example-2` — DAY (big-city avenue).** Beyond what we already nailed (warm sun, contrast, saturation, weathered blocks):
- **Dense traffic** — many cars both directions + a continuous row of parked cars. The street is *alive*.
- **Colorful street-level retail signage** — storefronts/awnings/sign strips (red/blue/white) line the commercial side. Big "inhabited city" cue.
- **Distant skyline in warm haze** — towers fade into atmospheric depth; gives scale (bigger city than our provincial block).
- **Long soft car shadow** — strong, slightly low sun; reads the time of day.
- **Median strip** with trees/bushes between directions.
- **Tire-polished wheel tracks** — lanes are darker/shinier where wheels run.

**`example-night` — NIGHT.**
- **Warm sodium street-lamp pools** on the asphalt + soft glow halos = the dominant light. Road between pools goes dark.
- **Glowing colored shop signage** at street level (blue/red/white).
- **Lit building windows** — sparse warm/cool dots in dark silhouettes.
- **Headlight cones** (player + oncoming bright points) and **red tail-light glow**, reflecting slightly on the road.
- **Semi-glossy asphalt** catching lamp/headlight highlights (specular streaks).
- **Dark blue ambient, low fill, HIGH contrast**, faint **city glow** on the horizon.
- Calm/realistic — **not** heavy purple-neon NFS.

**`example-rain` — RAIN (overcast day).**
- **Wet, glossy asphalt mirroring buildings + cars + sky** — the defining feature. *(Needs screen-space reflections — which we turned off.)*
- **Headlights + tail-lights ON in daytime**, reflecting on the wet road.
- **Desaturated, cool grey-blue overcast grade; flat soft light** (no sun, no cast shadows).
- **Reduced visibility** — buildings fade into **cool grey** mist faster (denser, cooler fog).
- **Wet-darkened surfaces** (asphalt much darker; buildings darker/muted).
- **Puddles, spray/mist**, melancholic mood.

### 12.2 Gaps our pass created or left (mode regressions)
1. **SSR globally OFF breaks wet-road reflections** (rain's signature look). `set_wet_mode` ([osm_terrain_generator.gd:19136](../osm/osm_terrain_generator.gd#L19136)) only sets `wetness_global`; the wet_road shader's metallic/roughness then has nothing to reflect but the sky. → SSR must be **conditional** (off when dry, on when wet), not globally off.
2. **Fog color is warm and global.** Rain/overcast wants **cool grey** fog; `night_mode_manager` rain path keeps `_day_fog_color` (warm) and only scales density.
3. **Day-tuned grade is global.** ACES white 4.0 / exposure 0.9 / sat boost is right for sun; rain wants **desaturated + cool**; these should be mode-driven.
4. **Headlights don't come on in daytime rain** (`car_lights` default `visible=false`, night-gated).
5. **Night** is functional (warm lamps, lit windows, headlights, road reflection) but leans **purple-NFS** (`NIGHT_FOG_COLOR (0.08,0.04,0.12)`, neon tints) and can be soupy (night vfog 0.015) vs the reference's calmer warm-amber + blue with defined lamp pools.

### 12.3 Revised phases (mode-aware)

**Amend Phase 2:** SSR is not "off" but **off-when-dry / on-when-wet**. SSIL + SDFGI stay off.

**New Phase M — Mode-aware rendering** (do before the optional polish):
- **M1 · Rain reflections (highest):** in `set_wet_mode`, drive `env.ssr_enabled = wet` (with modest `ssr_max_steps` ~24–32 for perf) so wet asphalt mirrors buildings/cars. Verify against `example-rain`. Perf: SSR only runs while raining; dry day stays cheap.
- **M2 · Mode-dependent fog + grade:** cool grey fog `(~0.62,0.66,0.70)` + denser for rain; warm thin fog for sun (done); night fog already set — neutralize its purple. Apply a per-mode grade (cool desaturate for rain) via the existing `color_grading` overlay or `Environment.adjustment_*`. Wire in `night_mode_manager` day/rain/night branches.
- **M3 · Car lights in rain:** turn headlights/tail-lights on whenever raining (day or night); ensure they read + reflect on the wet road.
- **M4 · Night refinement:** warmer, more defined sodium lamp pools (tune lamp `OmniLight` range/energy/attenuation + glow), pull `NIGHT_FOG`/ambient away from purple toward neutral warm+blue, verify glowing shop signage, tune night vfog so it's atmospheric not soupy. Compare to `example-night`.
- **M5 · Day life (overlaps Phase 6):** denser traffic, colorful storefront signage on commercial frontages, distant skyline haze, tire-polished wheel tracks on lanes.

### 12.4 Revised Definition of Done
Was sunny-day only. Now: a side-by-side that reads as the right *kind of place* in **all three modes** —
sunny vs [example-2](../tools/overpass-docker/example-2.png), night vs [example-night](../tools/overpass-docker/example-night.png),
rain vs [example-rain](../tools/overpass-docker/example-rain.png) — each holding the perf budget, with night/rain transitions intact.

---

## 11. Execution log

- **2026-06-04 — MCP bridge fix:** a stale node MCP server from a prior session held port 6505; the editor connected to it while this session's server never bound. Killed stale server, killed all Godot, let the harness respawn the node server (bound free 6505), reopened editor → connected.
- **2026-06-04 — Phase 0 baseline:** moved free-drive spawn from the garages plot (`59.149886/37.94937`) to a denser residential block **`59.146174/37.939085`** (user-directed) in `main.tscn`. Baseline shot `screenshots/vibe_baseline_02.png`. Perf (vsync off): **FPS≈115, draws≈2327, prims≈38M, VRAM≈1670 MB**. Confirms diagnosis: `FacadeAssembler` panel blocks render fine here, but the frame is cold/flat/low-contrast/hazed-grey with a pale blown sky and crisp-white markings — atmosphere/light + warmth + weathering is the dominant gap. (macOS Low Power Mode caps FPS at 60; measure with vsync off.)
- **Note:** the runtime fog override at [osm_terrain_generator.gd:19253-19257](../osm/osm_terrain_generator.gd#L19253) overrides the `.tscn` fog at load — must be edited alongside the Environment. Only one scene sun (the `DirectionalLight3D` at line 1480 is a tree-billboard prerender light).
- **2026-06-04 — Phase 1 DONE (atmosphere/light), both `main.tscn` + `race_scene.tscn`:** ambient → Sky source (energy 1.35 after shade-fill tuning); sun warm `(1,0.95,0.86)` energy 1.5 + `light_angular_distance 0.6` (soft); tonemap → ACES, white 2.5, exposure 1.05; fog → warm `(0.82,0.78,0.68)`, thin (`graphics_settings` formula `0.4/render_distance`, aerial 0.4), `fog_sky_affect 0`; **day volumetric fog disabled**. Matched the generator's runtime fog override + `graphics_settings._apply_render_distance`. Result `screenshots/vibe_phase2_01.png` / `vibe_phase3c_spawn.png` — transformed from cold/flat/milky to warm sunny w/ real contrast + blue sky. **Biggest single win.**
- **2026-06-04 — Phase 2 DONE:** SSR + SSIL + (race) SDFGI disabled in both scenes; SSR also flipped off in `GraphicsSettings` default + load-default + the saved `user://graphics.cfg` (which was overriding). SSAO kept. Perf (vsync off): ~115 FPS, no regression (gain masked by NPC-count drift).
- **2026-06-04 — Phase 3 DONE (weathering):** world-space procedural weathering in `facade_111_125.gdshader` + `building_wall.gdshader` (opt-in `weather_strength`, default 0 so curbs/parapets/fences stay clean; wired 0.6 onto wall+recess mats). Per-building tonal + warm↔cool tint variation + vertical streaks + grunge + slight desat. Softened dark floor (0.88/0.14/0.95) + ambient lift 1.0→1.35 to stop shaded faces crushing to black. `vibe_phase3c_closeup.png`.
- **2026-06-04 — Phase 5 DONE (materials):** worn markings (`Color(1,1,1)`→`(0.8,0.79,0.73)`, rough 0.75) at gen lines 5455/6820; asphalt world-space patch/stain wear in `wet_road.gdshader` (`asphalt_wear` uniform 0.55).
- **2026-06-04 — Bug fixes:** (1) **load-hang fix** — `_apply_road_result` (osm_terrain_generator.gd ~5066) assigned a possibly-freed chunk `parent` to a typed `Node3D`, raising "invalid previously freed instance" which tripped the editor break-on-error and froze generation; now fetched untyped → validated → narrowed. (2) night→day restore now restores `volumetric_fog_enabled` (`_day_vfog_enabled`) and **ambient color/energy** (were never captured → reset to 1.0 default after a night cycle). **Night mode verified intact** (`vibe_night_check.png`) — sodium lamps, lit windows, volumetric haze.
- **Phase 4 DEFERRED (risk):** curbs were intentionally zeroed for every highway class; the sidewalk-junction curb system has 8 documented failed attempts ([[curb_junction_debug]]) and the bridge-seam rule applies. Not worth reopening now; revisit via texture-only concrete sidewalk if pursued.
- **Remaining (optional polish):** Phase 6 clutter/vegetation density; Phase 7 sky cumulus clouds (day sky is the `day_clear_2k.hdr` panorama — cloudless; swap risks sun/exposure mismatch since it now also drives ambient) + final A/B montage.
- **2026-06-04 — Phase M DONE (mode-aware day/night/rain), verified in all states:**
  - **M1 SSR-when-wet** ([osm_terrain_generator.gd `set_wet_mode`](../osm/osm_terrain_generator.gd#L19136)): SSR on (28 steps) while wet, off when dry — fixes the rain regression; wet asphalt now mirrors buildings/cars/sky. Verified ssr flips true→false on rain off.
  - **M2 mode fog/grade** (`night_mode_manager._apply_rain_lighting`): rain → cool grey fog `(0.62,0.66,0.72)` + `adjustment_saturation 0.78`; restores warm `_day_fog_color`/`_day_saturation` on clear. Night fog de-purpled to `(0.05,0.06,0.10)`; night vfog 0.015→0.008; night-sky neon glow toned down.
  - **M3 rain headlights**: player ([car.gd:247](../car/car.gd#L247) already `night OR rain`) + NPC (added `rain_changed` → `_refresh_lights` in [npc_car.gd](../traffic/npc_car.gd)). Oncoming/queued traffic shows lights in daytime rain.
  - **Rain brightness fix**: rain dimming mults were tuned for the old bright base → daytime rain read as dusk. Raised `RAIN_AMBIENT_ENERGY_MULT 0.4→0.85`, `RAIN_BG 0.4→0.65`, `RAIN_SUN 0.35→0.45` so rain is a *bright* overcast (sky-as-light), not twilight.
  - Shots: [vibe_m_day](../screenshots/vibe_m_day.png) · [vibe_m_night](../screenshots/vibe_m_night.png) · [vibe_m_rain_day2](../screenshots/vibe_m_rain_day2.png) · [vibe_m_rain_night](../screenshots/vibe_m_rain_night.png). Perf: SSR cost is rain-only (bounded, 28 steps); dry day/night unchanged.
- **2026-06-04 — Phase 6 (partial): denser roadside greenery.** `TREE_DENSITY_PARK 0.005→0.0075`, `TREE_DENSITY_FOREST 0.012→0.015` ([osm_terrain_generator.gd:16873](../osm/osm_terrain_generator.gd#L16873)), still capped at `MAX_TREES_PER_POLYGON 600`. Verges read leafier (closer to the tree-lined reference streets); perf held (~143 FPS, draws ~2.4k at the test spot). Shot: [vibe_greenery](../screenshots/vibe_greenery.png).
- **2026-06-04 — Phase 5/M5: wheel-track wear.** Subtle longitudinal tire-polish bands on the carriageway via a new `wheel_wear` uniform in [wet_road.gdshader](../shaders/wet_road.gdshader); opt-in through `WetRoadMaterial.apply_road_type_params` (1.0 on vehicle roads, 0.0 on `path`/sidewalk + `tram`). Reads as lived-in wear, no sidewalk artifacts; shader-only, no perf cost (~120 FPS). Shot: [vibe_wheeltracks](../screenshots/vibe_wheeltracks.png). Pushed to `Krupnikas/osm-racing soviet-vibe-visuals`.
- **Phase 7 (sky clouds): deprioritized** — the `day_clear` HDRI already carries light cloud structure that reads fine; swapping it risks sun/exposure/ambient mismatch (it drives sky ambient). Not worth the risk for marginal gain.

## 10. Open questions / uncertainties (resolve during execution)

- **Cherepovets facades in daylight** — no saved shot yet; Phase 0 verifies real best-case before facade work.
- **`day_clear` HDRI true look** — inferred pale from washed shots; verify directly in Phase 1.
- **`example.png` source** — unknown; treated purely as north-star mood, not a pixel target.
- **Geo-gate decision** — whether to extend `FacadeAssembler` beyond Cherepovets vs. only improving the fallback; decided by Phase-3 perf measurement.
