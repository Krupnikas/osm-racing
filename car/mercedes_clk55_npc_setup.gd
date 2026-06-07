extends "res://car/npc_real_lens.gd"

## NPC setup for the Mercedes-Benz CLK 55 AMG 2003 (VehicleBody3D traffic car).
## Pipeline-generated. Native forward = +Z = NPC forward → no rotation. Wheels split by
## the hardened CarWheelRig. Body colour is a per-instance surface_override_material on
## the cached MergedMesh's "CarPaint" surface. 138k verts → spawn weight kept very low.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const PAINT_MAT := "carpaint"

const NPC_COLORS := [
	Color(0.761, 0.769, 0.765),  # Brilliant Silver
	Color(0.761, 0.769, 0.765),  # Silver (common)
	Color(0.067, 0.067, 0.075),  # Obsidian Black
	Color(0.020, 0.020, 0.020),  # Tiefschwarz
	Color(0.933, 0.925, 0.886),  # Alabaster White
	Color(0.784, 0.788, 0.776),  # Iridium Silver
	Color(0.149, 0.192, 0.176),  # Graphite Green (rare)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	CarWheelRig.build(self)
	init_real_lens(["glass_light_1"], ["light_glass"], false)
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
				dup.metallic = 0.5
				dup.metallic_specular = 0.9
				dup.roughness = 0.18
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
