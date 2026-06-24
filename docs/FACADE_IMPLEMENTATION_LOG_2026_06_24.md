# Facade Implementation Log — 2026-06-24

This document records the facade work done for:

- Dubai Creek Harbour (DCH);
- Cherepovets, Sovetsky Avenue low-rise fabric;
- Cherepovets, 13 Kurmanova Street / OSM way `45119820`.

It complements:

- `docs/FACADE_ARCHETYPE_PIPELINE.md`
- `docs/DCH_PIPELINE_PROGRESS.md`
- `docs/DUBAI_CREEK_HARBOUR_FACADE_PIPELINE_PLAN.md`
- `docs/SOVETSKY_LOWRISE_FACADE_PIPELINE.md`
- `docs/KURMANOVA_13_FACADE_OVERRIDE.md`

## Runtime Changes

### `FacadeAssembler` multi-city archetype loading

File:

- `osm/facade_assembler.gd`

Implemented support for loading facade JSONs from multiple city folders through
`ARCHETYPE_DIRS`.

Currently loaded folders:

- `res://decorations/russia/cherepovets/facades/`
- `res://decorations/uae/dubai_creek_harbour/facades/`

This lets Cherepovets panel/brick/garage archetypes and DCH modern tower
archetypes coexist in one cache. Selection still filters by `category`, so DCH
`modern` archetypes do not mix with Cherepovets `panel` / `brick` / `garage`
archetypes.

### New category support

`FacadeAssembler._tag_to_category()` now supports:

- `panel` / `large_panel` -> `panel`
- `brick` -> `brick`
- `garage` -> `garage`
- `modern` -> `modern`

DCH uses synthetic `mat_tag = "modern"` in `osm_terrain_generator.gd`.

### DCH full-cell atom mode

File:

- `osm/facade_assembler.gd`

Added `atom_mode: "full_cell"` support. In this mode, a slot role such as
`mid-window`, `mid-balcony`, or `technical-louver` is rendered as the whole
cell background instead of a small alpha overlay on top of a wall.

This was needed for DCH towers because many cells are complete facade modules:
glass panels, balcony/glass units, or louver panels. Treating them as overlays
on a generic wall makes modern Gulf towers look like post-Soviet panels with
stuck-on windows.

### `technical-louver` slot

File:

- `osm/facade_assembler.gd`

Added a `technical-louver` slot for DCH crown/service-floor facade modules.

Current status:

- slot exists in runtime;
- tower-3 has a `technical-louver-1.png` atom;
- crown/vertical-zonation logic is still future work.

### Complex grouping for DCH

Files:

- `osm/facade_assembler.gd`
- `osm/osm_terrain_generator.gd`
- `osm/decorations/building_override.gd`
- `osm/decoration_layer.gd`
- `decorations/uae/dubai_creek_harbour/building_overrides.json`

DCH buildings often belong to one named development but have separate OSM ways.
The runtime now supports stable grouping through:

- `facade_group` in building overrides;
- `FacadeAssembler.complex_key(name)` fallback for named towers;
- `FacadeAssembler.select_archetype(..., group_key)`.

Effect: related towers such as Creek Gate Tower 1 and 2 can receive the same
archetype instead of random independent picks by way id.

### Floor-aware atom overrides

File:

- `osm/facade_assembler.gd`

Added `floor_atom_overrides`.

Supported zones:

- `ground`
- `middle`
- `top`
- `upper`

Resolution order:

- floor `0` checks `ground`;
- top floor checks `top`, then `upper`;
- middle upper floors check `middle`, then `upper`;
- if no override exists, the original atom category is used.

Example:

```json
"floor_atom_overrides": {
  "ground": {
    "wall": "lower-wall",
    "mid-wall": "lower-mid-wall",
    "window": "lower-window"
  },
  "upper": {
    "wall": "upper-wall",
    "mid-wall": "upper-mid-wall",
    "window": "upper-window"
  }
}
```

This is what enables:

- Sovetsky two-tone lower/upper walls;
- Sovetsky ground-floor rustication;
- red-brick upper arched windows;
- Kurmanova top white-brick/gable-window layer;
- Kurmanova entrance only on ground floor.

### `entrance` slot in `FacadeAssembler`

File:

- `osm/facade_assembler.gd`

Added slot:

```text
entrance: bg=mid-wall, overlay=entrance, width=4.8m, overlay_offset_top_px=0
```

This mirrors the 111-125 idea that an entrance atom occupies a full mid-bay
cell, but makes it available to generic JSON archetypes.

Important rule learned from Kurmanova:

- an `entrance` atom should be the same bay width as the comparable
  `mid-window` atom;
- for 4.8 m bays, the atom canvas should be `768x512`;
- the visible entrance width should be close to the visible mid-window width.

Kurmanova numbers:

- `mid-window-1.png` alpha bbox width: `673 px`;
- `entrance-1.png` alpha bbox width: `688 px`.

### Forced facade archetype by building override

Files:

