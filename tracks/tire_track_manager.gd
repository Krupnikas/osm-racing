extends Node

## Менеджер грязных следов шин на траве.
## Рисует в CPU Image маску (RGBA8) вокруг машины, передаёт в ground.gdshader.
## Следы постепенно исчезают через буфер точек с временем жизни.

const MASK_SIZE := 256  # 256×256 — ~0.2м/px при 50м
const WORLD_SIZE := 50.0  # метров — квадрат вокруг машины
const PIXELS_PER_METER := MASK_SIZE / WORLD_SIZE  # ~5.12 px/m
const STAMP_RADIUS := 3  # пикселей (~0.6м диаметр следа)
const MIN_SPEED := 2.0  # м/с — минимальная скорость для следа
const STAMP_DISTANCE := 0.25  # метров между штампами
const TRACK_LIFETIME := 25.0  # секунд жизни следа
const MAX_POINTS := 5000  # макс точек в буфере (safety cap)

var _car: Node3D = null
var _material: ShaderMaterial = null
var _mask_image: Image = null
var _mask_texture: ImageTexture = null

# Буфер точек для перерисовки с fade
var _track_points: Array = []  # [{wx, wz, time, intensity}]
var _last_stamp_pos: Array[Vector3] = []  # per-wheel last stamp position
var _origin := Vector2.ZERO  # world origin of mask (top-left corner)
var _active := false


func setup(car: Node3D, material: ShaderMaterial) -> void:
	_car = car
	_material = material
	if not _car or not _material:
		return

	_mask_image = Image.create(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_RGBA8)
	_mask_image.fill(Color.BLACK)
	_mask_texture = ImageTexture.create_from_image(_mask_image)
	_material.set_shader_parameter("track_mask_tex", _mask_texture)
	_material.set_shader_parameter("track_world_size", WORLD_SIZE)

	# Инициализируем per-wheel позиции (4 колеса)
	var all_wheels: Array = _get_wheels()
	_last_stamp_pos.resize(all_wheels.size())
	for i in _last_stamp_pos.size():
		_last_stamp_pos[i] = Vector3.ZERO

	_active = true


func _process(_delta: float) -> void:
	if not _active:
		return

	var now := Time.get_ticks_msec() * 0.001

	# Убираем старые точки
	while _track_points.size() > 0 and (now - _track_points[0].time) > TRACK_LIFETIME:
		_track_points.pop_front()

	# Обновляем origin (центрируем на машине)
	var car_pos: Vector3 = _car.global_position
	_origin = Vector2(car_pos.x - WORLD_SIZE * 0.5, car_pos.z - WORLD_SIZE * 0.5)
	_material.set_shader_parameter("track_origin_world", _origin)

	# Штампуем колёса
	_stamp_wheels(now)

	# Перерисовываем маску из буфера точек
	_redraw_mask(now)

	# Upload в GPU
	_mask_texture.update(_mask_image)


func _stamp_wheels(now: float) -> void:
	var vel: Vector3 = _car.linear_velocity
	var speed: float = vel.length()
	if speed < MIN_SPEED:
		return

	var all_wheels: Array = _get_wheels()
	if all_wheels.is_empty():
		return
	# Ресайз если количество колёс изменилось
	if _last_stamp_pos.size() != all_wheels.size():
		_last_stamp_pos.resize(all_wheels.size())
		for j in _last_stamp_pos.size():
			_last_stamp_pos[j] = Vector3.ZERO
	# Интенсивность от скорости: больше скорость → ярче (до 1.0)
	var speed_factor: float = clampf((speed - MIN_SPEED) / 15.0, 0.2, 1.0)

	for i in all_wheels.size():
		var wheel: Node = all_wheels[i]
		if not wheel.is_colliding():
			continue

		# GEVP Wheel: surface_type определяется по группе collider'a
		var surface: String = wheel.surface_type if "surface_type" in wheel else ""
		if surface != "Grass":
			continue

		var wpos: Vector3 = wheel.global_position
		# Проверяем расстояние от последнего штампа
		if _last_stamp_pos[i] != Vector3.ZERO:
			var dist: float = wpos.distance_to(_last_stamp_pos[i])
			if dist < STAMP_DISTANCE:
				continue

		_last_stamp_pos[i] = wpos

		# Добавляем точку в буфер
		if _track_points.size() < MAX_POINTS:
			_track_points.append({
				"wx": wpos.x,
				"wz": wpos.z,
				"time": now,
				"intensity": speed_factor
			})


func _redraw_mask(now: float) -> void:
	# Очищаем маску
	_mask_image.fill(Color.BLACK)

	# Рисуем все живые точки
	for pt in _track_points:
		var age: float = now - pt.time
		var fade: float = 1.0 - age / TRACK_LIFETIME
		if fade <= 0.0:
			continue
		var val: float = pt.intensity * fade

		# World → pixel
		var px: int = int((pt.wx - _origin.x) * PIXELS_PER_METER)
		var py: int = int((pt.wz - _origin.y) * PIXELS_PER_METER)

		# Рисуем круг с мягкими краями
		_draw_stamp(px, py, val)


func _draw_stamp(cx: int, cy: int, intensity: float) -> void:
	var r := STAMP_RADIUS
	for dy in range(-r, r + 1):
		var iy := cy + dy
		if iy < 0 or iy >= MASK_SIZE:
			continue
		for dx in range(-r, r + 1):
			var ix := cx + dx
			if ix < 0 or ix >= MASK_SIZE:
				continue
			var dist_sq := dx * dx + dy * dy
			if dist_sq > r * r:
				continue
			# Мягкий край: от 1.0 в центре до 0.0 на краю
			var edge: float = 1.0 - sqrt(float(dist_sq)) / float(r)
			var val: float = intensity * edge
			# Max blend (не перетираем более яркие следы)
			var current: float = _mask_image.get_pixel(ix, iy).r
			if val > current:
				_mask_image.set_pixel(ix, iy, Color(val, 0.0, 0.0, 1.0))


func _get_wheels() -> Array:
	if not _car:
		return []
	# GEVP Vehicle хранит wheel_array (Array[Wheel])
	if "wheel_array" in _car:
		return _car.wheel_array
	# Fallback: VehicleBase с wheels_front/wheels_rear
	if "wheels_front" in _car:
		var wheels: Array = []
		wheels.append_array(_car.wheels_front)
		wheels.append_array(_car.wheels_rear)
		return wheels
	return []
