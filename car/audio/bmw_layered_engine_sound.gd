extends Node3D

const EXHAUST_POSITION := Vector3(0.0, 0.42, -1.85)
const LOOP_MASTER_GAIN_DB := 0.0
const STARTUP_MASTER_GAIN_DB := -2.0
const EVENT_MASTER_GAIN_DB := 2.0
const LOOP_UNIT_SIZE := 14.0
const LOOP_MAX_DISTANCE := 125.0
const STARTUP_UNIT_SIZE := 12.0
const STARTUP_MAX_DISTANCE := 110.0
const EVENT_UNIT_SIZE := 12.0
const EVENT_MAX_DISTANCE := 105.0
const LOOP_SOURCE_NORMALIZATION_DB := {
	&"idle": 3.8,
	&"low_on": 0.0,
	&"med_on": 0.2,
	&"high_on": -1.0,
	&"low_off": -0.6,
	&"med_off": -2.4,
	&"high_off": -3.4,
	&"max_rpm": 2.0,
}

const LOOP_CONFIGS := [
	{
		"id": &"idle",
		"path": "res://audio/vehicles/i6_german_free/idle.wav",
	},
	{
		"id": &"low_on",
		"path": "res://audio/vehicles/i6_german_free/low_on.wav",
	},
	{
		"id": &"med_on",
		"path": "res://audio/vehicles/i6_german_free/med_on.wav",
	},
	{
		"id": &"high_on",
		"path": "res://audio/vehicles/i6_german_free/high_on.wav",
	},
	{
		"id": &"low_off",
		"path": "res://audio/vehicles/i6_german_free/low_off.wav",
	},
	{
		"id": &"med_off",
		"path": "res://audio/vehicles/i6_german_free/med_off.wav",
	},
	{
		"id": &"high_off",
		"path": "res://audio/vehicles/i6_german_free/high_off.wav",
	},
	{
		"id": &"max_rpm",
		"path": "res://audio/vehicles/i6_german_free/maxRPM.wav",
	},
]

const STARTUP_PATH := "res://audio/vehicles/i6_german_free/startup.wav"
const EVENT_CONFIGS := [
	{
		"id": &"gear_up",
		"path": "res://audio/vehicles/i6_german_free/gearup.wav",
		"gain_db": -2.0,
	},
	{
		"id": &"gear_down",
		"path": "res://audio/vehicles/i6_german_free/geardown.wav",
		"gain_db": -3.5,
	},
]

@export var vehicle: Vehicle

var _loop_players: Dictionary = {}
var _loop_gain_db: Dictionary = {}
var _startup_player: AudioStreamPlayer3D
var _event_players: Dictionary = {}
var _event_gain_db: Dictionary = {}
var _startup_pending := true
var _last_gear := 0
var _shift_event_cooldown := 0.0
var _debug_mix_weights: Dictionary = {}
var _debug_loop_target_db: Dictionary = {}
var _debug_loop_target_pitch: Dictionary = {}
var _debug_scalar_state: Dictionary = {}
var _debug_last_event := {
	"id": "",
	"volume_db": -80.0,
	"pitch_scale": 1.0,
	"age": 9999.0,
}


func _ready() -> void:
	if not vehicle:
		var parent := get_parent()
		if parent is Vehicle:
			vehicle = parent

	_create_loop_players()
	_create_startup_player()
	_create_event_players()

	if vehicle:
		_last_gear = vehicle.current_gear


func _physics_process(delta: float) -> void:
	if not vehicle:
		return

	_shift_event_cooldown = maxf(_shift_event_cooldown - delta, 0.0)
	_debug_last_event["age"] = float(_debug_last_event.get("age", 9999.0)) + delta

	if not _is_audio_active():
		_pause_players()
		_last_gear = vehicle.current_gear
		return

	if _startup_pending:
		_play_startup_once()

	_resume_players()
	_update_loop_mix(delta)
	_process_shift_events()
	_last_gear = vehicle.current_gear


