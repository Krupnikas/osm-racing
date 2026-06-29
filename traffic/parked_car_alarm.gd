extends Node3D
class_name ParkedCarAlarm
## Parked-car alarm: when the player crashes hard enough into a parked car, that car plays ONE of two
## ordinary car-alarm sounds (chosen at random, played ONCE through — not looped) as 3D positional audio
## emitted from that car, and flashes its lights while the sound plays. When the sound finishes (or a
## safety timeout fires) the alarm stops, lights restore, the global cap slot is released, and the car
## enters cooldown. Self-contained child component attached to each parked car in
## osm_terrain_generator._spawn_parked_cars(). NOT connected to the police siren/beacon system.

# --- Tunables ---
const TRIGGER_SPEED := 5.5             # m/s — player speed gate (tune in self-test)
const FALLBACK_TIMEOUT_UNKNOWN := 22.0  # s — safety stop used ONLY when the clip length can't be read
const FALLBACK_MARGIN := 3.0            # s — safety stop = clip_length + this (fires only if `finished` fails)
# Short debounce only — long enough to absorb the multiple contacts of a single crash, short enough that
# deliberately hitting the car again (after its alarm finished) re-triggers it.
const COOLDOWN_MIN_MS := 1000
const COOLDOWN_MAX_MS := 1500
const BLINK_HZ := 3.0
const AUDIO_MAX_DISTANCE := 80.0
const AUDIO_UNIT_SIZE := 10.0
const AUDIO_LOCAL_OFFSET := Vector3(0.0, 0.8, 0.0)   # near the cabin, not the floor
const ALARM_STREAM_PATHS := [
	"res://audio/sfx/car_alarm_multitone.mp3",
	"res://audio/sfx/car_alarm_2.mp3",
]

# --- Global cap (shared across all parked cars) ---
static var max_active_alarms := 3
static var _active_alarm_count := 0

# --- Variation pool (loaded once, shared) ---
static var _alarm_streams: Array = []
static var _pool_loaded := false

# --- Debug ---
static var parked_car_alarm_debug := false  # gates [ALARM] prints; flip true for debugging
static var debug_player_hits := 0
static var debug_last_hit_speed := 0.0

# --- Per-car runtime state ---
var alarm_active := false
var _car: NPCCar = null
var _selected_stream: AudioStream = null
var _alarm_player: AudioStreamPlayer3D = null
var _fallback_left := 0.0
var _blink_t := 0.0
var _blink_on := false
var _last_stop_ms := -100000
var _cooldown_ms := 0
var _counted_in_cap := false


func _ready() -> void:
	set_process(false)   # only ON while an alarm is actually running
	_ensure_pool()
	_car = get_parent() as NPCCar
	if _car == null:
		push_warning("[ParkedCarAlarm] parent is not an NPCCar; disabled")
		return
	if not _car.body_entered.is_connected(_on_body_entered):
		_car.body_entered.connect(_on_body_entered)
	if parked_car_alarm_debug:
		print("[ALARM] component attached to '%s'" % _car.name)


static func _ensure_pool() -> void:
	if _pool_loaded:
		return
	_pool_loaded = true
	for path in ALARM_STREAM_PATHS:
		if ResourceLoader.exists(path):
			var s: AudioStream = load(path)
			if s != null:
				_alarm_streams.append(s)
		else:
			push_warning("[ParkedCarAlarm] missing alarm asset: " + path)
	if parked_car_alarm_debug:
		print("[ALARM] variation pool size=%d" % _alarm_streams.size())


# === Trigger ===

func _on_body_entered(other: Node) -> void:
	if other == null or not other.is_in_group("player"):
		return
	var spd := 0.0
	if other is RigidBody3D:
		spd = (other as RigidBody3D).linear_velocity.length()
	debug_player_hits += 1
	debug_last_hit_speed = spd
	_try_trigger(spd)


