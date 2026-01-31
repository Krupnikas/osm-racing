extends SceneTree

## Тестирует импакт каждой фичи на производительность
## Запуск: /Applications/Godot.app/Contents/MacOS/Godot --headless --script tests/feature_impact_test.gd

const TEST_DURATION := 30.0  # Каждый тест по 30 секунд
const TESTS := [
	{"name": "baseline", "config": {"all": true}},
	{"name": "no_buildings", "config": {"buildings": false}},
	{"name": "no_windows", "config": {"windows": false}},
	{"name": "no_roads", "config": {"roads": false}},
	{"name": "no_curbs", "config": {"curbs": false}},
	{"name": "no_vegetation", "config": {"vegetation": false}},
	{"name": "no_street_lamps", "config": {"street_lamps": false}},
	{"name": "no_traffic_signs", "config": {"traffic_signs": false}},
	{"name": "no_traffic_lights", "config": {"traffic_lights": false}},
	{"name": "no_frustum_culling", "config": {"frustum_culling": false}},
	# Комбинации
	{"name": "infra_only", "config": {"buildings": false, "vegetation": false}},  # Только дороги+знаки
	{"name": "buildings_only", "config": {"roads": false, "curbs": false, "vegetation": false, "street_lamps": false, "traffic_signs": false, "traffic_lights": false}},
	{"name": "roads_only", "config": {"buildings": false, "vegetation": false, "street_lamps": false, "traffic_signs": false, "traffic_lights": false}},
]

var current_test_index := 0
var test_results: Array[Dictionary] = []

func _init():
	print("\n========== FEATURE IMPACT TEST ==========")
	print("Testing %d configurations" % TESTS.size())
	print("Duration per test: %.0f seconds" % TEST_DURATION)
	print("Total time: ~%.1f minutes" % (TESTS.size() * TEST_DURATION / 60.0))
	print("==========================================\n")

	# Создаём отчёт
	_run_all_tests()
	_print_results()
	quit()

func _run_all_tests() -> void:
	# ПРИМЕЧАНИЕ: Godot в headless mode не может корректно запустить сцену
	# Нужно использовать обычный тест в GUI mode
	print("⚠️  ERROR: This test requires GUI mode!")
	print("Run instead:")
	print("  /Applications/Godot.app/Contents/MacOS/Godot --path . res://tests/feature_impact_test.tscn")
	print()

func _print_results() -> void:
	print("\n========== TEST PLAN ==========")
	for i in range(TESTS.size()):
		var test = TESTS[i]
		print("\nTest #%d: %s" % [i + 1, test.name])
		print("  Config: %s" % JSON.stringify(test.config))
	print("\n===============================\n")
