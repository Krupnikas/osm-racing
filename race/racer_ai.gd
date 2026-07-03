extends VehicleBase
class_name RacerAI

## AI-контроллер для соперников в гоночном режиме
## Наследует VehicleBase для единой физики с игроком
## Использует Pure Pursuit steering для следования по маршруту

enum AIState { FROZEN, RACING, RECOVERING, FINISHED }

# Маршрут гонки
var race_route: RaceRoute
var race_progress: float = 0.0  # Дистанция от старта (метры)
var race_position: int = 0      # Место в гонке (1, 2, 3...)
var current_segment_idx: int = 0  # Текущий сегмент маршрута

# Состояние AI
var ai_state := AIState.FROZEN
var target_speed: float = 50.0  # Целевая скорость в км/ч

# Параметры AI (для вариативности поведения)
@export var skill_level: float = 0.8      # 0.5-1.0, влияет на точность
@export var aggression: float = 0.5       # 0.0-1.0, влияет на скорость в поворотах
@export var racer_name: String = "AI"     # Имя для UI

# Константы Pure Pursuit (v1.1: геометрически корректная велосипедная модель)
const LOOKAHEAD_MIN := 18.0  # v1.1: поднят с 12 — короткий lookahead провоцировал рысканье
const LOOKAHEAD_MAX := 38.0  # v1.1: поднят с 35
const BRAKE_DISTANCE := 35.0  # Увеличено для раннего обнаружения
const UPDATE_INTERVAL := 0.05  # 50ms - более частое обновление
const CORRIDOR_WIDTH := 7.0  # Ширина коридора (совпадает с RaceBarriers.BARRIER_OFFSET)

# v1.1 pure-pursuit / rate-limit / телеметрия
const MIN_TURN_L := 6.0           # м — нижний предел евклидова расстояния до цели (защита от 1/L→∞)
const MAX_STEER_RATE := 6.0       # ед/с — мягкое ограничение скорости изменения команды руля
const WHEELBASE_FALLBACK := 2.5   # м — если колёса не собрались
const LOOKAHEAD_MAX_RATE := 4.0   # м/тик — плавное изменение lookahead (убирает скачки цели)
const DEBUG_SAMPLES_CAP := 1200   # ~60 с при 20 Гц

# Восстановление после застревания
var stuck_timer: float = 0.0
var recovery_timer: float = 0.0
var recovery_attempts: int = 0
const STUCK_THRESHOLD := 3.0        # Секунд без движения
const STUCK_SPEED := 3.0            # км/ч - считаем застрявшим
const RECOVERY_REVERSE_TIME := 2.0  # Секунд ехать назад
const MAX_RECOVERY_ATTEMPTS := 3    # После этого - респавн

# Raycast для obstacle detection
var obstacle_check_ray: RayCast3D

# Внутренние переменные
var update_timer := 0.0

# v1.1 pure-pursuit состояние
var wheelbase := 2.5              # измеряется в _ready из локальных Z позиций колёс
var _lookahead_dist := 18.0       # текущий (сглаженный между тиками) lookahead, м
var _cur_lateral_offset := 0.0    # боковое смещение от осевой (проекция текущего тика)
var _cur_proj_distance := 0.0     # арк-дистанция проекции текущего тика (для edge-guard)
var _last_obstacle_active := false  # сработал ли луч объезда в этом тике (для телеметрии)

# Телеметрия (off by default — нулевая стоимость в обычной игре; включает тест-сцена)
var ai_debug := false
var debug_target_point: Vector3 = Vector3.ZERO
var _debug_samples: Array = []
var _debug_sections: Array = []   # [{name, start_m, end_m}]
var _debug_t := 0.0               # аккумулятор времени (детерминированно, без Time/Date)
var _recovery_count := 0
# Цвета для рандомизации
const RACER_COLORS := [
	Color(0.9, 0.1, 0.1),   # Красный
	Color(0.1, 0.4, 0.9),   # Синий
	Color(0.1, 0.8, 0.2),   # Зелёный
	Color(0.9, 0.6, 0.1),   # Оранжевый
	Color(0.7, 0.1, 0.9),   # Фиолетовый
	Color(0.1, 0.9, 0.9),   # Бирюзовый
	Color(0.9, 0.9, 0.1),   # Жёлтый
	Color(0.9, 0.3, 0.6),   # Розовый
]


