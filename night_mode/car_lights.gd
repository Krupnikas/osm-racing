extends Node3D
class_name CarLights

## Освещение машины игрока: фары, габариты, стоп-сигналы, неоновая подсветка

# Настройки неона
@export var underglow_enabled := true  # По умолчанию включен (тусклый)
@export var underglow_color := Color(0.0, 1.0, 0.9)  # Cyan

# Цвета неона для переключения (G key)
const UNDERGLOW_COLORS := [
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(0.8, 0.0, 1.0),   # Purple
	Color(1.0, 0.0, 0.5),   # Pink
	Color(0.0, 1.0, 0.3),   # Green
	Color(1.0, 0.5, 0.0),   # Orange
]
var _current_color_index := 0

# Ссылки на источники света
var headlight_left: SpotLight3D
var headlight_right: SpotLight3D
var taillight_left: OmniLight3D
var taillight_right: OmniLight3D
var reverse_light: OmniLight3D
var underglow_lights: Array[OmniLight3D] = []

# Mesh для визуального эффекта фар
var headlight_mesh_left: MeshInstance3D
var headlight_mesh_right: MeshInstance3D
var taillight_mesh_left: MeshInstance3D
var taillight_mesh_right: MeshInstance3D
var reverse_mesh: MeshInstance3D

# Материал для динамического изменения яркости
var _taillight_mat_left: StandardMaterial3D
var _taillight_mat_right: StandardMaterial3D

# Ссылка на машину
var _car: VehicleBody3D
var _lights_enabled := false


func _ready() -> void:
	# Ищем машину-родителя
	var parent := get_parent()
	if parent is VehicleBody3D:
		_car = parent
		_setup_all_lights()


func _setup_all_lights() -> void:
	_create_headlights()
	_create_taillights()
	_create_reverse_light()
	_create_underglow()
	_create_light_meshes()


func _create_headlights() -> void:
	# Левая фара
	# SpotLight3D светит по -Z, машина едет по +Z, поэтому поворачиваем на 180° по Y
	headlight_left = SpotLight3D.new()
	headlight_left.name = "HeadlightL"
	headlight_left.position = Vector3(-0.55, 0.6, 2.3)
	headlight_left.rotation_degrees = Vector3(10, 180, 0)  # 180° по Y + 10° вниз
	headlight_left.spot_range = 80.0
	headlight_left.spot_angle = 45.0
	headlight_left.spot_angle_attenuation = 0.8
	headlight_left.light_energy = 4.0
	headlight_left.light_color = Color(1.0, 0.98, 0.9)
	headlight_left.shadow_enabled = true
	headlight_left.visible = false
	add_child(headlight_left)

	# Правая фара
	headlight_right = SpotLight3D.new()
	headlight_right.name = "HeadlightR"
	headlight_right.position = Vector3(0.55, 0.6, 2.3)
	headlight_right.rotation_degrees = Vector3(10, 180, 0)  # 180° по Y + 10° вниз
	headlight_right.spot_range = 80.0
	headlight_right.spot_angle = 45.0
	headlight_right.spot_angle_attenuation = 0.8
	headlight_right.light_energy = 4.0
	headlight_right.light_color = Color(1.0, 0.98, 0.9)
	headlight_right.shadow_enabled = true
	headlight_right.visible = false
	add_child(headlight_right)


func _create_taillights() -> void:
	# Левый габарит/стоп - смещён дальше назад, чтобы не отражался в заднем стекле
	taillight_left = OmniLight3D.new()
	taillight_left.name = "TaillightL"
	taillight_left.position = Vector3(-0.75, 0.35, -2.5)  # Дальше назад и ниже
	taillight_left.omni_range = 2.5
	taillight_left.light_energy = 0.6
	taillight_left.light_color = Color(1.0, 0.0, 0.0)
	taillight_left.visible = false
	add_child(taillight_left)

	# Правый габарит/стоп
	taillight_right = OmniLight3D.new()
	taillight_right.name = "TaillightR"
	taillight_right.position = Vector3(0.75, 0.35, -2.5)  # Дальше назад и ниже
	taillight_right.omni_range = 2.5
	taillight_right.light_energy = 0.6
	taillight_right.light_color = Color(1.0, 0.0, 0.0)
	taillight_right.visible = false
	add_child(taillight_right)


