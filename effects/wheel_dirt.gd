extends GPUParticles3D
## Грязь из-под колёс при езде по бездорожью
## Реалистичные брызги с вариацией цвета и размера

@export var vehicle: Vehicle
@export var min_speed := 2.0  # м/с
@export var base_emission_chance := 0.9  # Базовый шанс (увеличивается при заносе)

# Палитра цветов — реалистичная грязь с примесью травы
const DIRT_COLORS: Array[Color] = [
	# Коричневые тона (основа)
	Color(0.35, 0.28, 0.18, 0.9),   # Средний коричневый
	Color(0.28, 0.22, 0.14, 0.85),  # Тёмно-коричневый
	Color(0.22, 0.18, 0.12, 0.8),   # Очень тёмный (мокрая грязь)
	Color(0.42, 0.34, 0.22, 0.9),   # Светло-коричневый

	# Оливковые/зелёные тона (трава в грязи)
	Color(0.32, 0.35, 0.20, 0.85),  # Оливково-коричневый
	Color(0.28, 0.32, 0.18, 0.8),   # Тёмно-оливковый
	Color(0.35, 0.38, 0.25, 0.85),  # Зеленовато-коричневый
	Color(0.25, 0.30, 0.18, 0.75),  # Грязно-зелёный
]

const OFFROAD_SURFACES := ["Grass", "Dirt"]


func _process(_delta: float) -> void:
	if not is_instance_valid(vehicle):
		return

	var speed := vehicle.linear_velocity.length()
	if speed < min_speed:
		return

	for wheel in vehicle.wheel_array:
		if not wheel.is_colliding():
			continue

		if wheel.surface_type not in OFFROAD_SURFACES:
			continue

		# Шанс эмиссии зависит от заноса и скорости
		var slip := wheel.slip_vector.length()
		var spin_factor := absf(wheel.spin) / 50.0  # Пробуксовка
		var emission_chance := base_emission_chance + slip * 0.15 + spin_factor * 0.1
		emission_chance = clampf(emission_chance, 0.1, 0.7)

		if randf() > emission_chance:
			continue

		# Количество частиц: 50-150, больше при заносе
		var count := clampi(50 + int(slip * 40) + int(speed / 2.0), 50, 150)

		for i in count:
			_emit_dirt_particle(wheel, speed, slip)


func _emit_dirt_particle(wheel: Wheel, speed: float, slip: float) -> void:
	var t := Transform3D.IDENTITY

	# Позиция: точка контакта + случайное смещение
	t.origin = wheel.last_collision_point
	t.origin.x += randf_range(-0.12, 0.12)
	t.origin.y += randf_range(0.02, 0.08)
	t.origin.z += randf_range(-0.12, 0.12)

	# Скорость: комбинация направления движения и бокового заноса
	var move_dir := -vehicle.linear_velocity.normalized()
	var side_dir := wheel.global_transform.basis.x * wheel.slip_vector.x * 0.3

	# Случайный разброс
	var scatter := Vector3(
		randf_range(-0.4, 0.4),
		0,
		randf_range(-0.4, 0.4)
	)

	var vel := (move_dir + side_dir + scatter).normalized()
	vel *= speed * randf_range(0.15, 0.4)

	# Подброс вверх — меньше для мелких частиц, больше для крупных
	var up_force := randf_range(0.8, 2.5) + speed * randf_range(0.02, 0.08)
	up_force += slip * randf_range(0.3, 0.8)  # Занос добавляет высоту
	vel.y += up_force

	# Случайный цвет
	var idx1 := randi() % DIRT_COLORS.size()
	var idx2 := randi() % DIRT_COLORS.size()
	var color1 := DIRT_COLORS[idx1]
	var color2 := DIRT_COLORS[idx2]

	# Вариация яркости
	var brightness := randf_range(0.8, 1.2)
	color1 = Color(
		color1.r * brightness,
		color1.g * brightness,
		color1.b * brightness,
		color1.a * randf_range(0.7, 1.0)
	)

	emit_particle(t, vel, color1, color2, 5)
