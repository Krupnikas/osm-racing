extends GPUParticles3D
## Грязь из-под колёс при езде по бездорожью + брызги воды на мокрой дороге
## Реалистичные брызги с вариацией цвета и размера

@export var vehicle: Vehicle
@export var min_speed := 2.0  # м/с
@export var base_emission_chance := 0.9  # Базовый шанс (увеличивается при заносе)

# Глобальное значение wetness (обновляется из osm_terrain_generator)
static var current_wetness: float = 0.0

# Палитра цветов — реалистичная грязь с примесью травы
const DIRT_COLORS: Array[Color] = [
	Color(0.35, 0.28, 0.18, 0.9),
	Color(0.28, 0.22, 0.14, 0.85),
	Color(0.22, 0.18, 0.12, 0.8),
	Color(0.42, 0.34, 0.22, 0.9),
	Color(0.32, 0.35, 0.20, 0.85),
	Color(0.28, 0.32, 0.18, 0.8),
	Color(0.35, 0.38, 0.25, 0.85),
	Color(0.25, 0.30, 0.18, 0.75),
]

# Палитра цветов водяных брызг — более заметные
const SPRAY_COLORS: Array[Color] = [
	Color(0.75, 0.8, 0.9, 0.5),
	Color(0.65, 0.7, 0.8, 0.45),
	Color(0.8, 0.85, 0.95, 0.4),
	Color(0.6, 0.65, 0.75, 0.45),
]

const OFFROAD_SURFACES := ["Grass", "Dirt"]
const ROAD_SURFACES := ["Road"]
const SPRAY_MIN_SPEED := 5.0


func _process(_delta: float) -> void:
	if not is_instance_valid(vehicle):
		return

	var speed := vehicle.linear_velocity.length()
	if speed < min_speed:
		return

	var wetness := current_wetness

	for i in vehicle.wheel_array.size():
		var wheel: Wheel = vehicle.wheel_array[i]
		if not wheel.is_colliding():
			continue

		if wheel.surface_type in OFFROAD_SURFACES:
			_process_dirt(wheel, speed)
		elif wheel.surface_type in ROAD_SURFACES and wetness > 0.2 and speed > SPRAY_MIN_SPEED:
			var is_rear := i >= 2  # 0,1=front, 2,3=rear
			_process_spray(wheel, speed, wetness, is_rear)


func _process_dirt(wheel: Wheel, speed: float) -> void:
	var slip := wheel.slip_vector.length()
	var spin_factor := absf(wheel.spin) / 50.0
	var emission_chance := base_emission_chance + slip * 0.15 + spin_factor * 0.1
	emission_chance = clampf(emission_chance, 0.1, 0.7)

	if randf() > emission_chance:
		return

	var count := clampi(50 + int(slip * 40) + int(speed / 2.0), 50, 150)
	for j in count:
		_emit_dirt_particle(wheel, speed, slip)


func _process_spray(wheel: Wheel, speed: float, wetness: float, is_rear: bool) -> void:
	var speed_factor := clampf((speed - SPRAY_MIN_SPEED) / 15.0, 0.0, 1.0)
	var wet_factor := clampf((wetness - 0.2) / 0.8, 0.0, 1.0)
	var intensity := speed_factor * wet_factor

	if not is_rear:
		intensity *= 0.15

	var count := clampi(int(60.0 * intensity), 3 if is_rear else 1, 80)

	for j in count:
		_emit_spray_particle(wheel, speed, intensity, is_rear)


func _emit_dirt_particle(wheel: Wheel, speed: float, slip: float) -> void:
	var t := Transform3D.IDENTITY
	t.origin = wheel.last_collision_point
	t.origin.x += randf_range(-0.12, 0.12)
	t.origin.y += randf_range(0.02, 0.08)
	t.origin.z += randf_range(-0.12, 0.12)

	var move_dir := -vehicle.linear_velocity.normalized()
	var side_dir := wheel.global_transform.basis.x * wheel.slip_vector.x * 0.3

	var scatter := Vector3(
		randf_range(-0.4, 0.4),
		0,
		randf_range(-0.4, 0.4)
	)

	var vel := (move_dir + side_dir + scatter).normalized()
	vel *= speed * randf_range(0.15, 0.4)

	var up_force := randf_range(0.8, 2.5) + speed * randf_range(0.02, 0.08)
	up_force += slip * randf_range(0.3, 0.8)
	vel.y += up_force

	var idx1 := randi() % DIRT_COLORS.size()
	var idx2 := randi() % DIRT_COLORS.size()
	var color1 := DIRT_COLORS[idx1]
	var color2 := DIRT_COLORS[idx2]

	var brightness := randf_range(0.8, 1.2)
	color1 = Color(
		color1.r * brightness,
		color1.g * brightness,
		color1.b * brightness,
		color1.a * randf_range(0.7, 1.0)
	)

	emit_particle(t, vel, color1, color2, 5)


func _emit_spray_particle(wheel: Wheel, speed: float, intensity: float, is_rear: bool) -> void:
	var t := Transform3D.IDENTITY

	t.origin = wheel.last_collision_point
	t.origin.x += randf_range(-0.3, 0.3)
	t.origin.y += randf_range(0.03, 0.2)
	t.origin.z += randf_range(-0.25, 0.25)

	var move_dir := -vehicle.linear_velocity.normalized()
	var side := wheel.global_transform.basis.x
	var side_spread := side * randf_range(-0.8, 0.8)

	# Задние колёса — шлейф назад и вверх, передние — слабый боковой
	var up_component := 0.5 if is_rear else 0.2
	var vel := (move_dir * 0.8 + side_spread * 0.5 + Vector3(0, up_component, 0)).normalized()
	vel *= speed * randf_range(0.25, 0.6)

	# Подброс вверх
	vel.y += randf_range(1.0, 3.5) + speed * randf_range(0.02, 0.06)

	var idx := randi() % SPRAY_COLORS.size()
	var color1 := SPRAY_COLORS[idx]
	# color2 = полностью прозрачный для fade-out
	var color2 := Color(color1.r, color1.g, color1.b, 0.0)

	# Масштабируем видимость по интенсивности, но не слишком слабо
	color1.a *= clampf(0.5 + intensity * 0.5, 0.3, 1.0)

	emit_particle(t, vel, color1, color2, 5)
