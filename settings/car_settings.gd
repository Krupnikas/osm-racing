extends Node

## CarSettings - Autoload для выбора и настройки машин
##
## Система выбора машины в стиле NFS Underground с сохранением на диск.
## Каждая машина имеет уникальные характеристики для аркадного геймплея.
##
## Параметры GEVP Vehicle:
## - max_torque: крутящий момент в Нм (аркадные значения 600-700)
## - max_steering_angle: максимальный угол поворота колёс в градусах
## - steering_speed: скорость поворота руля (выше = отзывчивее)
## - final_drive: главная передача (выше = лучше разгон, ниже = выше макс. скорость)
## - max_rpm: максимальные обороты двигателя
## - coefficient_of_drag: коэффициент аэродинамического сопротивления (0.22-0.30)
## - frontal_area: площадь лобового сопротивления в м² (1.6-1.8 для компактных авто)
## - gear_ratios: передаточные числа КПП (плотные передачи = двигатель на высоких оборотах)
##
## ВАЖНО: После изменения max_torque нужно пересчитать max_clutch_torque,
## иначе сцепление ограничивает передачу мощности на колёса.

const CONFIG_PATH := "user://car_settings.cfg"
const DEFAULT_CAR := "nexia"

var selected_car_id: String = DEFAULT_CAR
const CARS := {
	"nexia": {
		"name": "Daewoo Nexia",
		"scene": "res://addons/gevp/scenes/nexia_car.tscn",
		"max_torque": 600.0,  # Аркадный крутящий момент
		"max_steering_angle": 40.0,
		"steering_speed": 4.25,
		"final_drive": 3.8,
		"max_rpm": 7000.0,
		"coefficient_of_drag": 0.25,
		"frontal_area": 1.7,
		# Короткие передачи - двигатель всегда на высоких оборотах
		"gear_ratios": [3.5, 2.3, 1.7, 1.3, 1.0]
	},
	"beetle": {
		"name": "VW Beetle",
		"scene": "res://addons/gevp/scenes/beetle_car.tscn",
		"max_torque": 700.0,  # Спортивная мощность
		"max_steering_angle": 42.0,
		"steering_speed": 4.5,
		"final_drive": 3.6,
		"max_rpm": 8000.0,
		"coefficient_of_drag": 0.22,
		"frontal_area": 1.6,
		# Спортивная КПП с плотными передачами
		"gear_ratios": [3.4, 2.2, 1.6, 1.25, 1.0, 0.85]
	},
	"polo": {
		"name": "VW Polo",
		"scene": "res://addons/gevp/scenes/polo_car.tscn",
		"max_torque": 600.0,
		"max_steering_angle": 40.0,
		"steering_speed": 4.25,
		"final_drive": 3.8,
		"max_rpm": 7000.0,
		"coefficient_of_drag": 0.27,
		"frontal_area": 1.75,
		"gear_ratios": [3.5, 2.3, 1.7, 1.3, 1.0]
	}
}


func _ready() -> void:
	_load_settings()


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		selected_car_id = config.get_value("car", "selected", DEFAULT_CAR)
		# Проверяем что машина существует
		if not CARS.has(selected_car_id):
			selected_car_id = DEFAULT_CAR


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("car", "selected", selected_car_id)
	config.save(CONFIG_PATH)


func get_car_scene_path() -> String:
	return CARS[selected_car_id]["scene"]


func get_car_ids() -> Array:
	return CARS.keys()


func get_car_name(car_id: String) -> String:
	return CARS[car_id]["name"]


func apply_car_stats(car: Node3D, car_id: String = "") -> void:
	"""Применить характеристики машины из настроек"""
	if car_id == "":
		car_id = selected_car_id

	if not CARS.has(car_id):
		return

	var stats: Dictionary = CARS[car_id]

	# Применяем параметры GEVP Vehicle
	if car.get("max_torque") != null and stats.has("max_torque"):
		car.max_torque = stats["max_torque"]
		print("CarSettings: Set max_torque = ", stats["max_torque"])

	if car.get("max_steering_angle") != null and stats.has("max_steering_angle"):
		car.max_steering_angle = deg_to_rad(stats["max_steering_angle"])
		print("CarSettings: Set max_steering_angle = ", stats["max_steering_angle"], "°")

	if car.get("steering_speed") != null and stats.has("steering_speed"):
		car.steering_speed = stats["steering_speed"]
		print("CarSettings: Set steering_speed = ", stats["steering_speed"])

	# Параметры для максимальной скорости
	if car.get("final_drive") != null and stats.has("final_drive"):
		car.final_drive = stats["final_drive"]
		print("CarSettings: Set final_drive = ", stats["final_drive"])

	if car.get("max_rpm") != null and stats.has("max_rpm"):
		car.max_rpm = stats["max_rpm"]
		print("CarSettings: Set max_rpm = ", stats["max_rpm"])

	if car.get("coefficient_of_drag") != null and stats.has("coefficient_of_drag"):
		car.coefficient_of_drag = stats["coefficient_of_drag"]
		print("CarSettings: Set coefficient_of_drag = ", stats["coefficient_of_drag"])

	# Передаточные числа КПП
	if car.get("gear_ratios") != null and stats.has("gear_ratios"):
		var ratios: Array[float] = []
		for r in stats["gear_ratios"]:
			ratios.append(r)
		car.gear_ratios = ratios
		print("CarSettings: Set gear_ratios = ", ratios)

	# Площадь лобового сопротивления
	if car.get("frontal_area") != null and stats.has("frontal_area"):
		car.frontal_area = stats["frontal_area"]
		print("CarSettings: Set frontal_area = ", stats["frontal_area"])

	# ВАЖНО: Пересчитываем max_clutch_torque после изменения max_torque
	# Иначе сцепление ограничивает передачу мощности
	if car.get("max_clutch_torque") != null and car.get("max_torque") != null:
		var ratio = 1.6  # default max_clutch_torque_ratio
		if car.get("max_clutch_torque_ratio") != null:
			ratio = car.max_clutch_torque_ratio
		car.max_clutch_torque = car.max_torque * ratio
		print("CarSettings: Recalculated max_clutch_torque = ", car.max_clutch_torque)
