extends Node
class_name TextureGenerator

# Генерирует процедурные текстуры для игры

static func create_asphalt_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	for y in range(size):
		for x in range(size):
			var base := 0.25 + rng.randf() * 0.1
			# Добавляем мелкие трещины
			var crack := 0.0
			if rng.randf() < 0.02:
				crack = -0.1
			var c: float = clamp(base + crack, 0.0, 1.0)
			image.set_pixel(x, y, Color(c, c, c))

	var texture := ImageTexture.create_from_image(image)
	return texture

# Текстура дороги с разметкой (для UV маппинга вдоль дороги)
# UV: x = поперёк дороги (0-1), y = вдоль дороги (повторяется)
static func create_road_texture(size: int = 256, lanes: int = 2, has_center_line: bool = true, has_edge_lines: bool = true) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var line_width := size / 80  # Ширина линии разметки (тонкая)
	var dash_length := size / 3  # Длина штриха
	var gap_length := size / 3   # Длина промежутка

	for y in range(size):
		for x in range(size):
			# Реалистичный асфальт с вариацией
			rng.seed = 12345 + x * 17 + y * 31
			var base := 0.22 + rng.randf() * 0.06
			# Добавляем крупнозернистую текстуру
			var grain := sin(float(x) * 0.8) * sin(float(y) * 0.8) * 0.02
			# Пятна масла и износ
			var wear := 0.0
			if rng.randf() < 0.03:
				wear = rng.randf() * 0.05 - 0.025
			base = clamp(base + grain + wear, 0.15, 0.35)
			var color := Color(base, base * 0.98, base * 0.96)

			# Центральная прерывистая белая линия
			if has_center_line:
				var center := size / 2
				if abs(x - center) < line_width:
					var dash_pos := y % (dash_length + gap_length)
					if dash_pos < dash_length:
						# Белая разметка с лёгким износом
						var line_wear := 0.85 + rng.randf() * 0.1
						color = Color(line_wear, line_wear, line_wear * 0.98)

			image.set_pixel(x, y, color)

	var texture := ImageTexture.create_from_image(image)
	return texture

# Текстура широкой дороги (шоссе) с двойной сплошной в центре
static func create_highway_texture(size: int = 512, lanes: int = 4) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23456

	var line_width := size / 128
	var dash_length := size / 4
	var gap_length := size / 4
	var lane_width := size / lanes
	var center := size / 2

	for y in range(size):
		for x in range(size):
			# Реалистичный тёмный асфальт для магистрали
			rng.seed = 23456 + x * 19 + y * 37
			var base := 0.18 + rng.randf() * 0.06
			# Крупнозернистая текстура
			var grain := sin(float(x) * 0.6) * sin(float(y) * 0.6) * 0.015
			# Износ и пятна
			var wear := 0.0
			if rng.randf() < 0.025:
				wear = rng.randf() * 0.04 - 0.02
			base = clamp(base + grain + wear, 0.12, 0.30)
			var color := Color(base, base * 0.98, base * 0.96)

			# Разделительные линии между полосами (белые прерывистые)
			# Пропускаем центральную полосу (lane 2 из 4) - там будет двойная сплошная
			for lane_i in range(1, lanes):
				var lane_x := lane_i * lane_width
				# Пропускаем центр - там двойная сплошная
				if lane_i == lanes / 2:
					continue
				if abs(x - lane_x) < line_width:
					var dash_pos := y % (dash_length + gap_length)
					if dash_pos < dash_length:
						var line_wear := 0.82 + rng.randf() * 0.1
						color = Color(line_wear, line_wear, line_wear * 0.98)

			# Центральная разделительная (двойная сплошная белая)
			var double_line_gap := line_width * 2  # Промежуток между линиями
			if abs(x - center - double_line_gap) < line_width or abs(x - center + double_line_gap) < line_width:
				var line_wear := 0.88 + rng.randf() * 0.08
				color = Color(line_wear, line_wear, line_wear * 0.98)

			image.set_pixel(x, y, color)

	var texture := ImageTexture.create_from_image(image)
	return texture


