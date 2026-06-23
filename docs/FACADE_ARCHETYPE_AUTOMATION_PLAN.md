# Automated Facade Archetype Pipeline

This plan describes how to turn a city or district name, such as Antalya, into
a set of usable OSM Racing facade archetypes: researched visual style, source
imagery, generated atom textures, molecule definitions, JSON archetypes, and
Godot preview/QA.

The intended collaboration model is: an AI/ML engineer builds the pipeline and
automation, while a local-history / urban-fabric expert validates whether the
result actually feels like the place.

## Existing Repo Context

This plan builds on the current modular facade system:

- [Facade archetype pipeline notes](FACADE_ARCHETYPE_PIPELINE.md)
- [Facade archetype draft](../decorations/facade_archetypes_DRAFT.md)
- [Generic facade assembler](../osm/facade_assembler.gd)
- [111-125 custom facade prototype](../osm/facade_111_125.gd)
- [Decoration layer loader](../osm/decoration_layer.gd)
- [Building override resource](../osm/decorations/building_override.gd)
- [Cherepovets building overrides](../decorations/russia/cherepovets/building_overrides.json)
- [Current facade archetype JSONs](../decorations/russia/cherepovets/facades)
- [Default panel atom textures](../decorations/russia/cherepovets/default-panels-atoms)
- [Default brick atom textures](../decorations/russia/cherepovets/default-bricks-atoms)

The current system already supports:

- wall atoms in `512x512`, `768x512`, and `1024x512`;
- overlay atoms for windows, balconies, loggias, and entrances;
- optional panel seams through `has_seams`;
- optional roofbottom/crown bands through `has_roofbottom`;
- molecule-based facade rhythm;
- deterministic archetype selection by material/floors/`way_id`;
- balcony extrusion through `slot_extrusion`.

## Target Outcome

Given a city and optionally a district or bounding box, the pipeline should
produce:

1. A researched urban-style report for the city/district.
2. A dataset manifest of source imagery and licenses.
3. A set of style reference images and optional cropped component references.
4. One or more generated atom texture packs.
5. One or more generated facade archetype JSON files.
6. A Godot preview scene or test harness with screenshots.
7. A QA report with pass/fail checks and human-review notes.

Example output archetypes for Antalya might be:

- `antalya-konyaalti-white-balcony-midrise-1`
- `antalya-muratpasa-shopfront-apartment-1`
- `antalya-kaleici-lowrise-plaster-1`
- `antalya-new-residential-glass-balcony-1`

## Non-Goals

- Do not reproduce every real building exactly.
- Do not scrape Google Street View or Google Maps as an automated data source.
- Do not encode real shop logos/signs into generic archetypes unless the asset
  rights and game-design intent are explicit.
- Do not ship generated assets without license/provenance records.
- Do not let the model silently decide that a generic Mediterranean style is
  "Antalya enough"; human validation is required.

## Revised Near-Term Strategy

The full city-to-archetypes pipeline is the long-term direction. The near-term
implementation deliberately focuses on the highest-value human bottleneck:
automating the AI "local urban researcher" step. This is the most labor-
intensive part of the current workflow, so Stage 0 is the primary experiment,
not a thin pre-step.

```text
experimental AI urban research + reference discovery
  -> approved style references
  -> generated atom pack
  -> validated archetype JSON
  -> minimal city-level runtime selector
  -> Godot preview
  -> one visible in-game Antalya archetype
```

The first shippable slice still depends on the deterministic part that makes
generated assets appear in the game, but we should lean into research/reference
automation now: web/OSM context search, ordinary-housing imagery discovery,
coverage checks, reference ranking, and style-brief synthesis. If AI-led
research fails, the pipeline falls back to manually supplied references.

1. **Experimental Stage 0:** AI acts as an urban researcher: gathers OSM/web
   context, finds open imagery candidates, ranks facade references, writes a
   style brief, and proposes archetype roles.
2. **Milestone 1:** reference-guided atom generation, postprocessing, JSON
   writing, and Godot preview.
3. **Minimal Stage 7:** city-level archetype pools keyed by the current free-roam
   city/location. District-level weights can come later.
4. **Minimal new catalog roles:** add only the 1-2 roles needed to keep the
   first Antalya archetype from becoming a recolored post-Soviet panel block.
   Good first candidates are `shopfront` and `crown`/`roofline`.
5. **Fixed seed support:** make "same series, same atom variants" a normal
   archetype feature instead of a one-off special case like
   [111-125](../osm/facade_111_125.gd).

Full embedding-based visual clustering and automatic facade rectification remain
useful, but they follow later. Stage 0 is the active near-term implementation of
research and reference discovery. Stages 1-4 describe the fuller long-term
decomposition of the same work and should not be built in parallel yet.

## Recommended External Data Sources

Use sources with API access and clear enough terms for an automated workflow:

- [OpenStreetMap / Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API)
  for buildings, roads, shops, amenities, districts, and tags.
