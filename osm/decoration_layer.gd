class_name DecorationLayer
extends Node

## Procedural Decoration Layer
## Добавляет декорации поверх OSM данных: билборды, переопределения зданий и т.д.

const BillboardDecorationScript = preload("res://osm/decorations/billboard_decoration.gd")
const BuildingOverrideScript = preload("res://osm/decorations/building_override.gd")

# Ссылка на terrain generator для доступа к start_lat/lon
var _terrain_generator: Node = null

# Загруженные декорации
var _billboards: Array = []  # Array[BillboardDecoration]
var _building_overrides: Array = []  # Array[BuildingOverride]

# Spatial index для быстрого поиска
var _billboard_spatial_hash: Dictionary = {}  # cell_key -> Array[int] (индексы)
var _building_override_by_way_id: Dictionary = {}  # way_id -> BuildingOverride
const CELL_SIZE := 100.0  # Размер ячейки пространственного индекса


func _ready() -> void:
	# Загружаем тестовые декорации
	_load_test_decorations()
	_build_spatial_index()


func _load_test_decorations() -> void:
	"""Загружает тестовые декорации (позже заменим на .tres файлы)"""

	# Тестовый билборд "РЕКЛАМА" на точке 59.149878, 37.948709
	var billboard = BillboardDecorationScript.new()
	billboard.lat = 59.149878
	billboard.lon = 37.948709
	billboard.use_latlon = true
	billboard.text = "РЕКЛАМА"
	billboard.size = Vector2(5.0, 2.5)
	billboard.pole_height = 4.0
	billboard.background_color = Color(0.1, 0.3, 0.7)  # Синий фон
	billboard.text_color = Color.WHITE
	billboard.has_backlight = true
	billboard.rotation_y = 0.0  # Повернём позже к дороге
	_billboards.append(billboard)

	# Билборд МВидео / Лада на 59.14986, 37.952547
	var billboard_mvideo = BillboardDecorationScript.new()
	billboard_mvideo.lat = 59.14986
	billboard_mvideo.lon = 37.952547
	billboard_mvideo.use_latlon = true
	billboard_mvideo.texture_path = "res://textures/billboards/mvideo-banner.jpg"
	billboard_mvideo.texture_path_back = "res://textures/billboards/lada-banner.jpg"
	billboard_mvideo.size = Vector2(6.0, 3.35)  # Среднее от пропорций обоих баннеров
	billboard_mvideo.pole_height = 4.0
	billboard_mvideo.has_backlight = true
	billboard_mvideo.emission_strength = 0.3
	billboard_mvideo.rotation_y = -PI / 2.0  # 90° по часовой
	_billboards.append(billboard_mvideo)

	# Тестовое переопределение здания: way 45836637 (39 Северное шоссе) - кастомная текстура
	var building_override = BuildingOverrideScript.new()
	building_override.osm_way_id = 45836637
	building_override.wall_texture_path = "res://textures/buildings/111-125.png"
	building_override.wall_emissive_path = "res://textures/buildings/111-125_emissive_mask.png"
	building_override.texture_repeat_y = 2.0
	building_override.use_adaptive_repeat = true  # Адаптивный режим
	building_override.texture_repeat_short = 1.0  # 1 повтор на коротких стенах
	building_override.texture_repeat_long = 3.0   # 3 повтора на длинных стенах
	_building_overrides.append(building_override)

	# 37 Северное шоссе (way 45836638)
	var override_37 = BuildingOverrideScript.new()
	override_37.osm_way_id = 45836638
	override_37.wall_texture_path = "res://textures/buildings/111-125.png"
	override_37.wall_emissive_path = "res://textures/buildings/111-125_emissive_mask.png"
	override_37.texture_repeat_y = 2.0
	override_37.use_adaptive_repeat = true
	override_37.texture_repeat_short = 1.0
	override_37.texture_repeat_long = 3.0
	_building_overrides.append(override_37)

	# 35 Северное шоссе (way 45836639)
	var override_35 = BuildingOverrideScript.new()
	override_35.osm_way_id = 45836639
	override_35.wall_texture_path = "res://textures/buildings/111-125.png"
	override_35.wall_emissive_path = "res://textures/buildings/111-125_emissive_mask.png"
	override_35.texture_repeat_y = 2.0
	override_35.use_adaptive_repeat = true
	override_35.texture_repeat_short = 1.0
	override_35.texture_repeat_long = 3.0
	_building_overrides.append(override_35)

	# Окинина 8 (way 1408400824) - кастомная текстура, 1 повтор
	var okinina_override = BuildingOverrideScript.new()
	okinina_override.osm_way_id = 1408400824
	okinina_override.wall_texture_path = "res://textures/buildings/111-126.jpg"
	okinina_override.texture_repeat_y = 1.0
	_building_overrides.append(okinina_override)

	# Химико-технологический колледж (way 45747168)
	var ptu_override = BuildingOverrideScript.new()
	ptu_override.osm_way_id = 45747168
	ptu_override.wall_texture_path = "res://textures/buildings/ptu.png"
	ptu_override.texture_repeat_y = 1.0
	_building_overrides.append(ptu_override)

	print("DecorationLayer: Loaded %d billboards, %d building overrides" % [
		_billboards.size(), _building_overrides.size()
	])