# Текстура primary дороги (одна сплошная в центре)
static func create_primary_texture(size: int = 512, lanes: int = 4) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23457

	var line_width := size / 128
	var dash_length := size / 4
	var gap_length := size / 4
	var lane_width := size / lanes
	var center := size / 2

	for y in range(size):
		for x in range(size):
			# Реалистичный тёмный асфальт
			rng.seed = 23457 + x * 19 + y * 37
			var base := 0.20 + rng.randf() * 0.06
			# Крупнозернистая текстура
			var grain := sin(float(x) * 0.6) * sin(float(y) * 0.6) * 0.015
			# Износ и пятна
			var wear := 0.0
			if rng.randf() < 0.025:
				wear = rng.randf() * 0.04 - 0.02
			base = clamp(base + grain + wear, 0.14, 0.32)
			var color := Color(base, base * 0.98, base * 0.96)

			# Разделительные линии между полосами (белые прерывистые)
			# Пропускаем центральную полосу - там будет сплошная
			for lane_i in range(1, lanes):
				var lane_x := lane_i * lane_width
				if lane_i == lanes / 2:
					continue
				if abs(x - lane_x) < line_width:
					var dash_pos := y % (dash_length + gap_length)
					if dash_pos < dash_length:
						var line_wear := 0.82 + rng.randf() * 0.1
						color = Color(line_wear, line_wear, line_wear * 0.98)

			# Центральная разделительная (одна сплошная белая)
			if abs(x - center) < line_width:
				var line_wear := 0.88 + rng.randf() * 0.08
				color = Color(line_wear, line_wear, line_wear * 0.98)

			image.set_pixel(x, y, color)

	var texture := ImageTexture.create_from_image(image)
	return texture


# Текстура перекрёстка (чистый асфальт без разметки)
static func create_intersection_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 34568

	for y in range(size):
		for x in range(size):
			# Реалистичный тёмный асфальт (как на дорогах)
			rng.seed = 34568 + x * 19 + y * 37
			var base := 0.20 + rng.randf() * 0.06
			# Крупнозернистая текстура
			var grain := sin(float(x) * 0.6) * sin(float(y) * 0.6) * 0.015
			# Износ и пятна (больше износа на перекрёстках)
			var wear := 0.0
			if rng.randf() < 0.04:
				wear = rng.randf() * 0.05 - 0.025
			base = clamp(base + grain + wear, 0.14, 0.32)
			image.set_pixel(x, y, Color(base, base * 0.98, base * 0.96))

	var texture := ImageTexture.create_from_image(image)
	return texture


# Текстура пешеходной дорожки (светлый асфальт)
static func create_sidewalk_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 34567

	for y in range(size):
		for x in range(size):
			# Светлый серый асфальт для тротуаров
			rng.seed = 34567 + x * 13 + y * 29
			var base := 0.45 + rng.randf() * 0.08
			# Мелкозернистая текстура
			var grain := sin(float(x) * 1.2) * sin(float(y) * 1.2) * 0.015
			# Небольшие пятна и вариации
			var spot := 0.0
			if rng.randf() < 0.04:
				spot = rng.randf() * 0.06 - 0.03
			base = clamp(base + grain + spot, 0.38, 0.58)
			# Чуть тёплый оттенок серого
			image.set_pixel(x, y, Color(base, base * 0.98, base * 0.95))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_concrete_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 54321

	for y in range(size):
		for x in range(size):
			var base := 0.6 + rng.randf() * 0.08
			# Линии стыков
			var joint := 0.0
			if x % 64 < 2 or y % 64 < 2:
				joint = -0.15
			var c: float = clamp(base + joint, 0.0, 1.0)
			image.set_pixel(x, y, Color(c * 0.95, c * 0.93, c * 0.9))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_brick_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11111

	var brick_width := 32
	var brick_height := 16
	var mortar := 2

	for y in range(size):
		for x in range(size):
			var row := y / brick_height
			var offset := (row % 2) * (brick_width / 2)
			var bx := (x + offset) % brick_width
			var by := y % brick_height

			var is_mortar := bx < mortar or by < mortar

			if is_mortar:
				var c := 0.5 + rng.randf() * 0.05
				image.set_pixel(x, y, Color(c, c * 0.95, c * 0.9))
			else:
				var base := 0.55 + rng.randf() * 0.15
				image.set_pixel(x, y, Color(base, base * 0.4, base * 0.3))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_grass_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 33333

	for y in range(size):
		for x in range(size):
			var base_g := 0.4 + rng.randf() * 0.25
			var base_r := base_g * 0.5 + rng.randf() * 0.1
			var base_b := base_g * 0.3 + rng.randf() * 0.05
			image.set_pixel(x, y, Color(base_r, base_g, base_b))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_dirt_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 44444

	for y in range(size):
		for x in range(size):
			var base := 0.35 + rng.randf() * 0.2
			image.set_pixel(x, y, Color(base * 0.8, base * 0.6, base * 0.4))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_water_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 55555

	for y in range(size):
		for x in range(size):
			var wave := sin(float(x) * 0.1) * 0.05 + sin(float(y) * 0.08) * 0.05
			var base_b := 0.6 + wave + rng.randf() * 0.1
			var base_g := 0.4 + wave * 0.5 + rng.randf() * 0.05
			var base_r := 0.2 + rng.randf() * 0.05
			image.set_pixel(x, y, Color(base_r, base_g, base_b, 0.85))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_roof_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 66666

	var tile_size := 16

	for y in range(size):
		for x in range(size):
			var tx := x % tile_size
			var ty := y % tile_size
			var row := y / tile_size
			var offset := (row % 2) * (tile_size / 2)
			var ax := (x + offset) % tile_size

			var edge := ax < 1 or ty < 1
			var base := 0.35 + rng.randf() * 0.1
			if edge:
				base *= 0.7
			# Красновато-коричневая черепица
			image.set_pixel(x, y, Color(base * 1.2, base * 0.5, base * 0.4))

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_wall_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77777

	for y in range(size):
		for x in range(size):
			var base := 0.7 + rng.randf() * 0.1
			# Штукатурка с небольшими неровностями
			var noise := sin(float(x) * 0.5) * cos(float(y) * 0.5) * 0.03
			var c: float = clamp(base + noise, 0.0, 1.0)
			image.set_pixel(x, y, Color(c * 0.95, c * 0.9, c * 0.85))

	var texture := ImageTexture.create_from_image(image)
	return texture

