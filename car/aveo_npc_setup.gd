extends "res://car/npc_real_lens.gd"

## NPC setup for the Chevrolet Aveo 5 LT 2009 (VehicleBody3D traffic car).
## Pipeline-generated. Native forward = +Z = NPC forward → no rotation. Wheels via
## CarWheelRig extra mat keys (SketchUp tokens). Body colour = per-instance override on
## the cached MergedMesh's main panel material.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const WHEEL_MATS := ["chevy_aveo_54uher", "chevy_aveo_45uher"]
const PAINT_MAT := "chevy_aveo_65i5wejnytjhmf"

const NPC_COLORS := [
	Color(0.761, 0.757, 0.737),  # Silver Birch
	Color(0.761, 0.757, 0.737),  # Silver (common)
	Color(0.020, 0.020, 0.020),  # Black
	Color(0.412, 0.416, 0.404),  # Dark Tarnished Silver
	Color(0.118, 0.369, 0.620),  # Sports Blue
	Color(0.722, 0.667, 0.549),  # Cashmere
	Color(0.184, 0.420, 0.353),  # Tahiti Green (rare)
	Color(0.325, 0.078, 0.129),  # Merlot (rare)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	CarWheelRig.build(self, CarWheelRig.DEFAULT_NAME_KEYS, CarWheelRig.DEFAULT_MAT_KEYS, WHEEL_MATS)
	init_real_lens(["chevy_aveo_342yhwwesrtfnhdtf"], ["chevy_aveo_34yg4wersbrdf"], false)
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
				dup.metallic = 0.3
				dup.metallic_specular = 0.8
				dup.roughness = 0.3
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
