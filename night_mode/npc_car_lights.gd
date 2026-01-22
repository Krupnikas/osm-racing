extends Node3D
class_name NPCCarLights

## Упрощённое освещение для NPC машин (без теней, меньший range)
##
## ВАЖНО: Позиции фар синхронизированы с car_lights.gd
## При добавлении новой модели нужно обновить оба файла!

var headlight: SpotLight3D
var headlight_left: SpotLight3D  # Для моделей с раздельными фарами
var headlight_right: SpotLight3D
var taillight: OmniLight3D
var taillight_left: OmniLight3D  # Для моделей с раздельными фарами
var taillight_right: OmniLight3D
var reverse_light: OmniLight3D

# Mesh для визуального эффекта
var headlight_mesh: MeshInstance3D
var headlight_mesh_left: MeshInstance3D  # Для моделей с раздельными фарами
var headlight_mesh_right: MeshInstance3D
var taillight_mesh: MeshInstance3D
var taillight_mesh_left: MeshInstance3D  # Для моделей с раздельными фарами
var taillight_mesh_right: MeshInstance3D
var reverse_mesh: MeshInstance3D

# Используем раздельные фары для некоторых моделей
var _use_split_lights := false

var _npc: VehicleBody3D
var _lights_enabled := false
var _taillight_mat: StandardMaterial3D

# Тип модели машины (синхронизировано с car_lights.gd)
enum CarModel { DEFAULT, NEXIA, PAZ, LADA_2109, VAZ_2107 }
var _car_model: CarModel = CarModel.DEFAULT


func setup_lights(npc: VehicleBody3D) -> void:
	_npc = npc
	_detect_car_model()

	_create_headlight()
	_create_taillight()
	_create_reverse_light()
	_create_light_meshes()


func _detect_car_model() -> void:
	"""Определяет тип модели машины по имени ноды"""
	for child in _npc.get_children():
		if child.name == "NexiaModel":
			_car_model = CarModel.NEXIA
			return
		elif child.name == "PAZModel":
			_car_model = CarModel.PAZ
			return
		elif child.name == "VAZ2107Model":
			_car_model = CarModel.VAZ_2107
			return
		elif child.name == "Model":
			# Lada 2109 (taxi, DPS) uses "Model" node name
			_car_model = CarModel.LADA_2109
			return
	_car_model = CarModel.DEFAULT


func _create_headlight() -> void:
	# SpotLight3D светит по -Z, машина едет по +Z, поворачиваем на 180° по Y
	# Позиции синхронизированы с car_lights.gd

	# Реальные модели (Lada, Nexia, PAZ) используют раздельные фары
	if _car_model == CarModel.LADA_2109:
		_use_split_lights = true
		var left_pos = Vector3(-0.5, 0.6, 2.15)
		var right_pos = Vector3(0.5, 0.6, 2.15)
		headlight_left = _create_single_headlight("NPCHeadlightL", left_pos)
		headlight_right = _create_single_headlight("NPCHeadlightR", right_pos)
		return

	if _car_model == CarModel.NEXIA:
		_use_split_lights = true
		var left_pos = Vector3(-0.55, 0.6, 1.8)
		var right_pos = Vector3(0.55, 0.6, 1.8)
		headlight_left = _create_single_headlight("NPCHeadlightL", left_pos)
		headlight_right = _create_single_headlight("NPCHeadlightR", right_pos)
		return

	if _car_model == CarModel.PAZ:
		_use_split_lights = true
		var left_pos = Vector3(-0.55, 0.1, 2.3)
		var right_pos = Vector3(0.55, 0.1, 2.3)
		headlight_left = _create_single_headlight("NPCHeadlightL", left_pos)
		headlight_right = _create_single_headlight("NPCHeadlightR", right_pos)
		return

	if _car_model == CarModel.VAZ_2107:
		_use_split_lights = true
		var left_pos = Vector3(-0.37, 0.37, 1.33)
		var right_pos = Vector3(0.37, 0.37, 1.33)
		headlight_left = _create_single_headlight("NPCHeadlightL", left_pos)
		headlight_right = _create_single_headlight("NPCHeadlightR", right_pos)
		return

	# Блочные машинки используют одну центральную фару
	headlight = _create_single_headlight("NPCHeadlight", Vector3(0, 0.55, 2.1))


