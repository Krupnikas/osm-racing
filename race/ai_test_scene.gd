extends Node3D

## Isolated AI steering test harness (v1.1).
##
## A flat, OSM-free scene used to tune/measure racing-opponent route following
## without loading the procedural city. Builds a deterministic diagnostic route
## (straight / gentle / medium / S-bend / sharp / finish), spawns ONE RacerAI,
## starts it driving, draws a debug overlay (centerline + ±corridor + target),
## and exposes MCP-callable methods:
##   get_summary()        -> the AI's get_debug_summary() (global + per-section)
##   restart()            -> reload the scene for a fresh pass
##   set_camera("top"|"chase")
##   set_overlay(on: bool)
##
## NOTE: test-only. Not part of any production scene.

const RACER_SCENE := preload("res://race/racer_nexia.tscn")

# Fixed, deterministic AI params (override RacerAI._ready randomisation).
const TEST_SKILL := 0.92
const TEST_AGGRESSION := 0.7
const TEST_TARGET_SPEED := 80.0

# Stress test: spawn this many metres to the right of the centerline so the
# controller has to converge back. The bang-bang gain shows up as oscillation
# here. 0 = spawn on the line. Set via RaceState.test_spawn_offset if present.
const SPAWN_LATERAL_OFFSET := 0.0

# Режим маршрута: "synthetic" = гладкая процедурная трасса (для тюнинга),
# "fanera" = РЕАЛЬНАЯ геометрия трека fanera_sprint (24 сырых waypoint игрока) —
# для воспроизведения синусоиды на резких изломах вне города/столбов.
const ROUTE_MODE := "fanera"

# Эксперимент: стены по краям маршрута на слое Buildings (2) — то, что видит луч объезда ИИ
# (маска 2|8). Проверяем, вызывает ли объезд синусоиду на идеально гладкой геометрии.
const ADD_EDGE_OBSTACLES := true
const WALL_OFFSET := 6.0   # м от осевой до стены — как край дороги/дома в городе; в этом диапазоне
                           # боковые лучи объезда (±16.7°, достают ~20м) начинают цеплять стены при рысканье

# Реальные точки трека fanera_sprint (lat, lon) — race_tracks.gd::_create_fanera_sprint.route_points
const FANERA_ORIGIN_LAT := 59.149827
const FANERA_ORIGIN_LON := 37.948859
const FANERA_LATLON := [
	Vector2(59.149827, 37.948859), Vector2(59.149307, 37.948601), Vector2(59.148223, 37.947829),
	Vector2(59.147065, 37.94704), Vector2(59.146691, 37.946772), Vector2(59.146212, 37.946402),
	Vector2(59.145588, 37.945919), Vector2(59.144677, 37.945254), Vector2(59.144251, 37.944948),
	Vector2(59.144204, 37.944905), Vector2(59.144234, 37.94468), Vector2(59.144564, 37.942051),
	Vector2(59.145029, 37.938409), Vector2(59.145043, 37.938243), Vector2(59.144952, 37.938189),
	Vector2(59.14397, 37.937706), Vector2(59.143021, 37.937234), Vector2(59.142036, 37.936757),
	Vector2(59.141978, 37.936741), Vector2(59.141554, 37.939927), Vector2(59.141153, 37.942953),
	Vector2(59.141131, 37.943237), Vector2(59.141166, 37.943414), Vector2(59.141354, 37.943516),
]

var _car  # RacerAI (untyped so custom debug methods resolve at runtime)
var _route  # RaceRoute
var _sections: Array = []      # [{name, start_m, end_m}]
var _route_pts: Array = []     # Array[Vector3] raw centerline
var _bounds_center := Vector3.ZERO
var _bounds_size := 200.0

var _top_cam: Camera3D
var _chase_cam: Camera3D
var _route_debug: MeshInstance3D
var _overlay_mat: StandardMaterial3D
var _overlay_on := true
var _started := false


func _ready() -> void:
	seed(12345)
	_build_environment()
	_build_ground()

	var built := _generate_route()
	_route = built["route"]
	_sections = built["sections"]
	_route_pts = built["points"]
	_compute_bounds()

	_build_cameras()
	_build_overlay()
	_build_obstacles()

	_spawn_car()

	# Let the car settle on the ground, then start driving.
	await _start_after_settle()


