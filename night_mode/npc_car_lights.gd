extends Node3D
class_name NPCCarLights

## Упрощённое освещение для NPC машин (без теней, меньший range)

var headlight: SpotLight3D
var taillight: OmniLight3D
var reverse_light: OmniLight3D

# Mesh для визуального эффекта
var headlight_mesh: MeshInstance3D
var taillight_mesh: MeshInstance3D
var reverse_mesh: MeshInstance3D

var _npc: VehicleBody3D
var _lights_enabled := false
var _taillight_mat: StandardMaterial3D


func setup_lights(npc: VehicleBody3D) -> void:
	_npc = npc

	_create_headlight()
	_create_taillight()
	_create_reverse_light()
	_create_light_meshes()


func _create_headlight() -> void:
	# SpotLight3D светит по -Z, машина едет по +Z, поворачиваем на 180° по Y
	headlight = SpotLight3D.new()
	headlight.name = "NPCHeadlight"
	headlight.position = Vector3(0, 0.55, 2.1)
	headlight.rotation_degrees = Vector3(5, 180, 0)  # 180° по Y + 5° вниз
	headlight.spot_range = 40.0
	headlight.spot_angle = 50.0
	headlight.spot_angle_attenuation = 0.8
	headlight.light_energy = 3.0
	headlight.light_color = Color(0.95, 0.95, 0.85)
	headlight.shadow_enabled = false  # Без теней для производительности
	headlight.visible = false
	_npc.add_child(headlight)


func _create_taillight() -> void:
	taillight = OmniLight3D.new()
	taillight.name = "NPCTaillight"
	taillight.position = Vector3(0, 0.4, -2.2)  # Ниже, чтобы не отражался в стекле
	taillight.omni_range = 3.0
	taillight.light_energy = 0.8
	taillight.light_color = Color(1.0, 0.0, 0.0)
	taillight.shadow_enabled = false
	taillight.visible = false
	_npc.add_child(taillight)


func _create_reverse_light() -> void:
	reverse_light = OmniLight3D.new()
	reverse_light.name = "NPCReverseLight"
	reverse_light.position = Vector3(0, 0.35, -2.2)  # Ниже
	reverse_light.omni_range = 4.0
	reverse_light.light_energy = 1.2
	reverse_light.light_color = Color(1.0, 1.0, 1.0)
	reverse_light.shadow_enabled = false
	reverse_light.visible = false
	_npc.add_child(reverse_light)


func _create_light_meshes() -> void:
	# Материал для светящихся фар
	var headlight_mat := StandardMaterial3D.new()
	headlight_mat.albedo_color = Color(1.0, 1.0, 0.9)
	headlight_mat.emission_enabled = true
	headlight_mat.emission = Color(1.0, 1.0, 0.8)
	headlight_mat.emission_energy_multiplier = 4.0

	# Mesh фар (два прямоугольника)
	headlight_mesh = MeshInstance3D.new()
	headlight_mesh.name = "NPCHeadlightMesh"

	# Создаём ImmediateMesh с двумя квадами
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 0.1, 0.03)
	headlight_mesh.mesh = mesh
	headlight_mesh.material_override = headlight_mat
	headlight_mesh.position = Vector3(0, 0.55, 2.21)
	headlight_mesh.visible = false
	_npc.add_child(headlight_mesh)

	# Материал для габаритов (сохраняем ссылку для стоп-сигналов)
	_taillight_mat = StandardMaterial3D.new()
	_taillight_mat.albedo_color = Color(1.0, 0.0, 0.0)
	_taillight_mat.emission_enabled = true
	_taillight_mat.emission = Color(1.0, 0.0, 0.0)
	_taillight_mat.emission_energy_multiplier = 1.5

	taillight_mesh = MeshInstance3D.new()
	taillight_mesh.name = "NPCTaillightMesh"
	var tl_mesh := BoxMesh.new()
	tl_mesh.size = Vector3(0.4, 0.06, 0.03)
	taillight_mesh.mesh = tl_mesh
	taillight_mesh.material_override = _taillight_mat
	taillight_mesh.position = Vector3(0, 0.4, -2.22)  # Ниже
	taillight_mesh.visible = false
	_npc.add_child(taillight_mesh)

	# Материал для заднего хода (белый)
	var reverse_mat := StandardMaterial3D.new()
	reverse_mat.albedo_color = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_enabled = true
	reverse_mat.emission = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_energy_multiplier = 2.5

	reverse_mesh = MeshInstance3D.new()
	reverse_mesh.name = "NPCReverseMesh"
	var rv_mesh := BoxMesh.new()
	rv_mesh.size = Vector3(0.12, 0.05, 0.03)
	reverse_mesh.mesh = rv_mesh
	reverse_mesh.material_override = reverse_mat
	reverse_mesh.position = Vector3(0, 0.35, -2.22)  # Ниже
	reverse_mesh.visible = false
	_npc.add_child(reverse_mesh)


func enable_lights() -> void:
	if _lights_enabled:
		return
	_lights_enabled = true

	if headlight:
		headlight.visible = true
	if taillight:
		taillight.visible = true
	if headlight_mesh:
		headlight_mesh.visible = true
	if taillight_mesh:
		taillight_mesh.visible = true


func disable_lights() -> void:
	if not _lights_enabled:
		return
	_lights_enabled = false

	if headlight:
		headlight.visible = false
	if taillight:
		taillight.visible = false
	if headlight_mesh:
		headlight_mesh.visible = false
	if taillight_mesh:
		taillight_mesh.visible = false
	if reverse_light:
		reverse_light.visible = false
	if reverse_mesh:
		reverse_mesh.visible = false


func set_braking(is_braking: bool) -> void:
	if not _lights_enabled:
		return
	# Увеличиваем яркость при торможении
	var energy := 3.0 if is_braking else 1.0
	if taillight:
		taillight.light_energy = energy
	if _taillight_mat:
		_taillight_mat.emission_energy_multiplier = 6.0 if is_braking else 2.0


func set_reversing(is_reversing: bool) -> void:
	if not _lights_enabled:
		return
	if reverse_light:
		reverse_light.visible = is_reversing
	if reverse_mesh:
		reverse_mesh.visible = is_reversing


func cleanup() -> void:
	if headlight and is_instance_valid(headlight):
		headlight.queue_free()
	if taillight and is_instance_valid(taillight):
		taillight.queue_free()
	if reverse_light and is_instance_valid(reverse_light):
		reverse_light.queue_free()
	if headlight_mesh and is_instance_valid(headlight_mesh):
		headlight_mesh.queue_free()
	if taillight_mesh and is_instance_valid(taillight_mesh):
		taillight_mesh.queue_free()
	if reverse_mesh and is_instance_valid(reverse_mesh):
		reverse_mesh.queue_free()
