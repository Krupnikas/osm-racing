class_name OSMLandmarks
extends RefCounted

# Centralized OSM-id → custom landmark GLB overrides.
#
# Keyed by OSM RELATION id. When a relation listed here is parsed:
#   - osm_loader suppresses ALL of its procedural geometry (walls / roof / footprint
#     extrusion + every member-way polygon) and captures the outer-ring footprint;
#   - osm_terrain_generator._place_landmarks_for_chunk places the GLB footprint-aligned:
#     centre  = area-weighted footprint centroid
#     rotation = footprint dominant axis (PCA) + rotation_offset_deg
#     scale    = footprint_long_extent / model_long_extent (uniform, aspect preserved) * scale_mult
#     ground   = terrain elevation under the centre, model base placed via real vertices
#
# To add another landmark: drop one entry here. Nothing else needs editing.
#
# Per-landmark correction fields (keep tuning here — no magic numbers in render code):
#   model               res:// path to the GLB
#   fit_way_id          OSM way id whose footprint defines centre/rotation/scale (e.g. the
#                       pedestrian ring around a stadium). The model is INSCRIBED in it.
#                       0/absent ⇒ use the relation's own outer footprint.
#   rotation_offset_deg added on top of the auto PCA bearing (visual correction; 0/90/180/270…)
#   scale_mult          multiplies the inscribe-fit scale (1.0 = touch the fit outline)
#   y_offset            vertical nudge after real-vertex grounding (metres)
#   visibility_range    draw distance (m). >300 ⇒ persistent self-parented + far-visible
#   collision           "" (none) | "box" (AABB) | "footprint" (tight prism on the building outline)
const OVERRIDES := {
	1724684: {  # Донбасс Арена / Donbass Arena — Donetsk (relation, building=civic leisure=stadium)
		"name": "Donbass Arena",
		"model": "res://models/landmarks/donbass-arena.glb",
		"fit_way_id": 200258208,  # surrounding pedestrian ring — model is inscribed inside it
		"rotation_offset_deg": 0.0,
		"scale_mult": 1.0,
		"y_offset": 0.0,
		"visibility_range": 2500.0,
		"collision": "footprint",
	},
}


static func has_relation(rel_id: int) -> bool:
	return OVERRIDES.has(rel_id)


static func get_config(rel_id: int) -> Dictionary:
	return OVERRIDES.get(rel_id, {})