func _build_spatial_index() -> void:
	"""Строит пространственный индекс для быстрого поиска"""
	_billboard_spatial_hash.clear()
	_building_override_by_way_id.clear()

	# Индекс building overrides по way_id
	for override in _building_overrides:
		if override.osm_way_id > 0:
			_building_override_by_way_id[override.osm_way_id] = override


func set_terrain_generator(generator: Node) -> void:
	"""Устанавливает ссылку на terrain generator"""
	_terrain_generator = generator


func get_building_override_for_way(way_id: int):
	"""Возвращает переопределение для здания по OSM way ID"""
	return _building_override_by_way_id.get(way_id, null)


func get_billboards_in_chunk(chunk_min: Vector2, chunk_max: Vector2) -> Array:
	"""Возвращает билборды в указанных границах чанка (локальные координаты)"""
	var result: Array = []

	if not _terrain_generator:
		return result

	var start_lat: float = _terrain_generator.start_lat
	var start_lon: float = _terrain_generator.start_lon

	for billboard in _billboards:
		var pos: Vector2 = billboard.get_local_position(start_lat, start_lon)
		if pos.x >= chunk_min.x and pos.x <= chunk_max.x and \
		   pos.y >= chunk_min.y and pos.y <= chunk_max.y:
			result.append(billboard)

	return result


