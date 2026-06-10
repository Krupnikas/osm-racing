extends Node3D

## Скрипт для настройки модели Daewoo Matiz
## Скрывает колёса из модели (GEVP использует свои), изменяет цвет кузова,
## настраивает стёкла (день/ночь), фары/габариты, неон.
##
## Модель: Sketchfab GLTF, масштаб ~0.01 в иерархии
## Ключевые меши: car body (кузов), lights (фары/фонари),
## wheel LF/RF/LB/RB (колёса), hood, trunk, doors
##
## ВАЖНО: Модель Matiz имеет transform с инвертированными осями X и Z
## (аналогично Nexia). Передняя часть = отрицательный Z, задняя = положительный Z.

# Цвет кузова — жёлтый (классический цвет такси-Матиза)
var body_color := Color(0.95, 0.85, 0.15, 1.0)

# Цвета стёкол для дня и ночи
var glass_color_day := Color(0.12, 0.14, 0.2, 0.5)
var glass_color_night := Color(0.05, 0.07, 0.12, 1.0)

var _glass_materials: Array[StandardMaterial3D] = []
var _taillight_materials: Array[StandardMaterial3D] = []
var _brake_lights: Array[SpotLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _underglow_lights: Array[SpotLight3D] = []
var _underglow_material: StandardMaterial3D
var _underglow_enabled := false
var _underglow_color_index := 0
var _is_night := false
var _vehicle: Node
var _night_manager: Node

const UNDERGLOW_COLORS := [
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(0.8, 0.0, 1.0),   # Purple
	Color(1.0, 0.0, 0.5),   # Pink
	Color(0.0, 1.0, 0.3),   # Green
	Color(1.0, 0.5, 0.0),   # Orange
]


func _ready() -> void:
	_vehicle = get_parent()

	await get_tree().process_frame

	_change_body_color()
	_setup_gevp_wheels()
	_setup_taillights()
	_setup_headlights()
	_setup_underglow()
	_hide_misplaced_tuning_lights()

	print("Matiz model setup complete")


func _process(_delta: float) -> void:
	if not is_instance_valid(_night_manager):
		_night_manager = get_tree().current_scene.find_child("NightModeManager", true, false)
	if _night_manager and "is_night" in _night_manager:
		var current_night: bool = _night_manager.is_night
		if current_night != _is_night:
			_is_night = current_night
			_update_glass_materials()
			_update_headlights()
			_update_underglow_for_night()

	_update_taillight_brightness()


func _update_glass_materials() -> void:
	for material in _glass_materials:
		if not is_instance_valid(material):
			continue
		if _is_night:
			material.albedo_color = glass_color_night
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.metallic = 0.2
			material.metallic_specular = 0.8
			material.roughness = 0.1
			material.clearcoat = 0.9
			material.clearcoat_roughness = 0.05
		else:
			material.albedo_color = glass_color_day
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.metallic = 0.0
			material.metallic_specular = 0.5
			material.roughness = 0.05
			material.clearcoat = 0.0
			material.clearcoat_roughness = 0.0



func _setup_gevp_wheels() -> void:
	var vehicle = get_parent()
	if not vehicle.get("front_left_wheel"):
		return

	# Маппинг имён групп колёс GLTF → ноды GEVP wheel
	var wheel_map := {
		"wheel lf": vehicle.front_left_wheel.wheel_node,
		"wheel rf": vehicle.front_right_wheel.wheel_node,
		"wheel lb": vehicle.rear_left_wheel.wheel_node,
		"wheel rb": vehicle.rear_right_wheel.wheel_node,
	}

	for group_pattern in wheel_map:
		var wheel_node: Node3D = wheel_map[group_pattern]
		var group: Node3D = _find_wheel_group(self, group_pattern)
		if not group:
			print("Matiz: wheel group not found: ", group_pattern)
			continue

		print("Matiz: Found wheel group '", group.name, "' -> ", wheel_node.name)

		# Рекурсивно ищем все MeshInstance3D внутри группы колеса
		var all_group_meshes := _find_all_meshes(group)
		var meshes_to_reparent: Array[MeshInstance3D] = []

		for child in all_group_meshes:
			if child is MeshInstance3D:
				var cname: String = child.name.to_lower()
				if "tire" in cname or "rim" in cname:
					meshes_to_reparent.append(child)
				else:
					# Скрываем тормозные диски и прочее
					child.visible = false

		for mesh in meshes_to_reparent:
			# reparent сохраняет global_transform (keep_global_transform=true по умолчанию)
			mesh.reparent(wheel_node)
			# Центрируем на позиции колеса GEVP, basis сохраняет масштаб и ориентацию
			mesh.position = Vector3.ZERO
			# wheel_visibility.gd скрывает колёса до нас — принудительно показываем
			mesh.visible = true
			print("  -> Reparented '", mesh.name, "' to ", wheel_node.name, " basis=", mesh.transform.basis)

	print("Matiz: GEVP wheels setup with model meshes")


func _find_wheel_group(root: Node, pattern: String) -> Node3D:
	for child in root.get_children():
		if child is Node3D:
			var child_name: String = child.name.to_lower()
			if child_name == pattern or child_name.begins_with(pattern + " ") or child_name.begins_with(pattern + "_"):
				return child
			var found := _find_wheel_group(child, pattern)
			if found:
				return found
	return null


func _find_all_meshes(node: Node) -> Array:
	var meshes: Array = []
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))
	return meshes


