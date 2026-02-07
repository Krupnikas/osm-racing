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

	# Тестовое переопределение здания: way 45836637 (39 Северное шоссе) - кастомная текстура
	var building_override = BuildingOverrideScript.new()
	building_override.osm_way_id = 45836637
	building_override.wall_texture_path = "res://textures/buildings/111-125.jpg"
	building_override.texture_repeat_y = 4.0
	_building_overrides.append(building_override)

	# Окинина 8 (way 1408400824) - кастомная текстура, 1 повтор
	var okinina_override = BuildingOverrideScript.new()
	okinina_override.osm_way_id = 1408400824
	okinina_override.wall_texture_path = "res://textures/buildings/111-126.jpg"
	okinina_override.texture_repeat_y = 1.0
	_building_overrides.append(okinina_override)

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

	# 2. Щит (квад)
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
	board_mesh.position.y = billboard.pole_height + billboard.size.y / 2.0
	board_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(board_mesh)

	# 3. Текст (если есть)
	if billboard.text != "":
		var label := Label3D.new()
		label.text = billboard.text
		label.font_size = 128
		label.modulate = billboard.text_color
		label.pixel_size = 0.01
		label.position.y = billboard.pole_height + billboard.size.y / 2.0
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
		label_back.position.y = billboard.pole_height + billboard.size.y / 2.0
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
