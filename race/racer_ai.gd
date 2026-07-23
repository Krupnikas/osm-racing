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
const RACER_SPEED_SCALE := 0.78   # множитель темпа для КИНЕМАТИКИ (оффскрин); гонка использует ниже дифф. масштаб
# P6: масштаб темпа ДИФФЕРЕНЦИРОВАН по кривизне — быстро на ПРЯМЫХ (конкурентно vs игрок), безопасно
# в АПЕКСАХ (иначе overshoot → столбы/вылеты). Раньше был единый 0.72 (недооценивал) → 0.85 (столбы).
const RACER_SCALE_STRAIGHT := 0.72  # прямые: bench-чистое значение. ★ ЭТО главный knob КОНКУРЕНТНОСТИ —
                                    # крутить ВВЕРХ в feel-pass main.tscn vs реальный игрок (стенд не может
                                    # это оценить: ghost не skilled; выше → влёт в столбы pole-alley/hairpin)
const RACER_SCALE_CORNER := 0.70    # апексы: безопасно, без overshoot (крутить ТУТ, если задевают столбы)
const KINEMATIC_SAFE_RADIUS := 200.0  # м — радиус вокруг камеры, где террейн НАДЁЖЕН (загружен + elevation
                                      # применён). Дальше edem кинематически по линии (физика свалилась бы
                                      # с elevation-обрыва). Физика/гонка колесо-в-колесо — только вблизи игрока.

# [C] Pure pursuit по K1999-линии (Snider/Coulter): ld = clamp(LD_K·v, LD_MIN, LD_MAX);
# δ = atan(2·L·sin α / chord). Короткий ld → осцилляции, длинный → срез угла (находка 7).
const LD_MIN := 9.0               # м — минимальный lookahead (на малой скорости)
const LD_MAX := 26.0              # м — максимальный lookahead (высокая скорость)
const LD_K := 1.0                 # ld ≈ LD_K · скорость(м/с)
const SPEED_PREVIEW := 6.0        # м — упреждение при чтении профиля скорости (лаг актуатора)
const RL_LINE_BIAS_MAX := 0.9     # м — персональный постоянный боковой сдвиг линии (racecraft-разброс:
                                  # соперники не едут гуськом по одной осевой). Плавный, не per-frame
                                  # → не возвращает синусоиду (в отличие от старого lane_offset+separation)
# РАЗНЫЕ ХАРАКТЕРЫ ВОДИТЕЛЕЙ (как Forza Drivatars): каждый быстр на прямой ИЛИ в повороте
# (_pace/_corner антикоррелированы) → они МЕНЯЮТСЯ местами (один уходит на прямой, другой отыгрывает
# в поворотах) = живая борьба, а не одинаковый блоб. Плюс:
#  • catch-up ТОЛЬКО для отстающих (лидер не придерживается → пелетон не склеивается);
#  • слипстрим/драфт: машина прямо впереди → буст (закрываемся и идём на ОБГОН — «попытка что-то сделать»).
const PACK_SPAN := 90.0           # м — отставание от центра пелетона, на котором catch-up максимален
const PACK_CATCHUP := 1.12        # макс. множитель для отстающего (лидера НЕ трогаем → без склейки)
const DRAFT_RANGE := 15.0         # м — дальность слипстрима за машиной впереди
const DRAFT_CONE_COS := 0.8       # ±37° — «прямо по курсу» для драфта
const DRAFT_MAX := 0.16           # макс. буст скорости в слипстриме (сетап обгона)

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

# ================= REDESIGN v4 — Blackboard + Perception (Phase 1) =================
# Типизированная классификация соперников (TORCS opponent.cpp) — заполняется раз в тик,
# потребляется FSM/offset/speed в P2+. В P1 НЕ меняет поведение: только собирает данные + верификация.
# docs/RACER_AI_CONTROL_ARCHITECTURE.md §2 (Blackboard), §5 M1/M2.
const OPP_FRONT := 1
const OPP_FRONT_FAST := 2
const OPP_BACK := 4
const OPP_SIDE := 8
const OPP_COLL := 16
const OPP_LETPASS := 32
const PERC_FRONT_DIST := 90.0     # м — сектор внимания впереди (TORCS 200 на длинных; у нас трассы короче)
const PERC_BACK_DIST := 45.0      # м — сектор сзади (угроза защиты)
const PERC_CAR_LEN := 4.3         # м — «впереди/сзади» дальше этого (длина машины)
const PERC_SPEED_MARGIN := 1.5    # м/с — «быстрее меня» для угрозы сзади (OPP_BACK)
const PERC_SIDE_GAP := 4.5        # м — |gap| меньше → колесо-в-колесо (overlap lockout в P3)
const PERC_COLL_LAT := 2.1        # м — боковой зазор для OPP_COLL (тормозим, пока не ушли вбок)
const PERC_COLL_TTC := 2.6        # с — time-to-collision для OPP_COLL (раньше начинаем осторожничать)
const REACQUIRE_RADIUS := 15.0    # м — дальше от линии → _bb_lost (переску с heading tie-break, Nav2 #3367)

# Восстановление после застревания (NFS-подход, Game AI Pro ch.38: не респавнить по одному кадру,
# интегрировать неподвижность по времени, дать шанс выехать самому, респавн — крайняя мера).
var recovery_timer: float = 0.0     # таймер текущего реверс-манёвра
var _flip_timer: float = 0.0        # сколько секунд машина перевёрнута
var _last_respawn_progress: float = -1.0  # где респавнились в прошлый раз (детект loop)
var _stuck_prog_anchor: float = 0.0  # race_progress в начале длинного окна (респавн — крайняя мера)
var _stuck_win_timer: float = 0.0    # длительность длинного окна, с
var _rev_prog_anchor: float = 0.0    # race_progress в начале короткого окна (реверс-нюдж)
var _rev_win_timer: float = 0.0      # длительность короткого окна, с
var _reverse_streak: int = 0         # подряд неудачных реверсов без прогресса (→ респавн)
const MAX_REVERSE_STREAK := 3        # столько реверсов не помогло → препятствие непроходимо → респавн
var _recovery_start_pos: Vector3 = Vector3.ZERO  # позиция в начале реверс-манёвра (для лога «сдвинулись?»)
# Диагностика (для честного трейса в main.gd RACE_AUTOTEST)
var dbg_urgency := 0.0
var dbg_safe := 0.0
var dbg_blocked := false
var _respawn_defers: int = 0        # сколько раз подряд отложили телепорт (игрок рядом)
const RESPAWN_MAX_DEFERS := 2       # после стольких отсрочек телепортируем даже рядом с игроком
const STUCK_MOVE_MIN := 1.0         # м — прирост race_progress за окно ниже которого = застряли → респавн
const STUCK_WINDOW := 5.5           # с — окно респавна (крайняя мера, спек юзера: <1 м за 5-7 с)
const REVERSE_AFTER := 1.5          # с окно проверки продвижения → реверс-нюдж (пробуем выехать сами)
const REVERSE_PROG_MIN := 0.6       # м — прирост race_progress за REVERSE_AFTER ниже которого = не растём
const STUCK_SPEED_MAX := 12.0       # км/ч — «застрял» = НЕ растёт прогресс И скорость ниже этого. КЛЮЧ:
                                    # прогресс замирает и когда машина УЕХАЛА С МАРШРУТА на скорости
                                    # (проекция не продвигается) — там реверс НЕ нужен (pursuit сам вернёт),
                                    # поэтому реверс/респавн только если машина РЕАЛЬНО почти стоит.