## The Matiz GLB ships an emissive "tune light" underbody-neon strip baked ~2 m below the
## body — at night it glows UNDER THE GROUND ("headlights under the ground"). The car already
## gets proper headlights (_setup_headlights) and its own underglow (_setup_underglow), so this
## stray mesh is redundant; hide it. Matched by the model's surface name "tune light".
func _hide_misplaced_tuning_lights() -> void:
	for mesh in _find_all_meshes(self):
		if not (mesh is MeshInstance3D):
			continue
		if "tune light" in String(mesh.name).to_lower():
			(mesh as MeshInstance3D).visible = false
			print("Matiz: hid misplaced under-ground tuning-light mesh '%s'" % mesh.name)


func _change_body_color() -> void:
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Определяем тип детали
		var is_wheel: bool = "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name or "brakedisk" in mesh_name or "brake" in mesh_name
		var is_chrome: bool = "chrome" in mesh_name
		var is_interior: bool = "leather" in mesh_name or "interior" in mesh_name or "carbon" in mesh_name or "plastic_dark" in mesh_name
		var is_light: bool = "light" in mesh_name or "lamp" in mesh_name or "turn" in mesh_name or "signal" in mesh_name

		if is_wheel or is_chrome or is_interior or is_light:
			continue

		var surface_count: int = mesh.get_surface_override_material_count()
		if surface_count == 0 and mesh.mesh:
			surface_count = mesh.mesh.get_surface_count()

		for i in range(surface_count):
			var material: Material = mesh.get_surface_override_material(i)
			if not material and mesh.mesh:
				var original_mat: Material = mesh.mesh.surface_get_material(i)
				if original_mat:
					material = original_mat.duplicate()
					mesh.set_surface_override_material(i, material)

			if not material:
				continue

			var mat_name := ""
			if material.resource_name:
				mat_name = material.resource_name.to_lower()

			# Стёкла
			var is_glass_mat: bool = "windshield" in mat_name or "glass" in mat_name
			# Светотехника
			var is_light_mat: bool = "light" in mat_name or "lamp" in mat_name or "turn" in mat_name or "signal" in mat_name or "brake" in mat_name or "rear" in mat_name
			# Краска кузова
			var is_paint: bool = "car_paint" in mat_name or "paint" in mat_name

			if is_light_mat:
				continue

			if material is StandardMaterial3D:
				if is_glass_mat:
					# Стёкла — день/ночь переключение
					material.albedo_texture = null
					material.normal_texture = null
					material.albedo_color = glass_color_day
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
					material.metallic = 0.0
					material.metallic_specular = 0.5
					material.roughness = 0.05
					_glass_materials.append(material)
				elif is_paint:
					# Кузов — глянцевая жёлтая краска
					material.albedo_color = body_color
					material.metallic = 0.3
					material.metallic_specular = 0.8
					material.roughness = 0.15
					material.clearcoat = 0.9
					material.clearcoat_roughness = 0.1


