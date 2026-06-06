extends "res://car/npc_real_lens.gd"

## NPC setup for the Renault Logan (VehicleBody3D traffic car).
## Native forward = +Z = NPC forward → no rotation. Real lamp lenses: front "fara"/"fara_2"
## meshes (white), rear "fonar" mesh (red) — they share the body material "Kuzov1" but are
## kept un-merged + given per-surface emissive by npc_real_lens, so no proxy boxes. Body
## colour is a per-instance override on the merged "Kuzov1" surface.

const PAINT_MAT := "kuzov1"

const NPC_COLORS := [
	Color(0.93, 0.93, 0.91),  # White
	Color(0.93, 0.93, 0.91),  # White (common)
	Color(0.74, 0.75, 0.75),  # Silver
	Color(0.74, 0.75, 0.75),  # Silver (common)
	Color(0.36, 0.37, 0.39),  # Grey
	Color(0.05, 0.05, 0.06),  # Black
	Color(0.13, 0.27, 0.45),  # Blue
	Color(0.62, 0.13, 0.14),  # Red
	Color(0.45, 0.50, 0.36),  # Khaki (rarer)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	# real lamp lenses (front fara = white, rear fonar = red) BEFORE the merge
	init_real_lens(["fara"], ["fonar"], true)
	body_color = NPC_COLORS[randi() % NPC_COLORS.size()]
	await get_tree().process_frame
	_apply_body_color()


func _apply_body_color() -> void:
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh")
	if merged and merged.mesh:
		var m: Mesh = merged.mesh
		for i in range(m.get_surface_count()):
			var src: Material = m.surface_get_material(i)
			if src and src.resource_name.to_lower() == PAINT_MAT and src is StandardMaterial3D:
				var dup: StandardMaterial3D = src.duplicate()
				dup.albedo_color = body_color
				dup.metallic = 0.25
				dup.metallic_specular = 0.7
				dup.roughness = 0.35
				merged.set_surface_override_material(i, dup)
	else:
		for node in _find_all_meshes(self):
			var mesh: MeshInstance3D = node as MeshInstance3D
			if mesh == null or mesh.mesh == null:
				continue
			for i in range(mesh.mesh.get_surface_count()):
				var mat: Material = mesh.get_active_material(i)
				if mat and mat.resource_name.to_lower() == PAINT_MAT and mat is StandardMaterial3D:
					var dup: StandardMaterial3D = mat.duplicate()
					dup.albedo_color = body_color
					mesh.set_surface_override_material(i, dup)


func _find_all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_all_meshes(c))
	return out