func _create_loop_players() -> void:
	for config in LOOP_CONFIGS:
		var stream := _load_loop_stream(config["path"])
		if not stream:
			push_warning("BMW audio loop missing: %s" % config["path"])
			continue

		var player := AudioStreamPlayer3D.new()
		player.name = "%sLoop" % String(config["id"]).capitalize()
		player.bus = &"SFX"
		player.stream = stream
		player.position = EXHAUST_POSITION
		player.volume_db = -80.0
		player.max_db = 10.0
		player.max_distance = LOOP_MAX_DISTANCE
		player.unit_size = LOOP_UNIT_SIZE
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.panning_strength = 1.0
		add_child(player)
		_loop_players[config["id"]] = player
		# Source normalization is based on measured clip loudness, not hand-tuned per-layer taste.
		_loop_gain_db[config["id"]] = float(LOOP_SOURCE_NORMALIZATION_DB.get(config["id"], 0.0))


func _create_startup_player() -> void:
	var stream := load(STARTUP_PATH) as AudioStream
	if not stream:
		push_warning("BMW startup audio missing: %s" % STARTUP_PATH)
		return

	_startup_player = AudioStreamPlayer3D.new()
	_startup_player.name = "StartupEvent"
	_startup_player.bus = &"SFX"
	_startup_player.stream = stream
	_startup_player.position = EXHAUST_POSITION
	_startup_player.volume_db = -80.0
	_startup_player.max_db = 10.0
	_startup_player.max_distance = STARTUP_MAX_DISTANCE
	_startup_player.unit_size = STARTUP_UNIT_SIZE
	_startup_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_startup_player.panning_strength = 1.0
	add_child(_startup_player)


func _create_event_players() -> void:
	for config in EVENT_CONFIGS:
		var stream := load(config["path"]) as AudioStream
		if not stream:
			push_warning("BMW shift audio missing: %s" % config["path"])
			continue

		var player := AudioStreamPlayer3D.new()
		player.name = "%sEvent" % String(config["id"]).capitalize()
		player.bus = &"SFX"
		player.stream = stream
		player.position = EXHAUST_POSITION
		player.volume_db = -80.0
		player.max_db = 10.0
		player.max_distance = EVENT_MAX_DISTANCE
		player.unit_size = EVENT_UNIT_SIZE
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.panning_strength = 1.0
		add_child(player)
		_event_players[config["id"]] = player
		_event_gain_db[config["id"]] = config["gain_db"]


func _load_loop_stream(path: String) -> AudioStream:
	var stream := load(path) as AudioStream
	if not stream:
		return null

	if stream is AudioStreamWAV:
		var wav := (stream as AudioStreamWAV).duplicate() as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * wav.mix_rate)
		return wav

	return stream


func _is_audio_active() -> bool:
	return vehicle.visible and not vehicle.freeze


func _resume_players() -> void:
	for config in LOOP_CONFIGS:
		var player: AudioStreamPlayer3D = _loop_players.get(config["id"])
		if not player:
			continue
		if not player.playing:
			player.play()
		player.stream_paused = false

	if _startup_player and _startup_player.playing:
		_startup_player.stream_paused = false

	for player: AudioStreamPlayer3D in _event_players.values():
		if player.playing:
			player.stream_paused = false


func _pause_players() -> void:
	for player: AudioStreamPlayer3D in _loop_players.values():
		if player.playing:
			player.stream_paused = true

	if _startup_player and _startup_player.playing:
		_startup_player.stream_paused = true

	for player: AudioStreamPlayer3D in _event_players.values():
		if player.playing:
			player.stream_paused = true


func _play_startup_once() -> void:
	_startup_pending = false
	if not _startup_player:
		return

	_startup_player.stream_paused = false
	_startup_player.volume_db = -6.0 + STARTUP_MASTER_GAIN_DB
	_startup_player.pitch_scale = 1.0
	_startup_player.play()


