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
@export var lane_offset: float = 0.0      # м — персональное смещение линии (не все по осевой);
                                          # в крутых поворотах стягивается к апексу

# Общие константы контроллера (детали pure-pursuit/скорости/context — в блоке REDESIGN v3 ниже)
const UPDATE_INTERVAL := 0.05     # с — период обновления логики AI (20 Гц)
const MIN_TURN_L := 6.0           # м — нижний предел хорды до цели (защита от κ=2·sinα/L→∞)
const MAX_STEER_RATE := 6.0       # ед/с — мягкое ограничение скорости изменения команды руля
const WHEELBASE_FALLBACK := 2.5   # м — если колёса не собрались
const DEBUG_SAMPLES_CAP := 1200   # ~60 с при 20 Гц

# ================= REDESIGN v3 — faithful K1999 line + friction speed profile =================
# (docs/RACER_AI_REDESIGN_PLAN.md §3[A]/[B]; algorithm spec docs/RACER_AI_SIM_REUSE.md)
# Phase 1: строится офлайн один раз на старте, ПОКА НЕ подключён к рулю (только дамп геометрии).
const RL_STATION_DS := 3.0        # м — равномерный шаг станций (K1999 resample)
const RL_MARGIN := 1.2            # м — безопасный отступ линии от кромки дороги
const RL_DEFAULT_HALF := 3.5      # м — half-width fallback (≈реальная местная улица ~7 м)
const RL_HALF_MIN := 2.5          # м — пол ширины (защита от sliver/чужого сегмента → не прижать к осевой)
const RL_HALF_MAX := 8.0          # м — потолок ширины (защита от захвата далёкой широкой дороги)
const RL_ITERS := 400             # макс. полных проходов K1999 (early-exit по сходимости)
const RL_NEWTON_GAIN := 0.6       # демпфирование шага Ньютона (стабильность)
const RL_MAX_STEP := 0.5          # м — предел смещения точки за один проход
const RL_CONVERGE := 0.002        # м — порог сходимости (макс |Δoff| за проход)
const RL_WIDTH_QUERY_R := 80.0    # м — радиус запроса (широкий: get_road_segments_in_radius фильтрует
                                  #      по КОНЦАМ сегмента, длинные дороги рядом иначе теряются)
const RL_ON_ROAD_TOL := 12.0      # м — станция дальше этого от осевой ближайшей дороги → не на дороге (fallback)
# Профиль скорости — фрикционный круг v=√(a_lat/κ) + прямой/обратный проход (Q4: arcade-grippy)
const SP_A_LAT := 9.0             # м/с² — предел бокового сцепления
const SP_A_BRAKE := 8.0           # м/с² — тормозное замедление (backward pass)
const SP_A_ACCEL := 6.0           # м/с² — продольный разгон (forward pass)
const SP_TOP := 33.0              # м/с (~120 км/ч) — общий потолок профиля; per-car cap отдельно
const SP_CURV_EPS := 1.0e-4       # 1/м — защита от деления на нулевую кривизну

# [C] Pure pursuit по K1999-линии (Snider/Coulter): ld = clamp(LD_K·v, LD_MIN, LD_MAX);
# δ = atan(2·L·sin α / chord). Короткий ld → осцилляции, длинный → срез угла (находка 7).
const LD_MIN := 9.0               # м — минимальный lookahead (на малой скорости)
const LD_MAX := 26.0              # м — максимальный lookahead (высокая скорость)
const LD_K := 1.0                 # ld ≈ LD_K · скорость(м/с)
const SPEED_PREVIEW := 6.0        # м — упреждение при чтении профиля скорости (лаг актуатора)
const RL_LINE_BIAS_MAX := 0.9     # м — персональный постоянный боковой сдвиг линии (racecraft-разброс:
                                  # соперники не едут гуськом по одной осевой). Плавный, не per-frame
                                  # → не возвращает синусоиду (в отличие от старого lane_offset+separation)

# [D] Context steering (A. Fray, Game AI Pro 2 ch.18; шипнут в F1 2011) — фильтр НАПРАВЛЕНИЯ,
# НЕ сумма «беги/догоняй» векторов (та схлопывается в 0 → находка 14). N слотов в переднем секторе;
# interest[d]=совпадение с pursuit-направлением, danger[d]=feeler-хиты (здания/столбы/машины/игрок).
# Выбор: мин-danger множество → макс interest → к прошлому курсу (не флип-флоп). Чисто → chosen=desired
# (нулевое вмешательство → не возвращает синусоиду). Обгон эмерджентен: машина впереди = danger в
# передних слотах → берётся соседний чистый слот.
const CTX_SLOTS := 16
const CTX_ARC_DEG := 100.0        # ± сектор направлений вокруг курса (не даёт выбрать «назад»)
const CTX_REACH_MIN := 6.0        # м — мин. дальность feeler
const CTX_REACH_MAX := 22.0       # м — макс. дальность feeler
const CTX_REACH_K := 0.55         # reach ≈ K·v(м/с)
const CTX_SPILL := 0.5            # растекание danger на соседние слоты (не чиркаем углом об край)
const CTX_DANGER_BAND := 0.05     # ширина «почти-минимального» danger-множества для выбора
const CTX_HYST := 0.3             # блендинг с прошлым направлением (free hysteresis Fray)
const CTX_CLEAR := 0.15           # danger по курсу ниже этого = чисто → точное pursuit (без вмешательства)
const CTX_FEELER_Y := 0.7         # м — высота feeler'ов (выше бордюров ~0.15м; ловит столбы/машины/здания)
const CTX_CAR_AHEAD_COS := 0.5    # машина в ±60° от курса = ВПЕРЕДИ (объезд/обгон); дальше = СБОКУ (держим линию)
const CTX_STATIC_SLOW := 0.2      # danger статики по курсу выше этого → замедляемся (стена/столб); машины — темп

