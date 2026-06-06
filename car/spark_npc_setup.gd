extends Node3D

## NPC setup for the Chevrolet Spark 1.2 LT 2011 (VehicleBody3D traffic car).
## Pipeline-generated. Native forward = +Z = NPC forward → no rotation. Wheels via
## CarWheelRig extra mat keys ("sparkllantas" tyre + "sparkrines" rim variants).
## Body colour = per-instance override on the main paint material "Spark".
##
## Lights: like the PLAYER, the NPC glows the REAL lamp lens meshes (the shared
## "Sparkluces" material, split front +Z white / rear −Z red) instead of rectangular
## proxy boxes. Setting the "real_lens_lights" meta on the NPC root tells the shared
## NPCCarLights system to skip its proxy meshes (it still adds the SpotLight beams and
## taillight OmniLights for illumination). Lens emission toggles with night.

const CarWheelRig := preload("res://tools/car_wheel_rig.gd")
const WHEEL_MATS := ["sparkllantas", "sparkrines"]
const PAINT_MAT := "spark"
const LAMP_MATS := ["sparkluces"]  # shared front+rear lens; split by centroid z

const NPC_COLORS := [
	Color(0.918, 0.918, 0.906),  # Summit White (common)
	Color(0.745, 0.749, 0.741),  # Silver (common)
	Color(0.043, 0.043, 0.050),  # Black Granite
	Color(0.176, 0.302, 0.486),  # Denim Blue
	Color(0.671, 0.106, 0.118),  # Salsa Red
	Color(0.929, 0.792, 0.169),  # Lemonade Yellow (rare)
	Color(0.871, 0.337, 0.541),  # Techno Pink (rare)
	Color(0.518, 0.690, 0.231),  # Jalapeno Green (rare)
]

var body_color := NPC_COLORS[0]

var _night_manager: Node
var _is_night := false
var _head_mats: Array[StandardMaterial3D] = []      # front lens (glow at night)
var _tail_glow_mats: Array[StandardMaterial3D] = []  # rear lens (glow at night)


func _ready() -> void:
	# Mark the NPC so the shared NPCCarLights system skips its rectangular proxy boxes
	# (set BEFORE the await so it is in place when the parent's _ready runs setup_lights).
	var npc := get_parent()
	if npc:
		npc.set_meta("real_lens_lights", true)
	CarWheelRig.build(self, CarWheelRig.DEFAULT_NAME_KEYS, CarWheelRig.DEFAULT_MAT_KEYS, WHEEL_MATS)
	# Flag + emissive the real lens meshes BEFORE the parent's _merge_meshes() runs, so the
	# merge keeps them separate (npc_keep_unmerged) and the per-surface glow renders.
	_emissive_lamps()
	body_color = NPC_COLORS[randi() % NPC_COLORS.size()]
	await get_tree().process_frame
	_apply_body_color()


func _process(_delta: float) -> void:
	if not is_instance_valid(_night_manager):
		var scene := get_tree().current_scene
		if scene:
			_night_manager = scene.find_child("NightModeManager", true, false)
	if _night_manager and _night_manager.get("is_night") != null:
		var n: bool = _night_manager.get("is_night")
		if n != _is_night:
			_is_night = n
			for m in _head_mats:
				if is_instance_valid(m):
					m.emission_energy_multiplier = 1.3 if _is_night else 0.0
			for m in _tail_glow_mats:
				if is_instance_valid(m):
					m.emission_energy_multiplier = 1.8 if _is_night else 0.0


# Transform from a node up to this setup node (model-local; native front = +Z).
func _xform_to_self(node: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != self:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


func _surface_centroid_z(mi: MeshInstance3D, surf: int) -> float:
	var arr = mi.mesh.surface_get_arrays(surf)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if verts.size() == 0:
		return 0.0
	var t := _xform_to_self(mi)
	var s := 0.0
	for v in verts:
		s += (t * v).z
	return s / verts.size()


# Make the REAL lamp lens meshes emissive; split front (+Z) white / rear (−Z) red.
# Both start OFF (energy 0) and turn on at night via _process.
func _emissive_lamps() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D) or mesh.mesh == null:
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			var mn := (src.resource_name.to_lower() if src else "")
			if not (mn in LAMP_MATS):
				continue
			var is_front: bool = _surface_centroid_z(mesh, i) >= 0.0
			# keep this lens mesh out of the body merge so the glow renders lens-shaped
			mesh.set_meta("npc_keep_unmerged", true)
			var mat: Material = mesh.get_surface_override_material(i)
			if not mat:
				mat = src.duplicate()
				mesh.set_surface_override_material(i, mat)
			if not (mat is StandardMaterial3D):
				continue
			mat.emission_enabled = true
			if is_front:
				mat.emission = Color(1.0, 0.96, 0.85)
				mat.emission_energy_multiplier = 0.0
				_head_mats.append(mat)
			else:
				mat.emission = Color(1.0, 0.05, 0.05)
				mat.emission_energy_multiplier = 0.0
				_tail_glow_mats.append(mat)


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
