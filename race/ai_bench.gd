extends Node3D
class_name AIBench

## BENCH-only isolated AI test harness (docs/RACER_AI_IMPLEMENTATION_PLAN.md § Phase 0).
## Flat hand-authored track + opponents + curb poles + houses + ambient NPCs + a scripted ghost-player,
## so racecraft / avoidance / recovery are verified AUTONOMOUSLY (headless metrics + top-down screenshots)
## without the fanera/OSM scene and without a human driving alongside.
##
## Run headless (primary):
##   RACE_BENCH=overtake:30 Godot --headless --path <proj> res://race/ai_bench.tscn 2>&1 | grep "=>"
## Run visual (MCP): play_scene mode:"res://race/ai_bench.tscn" → get_game_screenshot → stop_scene
##
## Scenarios: linefollow | fieldchurn | overtake | defend | poles | npc_overtake | recover | rubberband | default

const OPP_SCENES := [
	"res://race/racer_nexia.tscn",
	"res://race/racer_vaz2107.tscn",
	"res://race/racer_logan.tscn",
]
# Deterministic personas: [pace, aggression, line_bias, bio_phase]  (pace>1 = fast on straights)
const PERSONAS := [
	[1.06, 0.85, 0.7, 0.0],
	[0.94, 0.60, -0.7, 2.1],
	[1.00, 0.75, 0.0, 4.2],
]
const CAR_HALF := 1.0        # m — coarse half-width for overlap/hit tests
const POLE_R := 0.14
const GROUND_LAYER := 1
# Preload bench scripts directly (avoids global class_name cache timing on fresh headless runs).
const GHOST_SCRIPT := preload("res://race/bench_ghost_player.gd")
const NPC_SCRIPT := preload("res://race/bench_npc.gd")
const POLE_CACHE_SCRIPT := preload("res://race/pole_cache.gd")
const GHOST_CRUISE := 0
const GHOST_BLOCK := 1
const GHOST_PARK := 2

var _scenario := "default"
var _run_seconds := 30.0

var _route: RaceRoute
var _sections: Array = []          # [{name,start,end,straight}]
var _pts := PackedVector3Array()
var _opponents: Array = []         # RacerAI
var _npcs: Array = []              # BenchNPC
var _ghost = null
var _poles: Array = []             # Vector3
var _houses: Array = []            # {pos:Vector3, size:Vector2}

# track-build cursor
var _bt_cursor := Vector3.ZERO
var _bt_hd := 0.0
var _bt_arc := 0.0

# metrics
var _t := 0.0
var _log_accum := 0.0
var _opp_stats: Array = []         # per-opp dict
var _pole_pairs := {}              # active overlap "oi_pi" -> true
var _house_pairs := {}
var _npc_pairs := {}
var _ghost_pairs := {}
var _pole_hits := 0
var _building_hits := 0
var _npc_passthroughs := 0
var _npc_contacts := 0
var _player_punts := 0
var _position_swaps := 0
var _pair_ahead := {}              # "i_j" -> bool (i ahead of j)
var _ghost_passes := 0             # opponents crossing from behind→ahead of the ghost player
var _ghost_ahead := {}             # i -> bool (opp i ahead of ghost)
var _finished := false


func _ready() -> void:
	_parse_env()
	_build_track()
	_build_world()
	_build_static()
	_spawn_cast()
	# P8: скармливаем ИЗВЕСТНЫЕ позиции столбов соперникам (danger-map по позиции), если не отключено.
	if OS.get_environment("RACE_BENCH_NOPOLECACHE") == "" and not _poles.is_empty():
		var pc = POLE_CACHE_SCRIPT.new()
		pc.add_points(_poles)
		for opp in _opponents:
			if is_instance_valid(opp) and opp.has_method("set_pole_cache"):
				opp.set_pole_cache(pc)
	print("=>BENCH scenario=%s seconds=%.0f route_len=%.0f opps=%d npcs=%d poles=%d houses=%d ghost=%s" % [
		_scenario, _run_seconds, _route.total_length, _opponents.size(), _npcs.size(),
		_poles.size(), _houses.size(), "yes" if _ghost != null else "no"])


