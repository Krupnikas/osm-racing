extends Node
class_name TestRunner

# Запускает все тесты проекта
# Добавьте этот скрипт в сцену и вызовите run_all() или запустите test_runner.tscn

const TestOSMLoaderScript = preload("res://tests/test_osm_loader.gd")
const TestRoadTerrainClippingScript = preload("res://tests/test_road_terrain_clipping.gd")
const TestChunkLifecycleScript = preload("res://tests/test_chunk_lifecycle.gd")

var total_passed := 0
var total_failed := 0

func _ready() -> void:
	# Автоматически запускаем тесты при старте сцены
	await run_all()

func run_all() -> void:
	print("\n" + "=".repeat(50))
	print("       RUNNING ALL TESTS")
	print("=".repeat(50))

	total_passed = 0
	total_failed = 0

	# OSM Loader Tests
	var osm_tests := TestOSMLoaderScript.new()
	osm_tests.run_all_tests()
	total_passed += osm_tests.tests_passed
	total_failed += osm_tests.tests_failed

	# Road-Terrain Clipping Tests
	var road_terrain_tests := TestRoadTerrainClippingScript.new()
	road_terrain_tests.run_all_tests()
	total_passed += road_terrain_tests.tests_passed
	total_failed += road_terrain_tests.tests_failed

	# Chunk lifecycle tests
	var chunk_lifecycle_tests := TestChunkLifecycleScript.new()
	add_child(chunk_lifecycle_tests)
	await chunk_lifecycle_tests.run_all_tests()
	total_passed += chunk_lifecycle_tests.tests_passed
	total_failed += chunk_lifecycle_tests.tests_failed
	chunk_lifecycle_tests.queue_free()

	# Итоговый результат
	print("\n" + "=".repeat(50))
	print("       FINAL RESULTS")
	print("=".repeat(50))
	print("Total Passed: %d" % total_passed)
	print("Total Failed: %d" % total_failed)

	if total_failed == 0:
		print("\n*** ALL TESTS PASSED ***")
	else:
		print("\n*** SOME TESTS FAILED ***")

	print("=".repeat(50) + "\n")
	get_tree().quit(total_failed)
