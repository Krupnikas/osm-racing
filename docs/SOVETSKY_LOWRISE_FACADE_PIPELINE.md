# Sovetsky Avenue Low-Rise Facade Pipeline

Scope: Cherepovets, Sovetsky Avenue, buildings with street numbers `<= 86` on
the selected side of Prospekt Pobedy. Only low-rise buildings are in scope:
`1-3` floors.

Reference folder:

- `/Users/alekseiaksenov/Documents/sovetsky`

Working assets:

- `data/facade_pipeline/cherepovets_sovetsky/references/`
- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/`
- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/`

Related implementation summary:

- `docs/FACADE_IMPLEMENTATION_LOG_2026_06_24.md`

Important rule: **signage is not part of these facade archetypes**. Shop signs,
pharmacy banners, logos, sale posters, and brand colors are ignored during atom
generation. They should be applied later by the existing/future signage or
storefront algorithm.

## Source Contact Sheet

The 13 source screenshots were normalized into:

- `data/facade_pipeline/cherepovets_sovetsky/references/sovetsky_source_contact_sheet.png`

The relevant low-rise visual fabric is:

- two-storey plaster buildings with different lower/upper wall colors;
- pastel painted plaster buildings with white window surrounds;
- red brick historic buildings with white decorative trim;
- strong horizontal cornices and floor belts;
- rectangular first-floor windows and arched/decorative second-floor windows;
- occasional ground-floor shops, but signage is excluded from the archetype.

## Proposed Archetypes

### `sovetsky-lowrise-two-tone-plaster-1`

Primary references:

- `sovetsky-ref-03.jpg`
- `sovetsky-ref-05.jpg`
- supporting: `sovetsky-ref-01.jpg`, `sovetsky-ref-06.jpg`,
  `sovetsky-ref-10.jpg`, `sovetsky-ref-13.jpg`

Look:

- lower floor: warm ochre / golden yellow plaster;
- upper floor: pale cream / light warm yellow plaster;
- white plaster window surrounds, pilasters, floor belt, and cornice;
- grey stone/plaster plinth possible, but not required in first body pass;
- 2 floors are the main target; 3 floors can reuse upper-floor treatment for
  floors 1-2.

Generated atom folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-two-tone-plaster-1/`

Generated atoms:

- `lower-wall-1.png` `512x512 RGB`
- `lower-mid-wall-1.png` `768x512 RGB`
- `lower-long-wall-1.png` `1024x512 RGB`
- `upper-wall-1.png` `512x512 RGB`
- `upper-mid-wall-1.png` `768x512 RGB`
- `upper-long-wall-1.png` `1024x512 RGB`
- `window-1.png` `512x512 RGBA`
- `arched-window-1.png` `512x512 RGBA`
- `horizontal-belt-1.png` `512x30 RGB`
- `horizontal-mid-belt-1.png` `768x30 RGB`
- `horizontal-long-belt-1.png` `1024x30 RGB`
- `horizontal-seam-1.png` `512x30 RGB` alias for runtime compatibility
- `horizontal-mid-seam-1.png` `768x30 RGB` alias for runtime compatibility
- `horizontal-long-seam-1.png` `1024x30 RGB` alias for runtime compatibility
- `vertical-seam-1.png` `30x572 RGB`
- `roofbottom-1.png` `512x512 RGB` candidate
- `long-roofbottom-1.png` `1024x512 RGB` candidate

QA sheets:

- `sovetsky-lowrise-two-tone-plaster-1_atoms_contact_sheet.png`
- `sovetsky-lowrise-two-tone-plaster-1_molecule_preview.png`

Runtime caveat:

`FacadeAssembler` supports semantic floor zones through `floor_atom_overrides`.
This archetype uses floor-aware wall selection:

- floor `0`: lower wall atoms;
- floor `1+`: upper wall atoms;
- for 2 floors, ground = lower, upper = upper;
- for 3 floors, ground = lower, floors 1-2 = upper.

Schema:

```json
"floor_atom_overrides": {
  "ground": {
    "wall": "lower-wall",
    "mid-wall": "lower-mid-wall",
    "long-wall": "lower-long-wall"
  },
  "upper": {
    "wall": "upper-wall",
    "mid-wall": "upper-mid-wall",
    "long-wall": "upper-long-wall",
    "window": "arched-window"
  }
}
```

Supported zone keys are `ground`, `middle`, `upper`, and optional `top`.
If no override exists for a zone/category pair, the original slot category is
used unchanged.

The decorative floor belt can initially reuse the existing seam draw path:

```json
"has_seams": true
```

Semantically, however, this is not a panel seam. It is a historic horizontal
plaster belt/cornice line.

Molecules:

```json
[
  {
    "id": "sov2-win-wall-win",
    "slots": ["window", "wall", "window"],
    "tags": ["any"]
  },
  {
    "id": "sov2-win-win-wall-win",
    "slots": ["window", "window", "wall", "window"],
    "tags": ["long"]
  },
  {
    "id": "sov2-wall-win-wall-win",
    "slots": ["wall", "window", "wall", "window"],
    "tags": ["any"]
  },
  {
    "id": "sov2-win-wall-win-wall-win",
    "slots": ["window", "wall", "window", "wall", "window"],
    "tags": ["long"]
  }
]
```

Window role note:

The molecule role can stay `window`, but the atom picker should be allowed to
choose `arched-window` on upper floors via `floor_atom_overrides`.

Draft archetype manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-two-tone-plaster-1.json`