func _update_loop_mix(delta: float) -> void:
	var rpm := clampf(vehicle.motor_rpm, vehicle.idle_rpm, vehicle.max_rpm)
	var rpm_norm := inverse_lerp(vehicle.idle_rpm, vehicle.max_rpm, rpm)
	var load := clampf(vehicle.throttle_amount, 0.0, 1.0)
	var brake := clampf(vehicle.brake_amount, 0.0, 1.0)
	var speed_mps := absf(vehicle.speed)
	var speed_kmh := speed_mps * 3.6
	var current_gear := maxi(vehicle.current_gear, 1)
	var upper_gear_bias := clampf(inverse_lerp(3.0, 5.0, float(current_gear)), 0.0, 1.0)
	var top_end_gear_bias := clampf(inverse_lerp(4.0, 6.0, float(current_gear)), 0.0, 1.0)
	var coupled_rpm := clampf(vehicle.wheel_coupled_rpm, vehicle.idle_rpm, vehicle.max_rpm)
	var drivetrain_rpm := clampf(vehicle.drivetrain_rpm, vehicle.idle_rpm, vehicle.max_rpm)
	var engine_load := clampf(vehicle.engine_load, 0.0, 1.0)
	var moving := clampf(inverse_lerp(0.8, 7.0, speed_mps), 0.0, 1.0)
	var low_speed_presence := 1.0 - clampf(inverse_lerp(12.0, 28.0, speed_mps), 0.0, 1.0)
	var crawl_presence := 1.0 - clampf(inverse_lerp(3.0, 10.0, speed_mps), 0.0, 1.0)
	var shift_state := clampf(vehicle.shift_phase, 0.0, 1.0)
	var redline_state := 1.0 if vehicle.motor_is_redline else 0.0

	var on_throttle := clampf(load - brake * 0.12, 0.0, 1.0)
	var lift := clampf(1.0 - load - brake * 0.25, 0.0, 1.0)
	var drive_state := maxf(pow(on_throttle, 0.92), engine_load * lerpf(0.72, 1.0, moving)) * (1.0 - shift_state * 0.35)
	var coast_state := pow(lift, 1.05) * clampf(inverse_lerp(0.16, 1.0, rpm_norm), 0.0, 1.0)
	coast_state *= lerpf(0.35, 1.0, moving)
	coast_state = maxf(coast_state, shift_state * clampf(inverse_lerp(0.40, 0.95, rpm_norm), 0.0, 1.0) * 0.22)
	var throttle_rise_rate := clampf(vehicle.throttle_attack_rate, -6.0, 6.0)
	var throttle_attack := clampf(inverse_lerp(0.28, 2.4, throttle_rise_rate), 0.0, 1.0)
	var pedal_aggression := maxf(pow(on_throttle, 0.82), engine_load * 0.95)
	var rpm_gap := maxf(
		maxf(vehicle.clutch_slip_rpm, maxf(rpm - coupled_rpm, 0.0)),
		absf(rpm - drivetrain_rpm) * 0.45
	)
	var slip_rpm_bias := clampf(inverse_lerp(450.0, 1800.0, rpm_gap), 0.0, 1.0)
	var low_gear_bias := 1.0 - clampf(inverse_lerp(3.0, 5.5, float(current_gear)), 0.0, 1.0)
	var low_speed_bias := 1.0 - clampf(inverse_lerp(120.0, 185.0, speed_kmh), 0.0, 1.0)
	var spectral_coupling := slip_rpm_bias * low_gear_bias * low_speed_bias * lerpf(0.38, 1.0, maxf(drive_state, engine_load))
	var character_rpm_target := minf(rpm, coupled_rpm + lerpf(380.0, 900.0, maxf(engine_load, drive_state)))
	var character_rpm := lerpf(rpm, character_rpm_target, spectral_coupling)
	var character_rpm_norm := inverse_lerp(vehicle.idle_rpm, vehicle.max_rpm, character_rpm)
	var band_pitch_rpm := lerpf(rpm, character_rpm, clampf(0.24 + spectral_coupling * 0.56 + upper_gear_bias * 0.10, 0.0, 0.82))
	var high_rpm_state := clampf(inverse_lerp(0.56, 1.0, character_rpm_norm), 0.0, 1.0)
	var aggression_state := clampf(
		maxf(
			maxf(
				pedal_aggression * lerpf(0.58, 0.86, high_rpm_state),
				throttle_attack * lerpf(0.30, 0.72, moving)
			),
			engine_load * lerpf(0.42, 0.82, high_rpm_state)
		),
		0.0,
		1.0
	)

	var idle_weight := _triangle(rpm, vehicle.idle_rpm * 0.68, vehicle.idle_rpm * 1.02, 1700.0)
	idle_weight *= lerpf(1.0, 0.36, drive_state)
	idle_weight = maxf(idle_weight, crawl_presence * lerpf(0.70, 0.42, drive_state))

	var low_on_weight := _triangle(rpm, 950.0, 2250.0, 4850.0) * lerpf(0.34, 1.0, drive_state)
	low_on_weight += low_speed_presence * _triangle(rpm, vehicle.idle_rpm * 0.92, 1750.0, 3550.0) * lerpf(0.18, 0.46, drive_state)
	var raw_med_on_weight := _triangle(character_rpm, 3300.0, 5050.0, 7050.0) * lerpf(0.05, 0.94, drive_state)
	var raw_high_on_weight := _triangle(character_rpm, 4850.0, 6600.0, vehicle.max_rpm * 1.01)
	raw_med_on_weight *= lerpf(0.96, 1.05, aggression_state)
	raw_high_on_weight *= drive_state * lerpf(0.35, 1.0, high_rpm_state)
	raw_high_on_weight *= lerpf(1.0, 1.08, aggression_state)

	var low_off_weight := _triangle(rpm, 1000.0, 1900.0, 3200.0) * coast_state * 0.55
	var raw_med_off_weight := _triangle(character_rpm, 3100.0, 4900.0, 6800.0) * coast_state * 0.70
	var high_off_weight := _triangle(character_rpm, 5150.0, 6800.0, vehicle.max_rpm * 1.02)
	high_off_weight *= coast_state * lerpf(0.38, 1.0, high_rpm_state)

	var mid_character_gate := clampf(
		inverse_lerp(
			lerpf(28.0, 20.0, upper_gear_bias),
			lerpf(68.0, 54.0, upper_gear_bias),
			speed_kmh
		),
		0.0,
		1.0
	)
	var high_character_gate := clampf(
		inverse_lerp(
			lerpf(76.0, 62.0, upper_gear_bias),
			lerpf(142.0, 122.0, upper_gear_bias),
			speed_kmh
		),
		0.0,
		1.0
	)
	var top_end_gate := clampf(
		inverse_lerp(
			lerpf(188.0, 152.0, top_end_gear_bias),
			lerpf(236.0, 192.0, top_end_gear_bias),
			speed_kmh
		),
		0.0,
		1.0
	)
	var top_end_preload_gate := clampf(
		inverse_lerp(
			lerpf(164.0, 146.0, top_end_gear_bias),
			lerpf(198.0, 174.0, top_end_gear_bias),
			speed_kmh
		),
		0.0,
		1.0
	)

	var low_mid_transition := clampf(inverse_lerp(3600.0, 5300.0, character_rpm), 0.0, 1.0)
	low_mid_transition = low_mid_transition * low_mid_transition * (3.0 - 2.0 * low_mid_transition)
	var med_on_weight := raw_med_on_weight * lerpf(0.18, 1.0, mid_character_gate) * lerpf(0.30, 1.0, low_mid_transition)
	var suppressed_med_on := raw_med_on_weight - med_on_weight
	low_on_weight += suppressed_med_on * lerpf(0.92, 0.56, clampf(inverse_lerp(3300.0, 5000.0, rpm), 0.0, 1.0))
	var med_off_weight := raw_med_off_weight * lerpf(0.38, 1.0, mid_character_gate) * lerpf(0.55, 1.0, low_mid_transition)
	var suppressed_med_off := raw_med_off_weight - med_off_weight
	low_off_weight += suppressed_med_off * 0.62

	var high_on_weight := raw_high_on_weight * lerpf(0.36, 1.0, high_character_gate)
	var suppressed_high_on := raw_high_on_weight - high_on_weight
	var high_to_mid_transfer := lerpf(0.22, 0.40, clampf(inverse_lerp(5100.0, 7100.0, character_rpm), 0.0, 1.0))
	med_on_weight += suppressed_high_on * high_to_mid_transfer

	var raw_max_rpm_weight := clampf(inverse_lerp(vehicle.max_rpm * 0.72, vehicle.max_rpm * 0.96, character_rpm), 0.0, 1.0)
	raw_max_rpm_weight = maxf(raw_max_rpm_weight, redline_state * 0.9)
	raw_max_rpm_weight *= maxf(drive_state * 0.94, coast_state * 0.20)
	var max_rpm_gate := maxf(top_end_gate, top_end_preload_gate * lerpf(0.22, 0.34, top_end_gear_bias))
	var max_rpm_weight := raw_max_rpm_weight * max_rpm_gate
	var suppressed_max_rpm := raw_max_rpm_weight - max_rpm_weight
	med_on_weight += suppressed_max_rpm * 0.10
	high_on_weight += suppressed_max_rpm * lerpf(0.36, 0.62, high_character_gate)

	var total_weight := idle_weight + low_on_weight + med_on_weight + high_on_weight
	total_weight += low_off_weight + med_off_weight + high_off_weight + max_rpm_weight
	if total_weight > 1.12:
		var weight_scale := 1.12 / total_weight
		idle_weight *= weight_scale
		low_on_weight *= weight_scale
		med_on_weight *= weight_scale
		high_on_weight *= weight_scale
		low_off_weight *= weight_scale
		med_off_weight *= weight_scale
		high_off_weight *= weight_scale
		max_rpm_weight *= weight_scale

	var drive_boost := lerpf(0.0, 1.0, drive_state) + lerpf(0.0, 0.35, rpm_norm)
	var aggression_db := lerpf(0.0, 1.0, aggression_state)
	var throttle_bark_db := throttle_attack * lerpf(0.0, 0.55, moving)
	var low_speed_gain := lerpf(2.8, 0.0, clampf(inverse_lerp(10.0, 28.0, speed_mps), 0.0, 1.0))

	_debug_scalar_state = {
		"speed_kmh": speed_kmh,
			"speed_mps": speed_mps,
			"gear": vehicle.current_gear,
			"rpm": rpm,
			"rpm_norm": rpm_norm,
			"coupled_rpm": coupled_rpm,
				"drivetrain_rpm": drivetrain_rpm,
				"character_rpm": character_rpm,
				"character_rpm_norm": character_rpm_norm,
				"band_pitch_rpm": band_pitch_rpm,
				"rpm_gap": rpm_gap,
			"throttle": load,
			"brake": brake,
			"clutch": vehicle.clutch_amount,
			"torque_norm": clampf(vehicle.torque_output / maxf(vehicle.max_torque, 1.0), -1.0, 1.0),
			"engine_load": engine_load,
			"drive_state": drive_state,
			"coast_state": coast_state,
			"moving": moving,
			"low_speed_presence": low_speed_presence,
			"crawl_presence": crawl_presence,
			"low_speed_gain": low_speed_gain,
			"high_rpm_state": high_rpm_state,
			"spectral_coupling": spectral_coupling,
			"throttle_attack_rate": throttle_rise_rate,
			"throttle_attack": throttle_attack,
				"aggression_state": aggression_state,
				"mid_character_gate": mid_character_gate,
				"high_character_gate": high_character_gate,
				"top_end_gate": top_end_gate,
				"top_end_preload_gate": top_end_preload_gate,
				"shift_phase": vehicle.shift_phase,
			"shift_direction": vehicle.shift_direction,
			"shift_state": shift_state,
			"redline_state": redline_state,
			"is_shifting": vehicle.is_shifting,
		"motor_is_redline": vehicle.motor_is_redline,
	}
	_debug_mix_weights = {
		"idle": idle_weight,
		"low_on": low_on_weight,
		"med_on": med_on_weight,
		"high_on": high_on_weight,
		"low_off": low_off_weight,
		"med_off": med_off_weight,
		"high_off": high_off_weight,
		"max_rpm": max_rpm_weight,
	}
	_debug_loop_target_db.clear()
	_debug_loop_target_pitch.clear()

	_set_loop_mix(&"idle", _mix_db(idle_weight, -26.0, -7.5) + low_speed_gain * 0.85, clampf(rpm / 920.0, 0.94, 1.08), delta)
	# Keep the low/mid pitch targets closer together so the sample handoff reads as one engine.
	_set_loop_mix(&"low_on", _mix_db(low_on_weight, -31.5, -8.4) + drive_boost + low_speed_gain + aggression_db * 0.16 + throttle_bark_db * 0.10, clampf(lerpf(rpm, band_pitch_rpm, 0.18) / 3050.0 + aggression_state * 0.006, 0.93, 1.08), delta)
	_set_loop_mix(&"med_on", _mix_db(med_on_weight, -35.4, -10.3) + drive_boost + aggression_db * 0.44 + throttle_bark_db * 0.22, clampf(band_pitch_rpm / 4100.0 + aggression_state * 0.008 + throttle_attack * 0.003, 0.97, 1.095), delta)
	_set_loop_mix(&"high_on", _mix_db(high_on_weight, -34.0, -8.3) + drive_boost * 0.76 + aggression_db * 0.62 + throttle_bark_db * 0.32, clampf(band_pitch_rpm / 6400.0 + aggression_state * 0.007 + throttle_attack * 0.004, 0.95, 1.065), delta)
	_set_loop_mix(&"low_off", _mix_db(low_off_weight, -36.0, -11.8) + low_speed_gain * 0.45, clampf(rpm / 2250.0, 0.93, 1.08), delta)
	_set_loop_mix(&"med_off", _mix_db(med_off_weight, -37.0, -12.2), clampf(band_pitch_rpm / 4100.0, 0.94, 1.07), delta)
	_set_loop_mix(&"high_off", _mix_db(high_off_weight, -35.5, -10.8), clampf(band_pitch_rpm / 6400.0, 0.95, 1.05), delta)
	_set_loop_mix(&"max_rpm", _mix_db(max_rpm_weight, -37.5, -9.6) + drive_boost * 0.44 + aggression_db * 0.34, clampf(band_pitch_rpm / maxf(vehicle.max_rpm * 0.91, 1.0) + aggression_state * 0.004, 0.97, 1.045), delta)


