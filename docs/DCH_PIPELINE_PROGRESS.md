# DCH Facade Pipeline — Progress & Findings Log

Living record of the Dubai Creek Harbour photo-driven facade pipeline: decisions,
what works, **dead-ends to NOT repeat**, the corrected approach, and the atom spec.
Companion to [DUBAI_CREEK_HARBOUR_FACADE_PIPELINE_PLAN.md](DUBAI_CREEK_HARBOUR_FACADE_PIPELINE_PLAN.md)
and [DCH_FACADE_PRIOR_ART.md](DCH_FACADE_PRIOR_ART.md).

Implementation summary for the DCH/Sovetsky/Kurmanova facade runtime pass:
[FACADE_IMPLEMENTATION_LOG_2026_06_24.md](FACADE_IMPLEMENTATION_LOG_2026_06_24.md).

---

## ★ HEADLINE FINDING (2026-06-23) — the approach correction

**Local auto-extraction (segmentation + SAM + SDXL img2img) does NOT produce usable
isolated atoms from casual phone photos.** It yields rotated, non-isolated facade
fragments. Root cause is the **wrong class of model**:

- **SDXL img2img is strength-based "repaint the input"** — it CANNOT rectify perspective,
  isolate a single element, remove the background, or reframe. It is fundamentally the
  wrong tool for "turn this crooked photo into a clean isolated front-on atom".
- The CORRECT tool is an **instruction-following image-EDIT model** — given the crooked
  photo + a specific per-atom instruction, it rectifies + isolates + cleans + reframes in
  one shot. This matches the project's **original manual atom-authoring workflow**
  (screenshot → image generator → clean rectangular atom; see FACADE_ARCHETYPE_PIPELINE.md).

**Capable instruction-edit models:** GPT-image-1 (OpenAI, supports transparent output),
Gemini image ("nano-banana"), FLUX.1 Kontext, Qwen-Image-Edit.

**Why we can't just run it here:** Claude has no image-gen tool, and the local stack is
plain SDXL (not instruction-following). Execution must be one of:
- **(A)** user runs the per-atom prompts in their own image-AI (zero infra; the proven manual route);
- **(B)** a hosted edit API (OpenAI / fal / Replicate) — needs an API key + budget; then we script the full photo→atom-pack run;
- **(C)** a local instruction-edit model (FLUX Kontext / Qwen-Image-Edit) — large download, heavy on MPS.

---

## ✅ RUNTIME APPLIED (2026-06-23) — 3 archetypes live & verified in-engine
Prepared atom packs (made externally via the instruction-edit route) were wired through FacadeAssembler.
Verified in DCH free-roam: `_facade_city='dubai_creek_harbour'`, **44 FacadeAssembler meshes**, all DCH atoms
(tower-1 ×22, tower-3 ×13, tower-2 ×9); cache holds Cherepovets + 3 gulf archetypes, no cross-mix. Towers read
as modern Gulf glass / graphite-banded mega-frame — not Cherepovets panels; columnar; full-cell. Screenshots:
`docs/dch_overview.png`, `dch_tower2.png`, `dch_tower3.png`.

Built:
- Atoms → `decorations/uae/dubai_creek_harbour/gulf-residential-mid-class-tower-{1,2,3}-atoms/` (imported).
- 3 archetype JSONs (`category: modern`; `atom_mode`: tower-1 `overlay` RGBA full-size offset 0, tower-2/3
  `full_cell` opaque atom = whole-cell bg).
- `facade_assembler.gd`: `ARCHETYPE_DIRS` multi-dir load, `_tag_to_category("modern")`, `technical-louver`
  slot, `atom_mode:"full_cell"`, **`complex_key()` + `select_archetype(...,group_key)`** (same complex → same archetype).
- `osm_terrain_generator.gd`: `_detect_facade_city()` from REAL `osm_data.center_lat/lon`, `_facade_city`,
  facade gate uses it, DCH→`mat_tag="modern"` + `group_key`. Cherepovets branch unchanged (preserved by construction).
