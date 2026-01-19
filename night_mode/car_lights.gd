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

# Тип модели машины
enum CarModel { DEFAULT, NEXIA, PAZ }
var _car_model: CarModel = CarModel.DEFAULT


func _ready() -> void:
	# Ищем машину-родителя
	var parent := get_parent()
	if parent is VehicleBody3D:
		_car = parent
		_detect_car_model()
		_setup_all_lights()


func _detect_car_model() -> void:
	"""Определяет тип модели машины по наличию дочерних узлов"""
	# Ищем узлы моделей
	for child in _car.get_children():
		if child.name == "NexiaModel":
			_car_model = CarModel.NEXIA
			print("CarLights: Detected Nexia model")
			return
		elif child.name == "PAZModel":
			_car_model = CarModel.PAZ
			print("CarLights: Detected PAZ bus model")
			return

	_car_model = CarModel.DEFAULT
	print("CarLights: Using default model")


func _setup_all_lights() -> void:
	_create_headlights()
	_create_taillights()
	_create_reverse_light()
	_create_underglow()
	_create_light_meshes()


func _create_headlights() -> void:
	# Позиции фар в зависимости от модели
	var left_pos: Vector3
	var right_pos: Vector3

	if _car_model == CarModel.NEXIA:
		# Позиции для Nexia - немного ближе к кузову по Z
		left_pos = Vector3(-0.55, 0.6, 1.8)
		right_pos = Vector3(0.55, 0.6, 1.8)
		print("CarLights: Creating Nexia headlights at z=1.8")
	elif _car_model == CarModel.PAZ:
		# Позиции для ПАЗ - автобус, фары ближе к корпусу и друг к другу
		left_pos = Vector3(-0.55, 0.1, 2.3)
		right_pos = Vector3(0.55, 0.1, 2.3)
		print("CarLights: Creating PAZ headlights - closer to body and together")
	else:
		# Позиции для стандартной модели
		left_pos = Vector3(-0.55, 0.6, 2.3)
		right_pos = Vector3(0.55, 0.6, 2.3)

	# Левая фара
	# SpotLight3D светит по -Z, машина едет по +Z, поэтому поворачиваем на 180° по Y
	headlight_left = SpotLight3D.new()
	headlight_left.name = "HeadlightL"
	headlight_left.position = left_pos
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
	headlight_right.position = right_pos
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
	# Позиции задних фонарей в зависимости от модели
	var left_pos: Vector3
	var right_pos: Vector3

	if _car_model == CarModel.NEXIA:
		# Позиции для Nexia - ближе друг к другу, выше
		left_pos = Vector3(-0.45, 0.80, -2.0)
		right_pos = Vector3(0.45, 0.80, -2.0)
		print("CarLights: Creating Nexia taillights at (-0.45, 0.80, -2.0)")
	elif _car_model == CarModel.PAZ:
		# Позиции для ПАЗ - автобус, задние фары очень низко
		left_pos = Vector3(-0.55, -0.4, -2.4)
		right_pos = Vector3(0.55, -0.4, -2.4)
		print("CarLights: Creating PAZ taillights - very low")
	else:
		# Позиции для стандартной модели
		left_pos = Vector3(-0.75, 0.35, -2.5)
		right_pos = Vector3(0.75, 0.35, -2.5)

	# Левый габарит/стоп - смещён дальше назад, чтобы не отражался в заднем стекле
	taillight_left = OmniLight3D.new()
	taillight_left.name = "TaillightL"
	taillight_left.position = left_pos
	taillight_left.omni_range = 2.5
	taillight_left.light_energy = 0.6
	taillight_left.light_color = Color(1.0, 0.0, 0.0)
	taillight_left.visible = false
	add_child(taillight_left)

	# Правый габарит/стоп
	taillight_right = OmniLight3D.new()
	taillight_right.name = "TaillightR"
	taillight_right.position = right_pos
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
	# Позиции в зависимости от модели
	var headlight_left_pos: Vector3
	var headlight_right_pos: Vector3
	var headlight_size: Vector3

	if _car_model == CarModel.NEXIA:
		# Для Nexia - ближе к кузову
		headlight_left_pos = Vector3(-0.55, 0.55, 1.72)
		headlight_right_pos = Vector3(0.55, 0.55, 1.72)
		headlight_size = Vector3(0.25, 0.12, 0.05)
		print("CarLights: Creating Nexia headlight meshes at z=1.72")
	elif _car_model == CarModel.PAZ:
		# Для ПАЗ - автобус, фары ближе к корпусу и друг к другу
		headlight_left_pos = Vector3(-0.55, 0.05, 2.22)
		headlight_right_pos = Vector3(0.55, 0.05, 2.22)
		headlight_size = Vector3(0.35, 0.18, 0.08)
		print("CarLights: Creating PAZ headlight meshes - closer")
	else:
		# Позиции для стандартной модели
		headlight_left_pos = Vector3(-0.55, 0.55, 2.22)
		headlight_right_pos = Vector3(0.55, 0.55, 2.22)
		headlight_size = Vector3(0.25, 0.12, 0.05)

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
	hl_mesh.size = headlight_size
	headlight_mesh_left.mesh = hl_mesh
	headlight_mesh_left.material_override = headlight_mat
	headlight_mesh_left.position = headlight_left_pos
	headlight_mesh_left.visible = false
	add_child(headlight_mesh_left)

	# Правый световой элемент фары
	headlight_mesh_right = MeshInstance3D.new()
	headlight_mesh_right.name = "HeadlightMeshR"
	headlight_mesh_right.mesh = hl_mesh
	headlight_mesh_right.material_override = headlight_mat
	headlight_mesh_right.position = headlight_right_pos
	headlight_mesh_right.visible = false
	add_child(headlight_mesh_right)

	# Позиции задних фонарей в зависимости от модели
	var taillight_left_pos: Vector3
	var taillight_right_pos: Vector3
	var taillight_size: Vector3
	var reverse_pos: Vector3
	var reverse_size: Vector3

	if _car_model == CarModel.NEXIA:
		# Для Nexia - ближе друг к другу, выше, меньше размер
		taillight_left_pos = Vector3(-0.45, 0.80, -2.02)
		taillight_right_pos = Vector3(0.45, 0.80, -2.02)
		taillight_size = Vector3(0.12, 0.053, 0.02)  # В 1.5 раза меньше: 0.18/1.5, 0.08/1.5, 0.03/1.5
		reverse_pos = Vector3(0, 0.80, -1.78)
		reverse_size = Vector3(0.08, 0.04, 0.02)  # В 1.5 раза меньше: 0.12/1.5, 0.06/1.5, 0.03/1.5
		print("CarLights: Creating Nexia taillight meshes at (-0.45, 0.80, -2.02)")
	elif _car_model == CarModel.PAZ:
		# Для ПАЗ - автобус, задние фары очень низко
		taillight_left_pos = Vector3(-0.55, -0.45, -2.42)
		taillight_right_pos = Vector3(0.55, -0.45, -2.42)
		taillight_size = Vector3(0.25, 0.12, 0.04)
		reverse_pos = Vector3(0, -0.45, -2.18)
		reverse_size = Vector3(0.18, 0.09, 0.04)
		print("CarLights: Creating PAZ taillight meshes - very low")
	else:
		# Позиции для стандартной модели
		taillight_left_pos = Vector3(-0.75, 0.35, -2.52)
		taillight_right_pos = Vector3(0.75, 0.35, -2.52)
		taillight_size = Vector3(0.18, 0.08, 0.03)
		reverse_pos = Vector3(0, 0.35, -2.28)
		reverse_size = Vector3(0.12, 0.06, 0.03)

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

	# Левый габарит
	taillight_mesh_left = MeshInstance3D.new()
	taillight_mesh_left.name = "TaillightMeshL"
	var tl_mesh := BoxMesh.new()
	tl_mesh.size = taillight_size
	taillight_mesh_left.mesh = tl_mesh
	taillight_mesh_left.material_override = _taillight_mat_left
	taillight_mesh_left.position = taillight_left_pos
	taillight_mesh_left.visible = false
	add_child(taillight_mesh_left)

	# Правый габарит
	taillight_mesh_right = MeshInstance3D.new()
	taillight_mesh_right.name = "TaillightMeshR"
	taillight_mesh_right.mesh = tl_mesh
	taillight_mesh_right.material_override = _taillight_mat_right
	taillight_mesh_right.position = taillight_right_pos
	taillight_mesh_right.visible = false
	add_child(taillight_mesh_right)

	# Материал для фонаря заднего хода
	var reverse_mat := StandardMaterial3D.new()
	reverse_mat.albedo_color = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_enabled = true
	reverse_mat.emission = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_energy_multiplier = 2.5

	# Фонарь заднего хода (по центру)
	reverse_mesh = MeshInstance3D.new()
	reverse_mesh.name = "ReverseMesh"
	var rv_mesh := BoxMesh.new()
	rv_mesh.size = reverse_size
	reverse_mesh.mesh = rv_mesh
	reverse_mesh.material_override = reverse_mat
	reverse_mesh.position = reverse_pos
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