- `osm/decorations/building_override.gd`
- `osm/decoration_layer.gd`
- `osm/osm_terrain_generator.gd`
- `osm/facade_assembler.gd`

Added `facade_archetype_id` / JSON key `facade_archetype`.

Example:

```json
{
  "osm_way_id": 45119820,
  "comment": "13 улица Курманова (NORTHIS)",
  "facade_archetype": "kurmanova-13-brick-commercial-1",
  "height_override": 10.5
}
```

Runtime behavior:

- `decoration_layer.gd` parses `facade_archetype`;
- `osm_terrain_generator.gd` detects forced id;
- `FacadeAssembler.get_archetype(id)` returns the resolved archetype;
- the forced archetype bypasses normal `building:material` category selection;
- the normal building shell still provides roof/foundation while
  `FacadeAssembler` replaces wall surfaces.

This is for landmark/specific buildings where the facade should match one
known way, not a generic district style.

## Dubai Creek Harbour

### Runtime archetypes

Production folders:

- `decorations/uae/dubai_creek_harbour/facades/`
- `decorations/uae/dubai_creek_harbour/gulf-residential-mid-class-tower-1-atoms/`
- `decorations/uae/dubai_creek_harbour/gulf-residential-mid-class-tower-2-atoms/`
- `decorations/uae/dubai_creek_harbour/gulf-residential-mid-class-tower-3-atoms/`

Archetypes:

- `gulf-residential-mid-class-tower-1`
- `gulf-residential-mid-class-tower-2`
- `gulf-residential-mid-class-tower-3`

Source/progress folders:

- `data/facade_pipeline/dubai_creek_harbour/generated_atoms/gulf-residential-mid-class-tower-1/`
- `data/facade_pipeline/dubai_creek_harbour/generated_atoms/gulf-residential-mid-class-tower-2/`
- `data/facade_pipeline/dubai_creek_harbour/generated_atoms/gulf-residential-mid-class-tower-3/`

### What was learned

DCH requires:

- atom inventory before generation;
- visual proportion estimation after rectification;
- `full_cell` support for many tower atoms;
- column-preserving molecules in future work;
- eventual vertical zonation for podium/body/crown;
- DCH-specific reveals/seams, not Cherepovets panel seams.

Important DCH correction:

- Do not generate an isolated window before describing all facade atoms/bays
  visible in the source facade.
- `window`, `mid-window`, `mid-balcony`, and `long-balcony` heights must be
  consistent if they occupy the same floor band.
- Podiums are a separate atom family (`podium-screen`, `podium-glazing`) and
  should not be faked as ordinary windows.

### Current caveats

- DCH body patterns are still horizontally tiled; true column-preserving
  molecules remain a follow-up.
- Podium and roof/crown zoning is documented but not implemented.
- In-engine glass material/reflection is still future work.

## Sovetsky Avenue Low-Rise Facades

Document:

- `docs/SOVETSKY_LOWRISE_FACADE_PIPELINE.md`

Reference folder:

- `/Users/alekseiaksenov/Documents/sovetsky`

Working folder:

- `data/facade_pipeline/cherepovets_sovetsky/`

General scope:

- Cherepovets, Sovetsky Avenue, house numbers `<= 86`;
- one side of Prospekt Pobedy;
- low-rise buildings only, `1-3` floors;
- signs, shop banners, pharmacy branding, plaques, and posters are excluded
  from facade atoms and should be generated later by signage/storefront systems.

### Generated Sovetsky archetypes

#### `sovetsky-lowrise-two-tone-plaster-1`

Folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-two-tone-plaster-1/`

Manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-two-tone-plaster-1.json`

Key idea:

- lower floor has ochre/yellow plaster;
- upper floors have pale cream plaster;
- implemented through `floor_atom_overrides`, not color averaging.

Important atoms:

- `lower-wall`, `lower-mid-wall`, `lower-long-wall`
- `upper-wall`, `upper-mid-wall`, `upper-long-wall`
- `window`
- `arched-window`
- horizontal belt aliases as seam atoms

#### `sovetsky-lowrise-pastel-plaster-1`

Folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-pastel-plaster-1/`

Manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-pastel-plaster-1.json`

Key idea:

- turquoise/pastel plaster;
- white historic window surrounds;
- horizontal floor belt retained;
- vertical seam is intentionally near-invisible plaster so the runtime does
  not draw false white pilasters at every bay boundary.

#### `sovetsky-lowrise-orange-commercial-plaster-1`

Folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-orange-commercial-plaster-1/`

Manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-orange-commercial-plaster-1.json`

Primary reference:

- `data/facade_pipeline/cherepovets_sovetsky/references/sovetsky-ref-04.jpg`

Key idea:

- orange historic plaster;
- commercial ground floor with two storefront windows and a central entrance;
- upper floor has three white-trimmed window bays;
- implemented with the same `mid-window / entrance / mid-window` molecule on
  all floors, while `floor_atom_overrides` turns the ground floor into
  storefronts and the upper floor into three windows;
- storefront signage and readable brand text are deliberately excluded.