- `building_override.gd` + `decoration_layer.gd`: `facade_group` field. `index.json`: DCH source.

**Same-complex grouping (towers of one development share an archetype):** selection hashes a *complex key*,
not `way_id`. Key = explicit `facade_group` in the building override (DCH towers are OSM-unnamed, so we set it:
Creek Gate T1/T2→`creek_gate`, Creek Horizon T1/T2→`creek_horizon`, Cove 1/2→`the_cove`), else `complex_key(name)`
(strips trailing "Tower N / Building N / North-South"). Headless-verified: both Creek Gate towers → same archetype,
both Creek Horizon → same.

Caveats (non-blocking, follow-up): full_cell stretches the atom to the slot (tower-3 balcony 3.2 m→4.8 m, ~+50%);
non-archetype DCH buildings + some ground polygons show the generic missing-texture checker (pre-existing fallback
outside Cherepovets, not the pack); deferred render-side tasks: vertical zonation (podium/body/crown), in-engine
glass reflection, `technical-louver` crown molecule (reserved in `_future_crown_molecules`).

## Target atom format (confirmed from `decorations/russia/cherepovets/default-panels-atoms`)
Atoms are CLEAN, hand-authored-quality, ISOLATED components — not photo crops.

| Role | Size (px) | Mode | Content |
|---|---|---|---|
| `wall` / `mid-wall` / `long-wall` | 512×512 / 768×512 / 1024×512 | **RGB opaque** | flat material, **NO openings**, tileable |
| `window` / `mid-window` | 320×320 / 480×320 | **RGBA (alpha)** | single window+frame, **isolated on transparent** |
| `mid-balcony` / `long-balcony` | 700×512 / 1024×512 | **RGBA** | balcony unit, isolated on transparent |
| seams | 30×572, 512/768/1024×30 | RGB | thin seam strips |

Grid law: **160 px/m horizontally, 512 px = one floor.** (see FACADE_ARCHETYPE_PIPELINE.md)

---

## Corrected pipeline (per-atom, instruction-edit driven)
1. **Input**: owned/curated DCH photos (any rights for a pet-project; keep atoms generic; record provenance).
2. **Bay/atom inventory first**: before generating anything, inspect the facade photo and name the
   actual bays/atoms present (`wall`, `window`, `mid-window`, `mid-balcony`, `long-balcony`,
   `seam`, `podium-screen`, `podium-glazing`, `crown`, etc.) plus their approximate proportions
   inside the 512 px floor/bay grid.
   Do not let the image model invent a generic glazing proportion.
3. **Generate (per atom)**: feed ONE photo + a SPECIFIC instruction prompt to an instruction-edit
   model → clean, rectified, isolated atom (transparent bg, or magenta bg if the model lacks alpha).
4. **Local post (lightweight, no NN)**: chroma-key `#FF00FF` → alpha; exact resize to the spec size;
   seamless/tiling check for walls.
5. **Validate** against the atom format, measured bay proportions, and cross-atom family alignment:
   `window`, `mid-window`, and `mid-balcony` visible heights should agree because they occupy the
   same floor band. Then write the archetype JSON.
6. **Runtime selection + render-side** → atoms appear in-game.

Drafted per-atom prompts (ready to run on our photos): see "Per-atom prompts" below.

---

