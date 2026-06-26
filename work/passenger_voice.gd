extends Node
class_name PassengerVoice

## Голосовые реакции пассажира в режиме «Извоз» (work mode).
##
## Реагирует на ТРИ типа плохой езды: резкое торможение, превышение скорости,
## съезд с дороги. Голос выбирается ОДИН на поездку (work_manager.get_passenger_voice)
## и не меняется до конца поездки.
##
## Один авторитетный плеер: клипы НЕ накладываются, НЕ очередятся — если речь
## уже играет, новое событие отбрасывается навсегда. Музыка слегка приглушается
## на время реплики (через MusicManager.set_speech_duck, относительно громкости
## пользователя). Геймплей не трогаем: читаем телеметрию машины (linear_velocity)
## и OSMTerrain.is_point_on_road.

const VOICES: Array[String] = ["oleg", "old-tuminah", "elena-tymanova"]
const SPEECH_DIR := "res://audio/speech/"
const CLIPS_PER_EVENT := 3
# Тип события -> префикс в именах файлов (в ассетах "breaking", не "braking").
const EVENT_PREFIX := {"brake": "breaking", "speed": "speeding", "offroad": "not-on-road"}
const DRIVING_STATE := 2  # work_manager State.DRIVING

# --- Пороги/тайминги (тюнятся вживую) ---
@export var brake_decel_threshold := 6.0    # м/с^2 (~0.6g) — резкое торможение
@export var brake_rearm_decel := 3.0        # м/с^2 — ниже этого триггер пере-взводится
@export var brake_min_speed_kmh := 20.0
@export var brake_cooldown := 4.0
@export var collision_decel_cap := 20.0     # выше — это удар/столкновение, не торможение

@export var speed_threshold_kmh := 90.0
@export var speed_rearm_kmh := 75.0
@export var speed_sustain := 1.5
@export var speed_cooldown := 12.0

@export var offroad_margin := 2.0    # как у safe-бонуса в work_manager (проверенное значение)
@export var offroad_sustain := 1.3
@export var offroad_onroad_reset := 0.5
@export var offroad_cooldown := 10.0

var _wm: Node
var _car: Node
var _terrain: Node

var _voice := ""
var _active := false

# Воспроизведение (одно авторитетное состояние)
var _player: AudioStreamPlayer
var _is_playing := false
var _last_clip := {"brake": "", "speed": "", "offroad": ""}
var _clip_cache := {}

# Телеметрия
var _prev_speed_ms := 0.0
var _have_prev := false

# Детекторы
var _brake_armed := true
var _brake_cd := 0.0
var _speed_armed := true
var _speed_timer := 0.0
var _speed_cd := 0.0
var _offroad_armed := true
var _offroad_timer := 0.0
var _onroad_timer := 0.0
var _offroad_cd := 0.0


func setup(work_manager: Node, car: Node, terrain: Node = null) -> void:
	_wm = work_manager
	_car = car
	_terrain = terrain  # передаётся из main (тот же узел, что у work_manager)
	if _terrain == null:
		var scene_root := get_tree().current_scene
		if scene_root:
			_terrain = scene_root.find_child("OSMTerrain", true, false)
	if _terrain == null:
		push_warning("PassengerVoice: OSMTerrain not found — off-road reactions disabled until found")

	_player = AudioStreamPlayer.new()
	_player.name = "VoiceAudio"
	_player.bus = "SFX"
	add_child(_player)
	_player.finished.connect(_on_finished)

	if _wm:
		if _wm.has_signal("order_accepted"):
			_wm.order_accepted.connect(_on_trip_start)
		if _wm.has_signal("order_completed"):
			_wm.order_completed.connect(_on_trip_completed)

	set_physics_process(false)


# === Жизненный цикл поездки ===

func _on_trip_start(_fare: int = 0, _dest: String = "") -> void:
	_voice = ""
	if _wm and _wm.has_method("get_passenger_voice"):
		_voice = str(_wm.get_passenger_voice())
	if _voice == "":
		_voice = VOICES[randi() % VOICES.size()]
	_reset_detectors()
	_active = true
	set_physics_process(true)


func _on_trip_completed(_result: Dictionary = {}) -> void:
	_end_trip()


func _end_trip() -> void:
	_active = false
	set_physics_process(false)
	_stop_speech()
	_voice = ""
	_reset_detectors()


func _reset_detectors() -> void:
	_have_prev = false
	_prev_speed_ms = 0.0
	_brake_armed = true
	_brake_cd = 0.0
	_speed_armed = true
	_speed_timer = 0.0
	_speed_cd = 0.0
	_offroad_armed = true
	_offroad_timer = 0.0
	_onroad_timer = 0.0
	_offroad_cd = 0.0
	for k in _last_clip:
		_last_clip[k] = ""


# === Детекторы ===

func _physics_process(delta: float) -> void:
	if not _active or not is_instance_valid(_car):
		return
	# Защита: пассажир должен быть на борту (state == DRIVING).
	if _wm and _wm.has_method("get_state") and _wm.get_state() != DRIVING_STATE:
		_end_trip()
		return

	var lv = _car.get("linear_velocity")
	var v: Vector3 = lv if lv is Vector3 else Vector3.ZERO
	var speed_ms := v.length()
	var speed_kmh := speed_ms * 3.6

	var decel := 0.0
	if _have_prev and delta > 0.0:
		decel = (_prev_speed_ms - speed_ms) / delta
	_prev_speed_ms = speed_ms
	_have_prev = true

	_brake_cd = maxf(0.0, _brake_cd - delta)
	_speed_cd = maxf(0.0, _speed_cd - delta)
	_offroad_cd = maxf(0.0, _offroad_cd - delta)

	_update_brake(decel, speed_kmh)
	_update_speed(speed_kmh, delta)
	_update_offroad(delta)