func _ready() -> void:
	super._ready()

	# Настраиваем привод (AWD для лучшего контроля)
	for wheel in wheels_front:
		wheel.use_as_traction = true
	for wheel in wheels_rear:
		wheel.use_as_traction = true

	# Колёсная база из локальных Z-позиций колёс (велосипедная модель pure pursuit)
	wheelbase = WHEELBASE_FALLBACK
	if not wheels_front.is_empty() and not wheels_rear.is_empty():
		var fz := 0.0
		for w in wheels_front:
			fz += w.position.z
		fz /= wheels_front.size()
		var rz := 0.0
		for w in wheels_rear:
			rz += w.position.z
		rz /= wheels_rear.size()
		wheelbase = maxf(0.5, absf(fz - rz))

	# Создаём raycast для obstacle detection
	# Layer 1 = Player (bit 0 = 1)
	# Layer 2 = Buildings (bit 1 = 2)
	# Layer 3 = Terrain (bit 2 = 4)
	# Layer 4 = NPCTraffic (bit 3 = 8)
	# Layer 8 = RaceOpponents (bit 7 = 128) - НЕ включаем (гонка!)
	obstacle_check_ray = RayCast3D.new()
	obstacle_check_ray.enabled = true
	obstacle_check_ray.collision_mask = 2 | 8  # Здания (2) и NPC трафик (8), не соперники
	obstacle_check_ray.hit_from_inside = false
	add_child(obstacle_check_ray)

	# Добавляем в группу для идентификации
	add_to_group("race_opponent")

	# Рандомизируем параметры AI для вариативности
	skill_level = randf_range(0.85, 1.0)
	aggression = randf_range(0.5, 0.9)
	target_speed = randf_range(70.0, 90.0)


func _physics_process(delta: float) -> void:
	match ai_state:
		AIState.FROZEN:
			# Заморожены до старта - ничего не делаем
			throttle_input = 0.0
			brake_input = 1.0
			steering_input = 0.0

		AIState.RACING:
			# Обновляем AI с интервалом
			update_timer += delta
			if update_timer >= UPDATE_INTERVAL:
				update_timer = 0.0
				_update_ai_driver()

			# Проверяем застревание
			_check_stuck(delta)

		AIState.RECOVERING:
			# Выполняем восстановление
			_execute_recovery(delta)

		AIState.FINISHED:
			# Финишировали - тормозим
			throttle_input = 0.0
			brake_input = 0.5
			steering_input = 0.0

	# Вызываем базовую физику
	_base_physics_process(delta)


# ===== ПУБЛИЧНЫЕ МЕТОДЫ =====

func set_race_route(route: RaceRoute) -> void:
	"""Устанавливает маршрут гонки"""
	race_route = route
	race_progress = 0.0
	current_segment_idx = 0


func freeze_for_countdown() -> void:
	"""Замораживает машину для обратного отсчёта"""
	ai_state = AIState.FROZEN
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func start_racing() -> void:
	"""Начинает гонку"""
	ai_state = AIState.RACING
	freeze = false
	stuck_timer = 0.0
	recovery_attempts = 0

	# Инициализируем начальную позицию на маршруте
	# Это критично - без этого AI застрянет с progress=0
	if race_route:
		var projection := race_route.project_position(global_position, 0)
		current_segment_idx = projection.segment_idx
		race_progress = projection.distance


func finish_race() -> void:
	"""Завершает гонку для этого AI"""
	ai_state = AIState.FINISHED


func get_race_progress() -> float:
	"""Возвращает прогресс по маршруту (дистанция от старта)"""
	return race_progress


# ===== ТЕЛЕМЕТРИЯ (off by default; включается тест-сценой ai_test_scene.gd) =====