## Dead-ends — do NOT repeat
- ❌ **SDXL img2img for atoms** — only repaints; can't rectify/isolate/reframe. Output = rotated, non-isolated fragments.
- ❌ **CMP SegFormer (`Xpitfire/...`) on modern glass towers** — noisy; **misses glass balconies** (CMP = European masonry); glass curtain walls partly read as "background". Usable only as a rough ROI hint, never a clean mask.
- ❌ **chsasank vanishing-point rectification on cluttered shots** — works when the facade fills the frame, but foreground (pool/loungers/water) injects spurious lines → over-skew.
- ❌ **GroundingDINO-tiny box selection** — low confidence on facade parts; tends to return whole-facade boxes, not single window/balcony units.
- ❌ **Naive center-crop ROI** — grabs the wrong content (asked for "wall", got a balcony).
- ⚠️ **EXIF orientation** — phone photos are stored sideways; must `ImageOps.exif_transpose` on load (and an instruction-edit model handles rotation anyway).

---

## What works / verified
- Local SDXL **runs** on M5 Pro / MPS (~18 s/img) — but wrong tool for atoms (see above).
- GroundingDINO + SAM + CMP SegFormer all load & run (SAM must run on **CPU** — MPS lacks float64).
- Keyless Stage 0 collection runs end-to-end (boundary, 648 buildings via skrup, imagery+license).
- **Imagegen attempt 1 on `creek-5` nearly worked conceptually**: it isolated/redrew one window on
  magenta, but the model invented the wrong proportion (too tall/narrow). Takeaway: after
  perspective correction, measure/estimate the bay ratio before generation. For the small `creek-5`
  window bay, the visible window is roughly **9:10 width:height**, fills almost the full floor
  height, and uses about **90% of the bay width**. A good target is a square 512×512 overlay canvas
  with the visible window about 460 px wide and almost 512 px tall, not a 320×420 tall-slit atom.
- **Cross-atom height consistency is mandatory**: on the same facade/floor, the visible `window`
  height and visible `mid-balcony` glazing/balcony height must match closely. A window taller than
  the balcony looks wrong because they are in the same floor band. Current first-pass metrics:
  `mid-window-1` visible height ≈ 428 px, `mid-balcony-1` ≈ 426 px, but `window-1` ≈ 456 px.
  Therefore `window-1` remains only a candidate and should be regenerated or resized so its visible
  bbox height matches the balcony/window family before promotion.
- **`creek-5` reveals a new archetypal podium atom family**: the large brown-grey gridded podium
  screen is not a window, balcony, wall, or roofbottom. It should become planned roles such as
  `podium-screen` and `podium-glazing`, used by vertical zonation/podium floors. Do not generate it
  in the first minimal residential-body archetype, but do not fold it into `window` or `wall`.
- **DCH does have seams/joints, but not Cherepovets panel seams**. The visible facade has thin
  architectural reveal lines and bay-grid joints between beige cladding/slab modules. Treat these as
  a DCH-specific `architectural-reveal` / `bay-joint` seam family, not rusty/painted panel seams.
  First minimal archetype may keep them baked subtly into wall/window/balcony atoms or add thin
  neutral seam atoms later; avoid `has_seams=true` with post-Soviet seam textures.

## Archetype Naming Decision

The three prepared DCH residential tower packs are independent archetype
varieties, not just temporary photo-derived variants:

- `gulf-residential-mid-class-tower-1` — source-derived from `creek-5`.
- `gulf-residential-mid-class-tower-2` — source-derived from `creek-1`.
- `gulf-residential-mid-class-tower-3` — source-derived from `creek-7`.

The `creek-*` names remain only as provenance/reference-photo labels. Runtime
archetype IDs and atom-pack folders should use the `gulf-residential-mid-class`
names.

## Molecule Inventory From The Three Source Facades

Molecule inventory is mandatory after atom inventory. The source facade tells us
which horizontal/vertical bay combinations actually exist; otherwise we only have
a pile of atoms and the runtime may assemble a facade that never occurs in the
reference fabric.

Important runtime caveat:

- Current facade JSON molecules are horizontal slot lists chosen per floor/edge.
- The DCH tower sources are strongly **columnar**: balcony stacks, glass strips,
  service-wall strips, and louver crowns should stay vertically aligned for many
  floors.