func _process_shift_events() -> void:
	if _shift_event_cooldown > 0.0:
		return
	if vehicle.current_gear == _last_gear:
		return
	if _last_gear <= 0 or vehicle.current_gear <= 0:
		return
	if absf(vehicle.speed) < 2.5:
		return

	var rpm_norm := inverse_lerp(vehicle.idle_rpm, vehicle.max_rpm, vehicle.motor_rpm)
	if vehicle.current_gear > _last_gear:
		_play_event(&"gear_up", lerpf(-11.5, -6.0, rpm_norm), lerpf(0.97, 1.02, rpm_norm))
	else:
		_play_event(&"gear_down", lerpf(-12.0, -7.0, rpm_norm), lerpf(0.96, 1.01, rpm_norm))

	_shift_event_cooldown = 0.16


func _set_loop_mix(id: StringName, target_db: float, target_pitch: float, delta: float) -> void:
	var player: AudioStreamPlayer3D = _loop_players.get(id)
	if not player:
		return

	target_db += LOOP_MASTER_GAIN_DB + float(_loop_gain_db.get(id, 0.0))
	_debug_loop_target_db[String(id)] = target_db
	_debug_loop_target_pitch[String(id)] = target_pitch
	player.volume_db = lerpf(player.volume_db, target_db, clampf(delta * 8.0, 0.0, 1.0))
	player.pitch_scale = lerpf(player.pitch_scale, target_pitch, clampf(delta * 10.0, 0.0, 1.0))


