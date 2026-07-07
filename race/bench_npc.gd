extends RigidBody3D
class_name BenchNPC

## BENCH-only ambient-traffic stand-in for the AI bench (docs/RACER_AI_IMPLEMENTATION_PLAN.md §2.5).
## Matches what the race AI must sense/collide with in production (Reality Check §C):
##  • collision_layer = 4 (NPCTraffic), group "traffic"
##  • real physics body → exposes linear_velocity + get_speed_kmh()
## Moves at a fixed slow lane speed along a straight direction (velocity forced each tick).
## Not chunk-owned, not waypoint-driven — just a controllable slow obstacle for overtaking tests.

var lane_dir: Vector3 = Vector3.FORWARD
var lane_speed_ms: float = 7.0          # ~25 km/h
var ground_y: float = 0.5

func _ready() -> void:
	collision_layer = 4                  # NPCTraffic (bit 2)
	collision_mask = 1                   # ground only
	gravity_scale = 0.0
	freeze = false
	add_to_group("traffic")
	if get_node_or_null("Col") == null:
		var col := CollisionShape3D.new()
		col.name = "Col"
		var box := BoxShape3D.new()
		box.size = Vector3(1.7, 1.3, 4.2)
		col.shape = box
		col.position = Vector3(0.0, 0.65, 0.0)
		add_child(col)
	if get_node_or_null("Mesh") == null:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		var bm := BoxMesh.new()
		bm.size = Vector3(1.7, 1.3, 4.2)
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.55, 0.55, 0.6)   # grey = ambient traffic
		mi.material_override = mat
		mi.position = Vector3(0.0, 0.65, 0.0)
		add_child(mi)

func setup(pos: Vector3, dir: Vector3, speed_ms: float) -> void:
	lane_dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	lane_speed_ms = speed_ms
	global_position = Vector3(pos.x, ground_y, pos.z)
	look_at(global_position + lane_dir, Vector3.UP)  # -Z faces travel dir (Godot convention)

func _physics_process(_delta: float) -> void:
	# Force a constant lane velocity (one-sided: traffic does not react to racers — as in production).
	linear_velocity = lane_dir * lane_speed_ms
	angular_velocity = Vector3.ZERO
	# Pin to the ground plane (gravity off).
	global_position.y = ground_y

func get_speed_kmh() -> float:
	return lane_speed_ms * 3.6