const RECOVERY_REVERSE_TIME := 1.2  # с длительность одного реверс-манёвра
const FLIP_UP_Y := 0.2              # up-вектор ниже → считаем перевёрнутой
const FLIP_TIMEOUT := 1.5           # с перевёрнутой → сразу респавн (реверсом не встать)
const RESPAWN_HIDE_DIST := 60.0     # м — ближе к игроку жёсткий телепорт не делаем (маскируем)
# P7 anti-spin: traction-control кламп (замер: нормальная езда slip<1 м/с → в норме no-op)
const TCL_SLIP := 2.0               # м/с допустимого переспина колёс (TORCS filterTCL) — дальше режем газ
const TCL_RANGE := 10.0             # м/с диапазон, за который газ сбрасывается в ноль по мере роста slip

# ShapeCast (толстый «луч»-сфера) для обнаружения помех: тонкие объекты (столбы, узкие стены)
# проскакивают МЕЖДУ обычными лучами; сфера радиуса CTX_FEELER_RADIUS их ловит.
var obstacle_check_ray: ShapeCast3D
const CTX_FEELER_RADIUS := 0.7    # м — радиус сферы feeler'а (толщина коридора ≈ ширина машины)

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
var _kinematic := false           # едем кинематически по линии (чанк под нами не загружен — LOD)
var lod_disabled := false         # BENCH-only: отключает terrain kinematic-LOD (ai_bench смотрит сверху
                                  # >200м → иначе форсит кинематику). В проде всегда false, нулевая стоимость.
var _pace := 1.0                  # множитель прямолинейной скорости (быстр на прямой)
var _corner := 1.0                # множитель поворотной скорости (антикоррелирован с _pace → трейды)

# Blackboard (P1) — заполняется _perception_update, потребляется FSM/offset/speed в P2+
var _bb_speed_ms := 0.0
var _bb_forward := Vector3.FORWARD     # плоский курс (-Z)
var _bb_perp := Vector3.RIGHT          # правый вектор линии (+ = как offset/steer/curv; Reality Check §A)
var _bb_curv_ahead := 0.0              # знаковая кривизна впереди (знак = сторона; inside-of-corner в P3)
var _bb_half_ahead := RL_DEFAULT_HALF  # запечённая полуширина коридора (кламп offset в P3)
var _bb_lost := false                  # машина далеко от линии (переску не нашёл близко)
var _bb_opp: Array = []                # [{node,is_rival,is_traffic,is_player,gap,lat,vel,speed,catchdist,flags}]
var _bb_nearest_front: Dictionary = {}
var _bb_rear_threat: Dictionary = {}
var _bb_side_car: Dictionary = {}
var _bb_gap_to_player := 0.0           # знак: + = я впереди игрока (rubber-band в P6)

# Mode FSM (P2 skeleton — только RACE; переходы OVERTAKE/DEFEND/DRAFT добавит P3)
enum Mode { RACE, OVERTAKE, DEFEND, DRAFT }
var _mode := Mode.RACE
var _myoffset := 0.0               # текущее боковое смещение ЦЕЛИ (плавное, rate-limited → не синусоида)
const OFFSET_RATE := 4.5           # м/с — темп изменения _myoffset (успеть уйти на полосу ДО контакта)
# Персона (Ch.38): биоритм медленно модулирует темп → окна уязвимости → поле МЕНЯЕТСЯ местами
var _race_time := 0.0              # детерминированный аккумулятор времени гонки (без Time/Date)
var _bio_phase := 0.0              # персональная фаза биоритма
const BIO_PERIOD := 45.0           # с — период биоритма
const BIO_DEPTH := 0.07            # ±7% модуляция темпа (короткие окна уязвимости)

# Racecraft (P3): OVERTAKE (TORCS getOffset pass-side) + DEFEND (Ch.38 one-move) + фильтры (filterSColl/BColl)
var _overtake_lockout := 0.0       # с — блок повторного входа в OVERTAKE после аборта (антиосцилляция)
var _defend_side := 0.0            # закоммиченная сторона прикрытия (одно движение)
var _defend_timer := 0.0           # длительность текущей защиты
const OVERTAKE_TIME := 2.5         # с — гейт коммита: time_to_overtake = catchdist/speed < этого
const OVERTAKE_ABORT_LOCK := 2.5   # с — после выхода из OVERTAKE не входим снова (антифлип)
const DEFEND_MAX_T := 3.0          # с — макс длительность защиты (потом отпускаем)
const OFFSET_STEP := 2.2           # м — боковой уход на обгон/защиту (в пределах коридора)
const CAR_HALF_W := 0.95           # м — полуширина машины (кламп offset к коридору)
const SIDECOLL_MARGIN := 2.6       # м — боковой зазор filterSColl (не въезжаем в машину сбоку)

# Recovery hardening (P4): STK collision-count (грайндинг о стену) + sign-product guard (нет ложных реверсов)
var _collision_times: Array = []   # времена (_race_time) столкновений со СТАТИКОЙ (не с машинами)
const COLL_COUNT_N := 3            # столько столкновений за окно = трёмся о стену → реверс
const COLL_COUNT_WINDOW := 1.2     # с — окно накопления (быстрее ловим грайндинг о стену)
const COLL_DEBOUNCE := 0.2         # с — дедуп (Bullet шлёт контакт много раз)
const COLL_AGE := 4.0              # с — старше этого выбрасываем
const LOST_SPEED_CAP := 45.0       # км/ч — потолок скорости пока машина далеко от линии (re-acquire)

# P6: IDM follow-brake (Treiber) + rubber-band (умеренный аркадный) — закрывают punt/passthrough + держат гонку близкой
const IDM_T := 1.4                 # с — safe time gap
const IDM_S0 := 3.0                # м — min standstill gap
const IDM_A := 3.0                 # м/с² — accel scale (для s*)
const IDM_B := 4.0                 # м/с² — comfort brake (для s*)
const IDM_LANE_W := 1.9            # м — машина впереди в этом боковом зазоре = «в моей полосе» → тормозим
const RB_DEADZONE := 25.0          # м — мёртвая зона (честно колесо-в-колесо, никакой резинки рядом)
const RB_K_AHEAD := 0.0018         # наклон forward banding (впереди игрока → чуть медленнее)
const RB_MIN_AHEAD := 0.88         # −12% макс (throttle-ahead виден игроку → держим слабым)
const RB_K_BEHIND := 0.0024        # наклон reverse banding (позади игрока → помощь, сильнее)
const RB_MAX_BEHIND := 1.16        # +16% макс (help-behind незаметно/оффскрин → сильнее; АСИММЕТРИЯ)