func _update_brake(decel: float, speed_kmh: float) -> void:
	if decel < brake_rearm_decel:
		_brake_armed = true
	if _brake_armed and _brake_cd <= 0.0 \
			and speed_kmh > brake_min_speed_kmh \
			and decel >= brake_decel_threshold and decel < collision_decel_cap:
		_brake_armed = false
		_brake_cd = brake_cooldown
		_try_play("brake")


func _update_speed(speed_kmh: float, delta: float) -> void:
	if speed_kmh <= speed_rearm_kmh:
		_speed_armed = true
	if speed_kmh > speed_threshold_kmh:
		_speed_timer += delta
	else:
		_speed_timer = 0.0
	if _speed_armed and _speed_cd <= 0.0 and _speed_timer >= speed_sustain:
		_speed_armed = false
		_speed_timer = 0.0
		_speed_cd = speed_cooldown
		_try_play("speed")


func _update_offroad(delta: float) -> void:
	# Лениво до-ищем террейн, если на старте поездки его ещё не было в дереве.
	if _terrain == null:
		var sr := get_tree().current_scene
		if sr:
			_terrain = sr.find_child("OSMTerrain", true, false)
	if _terrain == null or not _terrain.has_method("is_point_on_road") or not is_instance_valid(_car):
		return
	var pos := Vector2(_car.global_position.x, _car.global_position.z)
	var on_road := bool(_terrain.is_point_on_road(pos, offroad_margin))
	if on_road:
		_onroad_timer += delta
		# Накопитель «вне дороги» обнуляем ТОЛЬКО после устойчивого возврата на
		# дорогу — кратковременные «на дороге» (бордюр, дырки маски на перекрёстках)
		# не сбрасывают, иначе sustain никогда не наберётся.
		if _onroad_timer >= offroad_onroad_reset:
			_offroad_timer = 0.0
			_offroad_armed = true
	else:
		_onroad_timer = 0.0
		_offroad_timer += delta
	if _offroad_armed and _offroad_cd <= 0.0 and _offroad_timer >= offroad_sustain:
		_offroad_armed = false
		_offroad_timer = 0.0
		_offroad_cd = offroad_cooldown
		_try_play("offroad")


# === Воспроизведение (одно авторитетное состояние) ===

func _try_play(event: String) -> void:
	if _is_playing:
		return  # речь идёт — событие отбрасываем НАВСЕГДА (без прерывания/очереди)
	if not _active or _voice == "":
		return
	var stream := _pick_clip(event)
	if stream == null:
		return  # ассет отсутствует/не загрузился — не играем, музыку не дакаем
	_player.stream = stream
	_player.play()
	_is_playing = true
	_set_duck(true)


func _pick_clip(event: String) -> AudioStream:
	if not EVENT_PREFIX.has(event):
		return null
	var idx := randi() % CLIPS_PER_EVENT + 1
	var path := _clip_path(event, idx)
	# Не повторять тот же клип сразу, если есть альтернатива.
	if path == _last_clip[event] and CLIPS_PER_EVENT > 1:
		var alt: Array[int] = []
		for i in range(1, CLIPS_PER_EVENT + 1):
			if _clip_path(event, i) != _last_clip[event]:
				alt.append(i)
		if not alt.is_empty():
			idx = alt[randi() % alt.size()]
			path = _clip_path(event, idx)
	_last_clip[event] = path
	return _load_clip(path)


func _clip_path(event: String, idx: int) -> String:
	return "%s%s/%s-%02d.mp3" % [SPEECH_DIR, _voice, EVENT_PREFIX[event], idx]


func _load_clip(path: String) -> AudioStream:
	if _clip_cache.has(path):
		return _clip_cache[path]
	if not ResourceLoader.exists(path):
		push_warning("PassengerVoice: missing clip " + path)
		_clip_cache[path] = null
		return null
	var s := load(path) as AudioStream
	if s == null:
		push_warning("PassengerVoice: failed to load " + path)
	_clip_cache[path] = s
	return s


func _on_finished() -> void:
	_is_playing = false
	_set_duck(false)


func _stop_speech() -> void:
	if _player and is_instance_valid(_player) and _player.playing:
		_player.stop()
	_is_playing = false
	_set_duck(false)


func _set_duck(on: bool) -> void:
	if MusicManager and MusicManager.has_method("set_speech_duck"):
		MusicManager.set_speech_duck(on)


func _exit_tree() -> void:
	_stop_speech()


# === Debug-хуки (для харнесса и MCP execute_game_script) ===

func debug_set_voice(v: String) -> void:
	_voice = v


func debug_force_active(v: String = "") -> void:
	if v != "":
		_voice = v
	elif _voice == "":
		_voice = VOICES[randi() % VOICES.size()]
	_reset_detectors()
	_active = true
	set_physics_process(true)


func debug_trigger(event: String) -> void:
	_try_play(event)


func debug_state() -> Dictionary:
	return {
		"active": _active, "voice": _voice, "is_playing": _is_playing,
		"stream": _player.stream.resource_path if (_player and _player.stream) else "",
		"ducked": (MusicManager.get("_speech_ducked") if MusicManager else null),
	}


static func _find() -> Node:
	var ml = Engine.get_main_loop()
	if ml is SceneTree:
		var cs = (ml as SceneTree).current_scene
		if cs:
			return cs.find_child("PassengerVoice", true, false)
	return null


static func dbg_trigger(event: String) -> void:
	var p = _find()
	if p:
		p.debug_trigger(event)


static func dbg_voice(v: String) -> void:
	var p = _find()
	if p:
		p.debug_set_voice(v)