# Восстановление после застревания (NFS-подход, Game AI Pro ch.38: не респавнить по одному кадру,
# интегрировать неподвижность по времени, дать шанс выехать самому, респавн — крайняя мера).
var recovery_timer: float = 0.0     # таймер текущего реверс-манёвра
var _flip_timer: float = 0.0        # сколько секунд машина перевёрнута
var _last_respawn_progress: float = -1.0  # где респавнились в прошлый раз (детект loop)
var _stuck_anchor: Vector3 = Vector3.ZERO  # позиция начала окна «застревания» (нетто-смещение от неё)
var _stuck_win_timer: float = 0.0   # длительность текущего окна проверки застревания, с
var _slow_timer: float = 0.0        # сколько едем медленно подряд (триггер реверс-нюджа)
# Диагностика (для честного трейса в main.gd RACE_AUTOTEST)
var dbg_urgency := 0.0
var dbg_safe := 0.0
var dbg_blocked := false
var _respawn_defers: int = 0        # сколько раз подряд отложили телепорт (игрок рядом)
const RESPAWN_MAX_DEFERS := 2       # после стольких отсрочек телепортируем даже рядом с игроком
const STUCK_SPEED := 6.0            # км/ч — ниже считаем «почти стоим» (триггер попытки реверса)
const STUCK_MOVE_MIN := 1.0        # м — нетто-смещение за окно, ниже которого = застряли (спек юзера)
const STUCK_WINDOW := 5.5           # с — окно: если за него сместились <MOVE_MIN → респавн (крайняя мера)
const REVERSE_AFTER := 1.5          # с непрерывно-медленно → пробуем сдать назад и довернуть нос
const RECOVERY_REVERSE_TIME := 1.2  # с длительность одного реверс-манёвра
const FLIP_UP_Y := 0.2              # up-вектор ниже → считаем перевёрнутой
const FLIP_TIMEOUT := 1.5           # с перевёрнутой → сразу респавн (реверсом не встать)
const RESPAWN_HIDE_DIST := 60.0     # м — ближе к игроку жёсткий телепорт не делаем (маскируем)

# Raycast для obstacle detection
var obstacle_check_ray: RayCast3D

# Внутренние переменные
var update_timer := 0.0

# v1.1 pure-pursuit состояние
var wheelbase := 2.5              # измеряется в _ready из локальных Z позиций колёс
var _lookahead_dist := 18.0       # текущий (сглаженный между тиками) lookahead, м
var _cur_lateral_offset := 0.0    # боковое смещение от осевой (проекция текущего тика)
var _cur_proj_distance := 0.0     # арк-дистанция проекции текущего тика (для edge-guard)
var _last_obstacle_active := false  # сработал ли объезд в этом тике (для телеметрии; Phase 3 включит)

# REDESIGN v3 — настоящая K1999 линия + профиль скорости (Phase 2: подключена к рулю)
var _terrain: Node = null         # OSMTerrain — источник ширины дороги (резолвится в set_race_route)
var _line: Array = []             # Array[Dictionary] {pos,tangent,curv,arc,vmax,off,half}
var _line_fallback_frac := 0.0    # доля станций без данных ширины дороги (использован fallback)
var _line_arc := 0.0              # арк-дистанция проекции машины на K1999-линию (для рулёжки)
var _line_seg := 0                # монотонный индекс сегмента линии (forward-biased окно проекции)
var _line_lateral := 0.0          # боковое смещение машины от линии (м; телеметрия/edge cases)
var _ctx_last_dir := Vector3.ZERO  # прошлое выбранное направление (гистерезис против флип-флопа)
var _line_bias := 0.0             # м — персональный постоянный боковой сдвиг линии (racecraft)

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
	# Layer 8 = RaceOpponents (bit 7 = 128)
	# v2: видим и СОПЕРНИКОВ (128), и ИГРОКА (1) — иначе таранили друг друга и игрока
	# (бэклог S1). Обгон эмерджентен: медленная машина впереди = помеха в коридоре →
	# line-shift обводит её дугой. Терраин (4) НЕ в маске — горки не пугают сенсор.
	obstacle_check_ray = RayCast3D.new()
	obstacle_check_ray.enabled = true
	obstacle_check_ray.collision_mask = 2 | 8 | 128 | 1
	obstacle_check_ray.hit_from_inside = false
	add_child(obstacle_check_ray)
	obstacle_check_ray.add_exception(self)  # feeler'ы не должны ловить собственный кузов (слой 128)

	# Добавляем в группу для идентификации
	add_to_group("race_opponent")

	# Рандомизируем параметры AI для вариативности
	skill_level = randf_range(0.85, 1.0)
	aggression = randf_range(0.5, 0.9)
	# Тесные городские улицы: 84 км/ч → вылеты и постоянные recovery. Держим скорость,
	# которую реально сдюжить чисто (меньше аварий = меньше мёртвого времени на respawn).
	# v3: per-car target_speed РАЗВОДИТ поле (racecraft эмерджентен), а НЕ статический lane_offset
	# (тот сдвигал pursuit-цель и давал синусоиду — удалён, см. RACER_AI_REDESIGN_PLAN §4).
	target_speed = randf_range(46.0, 62.0)
	_line_bias = randf_range(-RL_LINE_BIAS_MAX, RL_LINE_BIAS_MAX)  # персональная полоса (racecraft-разброс)


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
	_resolve_terrain()
	_build_racing_line()        # K1999 линия + профиль скорости (Phase 2: подключена к рулю)
	_line_arc = 0.0
	_line_seg = 0


# ================= REDESIGN v3 — K1999 racing line (Phase 1) =================

func _resolve_terrain() -> void:
	"""Находит OSMTerrain для запроса ширины дороги (нужен для границ K1999-линии)."""
	_terrain = null
	var scene := get_tree().current_scene
	if scene != null:
		_terrain = scene.get_node_or_null("OSMTerrain")


func _road_half_width_at(x: float, z: float) -> float:
	"""Половина ширины дороги (м) из ближайшего OSM-сегмента к точке; -1, если данных нет."""
	if _terrain == null or not _terrain.has_method("get_road_segments_in_radius"):
		return -1.0
	var segs: Array = _terrain.get_road_segments_in_radius(Vector3(x, 0.0, z), RL_WIDTH_QUERY_R)
	var best := -1.0
	var best_d := INF
	var p := Vector2(x, z)
	for seg in segs:
		var a: Vector2 = seg.p1
		var b: Vector2 = seg.p2
		var ab := b - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 < 0.01 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var closest := a + ab * t
		var d := p.distance_to(closest)
		if d < best_d:
			best_d = d
			best = float(seg.width) * 0.5
	# Честность: принимаем ширину, только если станция реально РЯДОМ с осевой (иначе не на дороге)
	if best_d > RL_ON_ROAD_TOL:
		return -1.0
	if best > 0.0:
		best = clampf(best, RL_HALF_MIN, RL_HALF_MAX)  # против sliver/чужого сегмента и highway-захвата
	return best


