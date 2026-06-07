extends "res://car/npc_real_lens.gd"

## NPC setup for the Mini Cooper S F56 (VehicleBody3D traffic car).
## Sketchfab GLB. Native forward = +Z = NPC forward → NO rotation. Real lamp lenses: front
## "glass_light" (white), rear "red_glass" (red), kept un-merged + lifted (in case nested).
## Body colour = per-instance override on the merged "*Paint*"/"*Coloured*" surfaces.

const NPC_COLORS := [
	Color(0.941, 0.910, 0.847),  # Pepper White
	Color(0.035, 0.039, 0.051),  # Midnight Black
	Color(0.333, 0.341, 0.353),  # Thunder Grey
	Color(0.486, 0.490, 0.478),  # Moonwalk Grey
	Color(0.710, 0.086, 0.125),  # Chili Red
	Color(0.082, 0.396, 0.663),  # Electric Blue
	Color(0.071, 0.196, 0.149),  # British Racing Green (rarer)
	Color(0.851, 0.541, 0.122),  # Volcanic Orange (rare)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	init_real_lens(["glass_light"], ["red_glass"], false)
	lift_kept_lamps()
	body_color = NPC_COLORS[randi() % NPC_COLORS.size()]
	await get_tree().process_frame
	_apply_body_color()
	# npc_car_lights adds a single CENTRAL taillight omni for unknown models — the emissive
	# "red_glass" corner lenses are the real taillights, so remove the central one.
	var npc := get_parent()
	var central_tl: Node = npc.find_child("NPCTaillight", true, false) if npc else null
	if central_tl:
		central_tl.queue_free()


func _apply_body_color() -> void:
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh")
	var targets: Array = []
	if merged and merged.mesh:
		targets.append(merged)
	for n in _find_all_meshes(self):
		if n is MeshInstance3D and n.mesh and n.visible:
			targets.append(n)
	for mesh in targets:
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			if src == null:
				continue
			var mn := src.resource_name.to_lower()
			if "paint" in mn or "coloured" in mn or "carp" in mn:
				var dup: StandardMaterial3D = src.duplicate() if src is StandardMaterial3D else null
				if dup:
					dup.albedo_color = body_color
					dup.metallic = 0.6; dup.metallic_specular = 0.85; dup.roughness = 0.25
					mesh.set_surface_override_material(i, dup)


func _find_all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_all_meshes(c))
	return out