func _create_reverse_light() -> void:
	# Фонарь заднего хода (белый, по центру) - смещён назад
	reverse_light = OmniLight3D.new()
	reverse_light.name = "ReverseLight"
	reverse_light.position = Vector3(0, 0.3, -2.5)  # Дальше назад
	reverse_light.omni_range = 3.5
	reverse_light.light_energy = 1.0
	reverse_light.light_color = Color(1.0, 1.0, 1.0)
	reverse_light.visible = false
	add_child(reverse_light)


func _create_underglow() -> void:
	# 4 источника под машиной + 2 по бокам
	var positions := [
		Vector3(-0.85, 0.12, 1.0),   # Front left
		Vector3(0.85, 0.12, 1.0),    # Front right
		Vector3(-0.85, 0.12, -1.0),  # Rear left
		Vector3(0.85, 0.12, -1.0),   # Rear right
		Vector3(-0.95, 0.15, 0.0),   # Side left
		Vector3(0.95, 0.15, 0.0),    # Side right
	]

	for i in range(positions.size()):
		var light := OmniLight3D.new()
		light.name = "Underglow_%d" % i
		light.position = positions[i]
		light.omni_range = 1.5
		light.light_energy = 0.25  # Совсем тусклый неон
		light.light_color = underglow_color
		light.visible = false
		add_child(light)
		underglow_lights.append(light)


func _create_light_meshes() -> void:
	# Материал для светящихся фар
	var headlight_mat := StandardMaterial3D.new()
	headlight_mat.albedo_color = Color(1.0, 1.0, 0.9)
	headlight_mat.emission_enabled = true
	headlight_mat.emission = Color(1.0, 1.0, 0.8)
	headlight_mat.emission_energy_multiplier = 5.0

	# Левый световой элемент фары
	headlight_mesh_left = MeshInstance3D.new()
	headlight_mesh_left.name = "HeadlightMeshL"
	var hl_mesh := BoxMesh.new()
	hl_mesh.size = Vector3(0.25, 0.12, 0.05)
	headlight_mesh_left.mesh = hl_mesh
	headlight_mesh_left.material_override = headlight_mat
	headlight_mesh_left.position = Vector3(-0.55, 0.55, 2.22)
	headlight_mesh_left.visible = false
	add_child(headlight_mesh_left)

	# Правый световой элемент фары
	headlight_mesh_right = MeshInstance3D.new()
	headlight_mesh_right.name = "HeadlightMeshR"
	headlight_mesh_right.mesh = hl_mesh
	headlight_mesh_right.material_override = headlight_mat
	headlight_mesh_right.position = Vector3(0.55, 0.55, 2.22)
	headlight_mesh_right.visible = false
	add_child(headlight_mesh_right)

	# Материалы для габаритов (отдельные для каждого, чтобы менять яркость)
	_taillight_mat_left = StandardMaterial3D.new()
	_taillight_mat_left.albedo_color = Color(1.0, 0.0, 0.0)
	_taillight_mat_left.emission_enabled = true
	_taillight_mat_left.emission = Color(1.0, 0.0, 0.0)
	_taillight_mat_left.emission_energy_multiplier = 1.5

	_taillight_mat_right = StandardMaterial3D.new()
	_taillight_mat_right.albedo_color = Color(1.0, 0.0, 0.0)
	_taillight_mat_right.emission_enabled = true
	_taillight_mat_right.emission = Color(1.0, 0.0, 0.0)
	_taillight_mat_right.emission_energy_multiplier = 1.5

	# Левый габарит - дальше назад чтобы не отражался
	taillight_mesh_left = MeshInstance3D.new()
	taillight_mesh_left.name = "TaillightMeshL"
	var tl_mesh := BoxMesh.new()
	tl_mesh.size = Vector3(0.18, 0.08, 0.03)
	taillight_mesh_left.mesh = tl_mesh
	taillight_mesh_left.material_override = _taillight_mat_left
	taillight_mesh_left.position = Vector3(-0.75, 0.35, -2.52)  # Дальше назад
	taillight_mesh_left.visible = false
	add_child(taillight_mesh_left)

	# Правый габарит
	taillight_mesh_right = MeshInstance3D.new()
	taillight_mesh_right.name = "TaillightMeshR"
	taillight_mesh_right.mesh = tl_mesh
	taillight_mesh_right.material_override = _taillight_mat_right
	taillight_mesh_right.position = Vector3(0.75, 0.35, -2.52)  # Дальше назад
	taillight_mesh_right.visible = false
	add_child(taillight_mesh_right)

	# Материал для фонаря заднего хода
	var reverse_mat := StandardMaterial3D.new()
	reverse_mat.albedo_color = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_enabled = true
	reverse_mat.emission = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_energy_multiplier = 2.5

	# Фонарь заднего хода (по центру) - ниже
	reverse_mesh = MeshInstance3D.new()
	reverse_mesh.name = "ReverseMesh"
	var rv_mesh := BoxMesh.new()
	rv_mesh.size = Vector3(0.12, 0.06, 0.03)
	reverse_mesh.mesh = rv_mesh
	reverse_mesh.material_override = reverse_mat
	reverse_mesh.position = Vector3(0, 0.35, -2.28)
	reverse_mesh.visible = false
	add_child(reverse_mesh)