- Therefore these molecules should be treated as **column-preserving body
  patterns**. If the current assembler randomizes a different molecule every
  floor, DCH towers will look wrong even if the atoms are good.
- For `full_cell` atoms, the molecule slot is the visible cell itself. It should
  not be rendered as a small overlay on top of a wall background.

### `gulf-residential-mid-class-tower-1` molecules (`creek-5`)

Visual read:

- Warm beige grid with mixed narrow windows, wider glazing bays, stacked glass
  balconies, and occasional longer balcony/loggia cells.
- Residential body is a varied but still regular grid; podium-screen/glazing is
  a separate lower-zone system, not a body molecule.

Body molecules:

```json
[
  {
    "id": "t1-window-midbal-window",
    "slots": ["window", "mid-balcony", "window"],
    "tags": ["any"],
    "notes": "Narrow residential windows flanking a stacked balcony bay."
  },
  {
    "id": "t1-midwin-midbal-midwin",
    "slots": ["mid-window", "mid-balcony", "mid-window"],
    "tags": ["any"],
    "notes": "Wide glazing bays around a balcony stack; common upper-body rhythm."
  },
  {
    "id": "t1-window-midwin-midbal-window",
    "slots": ["window", "mid-window", "mid-balcony", "window"],
    "tags": ["long"],
    "notes": "Mixed narrow/wide glazing with one balcony bay."
  },
  {
    "id": "t1-longbal-midwin-window",
    "slots": ["long-balcony", "mid-window", "window"],
    "tags": ["long"],
    "notes": "Wider balcony/loggia moment plus adjacent glazing."
  }
]
```

Postponed lower-zone molecules:

```json
[
  {
    "id": "t1-podium-screen-row",
    "slots": ["podium-screen", "podium-screen", "podium-screen"],
    "tags": ["podium"],
    "notes": "Requires new podium-screen slot/zone; do not fake as windows."
  },
  {
    "id": "t1-podium-glazing-screen",
    "slots": ["podium-glazing", "podium-screen", "podium-glazing"],
    "tags": ["podium"],
    "notes": "Ground/podium amenity glazing plus brown-grey screen grid."
  }
]
```

### `gulf-residential-mid-class-tower-2` molecules (`creek-1`)

Visual read:

- Tall pale tower with strong vertical strips: blue-grey glass curtain-wall
  columns, stacked balcony columns, and pale cladding/service-core strips.
- The facade should read as vertical bands. Do not shuffle balcony/window
  columns independently on every floor.

Body molecules:

```json
[
  {
    "id": "t2-glass-balcony-glass",
    "slots": ["mid-window", "mid-balcony", "mid-window"],
    "tags": ["any"],
    "notes": "Primary Creek-1 rhythm: glass strip, balcony stack, glass strip."
  },
  {
    "id": "t2-glass-wall-balcony-glass",
    "slots": ["mid-window", "wall", "mid-balcony", "mid-window"],
    "tags": ["long"],
    "notes": "Adds a pale cladding/core pier between glass and balcony columns."
  },
  {
    "id": "t2-glass-balcony-wall-balcony-glass",
    "slots": ["mid-window", "mid-balcony", "wall", "mid-balcony", "mid-window"],
    "tags": ["long"],
    "notes": "Symmetric tower-body rhythm with central pale vertical pier."
  },
  {
    "id": "t2-glass-wall-glass",
    "slots": ["mid-window", "wall", "mid-window"],
    "tags": ["any"],
    "notes": "Curtain-wall strip interrupted by pale service/cladding pier."
  }
]
```

Optional edge/side molecules:

```json
[
  {
    "id": "t2-balcony-stack",
    "slots": ["mid-balcony"],
    "tags": ["any"],
    "notes": "Use only if the assembler can lock this as a vertical column."
  },
  {
    "id": "t2-glass-strip",
    "slots": ["mid-window"],
    "tags": ["any"],
    "notes": "Use only if the assembler can lock this as a vertical strip."
  }
]
```