func _create_single_headlight(light_name: String, pos: Vector3) -> SpotLight3D:
	var light = SpotLight3D.new()
	light.name = light_name
	light.position = pos
	light.rotation_degrees = Vector3(5, 180, 0)  # 180° по Y + 5° вниз
	light.spot_range = 40.0
	light.spot_angle = 45.0
	light.spot_angle_attenuation = 0.8
	light.light_energy = 2.0
	light.light_color = Color(0.95, 0.95, 0.85)
	light.shadow_enabled = false  # Без теней для производительности
	light.visible = false
	_npc.add_child(light)
	return light


func _create_taillight() -> void:
	# Позиции синхронизированы с car_lights.gd

	# Реальные модели используют раздельные задние фары
	if _car_model == CarModel.LADA_2109:
		var left_pos = Vector3(-0.35, 0.55, -2.05)
		var right_pos = Vector3(0.35, 0.55, -2.05)
		taillight_left = _create_single_taillight("NPCTaillightL", left_pos)
		taillight_right = _create_single_taillight("NPCTaillightR", right_pos)
		return

	if _car_model == CarModel.NEXIA:
		var left_pos = Vector3(-0.45, 0.80, -2.0)
		var right_pos = Vector3(0.45, 0.80, -2.0)
		taillight_left = _create_single_taillight("NPCTaillightL", left_pos)
		taillight_right = _create_single_taillight("NPCTaillightR", right_pos)
		return

	if _car_model == CarModel.PAZ:
		var left_pos = Vector3(-0.55, -0.4, -2.4)
		var right_pos = Vector3(0.55, -0.4, -2.4)
		taillight_left = _create_single_taillight("NPCTaillightL", left_pos)
		taillight_right = _create_single_taillight("NPCTaillightR", right_pos)
		return

	if _car_model == CarModel.VAZ_2107:
		var left_pos = Vector3(-0.37, 0.33, -1.33)
		var right_pos = Vector3(0.37, 0.33, -1.33)
		taillight_left = _create_single_taillight("NPCTaillightL", left_pos)
		taillight_right = _create_single_taillight("NPCTaillightR", right_pos)
		return

	# Блочные машинки используют одну центральную фару
	taillight = _create_single_taillight("NPCTaillight", Vector3(0, 0.4, -2.2))


func _create_single_taillight(light_name: String, pos: Vector3) -> OmniLight3D:
	var light = OmniLight3D.new()
	light.name = light_name
	light.position = pos
	light.omni_range = 3.0
	light.light_energy = 0.8
	light.light_color = Color(1.0, 0.0, 0.0)
	light.shadow_enabled = false
	light.visible = false
	_npc.add_child(light)
	return light


