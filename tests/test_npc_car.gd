extends Node

## Юнит-тесты для NPCCar

var RoadNetworkScript = preload("res://traffic/road_network.gd")
var npc_car_scene = preload("res://traffic/npc_car.tscn")

func _ready():
	print("\n=== Running NPCCar Tests ===")

	test_npc_car_initialization()
	test_path_following()
	test_color_randomization()
	test_obstacle_detection_setup()

	print("=== All NPCCar Tests Passed ===\n")
	# Don't quit - let the test runner handle it


func test_npc_car_initialization():
	print("Test: NPC car initialization...")

	var npc = npc_car_scene.instantiate()
	add_child(npc)

	assert_true(npc.max_engine_power == 150.0, "Engine power set correctly")
	assert_true(npc.max_steering_angle == 30.0, "Steering angle set correctly")
	assert_true(npc.collision_layer == 4, "Collision layer correct")
	assert_true(npc.collision_mask == 7, "Collision mask correct (terrain + buildings + NPCs)")

	assert_true(npc.waypoint_path.is_empty(), "Path initially empty")
	assert_true(npc.current_waypoint_index == 0, "Waypoint index at 0")

	npc.queue_free()
	print("  ✓ NPC car initializes correctly")


func test_path_following():
	print("Test: Path following...")

	var road_network = RoadNetworkScript.new()

	# Создаём простой путь
	var waypoints = []
	for i in range(5):
		var wp = road_network.Waypoint.new(
			Vector3(i * 10.0, 0, 0),
			Vector3(1, 0, 0),
			40.0,
			10.0,
			"0,0"
		)
		waypoints.append(wp)

	# Связываем waypoints
	for i in range(waypoints.size() - 1):
		waypoints[i].next_waypoints.append(waypoints[i + 1])

	var npc = npc_car_scene.instantiate()
	add_child(npc)

	npc.set_path(waypoints)

	assert_true(npc.waypoint_path.size() == 5, "Path set correctly")
	assert_true(npc.target_speed == 40.0 * 0.8, "Target speed set from waypoint")

	npc.queue_free()
	print("  ✓ Path following setup works")


func test_color_randomization():
	print("Test: Color randomization...")

	var colors_seen = {}
	var npc = npc_car_scene.instantiate()
	add_child(npc)

	# Проверяем что randomize_color не вызывает ошибок
	for i in range(10):
		npc.randomize_color()
		# Функция должна работать без ошибок

	npc.queue_free()
	print("  ✓ Color randomization works")


func test_obstacle_detection_setup():
	print("Test: Obstacle detection setup...")

	var npc = npc_car_scene.instantiate()
	add_child(npc)

	# Даём время на _ready
	await get_tree().process_frame

	assert_true(npc.obstacle_check_ray != null, "Raycast created")
	assert_true(npc.obstacle_check_ray.collision_mask == 6, "Raycast mask correct (buildings + NPCs)")

	npc.queue_free()
	print("  ✓ Obstacle detection setup correctly")


func assert_true(condition: bool, message: String):
	if not condition:
		push_error("ASSERTION FAILED: %s" % message)
		get_tree().quit(1)
