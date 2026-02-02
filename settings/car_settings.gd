extends Node

## Autoload для сохранения выбранной машины игрока

const CONFIG_PATH := "user://car_settings.cfg"
const DEFAULT_CAR := "nexia"

var selected_car_id: String = DEFAULT_CAR

const CARS := {
	"nexia": {
		"name": "Daewoo Nexia",
		"scene": "res://addons/gevp/scenes/nexia_car.tscn"
	},
	"beetle": {
		"name": "VW Beetle",
		"scene": "res://addons/gevp/scenes/beetle_car.tscn"
	},
	"polo": {
		"name": "VW Polo",
		"scene": "res://addons/gevp/scenes/polo_car.tscn"
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
