class_name RaceManager
extends Node

## Менеджер гонки: состояния, таймер, обратный отсчёт

const RaceTrackScript = preload("res://race/race_tracks.gd")

signal race_loading_started
signal race_loading_progress(progress: float, status: String)
signal race_ready  # Чанки загружены, можно начинать отсчёт
signal countdown_tick(number: int)  # 3, 2, 1
signal countdown_go  # Старт!
signal race_started
signal race_finished(time: float)
signal race_cancelled

enum State { IDLE, LOADING, COUNTDOWN, RACING, FINISHED }

var current_state := State.IDLE
var race_time := 0.0
var current_track  # RaceTrack

@export var terrain_generator_path: NodePath
@export var car_path: NodePath
@export var camera_path: NodePath

var _terrain_generator: Node3D
var _car: Node3D
var _car_rigidbody: RigidBody3D
var _camera: Camera3D
var _finish_line: Area3D
var _countdown_timer: float = 0.0
var _countdown_current: int = 0


func _ready() -> void:
	await get_tree().process_frame

	if terrain_generator_path:
		_terrain_generator = get_node_or_null(terrain_generator_path)
	if car_path:
		_car = get_node_or_null(car_path)
		_car_rigidbody = _car if _car is RigidBody3D else null
	if camera_path:
		_camera = get_node_or_null(camera_path)


func _process(delta: float) -> void:
	match current_state:
		State.COUNTDOWN:
			_process_countdown(delta)
		State.RACING:
			race_time += delta


func _process_countdown(delta: float) -> void:
	_countdown_timer -= delta
	if _countdown_timer <= 0:
		if _countdown_current > 0:
			_countdown_current -= 1
			_countdown_timer = 1.0
			if _countdown_current > 0:
				countdown_tick.emit(_countdown_current)
			else:
				# GO!
				countdown_go.emit()
				_start_racing()
		else:
			_start_racing()


func start_race(track) -> void:
	"""Запустить гонку на указанной трассе"""
	if current_state != State.IDLE:
		print("RaceManager: Cannot start race - already in state ", State.keys()[current_state])
		return

	current_track = track
	race_time = 0.0
	current_state = State.LOADING
	race_loading_started.emit()

	print("RaceManager: Starting race on track '%s'" % track.track_name)

	# ВАЖНО: Перемещаем машину на старт ДО загрузки terrain
	# Это нужно чтобы terrain_generator загрузил чанки вокруг старта, а не финиша
	var start_pos := _latlon_to_local(track.start_lat, track.start_lon)
	start_pos.y = 0.5
	if _car:
		_car.global_position = start_pos
		_car.visible = false
	if _car_rigidbody:
		_car_rigidbody.freeze = true
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO

	# Ждём загрузку чанков (используем сигнал от terrain_generator)
	if _terrain_generator:
		# Отключаем старые соединения и подключаем заново (для чистого состояния)
		if _terrain_generator.initial_load_progress.is_connected(_on_load_progress):
			_terrain_generator.initial_load_progress.disconnect(_on_load_progress)
		if _terrain_generator.initial_load_complete.is_connected(_on_load_complete):
			_terrain_generator.initial_load_complete.disconnect(_on_load_complete)

		_terrain_generator.initial_load_progress.connect(_on_load_progress)
		_terrain_generator.initial_load_complete.connect(_on_load_complete)

		# Запускаем загрузку с координат старта
		_terrain_generator.start_lat = track.start_lat
		_terrain_generator.start_lon = track.start_lon
		_terrain_generator.reset_terrain()
		# Даём кадр на сброс состояния перед загрузкой
		await get_tree().process_frame
		_terrain_generator.start_loading()
	else:
		# Нет генератора - сразу готовы
		_on_race_ready()


func _on_load_progress(progress: float, status: String) -> void:
	if current_state == State.LOADING:
		race_loading_progress.emit(progress, status)


func _on_load_complete() -> void:
	if current_state == State.LOADING:
		_on_race_ready()


func _on_race_ready() -> void:
	"""Загрузка завершена, спавним машину и начинаем обратный отсчёт"""
	print("RaceManager: Race ready, spawning car")

	# Теперь дороги загружены - спавним машину на ближайшей дороге
	_spawn_car_at_start()

	# Ждём физический кадр чтобы позиция применилась
	await get_tree().physics_frame

	# Проверяем что машина на правильной высоте (защита от багов)
	if _car and _car.global_position.y > 10.0:
		print("RaceManager: WARNING - Car at height %.1f, correcting to 0.5" % _car.global_position.y)
		var pos := _car.global_position
		pos.y = 0.5
		_car.global_position = pos

	# Создаём финишную линию
	_create_finish_line()

	race_ready.emit()

	# Небольшая пауза перед отсчётом
	await get_tree().create_timer(0.5).timeout

	# Запускаем обратный отсчёт
	_start_countdown()