# Текстура панельного дома (российская панелька)
# Имитирует бетонные панели с окнами
static func create_panel_building_texture(size: int = 512, floors: int = 5, windows_per_floor: int = 4) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99999

	var floor_height := size / floors
	var window_width := size / (windows_per_floor * 2)
	var window_height := floor_height / 2
	var window_margin_x := window_width / 2
	var window_margin_y := floor_height / 4

	# Цвета панелек (серый бетон с лёгким оттенком)
	var panel_colors := [
		Color(0.65, 0.63, 0.60),  # Серый
		Color(0.70, 0.68, 0.62),  # Светло-серый
		Color(0.60, 0.58, 0.55),  # Тёмно-серый
		Color(0.68, 0.65, 0.58),  # Бежево-серый
	]
	var panel_color: Color = panel_colors[rng.randi() % panel_colors.size()]

	for y in range(size):
		for x in range(size):
			# Базовый цвет панели с шумом
			var noise := rng.randf() * 0.05 - 0.025
			var color := Color(
				clamp(panel_color.r + noise, 0.0, 1.0),
				clamp(panel_color.g + noise, 0.0, 1.0),
				clamp(panel_color.b + noise, 0.0, 1.0)
			)

			# Швы между панелями (горизонтальные между этажами)
			var floor_pos := y % floor_height
			if floor_pos < 3:
				color = color.darkened(0.2)

			# Вертикальные швы между секциями
			var section_width := size / 2
			if x % section_width < 2:
				color = color.darkened(0.15)

			# Окна
			var floor_idx := y / floor_height
			var in_floor_y := y % floor_height
			var window_y_start := window_margin_y
			var window_y_end := window_margin_y + window_height

			if in_floor_y >= window_y_start and in_floor_y < window_y_end:
				for w in range(windows_per_floor):
					var window_x_start := window_margin_x + w * (window_width + window_margin_x)
					var window_x_end := window_x_start + window_width

					if x >= window_x_start and x < window_x_end:
						# Рама окна
						var in_window_x := x - window_x_start
						var in_window_y := in_floor_y - window_y_start
						var frame_size := 4

						if in_window_x < frame_size or in_window_x >= window_width - frame_size or \
						   in_window_y < frame_size or in_window_y >= window_height - frame_size:
							# Белая рама
							color = Color(0.9, 0.9, 0.88)
						else:
							# Стекло (тёмно-синее с отражением)
							var reflection := sin(float(in_window_x) * 0.3) * 0.1
							color = Color(0.15 + reflection, 0.2 + reflection, 0.35 + reflection)
							# Иногда свет в окне
							if rng.randf() < 0.1:
								color = Color(0.8, 0.7, 0.4)  # Тёплый свет

			# Балконы (на некоторых этажах)
			if floor_idx > 0 and floor_idx < floors - 1:
				var balcony_chance := 0.5
				var balcony_seed := floor_idx * 1000 + (x / (size / windows_per_floor))
				var balcony_rng := RandomNumberGenerator.new()
				balcony_rng.seed = balcony_seed
				if balcony_rng.randf() < balcony_chance:
					# Ограждение балкона под окном
					if in_floor_y >= window_y_end and in_floor_y < window_y_end + 15:
						for w in range(windows_per_floor):
							var window_x_start := window_margin_x + w * (window_width + window_margin_x)
							var window_x_end := window_x_start + window_width
							if x >= window_x_start - 5 and x < window_x_end + 5:
								# Металлическое ограждение
								if (x + y) % 8 < 2:
									color = Color(0.3, 0.3, 0.35)

			image.set_pixel(x, y, color)

	var texture := ImageTexture.create_from_image(image)
	return texture