func _menger(a: Vector3, b: Vector3, c: Vector3) -> float:
	"""Знаковая кривизна трёх точек (XZ): κ = 2·(v1×v2)/(|v1|·|v2|·|c−a|). Знак = сторона поворота."""
	var v1 := Vector2(b.x - a.x, b.z - a.z)
	var v2 := Vector2(c.x - b.x, c.z - b.z)
	var d13 := Vector2(c.x - a.x, c.z - a.z).length()
	var denom := v1.length() * v2.length() * d13
	if denom < 1.0e-6:
		return 0.0
	var cross := v1.x * v2.y - v1.y * v2.x
	return 2.0 * cross / denom


func _st_point(stations: Array, off: Array, i: int) -> Vector3:
	"""Позиция станции i при латеральном смещении off[i] вдоль её перпендикуляра."""
	var s: Dictionary = stations[i]
	var c: Vector3 = s["c"]
	var perp: Vector3 = s["perp"]
	return c + perp * float(off[i])


func _build_racing_line() -> void:
	"""Настоящая K1999 (VDrift k1999.cpp): линия минимальной кривизны в границах дороги.
	1) ресэмпл осевой на равномерные станции + ширина дороги из OSM;
	2) на каждой станции латеральный оффсет off (0=осевая), концы закреплены;
	3) K1999: κ по Менгеру, цель = взвешенное среднее кривизн соседей, демпфированный
	   шаг Ньютона по off к цели, clamp в границы дороги (−(half−margin)…+(half−margin));
	4) выход {pos,tangent,curv,arc}; 5) фрикционный профиль скорости.
	Строится ОДИН раз, общая для всех машин (различие машин — в скорости/объезде, не в линии)."""
	_line.clear()
	_line_fallback_frac = 0.0
	if race_route == null or race_route.points.size() < 2:
		return
	var total: float = race_route.total_length
	if total < RL_STATION_DS:
		return

	# (1) равномерные станции: центр, перпендикуляр (лево = +), half-width дороги
	var n_st := maxi(3, int(round(total / RL_STATION_DS)) + 1)
	var stations: Array = []
	var fb := 0
	for i in range(n_st):
		var d := float(i) / float(n_st - 1) * total
		var pd := race_route.get_point_at_distance(d)
		var c: Vector3 = pd.position
		var dir: Vector3 = pd.direction
		var tang := Vector3(dir.x, 0.0, dir.z)
		tang = tang.normalized() if tang.length() > 0.01 else Vector3.FORWARD
		var perp := Vector3(-tang.z, 0.0, tang.x)  # лево = +off
		var half := _road_half_width_at(c.x, c.z)
		var wfb := false
		if half < 0.5:
			half = RL_DEFAULT_HALF
			wfb = true
			fb += 1
		stations.append({"c": c, "perp": perp, "half": half, "wfb": wfb})
	_line_fallback_frac = float(fb) / float(n_st)

	# (2) латеральные оффсеты, init 0 (осевая), концы закреплены
	var off: Array = []
	off.resize(n_st)
	off.fill(0.0)

	# (3) K1999 итерации (Newton-по-кривизне), early-exit по сходимости
	for _pass in range(RL_ITERS):
		var max_delta := 0.0
		for i in range(1, n_st - 1):
			var pim := _st_point(stations, off, i - 1)
			var pi := _st_point(stations, off, i)
			var pip := _st_point(stations, off, i + 1)
			var curv := _menger(pim, pi, pip)
			var lprev := pi.distance_to(pim)
			var lnext := pi.distance_to(pip)
			# кривизны соседей (для целевой) — VDrift-взвешивание по длинам сегментов
			var cprev := curv
			var cnext := curv
			if i >= 2:
				cprev = _menger(_st_point(stations, off, i - 2), pim, pi)
			if i <= n_st - 3:
				cnext = _menger(pi, pip, _st_point(stations, off, i + 2))
			var target := (lnext * cprev + lprev * cnext) / maxf(0.001, lnext + lprev)
			# производная кривизны по оффсету (перт. на eps) → шаг Ньютона к цели
			var st_i: Dictionary = stations[i]
			var perp_i: Vector3 = st_i["perp"]
			var c_i: Vector3 = st_i["c"]
			var eps := 0.01
			var pi_eps: Vector3 = c_i + perp_i * (float(off[i]) + eps)
			var curv_eps := _menger(pim, pi_eps, pip)
			var dcurv := (curv_eps - curv) / eps
			if absf(dcurv) > 1.0e-6:
				var step := clampf((target - curv) / dcurv, -RL_MAX_STEP, RL_MAX_STEP) * RL_NEWTON_GAIN
				var lim: float = maxf(0.0, float(st_i["half"]) - RL_MARGIN)
				var new_off := clampf(float(off[i]) + step, -lim, lim)
				max_delta = maxf(max_delta, absf(new_off - float(off[i])))
				off[i] = new_off
		if max_delta < RL_CONVERGE:
			break

	# (4) выход: pos, tangent, curv, cumulative arc
	var pts: Array = []
	for i in range(n_st):
		pts.append(_st_point(stations, off, i))
	var acc := 0.0
	for i in range(n_st):
		var pos: Vector3 = pts[i]
		var tang3: Vector3
		if i == 0:
			tang3 = pts[1] - pts[0]
		elif i == n_st - 1:
			tang3 = pts[i] - pts[i - 1]
		else:
			tang3 = pts[i + 1] - pts[i - 1]
		tang3.y = 0.0
		tang3 = tang3.normalized() if tang3.length() > 0.01 else Vector3.FORWARD
		var curv := 0.0
		if i > 0 and i < n_st - 1:
			curv = _menger(pts[i - 1], pts[i], pts[i + 1])
		if i > 0:
			var prev: Vector3 = pts[i - 1]
			acc += Vector2(pos.x - prev.x, pos.z - prev.z).length()
		_line.append({
			"pos": pos, "tangent": tang3, "curv": curv, "arc": acc,
			"vmax": SP_TOP, "off": float(off[i]), "half": float(stations[i]["half"]),
			"wfb": bool(stations[i]["wfb"]),
		})

	# (5) фрикционный профиль скорости
	_build_speed_profile()


