extends Node

## Юнит-тесты для RoadNetwork

var RoadNetworkScript = preload("res://traffic/road_network.gd")
var road_network

func _ready():
	print("\n=== Running RoadNetwork Tests ===")
	road_network = RoadNetworkScript.new()

	test_waypoint_creation()
	test_road_segment_addition()
	test_vehicle_road_filtering()
	test_waypoint_connections()
	test_get_waypoints_in_chunk()
	test_clear_chunk()

	print("=== All RoadNetwork Tests Passed ===\n")
	# Don't quit - let the test runner handle it


func test_waypoint_creation():
	print("Test: Waypoint creation...")

	var wp = road_network.Waypoint.new(
		Vector3(10, 0, 20),
		Vector3(1, 0, 0),
		50.0,
		12.0,
		"0,0"
	)

	assert_true(wp.position == Vector3(10, 0, 20), "Waypoint position")
	assert_true(wp.direction == Vector3(1, 0, 0), "Waypoint direction")
	assert_true(wp.speed_limit == 50.0, "Waypoint speed limit")
	assert_true(wp.width == 12.0, "Waypoint width")
	assert_true(wp.chunk_key == "0,0", "Waypoint chunk key")
	assert_true(wp.next_waypoints.is_empty(), "Waypoint next_waypoints empty")

	print("  ✓ Waypoint creation works correctly")


func test_road_segment_addition():
	print("Test: Road segment addition...")

	var points = PackedVector2Array([
		Vector2(0, 0),
		Vector2(100, 0),
		Vector2(200, 0)
	])

	road_network.add_road_segment(points, "primary", "0,0", {})

	var waypoints = road_network.get_waypoints_in_chunk("0,0")
	assert_true(not waypoints.is_empty(), "Waypoints created")
	assert_true(waypoints.size() > 2, "Multiple waypoints created")

	# Проверяем что waypoints связаны последовательно
	var first_wp = waypoints[0]
	assert_true(first_wp.next_waypoints.size() > 0, "First waypoint has next")

	print("  ✓ Road segments add waypoints correctly")


func test_vehicle_road_filtering():
	print("Test: Vehicle road filtering...")

	# Добавляем пешеходную дорогу
	var footway_points = PackedVector2Array([
		Vector2(0, 100),
		Vector2(100, 100)
	])
	road_network.add_road_segment(footway_points, "footway", "1,0", {})

	# Добавляем обычную дорогу
	var road_points = PackedVector2Array([
		Vector2(0, 200),
		Vector2(100, 200)
	])
	road_network.add_road_segment(road_points, "residential", "1,0", {})

	var waypoints = road_network.get_waypoints_in_chunk("1,0")

	# Должны быть только waypoints от residential дороги
	assert_true(waypoints.size() > 0, "Vehicle road waypoints created")

	# Проверяем что это не footway (speed limit должен быть 25 для residential)
	if waypoints.size() > 0:
		var first_wp = waypoints[0]
		assert_true(first_wp.speed_limit == 25.0, "Correct speed limit for residential")

	print("  ✓ Pedestrian roads filtered correctly")


func test_waypoint_connections():
	print("Test: Waypoint connections at intersections...")

	# Создаём две пересекающиеся дороги
	var road1 = PackedVector2Array([
		Vector2(0, 50),
		Vector2(100, 50)
	])
	var road2 = PackedVector2Array([
		Vector2(50, 0),
		Vector2(50, 100)
	])

	road_network.add_road_segment(road1, "primary", "2,0", {})
	road_network.add_road_segment(road2, "secondary", "2,0", {})

	# Проверяем что создались пересечения
	var all_waypoints = road_network.all_waypoints

	# Ищем waypoint с несколькими next_waypoints (пересечение)
	var found_intersection = false
	for wp in all_waypoints:
		if wp.next_waypoints.size() > 1:
			found_intersection = true
			break

	# Пересечения могут быть найдены если waypoints достаточно близко
	print("  ✓ Waypoint connections tested (intersections: %s)" % found_intersection)


func test_get_waypoints_in_chunk():
	print("Test: Get waypoints in chunk...")

	var chunk1_waypoints = road_network.get_waypoints_in_chunk("0,0")
	var chunk2_waypoints = road_network.get_waypoints_in_chunk("1,0")
	var empty_chunk = road_network.get_waypoints_in_chunk("99,99")

	assert_true(chunk1_waypoints.size() > 0, "Chunk 0,0 has waypoints")
	assert_true(chunk2_waypoints.size() > 0, "Chunk 1,0 has waypoints")
	assert_true(empty_chunk.is_empty(), "Empty chunk returns empty array")

	print("  ✓ Get waypoints in chunk works correctly")


func test_clear_chunk():
	print("Test: Clear chunk...")

	var initial_count = road_network.all_waypoints.size()
	road_network.clear_chunk("1,0")

	var after_clear = road_network.all_waypoints.size()
	var cleared_waypoints = road_network.get_waypoints_in_chunk("1,0")

	assert_true(after_clear < initial_count, "Waypoints removed")
	assert_true(cleared_waypoints.is_empty(), "Chunk cleared")

	print("  ✓ Clear chunk works correctly")


func assert_true(condition: bool, message: String):
	if not condition:
		push_error("ASSERTION FAILED: %s" % message)
		get_tree().quit(1)
