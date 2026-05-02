extends Node3D

## Маркер высадки в стиле GTA San Andreas
## Светящийся диск + тор-кольцо + вертикальный луч, жёлто-оранжевый

const MARKER_COLOR := Color(1.0, 0.75, 0.0)

var _time: float = 0.0
var _disc: MeshInstance3D
var _ring: MeshInstance3D
var _beam: MeshInstance3D
var _disc_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D
var _beam_mat: StandardMaterial3D
var _raycast_done: bool = false


func _ready() -> void:
	# Диск на земле
	_disc = MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = 3.0
	disc_mesh.bottom_radius = 3.0
	disc_mesh.height = 0.05
	_disc.mesh = disc_mesh
	_disc_mat = _make_glow_material(MARKER_COLOR, 0.6)
	_disc.set_surface_override_material(0, _disc_mat)
	_disc.position = Vector3(0, 0.05, 0)
	add_child(_disc)

	# Тор-кольцо (TorusMesh)
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 2.5
	ring_mesh.outer_radius = 3.2
	ring_mesh.rings = 32
	ring_mesh.ring_segments = 16
	_ring.mesh = ring_mesh
	_ring_mat = _make_glow_material(MARKER_COLOR, 0.5)
	_ring.set_surface_override_material(0, _ring_mat)
	_ring.position = Vector3(0, 0.3, 0)
	add_child(_ring)

	# Вертикальный луч (конический цилиндр)
	_beam = MeshInstance3D.new()
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.0
	beam_mesh.bottom_radius = 1.5
	beam_mesh.height = 15.0
	_beam.mesh = beam_mesh
	_beam_mat = _make_glow_material(MARKER_COLOR, 0.3)
	_beam.set_surface_override_material(0, _beam_mat)
	_beam.position = Vector3(0, 7.5, 0)
	add_child(_beam)

	# OmniLight
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.85, 0.4)
	light.light_energy = 2.0
	light.omni_range = 10.0
	light.position = Vector3(0, 1.0, 0)
	add_child(light)


func _physics_process(delta: float) -> void:
	_time += delta

	# Пульсация
	var pulse := (sin(_time * 3.0) + 1.0) * 0.5  # 0..1
	_disc_mat.albedo_color.a = 0.4 + pulse * 0.4
	_disc_mat.emission_energy_multiplier = 1.0 + pulse * 2.0
	_ring_mat.albedo_color.a = 0.3 + pulse * 0.4
	_ring_mat.emission_energy_multiplier = 1.0 + pulse * 1.5
	_beam_mat.albedo_color.a = 0.15 + pulse * 0.2
	_beam_mat.emission_energy_multiplier = 0.5 + pulse * 1.5

	# Медленное вращение
	rotation.y += delta * 0.5

	# Raycast Y-коррекция
	if not _raycast_done:
		_snap_to_ground()


func _snap_to_ground() -> void:
	var space_state := get_world_3d().direct_space_state
	if not space_state:
		return
	var x := global_position.x
	var z := global_position.z
	for i in range(10):
		var from_y := 5000.0 - i * 550.0
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, from_y, z), Vector3(x, -500.0, z))
		var result := space_state.intersect_ray(query)
		if not result.is_empty():
			global_position.y = result.position.y
			_raycast_done = true
			return


func _make_glow_material(color: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	return mat