func _setup_taillights() -> void:
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		if "rear_brake_light" in mesh_name or "rear_lamp" in mesh_name or "rear light glass" in mesh_name or "rear_light_glass" in mesh_name:
			_setup_taillight_material(mesh)

	# SpotLight3D стоп-сигналов (направлены назад, +Z в GEVP)
	var brake_positions := [
		Vector3(-0.45, 0.80, 1.55),
		Vector3(0.45, 0.80, 1.55),
	]

	for i in range(brake_positions.size()):
		var light := SpotLight3D.new()
		light.name = "BrakeLight_%d" % i
		light.position = brake_positions[i]
		light.rotation_degrees = Vector3(0, 180, 0)
		light.spot_range = 1.5
		light.spot_angle = 90.0
		light.light_energy = 0.3
		light.light_color = Color(1.0, 0.0, 0.0)
		light.shadow_enabled = false
		light.visible = true
		get_parent().add_child(light)
		_brake_lights.append(light)
		print("  -> Created brake SpotLight at ", brake_positions[i])


func _setup_taillight_material(mesh: MeshInstance3D) -> void:
	var surface_count: int = mesh.get_surface_override_material_count()
	if surface_count == 0 and mesh.mesh:
		surface_count = mesh.mesh.get_surface_count()

	for i in range(surface_count):
		var material: Material = mesh.get_surface_override_material(i)
		if not material and mesh.mesh:
			var original_mat: Material = mesh.mesh.surface_get_material(i)
			if original_mat:
				material = original_mat.duplicate()
				mesh.set_surface_override_material(i, material)

		if material is StandardMaterial3D:
			material.emission_enabled = true
			material.emission = Color(1.0, 0.1, 0.1)
			material.emission_energy_multiplier = 0.5
			_taillight_materials.append(material)
			print("  -> Added taillight material")


func _setup_headlights() -> void:
	# Находим и включаем emission на передних габаритах
	var meshes := _find_all_meshes(self)
	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue
		var mesh_name: String = mesh.name.to_lower()
		if "front_turn_signals" in mesh_name or "front turn signals" in mesh_name:
			_setup_front_marker_material(mesh)

	# SpotLight3D фар (направлены вперёд, -Z в GEVP)
	# Позиция чуть впереди бампера, чтобы тень от кузова не блокировала свет
	var headlight_positions := [
		Vector3(-0.45, 0.75, -1.30),
		Vector3(0.45, 0.75, -1.30),
	]

	for i in range(headlight_positions.size()):
		var light := SpotLight3D.new()
		light.name = "Headlight_%d" % i
		light.position = headlight_positions[i]
		light.rotation_degrees = Vector3(-5, 0, 0)  # Чуть вниз, как настоящие фары
		light.spot_range = 30.0
		light.spot_angle = 45.0
		light.light_energy = 3.0
		light.light_color = Color(1.0, 0.95, 0.8)
		light.shadow_enabled = false  # Без теней — иначе кузов блокирует свет
		light.visible = _is_night
		get_parent().add_child(light)
		_headlights.append(light)
		print("  -> Created headlight SpotLight at ", headlight_positions[i])


func _setup_front_marker_material(mesh: MeshInstance3D) -> void:
	var surface_count: int = mesh.get_surface_override_material_count()
	if surface_count == 0 and mesh.mesh:
		surface_count = mesh.mesh.get_surface_count()

	for i in range(surface_count):
		var material: Material = mesh.get_surface_override_material(i)
		if not material and mesh.mesh:
			var original_mat: Material = mesh.mesh.surface_get_material(i)
			if original_mat:
				material = original_mat.duplicate()
				mesh.set_surface_override_material(i, material)

		if material is StandardMaterial3D:
			material.emission_enabled = true
			material.emission = Color(1.0, 0.6, 0.1)
			material.emission_energy_multiplier = 0.5
			print("  -> Added front marker material")