### `sovetsky-lowrise-pastel-plaster-1`

Primary references:

- `sovetsky-ref-02.jpg`
- supporting candidates for future variants: `sovetsky-ref-08.jpg`,
  other turquoise/pastel shopfront facades

Look:

- single pastel plaster color, often turquoise, pale grey, dusty rose, or cream;
- white plaster surrounds and pilasters;
- mostly 2 floors;
- shop signs may exist on ground floor but are excluded.

Generated atom folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-pastel-plaster-1/`

Generated atoms:

- `wall-1.png` `512x512 RGB`
- `mid-wall-1.png` `768x512 RGB`
- `long-wall-1.png` `1024x512 RGB`
- `window-1.png` `512x512 RGBA`
- `horizontal-belt-1.png` `512x30 RGB`
- `horizontal-mid-belt-1.png` `768x30 RGB`
- `horizontal-long-belt-1.png` `1024x30 RGB`
- `horizontal-seam-1.png` `512x30 RGB` alias for runtime compatibility
- `horizontal-mid-seam-1.png` `768x30 RGB` alias for runtime compatibility
- `horizontal-long-seam-1.png` `1024x30 RGB` alias for runtime compatibility
- `vertical-seam-1.png` `30x572 RGB`
- `roofbottom-1.png` `512x512 RGB`
- `long-roofbottom-1.png` `1024x512 RGB`

QA sheets:

- `sovetsky-lowrise-pastel-plaster-1_atoms_contact_sheet.png`
- `sovetsky-lowrise-pastel-plaster-1_molecule_preview.png`

Draft archetype manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-pastel-plaster-1.json`

Important modeling decision:

- `has_seams = true`, because the white horizontal belt between floors is part
  of the look.
- `vertical-seam-1.png` is intentionally almost invisible turquoise plaster.
  This avoids drawing a false white pilaster at every bay boundary while still
  allowing the existing seam path to draw the horizontal belt.

Molecules:

```json
[
  {
    "id": "sov-pastel-win-wall-win",
    "slots": ["window", "wall", "window"],
    "tags": ["any"]
  },
  {
    "id": "sov-pastel-win-wall-win-wall-win",
    "slots": ["window", "wall", "window", "wall", "window"],
    "tags": ["long"]
  },
  {
    "id": "sov-pastel-wall-win-wall-win",
    "slots": ["wall", "window", "wall", "window"],
    "tags": ["any"]
  }
]
```

### `sovetsky-lowrise-orange-commercial-plaster-1`

Primary reference:

- `sovetsky-ref-04.jpg`

Look:

- saturated orange historic plaster;
- two-storey small commercial building;
- ground floor has two large shop windows and a central entrance;
- upper floor has three regular windows with white plaster surrounds and
  shallow arched/curved top trim;
- strong white horizontal belt between the commercial ground floor and the
  upper floor;
- white rusticated corner quoins are visible in the source, but are not part of
  the first draft because the current assembler has no corner-only trim slot;
- the `Yves Rocher` sign, sale posters, street plates, UI controls, pole, and
  brand colors are excluded from the archetype.