func _parse_env() -> void:
	var raw := OS.get_environment("RACE_BENCH")
	if raw == "":
		raw = "default:30"
	var parts := raw.split(":")
	_scenario = parts[0].strip_edges()
	if parts.size() > 1:
		_run_seconds = maxf(3.0, float(parts[1]))


# ================= TRACK =================

func _seg_straight(nm: String, length: float, step: float = 4.0) -> void:
	var s0 := _bt_arc
	var d := Vector3(cos(_bt_hd), 0.0, sin(_bt_hd))
	var n := maxi(1, int(length / step))
	var actual := length / float(n)
	for _i in range(n):
		_bt_cursor += d * actual
		_bt_arc += actual
		_pts.append(_bt_cursor)
	_sections.append({"name": nm, "start": s0, "end": _bt_arc, "straight": true})


func _seg_arc(nm: String, radius: float, sweep_deg: float, step_deg: float = 6.0) -> void:
	var s0 := _bt_arc
	var steps := maxi(1, int(absf(sweep_deg) / step_deg))
	var dstep := deg_to_rad(sweep_deg) / float(steps)
	var seg_len := radius * absf(dstep)
	for _i in range(steps):
		_bt_hd += dstep
		var d := Vector3(cos(_bt_hd), 0.0, sin(_bt_hd))
		_bt_cursor += d * seg_len
		_bt_arc += seg_len
		_pts.append(_bt_cursor)
	_sections.append({"name": nm, "start": s0, "end": _bt_arc, "straight": false})


func _build_track() -> void:
	_pts = PackedVector3Array()
	_sections = []
	_bt_cursor = Vector3.ZERO
	_bt_hd = 0.0
	_bt_arc = 0.0
	_pts.append(_bt_cursor)
	_seg_straight("straight_start", 220.0)   # top speed, draft, overtake setup
	_seg_arc("sweeper1", 55.0, 80.0)         # fast sweeper
	_seg_straight("pole_alley", 90.0)        # poles both curbs
	_seg_arc("hairpin", 16.0, 150.0)         # tight — apex-overshoot into curb poles
	_seg_straight("straight_mid", 110.0)
	_seg_arc("chicane_a", 22.0, -45.0)       # weave test
	_seg_arc("chicane_b", 22.0, 45.0)
	_seg_straight("house_canyon", 70.0)      # buildings tight to road
	_seg_arc("sweeper2", 45.0, 55.0)
	_seg_straight("npc_lane", 180.0)         # slow NPCs to overtake
	_route = _route_from_points(_pts)


func _route_from_points(pts: PackedVector3Array) -> RaceRoute:
	var route := RaceRoute.new()
	var acc := 0.0
	for i in range(pts.size()):
		var pos: Vector3 = pts[i]
		var dir := Vector3.FORWARD
		if i < pts.size() - 1:
			dir = (pts[i + 1] - pos).normalized()
		elif route.points.size() > 0:
			dir = route.points[-1].direction
		if i > 0:
			acc += pts[i - 1].distance_to(pos)
		route.points.append(RaceRoute.RoutePoint.new(pos, dir, acc))
	if route.points.size() > 0:
		route.total_length = route.points[-1].distance_from_start
	return route


func _pose_at(arc: float) -> Dictionary:
	var pd := _route.get_point_at_distance(clampf(arc, 0.0, _route.total_length))
	var pos: Vector3 = pd.position
	var dir: Vector3 = pd.direction
	var tang := Vector3(dir.x, 0.0, dir.z)
	tang = tang.normalized() if tang.length() > 0.01 else Vector3.FORWARD
	var perp := Vector3(-tang.z, 0.0, tang.x)
	return {"pos": pos, "tang": tang, "perp": perp}


