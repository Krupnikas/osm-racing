extends "res://car/npc_real_lens.gd"

## NPC setup for the LADA 2171 Priora (VehicleBody3D traffic car).
## Native forward = -Z → NPC forward +Z, so the scene rotates the model 180°.
## Real lamp lenses: emissive inner bulbs (headlight light/highbeam = front white, stop = rear
## red), kept un-merged. After the merge, the merged body surfaces get the same metallic-paint
## / glass-window / clear-lens-cover / glossy-optic polish as the player (FBX imported flat).

const PAINT_MATS := ["body paint", "priora_paint"]

const NPC_COLORS := [
	Color(0.941, 0.937, 0.906),  # White Cloud
	Color(0.941, 0.937, 0.906),  # White (common)
	Color(0.749, 0.760, 0.760),  # Snow Queen silver
	Color(0.749, 0.760, 0.760),  # Silver (common)
	Color(0.345, 0.357, 0.357),  # Quartz gray
	Color(0.035, 0.035, 0.043),  # Black Pearl
	Color(0.122, 0.255, 0.416),  # Regatta blue
	Color(0.392, 0.129, 0.165),  # Antares red
	Color(0.408, 0.471, 0.420),  # Sochi green (rarer)
]

var body_color := NPC_COLORS[0]


func _ready() -> void:
	# emissive inner bulbs (front white / rear red), kept un-merged, BEFORE the merge
	init_real_lens(["headlight light", "highbeam"], ["stop"], false)
	# the FBX nests the "headlight" lamp under the "body" mesh; the merge hides "body" and
	# (visibility propagates) the lamp would vanish — lift the kept lamp meshes to the root.
	lift_kept_lamps()
	body_color = NPC_COLORS[randi() % NPC_COLORS.size()]
	await get_tree().process_frame
	_polish_merged()


func _polish_merged() -> void:
	var npc := get_parent()
	var merged: MeshInstance3D = npc.get_node_or_null("MergedMesh")
	if merged and merged.mesh:
		for i in range(merged.mesh.get_surface_count()):
			_polish_surface(merged, i, merged.mesh.surface_get_material(i))
	# ALSO polish the kept (un-merged, still-visible) meshes — the whole "headlight" lamp
	# node is kept out of the merge, so it needs the same metallic/glass/optic treatment as
	# the player (otherwise its raw dark materials read as an empty headlight cavity).
	for n in _find_all_meshes(self):
		if n is MeshInstance3D and n.mesh and n.visible:
			for i in range(n.mesh.get_surface_count()):
				_polish_surface(n, i, n.mesh.surface_get_material(i))


func _polish_surface(mesh: MeshInstance3D, i: int, src: Material) -> void:
	if src == null:
		return
	var mn := src.resource_name.to_lower()
	var mat: Material = mesh.get_surface_override_material(i)
	if not mat:
		mat = src.duplicate()
		mesh.set_surface_override_material(i, mat)
	if not (mat is StandardMaterial3D):
		return
	if mn in PAINT_MATS:
		mat.albedo_color = body_color
		mat.metallic = 0.7; mat.metallic_specular = 0.9; mat.roughness = 0.22
		mat.clearcoat_enabled = true; mat.clearcoat = 0.6; mat.clearcoat_roughness = 0.08
	elif mn == "win" or mn == "win frame":
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.05, 0.06, 0.08, 0.55)
		mat.metallic = 0.25; mat.metallic_specular = 0.9; mat.roughness = 0.05
	elif mn == "priora_chrome" or mn == "headlight chrome":
		mat.albedo_color = Color(0.8, 0.8, 0.82); mat.metallic = 0.95; mat.roughness = 0.12
	elif mn == "headlight glass_front" or mn == "headlight glass_other":
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.85, 0.88, 0.92, 0.10)
		mat.roughness = 0.02; mat.metallic = 0.1; mat.metallic_specular = 1.0
	elif mn.begins_with("headlight"):
		mat.roughness = 0.1; mat.metallic = 0.2; mat.metallic_specular = 0.9


func _find_all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_all_meshes(c))
	return out