Generated atom folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-orange-commercial-plaster-1/`

Generated atoms:

- `lower-wall-1.png` `512x512 RGB`
- `lower-mid-wall-1.png` `768x512 RGB`
- `lower-long-wall-1.png` `1024x512 RGB`
- `upper-wall-1.png` `512x512 RGB`
- `upper-mid-wall-1.png` `768x512 RGB`
- `upper-long-wall-1.png` `1024x512 RGB`
- `wall-1.png` / `mid-wall-1.png` / `long-wall-1.png` compatibility aliases
  for the upper wall set
- `upper-window-1.png` `768x512 RGBA`
- `mid-window-1.png` `768x512 RGBA` compatibility alias for the upper window
- `window-1.png` `512x512 RGBA`
- `storefront-window-1.png` `768x512 RGBA`
- `shop-entrance-1.png` `768x512 RGBA`
- `entrance-1.png` `768x512 RGBA` compatibility alias for `shop-entrance`
- `horizontal-belt-1.png` / `horizontal-mid-belt-1.png` /
  `horizontal-long-belt-1.png`
- `horizontal-seam-1.png` / `horizontal-mid-seam-1.png` /
  `horizontal-long-seam-1.png` runtime-compatible aliases for the belt
- `vertical-seam-1.png` `30x572 RGB`
- `roofbottom-1.png` `512x512 RGB`
- `long-roofbottom-1.png` `1024x512 RGB`

QA sheets:

- `sovetsky-lowrise-orange-commercial-plaster-1_atoms_contact_sheet.png`
- `sovetsky-lowrise-orange-commercial-plaster-1_molecule_preview.png`

Draft archetype manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-orange-commercial-plaster-1.json`

Important modeling decision:

- This is a commercial-ground-floor variant, not just another two-tone plaster
  wall. The same molecule is reused on all floors, but `floor_atom_overrides`
  changes the ground floor into storefronts.
- Ground floor:
  - `mid-window` becomes `storefront-window`;
  - `entrance` becomes `shop-entrance`;
  - wall atoms use `lower-*` orange plaster.
- Upper floors:
  - `mid-window` becomes `upper-window`;
  - `entrance` also becomes `upper-window`, so the central entrance bay becomes
    the third upper-floor window;
  - wall atoms use `upper-*` orange plaster.
- The white corner rustication should become a future `corner-trim`,
  `edge-trim`, or corner-aware assembler feature. Using `vertical-seam` for
  this would incorrectly repeat white quoins between every bay.

Molecules:

```json
[
  {
    "id": "sov-orange-store-store-store",
    "slots": ["mid-window", "entrance", "mid-window"],
    "tags": ["any"]
  },
  {
    "id": "sov-orange-wide-store-run",
    "slots": ["mid-window", "wall", "entrance", "wall", "mid-window"],
    "tags": ["long"]
  }
]
```

### `sovetsky-lowrise-cream-rusticated-plaster-1`

Primary reference:

- `sovetsky-ref-12.jpg`

Look:

- pale cream / very light beige historic plaster;
- upper floor: smoother plaster surface;
- ground floor: shallow horizontal rustication grooves;
- white rectangular window surrounds on both floors;
- upper-floor windows are taller and narrower;
- ground-floor windows are slightly wider and lower;
- white horizontal floor belt and heavy cornice;
- grey plinth is visible in the reference but not included in the first atom
  pack because the current assembler has no dedicated plinth slot.

Generated atom folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-cream-rusticated-plaster-1/`

Generated atoms:

- `lower-wall-1.png` `512x512 RGB`
- `lower-mid-wall-1.png` `768x512 RGB`
- `lower-long-wall-1.png` `1024x512 RGB`
- `upper-wall-1.png` `512x512 RGB`
- `upper-mid-wall-1.png` `768x512 RGB`
- `upper-long-wall-1.png` `1024x512 RGB`
- `wall-1.png` `512x512 RGB` compatibility alias for upper wall
- `mid-wall-1.png` `768x512 RGB` compatibility alias for upper wall
- `long-wall-1.png` `1024x512 RGB` compatibility alias for upper wall
- `lower-window-1.png` `512x512 RGBA`
- `upper-window-1.png` `512x512 RGBA`
- `window-1.png` `512x512 RGBA` compatibility alias for upper window
- `horizontal-belt-1.png` `512x30 RGB`
- `horizontal-mid-belt-1.png` `768x30 RGB`
- `horizontal-long-belt-1.png` `1024x30 RGB`
- `horizontal-seam-1.png` `512x30 RGB` alias for runtime compatibility
- `horizontal-mid-seam-1.png` `768x30 RGB` alias for runtime compatibility
- `horizontal-long-seam-1.png` `1024x30 RGB` alias for runtime compatibility
- `vertical-seam-1.png` `30x572 RGB`
- `roofbottom-1.png` `512x512 RGB`
- `long-roofbottom-1.png` `1024x512 RGB`

QA sheets:

- `sovetsky-lowrise-cream-rusticated-plaster-1_atoms_contact_sheet.png`
- `sovetsky-lowrise-cream-rusticated-plaster-1_molecule_preview.png`

Draft archetype manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-cream-rusticated-plaster-1.json`

