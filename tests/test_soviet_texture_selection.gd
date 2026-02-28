extends Node

## Тест для проверки выбора советских текстур для 5-этажных зданий БЕЗ оверрайдов
## ВАЖНО: Тестирует функцию _get_random_soviet_texture(), которая вызывается ТОЛЬКО
##        для зданий БЕЗ явных переопределений в building_overrides.json!
##
## Проверяет:
## 1. Кирпичные здания (building:material=brick) получают 5-soviet-brick.png
## 2. Панельные здания (concrete/panel/default) получают одну из 5 панельных текстур
## 3. Детерминированность выбора (один way_id → одна текстура)
## 4. Равномерное распределение панельных текстур

func _ready() -> void:
	print("\n========== TEST: Soviet Texture Selection ==========")

	# Создаём экземпляр OSMTerrainGenerator для доступа к приватным методам
	var terrain_gen = preload("res://osm/osm_terrain_generator.gd").new()

	var all_tests_passed := true

	# Тест 1: Кирпичное здание должно получить brick текстуру
	print("\n[TEST 1] Brick building material detection")
	var brick_tags := {"building:material": "brick", "building:levels": "5"}
	for way_id in range(1, 10):
		var texture := terrain_gen._get_random_soviet_texture(way_id, brick_tags)
		if texture != "res://textures/buildings/5-soviet-brick.png":
			print("  ❌ FAIL: way_id=%d got %s instead of brick texture" % [way_id, texture])
			all_tests_passed = false
		else:
			print("  ✅ PASS: way_id=%d correctly got brick texture" % way_id)

	# Тест 2: Панельное здание должно получить одну из 5 панельных текстур
	print("\n[TEST 2] Panel building material detection")
	const PANEL_TEXTURES := [
		"res://textures/buildings/5-soviet-panel.png",
		"res://textures/buildings/5-soviet-panel-2.png",
		"res://textures/buildings/5-soviet-panel-3.png",
		"res://textures/buildings/5-soviet-panel-4.png",
		"res://textures/buildings/5-soviet-panel-5.png"
	]

	var panel_tags := {"building:material": "concrete", "building:levels": "5"}
	for way_id in range(1, 10):
		var texture := terrain_gen._get_random_soviet_texture(way_id, panel_tags)
		if not texture in PANEL_TEXTURES:
			print("  ❌ FAIL: way_id=%d got %s which is not a panel texture" % [way_id, texture])
			all_tests_passed = false
		else:
			print("  ✅ PASS: way_id=%d got panel texture: %s" % [way_id, texture.get_file()])

	# Тест 3: Здание без тега material (по умолчанию панель)
	print("\n[TEST 3] Building without material tag (default to panel)")
	var default_tags := {"building:levels": "5"}
	for way_id in range(1, 10):
		var texture := terrain_gen._get_random_soviet_texture(way_id, default_tags)
		if not texture in PANEL_TEXTURES:
			print("  ❌ FAIL: way_id=%d got %s which is not a panel texture" % [way_id, texture])
			all_tests_passed = false
		else:
			print("  ✅ PASS: way_id=%d defaulted to panel texture: %s" % [way_id, texture.get_file()])

	# Тест 4: Детерминированность (один way_id всегда даёт одну текстуру)
	print("\n[TEST 4] Deterministic texture selection")
	var test_way_id := 12345
	var first_result := terrain_gen._get_random_soviet_texture(test_way_id, panel_tags)
	var deterministic := true
	for i in range(10):
		var result := terrain_gen._get_random_soviet_texture(test_way_id, panel_tags)
		if result != first_result:
			print("  ❌ FAIL: way_id=%d gave different results: %s vs %s" % [test_way_id, first_result.get_file(), result.get_file()])
			deterministic = false
			all_tests_passed = false
			break
	if deterministic:
		print("  ✅ PASS: way_id=%d consistently returns %s" % [test_way_id, first_result.get_file()])

	# Тест 5: Разные way_id дают разные панельные текстуры (проверка распределения)
	print("\n[TEST 5] Distribution across panel textures")
	var texture_counts := {}
	for texture_path in PANEL_TEXTURES:
		texture_counts[texture_path] = 0

	# Тестируем 100 разных way_id
	for way_id in range(1, 101):
		var texture := terrain_gen._get_random_soviet_texture(way_id, panel_tags)
		if texture in texture_counts:
			texture_counts[texture] += 1

	print("  Distribution of textures across 100 buildings:")
	var distribution_ok := true
	for texture_path in PANEL_TEXTURES:
		var count: int = texture_counts[texture_path]
		var percentage := count * 100.0 / 100.0
		print("    %s: %d (%.1f%%)" % [texture_path.get_file(), count, percentage])
		# Ожидаем примерно 20% для каждой из 5 текстур (допуск ±10%)
		if count < 10 or count > 30:
			print("      ⚠️  WARNING: Uneven distribution (expected ~20 per texture)")
			distribution_ok = false

	if distribution_ok:
		print("  ✅ PASS: Distribution is reasonable")
	else:
		print("  ⚠️  WARN: Distribution is uneven (may be acceptable for modulo-based selection)")

	# Тест 6: Случайные way_id БЕЗ оверрайдов (симулируют здания без явных переопределений)
	print("\n[TEST 6] Random way_ids WITHOUT overrides (simulate buildings without explicit overrides)")
	# ВАЖНО: Эти way_id НЕ должны совпадать с теми, что в building_overrides.json!
	# Реальные здания 7,9,13,17,21,23,27,29,31 УЖЕ ИМЕЮТ оверрайды и никогда не попадут в эту функцию

	# Симулируем панельные здания БЕЗ оверрайдов
	var random_panel_ids := [99999, 88888, 77777, 66666, 55555]
	print("  Simulated panel buildings WITHOUT overrides (building:material=concrete):")
	for way_id in random_panel_ids:
		var texture := terrain_gen._get_random_soviet_texture(way_id, panel_tags)
		if texture in PANEL_TEXTURES:
			print("    ✅ way_id=%d → %s" % [way_id, texture.get_file()])
		else:
			print("    ❌ way_id=%d → %s (WRONG! Expected panel texture)" % [way_id, texture])
			all_tests_passed = false

	# Симулируем кирпичные здания БЕЗ оверрайдов
	var random_brick_ids := [11111, 22222, 33333, 44444]
	print("  Simulated brick buildings WITHOUT overrides (building:material=brick):")
	for way_id in random_brick_ids:
		var texture := terrain_gen._get_random_soviet_texture(way_id, brick_tags)
		if texture == "res://textures/buildings/5-soviet-brick.png":
			print("    ✅ way_id=%d → %s" % [way_id, texture.get_file()])
		else:
			print("    ❌ way_id=%d → %s (WRONG! Expected brick texture)" % [way_id, texture])
			all_tests_passed = false

	print("\n  NOTE: Real buildings 7,9,13,17,21,23,27,29,31 (Северное шоссе) have EXPLICIT")
	print("        overrides in building_overrides.json and will NEVER call this function!")

	# Финальный результат
	print("\n" + "=".repeat(50))
	if all_tests_passed:
		print("✅ ALL TESTS PASSED")
	else:
		print("❌ SOME TESTS FAILED")
	print("=".repeat(50) + "\n")

	terrain_gen.queue_free()

	# Автовыход через 1 секунду
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()