func set_debug_sections(sections: Array) -> void:
	"""Секции для побиновой статистики: [{name, start_m, end_m}]."""
	_debug_sections = sections


func clear_debug_samples() -> void:
	"""Сбрасывает кольцевой буфер телеметрии перед новым прогоном."""
	_debug_samples.clear()
	_debug_t = 0.0
	_recovery_count = 0


func get_debug_samples() -> Array:
	"""Сырые сэмплы (для построения графиков)."""
	return _debug_samples


func _record_debug_sample(heading_error: float, steer_raw: float, corridor_active: bool) -> void:
	_debug_t += UPDATE_INTERVAL
	_debug_samples.append({
		"t": _debug_t,
		"pos": global_position,
		"race_progress": race_progress,
		"segment_idx": current_segment_idx,
		"lateral_offset": _cur_lateral_offset,
		"lookahead_dist": _lookahead_dist,
		"target_point": debug_target_point,
		"heading_error_rad": heading_error,
		"steer_raw": steer_raw,
		"steer_cmd": steering_input,
		"speed_kmh": current_speed_kmh,
		"throttle": throttle_input,
		"brake": brake_input,
		"corridor_active": corridor_active,
		"obstacle_active": _last_obstacle_active,
		"recovery_active": ai_state == AIState.RECOVERING,
	})
	if _debug_samples.size() > DEBUG_SAMPLES_CAP:
		_debug_samples.pop_front()


func _metric_block(samples: Array) -> Dictionary:
	"""Единый блок метрик по подмножеству сэмплов (глобально и по секциям)."""
	var n := samples.size()
	if n == 0:
		return {"sample_count": 0}
	var lat_min := INF
	var lat_max := -INF
	var steer_min := INF
	var steer_max := -INF
	var speed_sum := 0.0
	var speed_min := INF
	var sign_changes := 0
	var saturations := 0
	var corridor_hits := 0
	var obstacle_hits := 0
	var last_sign := 0
	for s in samples:
		var lat: float = s["lateral_offset"]
		lat_min = minf(lat_min, lat)
		lat_max = maxf(lat_max, lat)
		var st: float = s["steer_cmd"]
		steer_min = minf(steer_min, st)
		steer_max = maxf(steer_max, st)
		if absf(st) >= 0.98:
			saturations += 1
		if absf(st) > 0.02:
			var sg := 1 if st > 0.0 else -1
			if last_sign != 0 and sg != last_sign:
				sign_changes += 1
			last_sign = sg
		var sp: float = s["speed_kmh"]
		speed_sum += sp
		speed_min = minf(speed_min, sp)
		if bool(s["corridor_active"]):
			corridor_hits += 1
		if bool(s.get("obstacle_active", false)):
			obstacle_hits += 1
	var first_prog: float = samples[0]["race_progress"]
	var last_prog: float = samples[n - 1]["race_progress"]
	return {
		"sample_count": n,
		"lateral_p2p": lat_max - lat_min,
		"lateral_abs_max": maxf(absf(lat_min), absf(lat_max)),
		"steer_p2p": steer_max - steer_min,
		"steer_sign_changes": sign_changes,
		"steer_saturations": saturations,
		"avg_speed_kmh": speed_sum / float(n),
		"min_speed_kmh": speed_min,
		"distance_covered": last_prog - first_prog,
		"corridor_active_frac": float(corridor_hits) / float(n),
		"obstacle_active_frac": float(obstacle_hits) / float(n),
	}


func get_debug_summary() -> Dictionary:
	"""Глобальный блок метрик + прогресс/восстановления/длительность + блок на каждую секцию."""
	var g := _metric_block(_debug_samples)
	var total: float = race_route.total_length if race_route else 0.0
	g["progress_percent"] = (100.0 * race_progress / total) if total > 0.0 else 0.0
	g["recovery_count"] = _recovery_count
	g["duration_s"] = _debug_t
	var sec_out := {}
	for sec in _debug_sections:
		var sec_name: String = sec["name"]
		var sm: float = sec["start_m"]
		var em: float = sec["end_m"]
		var subset: Array = []
		for s in _debug_samples:
			var rp: float = s["race_progress"]
			if rp >= sm and rp < em:
				subset.append(s)
		sec_out[sec_name] = _metric_block(subset)
	return {"global": g, "sections": sec_out}