func _find_section(nm: String) -> Dictionary:
	for s in _sections:
		if s.name == nm:
			return s
	return {}


func _section_is_straight_at(arc: float) -> bool:
	for s in _sections:
		if arc >= s.start and arc < s.end:
			return bool(s.straight)
	return true


# ================= WORLD (ground / camera / light) =================

func _build_world() -> void:
	# Ground: big static plane on layer 1, group "Road" (so feelers ignore it via _classify_hit).
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	ground.collision_layer = GROUND_LAYER
	ground.collision_mask = 0
	ground.add_to_group("Road")
	var gcol := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(6000, 2.0, 6000)
	gcol.shape = gbox
	gcol.position = Vector3(0, -1.0, 0)        # top at Y=0
	ground.add_child(gcol)
	var gmesh := MeshInstance3D.new()
	var pmesh := PlaneMesh.new()
	pmesh.size = Vector2(6000, 6000)
	gmesh.mesh = pmesh
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.28, 0.30, 0.28)
	gmesh.material_override = gmat
	ground.add_child(gmesh)
	add_child(ground)

	# Visual ribbon of the racing line (helps top-down screenshots).
	_draw_track_ribbon()

	# Light + environment so screenshots aren't black.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, -40, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.6, 0.7, 0.85)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.environment = e
	add_child(env)

	# Overhead orthographic camera framing the whole track.
	var mn := Vector3(INF, 0, INF)
	var mx := Vector3(-INF, 0, -INF)
	for p in _pts:
		mn.x = minf(mn.x, p.x); mn.z = minf(mn.z, p.z)
		mx.x = maxf(mx.x, p.x); mx.z = maxf(mx.z, p.z)
	var center := (mn + mx) * 0.5
	var extent := maxf(mx.x - mn.x, mx.z - mn.z) + 80.0
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = extent
	cam.position = Vector3(center.x, 500.0, center.z)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.current = true
	add_child(cam)


func _draw_track_ribbon() -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.14)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
	var half := 3.5
	for i in range(_route.points.size()):
		var pt: RaceRoute.RoutePoint = _route.points[i]
		var tang := Vector3(pt.direction.x, 0.0, pt.direction.z).normalized()
		var perp := Vector3(-tang.z, 0.0, tang.x)
		im.surface_add_vertex(pt.position + perp * half + Vector3(0, 0.02, 0))
		im.surface_add_vertex(pt.position - perp * half + Vector3(0, 0.02, 0))
	im.surface_end()
	mi.mesh = im
	add_child(mi)


# ================= STATIC HAZARDS (poles / houses) =================

func _make_pole(pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "LampCol"
	body.collision_layer = 1                   # feeler mask includes bit1 → sensed; car mask includes 1 → contact
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = POLE_R
	cyl.height = 4.0
	col.shape = cyl
	col.position = Vector3(0, 2.0, 0)
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = POLE_R; cm.bottom_radius = POLE_R; cm.height = 4.0
	mi.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.75, 0.2)
	mi.material_override = mat
	mi.position = Vector3(0, 2.0, 0)
	body.add_child(mi)
	body.position = Vector3(pos.x, 0.0, pos.z)
	add_child(body)
	_poles.append(Vector3(pos.x, 0.0, pos.z))


func _make_house(pos: Vector3, size: Vector2) -> void:
	var body := StaticBody3D.new()
	body.name = "House"
	body.collision_layer = 2                    # Buildings
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, 8.0, size.y)
	col.shape = box
	col.position = Vector3(0, 4.0, 0)
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, 8.0, size.y)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.4, 0.35)
	mi.material_override = mat
	mi.position = Vector3(0, 4.0, 0)
	body.add_child(mi)
	body.position = Vector3(pos.x, 0.0, pos.z)
	add_child(body)
	_houses.append({"pos": Vector3(pos.x, 0.0, pos.z), "size": size})


