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
@export var roof_texture_path: String = ""  # Кастомная текстура крыши
@export var texture_repeat_x: float = 0.0  # Повторений по периметру (0 = авто)
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

# Переопределения параметров
@export var height_override: float = -1.0  # -1 = не менять
@export var height_multiplier: float = 1.0  # Множитель высоты

# Дополнительные элементы
@export var custom_sign_text: String = ""  # Вывеска на здании
@export var add_entrance: bool = false  # Добавить входную группу


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
