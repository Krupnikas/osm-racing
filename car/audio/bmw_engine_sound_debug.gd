extends Node

const DEBUG_PAGES := ["Overview", "Mix", "Loops", "Warnings"]
const LOOP_ORDER := ["idle", "low_on", "med_on", "high_on", "low_off", "med_off", "high_off", "max_rpm"]

@export var vehicle: Vehicle
@export var engine_sound_path: NodePath = NodePath("../EngineSound")
@export var show_overlay := false
@export var capture_trace := false
@export var trace_path := "user://bmw_engine_sound_trace.csv"
@export var trace_archive_dir := "user://bmw_engine_sound_traces"
@export_range(2.0, 60.0, 1.0) var sample_rate_hz := 20.0
@export_range(0.05, 0.5, 0.05) var overlay_refresh_seconds := 0.1

var _engine_sound: Node = null
var _canvas_layer: CanvasLayer
var _panel: PanelContainer
var _label: Label
var _current_page := 0
var _overlay_timer := 0.0
var _sample_timer := 0.0
var _trace_file: FileAccess = null
var _archive_trace_file: FileAccess = null
var _trace_absolute_path := ""
var _archive_absolute_path := ""


func _ready() -> void:
	if not vehicle:
		var parent := get_parent()
		if parent is Vehicle:
			vehicle = parent

	_engine_sound = _resolve_engine_sound()
	_create_overlay()
	_set_overlay_visibility(show_overlay)

	if capture_trace:
		_open_trace_file()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("ShowDebug"):
		show_overlay = !show_overlay
		_set_overlay_visibility(show_overlay)

	if show_overlay and Input.is_action_just_pressed("DebugNext"):
		_current_page = (_current_page + 1) % DEBUG_PAGES.size()

	if show_overlay and Input.is_action_just_pressed("DebugPrevious"):
		_current_page = posmod(_current_page - 1, DEBUG_PAGES.size())

	if not show_overlay:
		return

	_overlay_timer += delta
	if _overlay_timer < overlay_refresh_seconds:
		return

	_overlay_timer = 0.0
	var snapshot := _build_snapshot()
	_label.text = _format_page(snapshot)


func _physics_process(delta: float) -> void:
	if not capture_trace or (_trace_file == null and _archive_trace_file == null):
		return

	_sample_timer += delta
	var sample_interval := 1.0 / maxf(sample_rate_hz, 1.0)
	if _sample_timer < sample_interval:
		return

	_sample_timer = 0.0
	var snapshot := _build_snapshot()
	var trace_row := _build_trace_row(snapshot)
	if _trace_file:
		_trace_file.store_line(trace_row)
		_trace_file.flush()
	if _archive_trace_file:
		_archive_trace_file.store_line(trace_row)
		_archive_trace_file.flush()


func _exit_tree() -> void:
	if _trace_file:
		_trace_file.flush()
		_trace_file.close()
		_trace_file = null
	if _archive_trace_file:
		_archive_trace_file.flush()
		_archive_trace_file.close()
		_archive_trace_file = null


func _resolve_engine_sound() -> Node:
	if engine_sound_path != NodePath():
		var node := get_node_or_null(engine_sound_path)
		if node:
			return node

	var parent := get_parent()
	if parent:
		return parent.get_node_or_null("EngineSound")
	return null


func _create_overlay() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 100
	add_child(_canvas_layer)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
	margin.offset_left = 16.0
	margin.offset_top = 16.0
	margin.offset_right = 496.0
	margin.offset_bottom = 420.0
	_canvas_layer.add_child(margin)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(480.0, 360.0)
	margin.add_child(_panel)

	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	_panel.add_child(_label)


func _set_overlay_visibility(visible_state: bool) -> void:
	if _canvas_layer:
		_canvas_layer.visible = visible_state