func _poles_along(nm: String, spacing: float, edge: float) -> void:
	var sec := _find_section(nm)
	if sec.is_empty():
		return
	var a: float = sec.start
	while a <= sec.end:
		var pose := _pose_at(a)
		_make_pole(pose.pos + pose.perp * edge)
		_make_pole(pose.pos - pose.perp * edge)
		a += spacing


func _houses_along(nm: String, spacing: float, edge: float) -> void:
	var sec := _find_section(nm)
	if sec.is_empty():
		return
	var a: float = sec.start
	while a <= sec.end:
		var pose := _pose_at(a)
		_make_house(pose.pos + pose.perp * edge, Vector2(6, 6))
		_make_house(pose.pos - pose.perp * edge, Vector2(6, 6))
		a += spacing


func _build_static() -> void:
	match _scenario:
		"poles", "default":
			_poles_along("pole_alley", 12.0, 3.1)
			_poles_along("hairpin", 8.0, 3.0)
			_houses_along("house_canyon", 20.0, 5.5)
		"recover":
			# a wall straight on the racing line to crash into
			var pose := _pose_at(60.0)
			_make_house(pose.pos, Vector2(8, 3))
		"curb_poles":
			# ОДИН ряд столбов вдоль ПРЯМОЙ (реальный бордюр, 2.2 м) — чистый тест threading, 1 машина, без свалки
			var cs := _find_section("pole_alley")
			if not cs.is_empty():
				var ca: float = cs.start
				while ca <= cs.end:
					_make_pole(_pose_at(ca).pos + _pose_at(ca).perp * 2.2)
					ca += 9.0
		"hairpin_poles":
			# ОДНА машина через крутой поворot со столбами обеих сторон — изолируем «занос в повороте от инъекции»
			_poles_along("hairpin", 8.0, 3.0)
		"corner_pole":
			# Phase 0 репро «снос в повороте → столб»: столбы у самого края поворота (2.4м), 1 машина.
			# Понесёт наружу → цепляет внешние. corner_static_hits — метрика, которую роняем в Фазе 1.
			_poles_along("hairpin", 5.0, 2.4)
		"npc_overtake", "overtake", "defend", "rubberband", "fieldchurn", "linefollow":
			pass


# ================= CAST (opponents / npcs / ghost) =================

func _spawn_opponent(idx: int, arc: float, lane: float) -> void:
	var scene: PackedScene = load(OPP_SCENES[idx % OPP_SCENES.size()])
	var opp = scene.instantiate()
	add_child(opp)                       # triggers _ready (randomizes persona)
	opp.lod_disabled = true              # bench: flat, no streaming → keep physics
	opp.set_race_route(_route)           # builds K1999 line (falls back to RL_DEFAULT_HALF, no OSMTerrain)
	var p: Array = PERSONAS[idx % PERSONAS.size()]
	opp.set_persona(p[0], p[1], p[2], p[3])   # deterministic override (pace, aggr, bias, bio_phase)
	opp.racer_name = "OPP%d" % idx
	var pose := _pose_at(arc)
	opp.global_position = pose.pos + pose.perp * lane + Vector3(0, 0.6, 0)
	# Opponents (VehicleBody3D) are spawned in race_manager as grid_basis * Basis(UP, PI):
	# they drive with +Z toward the route, so -Z (look_at) faces backward. Match that 180° flip.
	opp.look_at(opp.global_position + pose.tang, Vector3.UP)
	opp.global_transform.basis = opp.global_transform.basis * Basis(Vector3.UP, PI)
	if opp.has_method("enable_collision_metric"):
		opp.enable_collision_metric()   # Phase 0: реальный счётчик столкновений
	opp.start_racing()
	_opponents.append(opp)
	_opp_stats.append({
		"prev_steer_sign": 0, "weave_flips": 0, "under_ticks": 0, "moving_ticks": 0,
		"total_ticks": 0, "max_prog": 0.0, "recover_ticks": 0,
		"was_recovering": false, "reverse_events": 0,
		"max_yaw": 0.0, "spin_ticks": 0,   # P7: спин-метрика (|yaw|>2.5 рад/с = крутит)
	})