### `gulf-residential-mid-class-tower-3` molecules (`creek-7`)

Visual read:

- White mega-frame grid with graphite bands.
- One-floor full-cell windows and balconies.
- A large blind/service-wall bay on one side.
- Upper floor/crown has dark technical louvers; this is a real archetypal role,
  not a normal residential window.

Body molecules:

```json
[
  {
    "id": "t3-window-window-balcony-servicewall",
    "slots": ["window", "window", "mid-balcony", "mid-wall"],
    "tags": ["long"],
    "notes": "Primary Creek-7 read: two residential columns, one balcony column, one blind/service-wall bay."
  },
  {
    "id": "t3-window-balcony-window-servicewall",
    "slots": ["window", "mid-balcony", "window", "mid-wall"],
    "tags": ["long"],
    "notes": "Variant where the balcony stack moves one bay left/right inside the mega-frame."
  },
  {
    "id": "t3-window-window-window-servicewall",
    "slots": ["window", "window", "window", "mid-wall"],
    "tags": ["long"],
    "notes": "Residential row with no balcony in the visible body band."
  },
  {
    "id": "t3-balcony-window-balcony-servicewall",
    "slots": ["mid-balcony", "window", "mid-balcony", "mid-wall"],
    "tags": ["long"],
    "notes": "Denser balcony-stack variant; use sparingly."
  }
]
```

Upper/service-zone molecule:

```json
[
  {
    "id": "t3-louver-louver-louver-servicewall",
    "slots": ["technical-louver", "technical-louver", "technical-louver", "mid-wall"],
    "tags": ["crown", "service"],
    "notes": "Requires a new `technical-louver` slot/zone. Do not fake this as a normal window."
  }
]
```

Frame/seam note:

- `tower-3` can either bake white mega-frame edges into the full-cell atoms or
  use separate `vertical-frame`/`horizontal-frame` seam atoms. Do not apply both
  strongly at once, or the facade will become over-gridded.

## `gulf-residential-mid-class-tower-1` (`creek-5`) facade atom inventory

Generate the first residential-body archetype from these roles only:

- `wall`: warm beige / light sand cladding, opaque, no openings; subtle vertical/horizontal reveal
  lines may be baked lightly, but no rusty panel seams.
- `window`: small almost-square residential glazing bay; visible module approx 9:10 width:height,
  nearly full floor height, about 90% of bay width; alpha overlay, target 512×512 proof canvas.
  Its visible bbox height must match the `mid-window`/`mid-balcony` family height, not exceed it.
- `mid-window`: wider blue-green glazing bay, usually 1.5 bays or a wider central strip; alpha
  overlay, target likely 768×512 proof canvas after measuring.
- `mid-balcony`: balcony bay with beige slab, glass/metal rail, and blue-green glazing behind; alpha
  overlay, target 700×512 or 768×512.
- `long-balcony`: longer balcony/terrace strip across two bays; alpha overlay, target 1024×512.
- `architectural-reveal` / `bay-joint`: thin beige shadow lines between cladding modules and floor
  slabs; not generated first unless the body looks too flat.

Documented but postponed:

- `podium-screen`: brown-grey gridded podium ventilation/privacy screen, new planned role.
- `podium-glazing`: large lower-floor storefront/amenity glazing, new planned role.
- `roofbottom` / `soffit`: beige horizontal roof/podium underside band with small square soffit
  details; postponed for the first atom generation pass.

Generated artifacts:

- Folder: `data/facade_pipeline/dubai_creek_harbour/generated_atoms/gulf-residential-mid-class-tower-1/`.
- `wall-1.png` 512x512 RGB.
- `mid-wall-1.png` 768x512 RGB.
- `long-wall-1.png` 1024x512 RGB.
- `window-1.png` 512x512 RGBA candidate; should be regenerated/resized before runtime promotion.
- `mid-window-1.png` 768x512 RGBA.
- `mid-balcony-1.png` 700x512 RGBA.
- `long-balcony-1.png` 1024x512 RGBA.
- QA sheets:
  - `gulf-residential-mid-class-tower-1_atoms_contact_sheet.png`.
  - `wall_series_contact_sheet.png`.