func _build_speed_profile() -> void:
	"""Фрикционно-ограниченный профиль: v=√(a_lat/κ) в поворотах, затем backward (тормоз) и
	forward (разгон) проходы (Kapania 2019 / friction circle). Пишет vmax (м/с) на точку."""
	var n := _line.size()
	if n < 2:
		return
	for i in range(n):
		var k: float = absf(float(_line[i]["curv"]))
		_line[i]["vmax"] = minf(SP_TOP, sqrt(SP_A_LAT / maxf(SP_CURV_EPS, k)))
	# backward (тормозные точки перед поворотами)
	for i in range(n - 2, -1, -1):
		var ds: float = float(_line[i + 1]["arc"]) - float(_line[i]["arc"])
		var vnext: float = float(_line[i + 1]["vmax"])
		var vb := sqrt(vnext * vnext + 2.0 * SP_A_BRAKE * maxf(0.0, ds))
		_line[i]["vmax"] = minf(float(_line[i]["vmax"]), vb)
	# forward (разгон)
	for i in range(1, n):
		var ds2: float = float(_line[i]["arc"]) - float(_line[i - 1]["arc"])
		var vprev: float = float(_line[i - 1]["vmax"])
		var vf := sqrt(vprev * vprev + 2.0 * SP_A_ACCEL * maxf(0.0, ds2))
		_line[i]["vmax"] = minf(float(_line[i]["vmax"]), vf)


func get_racing_line_debug() -> Dictionary:
	"""Сводка геометрии K1999-линии для Phase-1 верификации (дамп из main.gd RACE_LINEDUMP)."""
	var n := _line.size()
	if n == 0:
		return {"n": 0}
	var max_k := 0.0
	var vmin := INF
	var vmax := 0.0
	var off_min := INF
	var off_max := -INF
	var onroad := 0
	var have_onroad_api: bool = _terrain != null and _terrain.has_method("is_point_on_road")
	for e in _line:
		max_k = maxf(max_k, absf(float(e["curv"])))
		vmin = minf(vmin, float(e["vmax"]))
		vmax = maxf(vmax, float(e["vmax"]))
		off_min = minf(off_min, float(e["off"]))
		off_max = maxf(off_max, float(e["off"]))
		if have_onroad_api:
			var pos: Vector3 = e["pos"]
			if _terrain.is_point_on_road(Vector2(pos.x, pos.z), 0.5):
				onroad += 1
	var samples: Array = []
	var step := maxi(1, int(n / 12))
	for i in range(0, n, step):
		var e: Dictionary = _line[i]
		samples.append("arc%4.0f off%+.1f k%+.3f v%3.0fkmh half%.1f%s" % [
			float(e["arc"]), float(e["off"]), float(e["curv"]), float(e["vmax"]) * 3.6,
			float(e["half"]), (" FB" if bool(e.get("wfb", false)) else "")])
	# длина непрерывного «хвоста» станций с fallback-шириной (диагностика async-загрузки чанков)
	var tail := 0
	for i in range(n - 1, -1, -1):
		if bool(_line[i].get("wfb", false)):
			tail += 1
		else:
			break
	var first_fb := -1.0
	for i in range(n):
		if bool(_line[i].get("wfb", false)):
			first_fb = float(_line[i]["arc"])
			break
	# ДИАГНОСТИКА причины fallback: для каждой fallback-станции — есть ли ВООБЩЕ дорожный сегмент
	# среди всех ЗАГРУЖЕННЫХ чанков (радиус 3 км), и как далеко. INF ⇒ чанк не загружен (стриминг);
	# 25..80 м ⇒ маршрут в стороне от осевой; ≤25 ⇒ ложный fallback.
	var start_pos: Vector3 = _line[0]["pos"]
	var loaded_segs: Array = []
	if _terrain != null and _terrain.has_method("get_road_segments_in_radius"):
		loaded_segs = _terrain.get_road_segments_in_radius(start_pos, 3000.0)
	var fb_inf := 0        # нет сегмента в 3 км → чанк не загружен
	var fb_far := 0        # 25..80 м → маршрут в стороне от осевой
	var fb_close := 0      # ≤25 м → должно было пройти (ложный fallback)
	var fb_maxdist := 0.0  # макс. пространственная дистанция fallback-станции от старта
	for e in _line:
		if not bool(e.get("wfb", false)):
			continue
		var pos: Vector3 = e["pos"]
		fb_maxdist = maxf(fb_maxdist, pos.distance_to(start_pos))
		var p2 := Vector2(pos.x, pos.z)
		var nd := INF
		for seg in loaded_segs:
			var a: Vector2 = seg.p1
			var b: Vector2 = seg.p2
			var ab := b - a
			var l2 := ab.length_squared()
			var tt := 0.0 if l2 < 0.01 else clampf((p2 - a).dot(ab) / l2, 0.0, 1.0)
			nd = minf(nd, p2.distance_to(a + ab * tt))
		if nd == INF:
			fb_inf += 1
		elif nd > 25.0:
			fb_far += 1
		else:
			fb_close += 1
	return {
		"fb_tail_frac": float(tail) / float(n),
		"first_fb_arc": first_fb,
		"loaded_segs": loaded_segs.size(),
		"fb_inf": fb_inf,
		"fb_far": fb_far,
		"fb_close": fb_close,
		"fb_maxdist": fb_maxdist,
		"n": n,
		"arc_total": float(_line[n - 1]["arc"]),
		"route_len": race_route.total_length,
		"max_curv": max_k,
		"min_radius": (1.0 / max_k if max_k > 1.0e-4 else 9999.0),
		"vmin_kmh": vmin * 3.6,
		"vmax_kmh": vmax * 3.6,
		"off_min": off_min,
		"off_max": off_max,
		"fallback_frac": _line_fallback_frac,
		"onroad_frac": (float(onroad) / float(n) if have_onroad_api else -1.0),
		"samples": samples,
	}


