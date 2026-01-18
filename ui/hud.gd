extends Control

@export var car_path: NodePath

var _car: VehicleBody3D
var _speedometer: Control

# Текущие значения
var _current_speed: float = 0.0
var _current_rpm: float = 0.0
var _current_gear: String = "N"

func _ready() -> void:
	visible = false
	await get_tree().process_frame

	_speedometer = $Speedometer

	if car_path:
		_car = get_node(car_path) as VehicleBody3D
	else:
		_car = get_tree().get_first_node_in_group("car") as VehicleBody3D

	if _car and _car.has_signal("speed_changed"):
		_car.speed_changed.connect(_on_speed_changed)
		_car.rpm_changed.connect(_on_rpm_changed)
		_car.gear_changed.connect(_on_gear_changed)


func _on_speed_changed(speed: float) -> void:
	# Скорость уже в км/ч
	_current_speed = speed
	_update_speedometer()


func _on_rpm_changed(rpm: float) -> void:
	_current_rpm = rpm
	_update_speedometer()


func _on_gear_changed(gear: int) -> void:
	match gear:
		0: _current_gear = "R"
		1: _current_gear = "N"
		_: _current_gear = str(gear - 1)
	_update_speedometer()


func _update_speedometer() -> void:
	if _speedometer and _speedometer.has_method("update_values"):
		_speedometer.update_values(_current_speed, _current_rpm, _current_gear)


func show_hud() -> void:
	visible = true


func hide_hud() -> void:
	visible = false