func _create_reverse_light() -> void:
	# Позиция зависит от модели (синхронизировано с car_lights.gd)
	var pos: Vector3
	if _car_model == CarModel.NEXIA:
		pos = Vector3(0, 0.75, -1.95)
	elif _car_model == CarModel.PAZ:
		pos = Vector3(0, -0.45, -2.18)
	elif _car_model == CarModel.LADA_2109:
		pos = Vector3(0, 0.5, -1.9)
	elif _car_model == CarModel.VAZ_2107:
		pos = Vector3(0, 0.3, -1.23)
	else:
		pos = Vector3(0, 0.35, -2.2)

	reverse_light = OmniLight3D.new()
	reverse_light.name = "NPCReverseLight"
	reverse_light.position = pos
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

	# Материал для габаритов
	_taillight_mat = StandardMaterial3D.new()
	_taillight_mat.albedo_color = Color(1.0, 0.0, 0.0)
	_taillight_mat.emission_enabled = true
	_taillight_mat.emission = Color(1.0, 0.0, 0.0)
	_taillight_mat.emission_energy_multiplier = 1.5

	# Создаём меши в зависимости от модели
	if _use_split_lights:
		_create_split_light_meshes(headlight_mat)
	else:
		_create_single_light_meshes(headlight_mat)

	# Фонарь заднего хода (всегда один по центру)
	var reverse_mat := StandardMaterial3D.new()
	reverse_mat.albedo_color = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_enabled = true
	reverse_mat.emission = Color(1.0, 1.0, 1.0)
	reverse_mat.emission_energy_multiplier = 2.5

	var reverse_pos: Vector3
	var reverse_size: Vector3
	if _car_model == CarModel.LADA_2109:
		reverse_pos = Vector3(0, 0.5, -1.9)
		reverse_size = Vector3(0.1, 0.05, 0.03)
	elif _car_model == CarModel.NEXIA:
		reverse_pos = Vector3(0, 0.7, -1.97)
		reverse_size = Vector3(0.12, 0.05, 0.03)
	elif _car_model == CarModel.PAZ:
		reverse_pos = Vector3(0, -0.45, -2.18)
		reverse_size = Vector3(0.18, 0.09, 0.03)
	elif _car_model == CarModel.VAZ_2107:
		reverse_pos = Vector3(0, 0.3, -1.23)
		reverse_size = Vector3(0.07, 0.04, 0.02)
	else:
		reverse_pos = Vector3(0, 0.35, -2.22)
		reverse_size = Vector3(0.12, 0.05, 0.03)

	reverse_mesh = MeshInstance3D.new()
	reverse_mesh.name = "NPCReverseMesh"
	var rv_mesh := BoxMesh.new()
	rv_mesh.size = reverse_size
	reverse_mesh.mesh = rv_mesh
	reverse_mesh.material_override = reverse_mat
	reverse_mesh.position = reverse_pos
	reverse_mesh.visible = false
	_npc.add_child(reverse_mesh)


func _create_split_light_meshes(headlight_mat: StandardMaterial3D) -> void:
	"""Создаёт раздельные меши фар для реальных моделей"""
	var hl_left_pos: Vector3
	var hl_right_pos: Vector3
	var hl_size: Vector3
	var tl_left_pos: Vector3
	var tl_right_pos: Vector3
	var tl_size: Vector3

	if _car_model == CarModel.LADA_2109:
		hl_left_pos = Vector3(-0.5, 0.55, 2.1)
		hl_right_pos = Vector3(0.5, 0.55, 2.1)
		hl_size = Vector3(0.22, 0.1, 0.05)
		tl_left_pos = Vector3(-0.35, 0.5, -2.0)
		tl_right_pos = Vector3(0.35, 0.5, -2.0)
		tl_size = Vector3(0.15, 0.08, 0.03)
	elif _car_model == CarModel.VAZ_2107:
		hl_left_pos = Vector3(-0.37, 0.33, 1.3)
		hl_right_pos = Vector3(0.37, 0.33, 1.3)
		hl_size = Vector3(0.12, 0.12, 0.03)  # Круглые фары, масштаб 0.67
		tl_left_pos = Vector3(-0.37, 0.3, -1.3)
		tl_right_pos = Vector3(0.37, 0.3, -1.3)
		tl_size = Vector3(0.08, 0.07, 0.02)
	elif _car_model == CarModel.NEXIA:
		hl_left_pos = Vector3(-0.55, 0.55, 1.72)
		hl_right_pos = Vector3(0.55, 0.55, 1.72)
		hl_size = Vector3(0.25, 0.12, 0.05)
		tl_left_pos = Vector3(-0.45, 0.75, -2.02)
		tl_right_pos = Vector3(0.45, 0.75, -2.02)
		tl_size = Vector3(0.18, 0.08, 0.03)
	elif _car_model == CarModel.PAZ:
		hl_left_pos = Vector3(-0.55, 0.05, 2.22)
		hl_right_pos = Vector3(0.55, 0.05, 2.22)
		hl_size = Vector3(0.35, 0.18, 0.08)
		tl_left_pos = Vector3(-0.55, -0.45, -2.42)
		tl_right_pos = Vector3(0.55, -0.45, -2.42)
		tl_size = Vector3(0.25, 0.12, 0.04)
	else:
		return  # Не должно случиться

	# Передние фары - левая и правая
	headlight_mesh_left = _create_headlight_mesh("NPCHeadlightMeshL", hl_left_pos, hl_size, headlight_mat)
	headlight_mesh_right = _create_headlight_mesh("NPCHeadlightMeshR", hl_right_pos, hl_size, headlight_mat)

	# Задние фары - левая и правая
	taillight_mesh_left = _create_taillight_mesh("NPCTaillightMeshL", tl_left_pos, tl_size)
	taillight_mesh_right = _create_taillight_mesh("NPCTaillightMeshR", tl_right_pos, tl_size)


