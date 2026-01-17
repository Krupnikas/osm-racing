extends Node
class_name TestOSMLoader

# Тесты для OSMLoader
# Запуск: добавить TestRunner в сцену и вызвать run_all_tests()

var tests_passed := 0
var tests_failed := 0
var test_results := []

func run_all_tests() -> void:
	print("\n=== OSM Loader Tests ===\n")
	tests_passed = 0
	tests_failed = 0
	test_results.clear()

	# Запускаем все тесты
	test_latlon_to_local_center()
	test_latlon_to_local_offset()
	test_latlon_to_local_negative()
	test_parse_osm_data_empty()
	test_parse_osm_data_nodes_only()
	test_parse_osm_data_way_with_nodes()

	# Выводим результаты
	print("\n=== Results ===")
	print("Passed: %d" % tests_passed)
	print("Failed: %d" % tests_failed)
	print("Total: %d" % (tests_passed + tests_failed))

	if tests_failed > 0:
		print("\nFailed tests:")
		for result in test_results:
			if not result.passed:
				print("  - %s: %s" % [result.name, result.message])

func _assert(condition: bool, test_name: String, message: String = "") -> void:
	if condition:
		tests_passed += 1
		test_results.append({"name": test_name, "passed": true, "message": ""})
		print("[PASS] %s" % test_name)
	else:
		tests_failed += 1
		test_results.append({"name": test_name, "passed": false, "message": message})
		print("[FAIL] %s - %s" % [test_name, message])

func _assert_eq(actual, expected, test_name: String) -> void:
	var condition := actual == expected
	var message := "Expected %s, got %s" % [expected, actual]
	_assert(condition, test_name, message)

func _assert_near(actual: float, expected: float, tolerance: float, test_name: String) -> void:
	var condition := abs(actual - expected) < tolerance
	var message := "Expected ~%f (±%f), got %f" % [expected, tolerance, actual]
	_assert(condition, test_name, message)

# === Тесты latlon_to_local ===

func test_latlon_to_local_center() -> void:
	# В центре координаты должны быть (0, 0)
	var loader := _create_mock_loader(59.149886, 37.949370)
	var result := loader.latlon_to_local(59.149886, 37.949370)

	_assert_near(result.x, 0.0, 0.01, "latlon_to_local: center X should be 0")
	_assert_near(result.y, 0.0, 0.01, "latlon_to_local: center Y should be 0")

func test_latlon_to_local_offset() -> void:
	# Смещение на ~111 метров к северу (изменение широты на 0.001)
	var loader := _create_mock_loader(59.149886, 37.949370)
	var result := loader.latlon_to_local(59.150886, 37.949370)

	_assert_near(result.x, 0.0, 0.01, "latlon_to_local: north offset X should be 0")
	_assert_near(result.y, 111.0, 5.0, "latlon_to_local: north offset Y should be ~111m")

func test_latlon_to_local_negative() -> void:
	# Смещение на юг - должно быть отрицательным
	var loader := _create_mock_loader(59.149886, 37.949370)
	var result := loader.latlon_to_local(59.148886, 37.949370)

	_assert(result.y < 0, "latlon_to_local: south offset Y should be negative")

# === Тесты парсинга OSM данных ===

func test_parse_osm_data_empty() -> void:
	var loader := _create_mock_loader(59.149886, 37.949370)
	var data := {"elements": []}
	var result := loader._parse_osm_data(data)

	_assert_eq(result.ways.size(), 0, "parse_osm_data: empty data should have 0 ways")
	_assert_eq(result.nodes.size(), 0, "parse_osm_data: empty data should have 0 nodes")

func test_parse_osm_data_nodes_only() -> void:
	var loader := _create_mock_loader(59.149886, 37.949370)
	var data := {
		"elements": [
			{"type": "node", "id": 1, "lat": 59.15, "lon": 37.95},
			{"type": "node", "id": 2, "lat": 59.16, "lon": 37.96}
		]
	}
	var result := loader._parse_osm_data(data)

	_assert_eq(result.nodes.size(), 2, "parse_osm_data: should parse 2 nodes")
	_assert_eq(result.ways.size(), 0, "parse_osm_data: should have 0 ways without way elements")

func test_parse_osm_data_way_with_nodes() -> void:
	var loader := _create_mock_loader(59.149886, 37.949370)
	var data := {
		"elements": [
			{"type": "node", "id": 1, "lat": 59.15, "lon": 37.95},
			{"type": "node", "id": 2, "lat": 59.16, "lon": 37.96},
			{"type": "node", "id": 3, "lat": 59.17, "lon": 37.97},
			{
				"type": "way",
				"id": 100,
				"nodes": [1, 2, 3],
				"tags": {"highway": "residential", "name": "Test Street"}
			}
		]
	}
	var result := loader._parse_osm_data(data)

	_assert_eq(result.ways.size(), 1, "parse_osm_data: should parse 1 way")
	_assert_eq(result.ways[0].nodes.size(), 3, "parse_osm_data: way should have 3 nodes")
	_assert_eq(result.ways[0].tags.get("highway"), "residential", "parse_osm_data: should preserve tags")

# === Вспомогательные функции ===

func _create_mock_loader(center_lat: float, center_lon: float) -> Node:
	var OSMLoaderScript = preload("res://osm/osm_loader.gd")
	var loader := OSMLoaderScript.new()
	loader.center_lat = center_lat
	loader.center_lon = center_lon
	return loader