func export_racing_line_json(path: String) -> bool:
	"""Экспорт геометрии для top-down визуализации: K1999-линия, осевая маршрута, дорожные сегменты."""
	var data := {"line": [], "route": [], "roads": []}
	for e in _line:
		var p: Vector3 = e["pos"]
		data["line"].append({
			"x": p.x, "z": p.z, "v": float(e["vmax"]) * 3.6,
			"off": float(e["off"]), "wfb": bool(e.get("wfb", false)),
		})
	if race_route != null:
		for rp in race_route.points:
			var q: Vector3 = rp.position
			data["route"].append({"x": q.x, "z": q.z})
	if _terrain != null and _terrain.has_method("get_road_segments_in_radius") and _line.size() > 0:
		var c: Vector3 = _line[0]["pos"]
		for seg in _terrain.get_road_segments_in_radius(c, 3000.0):
			var a: Vector2 = seg.p1
			var b: Vector2 = seg.p2
			data["roads"].append({"x1": a.x, "z1": a.y, "x2": b.x, "z2": b.y, "w": float(seg.width)})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true


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

	# Инициализируем начальную позицию на маршруте
	# Это критично - без этого AI застрянет с progress=0
	if race_route:
		var projection := race_route.project_position(global_position, 0)
		current_segment_idx = projection.segment_idx
		race_progress = projection.distance
	_stuck_anchor = global_position
	_stuck_win_timer = 0.0
	_slow_timer = 0.0
	_reset_line_projection()  # синхронизируем арк-дистанцию проекции на K1999-линию


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
	"""REDESIGN v3 Phase 2 — чистый pure pursuit по K1999-линии (avoidance OFF).
	[C] ld=clamp(LD_K·v,LD_MIN,LD_MAX); aim = ОДНА точка на линии (arc+ld); δ=atan(2L·sinα/chord).
	[B] скорость из фрикционного профиля линии + per-car cap. Прогресс/финиш — по исходному
	маршруту (HUD/RaceManager). Никаких lane/separation/dodge — цель НЕ дёргается → нет синусоиды."""
	if not race_route or race_route.points.is_empty():
		throttle_input = 0.0
		brake_input = 1.0
		steering_input = 0.0
		return

	# Прогресс/финиш — по ИСХОДНОМУ маршруту (не трогаем смысл race_progress)
	_update_race_progress()
	if race_route.is_finished(race_progress):
		finish_race()
		return

	# Нет K1999-линии — деградируем на прямое следование по маршруту (не должно случаться в гонке)
	if _line.size() < 2:
		var lp := race_route.get_lookahead_point(race_progress, LD_MAX)
		_steer_towards(lp)
		throttle_input = 0.4
		brake_input = 0.0
		return

	# [C] Проекция на линию → текущая арк-дистанция; цель — одна точка впереди на ld
	_project_onto_line(global_position)
	var speed_ms: float = current_speed_kmh / 3.6
	var ld: float = clampf(LD_K * speed_ms, LD_MIN, LD_MAX)
	_lookahead_dist = ld  # для телеметрии
	# Цель — на K1999-линии, сдвинутая на персональный _line_bias по нормали линии (racecraft-полоса)
	var aim_s := _line_sample(_line_arc + ld)
	var aim: Vector3 = aim_s["pos"]
	if _line_bias != 0.0:
		var atang: Vector3 = aim_s["tangent"]
		aim += Vector3(-atang.z, 0.0, atang.x) * _line_bias

	var to_aim := aim - global_position
	to_aim.y = 0.0
	var chord: float = maxf(MIN_TURN_L, to_aim.length())
	var desired_dir: Vector3 = to_aim / maxf(0.001, to_aim.length())

	var forward := -global_transform.basis.z
	var forward_flat := Vector3(forward.x, 0.0, forward.z).normalized()

	# [D] Context steering: pursuit-направление → фильтруется картой опасности (машины/здания/столбы).
	# Чисто → steer_dir == desired_dir (нулевое вмешательство). Помеха впереди → соседнее чистое
	# направление (обгон/объезд эмерджентно), без суммирования векторов → без флип-флоп синусоиды.
	var ctx := _context_steer(desired_dir, forward_flat)
	var steer_dir: Vector3 = ctx["dir"]
	_last_obstacle_active = bool(ctx["active"])

	# Знак как в v1.1 (проверенная рулёжка): sin = cross(steer_dir, forward).y
	var sin_alpha: float = steer_dir.cross(forward_flat).y
	var cos_alpha: float = clampf(forward_flat.dot(steer_dir), -1.0, 1.0)
	var heading_error: float = atan2(sin_alpha, cos_alpha)

	# Велосипедная модель: κ=2·sinα/chord → угол колёс → нормировка в [-1,1]
	var kappa: float = 2.0 * sin_alpha / chord
	var delta_angle: float = atan(wheelbase * kappa)
	var steer_raw: float = clampf(delta_angle / deg_to_rad(max_steering_angle), -1.0, 1.0)

	if ai_debug:
		debug_target_point = aim

	# Мягкое ограничение скорости КОМАНДЫ руля (не фильтр — актуатор уже даёт лаг)
	steering_input = move_toward(steering_input, steer_raw, MAX_STEER_RATE * UPDATE_INTERVAL)

	# [B] Скорость из фрикционного профиля (тормозные точки уже впечены backward-проходом) +
	# лёгкое упреждение; aggression чуть двигает предел; per-car target_speed — верхний потолок.
	# ctx.speed_scale притормаживает, когда чистое направление уводит вбок от pursuit (объезд).
	var v_prof_ms: float = _line_sample(_line_arc + SPEED_PREVIEW).vmax
	var v_want_kmh: float = minf(target_speed, v_prof_ms * 3.6 * lerpf(0.9, 1.06, aggression)) * float(ctx["speed_scale"])
	var speed_error: float = v_want_kmh - current_speed_kmh
	if speed_error < -8.0:
		throttle_input = 0.0
		brake_input = clampf(-speed_error / 25.0, 0.15, 0.85)
	elif speed_error < 0.0:
		throttle_input = 0.1
		brake_input = 0.0
	else:
		throttle_input = clampf(speed_error / 8.0, 0.3, 1.0)
		brake_input = 0.0

	# Диагностика
	dbg_urgency = 1.0 - float(ctx["speed_scale"])
	dbg_safe = v_want_kmh
	dbg_blocked = bool(ctx["active"])

	if ai_debug:
		_record_debug_sample(heading_error, steer_raw, bool(ctx["active"]))


func _steer_towards(target: Vector3) -> void:
	"""Резерв: pure-pursuit руль на произвольную точку (когда линии нет)."""
	var to_t := target - global_position
	to_t.y = 0.0
	if to_t.length() < 0.01:
		return
	var chord: float = maxf(MIN_TURN_L, to_t.length())
	var d := to_t / to_t.length()
	var f := -global_transform.basis.z
	var ff := Vector3(f.x, 0.0, f.z).normalized()
	var sa: float = d.cross(ff).y
	var kappa: float = 2.0 * sa / chord
	var sr: float = clampf(atan(wheelbase * kappa) / deg_to_rad(max_steering_angle), -1.0, 1.0)
	steering_input = move_toward(steering_input, sr, MAX_STEER_RATE * UPDATE_INTERVAL)