func _create_single_light_meshes(headlight_mat: StandardMaterial3D) -> void:
	"""Создаёт одиночные центральные меши для блочных машинок"""
	var hl_pos = Vector3(0, 0.55, 2.21)
	var hl_size = Vector3(0.5, 0.1, 0.03)
	var tl_pos = Vector3(0, 0.4, -2.22)
	var tl_size = Vector3(0.4, 0.06, 0.03)

	headlight_mesh = _create_headlight_mesh("NPCHeadlightMesh", hl_pos, hl_size, headlight_mat)
	taillight_mesh = _create_taillight_mesh("NPCTaillightMesh", tl_pos, tl_size)


func _create_headlight_mesh(mesh_name: String, pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.name = mesh_name
	var box_mesh = BoxMesh.new()
	box_mesh.size = size
	mesh_inst.mesh = box_mesh
	mesh_inst.material_override = mat
	mesh_inst.position = pos
	mesh_inst.visible = false
	_npc.add_child(mesh_inst)
	return mesh_inst


func _create_taillight_mesh(mesh_name: String, pos: Vector3, size: Vector3) -> MeshInstance3D:
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.name = mesh_name
	var box_mesh = BoxMesh.new()
	box_mesh.size = size
	mesh_inst.mesh = box_mesh
	mesh_inst.material_override = _taillight_mat
	mesh_inst.position = pos
	mesh_inst.visible = false
	_npc.add_child(mesh_inst)
	return mesh_inst


func enable_lights() -> void:
	if _lights_enabled:
		return
	_lights_enabled = true

	if _use_split_lights:
		# Раздельные фары
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
	else:
		# Центральные фары
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

	if _use_split_lights:
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
	else:
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
	if _use_split_lights:
		if taillight_left:
			taillight_left.light_energy = energy
		if taillight_right:
			taillight_right.light_energy = energy
	else:
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
	# Раздельные фары
	if headlight_left and is_instance_valid(headlight_left):
		headlight_left.queue_free()
	if headlight_right and is_instance_valid(headlight_right):
		headlight_right.queue_free()
	if taillight_left and is_instance_valid(taillight_left):
		taillight_left.queue_free()
	if taillight_right and is_instance_valid(taillight_right):
		taillight_right.queue_free()
	if headlight_mesh_left and is_instance_valid(headlight_mesh_left):
		headlight_mesh_left.queue_free()
	if headlight_mesh_right and is_instance_valid(headlight_mesh_right):
		headlight_mesh_right.queue_free()
	if taillight_mesh_left and is_instance_valid(taillight_mesh_left):
		taillight_mesh_left.queue_free()
	if taillight_mesh_right and is_instance_valid(taillight_mesh_right):
		taillight_mesh_right.queue_free()
	# Центральные фары
	if headlight and is_instance_valid(headlight):
		headlight.queue_free()
	if taillight and is_instance_valid(taillight):
		taillight.queue_free()
	if headlight_mesh and is_instance_valid(headlight_mesh):
		headlight_mesh.queue_free()
	if taillight_mesh and is_instance_valid(taillight_mesh):
		taillight_mesh.queue_free()
	# Общие
	if reverse_light and is_instance_valid(reverse_light):
		reverse_light.queue_free()
	if reverse_mesh and is_instance_valid(reverse_mesh):
		reverse_mesh.queue_free()
