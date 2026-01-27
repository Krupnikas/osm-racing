extends Control

@export var car_path: NodePath
@export var terrain_generator_path: NodePath

var _car: Node3D  # Может быть VehicleBody3D или GEVP Vehicle
var _car_rigidbody: RigidBody3D  # Для GEVP - доступ к RigidBody3D
var _speedometer: Control
var _terrain_generator: Node3D

# Текущие значения
var _current_speed: float = 0.0
var _current_rpm: float = 0.0
var _current_gear: String = "N"

func _ready() -> void:
	visible = false
	await get_tree().process_frame

	_speedometer = $Speedometer

	if car_path:
		_car = get_node(car_path)
	else:
		_car = get_tree().get_first_node_in_group("car")

	if terrain_generator_path:
		_terrain_generator = get_node(terrain_generator_path)

	# Теперь _car указывает прямо на RigidBody3D (как в аркаде)
	if _car is RigidBody3D:
		_car_rigidbody = _car

	# Подключаем сигналы если есть (старая аркадная физика)
	if _car and _car.has_signal("speed_changed"):
		_car.speed_changed.connect(_on_speed_changed)
		_car.rpm_changed.connect(_on_rpm_changed)
		_car.gear_changed.connect(_on_gear_changed)


func _process(_delta: float) -> void:
	# Для GEVP Vehicle читаем значения напрямую (нет сигналов)
	if _car_rigidbody and not (_car is VehicleBody3D):
		# GEVP Vehicle - получаем данные из RigidBody3D
		if _car_rigidbody.has_method("get"):
			var speed_ms := _car_rigidbody.linear_velocity.length()
			_current_speed = speed_ms * 3.6  # м/с в км/ч

			# Читаем RPM и передачу если есть
			if _car_rigidbody.get("motor_rpm") != null:
				_current_rpm = _car_rigidbody.motor_rpm
			if _car_rigidbody.get("current_gear") != null:
				var gear: int = _car_rigidbody.current_gear
				if gear == -1:
					_current_gear = "R"
				elif gear == 0:
					_current_gear = "N"
				else:
					_current_gear = str(gear)

			_update_speedometer()

func _on_speed_changed(speed: float) -> void:
	# Скорость уже в км/ч (для старой аркадной физики)
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


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			_toggle_chunk_debug()


func _toggle_chunk_debug() -> void:
	if _terrain_generator and _terrain_generator.has_method("toggle_chunk_boundaries"):
		_terrain_generator.toggle_chunk_boundaries()


func _on_debug_button_pressed() -> void:
	_toggle_chunk_debug()