func _open_trace_file() -> void:
	_trace_absolute_path = ProjectSettings.globalize_path(trace_path)
	_trace_file = FileAccess.open(trace_path, FileAccess.WRITE)
	if _trace_file == null:
		push_warning("BMW sound debug trace could not be opened: %s" % _trace_absolute_path)
	else:
		var header := _build_trace_header()
		_trace_file.store_line(header)
		_trace_file.flush()

	_open_archive_trace_file()


func _open_archive_trace_file() -> void:
	var archive_dir_absolute := ProjectSettings.globalize_path(trace_archive_dir)
	var dir_error := DirAccess.make_dir_recursive_absolute(archive_dir_absolute)
	if dir_error != OK and not DirAccess.dir_exists_absolute(archive_dir_absolute):
		push_warning("BMW sound debug archive directory could not be created: %s" % archive_dir_absolute)
		return

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var archive_path := "%s/bmw_engine_sound_trace_%s.csv" % [trace_archive_dir.trim_suffix("/"), timestamp]
	_archive_absolute_path = ProjectSettings.globalize_path(archive_path)
	_archive_trace_file = FileAccess.open(archive_path, FileAccess.WRITE)
	if _archive_trace_file == null:
		push_warning("BMW sound debug archive trace could not be opened: %s" % _archive_absolute_path)
		return

	_archive_trace_file.store_line(_build_trace_header())
	_archive_trace_file.flush()


func _build_snapshot() -> Dictionary:
	var snapshot := {}
	if _engine_sound and _engine_sound.has_method("get_debug_snapshot"):
		snapshot = _engine_sound.call("get_debug_snapshot")

		if vehicle:
			snapshot["speed_kmh"] = float(snapshot.get("speed_kmh", vehicle.speed * 3.6))
			snapshot["speed_mps"] = float(snapshot.get("speed_mps", vehicle.speed))
			snapshot["gear"] = int(snapshot.get("gear", vehicle.current_gear))
			snapshot["rpm"] = float(snapshot.get("rpm", vehicle.motor_rpm))
			snapshot["coupled_rpm"] = float(snapshot.get("coupled_rpm", vehicle.wheel_coupled_rpm))
			snapshot["drivetrain_rpm"] = float(snapshot.get("drivetrain_rpm", vehicle.drivetrain_rpm))
			snapshot["throttle"] = float(snapshot.get("throttle", vehicle.throttle_amount))
			snapshot["brake"] = float(snapshot.get("brake", vehicle.brake_amount))
			snapshot["clutch"] = float(snapshot.get("clutch", vehicle.clutch_amount))
			snapshot["torque_norm"] = float(snapshot.get("torque_norm", vehicle.torque_output / maxf(vehicle.max_torque, 1.0)))
			snapshot["engine_load"] = float(snapshot.get("engine_load", vehicle.engine_load))
			snapshot["throttle_attack_rate"] = float(snapshot.get("throttle_attack_rate", vehicle.throttle_attack_rate))
			snapshot["shift_phase"] = float(snapshot.get("shift_phase", vehicle.shift_phase))
			snapshot["shift_direction"] = int(snapshot.get("shift_direction", vehicle.shift_direction))
			snapshot["is_shifting"] = bool(snapshot.get("is_shifting", vehicle.is_shifting))
			snapshot["motor_is_redline"] = bool(snapshot.get("motor_is_redline", vehicle.motor_is_redline))

	if not snapshot.has("weights"):
		snapshot["weights"] = {}
	if not snapshot.has("loop_db"):
		snapshot["loop_db"] = {}
	if not snapshot.has("loop_pitch"):
		snapshot["loop_pitch"] = {}
	if not snapshot.has("last_event"):
		snapshot["last_event"] = {"id": "", "volume_db": -80.0, "pitch_scale": 1.0, "age": 9999.0}

	return snapshot


