extends Node
class_name TramManager

## Менеджер трамваев — спавнит и управляет трамваями на рельсах

const MAX_TRAMS := 4
const SPAWN_DISTANCE := 300.0
const DESPAWN_DISTANCE := 400.0
const SPAWN_COOLDOWN_TIME := 2.0
const CHUNK_SIZE := 300.0

var road_network: Node  # RoadNetwork (shared with TrafficManager)
var player_car: Node3D
var active_trams: Array = []
var spawn_cooldown := 0.0


func _ready() -> void:
	await get_tree().process_frame
	# Get road_network from TrafficManager (shared)
	var traffic_mgr = get_parent()
	if traffic_mgr and traffic_mgr.has_method("get_road_network"):
		road_network = traffic_mgr.get_road_network()


func _process(delta: float) -> void:
	if road_network == null:
		return
	if player_car == null:
		player_car = _find_player_car()
		if player_car == null:
			return

	spawn_cooldown -= delta
	if spawn_cooldown <= 0.0:
		_update_spawning()
		spawn_cooldown = SPAWN_COOLDOWN_TIME

	_update_despawning()


func _find_player_car() -> Node3D:
	var cars = get_tree().get_nodes_in_group("player_car")
	if not cars.is_empty():
		return cars[0]
	# Try common paths
	var car = get_node_or_null("/root/Main/Car")
	if car:
		return car
	return null


func _update_spawning() -> void:
	if active_trams.size() >= MAX_TRAMS:
		return
	if player_car == null:
		return

	var player_pos: Vector3 = player_car.global_position
	var player_cx := int(floor(player_pos.x / CHUNK_SIZE))
	var player_cz := int(floor(player_pos.z / CHUNK_SIZE))

	# Check 3x3 chunks around player
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if active_trams.size() >= MAX_TRAMS:
				return
			var chunk_key := "%d,%d" % [player_cx + dx, player_cz + dz]
			_attempt_spawn_in_chunk(chunk_key, player_pos)


func _attempt_spawn_in_chunk(chunk_key: String, player_pos: Vector3) -> bool:
	var waypoints: Array = road_network.get_tram_waypoints_in_chunk(chunk_key)
	if waypoints.is_empty():
		return false

	# Filter by distance
	var candidates: Array = []
	for wp in waypoints:
		var dist: float = wp.position.distance_to(player_pos)
		if dist > 80.0 and dist < SPAWN_DISTANCE:
			candidates.append(wp)

	if candidates.is_empty():
		return false

	# Check not too close to existing trams
	var spawn_wp = candidates[randi() % candidates.size()]
	for tram in active_trams:
		if tram.global_position.distance_to(spawn_wp.position) < 30.0:
			return false

	var tram := _create_tram()
	get_parent().get_parent().add_child(tram)
	tram.global_position = spawn_wp.position
	tram.rotation.y = atan2(spawn_wp.direction.x, spawn_wp.direction.z)

	# Build path
	var path: Array = _build_path(spawn_wp, 30)
	tram.set_path(path)

	active_trams.append(tram)
	return true


func _update_despawning() -> void:
	if player_car == null:
		return
	var player_pos: Vector3 = player_car.global_position
	var to_remove: Array = []
	for tram in active_trams:
		if not is_instance_valid(tram):
			to_remove.append(tram)
			continue
		if tram.global_position.distance_to(player_pos) > DESPAWN_DISTANCE:
			to_remove.append(tram)
	for tram in to_remove:
		active_trams.erase(tram)
		if is_instance_valid(tram):
			tram.queue_free()


func _create_tram() -> Node3D:
	var tram = preload("res://traffic/tram.gd").new()
	tram.road_network = road_network
	return tram


func _build_path(start_wp, count: int) -> Array:
	var path := [start_wp]
	var current = start_wp
	for i in range(count - 1):
		if current.next_waypoints.is_empty():
			break
		# Always go straight (or random at junctions)
		var next = current.next_waypoints[0]
		if next in path:
			break
		path.append(next)
		current = next
	return path
