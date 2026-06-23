class_name DecorationLayer
extends Node

## Procedural Decoration Layer
## Добавляет декорации поверх OSM данных: билборды, переопределения зданий и т.д.

const BillboardDecorationScript = preload("res://osm/decorations/billboard_decoration.gd")
const BuildingOverrideScript = preload("res://osm/decorations/building_override.gd")

const DECORATIONS_PATH := "res://decorations/"
const INDEX_FILE := "index.json"

# Ссылка на terrain generator для доступа к start_lat/lon
var _terrain_generator: Node = null

# Загруженные декорации
var _billboards: Array = []  # Array[BillboardDecoration]
var _building_overrides: Array = []  # Array[BuildingOverride]
var _landuse_tree_overrides: Dictionary = {}  # way_id -> {dense: bool}
var _custom_models: Array = []  # Array of {model, lat, lon, rotation_y, scale}
var _roadside_props: Array = []  # Array of {type, lat, lon, rotation_y, variant} (manual kiosk/box)
var _market_stands: Array = []  # Array of {lat, lon, yaw, stand_count, spacing, scale} (manual)

# Spatial index для быстрого поиска
var _billboard_spatial_hash: Dictionary = {}  # cell_key -> Array[int] (индексы)
var _building_override_by_way_id: Dictionary = {}  # way_id -> BuildingOverride
const CELL_SIZE := 100.0  # Размер ячейки пространственного индекса

# Настройки из index.json
var _texture_base_path: String = "res://textures/"


func _ready() -> void:
	_load_decorations_from_json()
	_build_spatial_index()


func _load_decorations_from_json() -> void:
	"""Загружает декорации из JSON файлов"""
	var index_path := DECORATIONS_PATH + INDEX_FILE

	if not FileAccess.file_exists(index_path):
		push_warning("DecorationLayer: index.json not found at " + index_path)
		return

	var index_data := _load_json(index_path)
	if index_data.is_empty():
		return

	# Сохраняем базовый путь для текстур
	if index_data.has("texture_base_path"):
		_texture_base_path = index_data["texture_base_path"]

	# Загружаем каждый включённый источник
	var sources: Array = index_data.get("sources", [])
	for source in sources:
		if not source.get("enabled", true):
			continue

		var source_path: String = DECORATIONS_PATH + source.get("path", "")
		_load_city_decorations(source_path, source.get("id", "unknown"))

	print("DecorationLayer: Loaded %d billboards, %d building overrides, %d custom models from JSON" % [
		_billboards.size(), _building_overrides.size(), _custom_models.size()
	])


func _load_city_decorations(city_path: String, city_id: String) -> void:
	"""Загружает декорации для конкретного города"""
	var meta_path := city_path + "meta.json"

	if not FileAccess.file_exists(meta_path):
		push_warning("DecorationLayer: meta.json not found for " + city_id)
		return

	var meta := _load_json(meta_path)
	if meta.is_empty():
		return

	# Загружаем файлы, указанные в meta.json
	var files: Array = meta.get("files", [])
	for file_name in files:
		var file_path: String = city_path + file_name
		if file_name.ends_with("billboards.json"):
			_load_billboards_json(file_path)
		elif file_name.ends_with("building_overrides.json"):
			_load_building_overrides_json(file_path)


func _load_billboards_json(path: String) -> void:
	"""Загружает билборды из JSON файла"""
	var data := _load_json(path)
	if data.is_empty():
		return

	var billboards_data: Array = data.get("billboards", [])
	for bd in billboards_data:
		var billboard = BillboardDecorationScript.new()

		billboard.lat = bd.get("lat", 0.0)
		billboard.lon = bd.get("lon", 0.0)
		billboard.use_latlon = true

		# Размеры
		var size_arr: Array = bd.get("size", [4.0, 3.0])
		billboard.size = Vector2(size_arr[0], size_arr[1])
		billboard.pole_height = bd.get("pole_height", 3.0)

		# Поворот (градусы -> радианы)
		billboard.rotation_y = deg_to_rad(bd.get("rotation_deg", 0.0))

		# Текстуры
		if bd.has("texture"):
			billboard.texture_path = _texture_base_path + bd["texture"]
		if bd.has("texture_back"):
			billboard.texture_path_back = _texture_base_path + bd["texture_back"]

		# Текст
		billboard.text = bd.get("text", "")

		# Цвета (из hex строки)
		if bd.has("background"):
			billboard.background_color = Color.html(bd["background"])
		if bd.has("text_color"):
			billboard.text_color = Color.html(bd["text_color"])

		# Освещение
		billboard.has_backlight = bd.get("backlight", true)
		billboard.emission_strength = bd.get("emission", 0.5)

		_billboards.append(billboard)