func _play_event(id: StringName, volume_db: float, pitch_scale: float) -> void:
	var player: AudioStreamPlayer3D = _event_players.get(id)
	if not player:
		return

	player.stream_paused = false
	player.volume_db = volume_db + EVENT_MASTER_GAIN_DB + float(_event_gain_db.get(id, 0.0))
	player.pitch_scale = pitch_scale
	player.play()
	_debug_last_event = {
		"id": String(id),
		"volume_db": player.volume_db,
		"pitch_scale": player.pitch_scale,
		"age": 0.0,
	}


func get_debug_snapshot() -> Dictionary:
	var snapshot := _debug_scalar_state.duplicate(true)
	snapshot["weights"] = _debug_mix_weights.duplicate(true)
	snapshot["loop_db"] = _debug_loop_target_db.duplicate(true)
	snapshot["loop_pitch"] = _debug_loop_target_pitch.duplicate(true)
	snapshot["last_event"] = _debug_last_event.duplicate(true)
	return snapshot


func _triangle(value: float, start: float, peak: float, end: float) -> float:
	if value <= start or value >= end:
		return 0.0
	if value < peak:
		return inverse_lerp(start, peak, value)
	return 1.0 - inverse_lerp(peak, end, value)


func _mix_db(weight: float, silent_db: float, loud_db: float) -> float:
	if weight <= 0.01:
		return -70.0
	return lerpf(silent_db, loud_db, clampf(weight, 0.0, 1.0))