func _classify_hit(col: Object, hitpoint: Vector3, forward_flat: Vector3) -> int:
	"""Классификация feeler-хита по УЗЛУ (слой 1 смешивает землю/столбы/игрока — по слою нельзя):
	0 = игнор (дорога/земля Road/Grass, ИЛИ машина СБОКУ — держим линию, не шарахаемся от обгона);
	1 = статика (столб LampCol / здание(слой2) / дерево / прочая помеха — объезжаем И тормозим);
	2 = машина ВПЕРЕДИ/блокирует (объезжаем, но темп держим — обгон)."""
	if col == null:
		return 0
	if col.is_in_group("Road") or col.is_in_group("Grass"):
		return 0  # едем по этому — не помеха
	if col.is_in_group("race_opponent") or col.is_in_group("player") or col.is_in_group("car"):
		var to_hit := Vector3(hitpoint.x - global_position.x, 0.0, hitpoint.z - global_position.z)
		if to_hit.length() < 0.01:
			return 0
		if to_hit.normalized().dot(forward_flat) < CTX_CAR_AHEAD_COS:
			return 0  # машина сбоку/сзади — НЕ помеха (обгоняемый держит линию)
		return 2  # машина впереди — динамическая помеха (обгон)
	return 1  # столб/здание/дерево/прочая статика


func _context_steer(desired_dir: Vector3, forward_flat: Vector3) -> Dictionary:
	"""[D] Context steering (Fray) с классификацией помех по узлу (см. _classify_hit).
	interest=совпадение с pursuit; danger=feeler-хиты (кроме земли и машин сбоку). Выбор:
	мин-danger → макс interest → блендинг с прошлым. Чисто → chosen==desired (нулевое вмешательство).
	Тормозим ТОЛЬКО для статики впереди; машину обгоняем на скорости. Возврат {dir, speed_scale, active}."""
	var speed_ms: float = current_speed_kmh / 3.6
	var reach: float = clampf(CTX_REACH_K * speed_ms, CTX_REACH_MIN, CTX_REACH_MAX)
	var dirs: Array = []
	var interest: Array = []
	var danger: Array = []
	var stat: Array = []  # была ли в слоте СТАТИКА (для торможения)
	dirs.resize(CTX_SLOTS)
	interest.resize(CTX_SLOTS)
	danger.resize(CTX_SLOTS)
	stat.resize(CTX_SLOTS)
	for i in CTX_SLOTS:
		var frac: float = float(i) / float(CTX_SLOTS - 1)
		var ang: float = deg_to_rad(lerpf(-CTX_ARC_DEG, CTX_ARC_DEG, frac))
		var d: Vector3 = forward_flat.rotated(Vector3.UP, ang)
		dirs[i] = d
		interest[i] = maxf(0.0, d.dot(desired_dir))
		danger[i] = 0.0
		stat[i] = false

	# Feeler'ы: один RayCast, глобальный basis прибит к identity (target_position — ЛОКАЛЬНА)
	var from: Vector3 = global_position + Vector3(0.0, CTX_FEELER_Y, 0.0)
	for i in CTX_SLOTS:
		obstacle_check_ray.global_transform = Transform3D(Basis.IDENTITY, from)
		obstacle_check_ray.target_position = (dirs[i] as Vector3) * reach
		obstacle_check_ray.force_raycast_update()
		if not obstacle_check_ray.is_colliding():
			continue
		var hp: Vector3 = obstacle_check_ray.get_collision_point()
		var kind := _classify_hit(obstacle_check_ray.get_collider(), hp, forward_flat)
		if kind == 0:
			continue  # земля/дорога/машина сбоку — игнор
		var prox: float = clampf(1.0 - from.distance_to(hp) / reach, 0.0, 1.0)
		danger[i] = maxf(float(danger[i]), prox)
		if kind == 1:
			stat[i] = true
		if i > 0:
			danger[i - 1] = maxf(float(danger[i - 1]), prox * CTX_SPILL)
			if kind == 1:
				stat[i - 1] = true
		if i < CTX_SLOTS - 1:
			danger[i + 1] = maxf(float(danger[i + 1]), prox * CTX_SPILL)
			if kind == 1:
				stat[i + 1] = true

	# Слот, наиболее совпадающий с pursuit-направлением (куда мы и так хотим)
	var fwd_i: int = 0
	var fwd_int: float = -1.0
	for i in CTX_SLOTS:
		if float(interest[i]) > fwd_int:
			fwd_int = float(interest[i])
			fwd_i = i
	# ЧИСТО ВПЕРЁДИ → точное pursuit-направление (без дискретизации слотов → без джиттера/синусоиды)
	if float(danger[fwd_i]) < CTX_CLEAR:
		_ctx_last_dir = desired_dir
		return {"dir": desired_dir, "speed_scale": 1.0, "active": false}

	# Помеха по курсу: минимально-опасное множество (Fray) → максимальный interest среди него
	var min_d: float = INF
	for i in CTX_SLOTS:
		min_d = minf(min_d, float(danger[i]))
	var best_i: int = -1
	var best_int: float = -1.0
	for i in CTX_SLOTS:
		if float(danger[i]) <= min_d + CTX_DANGER_BAND and float(interest[i]) > best_int:
			best_int = float(interest[i])
			best_i = i
	if best_i < 0:
		best_i = fwd_i
	var chosen: Vector3 = dirs[best_i]

	# Free hysteresis (Fray): блендинг с прошлым направлением — гасит флип-флоп
	if _ctx_last_dir != Vector3.ZERO:
		chosen = (chosen + _ctx_last_dir * CTX_HYST).normalized()
	_ctx_last_dir = chosen

	# Скорость: тормозим ТОЛЬКО когда по курсу СТАТИКА (стена/столб). Машину обгоняем на скорости.
	var static_ahead: bool = bool(stat[fwd_i]) and float(danger[fwd_i]) > CTX_STATIC_SLOW
	var align: float = clampf(chosen.dot(desired_dir), -1.0, 1.0)
	var speed_scale: float = clampf(align, 0.45, 1.0) if static_ahead else clampf(align, 0.8, 1.0)
	return {"dir": chosen, "speed_scale": speed_scale, "active": true}


func _line_index_for_arc(arc: float) -> int:
	"""Бинарный поиск индекса точки линии i, такой что _line[i].arc ≤ arc < _line[i+1].arc."""
	var n := _line.size()
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if float(_line[mid]["arc"]) < arc:
			lo = mid + 1
		else:
			hi = mid
	return maxi(0, lo - 1)