func _load_building_overrides_json(path: String) -> void:
	"""Загружает переопределения зданий из JSON файла"""
	var data := _load_json(path)
	if data.is_empty():
		return

	var overrides_data: Array = data.get("building_overrides", [])
	for od in overrides_data:
		var override = BuildingOverrideScript.new()

		override.osm_way_id = od.get("osm_way_id", 0)
		override.facade_group = od.get("facade_group", "")

		# Текстуры
		if od.has("wall_texture"):
			override.wall_texture_path = _texture_base_path + od["wall_texture"]
		if od.has("wall_emissive"):
			override.wall_emissive_path = _texture_base_path + od["wall_emissive"]

		# Высота здания
		override.height_override = od.get("height_override", -1.0)

		# Повторение текстуры
		override.texture_repeat_y = od.get("repeat_y", 1.0)
		override.texture_repeat_x = od.get("repeat_x", 0.0)
		override.texture_offset_x = od.get("offset_x", 0.0)

		# Адаптивное повторение
		if od.has("adaptive_repeat"):
			var ar: Dictionary = od["adaptive_repeat"]
			override.use_adaptive_repeat = ar.get("enabled", false)
			override.texture_repeat_short = ar.get("short", 1.0)
			override.texture_repeat_long = ar.get("long", 3.0)

		# Материал здания (wood, brick и т.д.)
		if od.has("building_material"):
			override.building_material = od["building_material"]

		# Тип крыши (hip, gable)
		if od.has("roof_type"):
			override.roof_type = od["roof_type"]
		if od.has("ridge_height"):
			override.ridge_height = od["ridge_height"]
		if od.has("gable_color"):
			var gc: Array = od["gable_color"]
			if gc.size() >= 3:
				override.gable_color = Color(gc[0], gc[1], gc[2])

		# Входные группы подъездов
		if od.has("entrances"):
			override.entrances = od["entrances"]

		# Входные группы магазинов
		if od.has("shop_entrances"):
			override.shop_entrances = od["shop_entrances"]

		# POI nodes to skip
		if od.has("skip_pois"):
			override.skip_pois = od["skip_pois"]

		# Custom entrance groups (МАРС и т.д.)
		if od.has("custom_entrances"):
			override.custom_entrances = od["custom_entrances"]

		# Skip all auto-generated POI signs
		if od.has("skip_all_pois"):
			override.skip_all_pois = od["skip_all_pois"]
		if od.has("no_foundation"):
			override.no_foundation = od["no_foundation"]

		# Roof-mounted signs
		if od.has("roof_signs"):
			override.roof_signs = od["roof_signs"]
		if od.has("wall_signs"):
			override.wall_signs = od["wall_signs"]

		# Pediments (надстройки-фронтоны)
		if od.has("pediments"):
			override.pediments = od["pediments"]

		# Per-slot extrusion config (balcony box geometry)
		if od.has("slot_extrusion"):
			override.slot_extrusion = od["slot_extrusion"]

		# Custom 3D model (replaces entire building)
		if od.has("custom_model"):
			override.custom_model_path = od["custom_model"]
			override.custom_model_scale = od.get("custom_model_scale", 1.0)
			override.custom_model_rotation_y = od.get("custom_model_rotation_y", 0.0)
			override.custom_model_y_offset = od.get("custom_model_y_offset", 0.0)
			override.custom_model_visibility_range = od.get("custom_model_visibility_range", 500.0)

		_building_overrides.append(override)

	# Custom models (гаражи, веранды и т.д. по координатам)
	var models_data: Array = data.get("custom_models", [])
	for md in models_data:
		_custom_models.append({
			"model": md.get("model", ""),
			"lat": md.get("lat", 0.0),
			"lon": md.get("lon", 0.0),
			"rotation_y": md.get("rotation_y", 0.0),
			"scale": md.get("scale", 1.0),
			"y_offset": md.get("y_offset", 0.0),
			"visibility_range": md.get("visibility_range", 150.0),
			"clear_trees_radius": md.get("clear_trees_radius", 0.0),
			# Optional extras (bazar gate & co): box collision, per-half signs, real-vertex grounding
			"collision": md.get("collision", ""),  # "" | "box"
			"signs": md.get("signs", []),  # [{texture, side:"left"|"right"}]
			"auto_ground": md.get("auto_ground", false)
		})

	# Manual roadside props (kiosk/ebox) by coordinate — auto-grounded by the prop system
	var props_data: Array = data.get("roadside_props", [])
	for pd in props_data:
		_roadside_props.append({
			"type": pd.get("type", "kiosk"),
			"lat": pd.get("lat", 0.0),
			"lon": pd.get("lon", 0.0),
			"rotation_y": pd.get("rotation_y", 0.0),
			"variant": pd.get("variant", -1),  # -1 = auto by hash
		})

	# Market watermelon stands — EXACT manual placement only; anchor authoritative, no relocation.
	var stands_data: Array = data.get("market_stands", [])
	for sd in stands_data:
		_market_stands.append({
			"lat": sd.get("lat", 0.0),
			"lon": sd.get("lon", 0.0),
			"yaw": sd.get("yaw", 256.0),
			"stand_count": sd.get("stand_count", 2),
			"spacing": sd.get("spacing", 1.6),
			"scale": sd.get("scale", 1.0),
		})

	# Landuse overrides (деревья на конкретных landuse зонах)
	var landuse_data: Array = data.get("landuse_overrides", [])
	for lo in landuse_data:
		var wid: int = lo.get("osm_way_id", 0)
		if wid > 0 and lo.get("trees", false):
			_landuse_tree_overrides[wid] = {
				"dense": lo.get("dense", false)
			}


