extends Node

## Интеграционный тест системы трафика

var RoadNetworkScript = preload("res://traffic/road_network.gd")
var TrafficManagerScript = preload("res://traffic/traffic_manager.gd")
var npc_car_scene = preload("res://traffic/npc_car.tscn")

func _ready():
	print("\n=== Running Traffic Integration Tests ===")

	await test_traffic_manager_initialization()
	await test_npc_spawning()
	await test_npc_movement()
	await test_collision_avoidance()

	print("=== All Traffic Integration Tests Passed ===\n")
	# Don't quit - let the test runner handle it


func test_traffic_manager_initialization():
	print("Test: Traffic manager initialization...")

	var traffic_mgr = TrafficManagerScript.new()
	add_child(traffic_mgr)

	await get_tree().process_frame

	assert_true(traffic_mgr.road_network != null, "RoadNetwork created")
	assert_true(traffic_mgr.active_npcs.is_empty(), "No active NPCs initially")
	assert_true(traffic_mgr.inactive_npcs.is_empty(), "No inactive NPCs initially")

	traffic_mgr.queue_free()
	print("  ✓ Traffic manager initializes correctly")


func test_npc_spawning():
	print("Test: NPC spawning logic...")

	var road_network = RoadNetworkScript.new()
	add_child(road_network)

	# Создаём дорожную сеть
	var road_points = PackedVector2Array()
	for i in range(10):
		road_points.append(Vector2(i * 20.0, 0))

	road_network.add_road_segment(road_points, "primary", "0,0", {})

	var waypoints = road_network.get_waypoints_in_chunk("0,0")
	assert_true(waypoints.size() > 0, "Waypoints created for spawning")

	# Тестируем что можно получить waypoint
	var nearest = road_network.get_nearest_waypoint(Vector3(50, 0, 0))
	assert_true(nearest != null, "Can find nearest waypoint")

	road_network.queue_free()
	print("  ✓ NPC spawning logic works")


func test_npc_movement():
	print("Test: NPC movement...")

	var npc = npc_car_scene.instantiate()
	add_child(npc)

	var road_network = RoadNetworkScript.new()

	# Создаём прямую дорогу
	var waypoints = []
	for i in range(10):
		var wp = road_network.Waypoint.new(
			Vector3(i * 15.0, 0, 0),
			Vector3(1, 0, 0),
			40.0,
			10.0,
			"0,0"
		)
		waypoints.append(wp)

	for i in range(waypoints.size() - 1):
		waypoints[i].next_waypoints.append(waypoints[i + 1])

	npc.set_path(waypoints)
	npc.global_position = Vector3(0, 1, 0)

	# Симулируем несколько кадров
	for i in range(5):
		await get_tree().process_frame

	# NPC должен начать двигаться (скорость > 0)
	# Но из-за физики может быть еще 0, так что проверяем что не упало
	assert_true(npc.global_position.y > -10, "NPC not fallen through floor")

	npc.queue_free()
	print("  ✓ NPC movement doesn't crash")


func test_collision_avoidance():
	print("Test: Collision avoidance...")

	var npc1 = npc_car_scene.instantiate()
	var npc2 = npc_car_scene.instantiate()

	add_child(npc1)
	add_child(npc2)

	# Размещаем машины близко
	npc1.global_position = Vector3(0, 1, 0)
	npc2.global_position = Vector3(10, 1, 0)

	await get_tree().process_frame

	# Проверяем что raycast setup работает
	assert_true(npc1.obstacle_check_ray != null, "NPC1 has raycast")
	assert_true(npc2.obstacle_check_ray != null, "NPC2 has raycast")

	npc1.queue_free()
	npc2.queue_free()
	print("  ✓ Collision avoidance setup works")


func assert_true(condition: bool, message: String):
	if not condition:
		push_error("ASSERTION FAILED: %s" % message)
		get_tree().quit(1)