# Телеметрия (off by default — нулевая стоимость в обычной игре; включает тест-сцена)
var ai_debug := false
var debug_target_point: Vector3 = Vector3.ZERO
var _debug_samples: Array = []
var _debug_sections: Array = []   # [{name, start_m, end_m}]
var _debug_t := 0.0               # аккумулятор времени (детерминированно, без Time/Date)
var _recovery_count := 0
# Phase 0 — метрика столкновений (ТЕСТ-ONLY, armed через enable_collision_metric). contact_monitor уже включён.
# Считаем НОВЫЕ контакты по слою: статика (столб/дерево/здание, слой 2) vs динамика (NPC 4 / соперник 128).
# Статику дополнительно тегаем «в повороте» (|кривизна|>порог) — это число, которое надо ронять.
var _collmetric := false
var m_static_hits := 0
var m_dynamic_hits := 0
var m_npc_hits := 0        # контакты с NPC-трафиком (слой 4)
var m_racer_hits := 0      # контакты с другими соперниками (слой 128)
var m_corner_static_hits := 0
var _coll_touching: Dictionary = {}   # instance_id → true (дебаунс контакта)
var _static_hit_curvs: Array = []     # |кривизна| на каждом статическом контакте (corner vs straight из данных)
var _coll_events: Array = []          # [prog_m, speed_kmh, kind] на каждый контакт — где/почему бьются
const CORNER_CURV_METRIC := 0.012     # |кривизна|>0.012 → R<~83 м → «поворот» (city sweepers)
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
	obstacle_check_ray = ShapeCast3D.new()
	obstacle_check_ray.enabled = false  # не тикает каждый кадр сам — форсим вручную по слотам
	var feeler_shape := SphereShape3D.new()
	feeler_shape.radius = CTX_FEELER_RADIUS
	obstacle_check_ray.shape = feeler_shape
	obstacle_check_ray.collision_mask = 2 | 8 | 128 | 1 | 4  # +4: NPC-трафик (P5) — раньше проезжали насквозь
	obstacle_check_ray.max_results = 6
	add_child(obstacle_check_ray)
	obstacle_check_ray.add_exception(self)  # feeler'ы не должны ловить собственный кузов (слой 128)

	# Добавляем в группу для идентификации
	add_to_group("race_opponent")

	# P4: включаем контакт-монитор для STK collision-count детектора (грайндинг о стену)
	contact_monitor = true
	max_contacts_reported = 4
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

	# Рандомизируем параметры AI для вариативности
	skill_level = randf_range(0.85, 1.0)
	aggression = randf_range(0.5, 0.9)
	# Тесные городские улицы: 84 км/ч → вылеты и постоянные recovery. Держим скорость,
	# которую реально сдюжить чисто (меньше аварий = меньше мёртвого времени на respawn).
	# v3: per-car target_speed РАЗВОДИТ поле (racecraft эмерджентен), а НЕ статический lane_offset
	# (тот сдвигал pursuit-цель и давал синусоиду — удалён, см. RACER_AI_REDESIGN_PLAN §4).
	target_speed = randf_range(46.0, 62.0)
	_line_bias = randf_range(-RL_LINE_BIAS_MAX, RL_LINE_BIAS_MAX)  # персональная полоса (racecraft-разброс)
	# Разный характер: быстр на прямой ИЛИ в повороте (антикорреляция) → меняются местами
	_pace = randf_range(0.92, 1.08)
	_corner = 2.0 - _pace
	_bio_phase = randf() * TAU  # персональная фаза биоритма (окна уязвимости в разное время)


func _physics_process(delta: float) -> void:
	# TERRAIN LOD (как в NFS/Forza): если чанк под машиной не загружен (уехала вперёд игрока в
	# невыгруженный террейн) — НЕ симулируем физику (иначе проваливается под карту), а едем
	# кинематически по гоночной линии. Когда террейн снова под нами — приземляемся и возвращаем физику.
	if ai_state == AIState.RACING and _line.size() >= 2:
		var loaded := _terrain_reliable_here()
		if _kinematic:
			if loaded:
				_exit_kinematic()  # террейн вернулся → физика (проваливаемся дальше в match)
			else:
				_kinematic_step(delta)
				return
		elif not loaded:
			_enter_kinematic()
			_kinematic_step(delta)
			return

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

			if _collmetric:
				_tally_collisions()

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


func enable_collision_metric() -> void:
	"""Phase 0 (ТЕСТ-ONLY): включить подсчёт столкновений. contact_monitor уже true в _ready."""
	_collmetric = true
	max_contacts_reported = maxi(max_contacts_reported, 8)


func get_collision_metric() -> Dictionary:
	return {"static": m_static_hits, "dynamic": m_dynamic_hits, "corner_static": m_corner_static_hits,
		"npc": m_npc_hits, "racer": m_racer_hits, "static_curvs": _static_hit_curvs, "events": _coll_events}


func _tally_collisions() -> void:
	"""Считаем НОВЫЕ контакты по слою столкновения (дебаунс через _coll_touching). Слой земли/дороги (1)
	игнорируем — машина всегда на ней. Слой 2 = статика (столб/дерево/здание); 4/128 = NPC/соперник."""
	var now: Dictionary = {}
	for b in get_colliding_bodies():
		if b == null:
			continue
		var iid: int = b.get_instance_id()
		now[iid] = true
		if _coll_touching.has(iid):
			continue
		var layer: int = b.collision_layer
		var kind := ""
		if layer & 2:
			m_static_hits += 1
			_static_hit_curvs.append(snappedf(absf(_bb_curv_ahead), 0.001))
			if absf(_bb_curv_ahead) > CORNER_CURV_METRIC:
				m_corner_static_hits += 1
			kind = "corner" if absf(_bb_curv_ahead) > CORNER_CURV_METRIC else "static"
		elif layer & 128:
			m_dynamic_hits += 1
			m_racer_hits += 1
			kind = "racer"
		elif layer & 4:
			m_dynamic_hits += 1
			m_npc_hits += 1
			kind = "npc"
		if kind != "" and _coll_events.size() < 60:
			_coll_events.append([roundi(race_progress), roundi(current_speed_kmh), kind])
	_coll_touching = now


func set_persona(pace: float, aggr: float, bias: float, bio_phase: float = 0.0) -> void:
	"""BENCH-only: детерминированно задать характер водителя (иначе _ready рандомит).
	pace = множитель прямолинейной скорости (быстр на прямой ⇄ в повороте, антикоррелирован)."""
	_pace = pace
	_corner = 2.0 - pace
	aggression = clampf(aggr, 0.0, 1.0)
	_line_bias = clampf(bias, -RL_LINE_BIAS_MAX, RL_LINE_BIAS_MAX)
	_bio_phase = bio_phase


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
	_stuck_prog_anchor = race_progress
	_stuck_win_timer = 0.0
	_rev_prog_anchor = race_progress
	_rev_win_timer = 0.0
	_reset_line_projection()  # синхронизируем арк-дистанцию проекции на K1999-линию