## Shared gate path (used by the real collision and by the debug-impact hook).
func _try_trigger(spd: float) -> void:
	if alarm_active:
		_dbg("already_active", spd)          # re-hit ignored: no restart/switch/extend
		return
	if Time.get_ticks_msec() - _last_stop_ms < _cooldown_ms:
		_dbg("cooldown", spd)
		return
	if spd < TRIGGER_SPEED:
		_dbg("below_threshold", spd)
		return
	if _active_alarm_count >= max_active_alarms:
		_dbg("cap_full", spd)
		return
	if _alarm_streams.is_empty():
		_dbg("no_audio", spd)
		return
	_start_alarm()


# === Alarm run ===

func _start_alarm() -> void:
	_selected_stream = _alarm_streams[randi() % _alarm_streams.size()]
	_ensure_player()
	_alarm_player.stream = _selected_stream
	_alarm_player.play()
	# Stop is driven by `finished`; the timeout is only a safety net sized ABOVE the clip length so it
	# never truncates a long clip — it fires only if `finished` fails to arrive.
	var clip_len := 0.0
	if _selected_stream != null:
		clip_len = _selected_stream.get_length()
	_fallback_left = (clip_len + FALLBACK_MARGIN) if clip_len > 0.0 else FALLBACK_TIMEOUT_UNKNOWN
	_active_alarm_count += 1
	_counted_in_cap = true
	alarm_active = true
	_blink_t = 0.0
	_blink_on = false
	set_process(true)
	if parked_car_alarm_debug:
		print("[ALARM] START '%s' stream=%s len=%.1fs cap=%d/%d" % [
			_car.name, _selected_stream.resource_path.get_file(), clip_len,
			_active_alarm_count, max_active_alarms])


func _ensure_player() -> void:
	if _alarm_player != null and is_instance_valid(_alarm_player):
		return
	_alarm_player = AudioStreamPlayer3D.new()
	_alarm_player.name = "AlarmAudio"
	_alarm_player.bus = "SFX"
	_alarm_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_alarm_player.unit_size = AUDIO_UNIT_SIZE
	_alarm_player.max_distance = AUDIO_MAX_DISTANCE
	_alarm_player.position = AUDIO_LOCAL_OFFSET     # child of this component → emits from the hit car
	add_child(_alarm_player)
	_alarm_player.finished.connect(_on_alarm_finished)


func _process(delta: float) -> void:
	if not alarm_active:
		return
	# Flash the lights in step with the playing sound.
	_blink_t += delta
	var on := sin(_blink_t * TAU * BLINK_HZ) > 0.0
	if on != _blink_on:
		_blink_on = on
		_set_lights(on)
	# Safety net only — normal stop is the `finished` signal.
	_fallback_left -= delta
	if _fallback_left <= 0.0:
		_stop_alarm("fallback")


func _on_alarm_finished() -> void:
	# Normal end: the one-shot stream played one full pass.
	if alarm_active:
		_stop_alarm("finished")


func _stop_alarm(reason: String) -> void:
	if _alarm_player != null and is_instance_valid(_alarm_player) and _alarm_player.playing:
		_alarm_player.stop()
	_restore_lights()
	if _counted_in_cap:
		_active_alarm_count = maxi(0, _active_alarm_count - 1)
		_counted_in_cap = false
	alarm_active = false
	_selected_stream = null
	_blink_on = false
	_last_stop_ms = Time.get_ticks_msec()
	_cooldown_ms = randi_range(COOLDOWN_MIN_MS, COOLDOWN_MAX_MS)
	set_process(false)
	if parked_car_alarm_debug:
		print("[ALARM] STOP '%s' reason=%s cap=%d" % [
			_car.name if is_instance_valid(_car) else "?", reason, _active_alarm_count])


# === Lights (flash while sound plays; restore the day/night/rain state on stop) ===

func _set_lights(on: bool) -> void:
	if _car == null or not is_instance_valid(_car):
		return
	var lights = _car._lights
	if lights == null or not is_instance_valid(lights):
		return
	if on:
		lights.enable_lights()
	else:
		lights.disable_lights()


