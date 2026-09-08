extends Node
class_name PerfAutodrive

# Reproducible driving performance test.
#
# Spawns at Pionerskaya (Cherepovets), disables player-car collisions, and drives
# the real player node due south at a constant speed through the FULL game scene
# (streaming, LOD, rendering, physics world all live). Logs a per-second time series
# (distance vs fps / slow frames / node / resource / VRAM / chunk counts) plus, with
# --perf-verbose, a full per-slow-frame subsystem breakdown from the terrain generator.
#
# The point: reproduce "the further you drive, the more freezes" deterministically and
# see whether the cause is ACCUMULATION (nodes/resources/VRAM/pairs grow with distance)
# or per-boundary GPU-upload CHURN (spikes without growth).
#
# Enabled by main.gd when `-- --perf-drive` is passed. Optional:
#   --drive-speed=<m/s>  (default 25 = 90 km/h)
#   --drive-time=<sec>   (default 120)

const PIONERSKAYA := Vector2(59.149827, 37.948859)  # sprint start lat/lon

var terrain: Node
var car: RigidBody3D
var speed := 25.0
var run_time := 45.0   # drive seconds after arming (override with --drive-time=)
var no_npcs := false
const LOAD_BUDGET := 25.0  # extra wall-clock allowance for initial load before the hard cap
var _finished := false

var _armed := false
var _t := 0.0
var _spawn_pos := Vector3.ZERO
var _log_timer := 0.0
var _slow16 := 0        # frames > 16ms this interval (< 60fps)
var _slow33 := 0        # frames > 33ms this interval (< 30fps) — real hitches
var _worst_ms := 0.0
var _south := Vector3(0, 0, 1)  # +Z = south in this coordinate convention


static func parse_cmdline() -> Dictionary:
	# Returns {enabled, speed, run_time} from `-- --perf-drive ...` user args.
	var out := {"enabled": false, "speed": 25.0, "run_time": 45.0, "no_npcs": false}
	for arg in OS.get_cmdline_user_args():
		if arg == "--perf-drive":
			out["enabled"] = true
		elif arg.begins_with("--drive-speed="):
			out["speed"] = float(arg.substr("--drive-speed=".length()))
		elif arg.begins_with("--drive-time="):
			out["run_time"] = float(arg.substr("--drive-time=".length()))
		elif arg == "--no-npcs":
			out["no_npcs"] = true
	return out


func _ready() -> void:
	var cfg := parse_cmdline()
	speed = cfg["speed"]
	run_time = cfg["run_time"]
	no_npcs = cfg["no_npcs"]
	terrain = get_tree().get_first_node_in_group("terrain_generator")
	if terrain == null:
		push_error("[PERFDRIVE] no terrain_generator in tree")
		return
	if terrain.has_signal("initial_load_complete"):
		terrain.initial_load_complete.connect(_on_load_complete)
	# Hard wall-clock cap: the test ALWAYS exits within run_time + load budget, even if the
	# terrain never finishes loading / never arms. Keeps runs bounded.
	get_tree().create_timer(run_time + LOAD_BUDGET).timeout.connect(_on_hard_cap)
	print("[PERFDRIVE] waiting for terrain load — speed=%.1f m/s (%.0f km/h), run=%.0fs (hard cap %.0fs)" % [
		speed, speed * 3.6, run_time, run_time + LOAD_BUDGET])


func _on_load_complete() -> void:
	# Let the car settle on the road first (main._spawn_car_on_road runs on this signal too).
	await get_tree().create_timer(2.0).timeout
	_arm()


func _arm() -> void:
	car = get_tree().get_first_node_in_group("player") as RigidBody3D
	if car == null:
		push_error("[PERFDRIVE] no player RigidBody3D found")
		return

	# Neutralize the GEVP vehicle so it doesn't fight our kinematic drive.
	car.set_physics_process(false)
	car.set_process(false)
	# Disable player-car collisions (requested) + make it a kinematic mover.
	car.freeze = true
	car.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	car.collision_layer = 0
	car.collision_mask = 0

	_spawn_pos = car.global_position
	# Face south (visual only) and feed the predictive-LOD velocity signal.
	car.global_rotation = Vector3(0, PI, 0)
	terrain.perf_velocity_override = _south * speed
	terrain._perf_verbose = true  # log EVERY slow frame with full breakdown

	if no_npcs:
		var tm := get_tree().current_scene.find_child("TrafficManager", true, false)
		if tm:
			tm.max_npcs = 0
			tm.set_process(false)  # also kill the per-frame chunk scan in _update_spawning
			print("[PERFDRIVE] NPC traffic DISABLED (max_npcs=0, _process off)")

	_armed = true
	print("\n========== PERFDRIVE ARMED ==========")
	print("spawn=(%.0f, %.0f) speed=%.1f m/s heading=SOUTH collisions=OFF perf_verbose=ON" % [
		_spawn_pos.x, _spawn_pos.z, speed])
	print("=====================================\n")


func _physics_process(delta: float) -> void:
	if not _armed or car == null:
		return
	# Constant-speed kinematic step due south (Y held at spawn height).
	car.global_position += _south * speed * delta


func _process(delta: float) -> void:
	if not _armed:
		return
	_t += delta
	var ms := delta * 1000.0
	if ms > 16.0:
		_slow16 += 1
	if ms > 33.0:
		_slow33 += 1
	_worst_ms = maxf(_worst_ms, ms)

	_log_timer += delta
	if _log_timer >= 1.0:
		_emit_log()
		_log_timer = 0.0

	if _t >= run_time:
		_finish()


func _emit_log() -> void:
	var dist := _spawn_pos.distance_to(car.global_position)
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var res := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var objs := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var verts := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1_000_000.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1_048_576.0
	var pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	var loaded := 0
	var loading := 0
	var lc = terrain.get("_loaded_chunks")
	if lc is Dictionary:
		loaded = (lc as Dictionary).size()
	var lg = terrain.get("_loading_chunks")
	if lg is Dictionary:
		loading = (lg as Dictionary).size()
	print("[PERFDRIVE] t=%3.0fs dist=%5.0fm fps=%2.0f slow16/s=%2d slow33/s=%2d worst=%5.1fms | nodes=%d res=%d obj=%d verts=%.1fM draws=%d vram=%.0fMB pairs=%d chunks=%d(+%d)" % [
		_t, dist, Engine.get_frames_per_second(), _slow16, _slow33, _worst_ms,
		nodes, res, objs, verts, draws, vram, pairs, loaded, loading])
	_slow16 = 0
	_slow33 = 0
	_worst_ms = 0.0


func _on_hard_cap() -> void:
	if _finished:
		return
	print("[PERFDRIVE] hard time cap (%.0fs) reached — exiting" % (run_time + LOAD_BUDGET))
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_armed = false
	if terrain:
		terrain.perf_velocity_override = Vector3.ZERO
	var dist := _spawn_pos.distance_to(car.global_position) if car else 0.0
	print("\n========== PERFDRIVE DONE ==========")
	print("drove %.0f m in %.0f s (avg %.1f m/s)" % [dist, _t, dist / maxf(_t, 0.001)])
	print("====================================\n")
	await get_tree().create_timer(0.5).timeout
	# Use the project's crash-free exit (SIGKILL) — a plain get_tree().quit() hits the
	# WorkerThreadPool teardown SIGSEGV while chunk-streaming tasks are still in flight.
	var shutdown := get_node_or_null("/root/AppShutdown")
	if shutdown and shutdown.has_method("quit_clean"):
		shutdown.quit_clean()
	else:
		get_tree().quit()