Important modeling decision:

- Ground-floor rustication is modeled with `floor_atom_overrides`, not blended
  into a shared wall atom.
- `floor_atom_overrides.ground.window = "lower-window"`.
- `floor_atom_overrides.upper.window = "upper-window"`.
- `vertical-seam-1.png` is intentionally subtle cream plaster, not a white
  pilaster.
- The grey plinth should become a future `plinth` or `foundation-band` atom
  family if this look needs stronger street-level fidelity.

Molecules:

```json
[
  {
    "id": "sov-cream-win-wall-win",
    "slots": ["window", "wall", "window"],
    "tags": ["any"]
  },
  {
    "id": "sov-cream-win-wall-win-wall-win",
    "slots": ["window", "wall", "window", "wall", "window"],
    "tags": ["long"]
  },
  {
    "id": "sov-cream-wall-win-wall-win",
    "slots": ["wall", "window", "wall", "window"],
    "tags": ["any"]
  }
]
```

### `sovetsky-lowrise-red-brick-classic-1`

Primary reference:

- `sovetsky-ref-11.jpg`

Look:

- red brick wall;
- white arched second-floor surrounds;
- white horizontal belt between floors;
- white cornice/parapet zone;
- rectangular first-floor windows.

Generated atom folder:

- `data/facade_pipeline/cherepovets_sovetsky/generated_atoms/sovetsky-lowrise-red-brick-classic-1/`

Generated atoms:

- `wall-1.png` `512x512 RGB`
- `mid-wall-1.png` `768x512 RGB`
- `long-wall-1.png` `1024x512 RGB`
- `window-1.png` `512x512 RGBA`
- `arched-window-1.png` `512x512 RGBA`
- `horizontal-belt-1.png` `512x30 RGB`
- `horizontal-mid-belt-1.png` `768x30 RGB`
- `horizontal-long-belt-1.png` `1024x30 RGB`
- `horizontal-seam-1.png` `512x30 RGB` alias for runtime compatibility
- `horizontal-mid-seam-1.png` `768x30 RGB` alias for runtime compatibility
- `horizontal-long-seam-1.png` `1024x30 RGB` alias for runtime compatibility
- `vertical-seam-1.png` `30x572 RGB`
- `roofbottom-1.png` `512x512 RGB`
- `long-roofbottom-1.png` `1024x512 RGB`

QA sheets:

- `sovetsky-lowrise-red-brick-classic-1_atoms_contact_sheet.png`
- `sovetsky-lowrise-red-brick-classic-1_molecule_preview.png`

Draft archetype manifest:

- `data/facade_pipeline/cherepovets_sovetsky/generated_archetypes/sovetsky-lowrise-red-brick-classic-1.json`

Runtime category:

- `category = "brick"`, because existing `FacadeAssembler._tag_to_category()`
  already maps `building:material=brick` to `brick`. With `min_floors = 1` and
  `max_floors = 3`, this can become the low-rise brick counterpart to
  `default-bricks-1`.

Important modeling decision:

- `floor_atom_overrides.upper.window = "arched-window"`, so upper floors use
  the arched historic window while the ground floor keeps rectangular windows.
- The central entrance group and its sign are excluded from this first atom
  pack. Entrance groups should become a separate atom/slot once the pipeline
  supports them; signs remain algorithmic.
- `vertical-seam-1.png` is intentionally subtle brick, not white trim, to avoid
  false pilasters on every bay boundary.

Molecules:

```json
[
  {
    "id": "sov-brick-win-wall-win",
    "slots": ["window", "wall", "window"],
    "tags": ["any"]
  },
  {
    "id": "sov-brick-win-wall-win-wall-win",
    "slots": ["window", "wall", "window", "wall", "window"],
    "tags": ["long"]
  },
  {
    "id": "sov-brick-wall-win-wall-win",
    "slots": ["wall", "window", "wall", "window"],
    "tags": ["any"]
  }
]
```

## Validation Gates

- No signs, logos, readable text, sale posters, or brand colors inside atoms.
- Low-rise only: `min_floors = 1`, `max_floors = 3`.
- Two-tone archetype must preserve floor color zoning.
- Window overlays must not include wall color around the trim.
- Decorative horizontal belts are allowed, but they are not panel seams.
- The resulting facade should look like Sovetsky Avenue historic low-rise
  fabric, not Cherepovets panel housing.