func _spawn_npc(arc: float, lane: float, speed_ms: float) -> void:
	var npc = NPC_SCRIPT.new()
	add_child(npc)
	var pose := _pose_at(arc)
	npc.setup(pose.pos + pose.perp * lane, pose.tang, speed_ms)
	_npcs.append(npc)


func _spawn_ghost(arc: float, speed_frac: float, lane: float, mode: int) -> void:
	_ghost = GHOST_SCRIPT.new()
	add_child(_ghost)
	_ghost.setup(_route, speed_frac, lane, mode, arc)


func _spawn_cast() -> void:
	match _scenario:
		"linefollow":
			_spawn_opponent(0, 10.0, 0.0)
		"fieldchurn", "default":
			_spawn_opponent(0, 6.0, 1.2)
			_spawn_opponent(1, 16.0, -1.2)
			_spawn_opponent(2, 26.0, 0.0)
		"overtake":
			_spawn_opponent(0, 8.0, 1.0)
			_spawn_opponent(1, 18.0, -1.0)
			_spawn_opponent(2, 28.0, 0.0)
			_spawn_ghost(60.0, 0.5, 1.4, GHOST_CRUISE)   # slow, ahead, hugs right lane → rivals pass left (open side)
		"defend":
			_spawn_opponent(0, 45.0, 0.0)
			_spawn_ghost(8.0, 1.25, 0.0, GHOST_CRUISE)   # fast, behind → rival defends
		"rubberband":
			var frac := 1.0
			var fenv := OS.get_environment("RACE_BENCH_GHOST")
			if fenv != "":
				frac = maxf(0.2, float(fenv))
			_spawn_opponent(0, 20.0, 1.0)
			_spawn_opponent(1, 30.0, -1.0)
			_spawn_ghost(70.0, frac, 0.0, GHOST_CRUISE)
		"poles":
			var base: float = maxf(4.0, _find_section("pole_alley").start - 60.0)
			_spawn_opponent(0, base + 0.0, 1.0)
			_spawn_opponent(1, base + 10.0, -1.0)
			_spawn_opponent(2, base + 20.0, 0.0)
		"npc_overtake":
			var nl := _find_section("npc_lane")
			var base2: float = maxf(4.0, nl.start - 40.0)
			_spawn_opponent(0, base2 + 0.0, 0.0)
			_spawn_opponent(1, base2 + 10.0, 1.0)
			_spawn_opponent(2, base2 + 20.0, -1.0)
			var a: float = nl.start + 20.0
			var a_end: float = nl.end - 10.0
			while a < a_end:
				_spawn_npc(a, 1.5, 7.0)      # right lane, ~25 km/h
				a += 45.0
		"recover":
			_spawn_opponent(0, 45.0, 0.0)    # 15 m before the wall at arc 60
		"curb_poles":
			var cb: float = maxf(4.0, _find_section("pole_alley").start - 30.0)
			_spawn_opponent(0, cb, 0.6)      # 1 машина, чуть смещена к столбам → должна держать линию, не чиркать
		"hairpin_poles":
			var hb: float = maxf(4.0, _find_section("hairpin").start - 25.0)
			_spawn_opponent(0, hb, 0.0)      # 1 машина в поворот со столбами — изоляция инъекции
		"corner_pole":
			var cpb: float = maxf(4.0, _find_section("hairpin").start - 25.0)
			_spawn_opponent(0, cpb, 0.0)     # Phase 0: 1 машина в поворот со столбами у края


# ================= METRICS =================

func _physics_process(delta: float) -> void:
	if _finished:
		return
	_t += delta
	_update_metrics()
	_log_accum += delta
	if _log_accum >= 1.0:
		_log_accum -= 1.0
		_print_tick()
	if _t >= _run_seconds:
		_finish()


