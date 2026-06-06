extends Node3D

## NPC setup for the Honda Civic Si 2006 (VehicleBody3D traffic car).
##
## Pipeline-generated. Same Sketchfab "F_M_*_High" family as the Ford Focus ST.
## Model native forward = +Z = VehicleBody3D NPC forward, so NO rotation is applied.
##
## Wheels: merged Tire/Rim/Caliper/Disc meshes are split into four spinnable
## containers by CarWheelRig (run synchronously in _ready BEFORE the parent
## NPCCar._merge_meshes). The container child meshes are named "wheelmesh_*" so
## npc_car.gd._merge_meshes collects them into _wheel_mesh_nodes and spins them.
##
## Body colour: npc_car.gd merges the body into a cached MergedMesh whose materials
## are SHARED across instances, so the random colour is applied as a per-instance
## surface_override_material on the MergedMesh's "capaint" surface (after the merge).

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

# Official Honda Civic Si colours from new_cars_color_mapping.md, weighted toward
# common shades (white/silver/grey/black) like real traffic.
const NPC_COLORS := [
	Color(0.949, 0.945, 0.910),  # Taffeta White
	Color(0.949, 0.945, 0.910),  # Taffeta White (common)
	Color(0.749, 0.753, 0.733),  # Alabaster Silver
	Color(0.749, 0.753, 0.733),  # Alabaster Silver (common)
	Color(0.333, 0.337, 0.353),  # Galaxy Gray
	Color(0.035, 0.039, 0.071),  # Nighthawk Black
	Color(0.714, 0.098, 0.125),  # Rallye Red
	Color(0.090, 0.306, 0.604),  # Fiji Blue Pearl
	Color(0.616, 0.176, 0.114),  # Habanero Red Pearl (rare)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	# 1) split wheels synchronously so they exist before NPCCar._merge_meshes()
	CarWheelRig.build(self)
	# 2) pick a colour now; apply after the merge has run
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
			if src and src.resource_name.to_lower() == "capaint" and src is StandardMaterial3D:
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
				if mat and mat.resource_name.to_lower() == "capaint" and mat is StandardMaterial3D:
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