# ===== РЕАЛИЗАЦИЯ АБСТРАКТНЫХ МЕТОДОВ VehicleBase =====

func _get_steering_input() -> float:
	return steering_input


func _get_throttle_input() -> float:
	return throttle_input


func _get_brake_input() -> float:
	return brake_input


# ===== AI ЛОГИКА =====

func _update_ai_driver() -> void:
	"""Основная логика AI водителя (v1.1: геометрически корректный pure pursuit).
	Заменяет старый P-регулятор с фиксированным усилением 2.5, который слэмил руль в
	упор и давал предельный цикл (видимую синусоиду). См. docs/RACER_AI_V1_1_PLAN.md."""
	if not race_route or race_route.points.is_empty():
		throttle_input = 0.0
		brake_input = 1.0
		steering_input = 0.0
		return

	# Обновляем прогресс по маршруту (только вперёд!) + кэшируем проекцию этого тика
	_update_race_progress()

	# Проверяем финиш
	if race_route.is_finished(race_progress):
		finish_race()
		return

	# Крутизна поворота впереди — считаем один раз, используем и для lookahead, и для скорости
	var turn_sharpness := _get_turn_sharpness_ahead()

	# Адаптивный lookahead: растёт со скоростью, но КОРОЧЕ в крутых поворотах (иначе длинный
	# lookahead срезает угол и уводит широко — ключевой второй шаг из §R). Плавно, без скачков.
	var speed_factor: float = clamp(current_speed_kmh / 80.0, 0.0, 1.0)
	var lookahead_target: float = lerp(LOOKAHEAD_MIN, LOOKAHEAD_MAX, speed_factor) * lerp(1.0, 0.55, turn_sharpness)
	_lookahead_dist = move_toward(_lookahead_dist, lookahead_target, LOOKAHEAD_MAX_RATE)

	var lookahead_point: Vector3 = race_route.get_lookahead_point(race_progress, _lookahead_dist)

	# --- Pure pursuit (велосипедная модель) ---
	var steer_raw := 0.0
	var heading_error := 0.0
	if lookahead_point != Vector3.ZERO:
		var to_target := lookahead_point - global_position
		var to_target_flat := Vector3(to_target.x, 0, to_target.z).normalized()
		var forward := -global_transform.basis.z
		var forward_flat := Vector3(forward.x, 0, forward.z).normalized()

		# sin(угла курс→цель); знак совпадает со старым lateral_error (проверяем визуально)
		var sin_alpha: float = to_target_flat.cross(forward_flat).y
		var cos_alpha: float = clampf(forward_flat.dot(to_target_flat), -1.0, 1.0)
		heading_error = atan2(sin_alpha, cos_alpha)

		# Евклидово расстояние до цели: само гасит завышение усиления при сходе с линии
		var l_dist: float = maxf(MIN_TURN_L, Vector3(to_target.x, 0, to_target.z).length())
		# Кривизна pure pursuit → требуемый угол колёс (велосипедная модель) → нормировка в [-1,1]
		var kappa: float = 2.0 * sin_alpha / l_dist
		var delta_angle: float = atan(wheelbase * kappa)
		steer_raw = clampf(delta_angle / deg_to_rad(max_steering_angle), -1.0, 1.0)

	if ai_debug:
		debug_target_point = lookahead_point

	# Мягкое ограничение скорости команды руля (НЕ низкочастотный фильтр — актуатор уже даёт лаг)
	steering_input = move_toward(steering_input, steer_raw, MAX_STEER_RATE * UPDATE_INTERVAL)

	# Проверка препятствий и расчёт объезда (Craig Reynolds) — без изменений
	var obstacle_data := _check_obstacle_ahead()
	_last_obstacle_active = obstacle_data.detected

	if obstacle_data.detected:
		if obstacle_data.urgency > 0.6:
			# Здание/стена близко — жёсткий override, полностью уходим от препятствия
			steering_input = obstacle_data.avoidance_steering
			throttle_input = 0.3
			brake_input = 0.4
		else:
			# Далёкое препятствие — плавный blend
			var blend_factor: float = 0.3 + obstacle_data.urgency * 0.5
			steering_input = lerp(steering_input, obstacle_data.avoidance_steering, blend_factor)
			steering_input = clamp(steering_input, -1.0, 1.0)

			# Притормаживаем пропорционально urgency
			if obstacle_data.urgency > 0.3:
				throttle_input = lerp(0.7, 0.3, obstacle_data.urgency)
				brake_input = lerp(0.05, 0.3, obstacle_data.urgency)

	# Коридор — теперь ТОЛЬКО edge-guard у самого барьера (не второй регулятор на осевой)
	var corridor_active := false
	if not obstacle_data.detected:
		var corridor_correction := _calculate_corridor_correction()
		if absf(corridor_correction) > 0.0001:
			corridor_active = true
		steering_input = clamp(steering_input + corridor_correction, -1.0, 1.0)

	# Безопасная скорость для поворота
	# aggression влияет на то, как сильно замедляемся (выше = меньше торможение)
	var safe_speed := target_speed
	if turn_sharpness > 0.4:
		safe_speed = target_speed * lerp(0.85, 0.95, aggression)
	if turn_sharpness > 0.7:
		safe_speed = target_speed * lerp(0.65, 0.8, aggression)
	if turn_sharpness > 0.9:
		safe_speed = target_speed * lerp(0.5, 0.65, aggression)

	# Если нет критического препятствия, применяем нормальный контроль скорости
	if not obstacle_data.detected or obstacle_data.urgency <= 0.7:
		var speed_error: float = safe_speed - current_speed_kmh

		if speed_error < -10.0:
			# Сильно превышаем - тормозим
			throttle_input = 0.0
			brake_input = clamp(-speed_error / 30.0, 0.2, 0.6)
		elif speed_error < 0.0:
			# Немного превышаем - отпускаем газ
			throttle_input = 0.1
			brake_input = 0.0
		else:
			# Ускоряемся агрессивно
			throttle_input = clamp(speed_error / 8.0, 0.3, 1.0)
			brake_input = 0.0

	# Телеметрия (только когда включена тест-сценой)
	if ai_debug:
		_record_debug_sample(heading_error, steer_raw, corridor_active)


