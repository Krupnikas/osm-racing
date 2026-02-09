@tool
extends SceneTree

## Генератор Normal Map из текстуры здания
## Использует Sobel-фильтр для определения граней (окна, балконы)

func _init():
	var textures := [
		"res://textures/buildings/111-125.jpg",
		"res://textures/buildings/111-126.jpg"
	]

	for tex_path in textures:
		generate_normal_map(tex_path)

	print("Normal map generation complete!")
	quit()


func generate_normal_map(source_path: String) -> void:
	print("Processing: ", source_path)

	# Загружаем исходную текстуру
	var img := Image.new()
	var err := img.load(source_path)
	if err != OK:
		print("  ERROR: Failed to load ", source_path)
		return

	print("  Size: ", img.get_width(), "x", img.get_height())

	# Создаём карту высот (grayscale)
	var height_map := create_height_map(img)

	# Генерируем normal map из height map
	var normal_map := create_normal_map_from_height(height_map)

	# Сохраняем normal map
	var output_path := source_path.replace(".jpg", "_normal.png")
	normal_map.save_png(output_path)
	print("  Saved: ", output_path)


func create_height_map(source: Image) -> Image:
	"""Создаёт карту высот на основе яркости и контраста"""
	var width := source.get_width()
	var height := source.get_height()

	var height_map := Image.create(width, height, false, Image.FORMAT_L8)

	for y in range(height):
		for x in range(width):
			var color := source.get_pixel(x, y)
			# Luminance formula
			var lum := color.r * 0.299 + color.g * 0.587 + color.b * 0.114

			# Усиливаем контраст для лучшего выделения глубины
			# Тёмные области (окна, тени) = углубления
			# Светлые области (стены) = выступы
			lum = clampf(lum * 1.2, 0.0, 1.0)

			height_map.set_pixel(x, y, Color(lum, lum, lum, 1.0))

	return height_map


func create_normal_map_from_height(height_map: Image) -> Image:
	"""Генерирует normal map из height map используя Sobel-фильтр"""
	var width := height_map.get_width()
	var height := height_map.get_height()

	var normal_map := Image.create(width, height, false, Image.FORMAT_RGBA8)

	# Сила эффекта (больше = более выраженные нормали)
	var strength := 2.0

	for y in range(height):
		for x in range(width):
			# Sobel-фильтр для вычисления градиентов
			var tl := get_height(height_map, x - 1, y - 1)  # top-left
			var t  := get_height(height_map, x,     y - 1)  # top
			var tr := get_height(height_map, x + 1, y - 1)  # top-right
			var l  := get_height(height_map, x - 1, y)      # left
			var r  := get_height(height_map, x + 1, y)      # right
			var bl := get_height(height_map, x - 1, y + 1)  # bottom-left
			var b  := get_height(height_map, x,     y + 1)  # bottom
			var br := get_height(height_map, x + 1, y + 1)  # bottom-right

			# Sobel X gradient
			var dx := (tr + 2.0 * r + br) - (tl + 2.0 * l + bl)
			# Sobel Y gradient
			var dy := (bl + 2.0 * b + br) - (tl + 2.0 * t + tr)

			# Создаём нормаль
			var normal := Vector3(-dx * strength, -dy * strength, 1.0).normalized()

			# Преобразуем в цвет (0..1 range, где 0.5 = нейтральный)
			var r_val := normal.x * 0.5 + 0.5
			var g_val := normal.y * 0.5 + 0.5
			var b_val := normal.z * 0.5 + 0.5

			normal_map.set_pixel(x, y, Color(r_val, g_val, b_val, 1.0))

	return normal_map


func get_height(img: Image, x: int, y: int) -> float:
	"""Получает высоту пикселя с обработкой границ"""
	x = clampi(x, 0, img.get_width() - 1)
	y = clampi(y, 0, img.get_height() - 1)
	return img.get_pixel(x, y).r