func _process(delta: float) -> void:
	if not _lights_enabled or not _car:
		return

	# Проверяем торможение
	var braking: bool = _car.brake_input > 0.1 if "brake_input" in _car else false

	# Проверяем задний ход
	var reversing: bool = _car.current_gear == 0 if "current_gear" in _car else false

	# Обновляем яркость стоп-сигналов
	var tail_energy: float = 2.5 if braking else 0.8
	if taillight_left:
		taillight_left.light_energy = tail_energy
	if taillight_right:
		taillight_right.light_energy = tail_energy

	# Обновляем emission на mesh габаритов
	var emission_mult: float = 4.0 if braking else 1.5
	if _taillight_mat_left:
		_taillight_mat_left.emission_energy_multiplier = emission_mult
	if _taillight_mat_right:
		_taillight_mat_right.emission_energy_multiplier = emission_mult

	# Обновляем фонарь заднего хода
	if reverse_light:
		reverse_light.visible = reversing
	if reverse_mesh:
		reverse_mesh.visible = reversing



func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G and _lights_enabled:
			toggle_underglow()


func enable_lights() -> void:
	if _lights_enabled:
		return

	_lights_enabled = true

	if headlight_left:
		headlight_left.visible = true
	if headlight_right:
		headlight_right.visible = true
	if taillight_left:
		taillight_left.visible = true
	if taillight_right:
		taillight_right.visible = true
	if headlight_mesh_left:
		headlight_mesh_left.visible = true
	if headlight_mesh_right:
		headlight_mesh_right.visible = true
	if taillight_mesh_left:
		taillight_mesh_left.visible = true
	if taillight_mesh_right:
		taillight_mesh_right.visible = true

	if underglow_enabled:
		for light in underglow_lights:
			light.visible = true


func disable_lights() -> void:
	if not _lights_enabled:
		return

	_lights_enabled = false

	if headlight_left:
		headlight_left.visible = false
	if headlight_right:
		headlight_right.visible = false
	if taillight_left:
		taillight_left.visible = false
	if taillight_right:
		taillight_right.visible = false
	if headlight_mesh_left:
		headlight_mesh_left.visible = false
	if headlight_mesh_right:
		headlight_mesh_right.visible = false
	if taillight_mesh_left:
		taillight_mesh_left.visible = false
	if taillight_mesh_right:
		taillight_mesh_right.visible = false

	for light in underglow_lights:
		light.visible = false


func toggle_underglow() -> void:
	"""Переключает неоновую подсветку вкл/выкл"""
	underglow_enabled = not underglow_enabled
	for light in underglow_lights:
		light.visible = underglow_enabled and _lights_enabled

	# При включении переключаем цвет
	if underglow_enabled:
		_current_color_index = (_current_color_index + 1) % UNDERGLOW_COLORS.size()
		underglow_color = UNDERGLOW_COLORS[_current_color_index]
		for light in underglow_lights:
			light.light_color = underglow_color

	print("Underglow: ", "ON (" + str(_current_color_index) + ")" if underglow_enabled else "OFF")


func set_underglow_color(color: Color) -> void:
	underglow_color = color
	for light in underglow_lights:
		light.light_color = color


func set_underglow_enabled(enabled: bool) -> void:
	underglow_enabled = enabled
	if _lights_enabled:
		for light in underglow_lights:
			light.visible = enabled