func _process(delta: float) -> void:
	# Chase cam follow (top cam is static).
	if _chase_cam and _car and is_instance_valid(_car):
		var fwd: Vector3 = -_car.global_transform.basis.z
		var desired: Vector3 = _car.global_position - fwd * 8.0 + Vector3(0, 4.0, 0)
		_chase_cam.global_position = _chase_cam.global_position.lerp(desired, clampf(8.0 * delta, 0.0, 1.0))
		_chase_cam.look_at(_car.global_position + Vector3(0, 1.0, 0))
	if _overlay_on:
		_draw_overlay()


# ===== MCP-callable API =====

func get_summary() -> Dictionary:
	if _car and is_instance_valid(_car) and _car.has_method("get_debug_summary"):
		return _car.get_debug_summary()
	return {}


func restart() -> void:
	get_tree().reload_current_scene()


func set_camera(mode: String) -> void:
	if mode == "chase" and _chase_cam:
		_chase_cam.current = true
	elif _top_cam:
		_top_cam.current = true


func set_overlay(on: bool) -> void:
	_overlay_on = on
	if _route_debug:
		_route_debug.visible = on


# ===== Scene construction =====

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.shadow_enabled = true
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.72)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.ambient_light_energy = 1.0
	we.environment = env
	add_child(we)


func _build_ground() -> void:
	# Large flat box collider (top face at y=0), layer 1 so the car (mask 131) rests on it.
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("Grass")
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	shape.shape = box
	shape.position = Vector3(0, -1, 0)  # top face at y=0
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000, 4000)
	mesh.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.32, 0.38, 0.3)
	mesh.material_override = gmat
	body.add_child(mesh)


func _build_cameras() -> void:
	# Static top-down (orthographic) over the whole route — best for seeing the line.
	_top_cam = Camera3D.new()
	_top_cam.name = "TopDownCamera"
	_top_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_top_cam.size = _bounds_size * 1.2
	_top_cam.far = 2000.0
	_top_cam.global_position = _bounds_center + Vector3(0, 400, 0)
	_top_cam.rotation_degrees = Vector3(-90, 0, 0)
	_top_cam.current = true
	add_child(_top_cam)

	_chase_cam = Camera3D.new()
	_chase_cam.name = "ChaseCamera"
	_chase_cam.fov = 70.0
	_chase_cam.global_position = _route_pts[0] + Vector3(0, 4, 8)
	add_child(_chase_cam)


func _build_overlay() -> void:
	_overlay_mat = StandardMaterial3D.new()
	_overlay_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_mat.vertex_color_use_as_albedo = true
	_overlay_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_route_debug = MeshInstance3D.new()
	_route_debug.name = "RouteDebug"
	_route_debug.mesh = ImmediateMesh.new()
	add_child(_route_debug)
	_draw_overlay()


func _draw_overlay() -> void:
	if _route_debug == null or _route == null:
		return
	var im: ImmediateMesh = _route_debug.mesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES, _overlay_mat)

	var y := 0.25
	var white := Color(0.95, 0.95, 0.95)
	var amber := Color(0.95, 0.65, 0.15)
	var corridor: float = RacerAI.CORRIDOR_WIDTH

	var pts: Array = _route.points
	for i in range(pts.size() - 1):
		var a: Vector3 = pts[i].position
		var b: Vector3 = pts[i + 1].position
		var da: Vector3 = pts[i].direction
		var db: Vector3 = pts[i + 1].direction
		var la: Vector3 = da.rotated(Vector3.UP, PI / 2.0) * corridor
		var lb: Vector3 = db.rotated(Vector3.UP, PI / 2.0) * corridor
		# centerline
		_line(im, white, a + Vector3(0, y, 0), b + Vector3(0, y, 0))
		# corridor edges (±)
		_line(im, amber, a + la + Vector3(0, y, 0), b + lb + Vector3(0, y, 0))
		_line(im, amber, a - la + Vector3(0, y, 0), b - lb + Vector3(0, y, 0))

	# Current AI target / lookahead point (red cross).
	if _car and is_instance_valid(_car):
		var tp: Vector3 = _car.debug_target_point
		if tp != Vector3.ZERO:
			var red := Color(0.95, 0.15, 0.1)
			var c := tp + Vector3(0, y + 0.1, 0)
			_line(im, red, c + Vector3(-2, 0, 0), c + Vector3(2, 0, 0))
			_line(im, red, c + Vector3(0, 0, -2), c + Vector3(0, 0, 2))

	im.surface_end()


