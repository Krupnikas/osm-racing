extends "res://car/npc_real_lens.gd"

## NPC setup for the LADA 2110 (VehicleBody3D traffic car).
## Native forward -Z → NPC +Z, scene rotates 180°. Emissive inner bulbs (front white
## headlight_light/highbeam, rear red stop), kept un-merged + lifted out of the body mesh.
## Metallic/glass/optic polish (shared substring rules) on MergedMesh + kept lamp.

const Polish := preload("res://car/lada_samara_setup.gd")

const NPC_COLORS := [
	Color(0.769, 0.776, 0.765),  # Snow Queen
	Color(0.749, 0.757, 0.741),  # Crystal (common)
	Color(0.345, 0.357, 0.357),  # Quartz gray
	Color(0.231, 0.239, 0.259),  # Milky Way
	Color(0.035, 0.035, 0.043),  # Black
	Color(0.557, 0.180, 0.212),  # Triumph red
	Color(0.122, 0.255, 0.416),  # Regatta blue
	Color(0.122, 0.290, 0.231),  # Amulet green
	Color(0.141, 0.353, 0.388),  # Niagara (rarer)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	init_real_lens(["headlight_light", "headlight_highbeam"], [], false)
	# rear taillights = REAR half of the spanning "headlight_glass" surface (corners only),
	# kept un-merged; central "headlight_stop" excluded.
	_tail_glow_mats.append_array(LampEmissive.split_surface(self, "headlight_glass", false, 0.0, true, "blenda"))
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
	Polish.polish_surface(mat, body_color)


func _find_all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_all_meshes(c))
	return out
