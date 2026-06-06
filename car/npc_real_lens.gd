extends Node3D

## Base for NPC setup scripts that glow the REAL lamp-lens meshes (front warm-white /
## rear red) instead of rectangular proxy boxes. See docs/CAR_INTEGRATION_PIPELINE.md §5c.
##
## A subclass calls init_real_lens() / init_real_lens_zsplit() from its _ready BEFORE its own
## `await` (so it runs before traffic/npc_car.gd._merge_meshes(), which would otherwise hide
## the lens meshes). That flags each lens mesh `npc_keep_unmerged` (merge leaves it visible) and
## sets the NPC root's `real_lens_lights` meta (npc_car_lights.gd skips its proxy boxes). The
## base _process then toggles lens emission with night.

const LampEmissive := preload("res://tools/lamp_emissive.gd")

var _head_mats: Array = []
var _tail_glow_mats: Array = []
var _night_manager: Node
var _is_night := false


func _mark_real_lens() -> void:
	var npc := get_parent()
	if npc:
		npc.set_meta("real_lens_lights", true)


## Identify lens by material name (and node name if match_mesh_name). front_keys/rear_keys
## are lowercased substrings; rear is matched first so an overlapping front key (e.g. "light"
## vs "light3") does not steal a rear surface.
func init_real_lens(front_keys: Array, rear_keys: Array, match_mesh_name := false) -> void:
	_mark_real_lens()
	var r: Dictionary = LampEmissive.apply_by_name(self, front_keys, rear_keys, 0.0, 0.0, match_mesh_name, true)
	_head_mats = r["head"]
	_tail_glow_mats = r["tail"]


## One shared lamp material at both ends → split per-surface by centroid z.
func init_real_lens_zsplit(lamp_keys: Array, native_front_z_positive := true) -> void:
	_mark_real_lens()
	var r: Dictionary = LampEmissive.apply_zsplit(self, lamp_keys, 0.0, 0.0, native_front_z_positive, true)
	_head_mats = r["head"]
	_tail_glow_mats = r["tail"]


## Single lens mesh spanning BOTH ends (one surface) → triangle-level z-split into front
## (white) / rear (red) sub-meshes (e.g. Evo "lightglass").
func init_real_lens_split(lens_keys: Array, native_front_z_positive := true) -> void:
	_mark_real_lens()
	var r: Dictionary = LampEmissive.split_lens_mesh(self, lens_keys, 0.0, 0.0, native_front_z_positive, true)
	_head_mats = r["head"]
	_tail_glow_mats = r["tail"]


## For models whose lamp glow is baked into the merged body (e.g. RX-8 "Light_C" emission
## map): call this AFTER the merge (post-await) to override the merged surface emission
## directly. front_mats/rear_mats are EXACT lowercased merged-surface material names. Call
## _mark_real_lens() yourself BEFORE the await so proxy boxes are still skipped.
func emissive_merged(front_mats: Array, rear_mats: Array) -> void:
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh") if npc else null
	if merged == null or merged.mesh == null:
		return
	for i in range(merged.mesh.get_surface_count()):
		var src: Material = merged.mesh.surface_get_material(i)
		var mn := (src.resource_name.to_lower() if src else "")
		var is_front: bool = mn in front_mats
		var is_rear: bool = mn in rear_mats
		if not (is_front or is_rear):
			continue
		var mat: Material = merged.get_surface_override_material(i)
		if not mat:
			mat = src.duplicate()
			merged.set_surface_override_material(i, mat)
		if not (mat is StandardMaterial3D):
			continue
		mat.emission_enabled = true
		mat.emission_texture = null
		if is_front:
			mat.emission = LampEmissive.FRONT_COLOR
			mat.emission_energy_multiplier = 0.0
			_head_mats.append(mat)
		else:
			mat.emission = LampEmissive.REAR_COLOR
			mat.emission_energy_multiplier = 0.0
			_tail_glow_mats.append(mat)


## Turn OFF baked emission on named merged-body surfaces (e.g. an interior dashboard that
## glows through the windshield). Call after the merge (post-await).
func mute_merged_emission(mats: Array) -> void:
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh") if npc else null
	if merged == null or merged.mesh == null:
		return
	for i in range(merged.mesh.get_surface_count()):
		var src: Material = merged.mesh.surface_get_material(i)
		var mn := (src.resource_name.to_lower() if src else "")
		if mn in mats:
			var mat: Material = merged.get_surface_override_material(i)
			if not mat:
				mat = src.duplicate()
				merged.set_surface_override_material(i, mat)
			if mat is StandardMaterial3D:
				mat.emission_enabled = false


func _process(_delta: float) -> void:
	if not is_instance_valid(_night_manager):
		var scene := get_tree().current_scene
		if scene:
			_night_manager = scene.find_child("NightModeManager", true, false)
	if _night_manager and _night_manager.get("is_night") != null:
		var n: bool = _night_manager.get("is_night")
		if n != _is_night:
			_is_night = n
			for m in _head_mats:
				if is_instance_valid(m):
					m.emission_energy_multiplier = 1.3 if _is_night else 0.0
			for m in _tail_glow_mats:
				if is_instance_valid(m):
					m.emission_energy_multiplier = 1.8 if _is_night else 0.0
