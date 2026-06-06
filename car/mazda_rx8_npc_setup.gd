extends Node3D

## NPC setup for the Mazda RX-8 2006 (VehicleBody3D traffic car).
##
## Pipeline-generated. Same Sketchfab "F_M_*_High" family as the Ford Focus ST.
## Native forward = +Z = VehicleBody3D NPC forward → NO rotation.
##
## Wheels: merged Tire/Rims/Calipers split into spinnable containers by CarWheelRig
## (run synchronously in _ready BEFORE NPCCar._merge_meshes). Container child meshes
## named "wheelmesh_*" are collected by npc_car.gd and spun.
##
## Body colour: per-instance surface_override_material on the cached MergedMesh's
## "caarpaint" surface.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

const NPC_COLORS := [
	Color(0.941, 0.937, 0.906),  # Snowflake White
	Color(0.941, 0.937, 0.906),  # White (common)
	Color(0.765, 0.773, 0.765),  # Sunlight Silver
	Color(0.765, 0.773, 0.765),  # Silver (common)
	Color(0.357, 0.365, 0.376),  # Galaxy Gray
	Color(0.024, 0.024, 0.024),  # Black Mica
	Color(0.655, 0.098, 0.125),  # Velocity Red
	Color(0.169, 0.435, 0.682),  # Winning Blue
	Color(0.075, 0.169, 0.294),  # Phantom Blue (rarer)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	CarWheelRig.build(self)
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
			if src and src.resource_name.to_lower() == "caarpaint" and src is StandardMaterial3D:
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
				if mat and mat.resource_name.to_lower() == "caarpaint" and mat is StandardMaterial3D:
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