func finish_race() -> void:
	"""Завершает гонку для этого AI"""
	if _kinematic:  # финишировал на кинематике (оффскрин) → вернуть физику, чтобы осел на землю
		_kinematic = false
		freeze = false
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
	_perception_update()  # P1: Blackboard
	_race_time += UPDATE_INTERVAL
	var speed_ms: float = current_speed_kmh / 3.6
	var ld: float = clampf(LD_K * speed_ms, LD_MIN, LD_MAX)
	_lookahead_dist = ld  # для телеметрии
	# [P2] Mode FSM (пока только RACE) → целевое боковое смещение → ПЛАВНЫЙ _myoffset (заменил
	# статический _line_bias-сдвиг). Rate-limited → не per-frame jitter → не возвращает синусоиду.
	_mode = _fsm_update()
	var offset_target: float = _mode_offset(_mode)
	# overlap lockout (TORCS): не двигаем offset В СТОРОНУ машины сбоку — держим полосу
	if not _bb_side_car.is_empty():
		var sl: float = float(_bb_side_car["lat"])
		if absf(sl) < SIDECOLL_MARGIN and signf(offset_target - _myoffset) == signf(sl):
			offset_target = _myoffset
	_myoffset = move_toward(_myoffset, offset_target, OFFSET_RATE * UPDATE_INTERVAL)
	var aim_s := _line_sample(_line_arc + ld)
	var aim: Vector3 = aim_s["pos"]
	if absf(_myoffset) > 0.001:
		var atang: Vector3 = aim_s["tangent"]
		aim += Vector3(-atang.z, 0.0, atang.x) * _myoffset

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
	steering_input = _filter_scoll(steering_input)  # P3: корректирующий руль прочь от машины сбоку

	# [B] Скорость ГОВОРИТ фрикционный профиль (честный предел: быстро на прямой, безопасно в апексе) —
	# НЕ искусственный потолок target_speed (тот throttl'ил соперников до ~55 км/ч вдвое медленнее игрока).
	# Профиль дифференцируем характером (быстр на прямой _pace vs в повороте _corner), а catch-up/слипстрим
	# бустят в основном на ПРЯМЫХ (в апексе буст = вылет). ctx.speed_scale тормозит при объезде статики.
	var v_prof_ms: float = _line_sample(_line_arc + SPEED_PREVIEW).vmax
	var curviness: float = clampf(1.0 - v_prof_ms / SP_TOP, 0.0, 1.0)         # 0 прямая … 1 крутой поворот
	var v_base_kmh: float = v_prof_ms * 3.6 * lerpf(0.95, 1.08, aggression) * lerpf(_pace, _corner, curviness) * _biorhythm()
	var boost: float = 1.0 + (_catchup_factor() - 1.0 + _draft_boost() - 1.0) * (1.0 - curviness)
	var race_scale: float = lerpf(RACER_SCALE_CORNER, RACER_SCALE_STRAIGHT, 1.0 - curviness)  # прямые↑, апексы↓
	var v_want_kmh: float = v_base_kmh * boost * float(ctx["speed_scale"]) * race_scale
	if _bb_lost:
		v_want_kmh = minf(v_want_kmh, LOST_SPEED_CAP)  # P4: далеко от линии → снижаем скорость, целимся к ближней точке
	v_want_kmh = _idm_follow_cap(v_want_kmh)  # P6: не влетаем в машину/трафик прямо впереди в полосе
	v_want_kmh *= _rubberband()               # P6: умеренная резинка (мёртвая зона + асимметрия + затухание)
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
	# P7 P1: кламп тяги (TORCS filterTCL) — срезаем газ при пробуксовке (slip>2 м/с). В нормале slip<1 → no-op.
	throttle_input = _filter_tcl(throttle_input)
	brake_input = _filter_bcoll(brake_input)  # P3: тормоз при неминуемом догоне машины прямо впереди

	# Диагностика
	dbg_urgency = 1.0 - float(ctx["speed_scale"])
	dbg_safe = v_want_kmh
	dbg_blocked = bool(ctx["active"])

	if ai_debug:
		_record_debug_sample(heading_error, steer_raw, bool(ctx["active"]))


func _curv_ahead_signed(arc: float) -> float:
	"""Знаковая кривизна линии на арк-дистанции (знак = сторона поворота; + = к +perp)."""
	if _line.size() < 2:
		return 0.0
	var top: float = float(_line[_line.size() - 1]["arc"])
	return float(_line[_line_index_for_arc(clampf(arc, 0.0, top))]["curv"])


func _line_half_at(arc: float) -> float:
	"""Запечённая полуширина коридора линии на арк-дистанции (для клампа offset)."""
	if _line.size() < 2:
		return RL_DEFAULT_HALF
	var top: float = float(_line[_line.size() - 1]["arc"])
	return float(_line[_line_index_for_arc(clampf(arc, 0.0, top))]["half"])


func _perception_update() -> void:
	"""P1 — заполняет Blackboard: self + типизированные соперники (TORCS opponent.cpp) + gap до игрока.
	NO behaviour change: данные НЕ потребляются рулёжкой/скоростью до P2+. Классификация по флагам
	OPP_FRONT/FRONT_FAST/BACK/SIDE/COLL. Скорость соперников читается (rivals/traffic/player — все RigidBody3D)."""
	_bb_speed_ms = current_speed_kmh / 3.6
	var s := _line_sample(_line_arc)
	var tang: Vector3 = s["tangent"]
	# forward для перцепции = КАСАТЕЛЬНАЯ ЛИНИИ (направление РОСТА арк = движение), НЕ facing (-basis.z):
	# соперники развёрнуты (facing ≠ travel — flip 180° при спавне), иначе front/back инвертируются.
	_bb_forward = Vector3(tang.x, 0.0, tang.z).normalized()
	_bb_perp = Vector3(-tang.z, 0.0, tang.x)
	_bb_curv_ahead = _curv_ahead_signed(_line_arc + 12.0)
	_bb_half_ahead = _line_half_at(_line_arc)
	_bb_lost = _line_lateral > REACQUIRE_RADIUS

	_bb_opp.clear()
	_bb_nearest_front = {}
	_bb_rear_threat = {}
	_bb_side_car = {}
	var best_front := INF
	var best_back := INF
	var fwd2 := Vector2(_bb_forward.x, _bb_forward.z)
	var perp2 := Vector2(_bb_perp.x, _bb_perp.z)

	for group_name in ["race_opponent", "traffic", "player"]:
		for o in get_tree().get_nodes_in_group(group_name):
			if o == self or not is_instance_valid(o):
				continue
			var other := o as Node3D
			if other == null:
				continue
			var rel := other.global_position - global_position
			var rel2 := Vector2(rel.x, rel.z)
			if rel2.length() > PERC_FRONT_DIST:
				continue
			var gap := rel2.dot(fwd2)          # + = впереди меня по курсу (along-track аппрокс)
			var lat := rel2.dot(perp2)         # + = справа (perp basis, как offset/steer/curv)
			var ovel: Vector3 = (o as RigidBody3D).linear_velocity if o is RigidBody3D else Vector3.ZERO
			var ospeed := ovel.length()
			var closing := _bb_speed_ms - ospeed
			var flags := 0
			var catchdist := 0.0
			if gap > PERC_CAR_LEN:
				if ospeed < _bb_speed_ms - 0.2:
					flags |= OPP_FRONT
					catchdist = _bb_speed_ms * gap / maxf(0.3, closing)
				else:
					flags |= OPP_FRONT_FAST
			elif gap < -PERC_CAR_LEN:
				if ospeed > _bb_speed_ms - PERC_SPEED_MARGIN and rel2.length() < PERC_BACK_DIST:
					flags |= OPP_BACK
			if absf(gap) < PERC_SIDE_GAP:
				flags |= OPP_SIDE
			if (flags & OPP_FRONT) != 0 and absf(lat) < PERC_COLL_LAT and closing > 0.2 \
					and (gap / maxf(0.3, closing)) < PERC_COLL_TTC:
				flags |= OPP_COLL
			var rec := {
				"node": o, "is_rival": group_name == "race_opponent",
				"is_traffic": group_name == "traffic", "is_player": group_name == "player",
				"gap": gap, "lat": lat, "vel": ovel, "speed": ospeed,
				"catchdist": catchdist, "flags": flags,
			}
			_bb_opp.append(rec)
			if (flags & OPP_FRONT) != 0 and gap < best_front:
				best_front = gap
				_bb_nearest_front = rec
			if (flags & OPP_BACK) != 0 and (-gap) < best_back:
				best_back = -gap
				_bb_rear_threat = rec
			if (flags & OPP_SIDE) != 0:
				_bb_side_car = rec

	# gap до игрока по ДУГЕ маршрута (для rubber-band P6; проекция игрока на маршрут)
	var pl := get_tree().get_first_node_in_group("player")
	if pl != null and is_instance_valid(pl) and race_route != null and race_route.points.size() >= 2:
		var pp := race_route.project_position((pl as Node3D).global_position, 0)
		_bb_gap_to_player = race_progress - float(pp["distance"])


