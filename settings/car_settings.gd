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

# Характеристики для UI (0.0-1.0)
const DISPLAY_STATS := {
	"nexia": {"accel": 0.65, "speed": 0.60, "handling": 0.70},
	"beetle": {"accel": 0.85, "speed": 0.90, "handling": 0.80},
	"polo": {"accel": 0.60, "speed": 0.55, "handling": 0.75},
	"logan": {"accel": 0.55, "speed": 0.50, "handling": 0.65},
	"matiz": {"accel": 0.40, "speed": 0.35, "handling": 0.75},
	"bmw_m3_gtr": {"accel": 0.90, "speed": 0.95, "handling": 0.85},
	"ford_focus_st_2006": {"accel": 0.78, "speed": 0.80, "handling": 0.78},
	"honda_civic_si_2006": {"accel": 0.76, "speed": 0.78, "handling": 0.80},
	"mazda_rx8_2006": {"accel": 0.78, "speed": 0.80, "handling": 0.82},
	"audi_tt_32_2003": {"accel": 0.80, "speed": 0.82, "handling": 0.80},
	"volga_gaz3110": {"accel": 0.45, "speed": 0.50, "handling": 0.50},
	"lancer_evo_x_2008": {"accel": 0.85, "speed": 0.82, "handling": 0.88},
	"subaru_sti_2011": {"accel": 0.86, "speed": 0.83, "handling": 0.87},
	"mercedes_clk55_2003": {"accel": 0.82, "speed": 0.85, "handling": 0.76},
	"porsche_cayenne_turbo_s_2009": {"accel": 0.80, "speed": 0.82, "handling": 0.60},
	"chevrolet_aveo_5_lt_2009": {"accel": 0.50, "speed": 0.52, "handling": 0.58},
	"chevrolet_spark_12_lt_2011": {"accel": 0.42, "speed": 0.44, "handling": 0.62}
}

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
	},
	"logan": {
		"name": "Renault Logan",
		"scene": "res://addons/gevp/scenes/logan_car.tscn",
		"max_torque": 550.0,
		"max_steering_angle": 38.0,
		"steering_speed": 4.0,
		"final_drive": 4.2,
		"max_rpm": 6500.0,
		"coefficient_of_drag": 0.33,
		"frontal_area": 2.0,
		"gear_ratios": [3.73, 2.05, 1.39, 1.03, 0.82]
	},
	"matiz": {
		"name": "Daewoo Matiz",
		"scene": "res://addons/gevp/scenes/matiz_car.tscn",
		"max_torque": 450.0,
		"max_steering_angle": 42.0,
		"steering_speed": 4.5,
		"final_drive": 4.5,
		"max_rpm": 6000.0,
		"coefficient_of_drag": 0.35,
		"frontal_area": 1.5,
		"gear_ratios": [3.73, 2.05, 1.39, 1.03, 0.82]
	},
	"bmw_m3_gtr": {
		"name": "BMW M3 GTR",
		"scene": "res://addons/gevp/scenes/bmw_m3_gtr_car.tscn"
	},
	"ford_focus_st_2006": {
		"name": "Ford Focus ST",
		"scene": "res://addons/gevp/scenes/ford_focus_st_car.tscn",
		"max_torque": 850.0,  # 2.5L турбо, спортивный хот-хэтч
		"max_steering_angle": 38.0,
		"steering_speed": 4.3,
		"final_drive": 3.8,
		"max_rpm": 6500.0,
		"coefficient_of_drag": 0.32,
		"frontal_area": 2.0,
		"gear_ratios": [3.5, 2.3, 1.7, 1.3, 1.0]
	},
	"honda_civic_si_2006": {
		"name": "Honda Civic Si",
		"scene": "res://addons/gevp/scenes/honda_civic_si_car.tscn",
		"max_torque": 760.0,  # 2.0L i-VTEC K20, высокооборотистый
		"max_steering_angle": 40.0,
		"steering_speed": 4.5,
		"final_drive": 4.76,
		"max_rpm": 8000.0,
		"coefficient_of_drag": 0.31,
		"frontal_area": 1.98,
		"gear_ratios": [3.27, 2.13, 1.52, 1.15, 0.92, 0.74]
	},
	"mazda_rx8_2006": {
		"name": "Mazda RX-8",
		"scene": "res://addons/gevp/scenes/mazda_rx8_car.tscn",
		"max_torque": 720.0,  # 1.3L 13B Renesis rotary, низкий момент / высокие обороты
		"max_steering_angle": 40.0,
		"steering_speed": 4.6,
		"final_drive": 4.44,
		"max_rpm": 9000.0,
		"coefficient_of_drag": 0.31,
		"frontal_area": 1.95,
		"gear_ratios": [3.76, 2.27, 1.65, 1.32, 1.0, 0.84]
	},
	"audi_tt_32_2003": {
		"name": "Audi TT 3.2 quattro",
		"scene": "res://addons/gevp/scenes/audi_tt_car.tscn",
		"max_torque": 820.0,  # 3.2L VR6, AWD quattro
		"max_steering_angle": 38.0,
		"steering_speed": 4.2,
		"final_drive": 4.06,
		"max_rpm": 6500.0,
		"coefficient_of_drag": 0.32,
		"frontal_area": 1.90,
		"gear_ratios": [3.5, 2.3, 1.6, 1.2, 0.95, 0.78]
	},
	"volga_gaz3110": {
		"name": "Volga GAZ-3110",
		"scene": "res://addons/gevp/scenes/volga_gaz3110_car.tscn",
		"max_torque": 640.0,  # 2.3L ЗМЗ, RWD, тяжёлый седан
		"max_steering_angle": 36.0,
		"steering_speed": 3.8,
		"final_drive": 3.9,
		"max_rpm": 5500.0,
		"coefficient_of_drag": 0.42,
		"frontal_area": 2.1,
		"gear_ratios": [3.5, 2.26, 1.45, 1.0, 0.85]
	},
	"lancer_evo_x_2008": {
		"name": "Mitsubishi Lancer Evo X",
		"scene": "res://addons/gevp/scenes/lancer_evo_x_car.tscn",
		"max_torque": 900.0,  # 2.0L 4B11T turbo, AWD S-AWC
		"max_steering_angle": 38.0,
		"steering_speed": 4.4,
		"final_drive": 4.06,
		"max_rpm": 7000.0,
		"coefficient_of_drag": 0.35,
		"frontal_area": 2.1,
		"gear_ratios": [3.65, 2.37, 1.69, 1.32, 1.06, 0.84]
	},
	"subaru_sti_2011": {
		"name": "Subaru WRX STI",
		"scene": "res://addons/gevp/scenes/subaru_sti_car.tscn",
		"max_torque": 950.0,  # 2.5L EJ257 turbo, AWD
		"max_steering_angle": 38.0,
		"steering_speed": 4.4,
		"final_drive": 3.9,
		"max_rpm": 6500.0,
		"coefficient_of_drag": 0.36,
		"frontal_area": 2.1,
		"gear_ratios": [3.64, 2.24, 1.59, 1.16, 0.97, 0.76]
	},
	"mercedes_clk55_2003": {
		"name": "Mercedes CLK 55 AMG",
		"scene": "res://addons/gevp/scenes/mercedes_clk55_car.tscn",
		"max_torque": 1000.0,  # 5.4L M113 V8, RWD
		"max_steering_angle": 36.0,
		"steering_speed": 4.0,
		"final_drive": 2.82,
		"max_rpm": 6100.0,
		"coefficient_of_drag": 0.32,
		"frontal_area": 2.0,
		"gear_ratios": [3.59, 2.19, 1.41, 1.0, 0.83]
	},
	"porsche_cayenne_turbo_s_2009": {
		"name": "Porsche Cayenne Turbo S",
		"scene": "res://addons/gevp/scenes/cayenne_car.tscn",
		"max_torque": 1100.0,  # 4.8L twin-turbo V8, AWD SUV
		"max_steering_angle": 34.0,
		"steering_speed": 3.6,
		"final_drive": 3.7,
		"max_rpm": 6000.0,
		"coefficient_of_drag": 0.36,
		"frontal_area": 2.7,
		"gear_ratios": [4.1, 2.3, 1.5, 1.1, 0.87, 0.69]
	},
	"chevrolet_aveo_5_lt_2009": {
		"name": "Chevrolet Aveo 5 LT",
		"scene": "res://addons/gevp/scenes/aveo_car.tscn",
		"max_torque": 560.0,  # 1.6L, FWD economy hatch
		"max_steering_angle": 38.0,
		"steering_speed": 4.2,
		"final_drive": 4.18,
		"max_rpm": 6000.0,
		"coefficient_of_drag": 0.33,
		"frontal_area": 2.0,
		"gear_ratios": [3.5, 2.0, 1.3, 0.95, 0.75]
	},
	"chevrolet_spark_12_lt_2011": {
		"name": "Chevrolet Spark 1.2 LT",
		"scene": "res://addons/gevp/scenes/spark_car.tscn",
		"max_torque": 480.0,  # 1.2L, FWD city hatch
		"max_steering_angle": 40.0,
		"steering_speed": 4.5,
		"final_drive": 4.3,
		"max_rpm": 6200.0,
		"coefficient_of_drag": 0.33,
		"frontal_area": 1.9,
		"gear_ratios": [3.6, 2.05, 1.35, 0.97, 0.76]
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

	# Применяем тюнинг из карьеры (если есть активный профиль)
	if CareerState and CareerState.active_profile != "":
		_apply_tuning(car, car_id)

	# ВАЖНО: Пересчитываем max_clutch_torque после изменения max_torque
	# Иначе сцепление ограничивает передачу мощности
	if car.get("max_clutch_torque") != null and car.get("max_torque") != null:
		var ratio = 1.6  # default max_clutch_torque_ratio
		if car.get("max_clutch_torque_ratio") != null:
			ratio = car.max_clutch_torque_ratio
		car.max_clutch_torque = car.max_torque * ratio
		print("CarSettings: Recalculated max_clutch_torque = ", car.max_clutch_torque)


func _apply_tuning(car: Node3D, car_id: String) -> void:
	"""Применить бонусы тюнинга из карьеры"""
	var engine_lvl := CareerState.get_tuning_level(car_id, "engine")
	var suspension_lvl := CareerState.get_tuning_level(car_id, "suspension")
	var transmission_lvl := CareerState.get_tuning_level(car_id, "transmission")
	var brakes_lvl := CareerState.get_tuning_level(car_id, "brakes")

	if engine_lvl > 0:
		# Двигатель: +10%/+20%/+30% к крутящему моменту, +500/+1000/+1500 об/мин
		if car.get("max_torque") != null:
			car.max_torque *= (1.0 + engine_lvl * 0.10)
		if car.get("max_rpm") != null:
			car.max_rpm += engine_lvl * 500.0
		print("CarSettings: Tuning engine lvl %d applied" % engine_lvl)

	if suspension_lvl > 0:
		# Подвеска: +0.25/+0.5/+0.75 к скорости руля, +2/+4/+6 градусов к углу
		if car.get("steering_speed") != null:
			car.steering_speed += suspension_lvl * 0.25
		if car.get("max_steering_angle") != null:
			car.max_steering_angle += deg_to_rad(suspension_lvl * 2.0)
		print("CarSettings: Tuning suspension lvl %d applied" % suspension_lvl)

	if transmission_lvl > 0:
		# Коробка: -0.15/-0.3/-0.45 к главной передаче (выше макс. скорость)
		if car.get("final_drive") != null:
			car.final_drive -= transmission_lvl * 0.15
		print("CarSettings: Tuning transmission lvl %d applied" % transmission_lvl)

	if brakes_lvl > 0:
		# Тормоза: -0.02/-0.04/-0.06 к коэфф. сопротивления, -0.1/-0.2/-0.3 к лоб. площади
		if car.get("coefficient_of_drag") != null:
			car.coefficient_of_drag -= brakes_lvl * 0.02
		if car.get("frontal_area") != null:
			car.frontal_area -= brakes_lvl * 0.1
		print("CarSettings: Tuning brakes lvl %d applied" % brakes_lvl)
