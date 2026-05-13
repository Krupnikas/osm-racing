extends Control

@export var car_path: NodePath
@export var terrain_generator_path: NodePath

var _car: Node3D  # Может быть VehicleBody3D или GEVP Vehicle
var _car_rigidbody: RigidBody3D  # Для GEVP - доступ к RigidBody3D
var _speedometer: Control
var _minimap: Control
var _terrain_generator: Node3D

# Текущие значения
var _current_speed: float = 0.0
var _current_rpm: float = 0.0
var _current_gear: String = "N"

# Титры событий
var _event_label: Label
var _event_tween: Tween

func _ready() -> void:
	visible = false
	await get_tree().process_frame

	_speedometer = $Speedometer
	_minimap = $MiniMap if has_node("MiniMap") else null
	_event_label = $EventLabel if has_node("EventLabel") else null

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

	# Day / night swap for the round speedometer. NightModeManager is a
	# scene child (not autoload), so we walk the current scene to find it.
	var night_mgr: Node = null
	var scene_root := get_tree().current_scene
	if scene_root:
		night_mgr = scene_root.find_child("NightModeManager", true, false)
	if night_mgr and night_mgr.has_signal("night_mode_changed"):
		night_mgr.night_mode_changed.connect(_on_night_mode_changed)
		var is_night: bool = false
		if night_mgr.get("is_night") != null:
			is_night = bool(night_mgr.is_night)
		_on_night_mode_changed(is_night)


func _on_night_mode_changed(enabled: bool) -> void:
	if _speedometer and _speedometer.has_method("set_night"):
		_speedometer.set_night(enabled)


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
	if not _speedometer:
		return
	# Legacy path: old square speedometer used `update_values(speed, rpm, gear)`.
	if _speedometer.has_method("update_values"):
		_speedometer.update_values(_current_speed, _current_rpm, _current_gear)
		return
	# New round speedometer reads exported properties; numeric gear is
	# easier to format than the "N/R/1..6" string we keep for the legacy
	# component.
	_speedometer.current_speed_kmh = _current_speed
	var gear_int := 1
	if _current_gear == "R":
		gear_int = -1
	elif _current_gear == "N":
		gear_int = 0
	elif _current_gear.is_valid_int():
		gear_int = int(_current_gear)
	_speedometer.current_gear = gear_int
	# Pull nitro % from the car if it exposes one.
	if _car_rigidbody and _car_rigidbody.get("nitro_pct") != null:
		_speedometer.nitro_pct = float(_car_rigidbody.nitro_pct)


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


func set_race_mode(enabled: bool) -> void:
	"""Включает режим гонки (показывает соперников на мини-карте)"""
	if _minimap and _minimap.has_method("set_show_opponents"):
		_minimap.set_show_opponents(enabled)


## Показывает титр события над миникартой.
## text — текст титра, duration — сколько секунд висит перед fade-out.
## Если вызвать повторно до исчезновения — текст обновляется, таймер рестартует.
func show_event_title(text: String, duration: float = 3.0) -> void:
	if not _event_label:
		return
	_event_label.text = text
	_event_label.visible = true
	_event_label.modulate.a = 1.0
	_event_label.scale = Vector2(1.3, 1.3)
	_event_label.pivot_offset = _event_label.size * 0.5
	if _event_tween and _event_tween.is_valid():
		_event_tween.kill()
	_event_tween = create_tween()
	_event_tween.tween_property(_event_label, "scale", Vector2(1.0, 1.0), 0.15).set_ease(Tween.EASE_OUT)
	_event_tween.tween_interval(duration)
	_event_tween.tween_property(_event_label, "modulate:a", 0.0, 0.3)
	_event_tween.tween_callback(func(): _event_label.visible = false)
