extends GPUParticles3D
## Грязь из-под колёс при езде по бездорожью + брызги воды на мокрой дороге

@export var vehicle: Vehicle
@export var min_speed := 2.0  # м/с
@export var base_emission_chance := 0.9  # Базовый шанс (увеличивается при заносе)

# Глобальное значение wetness (обновляется из osm_terrain_generator)
static var current_wetness: float = 0.0

# Отдельный particle system для водяных брызг
var _spray_particles: GPUParticles3D

const OFFROAD_SURFACES := ["Grass", "Dirt"]
const ROAD_SURFACES := ["Road"]
const SPRAY_MIN_SPEED := 5.0


func _ready() -> void:
	var spray_scene := preload("res://effects/spray_effect.tscn")
	_spray_particles = spray_scene.instantiate() as GPUParticles3D
	add_child(_spray_particles)


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
			var is_left := (i % 2) == 0  # 0,2=left, 1,3=right
			var is_rear := i >= 2  # 0,1=front, 2,3=rear
			_process_spray(wheel, speed, wetness, is_rear, is_left)


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


func _process_spray(wheel: Wheel, speed: float, wetness: float, is_rear: bool, is_left: bool) -> void:
	var speed_factor := clampf((speed - SPRAY_MIN_SPEED) / 15.0, 0.0, 1.0)
	var wet_factor := clampf((wetness - 0.2) / 0.8, 0.0, 1.0)
	var intensity := speed_factor * wet_factor

	var count := clampi(int(30.0 * intensity), 2, 40)

	for j in count:
		_emit_spray_particle(wheel, speed, intensity, is_rear, is_left)


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

	emit_particle(t, vel, Color.WHITE, Color.WHITE, 5)


func _emit_spray_particle(wheel: Wheel, speed: float, intensity: float, is_rear: bool, is_left: bool) -> void:
	if not _spray_particles:
		return

	var t := Transform3D.IDENTITY
	t.origin = wheel.last_collision_point
	t.origin.x += randf_range(-0.1, 0.1)
	t.origin.y += randf_range(0.02, 0.08)
	t.origin.z += randf_range(-0.1, 0.1)

	var side_sign := -1.0 if is_left else 1.0
	var strength := speed * randf_range(0.3, 0.6)
	# Velocity в локальных координатах (spray — дочерний машины, Godot сам применяет basis)
	var vel := Vector3(side_sign * 8.0, 1.0, -8.0).normalized() * strength
	_spray_particles.emit_particle(t, vel, Color.WHITE, Color.WHITE, 5)