func _line(im: ImmediateMesh, col: Color, a: Vector3, b: Vector3) -> void:
	im.surface_set_color(col)
	im.surface_add_vertex(a)
	im.surface_set_color(col)
	im.surface_add_vertex(b)


# ===== Route generation =====

func _generate_route() -> Dictionary:
	if ROUTE_MODE == "fanera":
		return _generate_fanera_route()

	var pts: Array[Vector3] = []
	var pos := Vector3.ZERO
	var heading := Vector3(1, 0, 0)  # start heading +X
	var ds := 10.0
	pts.append(pos)

	var section_defs := [
		{"name": "straight_1", "len": 120.0, "turn": 0.0},
		{"name": "gentle", "len": 60.0, "turn": 15.0},
		{"name": "straight_2", "len": 50.0, "turn": 0.0},
		{"name": "medium", "len": 50.0, "turn": -45.0},
		{"name": "s_bend", "len": 80.0, "turn": 0.0, "sbend": true},
		{"name": "sharp", "len": 40.0, "turn": -80.0},
		{"name": "finish", "len": 60.0, "turn": 0.0},
	]

	var idx_sections: Array = []
	for sec in section_defs:
		var start_idx := pts.size() - 1  # shared boundary point
		var seclen: float = sec["len"]
		var steps: int = int(round(seclen / ds))
		if bool(sec.get("sbend", false)):
			var half: int = steps / 2
			for i in range(steps):
				var t_deg := 0.0
				if i < half:
					t_deg = 30.0 / float(maxi(1, half))
				else:
					t_deg = -30.0 / float(maxi(1, steps - half))
				heading = heading.rotated(Vector3.UP, deg_to_rad(t_deg))
				pos += heading * ds
				pts.append(pos)
		else:
			var turn_step: float = float(sec["turn"]) / float(maxi(1, steps))
			for i in range(steps):
				heading = heading.rotated(Vector3.UP, deg_to_rad(turn_step))
				pos += heading * ds
				pts.append(pos)
		idx_sections.append({"name": str(sec["name"]), "start_idx": start_idx, "end_idx": pts.size() - 1})

	# Build the RaceRoute via the existing public builder (identity converter).
	var pts2d: Array = []
	for p in pts:
		pts2d.append(Vector2(p.x, p.z))
	var conv := func(a, b): return Vector3(a, 0.0, b)
	var route = RaceRoute.build_from_track_waypoints(pts2d, conv)

	# Map section point indices -> route arc distances for telemetry binning.
	var sec_out: Array = []
	for s in idx_sections:
		var si: int = s["start_idx"]
		var ei: int = s["end_idx"]
		var sm: float = route.points[si].distance_from_start
		var em: float = route.points[ei].distance_from_start
		sec_out.append({"name": s["name"], "start_m": sm, "end_m": em})

	print("AITestScene: route len=%.1fm, %d points, %d sections" % [route.total_length, route.points.size(), sec_out.size()])
	return {"route": route, "sections": sec_out, "points": pts}


func _generate_fanera_route() -> Dictionary:
	# Тот же конвертер lat/lon→local, что и в игре (эквиректангулярный, север=−Z).
	var lon_scale := cos(deg_to_rad(FANERA_ORIGIN_LAT)) * 111000.0
	var conv := func(lat, lon): return Vector3((lon - FANERA_ORIGIN_LON) * lon_scale, 0.0, -(lat - FANERA_ORIGIN_LAT) * 111000.0)
	var route = RaceRoute.build_from_track_waypoints(FANERA_LATLON, conv)
	var pts: Array = []
	for rp in route.points:
		pts.append(rp.position)
	# Грубые секции по 300 м (для сводки; на репро главное — global-блок).
	var sec_out: Array = []
	var d := 0.0
	while d < route.total_length:
		sec_out.append({"name": "s%04d" % int(d), "start_m": d, "end_m": minf(d + 300.0, route.total_length)})
		d += 300.0
	print("AITestScene[FANERA]: len=%.1fm, %d points" % [route.total_length, route.points.size()])
	return {"route": route, "sections": sec_out, "points": pts}


