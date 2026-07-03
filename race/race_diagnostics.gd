extends Node
class_name RaceDiagnostics

## Continuous, objective race telemetry for debugging. Samples the PLAYER and every
## opponent during a race and records two things that matter for the current bugs:
##   1. Y vs the real ground surface beneath the car (raycast, cars excluded) →
##      detects falling through / under terrain, with depth.
##   2. Signed lateral deviation from the race route centerline → detects weaving
##      (sign-changes) and how far off the desired line each car gets.
##
## Read via get_report() (MCP `execute_game_script`). Auto-resets each new race.
## Cheap: SAMPLE_HZ for ≤4 cars. Leave enabled; it only samples while RACING.

const SAMPLE_HZ := 10.0
const UNDER_MARGIN := 1.5     # м ниже поверхности → считаем "под террейном"
const STATE_RACING := 3        # RaceManager.State.RACING

@export var race_manager_path: NodePath
var race_manager
var enabled := true

var _accum := 0.0
var _was_racing := false
var _stats: Dictionary = {}    # name -> aggregate dict


func _ready() -> void:
	if race_manager_path:
		race_manager = get_node_or_null(race_manager_path)


func reset() -> void:
	_stats.clear()


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	if race_manager == null:
		race_manager = get_parent().get_node_or_null("RaceManager")
		if race_manager == null:
			return
	var racing: bool = race_manager.current_state == STATE_RACING
	if racing and not _was_racing:
		reset()  # new race started — fresh stats
	_was_racing = racing
	if not racing:
		return
	_accum += delta
	if _accum < 1.0 / SAMPLE_HZ:
		return
	_accum = 0.0
	_sample()


func _sample() -> void:
	var world := get_viewport().find_world_3d()
	if world == null:
		return
	var ss := world.direct_space_state
	if ss == null:
		return
	var route = race_manager._race_route

	var excl: Array = []
	var player = race_manager._car
	if is_instance_valid(player):
		excl.append(player.get_rid())
	for o in race_manager._opponents:
		if is_instance_valid(o):
			excl.append(o.get_rid())

	if is_instance_valid(player):
		_sample_car("Player", player, route, ss, excl)
	for o in race_manager._opponents:
		if is_instance_valid(o):
			_sample_car(str(o.racer_name), o, route, ss, excl)


func _sample_car(nm: String, car, route, ss: PhysicsDirectSpaceState3D, excl: Array) -> void:
	var p: Vector3 = car.global_position

	# Topmost real surface at the car's XZ (cars excluded).
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, p.y + 500.0, p.z), Vector3(p.x, p.y - 500.0, p.z))
	q.exclude = excl
	var r: Dictionary = ss.intersect_ray(q)
	var has_surf: bool = not r.is_empty()
	var dy: float = INF                       # p.y - surface (>0 above, <0 under)
	if has_surf:
		dy = p.y - float(r["position"].y)

	# Signed lateral deviation from the route centerline (the "desired line").
	# Flatten to XZ — the route is authored at y=0 but cars sit at terrain
	# elevation (~120m); using 3D distance would pollute lateral with that gap.
	var lat: float = 0.0
	if route and route.points.size() >= 2:
		var p_flat := Vector3(p.x, 0.0, p.z)
		var proj: Dictionary = route.project_position(p_flat, 0)
		var rdata: Dictionary = route.get_point_at_distance(proj.get("distance", 0.0))
		var rpos: Vector3 = rdata["position"]
		var rdir: Vector3 = rdata["direction"]
		var to_car := Vector3(p.x - rpos.x, 0.0, p.z - rpos.z)
		var rdir_flat := Vector3(rdir.x, 0.0, rdir.z)
		var lat_dist: float = to_car.length()
		var side: float = signf(rdir_flat.cross(to_car).y)
		lat = lat_dist * side

	var spd: float = 0.0
	if car is RigidBody3D:
		spd = car.linear_velocity.length() * 3.6

	if not _stats.has(nm):
		_stats[nm] = {
			"n": 0, "min_y": INF, "max_y": -INF,
			"no_surface": 0, "under": 0, "max_under_depth": 0.0,
			"lat_min": INF, "lat_max": -INF, "lat_abs_max": 0.0,
			"prev_lat_sign": 0, "lat_sign_changes": 0,
			"spd_sum": 0.0, "spd_min": INF,
		}
	var s: Dictionary = _stats[nm]
	s["n"] += 1
	s["min_y"] = minf(s["min_y"], p.y)
	s["max_y"] = maxf(s["max_y"], p.y)
	if not has_surf:
		s["no_surface"] += 1
	elif dy < -UNDER_MARGIN:
		s["under"] += 1
		s["max_under_depth"] = maxf(s["max_under_depth"], -dy)
	s["lat_min"] = minf(s["lat_min"], lat)
	s["lat_max"] = maxf(s["lat_max"], lat)
	s["lat_abs_max"] = maxf(s["lat_abs_max"], absf(lat))
	var sgn := 0
	if lat > 0.3:
		sgn = 1
	elif lat < -0.3:
		sgn = -1
	if sgn != 0:
		if s["prev_lat_sign"] != 0 and sgn != s["prev_lat_sign"]:
			s["lat_sign_changes"] += 1
		s["prev_lat_sign"] = sgn
	s["spd_sum"] += spd
	s["spd_min"] = minf(s["spd_min"], spd)


func get_report() -> Dictionary:
	var out: Dictionary = {}
	for nm in _stats:
		var s: Dictionary = _stats[nm]
		var n: int = maxi(1, s["n"])
		out[nm] = {
			"samples": s["n"],
			"min_y": snappedf(s["min_y"], 0.1),
			"max_y": snappedf(s["max_y"], 0.1),
			"frames_under_terrain": s["under"],
			"under_frac": snappedf(float(s["under"]) / n, 0.01),
			"max_under_depth_m": snappedf(s["max_under_depth"], 0.1),
			"frames_no_surface": s["no_surface"],
			"lat_abs_max": snappedf(s["lat_abs_max"], 0.1),
			"lat_p2p": snappedf(s["lat_max"] - s["lat_min"], 0.1),
			"lat_sign_changes": s["lat_sign_changes"],
			"avg_speed_kmh": snappedf(s["spd_sum"] / n, 0.1),
			"min_speed_kmh": snappedf(s["spd_min"], 0.1),
			"FELL": s["under"] > 0 or s["no_surface"] > 0,
		}
	return out
