# Dubai Creek Harbour Facade Archetype Pipeline Plan

This document adapts the generic facade automation plan to a concrete first
non-Cherepovets target: **Dubai Creek Harbour**, Dubai, UAE.

The goal is not to reproduce every real tower. The goal is a place-plausible
OSM Racing facade pack for a master-planned waterfront district: clean modern
high-rise and mid-rise residential blocks, glass balconies, pale facade
materials, retail/promenade podiums, marina/waterfront cues, and a controlled
amount of luxury-new-build polish.

Related repo documents:

- [Automated facade archetype pipeline](FACADE_ARCHETYPE_AUTOMATION_PLAN.md)
- [Current facade archetype system notes](FACADE_ARCHETYPE_PIPELINE.md)
- [Facade archetype draft](../decorations/facade_archetypes_DRAFT.md)
- [FacadeAssembler](../osm/facade_assembler.gd)
- [DecorationLayer](../osm/decoration_layer.gd)
- [OSM terrain generator facade hook](../osm/osm_terrain_generator.gd)
- [Decoration index](../decorations/index.json)
- [Current Cherepovets facade JSONs](../decorations/russia/cherepovets/facades)
- [Facade performance debug notes](FACADE_PERF_DEBUG.md)

## Executive Decision

Use Dubai Creek Harbour as the first **Stage 0-first** implementation case.

Near-term target:

1. Build an automated research/reference-discovery run for Dubai Creek Harbour.
2. Produce an evidence-cited style brief and contact sheet.
3. Find rights-suitable real Dubai Creek Harbour photographs for generation
   conditioning. DCH photos are abundant online; the hard task is rights and
   provenance, not avoiding photos.
4. Rectify those photos, segment facade components, clean occlusions/alpha, and
   use the processed photo crops as the primary atom-generation conditioning
   input. Text prompts are auxiliary direction only.
5. Add one style-family archetype JSON and enough runtime selection logic for
   the archetype to appear in curated matching communities.
6. Preview and QA in Godot before expanding to more Dubai districts.

Do not start with embedding clustering. Do start with photo rectification,
component segmentation, and role-specific crop preparation because
photo-conditioned generation makes that processing a core stage. For this
district, one strong candidate style family is enough to prove the pipeline.

## Implementation Findings & Approach Correction (2026-06-23)

A first local implementation was attempted and **failed** — recorded here so it is not
repeated. Full detail + dead-ends in [DCH_PIPELINE_PROGRESS.md](DCH_PIPELINE_PROGRESS.md).

**Key correction — atom generation must use an instruction-following image-EDIT model,
NOT local SDXL img2img.**
- **SDXL img2img is strength-based "repaint the input"** — it cannot rectify perspective,
  isolate a single element, remove the background, or reframe. It produced rotated,
  non-isolated facade fragments. Wrong tool.
- Local **segmentation (CMP SegFormer) + SAM + rectification (chsasank)** could not produce
  clean, isolated, hand-authored-quality atoms from casual phone photos: CMP is noisy on
  modern glass and misses glass balconies; vanishing-point rectification over-skews on
  cluttered foregrounds; detectors return whole-facade boxes, not single units.
