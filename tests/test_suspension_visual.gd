extends Node3D

## Визуальный тест подвески - машина едет по кругу
## Позволяет наблюдать крен кузова в реальном времени

var car: VehicleBody3D
var time_elapsed := 0.0
var circle_radius := 15.0  # Уменьшили радиус чтобы не уезжать за карту
var drive_mode := "auto"  # "auto" или "manual"

# Виртуальный input для AI управления
var virtual_steering := 0.0
var virtual_throttle := 0.0
var virtual_brake := 0.0

@onready var camera: Camera3D = $Camera3D
@onready var label: Label = $UI/Label

func _ready():
	print("=== Visual Suspension Test ===")
	print("Машина будет ездить по кругу")
	print("Наблюдайте за креном кузова")
	print("WASD - ручное управление")
	print("TAB - переключить режим (авто/ручной)")
	print("ESC - выход")

	# Создаём машину
	_spawn_car()

	# Создаём круговую дорогу
	_create_circular_road()

func _spawn_car():
	var car_scene = preload("res://car/car_nexia.tscn")
	car = car_scene.instantiate()
	add_child(car)

	# Ставим машину в центр, высоко чтобы упала
	car.global_position = Vector3(0, 3, 0)
	car.rotation.y = 0  # Смотрит вперёд (по -Z)

func _create_circular_road():
	# Создаём плоский круг как дорогу
	var road = StaticBody3D.new()
	add_child(road)

	var mesh_instance = MeshInstance3D.new()
	road.add_child(mesh_instance)

	# Цилиндр как круговая дорога
	var cylinder = CylinderMesh.new()
	cylinder.top_radius = circle_radius + 5
	cylinder.bottom_radius = circle_radius + 5
	cylinder.height = 0.5
	mesh_instance.mesh = cylinder

	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.3, 0.3)
	mesh_instance.set_surface_override_material(0, material)

	# Коллизия
	var collision = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = circle_radius + 5
	shape.height = 0.5
	collision.shape = shape
	road.add_child(collision)

	road.collision_layer = 2
	road.collision_mask = 7

func _physics_process(delta: float):
	if not car:
		return

	time_elapsed += delta

	# Переключение режима
	if Input.is_action_just_pressed("ui_focus_next"):  # TAB
		drive_mode = "manual" if drive_mode == "auto" else "auto"
		print("Режим: ", drive_mode)

	# Управление машиной
	if drive_mode == "auto":
		_drive_in_circle_auto(delta)
	else:
		_drive_manual()

	# Обновляем камеру
	_update_camera()

	# Обновляем UI
	_update_ui()

	# ESC для выхода
	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().quit()

func _drive_manual():
	# Ничего не делаем - машина управляется стандартным input
	pass

func _drive_in_circle_auto(_delta: float):
	# Едем по кругу - руль вправо, газ постоянно
	# Эмулируем Input через симуляцию нажатий

	# Постоянный газ
	car.throttle_input = 1.0
	car.brake_input = 0.0

	# Руль МАКСИМАЛЬНО ВПРАВО (поворот направо)
	# При повороте направо машина должна крениться ВЛЕВО
	car.steering_input = -1.0  # -1.0 = вправо в Godot

func _update_camera():
	if not car:
		return

	# Камера следует за машиной сзади и сбоку
	var offset = Vector3(8, 5, 8)
	var target_pos = car.global_position + offset

	camera.global_position = camera.global_position.lerp(target_pos, 0.1)
	camera.look_at(car.global_position + Vector3(0, 1, 0))

func _update_ui():
	if not car or not label:
		return

	var speed = car.linear_velocity.length() * 3.6
	var roll = rad_to_deg(car.rotation.z)
	var pitch = rad_to_deg(car.rotation.x)

	# Центробежное ускорение
	var v_squared = car.linear_velocity.length_squared()
	var centripetal_accel = v_squared / circle_radius if circle_radius > 0 else 0
	var lateral_g = centripetal_accel / 9.8

	label.text = """ВИЗУАЛЬНЫЙ ТЕСТ ПОДВЕСКИ

Режим: %s
%s

Скорость: %.1f км/ч
Крен (Roll): %.2f° %s
Наклон (Pitch): %.2f°

%s

TAB - переключить режим
WASD - ручное управление
ESC - выход
""" % [
		drive_mode.to_upper(),
		"(AI применяет боковую силу)" if drive_mode == "auto" else "(Управляй машиной)",
		speed,
		roll,
		"← ВЛЕВО" if roll < -0.5 else ("→ ВПРАВО" if roll > 0.5 else ""),
		pitch,
		_get_roll_explanation(roll, lateral_g)
	]

func _get_roll_explanation(roll: float, lateral_g: float) -> String:
	if abs(lateral_g) < 0.1:
		return "Машина едет прямо - крена нет"

	var expected_direction = "влево (отрицательный)" if lateral_g > 0 else "вправо (положительный)"
	var actual_direction = "влево (отрицательный)" if roll < 0 else "вправо (положительный)"

	if (lateral_g > 0.1 and roll < -0.5) or (lateral_g < -0.1 and roll > 0.5):
		return "✓ ПРАВИЛЬНО: Крен %s\n(от центробежной силы)" % actual_direction
	elif abs(roll) < 0.5:
		return "⚠ Крен слабый (возможно слишком жёсткая подвеска)"
	else:
		return "✗ НЕПРАВИЛЬНО: Крен %s\n(должен быть %s)" % [actual_direction, expected_direction]