func get_perception_debug() -> String:
	"""BENCH/тест: краткая сводка Blackboard для верификации P1."""
	var nf := "none"
	if not _bb_nearest_front.is_empty():
		nf = "gap=%.0f lat=%.1f spd=%.0f cd=%.0f" % [
			_bb_nearest_front["gap"], _bb_nearest_front["lat"],
			float(_bb_nearest_front["speed"]) * 3.6, _bb_nearest_front["catchdist"]]
	return "opp=%d front[%s] rear=%s side=%s gapPl=%.0f curv=%.3f half=%.1f lost=%s" % [
		_bb_opp.size(), nf,
		"y" if not _bb_rear_threat.is_empty() else "n",
		"y" if not _bb_side_car.is_empty() else "n",
		_bb_gap_to_player, _bb_curv_ahead, _bb_half_ahead, str(_bb_lost)]


func _fsm_update() -> int:
	"""Mode FSM (Ch.38 §38.5): один активный режим, с гистерезисом (держим текущий до условия выхода)
	+ abort-lockout. Приоритет: OVERTAKE (атака) > DEFEND (сзади угроза) > RACE. RECOVER — отдельно (P4)."""
	if _overtake_lockout > 0.0:
		_overtake_lockout -= UPDATE_INTERVAL

	var can_overtake := false
	if _overtake_lockout <= 0.0 and not _bb_nearest_front.is_empty():
		var cd: float = float(_bb_nearest_front["catchdist"])
		if cd > 0.0 and cd / maxf(3.0, _bb_speed_ms) < OVERTAKE_TIME:
			can_overtake = true

	match _mode:
		Mode.OVERTAKE:
			# держим, пока есть догоняемая машина впереди; ушла/поравнялись → RACE + lockout
			if _bb_nearest_front.is_empty() or float(_bb_nearest_front["gap"]) < PERC_CAR_LEN:
				_overtake_lockout = OVERTAKE_ABORT_LOCK
				return Mode.RACE
			return Mode.OVERTAKE
		Mode.DEFEND:
			_defend_timer += UPDATE_INTERVAL
			# одно движение: отпускаем, если угроза ушла / поравнялись / вышло время (F1 rule)
			if _bb_rear_threat.is_empty() or _defend_timer > DEFEND_MAX_T or not _bb_side_car.is_empty():
				return Mode.RACE
			return Mode.DEFEND
		_:  # RACE
			if can_overtake:
				return Mode.OVERTAKE
			if not _bb_rear_threat.is_empty():
				_defend_timer = 0.0
				_defend_side = signf(float(_bb_rear_threat["lat"]))  # прикрываем сторону преследователя
				if _defend_side == 0.0:
					_defend_side = 1.0
				return Mode.DEFEND
			return Mode.RACE


func _mode_offset(mode: int) -> float:
	"""Целевое боковое смещение цели по режиму (perp-базис линии; + = как offset/steer/curv).
	OVERTAKE = сторона обгона (TORCS getOffset); DEFEND = прикрытие; RACE = персональная полоса."""
	var lim: float = maxf(0.0, _bb_half_ahead - CAR_HALF_W - 0.3)
	match mode:
		Mode.OVERTAKE:
			return clampf(_pass_side() * OFFSET_STEP, -lim, lim)
		Mode.DEFEND:
			return clampf(_defend_side * OFFSET_STEP * 0.8, -lim, lim)
		_:
			return clampf(_line_bias, -lim, lim)


func _pass_side() -> float:
	"""Сторона обгона (TORCS getOffset): машина сбоку → её ОТКРЫТАЯ сторона; по центру → ВНУТРЬ
	следующего поворота (sign кривизны). Всё в perp-базисе (+ = как offset/curv), без human L/R."""
	if _bb_nearest_front.is_empty():
		return signf(_line_bias)
	var opp_lat: float = float(_bb_nearest_front["lat"])  # + = соперник справа (в +perp)
	if opp_lat > 1.0:
		return -1.0   # соперник справа → обгон слева
	elif opp_lat < -1.0:
		return 1.0    # соперник слева → обгон справа
	# по центру: внутрь следующего поворота (+curv = правый поворот = +perp)
	if absf(_bb_curv_ahead) > 0.001:
		return signf(_bb_curv_ahead)
	return 1.0 if _line_bias >= 0.0 else -1.0


func _filter_scoll(steer: float) -> float:
	"""TORCS filterSColl: машина сбоку в пределах SIDECOLL_MARGIN → корректирующий руль ПРОЧЬ от неё
	(держим полосу, не въезжаем). Не борется с pursuit — лишь подталкивает от соседа."""
	if _bb_side_car.is_empty():
		return steer
	var lat: float = float(_bb_side_car["lat"])  # + = сосед справа
	if absf(lat) < SIDECOLL_MARGIN and absf(lat) > 0.01:
		var push: float = (SIDECOLL_MARGIN - absf(lat)) / SIDECOLL_MARGIN  # 0..1, сильнее вблизи
		steer -= signf(lat) * push * 0.4   # сосед справа → руль влево (прочь)
	return clampf(steer, -1.0, 1.0)


func _filter_bcoll(brake: float) -> float:
	"""TORCS filterBColl: неминуемый догон машины прямо впереди (OPP_COLL) → подмешиваем тормоз по TTC."""
	if _bb_nearest_front.is_empty():
		return brake
	if (int(_bb_nearest_front["flags"]) & OPP_COLL) != 0:
		var gap: float = float(_bb_nearest_front["gap"])
		return maxf(brake, clampf(1.0 - gap / 12.0, 0.2, 0.9))
	return brake