- **The working approach** (and the project's original manual workflow): give the crooked
  photo + a SPECIFIC per-atom instruction to an **instruction-edit model** (GPT-image-1,
  Gemini image, FLUX Kontext, Qwen-Image-Edit). It rectifies + isolates + cleans + reframes
  in one shot. Phase 4 below is updated to this approach.

**Execution options for the edit model** (Claude has no image-gen tool; local stack is plain SDXL):
(A) user runs the per-atom prompts in their own image-AI (zero infra, proven); (B) hosted edit
API key (OpenAI/fal/Replicate) → scripted full run; (C) local FLUX-Kontext/Qwen-Edit (heavy download).

**Target atom format** (from `default-panels-atoms`): walls 512/768/1024×512 **opaque RGB, no
openings, tileable**; windows/balconies **RGBA isolated on transparent** (320×320 / 480×320 /
700×512 / 1024×512). Atoms are clean isolated components, NOT photo crops. Grid: 160 px/m, 512 px/floor.

**Other confirmed findings:** clean CC0/CC-BY DCH facade photos ≈ 0 → use owned/any photos (pet-project
licensing); 96% of OSM buildings lack `building:levels` → floor-safety default mandatory + 7 named-tower
overrides written (dormant); SAM must run on CPU (MPS lacks float64); EXIF orientation must be applied.

## Why Dubai Creek Harbour Is a Good Test

Dubai Creek Harbour is different from Cherepovets and Antalya:

- It is a recent master-planned waterfront community, not a layered old city.
- Ordinary housing is mostly developer-designed apartment towers and mid-rise
  blocks, not low-rise vernacular fabric.
- Publicly visible references are often developer pages, property portals, or
  promenade/street-level images.
- The dominant look is likely cleaner and more repetitive than post-Soviet
  housing: pale wall planes, floor-to-ceiling glazing, glass balcony rails,
  vertical fins, podium retail, and landscaped public realm.
- Licensing is tricky because many of the most visible facade images are
  marketing/listing images. Treat those as research evidence by default, while
  separately finding cleared photographs for generation conditioning.

This makes it a useful stress test for the automation plan: the AI researcher
must discover a contemporary real-estate district without overfitting to glossy
renders or iconic skyline images.

## Archetype Scope Rule

Facade archetypes are scoped by **urban-fabric style family and market tier**,
not by a blanket city/region label and not necessarily by one city-specific
district. Dubai Creek Harbour towers should not create a narrow
`dubai_creek_harbour_only` archetype, but they also should not be generalized
to a broad `gulf-modern` bucket.

The first DCH delivery is a curated style-family set of three independent
mid-class residential tower archetypes:

- `gulf-residential-mid-class-tower-1`
- `gulf-residential-mid-class-tower-2`
- `gulf-residential-mid-class-tower-3`
- `style_family = "gulf_masterplan_uppermid_residential"`
- reusable only in explicitly approved matching communities:
  `dubai_creek_harbour`, `dubai_hills`, `creek_beach`, `emaar_beachfront`
- explicitly not for `dubai_marina`, `downtown_dubai`, or `business_bay`

Runtime selection should match on `style_family` and curated community
membership, not just bounding box or country/city. This lets visually similar
Emaar-style master-planned communities share assets while preventing the pack
from leaking into different Dubai fabrics.

## Initial Geographic Scope

Use OSM/Nominatim as the starting boundary source.

Observed Nominatim result during planning:

- Name: Dubai Creek Harbour, Arabic name in OSM result.
- OSM type/id: `way/1012353010`
- OSM category/type: `landuse=residential`
- License: OSM ODbL.
- Approximate bbox:
  - `min_lat`: `25.1849211`
  - `max_lat`: `25.2110181`
  - `min_lon`: `55.3404649`
  - `max_lon`: `55.3758420`

Store this as an initial config, then cache the full OSM polygon from
Nominatim/Overpass for point-in-polygon filtering. Do not rely on the bbox
alone because it includes nearby non-target fabric and edges of Ras Al Khor /
industrial areas.

Initial config:

```json
{
  "id": "dubai_creek_harbour",
  "display_name": "Dubai Creek Harbour",
  "country": "uae",
  "city": "dubai",
  "bbox": [25.1849211, 55.3404649, 25.2110181, 55.3758420],
  "osm_boundary": {
    "osm_type": "way",
    "osm_id": 1012353010,
    "source": "nominatim",
    "license": "OSM ODbL"
  },
  "districts": [
    {
      "id": "creek_island",
      "name": "Creek Island",
      "goal": "waterfront high-rise residential towers and marina podium"
    },
    {
      "id": "creek_beach",
      "name": "Creek Beach",
      "goal": "mid-rise beachside apartment blocks and podium retail"
    }
  ],
  "target_archetype_count": 1,
  "preferred_sources": [
    "osm",
    "mapillary",
    "kartaview",
    "wikimedia",
    "flickr",
    "developer_pages_research_only",
    "property_portals_research_only",
    "dubai_open_data",
    "local_uploads"
  ],
  "style_notes": "dominant residential/mixed-use facade look, not landmarks, not Dubai skyline, not Creek Tower"
}
```

## Source Strategy

### Primary machine-readable sources

| Source | Use | Notes |
|---|---|---|
| [OpenStreetMap / Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API) | Building footprints, roads, POIs, approximate usage, levels/height if tagged | Cache all responses. OSM tags may be sparse or include non-target hangars around the bbox. |
| [Nominatim](https://nominatim.openstreetmap.org/) | Initial boundary discovery | Cache boundary polygon and OSM ID. Respect usage policy and use a clear User-Agent. |
| [Dubai Municipality Open Data](https://www.dm.gov.ae/open-data2/) | Official Dubai datasets if usable | Explore for building, land-use, community, or GIS records. |
| [Dubai Pulse building usages API](https://gslb.dubaipulse.gov.ae/data/dm-general/dm_building_usages-open-api?page=3) | Building usage / occupancy context | Good for filtering residential/commercial if coordinates or building names can be joined. |
| [Mapillary API](https://www.mapillary.com/developer/api-documentation) | Street-level image candidates | CC-BY-SA. Use as cited research evidence by default, not direct generation conditioning. |
| [KartaView API](https://kartaview.org/doc/api-response) | Street-level image candidates | CC-BY-SA/terms-sensitive. Same default policy as Mapillary. |
| [Wikimedia Commons API](https://commons.wikimedia.org/wiki/Commons:API) | Open city images and possible conditioning photos | Use only per-file license. CC0/public-domain and CC-BY can be conditioning inputs; CC-BY needs attribution records. |
| [Flickr API](https://www.flickr.com/services/api/) | Geotagged rights-filtered imagery and possible conditioning photos | Use only if license and API terms permit. CC0/public-domain and CC-BY can be conditioning inputs; CC-BY needs attribution records. |
| Licensed stock providers, e.g. Shutterstock / Adobe Stock | Possible conditioning photos | Allowed only when the purchased license permits derivative texture/game asset use. Store license receipt/terms snapshot. |

### Dubai Creek Harbour-specific research sources

| Source | Use | Policy |
|---|---|---|
| [Emaar Dubai Creek Harbour community page](https://www.emaar.com/en/our-communities/dubai-creek-harbour) | Official district identity, project list, amenities, master-planned positioning | Research-only unless asset usage rights are explicitly cleared. |
| [Emaar Dubai Creek Residences page](https://www.emaar.com/en/properties/dubai-creek-residences) | High-value facade/style evidence for waterfront residential towers | Research-only by default. |
| [Emaar Dubai Creek Harbour properties for sale](https://www.emaar.com/en/property-for-sale/dubai-creek-harbour) | Current property names, tower/product mix, marketing language | Research-only; useful for naming candidate typologies. |
| [Property Finder area guide](https://www.propertyfinder.ae/en/area-insights/dubai/dubai-creek-harbour-the-lagoons) | Area description and building/project pages | Research-only. Do not use listing photos for atom conditioning unless rights are cleared. |
| [Property Finder new projects](https://www.propertyfinder.ae/en/new-projects/lp/dubai/dubai-creek-harbour-the-lagoons) | Project list, off-plan/completed status, developer stock | Research-only; useful for candidate tower names and eras. |
| [Propsearch Creek Island buildings](https://propsearch.ae/dubai/creek-island/buildings) | Building inventory and completion status | Research-only. Good for matching OSM building names. |
| [SSH Creek Beach District](https://www.sshic.com/our-projects/creek-beach-district/) | Planning/design framing for Creek Beach | Research-only. |
| [SWA Dubai Creek Harbor](https://www.swagroup.com/projects/dubai-creek-harbor/) | Landscape/master-plan context | Research-only. |
| Bayut / other UAE real-estate pages | Ordinary exterior/listing evidence | Research-only, unless explicit rights are cleared. |
| Local user uploads | Best generation-safe reference route | If owned/self-captured by the project/user, allowed for generation conditioning. |

### Conditioning Photo Policy

Atom generation for DCH is **photo-driven and mandatory**. The pipeline must
find rights-suitable real Dubai Creek Harbour photographs, process them, and
use them as the primary conditioning inputs. Text prompts only describe the
desired role, cleanup, and game-asset constraints layered on top of those photo
inputs.

Allowed generation-conditioning pools:

| Pool | Conditioning status | Required records |
|---|---|---|
| Owned / self-captured DCH photos | Allowed | capture owner, date/location if known, content hash, use grant |
| CC0 / public-domain DCH photos, e.g. Wikimedia or Flickr CC0 | Allowed | URL/source id, license URL/snapshot, content hash |
| Properly licensed stock photos | Allowed when the license permits derivative texture/game asset use | provider id, purchase/license receipt, terms snapshot, content hash |
| CC-BY photos | Allowed with attribution | URL/source id, author, license URL/snapshot, required attribution text, content hash |
| CC-BY-SA photos, including Mapillary/KartaView by default | Research evidence only | URL/source id, license, content hash, cited claims |
| Developer/listing/marketing imagery, including Emaar, Property Finder, Bayut, Propsearch | Research evidence only unless explicit rights are cleared | URL/source id, page snapshot where allowed, cited claims |

Promotion is blocked if any conditioning photo lacks cleared rights or
provenance. Every conditioning input must have:

- source URL or provider asset id;
- cached bytes or a legally permitted local snapshot;
- content hash;
- license/use-policy classification;
- author/attribution text when required;
- the exact atom roles it conditioned.

This keeps the pipeline photo-driven without contaminating game assets with
share-alike or marketing/listing rights problems.

### Explicit non-sources

- Do not automate Google Street View or Google Maps screenshots.
- Do not scrape Instagram/TikTok/YouTube thumbnails as generation inputs.
- Do not use developer renders as direct atom references unless legal clearance
  is recorded.
- Do not let Dubai skyline, Burj Khalifa views, or Dubai Creek Tower dominate
  the generic residential archetype.

## Expected Visual Hypotheses

These are hypotheses to verify with evidence, not truths.

### Candidate A: `gulf-residential-mid-class-tower-*`

Primary first implementation target.

Likely features:

- 30-60 floor residential towers and tower pairs.
- Pale concrete, off-white plaster, light beige stone/ceramic cladding.
- Blue-green or neutral reflective glazing.
- Floor-to-ceiling window modules.
- Repeating glass balcony rails, often stacked vertically.
- Balcony slabs/fins create strong vertical rhythms.
- Minimal grime; much cleaner than Cherepovets assets.
- No post-Soviet panel seams, but visible architectural reveal lines and
  bay-grid joints between beige cladding/slab modules.
- Optional crown/roofline band: slim white parapet, mechanical-screen band,
  or darker glass top.
- Ground-floor podium may have shops/cafes, but this can be handled by the
  existing storefront row if OSM POIs exist. `creek-5` also shows a distinct
  podium screen/glazing language that should become its own role family.

Suggested archetypes:

- `id`: `gulf-residential-mid-class-tower-1`
- `id`: `gulf-residential-mid-class-tower-2`
- `id`: `gulf-residential-mid-class-tower-3`
- `category`: `modern`
- `style_family`: `gulf_masterplan_uppermid_residential`
- `district_tags`: `uppermid`, `masterplan`, `newbuild`, `glass_balcony`
- `communities`: `dubai_creek_harbour`, `dubai_hills`, `creek_beach`,
  `emaar_beachfront`
- `min_floors`: `12`
- `max_floors`: `80`
- `has_seams`: `false` for the first pass; DCH architectural reveals/bay joints
  are a separate future seam family, not rusty panel seams
- `has_roofbottom`: `false` for the first residential-body pass; add
  roofbottom/soffit later
- `balcony_placement`: `full_height` or `centre` as metadata
- `slot_extrusion`:
  - `mid-balcony`: `0.6-0.8 m`
  - `long-balcony`: `0.6-0.8 m`

### Candidate B: `dch-creek-beach-light-midrise`

Second candidate after the high-rise pack works.

Likely features:

- 6-15 floor blocks around Creek Beach.
- Warm white, cream, sand, and light stone walls.
- Deep balconies/loggias with glass or white railings.
- Lower, resort-residential proportions.
- Occasional shaded podium/cafe/retail fronts.
- No post-Soviet panel seams, but likely subtle architectural reveals/bay
  joints.
- Cleaner, less aged texture than post-Soviet assets, but not flat: subtle
  stucco/stone variation, dust, sun fading, balcony shadows.

### Candidate C: `dch-promenade-retail-podium`

Document, but do not build in the first atom-generation pass.

Likely features:

- Retail/cafe podiums, awnings, glass doors, shaded colonnade-like rhythms.
- `podium-screen`: brown-grey gridded ventilation/privacy screen visible on
  `creek-5`; this is a new archetypal atom role, not a normal window/balcony.
- `podium-glazing`: large lower-floor storefront/amenity glazing.
- Best implemented through vertical zonation plus new podium roles, optionally
  aligned with the existing `_add_storefront_row()` logic when OSM POIs exist.

## `creek-5` First-Pass Atom Inventory

Before generating, inspect the facade and decide which atoms exist. For
`creek-5`, generate only the residential body first:

| Role | First-pass? | Approx. target | Notes |
|---|---:|---:|---|
| `wall` | yes | `512/768/1024 x 512` | Warm beige / light sand cladding; subtle reveal shadows allowed; opaque; no openings. |
| `window` | yes | proof `512x512` | Small almost-square residential glazing bay; visible module approx `9:10` width:height, almost full floor height, about `90%` bay width. |
| `mid-window` | yes | `768x512` after measuring | Wider blue-green glazing strip; likely 1.5 bay. |
| `mid-balcony` | yes | `700x512` or `768x512` | Beige slab, glass/metal rail, glazing behind; alpha overlay. |
| `long-balcony` | yes | `1024x512` | Longer balcony/terrace strip across two bays; alpha overlay. |
| `architectural-reveal` / `bay-joint` | not initially | thin neutral seams | DCH has these; add as a separate seam family if baked wall joints are not enough. |
| `podium-screen` | no | TBD | New role: brown-grey gridded podium screen. Documented and postponed. |
| `podium-glazing` | no | TBD | New role: large amenity/storefront glazing. Documented and postponed. |
| `roofbottom` / `soffit` | no | TBD | Beige horizontal band/underside with square soffit details. Postponed. |

This inventory is a generation gate. Do not ask the image model for "a DCH
window" until the source bay and target proportion are named.

Cross-atom height is also a gate: visible `window`, `mid-window`, and
`mid-balcony` heights should align because they belong to the same floor band.
If a standalone window is visibly taller than a balcony from the same facade
family, reject or regenerate it before writing the archetype JSON.

## Phase 0: Create the DCH Project Skeleton

Add a case-study data folder:

```text
data/facade_pipeline/dubai_creek_harbour/
  city_config.json
  research/
  references/
  generated_atoms/
  generated_archetypes/
  previews/
  reports/
```

Add a runtime decoration folder:

```text
decorations/uae/dubai_creek_harbour/
  meta.json
  building_overrides.json
  facades/
    gulf-residential-mid-class-tower-1.json
    gulf-residential-mid-class-tower-2.json
    gulf-residential-mid-class-tower-3.json
  gulf-residential-mid-class-tower-1-atoms/
  gulf-residential-mid-class-tower-2-atoms/
  gulf-residential-mid-class-tower-3-atoms/
```

Initial `meta.json`:

```json
{
  "id": "dubai_creek_harbour",
  "name": "Dubai Creek Harbour",
  "files": [
    "building_overrides.json"
  ]
}
```

Initial `building_overrides.json` can be empty:

```json
{
  "building_overrides": []
}
```

Add a disabled or test-only source to `decorations/index.json`:

```json
{
  "id": "dubai_creek_harbour",
  "name": "Dubai Creek Harbour",
  "path": "uae/dubai_creek_harbour/",
  "bounds": {
    "min_lat": 25.1849211,
    "max_lat": 25.2110181,
    "min_lon": 55.3404649,
    "max_lon": 55.3758420
  },
  "enabled": true
}
```

Acceptance:

- The repo has a place for research artifacts and a place for runtime assets.
- DCH does not affect Cherepovets until runtime source selection is fixed.

## Phase 1: Implement the Stage 0 DCH Research Run

Command target:

```bash
python -m facade_pipeline.cli research-references \
  --config data/facade_pipeline/dubai_creek_harbour/city_config.json \
  --goal "dominant Dubai Creek Harbour residential and mixed-use facade look, not landmarks, not skyline, not tower renders" \
  --max-reference-candidates 160 \
  --target-approved-references 30
```

Substeps:

1. Fetch and cache the OSM boundary:
   - Nominatim search for `"Dubai Creek Harbour, Dubai, United Arab Emirates"`.
   - Store full polygon as `research/osm_boundary.geojson`.
   - Store bbox and OSM ID in `research/osm_boundary.json`.
2. Query OSM/Overpass:
   - buildings inside polygon;
   - `building`, `building:levels`, `height`, `name`, `addr:*`;
   - POIs with `shop`, `amenity`, `tourism`, `office`;
   - roads/pedestrian routes/promenade paths for possible image sampling.
3. Run residential coverage pre-check:
   - classify footprints as target vs non-target:
     - target: `apartments`, `residential`, `yes` with tower footprint shape,
       named residential towers;
     - lower confidence: `commercial`, `retail`, `hotel`;
     - reject: `hangar`, `industrial`, `warehouse`, `roof`, `carport`.
   - sample points weighted by target residential footprint area and perimeter,
     not by road density.
   - separately sample promenade-facing edges because waterfront facades may
     be more visible from open public space than from roads.
4. Probe imagery sources:
   - Mapillary images inside/near sampled points;
   - KartaView images inside/near sampled points;
   - Wikimedia/Flickr geotagged images inside bbox with rights metadata;
   - local uploads if present.
5. Build a conditioning-photo shortlist:
   - filter Wikimedia/Flickr/local/stock candidates for CC0, public-domain,
     CC-BY, owned, or properly licensed status;
   - record attribution requirements for CC-BY inputs;
   - reject CC-BY-SA and marketing/listing imagery from conditioning;
   - keep a separate `conditioning_candidates.json` manifest.
6. Gather research-only evidence:
   - Emaar pages for official product names and visual language;
   - Property Finder / Propsearch / Citysearch / Bayut-style pages for tower
     lists, floor counts, completion status, exterior photos;
   - SSH/SWA pages for master-plan and Creek Beach context;
   - Dubai open data for building usage if joinable.
7. Emit `PARTIAL` if any external API fails:
   - do not block the run if Mapillary is sparse;
   - do not block the run if KartaView is sparse;
   - do block promotion if no evidence-cited style brief can be produced.
   - do block atom generation if no cleared conditioning photos are available.

Deliverables:

```text
data/facade_pipeline/dubai_creek_harbour/
  research/
    osm_boundary.json
    osm_boundary.geojson
    overpass_buildings.json
    overpass_pois.json
    coverage_precheck.json
    zero_coverage_zones.geojson
    source_evidence.json
    urban_research_report.md
  references/
    reference_candidates.json
    conditioning_candidates.json
    approval_queue.json
    contact_sheets/
      dch_stage0_candidates.png
    ai_style_briefs/
      gulf-residential-mid-class-tower-1.md
      gulf-residential-mid-class-tower-2.md
      gulf-residential-mid-class-tower-3.md
    snapshots/
      mapillary/
      kartaview/
      wikimedia/
      flickr/
      property_portals_research_only/
      developer_pages_research_only/
    stage0_run_manifest.json
```

Quality gates:

- Every selected visual claim cites at least one selected image or source item.
- Every selected image has source URL/ID/hash/license/use policy.
- Research-only images are never marked as generation-safe.
- Every conditioning candidate has cleared rights and per-input provenance.
- At least one non-landmark residential/mixed-use candidate exists.
- Coverage report explicitly lists areas with poor street-level imagery.
- Contact sheet includes negative examples: Creek Tower, skyline, hotels,
  interiors, pure renders, tourist photos.

## Phase 2: DCH Reference Ranking Rules

Add DCH-specific ranking rules/features to the Stage 0 scorer.

Positive signals:

- facade occupies at least 30 percent of image area;
- tower or residential block visible, not only skyline;
- visible balconies or window grid;
- pale facade plus blue/green/clear glass;
- retail/podium base visible;
- ordinary tower elevations rather than hero render angle;
- waterfront/promenade context only if facade is still readable.

Negative signals:

- Dubai Creek Tower or tower construction site dominates;
- Burj Khalifa/Downtown skyline dominates;
- interior apartment render;
- pool/gym/lobby amenity image;
- nighttime skyline glamour shot;
- image shows only marina/yachts/landscape;
- heavy perspective where facade components cannot be inferred;
- listing watermark or text overlay covers facade;
- hotel/branded residence only if target is generic apartments.

Output each candidate score with an explanation:

```json
{
  "candidate_id": "mapillary_...",
  "score": 0.82,
  "roles": ["style_overall", "balcony_reference", "window_reference"],
  "positive_evidence": [
    "repeating glass balcony rails",
    "off-white tower wall planes",
    "floor-to-ceiling glazing"
  ],
  "negative_evidence": [],
  "use_policy": "research_evidence_only"
}
```

## Phase 3: Style Brief and Human Approval

The AI style brief should produce a decision-ready package, not just prose.

Required sections:

1. Candidate label and rationale.
2. Evidence table:
   - image/source id;
   - URL;
   - license/use policy;
   - cited visual claims.
3. Dominant materials/colors:
   - off-white concrete/plaster;
   - light beige stone/ceramic;
   - blue-green or grey glass;
   - dark mullions/frames if evidence supports them.
4. Window system:
   - floor-to-ceiling vertical glazing;
   - narrow dark mullions;
   - occasional balcony doors;
   - low grime, mild dust/sun fading.
5. Balcony/loggia system:
   - glass railings;
   - stacked balcony slabs;
   - long balcony strips for tower rhythm;
   - 0.6-0.8 m extrusion in-game.
6. Wall atoms:
   - clean but not flat;
   - subtle plaster/stone/ceramic variation;
   - no post-Soviet seams;
   - note DCH architectural reveals/bay joints separately.
7. Ground-floor/podium:
   - `podium-screen` and `podium-glazing` are planned new roles;
   - do not generate them in the first residential-body pass.
8. Roof/crown:
   - thin parapet/mechanical band if evidence supports it;
   - postpone roofbottom/soffit generation for the first pass.
9. Conditioning-photo shortlist:
   - which photos are cleared for generation;
   - which role each photo should condition;
   - required attribution/license records.
10. Proposed atom pack.
11. Proposed molecules.
12. What to avoid.

Human checkpoint outcomes:

- `approve`: proceed to Phase 4 photo processing and atom generation;
- `approve_with_edits`: modify style brief, conditioning shortlist, cleanup
  notes, or auxiliary prompts;
- `retry_stage0`: change bbox or search goal;
- `manual_fallback`: user supplies owned/cleared facade photographs;
- `reject`: do not generate assets.

## Phase 4: Rectify Photos, Segment Components, Generate Atom Pack

> ⚠️ **CORRECTED (2026-06-23):** the local "rectify (chsasank) + segment (SegFormer/SAM)
> + SDXL img2img" approach described below was tried and **failed** to produce clean
> isolated atoms (see Implementation Findings above). **Use an instruction-following
> image-EDIT model instead** (GPT-image-1 / Gemini / FLUX Kontext / Qwen-Image-Edit):
> feed ONE photo + a specific per-atom prompt; it rectifies + isolates + cleans + reframes
> in one shot. Then locally: chroma-key `#FF00FF`→alpha (if no native alpha), exact-resize
> to the atom spec, seam/tiling check for walls. The rectification/segmentation steps below
> are retained only as an optional ROI/pre-crop aid, not the atom generator.

This is the hardest production stage. Because DCH generation is photo-driven,
the pipeline must convert cleared real photographs into role-specific,
orthographic conditioning inputs before any atom is generated.

Required processing stages:

1. **Rights filter**
   - Select only conditioning-approved photos from the provenance manifest:
     owned/self-captured, CC0/public-domain, properly licensed stock, or CC-BY
     with attribution records.
   - Keep Mapillary/KartaView, developer, listing, and marketing images as
     research evidence only unless explicit rights are cleared.
   - Block promotion if any conditioning input lacks URL/id, content hash,
     license, and use-policy.
2. **Perspective rectification**
   - Rectify each selected facade photo to an orthographic front view.
   - Remove baked perspective so wall/window/balcony atoms tile cleanly in the
     renderer.
   - Store before/after images and transform metadata.
3. **Component segmentation**
   - Segment by role:
     - `wall`;
     - `window`;
     - `mid-window`;
     - `mid-balcony`;
     - `long-balcony`;
     - `roofbottom` / crown band.
   - Produce masks and crops with clean role labels.
4. **Occlusion cleanup**
   - Remove trees, cars, people, street furniture, signage, strong reflections
     of other buildings, watermarks, and text overlays.
   - Repair missing wall/window/balcony areas by inpainting, but record that the
     crop was repaired.
5. **Alpha preparation**
   - Wall and roof/crown crops must be opaque.
   - Window, balcony, and loggia crops must have clean alpha with no pink/chroma
     background.
   - Balcony glass should retain transparent/translucent regions only if the
     renderer path supports the intended material; otherwise keep alpha clean
     and move reflectivity to the in-engine glass material task.
6. **Per-role photo-conditioned generation**
   - Use rectified role crops as the primary input to img2img, ControlNet
     tile/depth/segmentation, and/or IP-adapter.
   - Text prompts are auxiliary: they describe cleanup, role constraints, exact
     canvas size, material consistency, and "do not copy logos/signage/people."
   - Walls can often be near-direct from a clean rectified flat facade crop.
   - Windows and balconies should use the photo as a strong reference plus
     synthesized clean alpha.
7. **Exact sizing and tile validation**
   - Enforce the existing facade grid:
     - `160 px/m` horizontally;
     - `512 px` per floor;
     - `512/768/1024 px` for `wall`/`mid-wall`/`long-wall`.
   - Test wall atoms for seamless or near-seamless tiling.
   - Ensure all variants of a role share one canvas size so physical dimensions
     do not jitter in-game.
   - For overlay atoms, check visible alpha bbox heights across `window`,
     `mid-window`, and `mid-balcony`; they should match within the same floor
     band.
   - For `full_cell` atoms, check that the image contains exactly one
     floor/cell from edge to edge. Neighboring floors must not leak into the
     top or bottom of the atom.

Create:

```text
decorations/uae/dubai_creek_harbour/
  gulf-residential-mid-class-tower-1-atoms/
    wall-1.png
    wall-2.png
    mid-wall-1.png
    long-wall-1.png
    window-1.png
    window-2.png
    window-3.png
    window-4.png
    mid-window-1.png
    mid-window-2.png
    mid-window-3.png
    mid-window-4.png
    mid-balcony-1.png
    mid-balcony-2.png
    mid-balcony-3.png
    mid-balcony-4.png
    long-balcony-1.png
    long-balcony-2.png
    long-balcony-3.png
    long-balcony-4.png
    window-emission-1.png
    window-emission-2.png
    window-emission-3.png
    window-emission-4.png
  gulf-residential-mid-class-tower-2-atoms/
    ...
  gulf-residential-mid-class-tower-3-atoms/
    ...
```

Dimensions:

| Role | Size | Notes |
|---|---:|---|
| `wall` | `512x512` | Pale clean facade panel, no seams, opaque |
| `mid-wall` | `768x512` | Same material, not stretched from 512 |
| `long-wall` | `1024x512` | Same material, supports long balcony |
| `window` | `512x512` or measured per archetype | Either alpha overlay or opaque one-floor full-cell, depending on visual inventory |
| `mid-window` | `768x512` or measured per archetype | Wider glazing; may be opaque full-cell for curtain-wall towers |
| `mid-balcony` | `512x512`, `700x512`, or `768x512` | Glass balcony; may be alpha overlay or opaque one-floor full-cell |
| `long-balcony` | `1024x512` | Long stacked balcony/loggia strip |
| `architectural-reveal` / `bay-joint` | TBD | DCH-specific subtle seam family; not generated in first pass |
| `podium-screen` | TBD | New podium role; documented, postponed |
| `podium-glazing` | TBD | New podium role; documented, postponed |
| `roofbottom` / `soffit` | TBD | Crown/underside role; documented, postponed |
| `window-emission-*` | same as matching window | Warm interior glow masks |

Generation policy:

- Use real Dubai Creek Harbour photographs as primary generation-conditioning
  inputs.
- Use only owned, CC0, public-domain, CC-BY-with-attribution, properly licensed
  stock, or otherwise explicitly cleared photos for conditioning.
- Do not condition directly on Property Finder, Emaar, Mapillary, KartaView, or
  other research-only images unless legal clearance changes the policy.
- Use text prompts only as auxiliary constraints layered on top of photo
  conditioning.
- Postprocess every PNG to exact dimensions.
- Validate alpha:
  - wall: opaque;
  - windows/balconies: alpha channel required;
  - no pink/chroma background in final assets.

Auxiliary prompt direction for a wall crop:

```text
Using the provided rectified Dubai Creek Harbour facade photo crop as the
primary visual source, produce a one-floor wall atom: clean off-white concrete
and light beige stone texture, subtle sun fading and dust, no panel seams, no
windows, no balconies, orthographic, seamless/near-seamless game texture atom,
exact 512x512 canvas, preserve the source material feel without copying logos,
signage, people, cars, or distinctive protected artwork.
```

Auxiliary prompt direction for a balcony crop:

```text
Using the provided rectified Dubai Creek Harbour balcony photo crop as the
primary visual source, produce a transparent PNG cutout of a modern glass
balcony module: clear glass railing with slight blue-green tint, slim dark
metal mullions, pale slab edges, clean new-build finish, orthographic, clean
alpha, no wall texture, no logos, no people, exact target canvas.
```

## Phase 5: Write the First DCH Archetype JSON

Target file:

```text
decorations/uae/dubai_creek_harbour/facades/gulf-residential-mid-class-tower-1.json
```

Draft:

```json
{
  "id": "gulf-residential-mid-class-tower-1",
  "category": "modern",
  "material_tags": ["modern", "glass", "concrete", "residential_tower"],
  "style_family": "gulf_masterplan_uppermid_residential",
  "district_tags": ["uppermid", "masterplan", "newbuild", "glass_balcony"],
  "communities": ["dubai_creek_harbour", "dubai_hills", "creek_beach", "emaar_beachfront"],
  "not_for_communities": ["dubai_marina", "downtown_dubai", "business_bay"],
  "regions": ["uae", "dubai"],
  "min_floors": 12,
  "max_floors": 80,
  "has_seams": false,
  "has_roofbottom": false,
  "balcony_placement": "full_height",
  "atom_dir": "res://decorations/uae/dubai_creek_harbour/gulf-residential-mid-class-tower-1-atoms/",
  "atoms": {
    "wall": ["wall-1", "wall-2"],
    "mid-wall": ["mid-wall-1"],
    "long-wall": ["long-wall-1"],
    "window": ["window-1", "window-2", "window-3", "window-4"],
    "mid-window": ["mid-window-1", "mid-window-2", "mid-window-3", "mid-window-4"],
    "mid-balcony": ["mid-balcony-1", "mid-balcony-2", "mid-balcony-3", "mid-balcony-4"],
    "long-balcony": ["long-balcony-1", "long-balcony-2", "long-balcony-3", "long-balcony-4"]
  },
  "slot_overrides": {
    "window": {"overlay_offset_top_px": 32},
    "mid-window": {"overlay_offset_top_px": 32}
  },
  "molecules": [
    {
      "id": "t1-window-midbal-window",
      "slots": ["window", "mid-balcony", "window"],
      "tags": ["any"]
    },
    {
      "id": "t1-midwin-midbal-midwin",
      "slots": ["mid-window", "mid-balcony", "mid-window"],
      "tags": ["any"]
    },
    {
      "id": "t1-window-midwin-midbal-window",
      "slots": ["window", "mid-window", "mid-balcony", "window"],
      "tags": ["long"]
    },
    {
      "id": "t1-longbal-midwin-window",
      "slots": ["long-balcony", "mid-window", "window"],
      "tags": ["long"]
    }
  ],
  "slot_extrusion": {
    "mid-balcony": {"depth_m": 0.7, "shape": "box"},
    "long-balcony": {"depth_m": 0.7, "shape": "box"}
  }
}
```

Notes:

- `gulf-residential-mid-class-tower-2` and `gulf-residential-mid-class-tower-3`
  should not reuse the exact `tower-1` molecule list. Their source facades have
  different bay logic:
  - `tower-2`: `t2-glass-balcony-glass`,
    `t2-glass-wall-balcony-glass`,
    `t2-glass-balcony-wall-balcony-glass`,
    `t2-glass-wall-glass`.
  - `tower-3`: `t3-window-window-balcony-servicewall`,
    `t3-window-balcony-window-servicewall`,
    `t3-window-window-window-servicewall`,
    `t3-balcony-window-balcony-servicewall`, plus the future
    `t3-louver-louver-louver-servicewall` crown/service molecule.
- See `DCH_PIPELINE_PROGRESS.md` for the full molecule inventory and the visual
  reasoning behind each molecule.
- `category = modern` requires code support. If we need a very quick visual
  test before code cleanup, temporarily map DCH fallback material to `panel`,
  but the proper implementation should add `modern`.
- `long-balcony` extrusion is important for DCH; current Cherepovets configs
  mostly extrude only `mid-balcony`.
- Tall `window` overlays should be tested because current window convention is
  `320x320`; the renderer supports other sizes, but the result must be viewed
  in Godot.
- `podium-screen`, `podium-glazing`, and `roofbottom`/`soffit` are intentionally
  omitted from the first residential-body JSON. Add them after the basic body
  reads correctly.

## Required Render-Side Tasks

Photo-driven assets do not solve two engine-side problems. These are mandatory
for DCH-style towers and should be implemented separately from atom generation.

### Vertical Zonation

The assembler must support vertical facade zones:

1. `podium` / ground band;
2. `body` / typical repeating residential floors;
3. `crown` / parapet or mechanical-screen band.

Without zonation, 30-80 floor towers stack one identical molecule loop and read
as a barcode. The first implementation can be simple:

- first 1-3 floors use podium-capable molecules or existing storefront row
  alignment;
- middle floors use the typical balcony/window body molecules;
- top 1-3 floors use future `roofbottom`/`long-roofbottom` or crown-specific
  molecules after those atoms exist.

Acceptance:

- 40-60 floor previews have a readable base, body, and crown.
- The body can still repeat, but the whole tower must not look like one
  endlessly tiled strip.

### In-Engine Glass Material

Floor-to-ceiling glazing needs a real in-engine material, not only a painted
blue/green texture. Add a glass material path for DCH window/balcony overlays:

- cubemap/skybox reflection or screen-space reflection where available;
- tint and roughness controls;
- emission mask compatibility for night windows;
- fallback that still reads as glass on low settings.

Acceptance:

- daytime windows reflect sky/environment enough to read as glass;
- night windows can glow without turning the whole glass facade flat;
- balcony glass does not become an opaque painted rectangle.

## Phase 6: Generalize Runtime Facade Selection

Current blocker:

- [FacadeAssembler](../osm/facade_assembler.gd) hardcodes:
  - `ARCHETYPES_DIR := "res://decorations/russia/cherepovets/facades/"`
- [OSM terrain generator](../osm/osm_terrain_generator.gd) only tries
  `FacadeAssembler` when `_is_cherepovets_location()` is true.
- `_is_cherepovets_location()` currently returns `_decoration_layer != null`,
  which is a latent bug once multiple decoration sources exist.

Implementation tasks:

Build one shared, city-agnostic `FacadeArchetypeRegistry`. This is the same
infrastructure the Antalya plan needs, so do it once and route both DCH and
Antalya through it.

1. Add active decoration source selection.
   - Use `decorations/index.json` bounds.
   - At runtime, find sources whose bounds contain `start_lat/start_lon`.
   - Expose active source ids and active community ids.
   - Preserve Cherepovets behavior exactly when the active source is
     Cherepovets.
2. Move facade archetype discovery into `FacadeArchetypeRegistry`.
   - Load archetype dirs from active decoration sources instead of
     `ARCHETYPES_DIR`.
   - Resolve atoms once, cache by archetype id, and expose selection queries.
   - Remove the need for `FacadeAssembler` to know a city-specific folder.
3. Replace `_is_cherepovets_location()` as a facade gate.
   - Do not use `_decoration_layer != null` as a city test.
   - Ask the registry whether any facade archetypes are active for the current
     location/community.
4. Add style-family/community matching.
   - Match DCH using `style_family` and curated `communities`.
   - Reject `not_for_communities`.
   - Keep category/floor filters as additional constraints.
5. Add category mapping for DCH.
   - Extend `_tag_to_category()` with:
     - `modern`
     - `glass`
     - `concrete`
     - `residential_tower`
   - For active source `dubai_creek_harbour`, if a building is residential and
     no material tag exists, default to `modern`.
6. Keep Cherepovets behavior stable.
   - For Cherepovets, preserve the current brick/panel deterministic fallback.
   - Do not let DCH archetypes enter Cherepovets selection.
7. Floors and no-data safety:
   - Support `max_floors` up to `80`.
   - Prefer `building:levels`.
   - If missing, estimate `round(height / 3.2)`.
   - If both `building:levels` and height are missing, use a sane community
     default and a hard cap for no-data buildings.
   - For the first DCH pass, use a conservative no-data cap such as 18 floors
     unless a trusted source provides a higher value.
   - Never spawn a 200 m mystery block from missing OSM data.
8. Building skip list:
   - Continue skipping `hangar`, `industrial`, `warehouse`, `roof`, `carport`.
   - In DCH bbox this matters because OSM sanity checks can pick up nearby
     non-residential buildings.
9. Performance guardrails:
   - Tower districts multiply quad/vertex counts compared with 4-20 floor
     Cherepovets buildings.
   - Track facade batches, material count, and visible tower count during DCH
     previews; see [Facade performance debug notes](FACADE_PERF_DEBUG.md).
   - Add LOD or batching follow-up if 40-80 floor towers regress frame time.

Acceptance:

- Starting in Cherepovets still selects only Cherepovets archetypes.
- Starting in Dubai Creek Harbour selects the curated
  `gulf-residential-mid-class-tower-*` archetypes for matching residential
  towers/mid-rises.
- If DCH assets are missing, fallback remains graceful.

## Phase 7: Godot Preview Harness

Before running on real DCH OSM, create synthetic preview buildings:

```text
previews/dubai_creek_harbour/
  highrise_20f_rect.png
  highrise_40f_rect.png
  highrise_60f_tower_pair.png
  midrise_10f_creek_beach.png
  night_highrise_40f.png
```

Preview cases:

1. 12-floor rectangular block.
2. 30-floor slim tower.
3. 45-floor tower pair with long edges.
4. 60-floor high-rise with crown band.
5. 10-floor Creek Beach-style block, even if using the same first archetype.
6. Night mode with emission masks.
7. Storefront row test with fake POIs on the podium side.

Checks:

- walls are not stretched/blurry;
- tall windows fit inside each floor;
- balcony extrusion faces do not z-fight;
- `long-balcony` extrusion works;
- postponed roofbottom/crown does not block body preview;
- podium/body/crown zonation is visible on tall towers;
- floor-to-ceiling glazing uses the in-engine glass material and does not read
  as flat painted blue texture;
- night emission is visible but not noisy;
- no post-Soviet panel seams appear; DCH bay joints/reveals are subtle and
  intentional if present;
- facade does not read as Cherepovets recolor.

## Phase 8: Real OSM DCH Test

Run on a small viewport first.

Recommended test starts:

1. Creek Island / marina-facing towers.
2. Creek Beach mid-rise zone.
3. Edge near Ras Al Khor where non-target buildings may enter bbox.

Expected issues:

- OSM `building:levels` may be missing.
- Some buildings may be tagged only `building=yes`.
- Some DCH towers may not have individual names.
- Bbox may include industrial/hangar footprints outside the intended district.
- Storefront POIs may be sparse, so podium identity may be underrepresented.
- Tall towers may expose repetition more strongly than 4-20 floor Cherepovets
  buildings.
- Tower-heavy views may regress performance because DCH multiplies
  facade quads/vertices; compare against [Facade performance debug notes](FACADE_PERF_DEBUG.md).

Acceptance:

- At least 70 percent of visible DCH residential towers use DCH facade pack.
- No obvious DCH facade appears in Cherepovets.
- Industrial/hangar buildings in/near bbox do not get luxury residential glass
  facades.
- First-person and chase-camera screenshots read as modern Dubai waterfront
  residential fabric.
- Human reviewer marks the result `place-plausible`.

## Phase 9: Iterate to a Second Archetype

Only after the first archetype works:

1. Split high-rise vs Creek Beach mid-rise.
2. Add a second style-family archetype such as
   `gulf-masterplan-creek-beach-light-midrise-1`.
3. Add a stronger podium/storefront treatment if OSM POIs support it.
4. Add district weights:
   - Creek Island: high-rise pack high weight.
   - Creek Beach: mid-rise pack high weight.
   - Non-target bbox edges: fallback or neutral Dubai modern pack.
5. Consider visual clustering only after enough references are cached.

## Implementation Order

Recommended order for this repo:

1. Add `docs/DUBAI_CREEK_HARBOUR_FACADE_PIPELINE_PLAN.md`.
2. Add `data/facade_pipeline/dubai_creek_harbour/city_config.json`.
3. Scaffold `tools/facade_pipeline` enough to run Stage 0 source collection and
   write manifests/contact sheets/conditioning candidates.
4. Run DCH Stage 0 and produce the style brief plus cleared conditioning-photo
   shortlist.
5. Human review of the style brief, contact sheet, and conditioning-photo
   rights/provenance.
6. Rectify approved photos, segment components, remove occlusions, and prepare
   role-specific conditioning crops.
7. Generate atom PNGs from those photo-conditioned crops and postprocess exact
   dimensions/alpha/seamless tiling.
8. Write the style-family archetype JSON.
9. Build the shared `FacadeArchetypeRegistry` and active-source selection used
   by both DCH and Antalya.
10. Add vertical zonation support for podium/body/crown.
11. Add or improve the in-engine glass material path.
12. Add synthetic preview scene/test.
13. Run DCH OSM preview.
14. Iterate assets, molecules, zonation, and glass material.
15. Only then add a second style-family archetype.

## Open Caveats

- Developer/listing imagery is probably the best style evidence but not a safe
  generation input without permission.
- Dubai Creek Harbour has many renders and marketing images; the AI must
  distinguish built facade evidence from off-plan fantasy.
- Street-level imagery may be sparse inside private/promotional waterfront
  zones.
- OSM may under-tag floors/materials.
- Current roofbottom is a simple crown band. Some DCH towers may need more
  expressive roof/mechanical screens later.
- The existing storefront row may need Dubai-specific sign colors/materials to
  avoid looking Russian/post-Soviet.
- A clean luxury district can look too sterile in-game; add subtle sun/dust,
  reflections, balcony shadows, and interior glow variation.

## Definition of Done for the First DCH Slice

The first slice is done when:

1. Stage 0 produces a cached, evidence-cited DCH style brief.
2. Research artifacts include source URLs, licenses/use policies, hashes, and
   snapshots where allowed.
3. Conditioning photos have cleared rights and per-input provenance.
4. Rectified/segmented conditioning crops exist for wall, window, balcony, and
   crown roles.
5. One photo-conditioned generated atom pack passes exact-dimension, alpha, and
   tiling validation.
6. One style-family archetype JSON validates and references existing atoms.
7. Runtime selection can load the curated style-family archetype without
   affecting Cherepovets.
8. Vertical zonation prevents 30-80 floor towers from becoming a barcode loop.
9. The in-engine glass material reads as glass in day and night previews.
10. Godot synthetic previews pass day/night visual QA.
11. A real DCH OSM preview looks place-plausible to a human reviewer.
