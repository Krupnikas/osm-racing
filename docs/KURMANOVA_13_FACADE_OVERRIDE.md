# Kurmanova 13 Facade Override

Specific facade for:

- address: `13 улица Курманова`
- OSM way: `45119820`
- visible brand/sign: `NORTHIS`
- source screenshot: `/Users/alekseiaksenov/Documents/kurmanova.png`

This is a **way-specific facade**, not a generic Cherepovets district archetype.

## Runtime Files

Production archetype:

- `decorations/russia/cherepovets/facades/kurmanova-13-brick-commercial-1.json`

Production atoms:

- `decorations/russia/cherepovets/kurmanova-13-brick-commercial-1-atoms/`

Building override:

- `decorations/russia/cherepovets/building_overrides.json`

Override entry:

```json
{
  "osm_way_id": 45119820,
  "comment": "13 улица Курманова (NORTHIS)",
  "facade_archetype": "kurmanova-13-brick-commercial-1",
  "height_override": 10.5
}
```

Pipeline/reference files:

- `data/facade_pipeline/cherepovets_kurmanova/references/kurmanova-13-source.png`
- `data/facade_pipeline/cherepovets_kurmanova/generated_atoms/kurmanova-13-brick-commercial-1/`
- `data/facade_pipeline/cherepovets_kurmanova/generated_archetypes/kurmanova-13-brick-commercial-1.json`

QA images:

- `data/facade_pipeline/cherepovets_kurmanova/generated_atoms/kurmanova-13-brick-commercial-1/kurmanova-13-brick-commercial-1_atoms_contact_sheet.png`
- `data/facade_pipeline/cherepovets_kurmanova/generated_atoms/kurmanova-13-brick-commercial-1/kurmanova-13-brick-commercial-1_molecule_preview.png`
- `data/facade_pipeline/cherepovets_kurmanova/generated_atoms/kurmanova-13-brick-commercial-1/kurmanova-window-entrance-width-check.png`

## Atom Inventory

The facade is built from these visible atom families:

- `red-wall` / `red-mid-wall` / `red-long-wall`
- `white-wall` / `white-mid-wall` / `white-long-wall`
- `mid-window`
- `gable-window`
- `entrance`
- horizontal seam/belt
- vertical seam
- `roofbottom` / `long-roofbottom`

The source has many real-world details that are intentionally excluded:

- air conditioners;
- people;
- bicycles;
- cars;
- Street View arrows/UI;
- incidental posters;
- small wall signs outside the main NORTHIS entrance.

## Correct Window Proportion

The main window is a `mid-window`, not a regular `window`.

Final atom:

- file: `mid-window-1.png`
- size: `768x512`
- visible alpha bbox: `(47, 38, 720, 474)`
- visible width: `673 px`

Important shape constraints:

- exactly three vertical panes;
- no upper fortochka/top transom;
- no horizontal divider row;
- brown frame;
- landscape mid-bay proportion.

## Entrance Atom

The entrance must occupy the same mid-bay width as the main window.

Final atom:

- file: `entrance-1.png`
- size: `768x512`
- visible alpha bbox: `(40, 28, 728, 490)`
- visible width: `688 px`

The first entrance attempt was rejected because it was narrower than the
window. The corrected entrance has:

- central double glass doors;
- side glass panels;
- full-width grey frame;
- full-width dark signboard/canopy strip;
- locally drawn `NORTHIS` text for legibility.

## Runtime Assembly

The archetype uses the generic `FacadeAssembler`, not a separate custom
GDScript like `Facade111_125`.

The key molecule is:

```json
{
  "id": "kur13-window-entrance-window",
  "slots": ["mid-window", "entrance", "mid-window"],
  "tags": ["any"]
}
```

The same molecule is reused on floors, but `floor_atom_overrides` changes what
each category means:

- `ground`:
  - red brick walls;
  - center `entrance` stays entrance.
- `middle`:
  - red brick walls;
  - center `entrance` remaps to `mid-window`, so the entrance does not repeat.
- `top`:
  - white brick walls;
  - `mid-window` remaps to `gable-window`;
  - `entrance` remaps to missing category `none`, so the center slot is blank.

This captures the recognizable facade logic without needing a bespoke mesh for
the gable roof shape.

The long fallback molecule is:

```json
{
  "id": "kur13-wide-commercial-run",
  "slots": ["mid-window", "wall", "entrance", "wall", "mid-window"],
  "tags": ["long"]
}
```

This gives wide edges a calmer rhythm while preserving the same central
commercial bay.

## Why This Is an Override

This facade is too specific for normal category selection:

- it has a recognizable commercial ground floor;
- the upper floor changes material/color to white brick;
- the attic/gable window row should not repeat the same rectangular window;
- the NORTHIS entrance is a local landmark detail.

Because of that, the OSM way is pinned to a facade id through
`building_overrides.json`. This is the same conceptual bucket as other
way-specific buildings: when we need a specific visual identity, we opt out of
statistical facade selection.

## Assembler/Override Support Added

Support added in:

- `osm/facade_assembler.gd`
- `osm/decorations/building_override.gd`
- `osm/decoration_layer.gd`
- `osm/osm_terrain_generator.gd`

New generic pieces:

- `entrance` slot in `FacadeAssembler.SLOT_CATALOG`;
- `FacadeAssembler.get_archetype(id)`;
- `facade_archetype` key in `building_overrides.json`;
- forced facade archetype path in `osm_terrain_generator.gd`.

## Verification

Checked:

- production archetype JSON parses;
- `building_overrides.json` parses;
- runtime atom dimensions match the expected grid;
- `godot --headless --path . --check-only --quit` exits with code `0`.

Known non-fatal output:

- Godot prints a resource leak warning on exit, same as previous checks.