func _update_metrics() -> void:
	# per-opponent: under_map, moving, weave (on straights), progress
	for i in range(_opponents.size()):
		var opp = _opponents[i]
		if not is_instance_valid(opp):
			continue
		var st: Dictionary = _opp_stats[i]
		st.total_ticks += 1
		if opp.global_position.y < -0.3:
			st.under_ticks += 1
		var spd: float = opp.linear_velocity.length()
		if spd > 1.0:
			st.moving_ticks += 1
		var prog: float = opp.get_race_progress()
		st.max_prog = maxf(st.max_prog, prog)
		# weave: sign flips of steering while on a straight section
		if _section_is_straight_at(prog):
			var s: float = opp.steering_input
			var sign_now: int = (1 if s > 0.05 else (-1 if s < -0.05 else 0))
			if sign_now != 0 and st.prev_steer_sign != 0 and sign_now != st.prev_steer_sign:
				st.weave_flips += 1
			if sign_now != 0:
				st.prev_steer_sign = sign_now
		# recovering state + reverse-event transitions (for false-reverse measurement)
		var recovering: bool = int(opp.ai_state) == 2   # AIState.RECOVERING
		if recovering:
			st.recover_ticks += 1
		if recovering and not bool(st.was_recovering):
			st.reverse_events += 1
		st.was_recovering = recovering
		# P7 спин-метрика: пик и длительность высокой угловой скорости (крутит после удара/на выходе)
		var yaw_rate: float = absf(opp.angular_velocity.y)
		st.max_yaw = maxf(st.max_yaw, yaw_rate)
		if yaw_rate > 2.5:
			st.spin_ticks += 1

	_update_events()
	_update_swaps()
	_update_passes()


func _update_events() -> void:
	for i in range(_opponents.size()):
		var opp = _opponents[i]
		if not is_instance_valid(opp):
			continue
		var op: Vector3 = opp.global_position
		# poles
		for pi in range(_poles.size()):
			var key := "%d_%d" % [i, pi]
			var d := Vector2(op.x - _poles[pi].x, op.z - _poles[pi].z).length()
			var over := d < (CAR_HALF + POLE_R)
			if over and not _pole_pairs.has(key):
				_pole_pairs[key] = true
				_pole_hits += 1
			elif not over and _pole_pairs.has(key):
				_pole_pairs.erase(key)
		# houses
		for hi in range(_houses.size()):
			var h: Dictionary = _houses[hi]
			var hp: Vector3 = h.pos
			var hs: Vector2 = h.size
			var key2 := "%d_%d" % [i, hi]
			var over2 := absf(op.x - hp.x) < (hs.x * 0.5 + CAR_HALF) and absf(op.z - hp.z) < (hs.y * 0.5 + CAR_HALF)
			if over2 and not _house_pairs.has(key2):
				_house_pairs[key2] = true
				_building_hits += 1
			elif not over2 and _house_pairs.has(key2):
				_house_pairs.erase(key2)
		# npcs (overlap w/o physical contact possible = passthrough in P0–P5)
		for ni in range(_npcs.size()):
			var npc = _npcs[ni]
			if not is_instance_valid(npc):
				continue
			var key3 := "%d_%d" % [i, ni]
			var dn := Vector2(op.x - npc.global_position.x, op.z - npc.global_position.z).length()
			var over3 := dn < 3.0
			if over3 and not _npc_pairs.has(key3):
				_npc_pairs[key3] = true
				_npc_passthroughs += 1
			elif not over3 and _npc_pairs.has(key3):
				_npc_pairs.erase(key3)
		# ghost player punts
		if _ghost != null and is_instance_valid(_ghost):
			var dg := Vector2(op.x - _ghost.global_position.x, op.z - _ghost.global_position.z).length()
			var over4 := dg < (CAR_HALF + 1.2)
			if over4 and not _ghost_pairs.has(i):
				_ghost_pairs[i] = true
				_player_punts += 1
			elif not over4 and _ghost_pairs.has(i):
				_ghost_pairs.erase(i)