func create_billboard_mesh(billboard, elevation: float) -> Node3D:
	"""Создаёт 3D меш билборда"""
	var root := Node3D.new()
	root.name = "Billboard"

	if not _terrain_generator:
		return root

	var start_lat: float = _terrain_generator.start_lat
	var start_lon: float = _terrain_generator.start_lon
	var pos: Vector2 = billboard.get_local_position(start_lat, start_lon)

	# Позиционируем
	root.position = Vector3(pos.x, elevation, pos.y)
	root.rotation.y = billboard.rotation_y

	# 1. Столб
	var pole_mesh := MeshInstance3D.new()
	var pole := CylinderMesh.new()
	pole.top_radius = 0.08
	pole.bottom_radius = 0.12
	pole.height = billboard.pole_height
	pole_mesh.mesh = pole

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.3, 0.3, 0.35)
	pole_mat.metallic = 0.7
	pole_mat.roughness = 0.4
	pole_mesh.material_override = pole_mat
	pole_mesh.position.y = billboard.pole_height / 2.0
	root.add_child(pole_mesh)

	# 1.5. Металлическая рамка вокруг щита
	var frame_thickness := 0.06  # Толщина рамки
	var frame_depth := 0.12  # Глубина рамки (чтобы охватить обе стороны)
	var frame_y: float = billboard.pole_height + billboard.size.y / 2.0

	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.35, 0.35, 0.4)
	frame_mat.metallic = 0.8
	frame_mat.roughness = 0.35

	# Верхняя планка
	var top_bar := MeshInstance3D.new()
	var top_box := BoxMesh.new()
	top_box.size = Vector3(billboard.size.x + frame_thickness * 2, frame_thickness, frame_depth)
	top_bar.mesh = top_box
	top_bar.material_override = frame_mat
	top_bar.position = Vector3(0, frame_y + billboard.size.y / 2.0 + frame_thickness / 2.0, 0)
	top_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(top_bar)

	# Нижняя планка
	var bottom_bar := MeshInstance3D.new()
	var bottom_box := BoxMesh.new()
	bottom_box.size = Vector3(billboard.size.x + frame_thickness * 2, frame_thickness, frame_depth)
	bottom_bar.mesh = bottom_box
	bottom_bar.material_override = frame_mat
	bottom_bar.position = Vector3(0, frame_y - billboard.size.y / 2.0 - frame_thickness / 2.0, 0)
	bottom_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(bottom_bar)

	# Левая планка
	var left_bar := MeshInstance3D.new()
	var left_box := BoxMesh.new()
	left_box.size = Vector3(frame_thickness, billboard.size.y, frame_depth)
	left_bar.mesh = left_box
	left_bar.material_override = frame_mat
	left_bar.position = Vector3(-billboard.size.x / 2.0 - frame_thickness / 2.0, frame_y, 0)
	left_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(left_bar)

	# Правая планка
	var right_bar := MeshInstance3D.new()
	var right_box := BoxMesh.new()
	right_box.size = Vector3(frame_thickness, billboard.size.y, frame_depth)
	right_bar.mesh = right_box
	right_bar.material_override = frame_mat
	right_bar.position = Vector3(billboard.size.x / 2.0 + frame_thickness / 2.0, frame_y, 0)
	right_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(right_bar)

	# 2. Щит - две стороны с возможно разными текстурами
	var board_y: float = billboard.pole_height + billboard.size.y / 2.0
	var has_front_texture: bool = billboard.texture_path != ""
	var has_back_texture: bool = billboard.texture_path_back != ""

	if has_front_texture or has_back_texture:
		# Режим с текстурами - два QuadMesh
		# Передняя сторона
		var front_mesh := MeshInstance3D.new()
		var front_quad := QuadMesh.new()
		front_quad.size = Vector2(billboard.size.x, billboard.size.y)
		front_mesh.mesh = front_quad

		var front_mat := StandardMaterial3D.new()
		if has_front_texture:
			var front_tex := load(billboard.texture_path) as Texture2D
			if front_tex:
				front_mat.albedo_texture = front_tex
		else:
			front_mat.albedo_color = billboard.background_color

		if billboard.has_backlight:
			front_mat.emission_enabled = true
			if has_front_texture:
				var front_tex := load(billboard.texture_path) as Texture2D
				if front_tex:
					front_mat.emission_texture = front_tex
			front_mat.emission_energy_multiplier = billboard.emission_strength

		front_mesh.material_override = front_mat
		front_mesh.position.y = board_y
		front_mesh.position.z = 0.05
		front_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(front_mesh)

		# Задняя сторона
		var back_mesh := MeshInstance3D.new()
		var back_quad := QuadMesh.new()
		back_quad.size = Vector2(billboard.size.x, billboard.size.y)
		back_mesh.mesh = back_quad

		var back_mat := StandardMaterial3D.new()
		var back_tex_path: String = billboard.texture_path_back if has_back_texture else billboard.texture_path
		if back_tex_path != "":
			var back_tex := load(back_tex_path) as Texture2D
			if back_tex:
				back_mat.albedo_texture = back_tex
		else:
			back_mat.albedo_color = billboard.background_color

		if billboard.has_backlight:
			back_mat.emission_enabled = true
			if back_tex_path != "":
				var back_tex := load(back_tex_path) as Texture2D
				if back_tex:
					back_mat.emission_texture = back_tex
			back_mat.emission_energy_multiplier = billboard.emission_strength

		back_mesh.material_override = back_mat
		back_mesh.position.y = board_y
		back_mesh.position.z = -0.05
		back_mesh.rotation.y = PI
		back_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(back_mesh)
	else:
		# Режим без текстур - BoxMesh
		var board_mesh := MeshInstance3D.new()
		var board := BoxMesh.new()
		board.size = Vector3(billboard.size.x, billboard.size.y, 0.1)
		board_mesh.mesh = board

		var board_mat := StandardMaterial3D.new()
		board_mat.albedo_color = billboard.background_color

		if billboard.has_backlight:
			board_mat.emission_enabled = true
			board_mat.emission = billboard.background_color
			board_mat.emission_energy_multiplier = billboard.emission_strength

		board_mesh.material_override = board_mat
		board_mesh.position.y = board_y
		board_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(board_mesh)

	# 3. Текст (если есть и нет текстур)
	if billboard.text != "" and not has_front_texture:
		var label := Label3D.new()
		label.text = billboard.text
		label.font_size = 128
		label.modulate = billboard.text_color
		label.pixel_size = 0.01
		label.position.y = board_y
		label.position.z = 0.06
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label.no_depth_test = false
		root.add_child(label)

		# Текст с обратной стороны
		var label_back := Label3D.new()
		label_back.text = billboard.text
		label_back.font_size = 128
		label_back.modulate = billboard.text_color
		label_back.pixel_size = 0.01
		label_back.position.y = board_y
		label_back.position.z = -0.06
		label_back.rotation.y = PI
		label_back.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label_back.no_depth_test = false
		root.add_child(label_back)

	# LOD - устанавливаем на дочерние MeshInstance3D
	for child in root.get_children():
		if child is GeometryInstance3D:
			child.visibility_range_end = 300.0
			child.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	return root
