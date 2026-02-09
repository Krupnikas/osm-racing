class_name BillboardDecoration
extends Resource

## Декорация: рекламный билборд

# Позиционирование (lat/lon или локальные координаты)
@export var lat: float = 0.0
@export var lon: float = 0.0
@export var use_latlon: bool = true  # true = lat/lon, false = local_position
@export var local_position: Vector2 = Vector2.ZERO  # Локальные координаты X,Z

# Ориентация и размеры
@export var rotation_y: float = 0.0  # Поворот вокруг Y (радианы)
@export var size: Vector2 = Vector2(4.0, 3.0)  # Ширина x Высота в метрах
@export var pole_height: float = 3.0  # Высота столба

# Контент
@export var text: String = ""  # Текст на билборде (если нет текстуры)
@export var texture_path: String = ""  # Путь к текстуре передней стороны
@export var texture_path_back: String = ""  # Путь к текстуре задней стороны (если отличается)
@export var background_color: Color = Color.WHITE
@export var text_color: Color = Color.BLACK

# Освещение
@export var has_backlight: bool = true  # Подсветка ночью
@export var emission_strength: float = 0.5


func get_local_position(start_lat: float, start_lon: float) -> Vector2:
	"""Конвертирует lat/lon в локальные координаты"""
	if not use_latlon:
		return local_position

	var dx := (lon - start_lon) * 111000.0 * cos(deg_to_rad(start_lat))
	var dz := (lat - start_lat) * 111000.0
	return Vector2(dx, -dz)  # Z инвертирован для Godot
