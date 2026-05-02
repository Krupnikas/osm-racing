extends Node3D

## Процедурный человечек на точке подбора (такси)
## Рандомные цвета одежды/кожи, плавающий голубой маркер, OmniLight

const SHIRT_COLORS: Array[Color] = [
	Color(0.8, 0.2, 0.2), Color(0.2, 0.5, 0.8), Color(0.2, 0.7, 0.3),
	Color(0.9, 0.8, 0.1), Color(0.6, 0.3, 0.7), Color(0.9, 0.5, 0.2),
	Color(0.95, 0.95, 0.95), Color(0.15, 0.15, 0.15),
]

const SKIN_COLORS: Array[Color] = [
	Color(0.96, 0.80, 0.69), Color(0.72, 0.53, 0.39), Color(0.45, 0.30, 0.22),
]

const PANTS_COLORS: Array[Color] = [
	Color(0.15, 0.15, 0.3), Color(0.25, 0.25, 0.25),
	Color(0.35, 0.25, 0.15), Color(0.4, 0.35, 0.3),
]

var _marker_mesh: MeshInstance3D
var _time: float = 0.0
var _raycast_done: bool = false
var _snap_timer: float = 0.0


func _ready() -> void:
	var skin_color: Color = SKIN_COLORS[randi() % SKIN_COLORS.size()]
	var shirt_color: Color = SHIRT_COLORS[randi() % SHIRT_COLORS.size()]
	var pants_color: Color = PANTS_COLORS[randi() % PANTS_COLORS.size()]
	var hair_color := Color(0.15, 0.1, 0.05).lerp(Color(0.6, 0.5, 0.3), randf())

	# Ноги (2 цилиндра)
	for side in [-0.12, 0.12]:
		var leg := _make_mesh(CylinderMesh.new(), pants_color)
		(leg.mesh as CylinderMesh).top_radius = 0.08
		(leg.mesh as CylinderMesh).bottom_radius = 0.08
		(leg.mesh as CylinderMesh).height = 0.8
		leg.position = Vector3(side, 0.4, 0.0)
		add_child(leg)

	# Торс (капсула)
	var torso := _make_mesh(CapsuleMesh.new(), shirt_color)
	(torso.mesh as CapsuleMesh).radius = 0.18
	(torso.mesh as CapsuleMesh).height = 0.7
	torso.position = Vector3(0, 1.15, 0.0)
	add_child(torso)

	# Голова (сфера)
	var head := _make_mesh(SphereMesh.new(), skin_color)
	(head.mesh as SphereMesh).radius = 0.14
	(head.mesh as SphereMesh).height = 0.28
	head.position = Vector3(0, 1.7, 0.0)
	add_child(head)

	# Волосы (сфера чуть больше)
	var hair := _make_mesh(SphereMesh.new(), hair_color)
	(hair.mesh as SphereMesh).radius = 0.145
	(hair.mesh as SphereMesh).height = 0.2
	hair.position = Vector3(0, 1.76, -0.02)
	add_child(hair)

	# Плавающий голубой маркер
	_marker_mesh = _make_mesh(SphereMesh.new(), Color(0.3, 0.7, 1.0))
	(_marker_mesh.mesh as SphereMesh).radius = 0.15
	(_marker_mesh.mesh as SphereMesh).height = 0.3
	_marker_mesh.position = Vector3(0, 2.5, 0.0)
	var marker_mat: StandardMaterial3D = _marker_mesh.get_surface_override_material(0)
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.3, 0.7, 1.0)
	marker_mat.emission_energy_multiplier = 2.0
	add_child(_marker_mesh)

	# OmniLight у ног
	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 0.7, 1.0)
	light.light_energy = 1.5
	light.omni_range = 5.0
	light.position = Vector3(0, 0.5, 0.0)
	add_child(light)

	# Случайный поворот
	rotation.y = randf() * TAU


func _physics_process(delta: float) -> void:
	# Покачивание маркера
	_time += delta
	if _marker_mesh:
		_marker_mesh.position.y = 2.5 + sin(_time * 2.0) * 0.15

	# Raycast Y-коррекция (раз в секунду)
	if not _raycast_done:
		_snap_timer -= delta
		if _snap_timer <= 0.0:
			_snap_timer = 1.0
			_snap_to_ground()


func _snap_to_ground() -> void:
	var space_state := get_world_3d().direct_space_state
	if not space_state:
		return
	var x := global_position.x
	var z := global_position.z
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(x, 5000.0, z), Vector3(x, -500.0, z))
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		var old_y := global_position.y
		global_position.y = result.position.y
		_raycast_done = true
		print("WorkPerson: Snapped Y %.1f -> %.1f at (%.0f, %.0f)" % [old_y, result.position.y, x, z])


func _make_mesh(mesh: Mesh, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.set_surface_override_material(0, mat)
	return mi
