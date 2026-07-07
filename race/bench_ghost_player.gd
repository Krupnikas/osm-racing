extends RigidBody3D
class_name BenchGhostPlayer

## BENCH-only scripted stand-in for the human player (docs/RACER_AI_IMPLEMENTATION_PLAN.md §2.6).
## Replaces "the user drives alongside": a kinematic follower of the race route whose pace/lane/mode I set,
## so overtake / defend / rubber-band scenarios are fully repeatable without a human.
## Mimics the real player's interface so rivals treat it identically:
##  • groups "player" + "car", collision_layer = 1 (Player) → seen via group AND feeler mask bit 1
##  • real body → exposes linear_velocity (rubber-band / CPA reads)

enum Mode { CRUISE, BLOCK, PARK }

var race_route: RaceRoute
var speed_frac: float = 0.6              # fraction of a nominal race pace
var base_speed_ms: float = 22.0         # nominal pace the fraction scales
var lane_offset: float = 0.0            # constant lateral offset (perp basis; +/- to hold a side)
var mode: int = Mode.CRUISE
var ground_y: float = 0.5

var _arc: float = 0.0
var _park_arc: float = 0.0              # where to stop in PARK mode
var _prev_pos: Vector3 = Vector3.ZERO

func _ready() -> void:
	collision_layer = 1                  # Player (bit 0)
	collision_mask = 0                   # kinematic — we drive by position, don't need to be pushed
	gravity_scale = 0.0
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	add_to_group("player")
	add_to_group("car")
	if get_node_or_null("Col") == null:
		var col := CollisionShape3D.new()
		col.name = "Col"
		var box := BoxShape3D.new()
		box.size = Vector3(1.8, 1.3, 4.4)
		col.shape = box
		col.position = Vector3(0.0, 0.65, 0.0)
		add_child(col)
	if get_node_or_null("Mesh") == null:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		var bm := BoxMesh.new()
		bm.size = Vector3(1.8, 1.3, 4.4)
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.05, 0.05, 0.05)   # black = the player
		mi.material_override = mat
		mi.position = Vector3(0.0, 0.65, 0.0)
		add_child(mi)

func setup(route: RaceRoute, p_speed_frac: float, p_lane: float, p_mode: int, start_arc: float = 0.0) -> void:
	race_route = route
	speed_frac = p_speed_frac
	lane_offset = p_lane
	mode = p_mode
	_arc = start_arc
	_park_arc = start_arc
	_place_at_arc(_arc)
	_prev_pos = global_position

func _place_at_arc(arc: float) -> void:
	if race_route == null or race_route.points.size() < 2:
		return
	var pd := race_route.get_point_at_distance(arc)
	var pos: Vector3 = pd.position
	var dir: Vector3 = pd.direction
	var tang := Vector3(dir.x, 0.0, dir.z)
	tang = tang.normalized() if tang.length() > 0.01 else Vector3.FORWARD
	var perp := Vector3(-tang.z, 0.0, tang.x)   # same basis as RacerAI (+ = one consistent side)
	global_position = Vector3(pos.x, ground_y, pos.z) + perp * lane_offset
	look_at(global_position + tang, Vector3.UP)

func _physics_process(delta: float) -> void:
	if race_route == null:
		return
	var target := base_speed_ms * speed_frac
	if mode == Mode.PARK and _arc >= _park_arc:
		target = 0.0
	_arc = minf(race_route.total_length, _arc + target * delta)
	_place_at_arc(_arc)
	# Derived velocity for the AI's reads (rivals read node.linear_velocity).
	linear_velocity = (global_position - _prev_pos) / maxf(delta, 0.0001)
	_prev_pos = global_position

func get_speed_kmh() -> float:
	return linear_velocity.length() * 3.6