## `gulf-residential-mid-class-tower-2` (`creek-1`) facade atom pass

Source:

- Original photo: `~/Documents/creek/creek-1.jpg`.
- Working crop: `data/facade_pipeline/dubai_creek_harbour/references/working/creek-1-central-tower-body.jpg`.

Visual inventory before generation:

- `wall`: pale cream/off-white modern tower cladding, larger rectangular panel grid, subtle dust and
  sun fading; opaque wall atoms keep the same grid rhythm across `wall`, `mid-wall`, and `long-wall`.
- `mid-window`: tall/wide blue-grey curtain-wall bay with slim mullions and large reflective panels.
  In `creek-1` this is a **full-cell atom**, not a small transparent overlay: the glazing bay
  occupies the full vertical and horizontal extent of its image cell.
- `mid-balcony`: single stacked balcony bay with pale slab above/below, side returns, glass railing,
  and reflective blue-grey doors behind. In `creek-1` this is also a **full-cell atom**, not an
  alpha overlay: the balcony module fills its rectangular image cell.
- `long-balcony`: not primary for this photo; do not invent it for the minimal Creek-1 pass.
- `architectural-reveal` / `bay-joint`: present as thin modern reveal lines in cladding/slabs, not
  post-Soviet rusty seams.
- Podium/crown details are postponed.

Generated artifacts:

- Folder: `data/facade_pipeline/dubai_creek_harbour/generated_atoms/gulf-residential-mid-class-tower-2/`.
- `wall-1.png` 512x512 RGB.
- `mid-wall-1.png` 768x512 RGB.
- `long-wall-1.png` 1024x512 RGB.
- `mid-window-1.png` 768x512 RGB full-cell atom; generated from alpha candidate bbox
  `(85, 40, 680, 471)`, then stretched to fill the whole cell.
- `mid-balcony-1.png` 700x512 RGB full-cell atom; generated from alpha candidate bbox
  `(73, 37, 627, 466)`, then stretched to fill the whole cell.
- `horizontal-seam-1.png` 512x30 RGB.
- `horizontal-mid-seam-1.png` 768x30 RGB.
- `horizontal-long-seam-1.png` 1024x30 RGB.
- `vertical-seam-1.png` 30x572 RGB.
- QA sheets:
  - `wall_series_contact_sheet.png`.
  - `gulf-residential-mid-class-tower-2_atoms_contact_sheet.png`.
  - `gulf-residential-mid-class-tower-2_molecule_sanity_preview.png`.

Important outcome:

- Cross-atom height gate passed on the intermediate alpha candidates: `mid-window` visible height was
  `431 px`, `mid-balcony` visible height was `429 px`. They were then promoted to opaque full-cell
  atoms because Creek-1 bays fill their cells vertically and horizontally.
- Automation takeaway: after the visual inventory step, classify each role as either `overlay` or
  `full_cell`. Do not blindly make every window/balcony alpha. Modern curtain-wall towers often need
  full-cell window/balcony atoms.
- The seam/reveal images are only candidates. They are format-compatible with the existing seam
  categories, but semantically they represent clean architectural reveals. Use them only if baked
  wall joints are not enough in-engine.
- The balcony has a slightly wider visual slab than the window, which is acceptable for this DCH
  subtype because Creek-1 balconies project as slab boxes while curtain-wall strips remain flatter.

## `gulf-residential-mid-class-tower-3` (`creek-7`) facade atom pass

Source:

- Original photo: `~/Documents/creek/creek-7.jpg`.
- Copied reference: `data/facade_pipeline/dubai_creek_harbour/references/owned_uploads/creek-7.jpg`.
- Working crop: `data/facade_pipeline/dubai_creek_harbour/references/working/creek-7-main-facade.jpg`.

Visual inventory before generation:

- `wall` / `service-wall`: light grey blind/service facade bay with fine vertical panel grooves and
  dark horizontal belt bands. This is closer to a modern service-core wall than the pale Creek-1
  cladding.
- `window`: opaque **one-floor full-cell** residential window bay; grey/white side cladding, dark
  graphite horizontal bands, blue-grey glass, deep recess shadows. No alpha. The image edges must be
  the edges of one floor/cell; neighboring floors must not be visible at the top or bottom.
- `mid-balcony`: opaque **one-floor full-cell** balcony bay; dark graphite slab/band, glass railing,
  recessed blue-grey doors, light grey side cladding. No alpha. The image edges must be the edges of
  one floor/cell; neighboring floors must not be visible at the top or bottom.
- `technical-louver` / `roofscreen`: dark horizontal louver screen in a white rectangular frame.
  This is a distinct upper-zone atom, not a normal window/balcony.
- `vertical-frame` / `horizontal-frame`: strong white mega-frame strips with dark contact shadows.
  Semantically these are structural frame separators, not Cherepovets seams.

Generated artifacts:

- Folder: `data/facade_pipeline/dubai_creek_harbour/generated_atoms/gulf-residential-mid-class-tower-3/`.
- `wall-1.png` 512x512 RGB.
- `mid-wall-1.png` 768x512 RGB.
- `long-wall-1.png` 1024x512 RGB.
- `window-1.png` 512x512 RGB one-floor full-cell atom.
- `mid-balcony-1.png` 512x512 RGB one-floor full-cell atom.
- `technical-louver-1.png` 512x512 RGB candidate for a future upper/crown zone.
- `horizontal-seam-1.png` 512x30 RGB candidate frame strip.
- `horizontal-mid-seam-1.png` 768x30 RGB candidate frame strip.
- `horizontal-long-seam-1.png` 1024x30 RGB candidate frame strip.
- `vertical-seam-1.png` 30x572 RGB candidate frame strip.
- QA sheets:
  - `gulf-residential-mid-class-tower-3_atoms_contact_sheet.png`.
  - `gulf-residential-mid-class-tower-3_molecule_sanity_preview.png`.

Important outcome:

- Creek-7 reinforces the `full_cell` rule: window and balcony atoms should occupy their whole image
  cells; alpha overlays would be wrong for this facade subtype. Correction from QA: `full_cell`
  means exactly one floor/cell from edge to edge, not a crop that includes slivers of neighboring
  floors above or below.
- The initial `window`/`mid-balcony` generated candidates leaked neighboring floors at the top edge.
  They were fixed with a deterministic one-floor crop/stretch. The pre-fix versions are retained
  only for audit in `sources/*-pre-floor-crop.png`.
- The white mega-frame is a major part of the look. Current assets intentionally keep both options:
  some frame rhythm is baked into full-cell atoms, and separate frame/seam candidates also exist.
  Runtime composition should avoid applying both too strongly at once.
- `technical-louver` should be treated as planned zonation support. It belongs to the upper/service
  zone and should not be folded into normal residential molecules.

## Conditioning-input reality
- **Clean CC0/CC-BY DCH facade photos ≈ 0** (Wikimedia/Openverse = birds/skylines; categories empty).
- Listing photos (Propsearch/PropertyFinder) are **interior-heavy**; few facade elevations.
- **Best input = owned on-site photos** — 23 in `~/Documents/creek` → `references/owned_uploads/` (HEIC→jpg via `sips`).
  Curated per-role: wall=IMG_3988/9270/6488, window=IMG_3989/0160, balcony=IMG_8576/0439, crown=IMG_0021/9831.