func _format_page(snapshot: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("BMW Engine Sound Debug")
	lines.append("Page %d/%d: %s" % [_current_page + 1, DEBUG_PAGES.size(), DEBUG_PAGES[_current_page]])
	lines.append("` toggles, . / , switch pages")
	lines.append("")

	match _current_page:
		0:
			lines.append_array(_build_overview_lines(snapshot))
		1:
			lines.append_array(_build_mix_lines(snapshot))
		2:
			lines.append_array(_build_loop_lines(snapshot))
		3:
			lines.append_array(_build_warning_lines(snapshot))

	if capture_trace:
		lines.append("")
		lines.append("Trace latest: %s" % _trace_absolute_path)
		if _archive_absolute_path != "":
			lines.append("Trace archive: %s" % _archive_absolute_path)

	return "\n".join(lines)


func _build_overview_lines(snapshot: Dictionary) -> Array[String]:
	var last_event: Dictionary = snapshot.get("last_event", {})
	return [
		"Speed:    %6.1f km/h" % float(snapshot.get("speed_kmh", 0.0)),
		"Gear:     %6d" % int(snapshot.get("gear", 0)),
		"RPM:      %6.0f" % float(snapshot.get("rpm", 0.0)),
			"Throttle: %6.2f" % float(snapshot.get("throttle", 0.0)),
			"Brake:    %6.2f" % float(snapshot.get("brake", 0.0)),
			"Clutch:   %6.2f" % float(snapshot.get("clutch", 0.0)),
			"Load:     %6.2f" % float(snapshot.get("engine_load", 0.0)),
			"Torque:   %6.2f" % float(snapshot.get("torque_norm", 0.0)),
			"Shifting: %6s" % String(snapshot.get("is_shifting", false)),
			"Shift ph: %6.2f" % float(snapshot.get("shift_phase", 0.0)),
			"Redline:  %6s" % String(snapshot.get("motor_is_redline", false)),
		"",
		"Last event: %s" % String(last_event.get("id", "")),
		"Event dB:   %6.1f" % float(last_event.get("volume_db", -80.0)),
		"Event pitch:%6.2f" % float(last_event.get("pitch_scale", 1.0)),
		"Event age:  %6.2f s" % float(last_event.get("age", 9999.0)),
	]


func _build_mix_lines(snapshot: Dictionary) -> Array[String]:
	return [
			"RPM norm:          %5.2f" % float(snapshot.get("rpm_norm", 0.0)),
			"Coupled RPM:       %5.0f" % float(snapshot.get("coupled_rpm", 0.0)),
			"Drivetrain RPM:    %5.0f" % float(snapshot.get("drivetrain_rpm", 0.0)),
			"Character RPM:     %5.0f" % float(snapshot.get("character_rpm", 0.0)),
			"Band-pitch RPM:    %5.0f" % float(snapshot.get("band_pitch_rpm", 0.0)),
			"RPM gap:           %5.0f" % float(snapshot.get("rpm_gap", 0.0)),
			"Engine load:       %5.2f" % float(snapshot.get("engine_load", 0.0)),
			"Drive state:       %5.2f" % float(snapshot.get("drive_state", 0.0)),
			"Coast state:       %5.2f" % float(snapshot.get("coast_state", 0.0)),
			"Moving:            %5.2f" % float(snapshot.get("moving", 0.0)),
			"Low speed pres.:   %5.2f" % float(snapshot.get("low_speed_presence", 0.0)),
			"Crawl presence:    %5.2f" % float(snapshot.get("crawl_presence", 0.0)),
			"Low speed gain:    %5.2f dB" % float(snapshot.get("low_speed_gain", 0.0)),
			"High RPM state:    %5.2f" % float(snapshot.get("high_rpm_state", 0.0)),
			"Spec coupling:     %5.2f" % float(snapshot.get("spectral_coupling", 0.0)),
			"Throttle rate:     %5.2f" % float(snapshot.get("throttle_attack_rate", 0.0)),
			"Throttle attack:   %5.2f" % float(snapshot.get("throttle_attack", 0.0)),
			"Aggression:        %5.2f" % float(snapshot.get("aggression_state", 0.0)),
			"Mid gate:          %5.2f" % float(snapshot.get("mid_character_gate", 0.0)),
			"High gate:         %5.2f" % float(snapshot.get("high_character_gate", 0.0)),
			"Top preload:       %5.2f" % float(snapshot.get("top_end_preload_gate", 0.0)),
			"Top-end gate:      %5.2f" % float(snapshot.get("top_end_gate", 0.0)),
			"Shift phase:       %5.2f" % float(snapshot.get("shift_phase", 0.0)),
			"Shift direction:   %5d" % int(snapshot.get("shift_direction", 0)),
			"Shift state:       %5.2f" % float(snapshot.get("shift_state", 0.0)),
			"Redline state:     %5.2f" % float(snapshot.get("redline_state", 0.0)),
	]


func _build_loop_lines(snapshot: Dictionary) -> Array[String]:
	var lines: Array[String] = ["Loop          Weight   dB     Pitch"]
	var weights: Dictionary = snapshot.get("weights", {})
	var loop_db: Dictionary = snapshot.get("loop_db", {})
	var loop_pitch: Dictionary = snapshot.get("loop_pitch", {})

	for loop_id in LOOP_ORDER:
		lines.append(
			"%-11s %6.2f %6.1f %7.2f" % [
				loop_id,
				float(weights.get(loop_id, 0.0)),
				float(loop_db.get(loop_id, -80.0)),
				float(loop_pitch.get(loop_id, 1.0)),
			]
		)

	return lines


func _build_warning_lines(snapshot: Dictionary) -> Array[String]:
	var warnings := _collect_warnings(snapshot)
	if warnings.is_empty():
		return ["No obvious audio-mapping warnings right now."]
	return warnings


func _collect_warnings(snapshot: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var speed_kmh := float(snapshot.get("speed_kmh", 0.0))
	var rpm := float(snapshot.get("rpm", 0.0))
	var weights: Dictionary = snapshot.get("weights", {})

	if speed_kmh < 120.0 and float(weights.get("high_on", 0.0)) > 0.35:
		warnings.append("high_on is strong below 120 km/h")
	if speed_kmh < 160.0 and float(weights.get("max_rpm", 0.0)) > 0.18:
		warnings.append("max_rpm layer is audible before real top-end speed")
	if speed_kmh < 80.0 and rpm > 5500.0:
		warnings.append("RPM is above 5500 below 80 km/h")
	if speed_kmh < 20.0 and float(weights.get("low_on", 0.0)) < 0.12 and float(snapshot.get("throttle", 0.0)) > 0.25:
		warnings.append("low_on is weak during low-speed acceleration")
	if speed_kmh > 40.0 and float(weights.get("idle", 0.0)) > 0.28:
		warnings.append("idle layer is hanging too long after launch")

	return warnings


func _build_trace_header() -> String:
	var headers := [
		"time_s",
		"speed_kmh",
		"gear",
			"rpm",
			"rpm_norm",
			"coupled_rpm",
			"drivetrain_rpm",
			"character_rpm",
			"character_rpm_norm",
			"band_pitch_rpm",
			"rpm_gap",
			"throttle",
			"brake",
			"clutch",
			"torque_norm",
			"engine_load",
			"drive_state",
			"coast_state",
			"moving",
			"low_speed_presence",
			"crawl_presence",
			"low_speed_gain",
			"high_rpm_state",
			"spectral_coupling",
			"throttle_attack_rate",
			"throttle_attack",
			"aggression_state",
			"mid_character_gate",
			"high_character_gate",
			"top_end_preload_gate",
			"top_end_gate",
			"shift_phase",
			"shift_direction",
			"shift_state",
			"redline_state",
			"is_shifting",
		"event_id",
		"event_age",
		"event_volume_db",
		"event_pitch_scale",
	]

	for loop_id in LOOP_ORDER:
		headers.append("%s_weight" % loop_id)
		headers.append("%s_db" % loop_id)
		headers.append("%s_pitch" % loop_id)

	return ",".join(headers)


func _build_trace_row(snapshot: Dictionary) -> String:
	var values := [
		"%.3f" % (Time.get_ticks_msec() * 0.001),
		"%.3f" % float(snapshot.get("speed_kmh", 0.0)),
			str(int(snapshot.get("gear", 0))),
			"%.3f" % float(snapshot.get("rpm", 0.0)),
			"%.5f" % float(snapshot.get("rpm_norm", 0.0)),
			"%.3f" % float(snapshot.get("coupled_rpm", 0.0)),
				"%.3f" % float(snapshot.get("drivetrain_rpm", 0.0)),
				"%.3f" % float(snapshot.get("character_rpm", 0.0)),
				"%.5f" % float(snapshot.get("character_rpm_norm", 0.0)),
				"%.3f" % float(snapshot.get("band_pitch_rpm", 0.0)),
				"%.3f" % float(snapshot.get("rpm_gap", 0.0)),
			"%.5f" % float(snapshot.get("throttle", 0.0)),
			"%.5f" % float(snapshot.get("brake", 0.0)),
			"%.5f" % float(snapshot.get("clutch", 0.0)),
			"%.5f" % float(snapshot.get("torque_norm", 0.0)),
			"%.5f" % float(snapshot.get("engine_load", 0.0)),
			"%.5f" % float(snapshot.get("drive_state", 0.0)),
			"%.5f" % float(snapshot.get("coast_state", 0.0)),
			"%.5f" % float(snapshot.get("moving", 0.0)),
			"%.5f" % float(snapshot.get("low_speed_presence", 0.0)),
			"%.5f" % float(snapshot.get("crawl_presence", 0.0)),
			"%.5f" % float(snapshot.get("low_speed_gain", 0.0)),
			"%.5f" % float(snapshot.get("high_rpm_state", 0.0)),
			"%.5f" % float(snapshot.get("spectral_coupling", 0.0)),
				"%.5f" % float(snapshot.get("throttle_attack_rate", 0.0)),
				"%.5f" % float(snapshot.get("throttle_attack", 0.0)),
				"%.5f" % float(snapshot.get("aggression_state", 0.0)),
				"%.5f" % float(snapshot.get("mid_character_gate", 0.0)),
				"%.5f" % float(snapshot.get("high_character_gate", 0.0)),
				"%.5f" % float(snapshot.get("top_end_preload_gate", 0.0)),
				"%.5f" % float(snapshot.get("top_end_gate", 0.0)),
			"%.5f" % float(snapshot.get("shift_phase", 0.0)),
			str(int(snapshot.get("shift_direction", 0))),
			"%.5f" % float(snapshot.get("shift_state", 0.0)),
			"%.5f" % float(snapshot.get("redline_state", 0.0)),
		"1" if bool(snapshot.get("is_shifting", false)) else "0",
		String(snapshot.get("last_event", {}).get("id", "")),
		"%.5f" % float(snapshot.get("last_event", {}).get("age", 9999.0)),
		"%.5f" % float(snapshot.get("last_event", {}).get("volume_db", -80.0)),
		"%.5f" % float(snapshot.get("last_event", {}).get("pitch_scale", 1.0)),
	]

	var weights: Dictionary = snapshot.get("weights", {})
	var loop_db: Dictionary = snapshot.get("loop_db", {})
	var loop_pitch: Dictionary = snapshot.get("loop_pitch", {})
	for loop_id in LOOP_ORDER:
		values.append("%.5f" % float(weights.get(loop_id, 0.0)))
		values.append("%.5f" % float(loop_db.get(loop_id, -80.0)))
		values.append("%.5f" % float(loop_pitch.get(loop_id, 1.0)))

	return ",".join(values)