func _biorhythm() -> float:
	"""Медленная модуляция темпа (Ch.38): ±BIO_DEPTH синусоида → окна уязвимости → трейды позициями."""
	return 1.0 + BIO_DEPTH * sin(TAU * _race_time / BIO_PERIOD + _bio_phase)


func _idm_follow_cap(v_want_kmh: float) -> float:
	"""IDM/TTC follow-brake (Treiber): не влетаем в машину/трафик ПРЯМО ВПЕРЕДИ В ПОЛОСЕ. Если ушли
	вбок (обгон) — не тормозим. s* = s0 + v·T + v·Δv/(2√(a·b)); слишком близко → держим скорость передней."""
	if _bb_nearest_front.is_empty():
		return v_want_kmh
	if absf(float(_bb_nearest_front["lat"])) > IDM_LANE_W:
		return v_want_kmh  # передняя машина сбоку (обходим) — тормоз не нужен
	var gap_bumper: float = maxf(0.1, float(_bb_nearest_front["gap"]) - PERC_CAR_LEN)
	var dv: float = _bb_speed_ms - float(_bb_nearest_front["speed"])  # closing (+ = догоняем)
	var s_star: float = IDM_S0 + _bb_speed_ms * IDM_T + _bb_speed_ms * dv / (2.0 * sqrt(IDM_A * IDM_B))
	if s_star > gap_bumper:
		return minf(v_want_kmh, float(_bb_nearest_front["speed"]) * 3.6 + 4.0)
	return v_want_kmh


func _rubberband() -> float:
	"""Умеренный аркадный rubber-band (Melder): мёртвая зона у игрока (честно), кламп ±~15%, АСИММЕТРИЯ
	(help-behind сильнее throttle-ahead), затухание в последней четверти (заработанный отрыв держится)."""
	if race_route == null or race_route.total_length < 1.0:
		return 1.0
	var d := _bb_gap_to_player  # + = я впереди игрока
	var band := 1.0
	if absf(d) >= RB_DEADZONE:
		if d > 0.0:
			band = clampf(1.0 - RB_K_AHEAD * (d - RB_DEADZONE), RB_MIN_AHEAD, 1.0)
		else:
			band = clampf(1.0 + RB_K_BEHIND * (-d - RB_DEADZONE), 1.0, RB_MAX_BEHIND)
	var frac: float = race_progress / race_route.total_length
	var fade: float = clampf((1.0 - frac) / 0.25, 0.0, 1.0) if frac > 0.75 else 1.0
	return 1.0 + (band - 1.0) * fade


func get_mode() -> int:
	return _mode


func _catchup_factor() -> float:
	"""Мягкий catch-up ТОЛЬКО для отстающих (лидера не трогаем → пелетон не склеивается в блоб).
	Чем дальше позади среднего прогресса СОПЕРНИКОВ (не игрока) — тем больше буст, до PACK_CATCHUP."""
	var sum := 0.0
	var cnt := 0
	for o in get_tree().get_nodes_in_group("race_opponent"):
		if is_instance_valid(o):
			sum += float(o.race_progress)
			cnt += 1
	if cnt < 2:
		return 1.0
	var behind: float = maxf(0.0, sum / float(cnt) - race_progress)  # насколько ПОЗАДИ центра
	return lerpf(1.0, PACK_CATCHUP, clampf(behind / PACK_SPAN, 0.0, 1.0))


func _draft_boost() -> float:
	"""Слипстрим: если прямо по курсу в DRAFT_RANGE идёт соперник — буст скорости (закрываемся и
	готовим обгон). Даёт «попытку что-то сделать»: догнал в аэродинамической тени → вышел и обошёл."""
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var best := 0.0
	for o in get_tree().get_nodes_in_group("race_opponent"):
		if o == self or not is_instance_valid(o):
			continue
		var to: Vector3 = (o as Node3D).global_position - global_position
		to.y = 0.0
		var d := to.length()
		if d < 1.0 or d > DRAFT_RANGE:
			continue
		if to.normalized().dot(fwd) > DRAFT_CONE_COS:
			best = maxf(best, 1.0 - d / DRAFT_RANGE)  # ближе → сильнее
	return 1.0 + best * DRAFT_MAX


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
	if col.is_in_group("race_opponent") or col.is_in_group("player") or col.is_in_group("car") \
			or col.is_in_group("traffic"):
		var to_hit := Vector3(hitpoint.x - global_position.x, 0.0, hitpoint.z - global_position.z)
		if to_hit.length() < 0.01:
			return 0
		if to_hit.normalized().dot(forward_flat) < CTX_CAR_AHEAD_COS:
			return 0  # машина сбоку/сзади — НЕ помеха (обгоняемый/обгоняемый трафик держит линию)
		return 2  # машина/трафик ВПЕРЕДИ — динамическая помеха (объезд/обгон)
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

	# Feeler'ы: толстый ShapeCast-сфера на слот (тонкие столбы/стены не проскакивают между лучами).
	# Глобальный basis прибит к identity (target_position — ЛОКАЛЬНА).
	var from: Vector3 = global_position + Vector3(0.0, CTX_FEELER_Y, 0.0)
	for i in CTX_SLOTS:
		obstacle_check_ray.global_transform = Transform3D(Basis.IDENTITY, from)
		obstacle_check_ray.target_position = (dirs[i] as Vector3) * reach
		obstacle_check_ray.force_shapecast_update()
		if not obstacle_check_ray.is_colliding():
			continue
		# Классифицируем ВСЕ хиты слота (сфера ловит несколько): игнор земли/машины-сбоку,
		# приоритет статике/машине-впереди. prox — по ближайшему контакту (safe fraction).
		var kind := 0
		for r in obstacle_check_ray.get_collision_count():
			var k := _classify_hit(obstacle_check_ray.get_collider(r), obstacle_check_ray.get_collision_point(r), forward_flat)
			if k > kind:
				kind = k
		if kind == 0:
			continue  # только земля/дорога/машина сбоку — игнор
		var prox: float = clampf(1.0 - obstacle_check_ray.get_closest_collision_safe_fraction(), 0.0, 1.0)
		var is_static := kind == 1
		danger[i] = maxf(float(danger[i]), prox)
		if is_static:
			stat[i] = true
		if i > 0:
			danger[i - 1] = maxf(float(danger[i - 1]), prox * CTX_SPILL)
			if is_static:
				stat[i - 1] = true
		if i < CTX_SLOTS - 1:
			danger[i + 1] = maxf(float(danger[i + 1]), prox * CTX_SPILL)
			if is_static:
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
	# Сбит/респавн: окно не нашло близкой точки → полный переску с HEADING tie-break (Nav2 #3367):
	# среди кандидатов предпочитаем сегмент, чья касательная совпадает с курсом машины — иначе
	# глобальный ближайший может прицепиться к встречной/параллельной дороге.
	if best_d > 225.0:  # >15 м
		# travel-направление = ВЕЛОСИТИ (facing у соперников развёрнут; velocity — куда реально едем)
		var vel := linear_velocity
		var moving := (vel.x * vel.x + vel.z * vel.z) > 4.0  # >2 м/с
		var fx := vel.x
		var fz := vel.z
		var best_score := best_d  # без бонуса выравнивания (окно — как есть)
		for i in range(0, n - 1):
			var d := _seg_project(pos, i)
			var pa: Vector3 = _line[i]["pos"]
			var pb: Vector3 = _line[i + 1]["pos"]
			var score: float = float(d["d2"])
			if moving and (pb.x - pa.x) * fx + (pb.z - pa.z) * fz < 0.0:
				score += 1.0e6  # встречный сегмент — сильный штраф
			if score < best_score:
				best_score = score
				best_d = float(d["d2"])
				best_arc = float(d["arc"])
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