func _build_obstacles() -> void:
	if not ADD_EDGE_OBSTACLES or _route == null:
		return
	var pts: Array = _route.points
	var count := 0
	for i in range(pts.size() - 1):
		var a: Vector3 = pts[i].position
		var b: Vector3 = pts[i + 1].position
		var seg: Vector3 = b - a
		var seg_len: float = seg.length()
		if seg_len < 0.5:
			continue
		var dir: Vector3 = seg / seg_len
		var perp: Vector3 = Vector3(-dir.z, 0.0, dir.x)  # влево/вправо в плоскости XZ
		var mid: Vector3 = (a + b) * 0.5
		for side in [1.0, -1.0]:
			_make_wall(mid + perp * (side * WALL_OFFSET), dir, seg_len)
			count += 1
	print("AITestScene: built %d edge walls @ ±%.1fm (layer 2)" % [count, WALL_OFFSET])


func _make_wall(center: Vector3, dir: Vector3, length: float) -> void:
	var body := StaticBody3D.new()
	# Слой 8 (NPCTraffic): луч ИИ (маска 2|8) его ВИДИТ, но кузов машины (маска 131) с ним НЕ
	# сталкивается физически → чистый тест «только сенсор», без краша об стену.
	body.collision_layer = 8
	body.collision_mask = 0
	add_child(body)
	body.global_position = center + Vector3(0, 1.5, 0)
	body.look_at(body.global_position - dir, Vector3.UP)  # локальный +Z вдоль dir

	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 3.0, length)
	var shape := CollisionShape3D.new()
	shape.shape = box
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mesh.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.32, 0.26)
	mesh.material_override = m
	body.add_child(mesh)


func _compute_bounds() -> void:
	var minp: Vector3 = _route_pts[0]
	var maxp: Vector3 = _route_pts[0]
	for p in _route_pts:
		minp = Vector3(minf(minp.x, p.x), 0, minf(minp.z, p.z))
		maxp = Vector3(maxf(maxp.x, p.x), 0, maxf(maxp.z, p.z))
	_bounds_center = (minp + maxp) * 0.5
	_bounds_size = maxf(maxp.x - minp.x, maxp.z - minp.z) + 40.0


# ===== Car spawn / start =====

func _spawn_car() -> void:
	_car = RACER_SCENE.instantiate()
	add_child(_car)

	# Deterministic params (override RacerAI._ready randomisation, which already ran).
	_car.skill_level = TEST_SKILL
	_car.aggression = TEST_AGGRESSION
	_car.target_speed = TEST_TARGET_SPEED

	# Orient to match production opponent spawn (race_manager.gd:493): the racer
	# VehicleBody3D drives +Z-forward, so looking_at (which aims -Z) must be flipped 180°.
	var dir: Vector3 = _route.points[0].direction
	# Offset to the right of the centerline (perpendicular in XZ) for convergence stress.
	var right: Vector3 = dir.rotated(Vector3.UP, -PI / 2.0).normalized()
	var start_pos: Vector3 = _route.points[0].position + Vector3(0, 1.0, 0) + right * SPAWN_LATERAL_OFFSET
	var basis := Basis.looking_at(dir, Vector3.UP) * Basis(Vector3.UP, PI)
	_car.global_transform = Transform3D(basis, start_pos)


func _start_after_settle() -> void:
	# Wait for physics to seat the car on the ground.
	for i in range(20):
		await get_tree().physics_frame
	if not (_car and is_instance_valid(_car)):
		return
	_car.set_debug_sections(_sections)
	_car.ai_debug = true
	_car.clear_debug_samples()
	_car.set_race_route(_route)
	_car.start_racing()
	_started = true
	print("AITestScene: AI started — driving %.1fm route" % _route.total_length)