func _update_race_progress() -> void:
	"""Обновляет прогресс по маршруту (только вперёд!) и кэширует проекцию тика."""
	if not race_route:
		return

	# Проецируем позицию на маршрут, начиная от текущего сегмента (ОДНА проекция на тик)
	var projection := race_route.project_position(global_position, current_segment_idx)

	# Кэшируем боковое смещение и арк-дистанцию для edge-guard + телеметрии
	_cur_lateral_offset = projection.lateral_offset
	_cur_proj_distance = projection.distance

	# Обновляем только если прогресс увеличился (НЕ возвращаемся)
	if projection.distance > race_progress:
		race_progress = projection.distance
		current_segment_idx = projection.segment_idx


func _get_turn_sharpness_ahead() -> float:
	"""Определяет крутизну поворота впереди (0.0 = прямо, 1.0 = разворот)"""
	if not race_route or race_route.points.size() < 2:
		return 0.0

	var forward := -global_transform.basis.z
	var forward_flat := Vector3(forward.x, 0, forward.z).normalized()

	var max_angle := 0.0

	# Смотрим на 30м вперёд
	var check_distances := [10.0, 20.0, 30.0]
	for dist in check_distances:
		var point_data := race_route.get_point_at_distance(race_progress + dist)
		var point_dir := Vector3(point_data.direction.x, 0, point_data.direction.z).normalized()

		if point_dir.length() > 0.1:
			var angle := forward_flat.angle_to(point_dir)
			max_angle = max(max_angle, angle)

	# Нормализуем угол к [0..1] (90° = 1.0)
	return clamp(max_angle / (PI / 2.0), 0.0, 1.0)