func _start_countdown() -> void:
	"""Начать обратный отсчёт 3-2-1"""
	current_state = State.COUNTDOWN
	_countdown_current = 3
	_countdown_timer = 1.0
	countdown_tick.emit(3)


func _start_racing() -> void:
	"""Начать гонку после отсчёта"""
	print("RaceManager: GO!")
	current_state = State.RACING
	race_time = 0.0

	# Сохраняем позицию и поворот перед размораживанием
	var saved_pos := _car.global_position if _car else Vector3.ZERO
	var saved_rot := _car.global_rotation if _car else Vector3.ZERO

	print("RaceManager: BEFORE unfreeze - Y=%.2f, vel=%.2f" % [_car.global_position.y, _car_rigidbody.linear_velocity.length() if _car_rigidbody else 0])

	# Сбрасываем состояние GEVP прямо перед unfreeze
	_reset_vehicle_physics_state()

	# Размораживаем машину
	if _car_rigidbody:
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO
		_car_rigidbody.freeze = false

	print("RaceManager: AFTER unfreeze (same frame) - Y=%.2f" % _car.global_position.y)

	# Ждём физический кадр
	await get_tree().physics_frame
	print("RaceManager: AFTER 1 physics frame - Y=%.2f, vel_y=%.2f" % [_car.global_position.y, _car_rigidbody.linear_velocity.y if _car_rigidbody else 0])

	# Ещё один кадр
	await get_tree().physics_frame
	print("RaceManager: AFTER 2 physics frames - Y=%.2f, vel_y=%.2f" % [_car.global_position.y, _car_rigidbody.linear_velocity.y if _car_rigidbody else 0])

	# После разморозки снова устанавливаем позицию и обнуляем скорости
	if _car:
		_car.global_position = saved_pos
		_car.global_rotation = saved_rot
	if _car_rigidbody:
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO

	print("RaceManager: AFTER reset - Y=%.2f" % _car.global_position.y)
	race_started.emit()


func _spawn_car_at_start() -> void:
	"""Переместить машину на старт трассы (на ближайшую дорогу)"""
	if not _car or not current_track:
		return

	# Конвертируем lat/lon в локальные координаты
	var start_pos := _latlon_to_local(current_track.start_lat, current_track.start_lon)
	var finish_pos := _latlon_to_local(current_track.finish_lat, current_track.finish_lon)

	# Ищем ближайшую дорогу через TrafficManager
	var traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
	if traffic_manager and traffic_manager.has_method("get_road_network"):
		var road_network = traffic_manager.get_road_network()
		if road_network and not road_network.all_waypoints.is_empty():
			var nearest_wp = road_network.get_nearest_waypoint(start_pos)
			if nearest_wp:
				start_pos = nearest_wp.position
				print("RaceManager: Found road waypoint near start at Y=%.1f" % nearest_wp.position.y)

	# Поднимаем машину над дорогой
	start_pos.y = 0.5

	# Сбрасываем физику машины перед спавном
	if _car_rigidbody:
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO
		_car_rigidbody.linear_damp = 0.0  # Сброс демпфирования после финиша
		_car_rigidbody.freeze = true
		# Сбрасываем тормоза
		if _car_rigidbody.get("handbrake") != null:
			_car_rigidbody.handbrake = 0.0
		if _car_rigidbody.get("brake") != null:
			_car_rigidbody.brake = 0.0

	# Поворачиваем машину к финишу (перед машины смотрит в -Z)
	var dir := finish_pos - start_pos
	dir.y = 0
	var yaw := 0.0
	if dir.length_squared() > 0.01:
		yaw = atan2(dir.x, dir.z) + PI

	# Устанавливаем позицию и поворот через transform (надёжнее для RigidBody3D)
	var new_transform := Transform3D()
	new_transform.origin = start_pos
	new_transform.basis = Basis(Vector3.UP, yaw)
	_car.global_transform = new_transform

	# Показываем машину
	_car.visible = true

	# КРИТИЧЕСКИ ВАЖНО: Сбрасываем внутреннее состояние GEVP после телепортации!
	# Иначе GEVP рассчитает "скорость" как разницу между старой и новой позицией
	# и получит безумные значения, что приведёт к взлёту машины
	_reset_vehicle_physics_state()

	# Телепортируем камеру к машине (иначе она будет медленно лететь от финиша)
	if _camera and _camera.has_method("teleport_to_target"):
		_camera.teleport_to_target()

	print("RaceManager: Car spawned at start (%.1f, %.1f, %.1f), target Y=0.5" % [
		_car.global_position.x, _car.global_position.y, _car.global_position.z
	])


