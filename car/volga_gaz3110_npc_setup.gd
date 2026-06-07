extends "res://car/npc_real_lens.gd"

## NPC setup for the Volga GAZ-3110 (VehicleBody3D traffic car, low-poly).
## Pipeline-generated. Real-world scale (~1.0). Native forward = +Z = NPC forward → no
## rotation. Separate corner wheels split by CarWheelRig (sync, before _merge_meshes).
## Body colour is a per-instance surface_override_material on the cached MergedMesh's
## "BodyColor" surface.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const NPC_COLORS := [
	Color(0.941, 0.937, 0.894),  # White
	Color(0.941, 0.937, 0.894),  # White (common)
	Color(0.749, 0.761, 0.761),  # Buran (silver)
	Color(0.749, 0.761, 0.761),  # silver (common)
	Color(0.408, 0.420, 0.439),  # Scat (grey)
	Color(0.184, 0.188, 0.196),  # Anthracite
	Color(0.118, 0.247, 0.388),  # Cyclone (blue)
	Color(0.357, 0.078, 0.125),  # Red Wine
	Color(0.137, 0.263, 0.208),  # Malakhit (rarer)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	# drop the grille emblem named like a wheel before rigging (see player setup)
	for mi in find_children("*", "MeshInstance3D", true, false):
		var nm := str(mi.name)
		if nm.begins_with("Body") and "Wheel" in nm:
			mi.free()
	CarWheelRig.build(self)
	init_real_lens(["light"], ["light3"], false)
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
			if src and src.resource_name.to_lower() == "bodycolor" and src is StandardMaterial3D:
				var dup: StandardMaterial3D = src.duplicate()
				dup.albedo_color = body_color
				dup.metallic = 0.3
				dup.metallic_specular = 0.8
				dup.roughness = 0.25
				merged.set_surface_override_material(i, dup)
	else:
		for node in _find_all_meshes(self):
			var mesh: MeshInstance3D = node as MeshInstance3D
			if mesh == null or mesh.mesh == null:
				continue
			for i in range(mesh.mesh.get_surface_count()):
				var mat: Material = mesh.get_active_material(i)
				if mat and mat.resource_name.to_lower() == "bodycolor" and mat is StandardMaterial3D:
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
