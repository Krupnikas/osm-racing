extends Node
class_name TextureManager

# Синглтон для управления текстурами
# Кэширует сгенерированные текстуры для переиспользования

const TextureGeneratorScript = preload("res://textures/texture_generator.gd")

# Кэш текстур
var _textures: Dictionary = {}

# Кэш normal maps
var _normals: Dictionary = {}

# Кэш материалов
var _materials: Dictionary = {}

# Ссылка на настройки графики
var _graphics_settings: Node

func _ready() -> void:
	# Предгенерируем основные текстуры при старте
	_pregenerate_textures()
	# Ищем настройки графики
	await get_tree().process_frame
	_graphics_settings = get_tree().current_scene.find_child("GraphicsSettings", true, false)


func _are_normal_maps_enabled() -> bool:
	# Всегда возвращаем true при создании материалов
	# Normal maps будут созданы, но их влияние контролируется через normal_scale
	return true

func _pregenerate_textures() -> void:
	print("TextureManager: Pregenerating textures...")
	var start_time := Time.get_ticks_msec()

	# Дороги
	_textures["road_primary"] = TextureGeneratorScript.create_highway_texture(512, 4)
	_textures["road_secondary"] = TextureGeneratorScript.create_road_texture(256, 2, true, true)
	_textures["road_residential"] = TextureGeneratorScript.create_road_texture(256, 2, true, false)
	_textures["road_path"] = TextureGeneratorScript.create_sidewalk_texture(256)

	# Здания
	_textures["building_panel"] = TextureGeneratorScript.create_panel_building_texture(512, 5, 4)
	_textures["building_brick"] = TextureGeneratorScript.create_brick_building_texture(512, 4, 3)
	_textures["building_wall"] = TextureGeneratorScript.create_wall_texture(256)
	_textures["building_roof"] = TextureGeneratorScript.create_roof_texture(256)

	# Природа
	_textures["grass"] = TextureGeneratorScript.create_grass_texture(256)
	_textures["forest"] = TextureGeneratorScript.create_forest_texture(256)
	_textures["dirt"] = TextureGeneratorScript.create_dirt_texture(256)
	_textures["water"] = TextureGeneratorScript.create_water_texture(256)

	# Прочее
	_textures["concrete"] = TextureGeneratorScript.create_concrete_texture(256)
	_textures["asphalt"] = TextureGeneratorScript.create_asphalt_texture(256)

	# Normal maps
	print("TextureManager: Generating normal maps...")
	_normals["asphalt"] = TextureGeneratorScript.create_asphalt_normal(256)
	_normals["brick"] = TextureGeneratorScript.create_brick_normal(256)
	_normals["sidewalk"] = TextureGeneratorScript.create_sidewalk_normal(256)
	_normals["concrete"] = TextureGeneratorScript.create_concrete_normal(256)
	_normals["building_panel"] = TextureGeneratorScript.create_panel_building_normal(512, 5, 4)

	var elapsed := Time.get_ticks_msec() - start_time
	print("TextureManager: Generated %d textures + %d normals in %d ms" % [_textures.size(), _normals.size(), elapsed])
	print("TextureManager: Normal maps: ", _normals.keys())

func get_texture(name: String) -> ImageTexture:
	if _textures.has(name):
		return _textures[name]
	return null

func get_road_material(road_type: String) -> StandardMaterial3D:
	var mat_key := "road_" + road_type
	if _materials.has(mat_key):
		return _materials[mat_key]

	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var texture_key: String
	match road_type:
		"motorway", "trunk", "primary":
			texture_key = "road_primary"
		"secondary", "tertiary":
			texture_key = "road_secondary"
		"residential", "unclassified", "service":
			texture_key = "road_residential"
		"footway", "path", "cycleway", "track":
			texture_key = "road_path"
		_:
			texture_key = "road_residential"

	if _textures.has(texture_key):
		material.albedo_texture = _textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		material.uv1_scale = Vector3(1, 0.1, 1)  # Повторение вдоль дороги
		# Normal map для дорог (если включены)
		if _normals.has("asphalt") and _are_normal_maps_enabled():
			material.normal_enabled = true
			material.normal_texture = _normals["asphalt"]
			material.normal_scale = 0.5
	else:
		# Fallback цвет
		material.albedo_color = Color(0.3, 0.3, 0.3)

	_materials[mat_key] = material
	return material

func get_building_wall_material(building_type: String = "residential", height: float = 10.0) -> StandardMaterial3D:
	var mat_key := "building_wall_" + building_type
	if _materials.has(mat_key):
		return _materials[mat_key]

	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var texture_key: String
	match building_type:
		"apartments", "residential", "house":
			# Определяем по высоте: высокие - панельки, низкие - кирпич
			if height > 15.0:
				texture_key = "building_panel"
			else:
				texture_key = "building_brick"
		"commercial", "retail", "office":
			texture_key = "building_wall"
		"industrial", "warehouse":
			texture_key = "concrete"
		_:
			texture_key = "building_panel"

	if _textures.has(texture_key):
		material.albedo_texture = _textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		# UV масштаб зависит от высоты здания
		var floors := int(height / 3.0)  # ~3м на этаж
		material.uv1_scale = Vector3(1.0 / max(1, floors / 5.0), 1.0, 1.0)
		# Normal map для зданий (если включены)
		var normal_key := "building_panel" if texture_key == "building_panel" else "brick"
		if _normals.has(normal_key) and _are_normal_maps_enabled():
			material.normal_enabled = true
			material.normal_texture = _normals[normal_key]
			material.normal_scale = 0.6

	_materials[mat_key] = material
	return material

func get_building_roof_material() -> StandardMaterial3D:
	if _materials.has("building_roof"):
		return _materials["building_roof"]

	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	if _textures.has("building_roof"):
		material.albedo_texture = _textures["building_roof"]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		material.uv1_scale = Vector3(4, 4, 1)

	_materials["building_roof"] = material
	return material

func get_ground_material(ground_type: String) -> StandardMaterial3D:
	var mat_key := "ground_" + ground_type
	if _materials.has(mat_key):
		return _materials[mat_key]

	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var texture_key: String
	match ground_type:
		"grass", "meadow", "park", "garden":
			texture_key = "grass"
		"forest", "wood":
			texture_key = "forest"
		"farmland", "farm":
			texture_key = "dirt"
		"water", "river", "lake", "pond":
			texture_key = "water"
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		"concrete", "industrial":
			texture_key = "concrete"
		_:
			texture_key = "grass"

	if _textures.has(texture_key):
		material.albedo_texture = _textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		material.uv1_scale = Vector3(0.05, 0.05, 1)  # Большой масштаб для земли
		# Normal map для тротуаров (если включены)
		if texture_key == "concrete" and _normals.has("sidewalk") and _are_normal_maps_enabled():
			material.normal_enabled = true
			material.normal_texture = _normals["sidewalk"]
			material.normal_scale = 0.4

	_materials[mat_key] = material
	return material
