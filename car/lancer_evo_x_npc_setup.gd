extends "res://car/npc_real_lens.gd"

## NPC setup for the Mitsubishi Lancer Evo X MR 2008 (VehicleBody3D traffic car).
## Pipeline-generated. Real scale (~1.0). Native forward = +Z = NPC forward → no rotation.
## Separate corner wheels split by CarWheelRig (sync, before _merge_meshes). Body colour
## is a per-instance surface_override_material on the cached MergedMesh's
## "Vehicle_Exterior_mm_ext" surface.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const PAINT_MAT := "vehicle_exterior_mm_ext"

const NPC_COLORS := [
	Color(0.941, 0.937, 0.906),  # Wicked White
	Color(0.941, 0.937, 0.906),  # White (common)
	Color(0.749, 0.753, 0.745),  # Apex Silver
	Color(0.749, 0.753, 0.745),  # Silver (common)
	Color(0.306, 0.314, 0.329),  # Graphite Gray
	Color(0.027, 0.031, 0.043),  # Phantom Black
	Color(0.063, 0.298, 0.569),  # Octane Blue
	Color(0.710, 0.110, 0.133),  # Rally Red
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	CarWheelRig.build(self)
	# real lens: single spanning "lightglass" mesh → triangle-split front-white / rear-red
	init_real_lens_split(["lightglass"], true)
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
				dup.metallic = 0.4
				dup.metallic_specular = 0.85
				dup.roughness = 0.2
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