func _restore_lights() -> void:
	if _car == null or not is_instance_valid(_car):
		return
	var lights = _car._lights
	if lights == null or not is_instance_valid(lights):
		return
	var want: bool = _car._is_night or _car._is_raining
	if want:
		lights.enable_lights()
	else:
		lights.disable_lights()
	_car._lights_enabled = want   # keep NPCCar's wrapper guard in sync so future _refresh_lights() works


# === Cleanup ===

func _exit_tree() -> void:
	# Car freed / chunk unloaded: stop audio + release the cap slot. (Don't touch _car lights — it's leaving.)
	if _alarm_player != null and is_instance_valid(_alarm_player) and _alarm_player.playing:
		_alarm_player.stop()
	if _counted_in_cap:
		_active_alarm_count = maxi(0, _active_alarm_count - 1)
		_counted_in_cap = false
		if parked_car_alarm_debug:
			print("[ALARM] exit_tree cleanup released cap (now %d)" % _active_alarm_count)


func _dbg(reason: String, spd: float) -> void:
	if parked_car_alarm_debug:
		print("[ALARM] reject=%s '%s' speed=%.1f" % [reason, _car.name if is_instance_valid(_car) else "?", spd])


# === Static debug / test hooks (callable from MCP execute_game_script) ===

static func _all_alarms() -> Array:
	var out: Array = []
	var ml = Engine.get_main_loop()
	if ml is SceneTree:
		var root = (ml as SceneTree).current_scene
		if root != null:
			_collect(root, out)
	return out


static func _collect(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is ParkedCarAlarm:
			out.append(c)
		_collect(c, out)


static func _player_pos() -> Vector3:
	var ml = Engine.get_main_loop()
	if ml is SceneTree:
		var ps = (ml as SceneTree).get_nodes_in_group("player")
		if ps.size() > 0 and ps[0] is Node3D:
			return (ps[0] as Node3D).global_position
	return Vector3.ZERO


static func _nearest(require_idle: bool):
	var pp := _player_pos()
	var best = null
	var bd := INF
	for a in _all_alarms():
		if not is_instance_valid(a._car):
			continue
		if require_idle and a.alarm_active:
			continue
		var d: float = a._car.global_position.distance_to(pp)
		if d < bd:
			bd = d
			best = a
	return best


static func force_nearest_parked_car_alarm_on() -> bool:
	var a = _nearest(true)
	if a == null:
		print("[ALARM] force_on: no idle parked car found")
		return false
	a._start_alarm()
	return true


static func force_all_parked_car_alarms_off() -> void:
	for a in _all_alarms():
		if a.alarm_active:
			a._stop_alarm("forced")
	_active_alarm_count = 0   # authoritative repair of any drift
	print("[ALARM] force_all_off: cap reset to 0")


static func print_active_parked_car_alarm_count() -> void:
	var alarms = _all_alarms()
	var active := 0
	for a in alarms:
		if a.alarm_active:
			active += 1
	print("[ALARM] cap_counter=%d/%d  actually_active=%d  components=%d  pool=%d  %s" % [
		_active_alarm_count, max_active_alarms, active, alarms.size(), _alarm_streams.size(),
		("MISMATCH!" if active != _active_alarm_count else "ok")])


static func spawn_or_find_debug_parked_car_near_player() -> Node:
	var a = _nearest(false)
	if a == null:
		print("[ALARM] no parked car found near player")
		return null
	print("[ALARM] nearest parked car '%s' at %.1f m" % [
		a._car.name, a._car.global_position.distance_to(_player_pos())])
	return a._car


static func simulate_alarm_impact_on_nearest_parked_car(speed: float) -> bool:
	var a = _nearest(false)
	if a == null:
		print("[ALARM] simulate: no parked car found")
		return false
	a.debug_last_hit_speed = speed
	a._try_trigger(speed)
	return true