func _on_body_entered(body: Node) -> void:
	"""STK collision-count: считаем столкновения СО СТАТИКОЙ (столбы/стены/здания), НЕ с машинами
	(иначе гонка колесо-в-колесо ложно триггерит) и НЕ с землёй. Дедуп (0.2с) + старение (4с)."""
	if body == null:
		return
	if body.is_in_group("Road") or body.is_in_group("Grass"):
		return
	if body.is_in_group("race_opponent") or body.is_in_group("player") \
			or body.is_in_group("car") or body.is_in_group("traffic"):
		return  # контакт с машиной — не грайндинг
	if _collision_times.size() > 0 and _race_time - float(_collision_times[-1]) < COLL_DEBOUNCE:
		return
	while _collision_times.size() > 0 and _race_time - float(_collision_times[0]) > COLL_AGE:
		_collision_times.pop_front()
	_collision_times.append(_race_time)


func _wedged_against_obstacle() -> bool:
	"""TORCS sign-product guard: реверс НУЖЕН, только если машина НЕ возвращается на линию сама.
	Если латеральная скорость уменьшает |offset| (едем К линии) → pursuit вернёт, реверс НЕ нужен
	(иначе ложный реверс мешает возврату). Почти стоим → заклинены → реверс уместен."""
	if _line.size() < 2:
		return true
	var lp := _line_sample(_line_arc)
	var line_pos: Vector3 = lp["pos"]
	var tang: Vector3 = lp["tangent"]
	var perp := Vector2(-tang.z, tang.x)
	var signed_lat: float = Vector2(global_position.x - line_pos.x, global_position.z - line_pos.z).dot(perp)
	var vel2 := Vector2(linear_velocity.x, linear_velocity.z)
	if vel2.length() < 0.8:
		return true  # реально стоим → реверс уместен
	var lat_vel: float = vel2.dot(perp)
	if signed_lat * lat_vel < -0.2:
		return false  # движемся К линии → не заклинены, pursuit вернёт
	return true


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

	# P4: STK collision-count — N+ столкновений СО СТАТИКОЙ за окно = трёмся о стену → реверс СРАЗУ
	# (быстрее, чем 5.5с длинного окна; ловит «долбит стену, но чуть шевелится»).
	if _collision_times.size() >= COLL_COUNT_N \
			and _race_time - float(_collision_times[0]) > COLL_COUNT_WINDOW \
			and current_speed_kmh < STUCK_SPEED_MAX and _wedged_against_obstacle():
		_collision_times.clear()
		_reverse_streak += 1  # ЭСКАЛАЦИЯ: N реверсов не помогли (стена по всей ширине) → респавн-варп вперёд
		if _reverse_streak >= MAX_REVERSE_STREAK:
			_reverse_streak = 0
			_recovery_count += 1
			_respawn_on_track()
		else:
			_start_recovery()
		return

	# «Застрял» = прогресс НЕ растёт И машина почти стоит. Если прогресс замер, но скорость высокая —
	# это НЕ застревание, а вылет с маршрута на скорости: реверс/респавн НЕ трогаем, pursuit сам вернёт
	# на линию (иначе ложный реверс мешает возврату и держит машину вне трассы — корень проблемы).
	var almost_stopped: bool = current_speed_kmh < STUCK_SPEED_MAX

	# Длинное окно (респавн — крайняя мера): почти стоим И прогресс < 1 м за STUCK_WINDOW → релокация.
	_stuck_win_timer += delta
	if _stuck_win_timer >= STUCK_WINDOW:
		if almost_stopped and race_progress - _stuck_prog_anchor < STUCK_MOVE_MIN:
			_recovery_count += 1
			_respawn_on_track()  # сам переустановит якорь/окно
			return
		_stuck_prog_anchor = race_progress  # едем (или уехали с трассы) — новое окно
		_stuck_win_timer = 0.0
		_rev_prog_anchor = race_progress
		_rev_win_timer = 0.0
		return

	# Реверс-нюдж: почти стоим И прогресс не растёт за REVERSE_AFTER = упёрлись в столб/стену → назад.
	# Если N реверсов подряд не помогли (препятствие прямо на линии, объехать не выходит) → респавн.
	_rev_win_timer += delta
	if _rev_win_timer >= REVERSE_AFTER:
		var gained: float = race_progress - _rev_prog_anchor
		_rev_prog_anchor = race_progress
		_rev_win_timer = 0.0
		if almost_stopped and gained < REVERSE_PROG_MIN:
			# P4 sign-product guard: если машина возвращается на линию сама — НЕ реверсим (ложный реверс)
			if not _wedged_against_obstacle():
				_reverse_streak = 0
				return
			_reverse_streak += 1
			if _reverse_streak >= MAX_REVERSE_STREAK:
				_reverse_streak = 0
				_recovery_count += 1
				_respawn_on_track()
			else:
				_start_recovery()
			return
		_reverse_streak = 0  # продвигаемся — серия сброшена


func _start_recovery() -> void:
	"""Реверс-манёвр: сдать назад, доворачивая нос к касательной маршрута (не респавн — сначала
	даём выехать самому). Короткое окно реверса сбрасываем (после манёвра меряем прогресс заново);
	ДЛИННОЕ окно респавна НЕ трогаем — чтобы поймать «отъехал-въехал»-цикл и всё же респавнить."""
	ai_state = AIState.RECOVERING
	recovery_timer = RECOVERY_REVERSE_TIME
	_rev_prog_anchor = race_progress
	_rev_win_timer = 0.0
	_recovery_start_pos = global_position
	if ai_debug:
		print("[RECOV] %s REVERSE start pos=(%.0f,%.0f) prog=%.0f v=%.0f" % [
			racer_name, global_position.x, global_position.z, race_progress, current_speed_kmh])