# Текстура кирпичного дома (старый фонд)
static func create_brick_building_texture(size: int = 512, floors: int = 4, windows_per_floor: int = 3) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 88888

	var brick_width := 24
	var brick_height := 12
	var mortar := 2

	var floor_height := size / floors
	var window_width := size / (windows_per_floor * 2 + 1)
	var window_height := floor_height / 2
	var window_margin_x := window_width
	var window_margin_y := floor_height / 4

	for y in range(size):
		for x in range(size):
			# Кирпичная кладка
			var row := y / brick_height
			var offset := (row % 2) * (brick_width / 2)
			var bx := (x + offset) % brick_width
			var by := y % brick_height

			var is_mortar := bx < mortar or by < mortar

			var color: Color
			if is_mortar:
				var c := 0.5 + rng.randf() * 0.05
				color = Color(c, c * 0.95, c * 0.9)
			else:
				var base := 0.5 + rng.randf() * 0.15
				color = Color(base * 1.1, base * 0.45, base * 0.35)

			# Окна
			var floor_idx := y / floor_height
			var in_floor_y := y % floor_height
			var window_y_start := window_margin_y
			var window_y_end := window_margin_y + window_height

			if in_floor_y >= window_y_start and in_floor_y < window_y_end:
				for w in range(windows_per_floor):
					var window_x_start := window_margin_x + w * (window_width + window_margin_x)
					var window_x_end := window_x_start + window_width

					if x >= window_x_start and x < window_x_end:
						var in_window_x := x - window_x_start
						var in_window_y := in_floor_y - window_y_start
						var frame_size := 5

						if in_window_x < frame_size or in_window_x >= window_width - frame_size or \
						   in_window_y < frame_size or in_window_y >= window_height - frame_size:
							# Белая рама
							color = Color(0.85, 0.85, 0.8)
						else:
							# Стекло
							color = Color(0.2, 0.25, 0.4)
							if rng.randf() < 0.15:
								color = Color(0.75, 0.65, 0.35)

			image.set_pixel(x, y, color)

	var texture := ImageTexture.create_from_image(image)
	return texture

static func create_forest_texture(size: int = 256) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 88888

	for y in range(size):
		for x in range(size):
			var base_g := 0.3 + rng.randf() * 0.2
			var base_r := base_g * 0.4
			var base_b := base_g * 0.3
			image.set_pixel(x, y, Color(base_r, base_g, base_b))

	var texture := ImageTexture.create_from_image(image)
	return texture


# ============ NORMAL MAPS ============

# Генерирует normal map из height map (grayscale image)
static func _generate_normal_from_height(height_image: Image, strength: float = 1.0) -> Image:
	var size := height_image.get_width()
	var normal_image := Image.create(size, size, false, Image.FORMAT_RGB8)

	for y in range(size):
		for x in range(size):
			# Получаем соседние пиксели (с wrap-around)
			var left := height_image.get_pixel((x - 1 + size) % size, y).r
			var right := height_image.get_pixel((x + 1) % size, y).r
			var up := height_image.get_pixel(x, (y - 1 + size) % size).r
			var down := height_image.get_pixel(x, (y + 1) % size).r

			# Вычисляем нормаль из градиента высоты
			var dx := (left - right) * strength
			var dy := (up - down) * strength

			# Нормализуем вектор
			var normal := Vector3(dx, dy, 1.0).normalized()

			# Конвертируем из [-1,1] в [0,1] для хранения в текстуре
			var color := Color(
				normal.x * 0.5 + 0.5,
				normal.y * 0.5 + 0.5,
				normal.z * 0.5 + 0.5
			)
			normal_image.set_pixel(x, y, color)

	return normal_image


