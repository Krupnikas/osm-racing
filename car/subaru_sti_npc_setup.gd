extends "res://car/npc_real_lens.gd"

## NPC setup for the Subaru Impreza WRX STI 2011 (VehicleBody3D traffic car).
## Pipeline-generated. Native forward = +Z = NPC forward → no rotation. Wheels split by
## the hardened CarWheelRig (drops steering/bumper strays automatically). Body colour is
## a per-instance surface_override_material on the cached MergedMesh's "wrxM_CarPaint_Max1"
## surface.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const PAINT_MAT := "wrxm_carpaint_max1"

const NPC_COLORS := [
	Color(0.941, 0.933, 0.902),  # Satin White
	Color(0.941, 0.933, 0.902),  # White (common)
	Color(0.749, 0.761, 0.765),  # Spark Silver
	Color(0.749, 0.761, 0.765),  # Silver (common)
	Color(0.267, 0.282, 0.294),  # Dark Gray
	Color(0.031, 0.035, 0.047),  # Obsidian Black
	Color(0.106, 0.306, 0.608),  # World Rally Blue
	Color(0.710, 0.110, 0.137),  # Lightning Red
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	CarWheelRig.build(self)
	init_real_lens(["headlight"], ["taillight"], true)
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