func _line_sample(arc: float) -> Dictionary:
	"""Точка/касательная/скорость на K1999-линии по арк-дистанции (линейная интерполяция)."""
	var n := _line.size()
	if n < 2:
		return {"pos": global_position, "tangent": -global_transform.basis.z, "vmax": SP_TOP}
	var total: float = float(_line[n - 1]["arc"])
	arc = clampf(arc, 0.0, total)
	var idx := _line_index_for_arc(arc)
	var j := mini(idx + 1, n - 1)
	var a: Dictionary = _line[idx]
	var b: Dictionary = _line[j]
	var seg: float = float(b["arc"]) - float(a["arc"])
	var t: float = 0.0 if seg < 0.001 else (arc - float(a["arc"])) / seg
	var pos: Vector3 = (a["pos"] as Vector3).lerp(b["pos"] as Vector3, t)
	var tang: Vector3 = (a["tangent"] as Vector3).lerp(b["tangent"] as Vector3, t)
	tang.y = 0.0
	tang = tang.normalized() if tang.length() > 0.01 else Vector3.FORWARD
	var vmax: float = lerpf(float(a["vmax"]), float(b["vmax"]), t)
	return {"pos": pos, "tangent": tang, "vmax": vmax}


func _project_onto_line(pos: Vector3) -> void:
	"""Проекция машины на K1999-линию → _line_arc (forward-biased окно от _line_seg).
	При большом удалении (сбит/респавн) — полный переску. Обновляет _line_lateral."""
	var n := _line.size()
	if n < 2:
		return
	var best_d := INF
	var best_arc := _line_arc
	var best_seg := _line_seg
	var lo := maxi(0, _line_seg - 3)
	var hi := mini(n - 2, _line_seg + 60)
	for i in range(lo, hi + 1):
		var d := _seg_project(pos, i)
		if d["d2"] < best_d:
			best_d = d["d2"]
			best_arc = d["arc"]
			best_seg = i
	# Сбит/респавн: окно не нашло близкой точки → полный переску
	if best_d > 225.0:  # >15 м
		for i in range(0, n - 1):
			var d := _seg_project(pos, i)
			if d["d2"] < best_d:
				best_d = d["d2"]
				best_arc = d["arc"]
				best_seg = i
	_line_lateral = sqrt(best_d)
	# forward-biased: продвигаемся вперёд, назад — только при явном сбросе (переску выше)
	if best_arc >= _line_arc - 1.0 or best_d > 225.0:
		_line_arc = maxf(_line_arc, best_arc) if best_d <= 225.0 else best_arc
		_line_seg = best_seg


func _seg_project(pos: Vector3, i: int) -> Dictionary:
	"""Проекция pos на сегмент линии [i,i+1] (XZ): {d2: квадрат расст., arc: арк-дистанция}."""
	var a: Vector3 = _line[i]["pos"]
	var b: Vector3 = _line[i + 1]["pos"]
	var ax := b.x - a.x
	var az := b.z - a.z
	var l2 := ax * ax + az * az
	if l2 < 0.0001:
		return {"d2": INF, "arc": float(_line[i]["arc"])}
	var t: float = clampf(((pos.x - a.x) * ax + (pos.z - a.z) * az) / l2, 0.0, 1.0)
	var cx := a.x + ax * t
	var cz := a.z + az * t
	var dx := pos.x - cx
	var dz := pos.z - cz
	return {"d2": dx * dx + dz * dz, "arc": lerpf(float(_line[i]["arc"]), float(_line[i + 1]["arc"]), t)}


func _reset_line_projection() -> void:
	"""Полный переску проекции на линию (после респавна/старта) — сбрасывает forward-bias."""
	_line_seg = 0
	_line_arc = 0.0
	if _line.size() >= 2:
		_project_onto_line(global_position)


func _update_race_progress() -> void:
	"""Обновляет прогресс по маршруту (только вперёд!) и кэширует проекцию тика."""
	if not race_route:
		return

	# Проецируем позицию на маршрут, начиная от текущего сегмента (ОДНА проекция на тик)
	var projection := race_route.project_position(global_position, current_segment_idx)

	# Защита от залипания forward-only проекции на ДАЛЬНЕМ сегменте (после отбрасывания
	# назад/контакта): аномально большое боковое → переспроецируем с 0 и берём меньшее.
	if float(projection.lateral_offset) > 30.0:
		var full := race_route.project_position(global_position, 0)
		if float(full.lateral_offset) < float(projection.lateral_offset):
			projection = full
			current_segment_idx = full.segment_idx

	# Кэшируем боковое смещение и арк-дистанцию для edge-guard + телеметрии
	_cur_lateral_offset = projection.lateral_offset
	_cur_proj_distance = projection.distance

	# Обновляем только если прогресс увеличился (НЕ возвращаемся)
	if projection.distance > race_progress:
		race_progress = projection.distance
		current_segment_idx = projection.segment_idx


# ===== СИСТЕМА ВОССТАНОВЛЕНИЯ =====

func _check_stuck(delta: float) -> void:
	"""NFS-подход (Game AI Pro ch.38): даём машине выехать самой; респавн — крайняя мера.
	Окно STUCK_WINDOW: если НЕТТО-смещение от якоря < STUCK_MOVE_MIN (1 м) за окно → респавн.
	Внутри окна: если едем медленно REVERSE_AFTER подряд → пробуем сдать назад+довернуть нос
	(реверс-нюдж НЕ сбрасывает окно — иначе вечный цикл «отъехал-въехал»)."""
	# Переворот: реверсом не встать — сразу респавн (редкий случай, допустим и при игроке рядом)
	if global_transform.basis.y.y < FLIP_UP_Y:
		_flip_timer += delta
		if _flip_timer > FLIP_TIMEOUT:
			_flip_timer = 0.0
			_recovery_count += 1
			_respawn_on_track()
			return
	else:
		_flip_timer = 0.0

	_stuck_win_timer += delta
	if _stuck_win_timer >= STUCK_WINDOW:
		# Окно истекло: сместились ли мы за него хотя бы на метр?
		var net: float = global_position.distance_to(_stuck_anchor)
		if net < STUCK_MOVE_MIN:
			# Нет — застряли всерьёз (сами не выехали) → респавн на трассу (крайняя мера)
			_recovery_count += 1
			_respawn_on_track()  # он сам переустановит якорь/окно
			return
		# Едем нормально — открываем новое окно от текущей позиции
		_stuck_anchor = global_position
		_stuck_win_timer = 0.0
		_slow_timer = 0.0
		return

	# Внутри окна: медленно И не сдвинулись от якоря (не путать со стартовым разгоном от 0, где
	# машина уже едет вперёд) → пробуем реверс-нюдж (шанс выехать самому)
	if current_speed_kmh < STUCK_SPEED and global_position.distance_to(_stuck_anchor) < STUCK_MOVE_MIN:
		_slow_timer += delta
		if _slow_timer >= REVERSE_AFTER:
			_slow_timer = 0.0
			_start_recovery()
	else:
		_slow_timer = 0.0


