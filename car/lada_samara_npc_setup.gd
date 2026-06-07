extends "res://car/npc_real_lens.gd"

## NPC setup for the LADA 2114 Samara (VehicleBody3D traffic car).
## Native forward -Z → NPC +Z, scene rotates 180°. Emissive inner bulb (front white "headlight
## light" / rear red "stop"), kept un-merged + lifted out of the body mesh (lift_kept_lamps, the
## FBX nests the lamp under "body"). Metallic/glass/optic polish on the MergedMesh + kept lamp.

const Player := preload("res://car/lada_samara_setup.gd")

const NPC_COLORS := [
	Color(0.941, 0.937, 0.906),  # White Cloud
	Color(0.941, 0.937, 0.906),  # White (common)
	Color(0.749, 0.760, 0.760),  # silver
	Color(0.749, 0.760, 0.760),  # silver (common)
	Color(0.345, 0.357, 0.357),  # Quartz gray
	Color(0.035, 0.035, 0.043),  # Black
	Color(0.078, 0.212, 0.373),  # Baltica blue
	Color(0.545, 0.090, 0.125),  # Carmen red
	Color(0.122, 0.290, 0.231),  # Amulet green (rarer)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	init_real_lens(["headlight light"], ["stop"], false)
	lift_kept_lamps()
	body_color = NPC_COLORS[randi() % NPC_COLORS.size()]
	await get_tree().process_frame
	_polish()


func _polish() -> void:
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh")
	if merged and merged.mesh:
		for i in range(merged.mesh.get_surface_count()):
			_polish_surface(merged, i)
	for n in _find_all_meshes(self):
		if n is MeshInstance3D and n.mesh and n.visible:
			for i in range(n.mesh.get_surface_count()):
				_polish_surface(n, i)


func _polish_surface(mesh: MeshInstance3D, i: int) -> void:
	var src: Material = mesh.mesh.surface_get_material(i)
	if src == null:
		return
	var mat: Material = mesh.get_surface_override_material(i)
	if not mat:
		mat = src.duplicate()
		mesh.set_surface_override_material(i, mat)
	Player.polish_surface(mat, body_color)


func _find_all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_all_meshes(c))
	return out