func _update_swaps() -> void:
	for i in range(_opponents.size()):
		for j in range(i + 1, _opponents.size()):
			if not is_instance_valid(_opponents[i]) or not is_instance_valid(_opponents[j]):
				continue
			var key := "%d_%d" % [i, j]
			var ahead: bool = _opponents[i].get_race_progress() > _opponents[j].get_race_progress()
			if _pair_ahead.has(key) and _pair_ahead[key] != ahead:
				_position_swaps += 1
			_pair_ahead[key] = ahead


func _update_passes() -> void:
	if _ghost == null or not is_instance_valid(_ghost):
		return
	var ga: float = _ghost._arc
	for i in range(_opponents.size()):
		if not is_instance_valid(_opponents[i]):
			continue
		var ahead: bool = _opponents[i].get_race_progress() > ga
		if _ghost_ahead.has(i) and not bool(_ghost_ahead[i]) and ahead:
			_ghost_passes += 1
		_ghost_ahead[i] = ahead


func _print_tick() -> void:
	var parts: Array = []
	for i in range(_opponents.size()):
		var st: Dictionary = _opp_stats[i]
		parts.append("OPP%d[prog=%.0f weave=%d under=%d]" % [i, st.max_prog, st.weave_flips, st.under_ticks])
	print("=>T%.0f %s hits[pole=%d bld=%d npcPT=%d punt=%d] swaps=%d" % [
		_t, " ".join(PackedStringArray(parts)), _pole_hits, _building_hits,
		_npc_passthroughs, _player_punts, _position_swaps])
	if OS.get_environment("RACE_BENCH_DBG") != "" and _opponents.size() > 0 and is_instance_valid(_opponents[0]):
		var o = _opponents[0]
		var fwd: Vector3 = -o.global_transform.basis.z
		var vel: Vector3 = o.linear_velocity
		print("=>DBG pos=(%.1f,%.1f) y=%.2f spd=%.1f fwd=(%.2f,%.2f) thr=%.2f brk=%.2f str=%.2f line=%d state=%d" % [
			o.global_position.x, o.global_position.z, o.global_position.y, vel.length(),
			fwd.x, fwd.z, o.throttle_input, o.brake_input, o.steering_input, o._line.size(), int(o.ai_state)])
		if o.has_method("get_perception_debug"):
			var md: int = o.get_mode() if o.has_method("get_mode") else -1
			print("=>PERC mode=%d " % md, o.get_perception_debug())


func _finish() -> void:
	_finished = true
	print("=>SUMMARY scenario=%s dur=%.0f" % [_scenario, _t])
	for i in range(_opponents.size()):
		var st: Dictionary = _opp_stats[i]
		var tot: float = maxf(1.0, float(st.total_ticks))
		print("=>OPP%d prog=%.0f/%.0f onroad_moving=%.0f%% under_map=%.0f%% weave=%d recover_ticks=%d reverse_events=%d max_yaw=%.1f spin_ticks=%d" % [
			i, st.max_prog, _route.total_length, 100.0 * st.moving_ticks / tot,
			100.0 * st.under_ticks / tot, st.weave_flips, st.recover_ticks, st.reverse_events,
			st.max_yaw, st.spin_ticks])
		var opp = _opponents[i]
		if is_instance_valid(opp) and opp.has_method("get_collision_metric"):
			var cm: Dictionary = opp.get_collision_metric()
			print("=>COLL%d static=%d corner_static=%d dynamic=%d static_curvs=%s" % [
				i, cm.static, cm.corner_static, cm.dynamic, str(cm.get("static_curvs", []))])
	print("=>EVENTS pole_hits=%d building_hits=%d npc_passthroughs=%d npc_contacts=%d player_punts=%d position_swaps=%d ghost_passes=%d" % [
		_pole_hits, _building_hits, _npc_passthroughs, _npc_contacts, _player_punts, _position_swaps, _ghost_passes])
	print("=>DONE")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
