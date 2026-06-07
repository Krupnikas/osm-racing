extends "res://car/npc_real_lens.gd"

## NPC setup for the Ford Focus ST 2006 (VehicleBody3D traffic car).
##
## Pipeline-generated. Model native forward = +Z = VehicleBody3D NPC forward, so
## NO rotation is applied (unlike the GEVP player scene which rotates 180°).
##
## Wheels: the merged Tire/Rim/Disc/Caliper meshes are split into four spinnable
## containers by CarWheelRig (run synchronously in _ready BEFORE the parent
## NPCCar._merge_meshes runs). The container child meshes are named "wheelmesh_*"
## so npc_car.gd._merge_meshes collects them into _wheel_mesh_nodes and spins them.
##
## Body colour: npc_car.gd merges the body into a single cached MergedMesh whose
## materials are SHARED across instances, so we apply the random colour as a
## per-instance surface_override_material on the MergedMesh's Paint surface (after
## the merge), which gives genuine per-car variety.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")

# Official Ford Focus ST colours from new_cars_color_mapping.md, weighted toward
# common shades (white/silver/grey/black) like real traffic.
const NPC_COLORS := [
	Color(0.949, 0.945, 0.917),  # Frozen White
	Color(0.949, 0.945, 0.917),  # Frozen White (common)
	Color(0.722, 0.729, 0.722),  # Moondust Silver
	Color(0.722, 0.729, 0.722),  # Moondust Silver (common)
	Color(0.333, 0.361, 0.376),  # Sea Grey
	Color(0.031, 0.035, 0.039),  # Panther Black
	Color(0.149, 0.400, 0.663),  # Performance Blue
	Color(0.655, 0.098, 0.125),  # Colorado Red
	Color(0.851, 0.416, 0.106),  # Electric Orange (rare, hot-hatch)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	# 1) split wheels synchronously so they exist before NPCCar._merge_meshes()
	CarWheelRig.build(self)
	# 2) pick a colour now; apply after the merge has run
	init_real_lens(["lightcluster", "lightrefracted"], ["red_glass"], true)
	body_color = NPC_COLORS[randi() % NPC_COLORS.size()]
	await get_tree().process_frame
	_apply_body_color()


func _apply_body_color() -> void:
	# Per-instance recolour of the merged body (Paint surface), plus a fallback
	# for the un-merged case (simple/box NPCs never reach here, but be safe).
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh")
	if merged and merged.mesh:
		var m: Mesh = merged.mesh
		for i in range(m.get_surface_count()):
			var src: Material = m.surface_get_material(i)
			if src and src.resource_name.to_lower() == "paint" and src is StandardMaterial3D:
				var dup: StandardMaterial3D = src.duplicate()
				dup.albedo_color = body_color
				dup.metallic = 0.4
				dup.metallic_specular = 0.85
				dup.roughness = 0.2
				merged.set_surface_override_material(i, dup)
	else:
		# fallback: recolour original Paint meshes directly
		for node in _find_all_meshes(self):
			var mesh: MeshInstance3D = node as MeshInstance3D
			if mesh == null or mesh.mesh == null:
				continue
			for i in range(mesh.mesh.get_surface_count()):
				var mat: Material = mesh.get_active_material(i)
				if mat and mat.resource_name.to_lower() == "paint" and mat is StandardMaterial3D:
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