func _update_taillight_brightness() -> void:
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1

	for material in _taillight_materials:
		if is_instance_valid(material):
			material.emission_energy_multiplier = 2.0 if braking else 0.5

	for light in _brake_lights:
		if is_instance_valid(light):
			light.light_energy = 2.0 if braking else 0.3


func _update_headlights() -> void:
	print("Matiz _update_headlights: _is_night=", _is_night, " headlights_count=", _headlights.size())
	for light in _headlights:
		if is_instance_valid(light):
			light.visible = _is_night
			print("  headlight ", light.name, " visible=", light.visible, " pos=", light.position)


func _setup_underglow() -> void:
	var color := UNDERGLOW_COLORS[0]

	_underglow_material = StandardMaterial3D.new()
	_underglow_material.albedo_color = color
	_underglow_material.emission_enabled = true
	_underglow_material.emission = color
	_underglow_material.emission_energy_multiplier = 0.5

	# 4 с каждой стороны (между колёсами)
	var left_positions: Array[Vector3] = []
	var right_positions: Array[Vector3] = []
	for i in range(4):
		var z: float = 0.6 - (i * 0.4)
		left_positions.append(Vector3(-0.55, 0.30, z))
		right_positions.append(Vector3(0.55, 0.30, z))

	# 2 под задним бампером
	var rear_positions: Array[Vector3] = []
	for i in range(2):
		var x: float = -0.25 + (i * 0.5)
		rear_positions.append(Vector3(x, 0.30, 1.3))

	# 2 под передним бампером
	var front_positions: Array[Vector3] = []
	for i in range(2):
		var x: float = -0.25 + (i * 0.5)
		front_positions.append(Vector3(x, 0.25, -1.3))

	# Боковые (угол 60)
	for i in range(left_positions.size()):
		_add_underglow_light(left_positions[i], color, 60.0)
	for i in range(right_positions.size()):
		_add_underglow_light(right_positions[i], color, 60.0)

	# Задние (угол 70)
	for pos in rear_positions:
		_add_underglow_light(pos, color, 70.0)

	# Передние (угол 90)
	for pos in front_positions:
		_add_underglow_light(pos, color, 90.0)

	print("  -> Created underglow with %d lights" % _underglow_lights.size())


func _add_underglow_light(pos: Vector3, color: Color, angle: float) -> void:
	var light := SpotLight3D.new()
	light.name = "Underglow_%d" % _underglow_lights.size()
	light.position = pos
	light.rotation_degrees = Vector3(-90, 0, 0)
	light.spot_range = 1.0
	light.spot_angle = angle
	light.light_energy = 0.05
	light.spot_attenuation = 2.0
	light.light_volumetric_fog_energy = 0.5
	light.light_color = color
	light.shadow_enabled = true
	light.visible = _underglow_enabled
	get_parent().add_child(light)
	_underglow_lights.append(light)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			_toggle_underglow()


func _update_underglow_for_night() -> void:
	_underglow_enabled = _is_night
	for light in _underglow_lights:
		if is_instance_valid(light):
			light.visible = _underglow_enabled


func _toggle_underglow() -> void:
	_underglow_enabled = not _underglow_enabled

	if _underglow_enabled:
		_underglow_color_index = (_underglow_color_index + 1) % UNDERGLOW_COLORS.size()
		var new_color: Color = UNDERGLOW_COLORS[_underglow_color_index]

		for light in _underglow_lights:
			if is_instance_valid(light):
				light.light_color = new_color

		if _underglow_material:
			_underglow_material.albedo_color = new_color
			_underglow_material.emission = new_color

	for light in _underglow_lights:
		if is_instance_valid(light):
			light.visible = _underglow_enabled

	print("Underglow: ", "ON (color %d)" % _underglow_color_index if _underglow_enabled else "OFF")