#### `sovetsky-lowrise-red-brick-classic-1`

Folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-red-brick-classic-1/`

Manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-red-brick-classic-1.json`

Key idea:

- red brick wall;
- white belt/cornice;
- rectangular lower windows;
- arched upper windows via `floor_atom_overrides.upper.window = "arched-window"`.

#### `sovetsky-lowrise-cream-rusticated-plaster-1`

Folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-cream-rusticated-plaster-1/`

Manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-cream-rusticated-plaster-1.json`

Key idea:

- upper floor is smooth cream plaster;
- ground floor has shallow horizontal rustication;
- ground and upper windows differ;
- implemented through `floor_atom_overrides`.

### Sovetsky caveats

- These are pipeline/generated draft archetypes, not all installed as runtime
  production archetypes yet.
- Grey plinths are visible on several references but the generic assembler does
  not yet have a `plinth` or `foundation-band` atom slot.
- White corner quoins/rustication are visible on some references, but the generic
  assembler does not yet have a corner-only trim slot; using vertical seams for
  that would repeat quoins between every bay.
- Storefront signage is intentionally not part of the atoms.

## Kurmanova 13 / NORTHIS

Way:

- OSM way `45119820`

Reference:

- `/Users/alekseiaksenov/Documents/kurmanova.png`
- `data/facade_pipeline/cherepovets_kurmanova/references/kurmanova-13-source.png`

Production runtime folders:

- `decorations/russia/cherepovets/facades/kurmanova-13-brick-commercial-1.json`
- `decorations/russia/cherepovets/kurmanova-13-brick-commercial-1-atoms/`

Pipeline folders:

- `data/facade_pipeline/cherepovets_kurmanova/generated_atoms/kurmanova-13-brick-commercial-1/`
- `data/facade_pipeline/cherepovets_kurmanova/generated_archetypes/kurmanova-13-brick-commercial-1.json`

Building override:

- `decorations/russia/cherepovets/building_overrides.json`

Entry added:

```json
{
  "osm_way_id": 45119820,
  "comment": "13 улица Курманова (NORTHIS)",
  "facade_archetype": "kurmanova-13-brick-commercial-1",
  "height_override": 10.5
}
```

### Visual model

Kurmanova 13 is a way-specific commercial facade, not a generic Sovetsky
low-rise style.

Recognized atoms:

- red brick wall;
- white/silicate brick wall;
- brown wide three-pane `mid-window`;
- triangular brown gable window group;
- full-width commercial `entrance`;
- dark/light horizontal seam/belt;
- dark roofbottom/eaves over white brick.

### The corrected window atom

The first generated window was wrong because it had:

- a top transom/fortochka;
- two main panes;
- ordinary `window` proportions.

The corrected atom is:

- `mid-window-1.png`
- `768x512`
- three vertical panes;
- no top transom;
- alpha bbox `(47, 38, 720, 474)`;
- visible width `673 px`.

### Entrance atom

The first entrance attempt was too narrow compared with the window. The final
atom is:

- `entrance-1.png`
- `768x512`
- full-width mid-bay commercial entrance;
- side glass panels plus central doors;
- NORTHIS sign drawn locally for readable text;
- alpha bbox `(40, 28, 728, 490)`;
- visible width `688 px`.

The entrance and mid-window now occupy the same facade bay.

### Floor overrides

The Kurmanova archetype uses one molecule with `mid-window / entrance /
mid-window`, then remaps categories by floor:

- ground:
  - red brick walls;
  - center slot is `entrance`;
- middle:
  - red brick walls;
  - `entrance` category remaps to `mid-window`, so the entrance does not repeat;
- top:
  - white brick walls;
  - `mid-window` remaps to `gable-window`;
  - `entrance` remaps to missing category `none`, so the center slot disappears.

This is a pragmatic approximation of the photo: it captures red/white brick,
wide brown windows, triangular upper windows, and the NORTHIS entrance without
needing a full custom mesh.

### Kurmanova caveats

- The real roof/gable geometry is more complex than a flat facade atom stack.
- AC units, streetview arrows, people, bicycles, posters, and incidental
  objects were intentionally excluded.
- This is a forced way-specific facade. It should not be used as a random
  district archetype.

## Verification Performed

For the current implementation pass:

- JSON validation passed for new archetype files and `building_overrides.json`.
- PNG size validation passed for Kurmanova runtime atoms.
- `godot --headless --path . --check-only --quit` exited with code `0`.

Known recurring non-fatal output:

- Godot prints a resource leak warning on exit. This appeared before and does
  not indicate a syntax failure in the facade changes.

## Follow-Ups

- Add a generic `plinth` / `foundation-band` slot for historic low-rise facades.
- Add true podium/body/crown vertical zonation for DCH towers.
- Add column-preserving molecule support for DCH.
- Decide which generated Sovetsky draft archetypes should be promoted into
  `decorations/russia/cherepovets/facades/`.
- Add in-engine glass material/reflection support for modern DCH facades.