func _create_finish_line() -> void:
	"""Создать финишную линию на конечной точке"""
	if not current_track:
		return

	# Удаляем старую финишную линию если есть
	if _finish_line:
		_finish_line.queue_free()
		_finish_line = null

	# Конвертируем координаты
	var finish_pos := _latlon_to_local(current_track.finish_lat, current_track.finish_lon)
	var start_pos := _latlon_to_local(current_track.start_lat, current_track.start_lon)

	# Создаём Area3D
	_finish_line = Area3D.new()
	_finish_line.name = "FinishLine"

	# Создаём коллизию (широкая полоса поперёк дороги) - поднята для детекции машины
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(20.0, 4.0, 2.0)  # Широкая, высокая, тонкая
	collision.shape = shape
	collision.position = Vector3(0, 1.5, 0)  # Коллизия выше земли для детекции
	_finish_line.add_child(collision)

	# Создаём визуальную финишную линию - шахматка в два ряда
	var square_size := 1.0  # Размер одного квадрата
	var num_squares_x := 12  # Количество квадратов по ширине
	var num_squares_z := 2   # Два ряда

	for ix in range(num_squares_x):
		for iz in range(num_squares_z):
			var is_white := (ix + iz) % 2 == 0
			var square := MeshInstance3D.new()
			var square_mesh := BoxMesh.new()
			square_mesh.size = Vector3(square_size, 0.05, square_size)
			square.mesh = square_mesh

			var mat := StandardMaterial3D.new()
			if is_white:
				mat.albedo_color = Color.WHITE
				mat.emission_enabled = true
				mat.emission = Color(1, 1, 1, 1)
				mat.emission_energy_multiplier = 0.3
			else:
				mat.albedo_color = Color.BLACK
			square.material_override = mat

			# Позиция квадрата (центрируем по X и Z)
			var x_pos := (ix - num_squares_x / 2.0 + 0.5) * square_size
			var z_pos := (iz - num_squares_z / 2.0 + 0.5) * square_size
			square.position = Vector3(x_pos, 0.15, z_pos)
			_finish_line.add_child(square)

	# Добавляем вертикальные столбы по краям
	for side in [-1, 1]:
		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.15
		pole_mesh.bottom_radius = 0.15
		pole_mesh.height = 4.0
		pole.mesh = pole_mesh
		var pole_mat := StandardMaterial3D.new()
		pole_mat.albedo_color = Color(1, 0.2, 0.2)
		pole_mat.emission_enabled = true
		pole_mat.emission = Color(1, 0.2, 0.2)
		pole_mat.emission_energy_multiplier = 0.3
		pole.material_override = pole_mat
		pole.position = Vector3(side * 6.5, 2.0, 0)  # Столбы от земли вверх
		_finish_line.add_child(pole)

	# Позиция и ориентация - используем высоту дороги
	_finish_line.global_position = finish_pos

	# Поворачиваем перпендикулярно направлению движения
	var dir := finish_pos - start_pos
	dir.y = 0
	if dir.length_squared() > 0.01:
		var yaw := atan2(dir.x, dir.z)
		_finish_line.rotation = Vector3(0, yaw, 0)

	# Подключаем сигнал
	_finish_line.body_entered.connect(_on_finish_line_entered)

	# Добавляем в сцену
	add_child(_finish_line)

	print("RaceManager: Finish line created at (%.1f, %.1f, %.1f)" % [
		finish_pos.x, finish_pos.y, finish_pos.z
	])


func _on_finish_line_entered(body: Node3D) -> void:
	"""Машина пересекла финишную линию"""
	if current_state != State.RACING:
		return

	# Проверяем что это наша машина
	if body == _car or body == _car_rigidbody:
		_finish_race()


func _finish_race() -> void:
	"""Завершить гонку"""
	print("RaceManager: FINISH! Time: %.2f seconds" % race_time)
	current_state = State.FINISHED

	# Автоматическое торможение (ручной тормоз)
	if _car_rigidbody:
		# Для GEVP Vehicle - устанавливаем ручной тормоз
		if _car_rigidbody.has_method("set"):
			if _car_rigidbody.get("handbrake") != null:
				_car_rigidbody.handbrake = 1.0
			elif _car_rigidbody.get("brake") != null:
				_car_rigidbody.brake = 1.0
		# Замедляем машину
		_car_rigidbody.linear_damp = 3.0

	race_finished.emit(race_time)


func cancel_race() -> void:
	"""Отменить гонку и вернуться в IDLE"""
	if current_state == State.IDLE:
		return

	print("RaceManager: Race cancelled")

	# Удаляем финишную линию
	if _finish_line:
		_finish_line.queue_free()
		_finish_line = null

	current_state = State.IDLE
	race_cancelled.emit()


