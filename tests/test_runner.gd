extends Node
class_name TestRunner

# Запускает все тесты проекта
# Добавьте этот скрипт в сцену и вызовите run_all() или запустите test_runner.tscn

const TestOSMLoaderScript = preload("res://tests/test_osm_loader.gd")

var total_passed := 0
var total_failed := 0

func _ready() -> void:
	# Автоматически запускаем тесты при старте сцены
	run_all()

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
		# Выход с кодом ошибки для CI
		# get_tree().quit(1)

	print("=".repeat(50) + "\n")