func _calculate_corridor_correction() -> float:
	"""v1.1 EDGE-GUARD: молчит в середине дороги (pure pursuit уже целится в осевую),
	включается лишь у самого барьера (>0.7·ширины). Переиспользует проекцию текущего
	тика (без второго project_position). Слабый вклад (≤0.25), чтобы не искажать линию."""
	if not race_route:
		return 0.0

	var lateral_dist: float = _cur_lateral_offset  # из проекции этого тика (всегда ≥ 0)
	var threshold := CORRIDOR_WIDTH * 0.7          # ~4.9 м из ±7 м
	if lateral_dist <= threshold:
		return 0.0

	# Определяем СТОРОНУ: cross product направления маршрута и вектора к AI
	var route_data: Dictionary = race_route.get_point_at_distance(_cur_proj_distance)
	var route_pos: Vector3 = route_data.position
	var route_dir: Vector3 = route_data.direction
	var to_ai := global_position - route_pos
	# cross.y > 0 → AI справа от маршрута, < 0 → слева
	var side_sign: float = sign(route_dir.cross(to_ai).y)

	var excess: float = lateral_dist - threshold
	var max_excess: float = CORRIDOR_WIDTH * 0.3   # от 0.7·W до ~1.0·W
	var correction_strength: float = clamp(excess / max_excess, 0.0, 1.0) * 0.25
	# Рулим В СТОРОНУ маршрута (противоположно стороне AI)
	return -side_sign * correction_strength


func _check_obstacle_ahead() -> Dictionary:
	"""Проверяет наличие препятствия впереди и возвращает данные для объезда.
	Использует метод Craig Reynolds - латеральная сила направлена ОТ препятствия."""
	var result := {"detected": false, "avoidance_steering": 0.0, "urgency": 0.0}

	var speed_kmh: float = max(10.0, current_speed_kmh)
	# Дистанция проверки: короткая, чтобы не реагировать на далёкие здания вдоль дороги
	var check_distance: float = clamp(speed_kmh * 0.4, 8.0, 25.0)

	var from := global_position + Vector3(0, 1.0, 0)
	var forward := -global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP).normalized()

	# 3 луча: центральный и боковые (без крайних — они ловят здания сбоку от дороги)
	var rays := [
		{"dir": forward, "weight": 1.0},                                # Центр
		{"dir": (forward + right * 0.3).normalized(), "weight": 0.9},   # Немного справа
		{"dir": (forward - right * 0.3).normalized(), "weight": 0.9},   # Немного слева
	]

	var closest_distance := INF
	var obstacle_side := 0.0  # < 0 = слева, > 0 = справа

	for ray_data in rays:
		obstacle_check_ray.global_position = from
		obstacle_check_ray.target_position = ray_data.dir * check_distance
		obstacle_check_ray.force_raycast_update()

		if obstacle_check_ray.is_colliding():
			var hit_point := obstacle_check_ray.get_collision_point()
			var distance := from.distance_to(hit_point)

			if distance < closest_distance:
				closest_distance = distance
				result.detected = true

				# Определяем с какой стороны препятствие
				var to_obstacle := (hit_point - from).normalized()
				obstacle_side = right.dot(to_obstacle)  # + = справа, - = слева

	if result.detected:
		# Urgency: 1.0 = очень близко, 0.0 = далеко
		# Используем квадратичную функцию для более резкой реакции вблизи
		var raw_urgency: float = clamp(1.0 - (closest_distance / check_distance), 0.0, 1.0)
		var urgency: float = raw_urgency * raw_urgency  # Квадрат для нелинейности
		result.urgency = raw_urgency  # Но для blend используем линейный

		# Avoidance steering: руль В ПРОТИВОПОЛОЖНУЮ сторону от препятствия
		# Если препятствие справа (obstacle_side > 0), рулим влево (steering > 0)
		# Если препятствие слева (obstacle_side < 0), рулим вправо (steering < 0)
		# Умеренная сила объезда для плавных дуг
		var avoidance_strength: float = (0.3 + urgency * 0.5)
		result.avoidance_steering = -sign(obstacle_side) * clamp(avoidance_strength, 0.0, 0.8)

		# Если препятствие прямо по центру - выбираем сторону на основе текущего руления или маршрута
		if abs(obstacle_side) < 0.4:
			# Объезжаем в сторону куда уже рулим, или влево по умолчанию
			var preferred_side: float = 1.0  # По умолчанию влево
			if abs(steering_input) > 0.1:
				preferred_side = sign(steering_input)
			result.avoidance_steering = preferred_side * clamp(avoidance_strength, 0.0, 0.8)

	return result