func _start_recovery() -> void:
	"""Реверс-манёвр: сдать назад, доворачивая нос к касательной маршрута (не респавн — сначала
	даём выехать самому; окно застревания НЕ сбрасываем, чтобы поймать «отъехал-въехал»-цикл)."""
	ai_state = AIState.RECOVERING
	recovery_timer = RECOVERY_REVERSE_TIME


func _execute_recovery(delta: float) -> void:
	"""Едем задом, ДОВОРАЧИВАЯ нос к касательной маршрута (не случайный руль — так после реверса
	мы уже смотрим вдоль трассы). Окно застревания продолжает тикать (учёт wall-clock)."""
	recovery_timer -= delta
	_stuck_win_timer += delta  # окно идёт и во время реверса (чтобы респавн не откладывался вечно)

	if recovery_timer > 0.0:
		throttle_input = 0.0
		brake_input = 0.0

		# Ошибка курса к касательной маршрута в точке текущего прогресса
		var steer_cmd := 0.0
		if race_route:
			var pd: Dictionary = race_route.get_point_at_distance(race_progress)
			var tangent: Vector3 = pd.direction
			var tflat := Vector3(tangent.x, 0, tangent.z).normalized()
			var forward := -global_transform.basis.z
			var fflat := Vector3(forward.x, 0, forward.z).normalized()
			var herr: float = atan2(tflat.cross(fflat).y, fflat.dot(tflat))
			# При заднем ходе знак руля инвертируется относительно желаемого поворота носа
			steer_cmd = clampf(-herr * 1.2, -0.7, 0.7)
		steering_input = steer_cmd

		# Применяем силу назад
		var backward := global_transform.basis.z
		apply_central_force(backward * 3000.0)
	else:
		# Реверс завершён — назад в гонку (окно/якорь решат, помогло ли; иначе респавн позже)
		ai_state = AIState.RACING


func _ground_y_at(x: float, z: float, anchor_y: float) -> float:
	"""Высота поверхности в точке (STK TerrainInfo/getHoT): луч ВНИЗ на слой дорог/террейна (1).
	Так respawn кладёт машину НА поверхность, а не под неё (Y точек маршрута из билда неверный
	на elevated-террейне — отсюда «респавн под картой»). anchor_y — около текущей высоты машины."""
	var space := get_world_3d().direct_space_state
	if space == null:
		return anchor_y
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, anchor_y + 60.0, z), Vector3(x, anchor_y - 200.0, z))
	q.collision_mask = 1
	q.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return anchor_y
	return float(hit.position.y)


func _respawn_on_track() -> void:
	"""Релокация НА линию и НА поверхность (STK rescue: raycast-down height + reorient к касательной).
	МАСКИРОВКА: рядом с игроком откладываем (но не вечно). Кладём на осевую в точке текущего
	прогресса (там дорога — уводит с бокового заклина); при повторе — прыжок вперёд за проблему."""
	if not race_route or race_route.points.is_empty():
		return

	var flipped: bool = global_transform.basis.y.y < FLIP_UP_Y
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player != null and not flipped and _respawn_defers < RESPAWN_MAX_DEFERS:
		if global_position.distance_to(player.global_position) < RESPAWN_HIDE_DIST:
			# Рядом с игроком не телепортируем — ещё раз пробуем реверс (маскировка)
			_respawn_defers += 1
			ai_state = AIState.RECOVERING
			recovery_timer = RECOVERY_REVERSE_TIME
			return
	_respawn_defers = 0

	# Куда класть: НА осевую в точке текущего прогресса (дорога, уводит с бокового заклина).
	# Если это повтор почти на том же месте — прыгаем ВПЕРЁД за проблемный участок.
	var respawn_distance: float
	if race_progress < 10.0:
		# Заклинило на старт-гриде → выносим ЗА грид на чистый участок (не обратно в кучу)
		respawn_distance = 45.0
		print("RacerAI: ", racer_name, " START-stuck → warp past grid to ", respawn_distance)
	elif _last_respawn_progress >= 0.0 and absf(race_progress - _last_respawn_progress) < 15.0:
		respawn_distance = minf(race_route.total_length - 5.0, race_progress + 35.0)
		print("RacerAI: ", racer_name, " respawn-LOOP → warp forward to ", respawn_distance)
	else:
		respawn_distance = clampf(race_progress, 0.0, race_route.total_length - 5.0)
		print("RacerAI: ", racer_name, " respawning on line at progress ", respawn_distance)
	_last_respawn_progress = respawn_distance
	var point_data: Dictionary = race_route.get_point_at_distance(respawn_distance)
	var rp: Vector3 = point_data.position

	# Кладём НА поверхность (луч вниз), а не на Y точки маршрута
	var gy: float = _ground_y_at(rp.x, rp.z, global_position.y)
	global_position = Vector3(rp.x, gy + 1.2, rp.z)

	# Ориентируем по касательной маршрута
	var dir: Vector3 = point_data.direction
	var dflat := Vector3(dir.x, 0.0, dir.z)
	if dflat.length() > 0.1:
		dflat = dflat.normalized()
		global_rotation = Vector3(0, atan2(dflat.x, dflat.z), 0)

	# Стартовый толчок ВПЕРЁД по касательной — иначе после сброса скорости машина ~3с стоит
	# на полном газу, пока раскрутятся колёса (мёртвое время на каждый respawn).
	angular_velocity = Vector3.ZERO
	linear_velocity = dflat * 6.0 if dflat.length() > 0.1 else Vector3.ZERO

	# Синхронизируем прогресс/сегмент с точкой респавна
	var reproj := race_route.project_position(global_position, 0)
	race_progress = reproj.distance
	current_segment_idx = reproj.segment_idx
	_reset_line_projection()  # ресинхронизируем проекцию на K1999-линию после телепорта

	# Возвращаемся к гонке; открываем свежее окно застревания от новой позиции
	ai_state = AIState.RACING
	_stuck_anchor = global_position
	_stuck_win_timer = 0.0
	_slow_timer = 0.0


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