func _load_json(path: String) -> Dictionary:
	"""Загружает и парсит JSON файл"""
	if not FileAccess.file_exists(path):
		push_warning("DecorationLayer: File not found: " + path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("DecorationLayer: Cannot open file: " + path)
		return {}

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var error := json.parse(json_text)
	if error != OK:
		push_error("DecorationLayer: JSON parse error in %s at line %d: %s" % [
			path, json.get_error_line(), json.get_error_message()
		])
		return {}

	return json.data


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


func get_landuse_tree_override(way_id: int):
	"""Возвращает оверрайд деревьев для landuse зоны по OSM way ID"""
	return _landuse_tree_overrides.get(way_id, null)


func get_custom_models() -> Array:
	return _custom_models

func get_roadside_props() -> Array:
	return _roadside_props

func get_market_stands() -> Array:
	return _market_stands


func get_billboards_in_chunk(chunk_min: Vector2, chunk_max: Vector2) -> Array:
	"""Возвращает билборды в указанных границах чанка (локальные координаты)"""
	var result: Array = []

	if not _terrain_generator:
		return result

	var start_lat: float = _terrain_generator.start_lat
	var start_lon: float = _terrain_generator.start_lon
	var wo: Vector2 = _terrain_generator._world_offset if "_world_offset" in _terrain_generator else Vector2.ZERO

	for billboard in _billboards:
		var pos: Vector2 = billboard.get_local_position(start_lat, start_lon) - wo
		if pos.x >= chunk_min.x and pos.x <= chunk_max.x and \
		   pos.y >= chunk_min.y and pos.y <= chunk_max.y:
			result.append(billboard)

	return result


func create_road_billboard_mesh(world_x: float, world_z: float, elevation: float, yaw: float, tex_front: String, tex_back: String) -> Node3D:
	"""Procedural roadside billboard: two-sided, externally top-lit (night-only),
	no self-emission. Position/rotation are world-space (set after build)."""
	var deco = BillboardDecorationScript.new()
	deco.use_latlon = false
	deco.local_position = Vector2.ZERO
	deco.rotation_y = 0.0
	deco.size = Vector2(6.0, 3.0)
	deco.pole_height = 4.5
	deco.has_backlight = false  # NO self-emission — lit by the top lamp instead
	deco.texture_path = tex_front
	deco.texture_path_back = tex_back
	var root := create_billboard_mesh(deco, elevation, true)
	root.position = Vector3(world_x, elevation, world_z)
	root.rotation.y = yaw
	# Collision: pole cylinder (so cars can't drive through it). StaticBody3D defaults
	# to collision_layer 1 — same world layer lamp poles use.
	var col := StaticBody3D.new()
	col.name = "BillboardCol"
	var cshape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.22
	cyl.height = deco.pole_height
	cshape.shape = cyl
	cshape.position.y = deco.pole_height / 2.0
	col.add_child(cshape)
	root.add_child(col)
	# Visibility: a big roadside board should be visible as soon as its chunk loads
	# (the builder defaults to 300 m, which pops in "at the last moment"). Fade for smoothness.
	for child in root.get_children():
		if child is GeometryInstance3D:
			child.visibility_range_end = 600.0
			child.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return root


func create_billboard_mesh(billboard, elevation: float, with_top_lamp: bool = false) -> Node3D:
	"""Создаёт 3D меш билборда"""
	var root := Node3D.new()
	root.name = "Billboard"

	if not _terrain_generator:
		return root

	var start_lat: float = _terrain_generator.start_lat
	var start_lon: float = _terrain_generator.start_lon
	var wo: Vector2 = _terrain_generator._world_offset if "_world_offset" in _terrain_generator else Vector2.ZERO
	var pos: Vector2 = billboard.get_local_position(start_lat, start_lon) - wo

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

	# 1.6. Внешний верхний светильник (только для процедурных билбордов).
	# Простой провинциальный плафон сверху по центру, светит вниз на щит.
	# Свет включается только ночью через _recursive_update_lights (имя "LampLight").
	if with_top_lamp:
		var frame_top_y: float = frame_y + billboard.size.y / 2.0 + frame_thickness  # top surface of the frame
		var fix_mat := StandardMaterial3D.new()
		fix_mat.albedo_color = Color(0.2, 0.2, 0.22)
		fix_mat.metallic = 0.6
		fix_mat.roughness = 0.5
		# Кронштейн: короткая стойка ОТ верха рамки — никакого зазора, светильник прикреплён
		var bracket := MeshInstance3D.new()
		var brbox := BoxMesh.new()
		brbox.size = Vector3(0.09, 0.36, 0.09)
		bracket.mesh = brbox
		bracket.material_override = fix_mat
		bracket.position = Vector3(0, frame_top_y + 0.18, 0.0)  # bottom touches the frame top
		bracket.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(bracket)
		# Корпус-плафон на верхушке кронштейна (перекрывает её — без зазора)
		var lamp_top_y: float = frame_top_y + 0.36
		var housing := MeshInstance3D.new()
		var hbox := BoxMesh.new()
		hbox.size = Vector3(minf(billboard.size.x * 0.5, 1.6), 0.14, 0.42)
		housing.mesh = hbox
		housing.material_override = fix_mat
		housing.position = Vector3(0, lamp_top_y, 0.08)
		housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(housing)
		# Ночной прожектор: короткий радиус, без теней, distance-fade
		var lamp := SpotLight3D.new()
		lamp.name = "LampLight"  # toggled by OSMTerrain._recursive_update_lights
		lamp.position = Vector3(0, lamp_top_y - 0.08, 0.08)
		lamp.rotation_degrees = Vector3(-90, 0, 0)  # straight down onto the board
		lamp.spot_range = billboard.size.y + 3.5
		lamp.spot_angle = 62.0
		lamp.spot_attenuation = 1.2
		lamp.light_energy = 3.0
		lamp.light_color = Color(1.0, 0.93, 0.78)
		lamp.shadow_enabled = false
		lamp.light_bake_mode = Light3D.BAKE_DISABLED
		lamp.distance_fade_enabled = true
		lamp.distance_fade_begin = 75.0
		lamp.distance_fade_length = 25.0
		lamp.set_meta("is_broken", false)
		lamp.visible = false  # night-mode enables it (OSMTerrain sets initial state)
		root.add_child(lamp)

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