# ===== СИСТЕМА ВОССТАНОВЛЕНИЯ =====

func _check_stuck(delta: float) -> void:
	"""Проверяет, застряла ли машина"""
	if current_speed_kmh < STUCK_SPEED:
		stuck_timer += delta
		if stuck_timer > STUCK_THRESHOLD:
			_start_recovery()
	else:
		stuck_timer = 0.0
		recovery_attempts = 0


func _start_recovery() -> void:
	"""Начинает процедуру восстановления"""
	recovery_attempts += 1
	_recovery_count += 1  # телеметрия: общее число входов в recovery за прогон

	if recovery_attempts > MAX_RECOVERY_ATTEMPTS:
		# Слишком много попыток - респавн на трассу
		_respawn_on_track()
	else:
		# Пробуем выехать задом
		ai_state = AIState.RECOVERING
		recovery_timer = RECOVERY_REVERSE_TIME
		print("RacerAI: ", racer_name, " starting recovery attempt ", recovery_attempts)


func _execute_recovery(delta: float) -> void:
	"""Выполняет процедуру восстановления (едем задом)"""
	recovery_timer -= delta

	if recovery_timer > 0:
		# Едем назад
		throttle_input = 0.0
		brake_input = 0.0
		# Включаем задний ход через отрицательный throttle (если поддерживается)
		# Или просто откатываемся
		steering_input = randf_range(-0.5, 0.5)  # Случайный поворот

		# Применяем силу назад
		var backward := global_transform.basis.z
		apply_central_force(backward * 3000.0)
	else:
		# Восстановление завершено
		ai_state = AIState.RACING
		stuck_timer = 0.0


func _respawn_on_track() -> void:
	"""Телепортирует машину обратно на трассу"""
	if not race_route or race_route.points.is_empty():
		return

	print("RacerAI: ", racer_name, " respawning on track at progress ", race_progress)

	# Находим точку на маршруте немного позади текущего прогресса
	var respawn_distance: float = max(0.0, race_progress - 20.0)
	var point_data: Dictionary = race_route.get_point_at_distance(respawn_distance)

	# Телепортируем
	global_position = point_data.position + Vector3(0, 1.5, 0)

	# Поворачиваем в направлении движения
	var dir: Vector3 = point_data.direction
	if dir.length() > 0.1:
		var yaw := atan2(dir.x, dir.z)
		global_rotation = Vector3(0, yaw, 0)

	# Сбрасываем физику
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

	# Возвращаемся к гонке
	ai_state = AIState.RACING
	stuck_timer = 0.0
	recovery_attempts = 0


# ===== ВИЗУАЛЬНЫЕ НАСТРОЙКИ =====

func randomize_appearance() -> void:
	"""Рандомизирует внешний вид машины"""
	var color: Color = RACER_COLORS[randi() % RACER_COLORS.size()]
	_apply_body_color(color)


func _apply_body_color(color: Color) -> void:
	"""Применяет цвет к кузову машины"""
	# Ищем все MeshInstance3D и применяем цвет к материалам кузова
	for child in get_children():
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.name.to_lower().contains("body") or \
			   mesh_instance.name.to_lower().contains("chassis") or \
			   mesh_instance.name.to_lower().contains("hood"):
				var mat := StandardMaterial3D.new()
				mat.albedo_color = color
				mat.metallic = 0.6
				mat.roughness = 0.35
				mesh_instance.material_override = mat
