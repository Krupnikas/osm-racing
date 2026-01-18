extends Node

## Test Runner для всех traffic тестов

var tests = [
	"res://tests/test_road_network.gd",
	"res://tests/test_npc_car.gd",
	"res://tests/test_traffic_integration.gd"
]

var current_test_index = 0

func _ready():
	print("\n" + "=".repeat(50))
	print("TRAFFIC SYSTEM TEST SUITE")
	print("=".repeat(50))

	_run_next_test()


func _run_next_test():
	if current_test_index >= tests.size():
		print("\n" + "=".repeat(50))
		print("ALL TESTS COMPLETED SUCCESSFULLY!")
		print("=".repeat(50) + "\n")
		get_tree().quit()
		return

	var test_path = tests[current_test_index]
	print("\nRunning test: %s" % test_path)

	var test_script = load(test_path)
	var test_node = Node.new()
	test_node.set_script(test_script)
	add_child(test_node)

	# Ждём завершения теста
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	current_test_index += 1
	_run_next_test()
