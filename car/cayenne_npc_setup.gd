extends "res://car/npc_real_lens.gd"

## NPC setup for the Porsche Cayenne Turbo S 2009 (VehicleBody3D traffic car).
## Pipeline-generated. Native forward = +Z = NPC forward → no rotation. Wheels split by
## CarWheelRig with extra mat keys ["llanta","rin"] (+ default "disk"); hardened lateral
## filter keeps the 4 corners. Body colour = per-instance override on cached MergedMesh's
## "CAYENNE" surface.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const WHEEL_MATS := ["llanta", "rin"]
const PAINT_MAT := "cayenne"

const NPC_COLORS := [
	Color(0.067, 0.067, 0.067),  # Basalt Black
	Color(0.067, 0.067, 0.067),  # Black (common)
	Color(0.784, 0.788, 0.780),  # Crystal Silver
	Color(0.294, 0.306, 0.314),  # Meteor Gray
	Color(0.910, 0.882, 0.824),  # Sand White
	Color(0.082, 0.173, 0.306),  # Marine Blue
	Color(0.706, 0.627, 0.420),  # Nordic Gold (rare)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	CarWheelRig.build(self, CarWheelRig.DEFAULT_NAME_KEYS, CarWheelRig.DEFAULT_MAT_KEYS, WHEEL_MATS)
	init_real_lens(["cayenne_luz"], ["cayenne_luz2"], false)
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
				dup.roughness = 0.25
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