static func create_asphalt_normal(size: int = 256) -> ImageTexture:
	# Создаём height map для асфальта
	var height_image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	for y in range(size):
		for x in range(size):
			var height := 0.5 + rng.randf() * 0.15 - 0.075
			# Трещины
			if rng.randf() < 0.02:
				height -= 0.2
			height_image.set_pixel(x, y, Color(height, height, height))

	var normal_image := _generate_normal_from_height(height_image, 2.0)
	return ImageTexture.create_from_image(normal_image)


static func create_brick_normal(size: int = 256) -> ImageTexture:
	var height_image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11111

	var brick_width := 32
	var brick_height := 16
	var mortar := 2

	for y in range(size):
		for x in range(size):
			var row := y / brick_height
			var offset := (row % 2) * (brick_width / 2)
			var bx := (x + offset) % brick_width
			var by := y % brick_height

			var is_mortar := bx < mortar or by < mortar

			var height: float
			if is_mortar:
				height = 0.3  # Швы ниже
			else:
				height = 0.6 + rng.randf() * 0.1  # Кирпичи выше с вариацией

			height_image.set_pixel(x, y, Color(height, height, height))

	var normal_image := _generate_normal_from_height(height_image, 3.0)
	return ImageTexture.create_from_image(normal_image)


static func create_sidewalk_normal(size: int = 256) -> ImageTexture:
	var height_image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 34567

	for y in range(size):
		for x in range(size):
			# Мелкозернистая текстура светлого асфальта
			rng.seed = 34567 + x * 13 + y * 29
			var height := 0.5 + rng.randf() * 0.1 - 0.05
			# Мелкие неровности
			if rng.randf() < 0.03:
				height -= 0.08
			height_image.set_pixel(x, y, Color(height, height, height))

	var normal_image := _generate_normal_from_height(height_image, 1.5)
	return ImageTexture.create_from_image(normal_image)


static func create_concrete_normal(size: int = 256) -> ImageTexture:
	var height_image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 54321

	for y in range(size):
		for x in range(size):
			var height := 0.5 + rng.randf() * 0.08 - 0.04
			# Швы между плитами
			if x % 64 < 2 or y % 64 < 2:
				height = 0.3
			height_image.set_pixel(x, y, Color(height, height, height))

	var normal_image := _generate_normal_from_height(height_image, 2.0)
	return ImageTexture.create_from_image(normal_image)


static func create_panel_building_normal(size: int = 512, floors: int = 5, windows_per_floor: int = 4) -> ImageTexture:
	var height_image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99999

	var floor_height := size / floors
	var window_width := size / (windows_per_floor * 2)
	var window_height := floor_height / 2
	var window_margin_x := window_width / 2
	var window_margin_y := floor_height / 4

	for y in range(size):
		for x in range(size):
			var height := 0.5 + rng.randf() * 0.02

			# Швы между панелями (углубления)
			var floor_pos := y % floor_height
			if floor_pos < 3:
				height = 0.35

			var section_width := size / 2
			if x % section_width < 2:
				height = 0.38

			# Окна (углубления)
			var in_floor_y := y % floor_height
			var window_y_start := window_margin_y
			var window_y_end := window_margin_y + window_height

			if in_floor_y >= window_y_start and in_floor_y < window_y_end:
				for w in range(windows_per_floor):
					var window_x_start := window_margin_x + w * (window_width + window_margin_x)
					var window_x_end := window_x_start + window_width

					if x >= window_x_start and x < window_x_end:
						var in_window_x := x - window_x_start
						var in_window_y := in_floor_y - window_y_start
						var frame_size := 4

						if in_window_x < frame_size or in_window_x >= window_width - frame_size or \
						   in_window_y < frame_size or in_window_y >= window_height - frame_size:
							height = 0.55  # Рама выступает
						else:
							height = 0.25  # Стекло утоплено

			height_image.set_pixel(x, y, Color(height, height, height))

	var normal_image := _generate_normal_from_height(height_image, 2.5)
	return ImageTexture.create_from_image(normal_image)