func reset() -> void:
	"""Сбросить состояние для новой гонки"""
	cancel_race()
	current_track = null
	race_time = 0.0


func get_formatted_time() -> String:
	"""Получить время в формате MM:SS.ms"""
	var minutes := int(race_time) / 60
	var seconds := int(race_time) % 60
	var ms := int((race_time - int(race_time)) * 100)
	return "%02d:%02d.%02d" % [minutes, seconds, ms]


func _reset_vehicle_physics_state() -> void:
	"""Сбросить внутреннее состояние GEVP Vehicle после телепортации.
	Это критически важно! GEVP рассчитывает скорость как разницу позиций между кадрами.
	После телепортации previous_global_position указывает на старую позицию,
	и GEVP думает что машина пролетела сотни метров за один кадр."""

	if not _car_rigidbody:
		return

	var current_pos := _car.global_position

	# Сбрасываем состояние Vehicle (GEVP)
	if _car_rigidbody.get("previous_global_position") != null:
		_car_rigidbody.previous_global_position = current_pos
		print("RaceManager: Reset vehicle previous_global_position")

	if _car_rigidbody.get("local_velocity") != null:
		_car_rigidbody.local_velocity = Vector3.ZERO

	if _car_rigidbody.get("motor_rpm") != null and _car_rigidbody.get("idle_rpm") != null:
		_car_rigidbody.motor_rpm = _car_rigidbody.idle_rpm

	if _car_rigidbody.get("current_gear") != null:
		_car_rigidbody.current_gear = 0

	if _car_rigidbody.get("throttle_amount") != null:
		_car_rigidbody.throttle_amount = 0.0
	if _car_rigidbody.get("brake_amount") != null:
		_car_rigidbody.brake_amount = 0.0
	if _car_rigidbody.get("steering_amount") != null:
		_car_rigidbody.steering_amount = 0.0
	if _car_rigidbody.get("clutch_amount") != null:
		_car_rigidbody.clutch_amount = 0.0

	# Сбрасываем состояние всех колёс
	var wheels: Array = []
	if _car_rigidbody.get("wheel_array") != null:
		wheels = _car_rigidbody.wheel_array
	elif _car_rigidbody.get("front_left_wheel") != null:
		# Собираем колёса вручную
		if _car_rigidbody.front_left_wheel:
			wheels.append(_car_rigidbody.front_left_wheel)
		if _car_rigidbody.front_right_wheel:
			wheels.append(_car_rigidbody.front_right_wheel)
		if _car_rigidbody.rear_left_wheel:
			wheels.append(_car_rigidbody.rear_left_wheel)
		if _car_rigidbody.rear_right_wheel:
			wheels.append(_car_rigidbody.rear_right_wheel)

	for wheel in wheels:
		if wheel == null:
			continue

		# Сбрасываем previous_global_position колеса
		if wheel.get("previous_global_position") != null:
			wheel.previous_global_position = wheel.global_position

		# Сбрасываем скорости колеса
		if wheel.get("local_velocity") != null:
			wheel.local_velocity = Vector3.ZERO
		if wheel.get("previous_velocity") != null:
			wheel.previous_velocity = Vector3.ZERO

		# Сбрасываем вращение колеса
		if wheel.get("spin") != null:
			wheel.spin = 0.0

		# Сбрасываем сжатие подвески
		if wheel.get("previous_compression") != null:
			wheel.previous_compression = 0.0

		# Сбрасываем силы
		if wheel.get("force_vector") != null:
			wheel.force_vector = Vector2.ZERO
		if wheel.get("slip_vector") != null:
			wheel.slip_vector = Vector2.ZERO

	print("RaceManager: Reset GEVP physics state for %d wheels" % wheels.size())


func _latlon_to_local(lat: float, lon: float) -> Vector3:
	"""Конвертировать GPS координаты в локальные (используем terrain_generator)"""
	if _terrain_generator and _terrain_generator.has_method("_latlon_to_local"):
		var pos2d = _terrain_generator._latlon_to_local(lat, lon)
		return Vector3(pos2d.x, 0, pos2d.y)  # Vector2 -> Vector3

	# Fallback: простая конвертация
	# 1 градус широты ≈ 111 км
	# 1 градус долготы ≈ 111 км * cos(lat)
	var ref_lat := 59.15  # Череповец
	var ref_lon := 37.95

	var lat_diff := lat - ref_lat
	var lon_diff := lon - ref_lon

	var z := -lat_diff * 111000.0
	var x := lon_diff * 111000.0 * cos(deg_to_rad(lat))

	return Vector3(x, 0, z)
