extends Node3D
class_name NPCCarLights

## Упрощённое освещение для NPC машин (без теней, меньший range)

var headlight: OmniLight3D
var taillight: OmniLight3D

# Mesh для визуального эффекта
var headlight_mesh: MeshInstance3D
var taillight_mesh: MeshInstance3D

var _npc: VehicleBody3D
var _lights_enabled := false


func setup_lights(npc: VehicleBody3D) -> void:
	_npc = npc

	_create_headlight()
	_create_taillight()
	_create_light_meshes()


func _create_headlight() -> void:
	# Один OmniLight вместо двух SpotLight для производительности
	headlight = OmniLight3D.new()
	headlight.name = "NPCHeadlight"
	headlight.position = Vector3(0, 0.55, 2.1)
	headlight.omni_range = 18.0
	headlight.light_energy = 2.0
	headlight.light_color = Color(0.95, 0.95, 0.85)
	headlight.shadow_enabled = false  # Без теней для производительности
	headlight.visible = false
	_npc.add_child(headlight)


func _create_taillight() -> void:
	taillight = OmniLight3D.new()
	taillight.name = "NPCTaillight"
	taillight.position = Vector3(0, 0.55, -2.1)
	taillight.omni_range = 5.0
	taillight.light_energy = 1.2
	taillight.light_color = Color(1.0, 0.0, 0.0)
	taillight.shadow_enabled = false
	taillight.visible = false
	_npc.add_child(taillight)


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

	# Материал для габаритов
	var taillight_mat := StandardMaterial3D.new()
	taillight_mat.albedo_color = Color(1.0, 0.0, 0.0)
	taillight_mat.emission_enabled = true
	taillight_mat.emission = Color(1.0, 0.0, 0.0)
	taillight_mat.emission_energy_multiplier = 2.5

	taillight_mesh = MeshInstance3D.new()
	taillight_mesh.name = "NPCTaillightMesh"
	var tl_mesh := BoxMesh.new()
	tl_mesh.size = Vector3(0.5, 0.08, 0.03)
	taillight_mesh.mesh = tl_mesh
	taillight_mesh.material_override = taillight_mat
	taillight_mesh.position = Vector3(0, 0.55, -2.19)
	taillight_mesh.visible = false
	_npc.add_child(taillight_mesh)


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


func cleanup() -> void:
	if headlight and is_instance_valid(headlight):
		headlight.queue_free()
	if taillight and is_instance_valid(taillight):
		taillight.queue_free()
	if headlight_mesh and is_instance_valid(headlight_mesh):
		headlight_mesh.queue_free()
	if taillight_mesh and is_instance_valid(taillight_mesh):
		taillight_mesh.queue_free()