- [Overpass output formats](https://dev.overpass-api.de/output_formats.html)
  for machine-readable OSM extraction.
- [Mapillary API](https://www.mapillary.com/developer/api-documentation)
  for street-level imagery and metadata.
- [Mapillary CC-BY-SA license note](https://help.mapillary.com/hc/en-us/articles/115001770409-CC-BY-SA-license-for-open-data)
  for imagery license constraints.
- [KartaView API documentation](https://kartaview.org/doc/api-response) and
  [KartaView FAQ](https://kartaview.org/doc/faq) for another street-level
  imagery source.
- [KartaView terms](https://kartaview.org/terms) for imagery license
  constraints.
- [Wikimedia Commons API](https://commons.wikimedia.org/wiki/Commons:API) and
  [Wikimedia API Portal](https://api.wikimedia.org/wiki/Main_Page) for openly
  licensed landmark and city imagery.
- [Flickr API](https://www.flickr.com/services/api/) and
  [Flickr photo search](https://www.flickr.com/services/api/flickr.photos.search.html)
  for geotagged Creative-Commons or rights-filtered imagery.
- Real-estate / housing-market portals for ordinary housing research, e.g.
  [sahibinden](https://www.sahibinden.com/),
  [Emlakjet](https://www.emlakjet.com/), and
  [Hepsiemlak](https://www.hepsiemlak.com/en).
- Developer / new-build residential project pages for recent construction
  references and marketed facade typologies.
- Housing-stock statistics by construction year/type, e.g.
  [TurkStat data portal](https://data.tuik.gov.tr/en/) for Turkey, when
  available.
- Academic urban-morphology papers, theses, and planning documents for local
  fabric interpretation.

Optional sources for research only:

- local government open data;
- urban planning PDFs;
- manually supplied screenshots from a human researcher;
- local walking videos, only if licensing and derivative-use rules are clear.

### Source and derivative-license policy

Each source must be tagged with a use policy in `source_manifest.json`:

| Source type | Use policy |
|---|---|
| Own photos / project-created references | Allowed for generation conditioning and asset creation |
| CC0 / public-domain references | Allowed for generation conditioning and asset creation |
| Explicitly licensed asset references | Allowed according to the license terms |
| Mapillary imagery | CC-BY-SA; use for human style understanding by default; generation conditioning needs legal review |
| KartaView imagery | CC-BY-SA; use for human style understanding by default; generation conditioning needs legal review |
| Wikimedia Commons | Depends on per-file license; CC0/public-domain preferred for conditioning |
| Flickr / similar | Depends on per-file license and API terms; CC0/public-domain preferred for conditioning |
| Real-estate listing portals | Style-understanding only unless rights are explicitly cleared |
| Developer project pages | Style-understanding only unless rights are explicitly cleared |
| Academic papers / theses | Style-understanding only; do not extract images for assets unless rights allow |
| Housing-stock statistics | Safe as factual context/proportions, not image conditioning |

Default-safe approach: use open/listing/street-level imagery for **human style
understanding and cited evidence**, then generate atoms primarily from text
prompts plus owned, CC0, public-domain, or explicitly cleared references. This
avoids contaminating game assets with uncertain derivative-license obligations.
The open legal question is whether conditioning on CC-BY-SA imagery propagates
attribution/share-alike obligations to generated atom textures; until resolved,
avoid using CC-BY-SA imagery as direct generation conditioning for shippable
game assets.

## Proposed Repository Layout

Add a pipeline folder under `tools/`:

```text
tools/facade_pipeline/
  README.md
  pyproject.toml
  facade_pipeline/
    cli.py
    config.py
    osm_overpass.py
    imagery_sources/
      mapillary.py
      kartaview.py
      wikimedia.py
      local_uploads.py
    clustering/
      urban_grid.py
      feature_builder.py
      cluster_styles.py
    vision/
      score_images.py
      extract_facade_crops.py
      rectify.py
      component_classifier.py
    generation/
      prompt_templates.py
      atom_generator.py
      emission_masks.py
      postprocess_png.py
    archetypes/
      schema.py
      molecule_generator.py
      write_archetype_json.py
      validate_archetype.py
    godot/
      write_preview_scene.py
      run_preview.py
      screenshot_report.py
    reports/
      write_city_report.py
      write_qa_report.py
```

Generated/intermediate data should not be mixed with game assets until QA
passes:

```text
data/facade_pipeline/
  antalya/
    city_config.json
    source_manifest.json
    osm/
    imagery/
    references/
    crops/
    clusters/
    research/
    generated_atoms/
    generated_archetypes/
    previews/
    reports/
```

Final approved game assets should be copied into a game-facing location:

```text
decorations/turkey/antalya/
  facades/
  antalya-...-atoms/
  meta.json
```

## City Config

Each run starts from a city config:

```json
{
  "city_id": "antalya",
  "display_name": "Antalya",
  "country": "turkey",
  "bbox": [36.78, 30.55, 36.98, 30.90],
  "districts": [
    {
      "id": "konyaalti",
      "name": "Konyaalti",
      "bbox": [36.84, 30.55, 36.92, 30.70]
    }
  ],
  "target_archetype_count": 4,
  "preferred_sources": ["osm", "mapillary", "kartaview", "wikimedia", "local_uploads"],
  "style_notes": ""
}
```

The city expert may override or annotate districts before imagery collection.

## Stage 0: Experimental AI Urban Research and Reference Discovery

This is an experimental attempt to automate the most labor-intensive human
step: acting as the local urban researcher. The AI should try to discover what
the city/district looks like, where the dominant building fabrics are, and
which facade references are useful for atom generation.

Stage 0 output is **candidates to verify**, never authoritative truth. When the
team does not know the city well, keep a local validator in the loop before
promoting any archetype.

If this stage fails or produces generic/wrong results, the pipeline falls back
to manually supplied style references. The fallback is part of the design, not
a failure of the whole pipeline.

Command:

```bash
python -m facade_pipeline.cli research-references \
  --config data/facade_pipeline/antalya/city_config.json \
  --goal "dominant residential facade look, not landmarks" \
  --max-reference-candidates 120 \
  --target-approved-references 30
```

### Inputs

- `city_config.json`
- optional user goal, e.g. "mass residential midrise, not hotels";
- optional negative style notes, e.g. "avoid luxury resort facades";
- optional seed coordinates or districts;
- available API credentials for Mapillary/KartaView if required.

### Tasks

1. **Run an early residential coverage pre-check**
   - Treat this as the first gate of Stage 0.
   - Query OSM/Overpass for residential building footprints in the bbox.
   - Sample candidate search points weighted by residential footprint density,
     not by road density or imagery availability.
   - Cheaply probe Mapillary/KartaView/Wikimedia/local uploads for usable
     imagery density near those footprints.
   - Report zones with zero usable coverage.
   - If ordinary-housing coverage is thin, escalate immediately to real-estate
     portals, developer pages, housing-stock statistics, academic urban-
     morphology sources, or manual fallback.

2. **Define the research target**
   - Extract city/country/bbox from config.
   - Clarify whether the target is city-wide or district-specific.
   - Convert the user goal into search facets:
     - residential midrise;
     - mixed-use streets;
     - old town / low-rise;
     - coastal apartment fabric;
     - new residential blocks.

3. **Collect text and map context**
   - Query OSM/Overpass for buildings, roads, POIs, and district boundaries.
   - Search the web for broad urban-form clues:
     - district names;
     - common residential forms;
     - old town vs new residential areas;
     - local construction details;
     - planning/open-data references if available.
   - Search real-estate / housing-market sources for ordinary apartment
     exteriors and district-tagged housing stock, but mark those images as
     research-only unless rights are cleared.
   - Search developer/new-build pages for recent apartment typologies, but mark
     those images as research-only unless rights are cleared.
   - Search housing-stock statistics by construction year/type to infer dominant
     eras and typologies.
   - Search academic urban-morphology papers/theses for local fabric signals.
   - Record source URLs and short evidence snippets in a research manifest.

4. **Build a first-pass urban-fabric hypothesis**
   - Estimate common floor counts from OSM tags where available.
   - Infer likely building types from footprints and POI density.
   - Identify candidate zones:
     - dense apartment zone;
     - commercial/mixed-use streets;
     - old low-rise zone;
     - new-development zone.
   - Output a preliminary list of visual archetype hypotheses.

5. **Discover facade imagery candidates**
   - Query Mapillary around residential-footprint-weighted sample points.
   - Query KartaView around residential-footprint-weighted sample points.
   - Query Wikimedia Commons for geotagged or category-based city images.
   - Query geotagged Flickr / similar sources with rights filters where
     possible.
   - Collect real-estate/developer photos as research-only evidence when useful.
   - Include local user-uploaded folders if provided.
   - Do not scrape Google Street View or Google Maps.

6. **Rank images as facade references**
   - Prefer photos where a facade is visible and reasonably large.
   - Penalize images dominated by road, sky, trees, people, cars, or landmarks.
   - Prefer ordinary residential/mixed-use streets over iconic buildings.
   - Detect likely facade features:
     - wall color/material;
     - windows;
     - balconies/loggias;
     - ground-floor shops;
     - awnings;
     - AC units;
     - roofline/cornice;
     - seams or lack of seams.
   - Keep source provenance for every candidate.

7. **Select one initial candidate archetype**
   - Do not run embedding-based visual clustering in the first Stage 0 run.
   - Pick one ordinary-housing candidate fabric from the ranked evidence.
   - Give it a provisional label such as:
     - `coastal-white-balcony-midrise`;
     - `dense-mixed-use-shopfront`;
     - `old-town-lowrise-plaster`;
     - `new-glass-balcony-residential`.
   - Generate a contact sheet for this single candidate archetype.

8. **Write an evidence-cited AI style brief**
   - Every visual claim must cite at least one selected reference image with
     provenance. This is the main defense against confident generic output.
   - Write:
     - why the candidate is place-plausible;
     - dominant colors/materials;
     - window style;
     - balcony/loggia style;
     - ground-floor treatment;
     - roof/crown treatment;
     - whether seams exist;
     - recommended atom roles;
     - recommended molecule rhythms;
     - what to avoid.

9. **Select an initial reference set**
   - Pick the best reference images for the candidate archetype.
   - Mark each image's role:
     - `style_overall`;
     - `wall_reference`;
     - `window_reference`;
     - `balcony_reference`;
     - `shopfront_reference`;
     - `roofline_reference`;
     - `negative_reference`.
   - Produce an approval queue for the human reviewer.

10. **Snapshot for reproducibility**
   - Cache actual image bytes, not only URLs.
   - Store source URL, source ID, content hash, capture/download timestamp, and
     source license/use policy.
   - Store the model version, prompt version, and style brief timestamp.
   - Make every Stage 0 sub-step independently cached and resumable.
   - On partial external-API failure, emit a `PARTIAL` research report instead
     of failing the whole run.

### Deliverables

- `research/urban_research_report.md`
- `research/source_evidence.json`
- `research/urban_fabric_hypotheses.json`
- `research/coverage_precheck.json`
- `research/zero_coverage_zones.geojson`
- `references/reference_candidates.json`
- `references/contact_sheets/*.png`
- `references/ai_style_briefs/*.md`
- `references/approval_queue.json`
- `references/snapshots/<source>/<image_hash>.*`
- `references/stage0_run_manifest.json`

### Human checkpoint

The city expert or art director reviews:

- whether the candidate archetype is plausible;
- whether the selected photos show ordinary city fabric, not landmarks;
- whether the style brief feels like the intended city/district;
- whether the candidate should be rejected or renamed;
- whether the pipeline should proceed with AI references or switch to manual
  references.

Possible outcomes:

- **approve:** continue to Stage 5 atom generation;
- **approve with edits:** adjust style brief, negative references, or role list;
- **manual fallback:** user supplies reference photos and notes;
- **retry:** change bbox, district, or search goal and rerun Stage 0.

### Quality gates

Stage 0 is allowed to be imperfect, but it must not silently pass bad research.
It passes only if:

1. Every selected reference has source/provenance metadata.
2. At least one plausible non-landmark residential/mixed-use candidate exists.
3. The style brief names concrete facade features, not generic city adjectives.
4. Every style-brief feature claim is backed by at least one cited reference
   image with provenance.
5. The proposed roles map to current or planned `SLOT_CATALOG` roles.
6. Negative references are recorded when the AI detects tourist/landmark/luxury
   imagery that should not drive generic mass housing.
7. A human can inspect contact sheets before generation.
8. The coverage pre-check lists zones with zero usable coverage.
9. The run snapshot contains cached image bytes, hashes, prompts/model versions,
   and timestamps.

### Fallback rules

Use manual fallback if:

- open imagery coverage is poor;
- references are mostly landmarks/hotels/tourist photos;
- AI ranks or groups references by lighting/source instead of architecture;
- the style brief sounds generic or wrong;
- source licensing is unclear;
- the first preview fails the place-plausibility check.

Manual fallback input should be simple:

```text
manual_refs/
  wall/
  windows/
  balconies/
  shopfronts/
  roofline/
  notes.md
```

The rest of the pipeline remains identical after references are approved.

### Near-term relationship to Stages 1-4

Stage 0 supersedes Stages 1-4 for the near-term implementation. Build Stage 0
first as the integrated AI urban-research/reference-discovery path. Stages 1-4
below document the fuller long-term decomposition of research, imagery
collection, clustering, and crop extraction, but they should not be implemented
in parallel with Stage 0 during the first Antalya prototype.

## Stage 1: OSM and Urban-Fabric Research

Command:

```bash
python -m facade_pipeline.cli research-city \
  --config data/facade_pipeline/antalya/city_config.json
```

Implementation tasks:

1. Query OSM buildings through Overpass:
   - `building=*`
   - `building:levels`
   - `height`
   - `building:material`
   - `roof:shape`
   - `roof:material`
   - `shop=*`, `amenity=*`, `name=*` inside or near buildings
2. Build derived features:
   - estimated floors;
   - building footprint area;
   - frontage length;
   - road adjacency;
   - likely residential/commercial/industrial type;
   - density per grid cell.
3. Create urban grid cells, ideally H3 or a simple fixed meter grid.
4. Produce a city report:
   - dominant building heights;
   - likely apartment zones;
   - likely old-town / low-rise zones;
   - likely commercial-frontage streets;
   - OSM tag completeness and gaps.

Deliverables:

- `osm/buildings.geojson`
- `osm/pois.geojson`
- `clusters/grid_features.parquet`
- `reports/urban_fabric_report.md`

Caveats:

- OSM `building:material` is often sparse.
- `building:levels` can be missing or wrong.
- Administrative districts may not match visual urban fabric.
- Building age is rarely available directly.

## Stage 2: Imagery Collection

Command:

```bash
python -m facade_pipeline.cli collect-imagery \
  --config data/facade_pipeline/antalya/city_config.json \
  --max-images-per-cell 20
```

Implementation tasks:

1. Sample points weighted by OSM residential building-footprint density, then
   project to nearby streets/frontages where imagery APIs require street
   positions.
2. Query Mapillary/KartaView/Wikimedia/local uploads.
3. Store imagery metadata before downloading pixels:
   - source;
   - source image ID;
   - URL;
   - license/terms marker;
   - lat/lon;
   - heading;
   - capture date;
   - district/grid cell.
4. Download only images passing basic checks:
   - high enough resolution;
   - not too dark;
   - not mostly sky/road;
   - likely contains a building facade.

Deliverables:

- `source_manifest.json`
- `imagery/raw/...`
- `imagery/thumbs/...`
- `reports/imagery_coverage.md`

Caveats:

- API tokens may be required.
- Street-level coverage is uneven.
- Images may be old.
- Some neighborhoods may have no usable open imagery.
- Legal terms must be checked per source and preserved in the manifest.

## Stage 3: Visual Clustering and Style Reports

Command:

```bash
python -m facade_pipeline.cli cluster-styles \
  --city antalya \
  --input data/facade_pipeline/antalya/imagery/raw
```

Implementation tasks:

1. Compute image embeddings for facade candidates.
2. Combine visual embeddings with OSM/grid features.
3. Cluster images into likely visual fabric groups.
4. Ask a VLM/LLM to summarize each cluster:
   - wall color and material;
   - window frame style;
   - balcony/loggia frequency;
   - AC units/awnings/railings;
   - roof/crown clues;
   - commercial ground-floor clues;
   - seams present or absent;
   - what makes the cluster place-plausible.
5. Generate contact sheets for human review.

Deliverables:

- `clusters/style_clusters.json`
- `reports/style_cluster_report.md`
- `reports/style_cluster_contact_sheets/*.png`

Human checkpoint:

- The city expert names clusters and marks which should become archetypes.
- Bad clusters are rejected before atom generation.

Caveats:

- Clustering can group by lighting/season/source instead of architecture.
- Tourist photos can overrepresent landmarks.
- New-build and old-build areas can be visually close but culturally distinct.

## Stage 4: Facade Reference Extraction

Command:

```bash
python -m facade_pipeline.cli extract-references \
  --city antalya \
  --cluster antalya-konyaalti-white-balcony-midrise
```

Important framing: street-level photos are primarily **style references and
conditioning inputs**, not guaranteed direct atom sources. Production atoms are
usually generated in Stage 5 from style references plus strict size/alpha
constraints. Direct crop-to-atom should be treated as an optimization that must
pass QA, not the default path.

Implementation tasks:

1. Score facade images as style references:
   - representative of the district;
   - clear enough to show materials and proportions;
   - not dominated by cars, trees, signs, or extreme lighting;
   - license/provenance present.
2. Optionally detect and rectify facade planes.
3. Optionally crop candidate components:
   - `wall_reference`
   - `window_reference`
   - `mid_window_reference`
   - `mid_balcony_reference`
   - `long_balcony_reference`
   - `entrance_reference`
   - `shopfront_reference`
   - `seam_reference`
4. Score crops:
   - frontal enough;
   - not occluded by trees/cars/people;
   - not overexposed;
   - component is not cut off;
   - background is removable.
5. Write reference metadata:
   - source image ID;
   - full-image role as a style reference;
   - optional crop box;
   - optional component class;
   - quality score;
   - district/cluster.

Deliverables:

- `references/<cluster>/style_refs/*.jpg`
- `crops/<cluster>/<component>/*.png`
- `references/<cluster>/reference_manifest.json`
- `reports/<cluster>_reference_contact_sheet.png`

Human checkpoint:

- Review and approve style references first.
- Review component crops only if they will be used for direct conditioning or
  direct atom extraction.

Caveats:

- Perspective correction is hard on narrow street images.
- Windows and balconies are often partially occluded.
- The "real crop -> production atom" path will often fail because of shadows,
  perspective, occlusion, and background contamination.
- Some cities need new roles, e.g. AC unit, awning, shutter, railing, satellite
  dish, security grille.

## Stage 5: Atom Generation

Command:

```bash
python -m facade_pipeline.cli generate-atoms \
  --city antalya \
  --cluster antalya-konyaalti-white-balcony-midrise \
  --profile panel_like_no_seams
```

Implementation tasks:

1. Use approved style references and optional component crops as conditioning.
2. Generate wall atoms:
   - `wall`: `512x512`
   - `mid-wall`: `768x512`
   - `long-wall`: `1024x512`
3. Generate overlays:
   - `window`: usually `320x320`, configurable per archetype;
   - `mid-window`: usually `480x320`;
   - `mid-balcony`: usually `700x512` or `768x512`;
   - `long-balcony`: usually `1024x512`;
   - `entrance`: usually `768x512` or a dedicated role;
   - optional `shopfront`;
   - optional city-specific roles such as `awning`, `ac-unit`, or `crown`.
4. Generate seams if the style cluster needs them:
   - `vertical-seam`: `30x572`;
   - `horizontal-seam`: `512x30`;
   - `horizontal-mid-seam`: `768x30`;
   - `horizontal-long-seam`: `1024x30`.
5. Generate optional emission masks:
   - `window-emission-N.png`;
   - possibly balcony/window mask variants.
6. Run postprocessing:
   - exact resize;
   - alpha cleanup;
   - chroma/pink background removal;
   - PNG optimization;
   - naming normalization.

Deliverables:

- `generated_atoms/<cluster>-atoms/*.png`
- `generated_atoms/<cluster>-atoms/atom_manifest.json`
- `reports/<cluster>_atom_contact_sheet.png`

Validation:

- walls are opaque;
- overlays have alpha;
- exact dimensions match role schema;
- no pink/chroma leftovers;
- wall/mid/long color histograms are compatible;
- all files referenced in manifest exist.

Caveats:

- Image generators frequently ignore exact pixel sizes.
- Alpha channels need deterministic postprocessing.
- Generated windows can become too clean/generic unless the prompt preserves
  local aging, curtains, grilles, AC shadows, etc.
- Reusing too many highly distinct windows can make buildings visually noisy.
- Per-archetype variant caps are needed: enough variation to avoid repetition,
  not so much that every facade becomes visual static.

## Stage 6: Molecule and Archetype Generation

Command:

```bash
python -m facade_pipeline.cli write-archetype \
  --city antalya \
  --cluster antalya-konyaalti-white-balcony-midrise
```

Implementation tasks:

1. Create molecule candidates from the style report.
2. Validate each molecule against available atom roles.
3. Add tags:
   - `any`
   - `short`
   - `long`
   - future: `front`, `side`, `ground`, `upper`
4. Decide metadata:
   - `category`;
   - `min_floors`;
   - `max_floors`;
   - `has_seams`;
   - `has_roofbottom`;
   - `slot_overrides`;
   - `slot_extrusion`;
   - variant seed mode.
5. Write JSON compatible with [generic facade assembler](../osm/facade_assembler.gd).
6. Write an archetype report explaining why each molecule exists.

Deliverables:

- `generated_archetypes/<cluster>.json`
- `reports/<cluster>_archetype_report.md`

Example molecule ideas for Antalya-like midrise residential:

```json
[
  {"id": "win-bal-win", "slots": ["window", "mid-balcony", "window"], "tags": ["any"]},
  {"id": "bal-win-bal", "slots": ["mid-balcony", "window", "mid-balcony"], "tags": ["long"]},
  {"id": "longbal-only", "slots": ["long-balcony"], "tags": ["any"]},
  {"id": "win-win-longbal", "slots": ["window", "window", "long-balcony"], "tags": ["long"]}
]
```

Caveats:

- The current assembler does not yet support per-district weights.
- `balcony_placement` is mostly metadata today; placement is driven by slot
  dimensions and `overlay_offset_top_px`.
- Ground-floor-only entrance/shopfront molecules need assembler extensions.
- Mediterranean/Turkish fabric needs at least minimal new roles and
  ground-floor support; otherwise the first archetype risks becoming a
  recolored panel archetype.

### Variant seed contract

The current generic assembler uses `way_id` as the seed, so each building using
the same archetype can get different window/balcony variants. That is good for
generic city texture, but not for a repeated building series. The 111-125
prototype hardcodes a fixed seed in GDScript. Generated archetypes need this as
data:

```json
{
  "variant_seed_mode": "way_id",
  "variant_seed": 0
}
```

or:

```json
{
  "variant_seed_mode": "fixed",
  "variant_seed": 45836637
}
```

Implementation note: this requires a small change in
[FacadeAssembler](../osm/facade_assembler.gd), where `_seed` is currently set
from `way_id` in `build()`.

## Stage 7: Selection and Applicability Upgrades

The current selector in [FacadeAssembler](../osm/facade_assembler.gd) chooses
by category, floor count, and `way_id` hash. It is also effectively
Cherepovets-scoped because `ARCHETYPES_DIR` points to
`res://decorations/russia/cherepovets/facades/`.

Near-term priority: implement a **minimal city-level selector** before
district-level richness. Without this, generated assets are invisible in-game.

Implementation tasks:

1. Add city-aware archetype roots:
   - Cherepovets keeps `res://decorations/russia/cherepovets/facades/`;
   - Antalya can use `res://decorations/turkey/antalya/facades/`.
2. Select the active city from the current free-roam location / city config
   before selecting an archetype.
3. Preserve Cherepovets behavior as the default fallback.
4. Add optional archetype fields for later district weighting:

```json
{
  "city_id": "antalya",
  "city_ids": ["antalya"],
  "regions": ["turkey/antalya/konyaalti"],
  "probability_weight": 1.0,
  "building_types": ["apartments", "residential"],
  "district_tags": ["coastal_midrise"],
  "source_pipeline": {
    "city": "antalya",
    "cluster": "konyaalti-white-balcony-midrise",
    "version": "0.1"
  }
}
```

Archetypes and atom packs are reusable across visually similar cities or
regions. If Antalya's ordinary apartment fabric plausibly matches another
coastal Turkish city, that city may reuse the same atoms/archetype. The
selection metadata should support this through multiple `city_ids` and/or
multiple entries in `regions`. The acceptance metric is **place-plausible**, not
"unique enough to distinguish this city from all others."

5. Later, add region lookup in `osm/osm_terrain_generator.gd`:
   - city bounds;
   - district polygons or grid cells;
   - fallback city-wide pool.
6. Update `FacadeAssembler.select_archetype()` or wrap it with a selector
   that filters by:
   - city first;
   - district later;
   - material/category;
   - floors;
   - building type;
   - weighted random by `way_id`.
7. Preserve deterministic output: the same OSM data should produce the same
   archetype choices.

Caveats:

- City-level selection should ship before district-level selection.
- District polygons may be unavailable or too coarse.
- If weights are too strong, the city becomes repetitive.
- If weights are too broad, the city loses local identity.

## Stage 8: Godot Preview and QA

Command:

```bash
python -m facade_pipeline.cli preview-godot \
  --city antalya \
  --archetype generated_archetypes/antalya-konyaalti-white-balcony-midrise-1.json
```

Implementation tasks:

1. Create a temporary Godot preview scene or script:
   - 4-floor narrow building;
   - 8-floor medium building;
   - 12-floor long building;
   - short and long sides visible;
   - day and night lighting.
2. Copy generated atoms to a temporary `res://` path.
3. Load the archetype JSON.
4. Run Godot preview.
5. Capture screenshots.
6. Run visual QA:
   - no missing textures;
   - no empty facades;
   - no chroma backgrounds;
   - alpha edges acceptable;
   - overlays inside slot bounds;
   - seam alignment;
   - extrusion visible if enabled;
   - night emission acceptable.

Deliverables:

- `previews/<cluster>/day_*.png`
- `previews/<cluster>/night_*.png`
- `reports/<cluster>_qa_report.md`

Human checkpoint:

- The city expert approves or rejects the preview.
- The AI engineer fixes schema/geometry issues.
- The art director adjusts prompts/weights if the look feels wrong.

## Stage 9: Promotion to Game Assets

Command:

```bash
python -m facade_pipeline.cli promote \
  --city antalya \
  --cluster antalya-konyaalti-white-balcony-midrise \
  --approved-by "human-review"
```

Implementation tasks:

1. Copy approved atom folder into `decorations/turkey/antalya/`.
2. Copy approved archetype JSON into `decorations/turkey/antalya/facades/`.
3. Create or update `decorations/turkey/antalya/meta.json`.
4. Create or update `decorations/index.json` source entry.
5. Write provenance:
   - source imagery manifest;
   - generation prompts;
   - model/tool versions;
   - approval notes;
   - license notes.
6. Run a final in-game location smoke test.

Deliverables:

- game-ready atom PNGs;
- game-ready archetype JSONs;
- city metadata;
- provenance report.

## MVP Implementation Plan

### Milestone 0: Experimental AI Urban Researcher

Goal: let AI attempt the human-heavy first step: discover the city/district
look and prepare facade references automatically. This is experimental and has
a manual fallback.

Tasks:

- Implement `research-references` CLI command.
- Query OSM/Overpass for the city/bbox.
- Search allowed web/open imagery sources for city/district context.
- Query Mapillary/KartaView/Wikimedia/local uploads for facade candidates.
- Score and rank ordinary facade references.
- Generate contact sheets.
- Generate `urban_research_report.md`.
- Generate `ai_style_brief.md` for the first proposed archetype.
- Generate `approval_queue.json` for human review.

Success criteria:

- For Antalya, AI produces at least one plausible non-landmark residential or
  mixed-use facade candidate.
- The selected references have provenance.
- The style brief proposes concrete roles and molecules.
- A human can approve, edit, retry, or switch to manual references.

### Milestone 1: Reference-Guided Atom Factory

Goal: automate atom generation after Stage 0 produces approved references, or
after a human supplies manual fallback references. Direct production-quality
crops are not required.

Tasks:

- Add `tools/facade_pipeline` CLI skeleton.
- Define `atom_manifest.json` schema.
- Define prompt templates for:
  - wall atoms;
  - window variants;
  - balcony/loggia variants;
  - optional shopfront/crown variants.
- Implement PNG postprocessing:
  - exact resize;
  - alpha validation;
  - opaque wall validation;
  - contact sheet generation.
- Implement archetype JSON writer.
- Implement molecule validator.
- Implement Godot preview scene writer.

Success criteria:

- Given a folder of style references and optional rough component crops, the
  tool produces a valid atom pack, JSON archetype, and preview screenshots.

### Milestone 2: Minimal City Runtime Selector

Goal: make generated archetypes visible in-game by city, before district-level
selection exists.

Tasks:

- Add a city-aware archetype root resolver.
- Keep Cherepovets behavior unchanged.
- Add an Antalya facade root such as
  `res://decorations/turkey/antalya/facades/`.
- Select the archetype pool from the current free-roam city/location.
- Add deterministic tests for city pool selection.

Success criteria:

- Cherepovets buildings still use Cherepovets archetypes.
- Antalya buildings can use an Antalya archetype without way-specific
  overrides.

### Milestone 3: Minimal New Roles for Antalya MVP

Goal: avoid producing a recolored post-Soviet panel archetype.

Tasks:

- Add one ground-floor role, preferably `shopfront`.
- Add one roofline role, preferably `crown` or `roofline`.
- Extend `SLOT_CATALOG` and JSON validation for those roles.
- Add minimal molecule support for ground-floor-only usage, or define an MVP
  workaround if full ground/upper molecule splitting is too large.
- Add preview tests for the new roles.

Success criteria:

- The first Antalya archetype can show a distinct commercial ground-floor or
  roofline cue, not just a different wall color.

### Milestone 4: Fixed Variant Seed Contract

Goal: make repeated generated building series possible without writing a
special GDScript facade like 111-125.

Tasks:

- Add `variant_seed_mode` and `variant_seed` to archetype schema.
- Update [FacadeAssembler](../osm/facade_assembler.gd) to seed by either
  `way_id` or a fixed archetype seed.
- Add tests/previews showing the difference.

Success criteria:

- An archetype can intentionally keep the same variant layout across multiple
  buildings.

### Milestone 5: Production Imagery Connector Hardening

Goal: harden and scale the imagery/source connectors after the Stage 0
prototype proves the research loop. Stage 0 already uses these sources; this
milestone turns them from prototype calls into robust infrastructure.

Tasks:

- Add pagination/rate-limit handling for Mapillary/KartaView/Wikimedia/Flickr.
- Add retry and cache invalidation rules.
- Add source-specific license/use-policy checks.
- Add larger bbox and multi-district coverage reports.
- Add residential-footprint-weighted sampling diagnostics.

Success criteria:

- Given an Antalya bbox, produce a documented, resumable, reviewable imagery
  candidate set with coverage gaps and source licenses clearly reported.

### Milestone 6: Semi-Automated Reference Selection and Crops

Goal: reduce manual reference hunting, not necessarily produce final atoms from
crops.

Tasks:

- Add VLM-based facade-candidate scoring.
- Add style-reference contact sheets.
- Add optional component crop proposals.
- Add approved/rejected reference manifest.

Success criteria:

- Human reviewer selects good references from generated sheets, not from raw
  maps.

### Milestone 7: Style Clustering and District Weights

Goal: split a city into plausible visual archetype clusters after one
city-level archetype has shipped.

Tasks:

- Generate visual embeddings.
- Combine OSM/grid features.
- Cluster urban fabric.
- Generate style reports.
- Add district/grid-level archetype weights.

Success criteria:

- For Antalya, produce 3-6 named clusters that a local expert considers
  plausible and route them to different archetype pools.

## Quality Gates

Do not promote an archetype unless all gates pass:

1. License/provenance manifest exists.
2. All PNGs have exact expected dimensions.
3. All overlay PNGs have alpha.
4. All wall PNGs are opaque.
5. Archetype JSON references only existing atoms.
6. All molecules validate against known slots.
7. Godot preview loads without missing resources.
8. Day preview looks plausible.
9. Night preview has acceptable emission.
10. Human reviewer marks the result as place-plausible.
11. Promotion is blocked if source/provenance data is missing.
12. If direct photo crops were used as atoms, they must pass the same visual QA
    as generated atoms.

## Known Caveats

- Source imagery rights are the hardest non-technical risk.
- Google imagery should not be automated as a data source.
- OSM data is incomplete and biased.
- In Antalya/Turkey, `building:material` and `building:levels` may be sparse,
  so synthetic material/floor heuristics will matter.
- Street-level imagery coverage may be bad in residential districts.
- AI image generation may produce attractive but geographically generic assets.
- Direct crop-to-atom extraction from street imagery is a high-risk path; use
  photos as style references by default.
- Over-variation creates noisy facades.
- Under-variation creates obvious repetition.
- Local identity may live in secondary details: AC units, awnings, grilles,
  roof water tanks, satellite dishes, shopfront signage, balcony glazing.
- Some cities need new roles not present in current `SLOT_CATALOG`.
- Entrances and shopfronts need better ground-floor support in the generic
  assembler.
- City-aware selection is required before assets can appear in-game.
- District-aware selection requires additional code beyond asset generation.

## Recommended First Experiment

Run a constrained Antalya prototype:

1. Pick one bbox in Konyaalti or Muratpasa.
2. Run Stage 0: let AI discover ordinary facade references from OSM context,
   Mapillary/KartaView/Wikimedia/Flickr/local uploads, real-estate/developer
   research, housing-stock context, academic/planning references, and web
   research.
3. Review the AI contact sheet and style brief:
   - approve if it found plausible ordinary residential/mixed-use fabric;
   - edit if the candidate is close but needs correction;
   - retry with a narrower bbox or different goal if it found hotels/landmarks;
   - fall back to manually supplied references if coverage or quality is poor.
4. Lean into research/reference-discovery automation now: coverage pre-check,
   source discovery, ranking, style-brief synthesis, snapshots, and provenance.
   Defer only heavy embedding-based visual clustering and automatic
   rectification to later milestones.
5. Produce one atom pack:
   - no seams;
   - white/cream walls;
   - 6 window variants;
   - 6 balcony/loggia variants;
   - one `shopfront` or one `crown`/`roofline` cue.
6. Land the minimal city-level selector so the archetype can appear in
   Antalya free-roam and Cherepovets remains untouched.
7. Generate 2-3 molecules emphasizing balconies/loggias and the new role.
8. Preview in Godot on 4, 8, and 12-floor buildings.
9. Compare screenshots against the source contact sheet.
10. Test on real Antalya OSM only after the synthetic preview feels right.
11. Only then generalize to more districts and heavier visual clustering/crop
    extraction.

This keeps the first implementation grounded and avoids building a large
pipeline before the visual target is proven.
