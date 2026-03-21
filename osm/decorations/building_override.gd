class_name BuildingOverride
extends Resource

## Переопределение свойств здания из OSM

# Идентификация здания (один из способов)
@export var osm_way_id: int = 0  # OSM way ID (приоритет)
@export var position: Vector2 = Vector2.ZERO  # Позиция центра (lat, lon)
@export var match_radius: float = 10.0  # Радиус поиска по позиции

# Переопределения текстур
@export var wall_texture_path: String = ""  # Кастомная текстура стен
@export var wall_normal_path: String = ""  # Normal map (авто: *_normal.png)
@export var wall_ao_path: String = ""  # Ambient Occlusion (авто: *_ambient.png)
@export var wall_specular_path: String = ""  # Specular/Roughness (авто: *_specular.png)
@export var wall_displacement_path: String = ""  # Displacement/Height (авто: *_displacement.png)
@export var wall_emissive_path: String = ""  # Emissive mask для светящихся окон (авто: *_emissive_mask.png)
@export var roof_texture_path: String = ""  # Кастомная текстура крыши
@export var texture_repeat_x: float = 0.0  # Повторений по периметру (0 = авто)
@export var texture_offset_x: float = 0.0  # Сдвиг UV по периметру (доля от repeat, 0.0-1.0)
@export var texture_repeat_y: float = 2.0  # Сколько раз текстура повторяется по высоте

# Адаптивное повторение (отдельно для коротких/длинных стен)
@export var use_adaptive_repeat: bool = false  # Включить адаптивный режим
@export var texture_repeat_short: float = 1.0  # Повторов на короткой стене
@export var texture_repeat_long: float = 3.0  # Повторов на длинной стене
@export var normal_strength: float = 1.0  # Сила normal map (0.0-2.0)
@export var ao_strength: float = 1.0  # Сила ambient occlusion (0.0-1.0)
@export var heightmap_scale: float = 0.02  # Глубина parallax (0.0-0.1)

# Переопределение цвета (применяется поверх текстуры)
@export var color_tint: Color = Color.WHITE  # Оттенок (WHITE = без изменений)
@export var use_color_tint: bool = false  # Использовать color_tint

# Материал здания (из override JSON, например "wood", "brick")
var building_material: String = ""

# Тип крыши: "" = flat (default), "hip" = вальмовая, "gable" = двускатная
var roof_type: String = ""
var ridge_height: float = 0.0  # Высота конька (0 = авто: 2.5 hip, 3.5 gable)
var gable_color: Color = Color(0.9, 0.9, 0.92)  # Цвет фронтонов (для gable)

# Переопределения параметров
@export var height_override: float = -1.0  # -1 = не менять
@export var height_multiplier: float = 1.0  # Множитель высоты

# Дополнительные элементы
@export var custom_sign_text: String = ""  # Вывеска на здании
@export var add_entrance: bool = false  # Добавить входную группу

# Входные группы подъездов [{lat: float, lon: float, type: String (optional)}]
var entrances: Array = []

# Входные группы магазинов [{lat: float, lon: float, sign_logo: String (optional)}]
var shop_entrances: Array = []

# POI nodes to skip (suppress auto-generated entrance) [int osm_node_id, ...]
var skip_pois: Array = []

# Custom entrance groups [{type: String, lat: float, lon: float, ...}]
var custom_entrances: Array = []

# Skip all auto-generated POI signs for this building
var skip_all_pois: bool = false

# No foundation (texture goes from roof to ground)
var no_foundation: bool = false

# Roof-mounted signs [{lat: float, lon: float, logo: String}]
var roof_signs: Array = []

# Wall signs [{lat, lon, logo, height_ratio, width}] — logos/signs on building walls
var wall_signs: Array = []

# Pediments — надстройки-фронтоны на стене [{lat, lon, rect_height, tri_height, color: [R,G,B]}]
var pediments: Array = []

# Custom 3D model (replaces entire building geometry)
var custom_model_path: String = ""  # res:// path to GLB/GLTF
var custom_model_scale: float = 1.0
var custom_model_rotation_y: float = 0.0  # degrees
var custom_model_y_offset: float = 0.0
var custom_model_visibility_range: float = 500.0  # LOD visibility range


func matches_way_id(way_id: int) -> bool:
	"""Проверяет совпадение по OSM way ID"""
	return osm_way_id > 0 and osm_way_id == way_id


func matches_position(building_center: Vector2, threshold: float = -1.0) -> bool:
	"""Проверяет совпадение по позиции (lat, lon)"""
	if position == Vector2.ZERO:
		return false
	var radius := threshold if threshold > 0 else match_radius
	# position хранит (lat, lon), building_center тоже
	var dist := position.distance_to(building_center)
	# Примерное расстояние: 0.00001° ≈ 1м
	return dist < radius * 0.00001