- **Licensing = pet-project**: any photo OK for conditioning; keep atoms generic (no logos/branding); record provenance.

## Floor data
- 648 buildings, only **26 named**, ~13 actual DCH residential towers; **96% lack `building:levels`**.
- 68-building floor inventory → `research/dch_building_inventory.json`.
- 7 named-tower `osm_way_id` height overrides → `decorations/uae/dubai_creek_harbour/building_overrides.json`
  (`height_override = floors*3.2`; **dormant** until runtime selection lands).
- 622 anonymous footprints can't be per-building googled → need a **floor-safety default** (render-side),
  full accuracy needs spatial-match with better coords (not feasible from current data).

## Environment (verified)
- M5 Pro / Metal 4, 621 GB free. venv: `tools/facade_pipeline/.venv`.
- torch 2.8 (MPS), opencv 4.13, diffusers 0.36, transformers, scikit-image, Pillow, numpy.
- Cached (~10–15 GB HF): SDXL base, grounding-dino-tiny, sam-vit-base, CMP SegFormer.
- Keyless net OK (Nominatim/Wikimedia/Openverse/skrup). **No API keys** for any hosted image model.

## NOT started — the real in-game blocker
DCH renders nothing until the **runtime side** exists (pure GDScript, fully verifiable in-engine):
- `FacadeArchetypeRegistry`: active decoration source by location; non-hardcoded `ARCHETYPES_DIR`;
  replace `_is_cherepovets_location()` (`return _decoration_layer != null` — latent bug). Shared with Antalya.
- Vertical zonation (podium/body/crown) so 30–80-floor towers don't stack one molecule per floor.
- In-engine glass material (reflection), floor-safety default for the 622 anonymous footprints.

---

## Per-atom prompts (instruction-edit model; attach the photo as input)
**wall** (input `IMG_3988.JPG`): "Generate a seamless, perfectly tileable flat wall texture of the
building's pale off-white concrete and light stone cladding. Front-on orthographic, evenly lit, NO
windows, NO balconies, NO glass, no perspective, no sky/people/foreground. Clean 512×512 square,
tiles seamlessly, opaque."

**window** (input `IMG_3989.jpg`/`IMG_0160`; for `creek-5` small window use the measured bay ratio):
"Extract ONE single window/glazing module, redraw clean and front-on (de-skew perspective). Before
drawing, preserve the source bay proportion: for `creek-5` small windows the visible module is roughly
9:10 width:height, fills almost the whole floor height, and uses about 90% of the bay width. Isolated
on a fully transparent background (PNG alpha) or pure magenta fallback — only the window and its frame,
everything else transparent. Modern DCH glazing, blue-green tinted glass, slim dark mullions, pale slab
edges. Centered, crisp, orthographic. Do NOT turn it into a narrow tall storefront-like slit."

**balcony** (input `IMG_8576.JPG`): "Extract ONE single balcony unit, redraw clean and front-on.
Isolated on transparent background (PNG alpha) — glass balcony railing with slim dark metal frame +
pale concrete slab; everything else transparent. Centered, orthographic, crisp."

Alpha fallback: if the model can't output transparency, append "on a solid pure magenta #FF00FF
background" and we chroma-key locally.

## Key files
- Plan: `docs/DUBAI_CREEK_HARBOUR_FACADE_PIPELINE_PLAN.md` · Prior art: `docs/DCH_FACADE_PRIOR_ART.md`
- Pipeline code: `tools/facade_pipeline/facade_pipeline/` (cli.py=Stage0; gen_proof/extract_generate/seg_*=local attempts kept for reference)
- Artifacts: `data/facade_pipeline/dubai_creek_harbour/` (research/, references/owned_uploads/, generated_atoms/v1,v2)
- Runtime targets: `osm/facade_assembler.gd`, `osm/osm_terrain_generator.gd` (facade hook ~10445), `osm/decorations/building_override.gd`