func _execute_recovery(delta: float) -> void:
	"""Едем задом, ДОВОРАЧИВАЯ нос к касательной маршрута (не случайный руль — так после реверса
	мы уже смотрим вдоль трассы). Окно застревания продолжает тикать (учёт wall-clock)."""
	recovery_timer -= delta
	_stuck_win_timer += delta  # окно идёт и во время реверса (чтобы респавн не откладывался вечно)

	if recovery_timer > 0.0:
		# ЗАДНИЙ ХОД ЧЕРЕЗ КОЛЁСА: отрицательный throttle в передней передаче → отрицательный
		# engine_force → колёса крутятся назад и СЦЕПЛЕНИЕМ тянут машину (в отличие от заданной
		# скорости, которую не-крутящиеся колёса гасят трением, и от слабой central_force). Коробка
		# сама держит переднюю передачу (из R она выкидывает на <2 км/ч), поэтому реверсим тягой.
		throttle_input = -0.9
		brake_input = 0.0

		# Ошибка курса к касательной маршрута; при заднем ходе знак руля инвертируется
		var steer_cmd := 0.0
		if race_route:
			var pd: Dictionary = race_route.get_point_at_distance(race_progress)
			var tangent: Vector3 = pd.direction
			var tflat := Vector3(tangent.x, 0, tangent.z).normalized()
			var forward := -global_transform.basis.z
			var fflat := Vector3(forward.x, 0, forward.z).normalized()
			var herr: float = atan2(tflat.cross(fflat).y, fflat.dot(tflat))
			steer_cmd = clampf(-herr * 1.2, -0.7, 0.7)
		steering_input = steer_cmd
	else:
		# Реверс завершён — назад в гонку (окно/якорь решат, помогло ли; иначе респавн позже)
		if ai_debug:
			print("[RECOV] %s REVERSE end moved=%.1fm v=%.0f" % [
				racer_name, global_position.distance_to(_recovery_start_pos), current_speed_kmh])
		ai_state = AIState.RACING


func _kin_ground_y(x: float, z: float, fallback_y: float) -> float:
	"""Высота РЕАЛЬНОГО террейна в точке (луч вниз, слой 1) — для кинематики, чтобы отслеживать
	elevation по мере загрузки. Диапазон Y 500..−300 покрывает и SRTM-высоту, и плоский base. Нет
	попадания (чанк совсем не загружен) → высота линии (оффскрин-плейсхолдер)."""
	var space := get_world_3d().direct_space_state
	if space == null:
		return fallback_y
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 500.0, z), Vector3(x, -300.0, z))
	q.collision_mask = 1
	q.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	return float(hit.position.y) if not hit.is_empty() else fallback_y


func _terrain_reliable_here() -> bool:
	"""Надёжен ли террейн под машиной? Ключевой факт (из замеров): elevation грузится ПО-ЧАНКОВО
	асинхронно — рядом с камерой террейн на реальной высоте (SRTM), а ДАЛЬШЕ мешь может отрендериться
	ПЛОСКИМ (Y=0) до прихода elevation → соперник сваливается с «обрыва» и потом оказывается ПОД
	поднявшимся террейном. Луч «есть ли земля» тут ВРЁТ (земля есть, но на неверной высоте). Надёжный
	признак — БЛИЗОСТЬ К КАМЕРЕ: только там террейн гарантированно загружен и с elevation."""
	if lod_disabled:
		return true  # BENCH-only: плоский стенд без стриминга, физика всегда надёжна
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return true
	return global_position.distance_to(cam.global_position) < KINEMATIC_SAFE_RADIUS


func _enter_kinematic() -> void:
	"""Переход на кинематику: замораживаем физику (не падаем), синхронизируем арк на линии."""
	_kinematic = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	_project_onto_line(global_position)
	if ai_debug:
		print("[LOD] %s → KINEMATIC (chunk not loaded) prog=%.0f pos=(%.0f,%.0f)" % [
			racer_name, race_progress, global_position.x, global_position.z])


func _exit_kinematic() -> void:
	"""Возврат физики: приземляемся на теперь-загруженный террейн (луч вниз), скорость по касательной."""
	_kinematic = false
	freeze = false
	var gy: float = _ground_y_at(global_position.x, global_position.z, global_position.y)
	global_position = Vector3(global_position.x, gy + 1.0, global_position.z)
	var s := _line_sample(_line_arc)
	angular_velocity = Vector3.ZERO
	linear_velocity = (s["tangent"] as Vector3) * maxf(8.0, current_speed_kmh / 3.6)
	_reset_line_projection()
	_stuck_prog_anchor = race_progress
	_stuck_win_timer = 0.0
	_rev_prog_anchor = race_progress
	_rev_win_timer = 0.0
	if ai_debug:
		print("[LOD] %s → PHYSICS (terrain back) prog=%.0f" % [racer_name, race_progress])


func _kinematic_step(delta: float) -> void:
	"""Кинематический шаг: продвигаемся по гоночной линии со скоростью профиля (масштаб RACER_SPEED_SCALE),
	позиция = точка линии, ориентация — вдоль линии. Y берём с линии (оффскрин; при возврате — приземлим)."""
	var s := _line_sample(_line_arc)
	var pace_ms: float = maxf(6.0, float(s["vmax"]) * RACER_SPEED_SCALE)
	var adv := pace_ms * delta
	_line_arc += adv
	race_progress = minf(race_route.total_length, race_progress + adv)
	var s2 := _line_sample(_line_arc)
	var pos: Vector3 = s2["pos"]
	# Y: сажаем на РЕАЛЬНЫЙ террейн (raycast каждый кадр). Так машина ОТСЛЕЖИВАЕТ elevation по мере
	# его подгрузки (террейн поднимается — машина поднимается) → нет «попа» при возврате физики. Верно
	# и на холмах (реальный луч, не запомненная высота). Нет земли (совсем не загружен) → высота линии.
	var gy: float = _kin_ground_y(pos.x, pos.z, pos.y)
	global_position = Vector3(pos.x, gy + 0.5, pos.z)
	var ahead: Vector3 = _line_sample(_line_arc + 4.0)["pos"]
	var look := Vector3(ahead.x, global_position.y, ahead.z)
	if look.distance_to(global_position) > 0.1:
		look_at(look, Vector3.UP)  # forward(-Z) вдоль линии
	if race_route.is_finished(race_progress):
		finish_race()


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
		# респавн ЧУТЬ ВПЕРЁД (за точечное препятствие на линии: столб/узкая стена) — маскирует
		# восстановление и не кладёт обратно в то же заклиненное место
		respawn_distance = clampf(race_progress + 10.0, 0.0, race_route.total_length - 5.0)
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
	_stuck_prog_anchor = race_progress
	_stuck_win_timer = 0.0
	_rev_prog_anchor = race_progress
	_rev_win_timer = 0.0


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


func _filter_tcl(throttle: float) -> float:
	"""Traction-control клампа (TORCS filterTCL): при переспине ведущих колёс (ω·r − v > TCL_SLIP)
	срезаем газ, линейно до нуля за TCL_RANGE. Абсолютный переспин (не slip-ratio) → устойчив при v≈0.
	В нормальной езде slip<1 м/с → возвращаем throttle без изменений (no-op)."""
	if throttle <= 0.0:
		return throttle
	var drive := wheels_rear if not wheels_rear.is_empty() else wheels_front
	if drive.is_empty():
		return throttle
	var wheel_ms: float = (_get_average_wheel_rpm() / 60.0) * TAU * drive[0].wheel_radius
	var slip: float = wheel_ms - current_speed_kmh / 3.6
	if slip > TCL_SLIP:
		throttle -= minf(throttle, (slip - TCL_SLIP) / TCL_RANGE)
	return maxf(0.0, throttle)
