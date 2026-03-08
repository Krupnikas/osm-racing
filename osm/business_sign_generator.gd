class_name BusinessSignGenerator

## Генератор 3D вывесок для заведений (кафе, магазины, больницы и т.д.)
## Создаёт процедурные вывески с Label3D текстом на цветном фоне
## Для известных брендов использует логотипы вместо текста

# Путь к папке с логотипами брендов
const BRAND_LOGOS_PATH := "res://textures/brand_logos/"

# Словарь соответствия названий брендов и файлов логотипов
# Ключ: название бренда в нижнем регистре (или часть названия)
# Значение: имя файла логотипа (без пути)
const BRAND_LOGOS := {
	# Продуктовые сети
	"пятёрочка": "pyaterochka.png",
	"пятерочка": "pyaterochka.png",
	"pyaterochka": "pyaterochka.png",
	"5ка": "pyaterochka.png",
	"магнит": "magnit.png",
	"magnit": "magnit.png",
	"fix price": "fixprice.png",
	"fixprice": "fixprice.png",
	"фикс прайс": "fixprice.png",
	"северный градус": "severniy-gradus.png",

	# Маркетплейсы
	"ozon": "ozon.png",
	"озон": "ozon.png",
	"wildberries": "wildberries.png",
	"вайлдберриз": "wildberries.png",
	"wb": "wildberries.png",

	# Техника
	"dns": "dns.png",
	"днс": "dns.png",

	# Банки
	"сбербанк": "sberbank.png",
	"сбер": "sberbank.png",
	"sberbank": "sberbank.png",
	"sber": "sberbank.png",
	"втб": "vtb.png",
	"vtb": "vtb.png",
	"альфа-банк": "alfabank.png",
	"альфа банк": "alfabank.png",
	"alfabank": "alfabank.png",
	"alfa-bank": "alfabank.png",
	"тинькофф": "tinkoff.png",
	"тинькоф": "tinkoff.png",
	"tinkoff": "tinkoff.png",
	"т-банк": "tinkoff.png",
	"райффайзен": "raiffeisen.png",
	"raiffeisen": "raiffeisen.png",

	# Связь
	"мтс": "mts.png",
	"mts": "mts.png",
	"билайн": "beeline.png",
	"beeline": "beeline.png",
	"мегафон": "megafon.png",
	"megafon": "megafon.png",

	# Заправки
	"газпром": "gazprom.png",
	"gazprom": "gazprom.png",
	"газпромнефть": "gazprom.png",
	"лукойл": "lukoil.png",
	"lukoil": "lukoil.png",
	"роснефть": "rosneft.png",
	"rosneft": "rosneft.png",

	# Фастфуд
	"burger king": "burgerking.png",
	"бургер кинг": "burgerking.png",
	"вкусно и точка": "mcdonalds-russia.png",
	"вкусно — и точка": "mcdonalds-russia.png",
	"vkusno i tochka": "mcdonalds-russia.png",
	"rostic's": "rostics.png",
	"rostics": "rostics.png",
	"ростикс": "rostics.png",
	"kfc": "kfc.png",
	"кфс": "kfc.png",
	"mcdonalds": "mcdonalds.png",
	"mcdonald's": "mcdonalds.png",
	"макдоналдс": "mcdonalds.png",
	"starbucks": "starbucks.png",
	"старбакс": "starbucks.png",
}

# Кэш загруженных текстур логотипов
static var _logo_cache: Dictionary = {}

# Шрифт для аптек (Roboto Slab Bold)
static var _pharmacy_font: Font = null

# Цвета фонов по типу заведения
const SIGN_COLORS := {
	"restaurant": Color(0.8, 0.3, 0.2),  # Красно-коричневый
	"cafe": Color(0.6, 0.4, 0.2),        # Коричневый
	"fast_food": Color(0.9, 0.2, 0.2),   # Красный
	"bar": Color(0.3, 0.2, 0.5),         # Фиолетовый
	"pub": Color(0.4, 0.3, 0.2),         # Тёмно-коричневый
	"hospital": Color(0.95, 0.95, 0.95), # Белый
	"pharmacy": Color(0.95, 0.95, 0.95), # Белый
	"bank": Color(0.3, 0.4, 0.6),        # Синий
	"shop": Color(0.2, 0.5, 0.8),        # Голубой (универсальный)
	"fuel": Color(0.9, 0.8, 0.2),        # Жёлтый
}

const DEFAULT_COLOR := Color(0.3, 0.3, 0.4)  # Серо-синий

# Цвета текста по типу заведения (контрастные к светлому фону)
const TEXT_COLORS := {
	"pharmacy": Color(0.5, 0.1, 0.1),      # Тёмно-красный для аптек
	"shop": Color(0.2, 0.3, 0.6),          # Синий для магазинов
	"supermarket": Color(0.2, 0.3, 0.6),   # Синий
	"convenience": Color(0.2, 0.3, 0.6),   # Синий
}
const DEFAULT_TEXT_COLOR := Color(0.15, 0.45, 0.25)  # Зелёный для прочих

# Параметры вывесок
const SIGN_PADDING_H := 0.15  # Горизонтальный отступ (gap) по бокам
const SIGN_PADDING_V := 0.08  # Вертикальный отступ сверху/снизу
const SIGN_THICKNESS := 0.06  # Толщина вывески (глубина)
const SIGN_BACKGROUND_COLOR := Color(1.0, 1.0, 1.0)  # Чисто белый фон для текста
const LOGO_BACKGROUND_COLOR := Color(1.0, 1.0, 0.98)  # Почти белый для логотипов

# Кастомные цвета фона для конкретных логотипов
const BRAND_BACKGROUND_COLORS := {
	"mcdonalds-russia.png": Color(0.486, 0.306, 0.227),  # #7C4E3A
}

# Цвета для диагональных полос Ozon
const OZON_STRIPE_COLOR_1 := Color(0.22, 0.47, 0.87)  # Синий
const OZON_STRIPE_COLOR_2 := Color(0.85, 0.2, 0.5)    # Малиновый/розовый


static func create_sign(tags: Dictionary, max_width: float = 4.0) -> Node3D:
	"""
	Создаёт 3D вывеску для заведения

	Args:
		tags: Словарь OSM тегов с amenity/shop и name
		max_width: Максимальная ширина вывески в метрах (до масштабирования)

	Returns:
		Node3D с вывеской (Logo/Label3D + опционально фон + Light)
	"""
	var sign_root = Node3D.new()
	sign_root.name = "BusinessSign"

	# Получаем тип и цвет
	var amenity_type = tags.get("amenity", tags.get("shop", ""))
	var sign_color = get_sign_color(amenity_type)
	var sign_text = get_sign_text(tags)

	if sign_text == "":
		return sign_root  # Пустая вывеска если нет текста

	# Масштабируем всю вывеску (3.3 = базовые 3.0 + 10%)
	sign_root.scale = Vector3(3.3, 3.3, 3.3)

	# Проверяем, есть ли логотип для этого бренда
	var logo_file = _find_brand_logo(tags)

	if logo_file != "":
		# Создаём вывеску с логотипом
		_create_logo_sign(sign_root, logo_file, sign_color, max_width)
	else:
		# Создаём текстовую вывеску с объёмным текстом
		_create_text_sign(sign_root, sign_text, sign_color, max_width, amenity_type)

	# Добавляем подсветку для ночи
	var light = OmniLight3D.new()
	light.light_energy = 1.5
	light.light_color = sign_color.lightened(0.3)
	light.omni_range = 8.0
	light.position.y = -0.2
	sign_root.add_child(light)

	return sign_root


static func _find_brand_logo(tags: Dictionary) -> String:
	"""
	Ищет логотип для бренда по тегам OSM.
	Проверяет name и brand теги.

	Returns:
		Путь к файлу логотипа или пустую строку
	"""
	# Собираем все возможные названия для поиска
	var names_to_check: Array = []

	if tags.has("name"):
		names_to_check.append(str(tags.get("name")).to_lower())
	if tags.has("brand"):
		names_to_check.append(str(tags.get("brand")).to_lower())

	# Ищем совпадение в словаре брендов
	for name in names_to_check:
		# Точное совпадение
		if BRAND_LOGOS.has(name):
			var logo_path = BRAND_LOGOS_PATH + BRAND_LOGOS[name]
			if ResourceLoader.exists(logo_path):
				print("BusinessSign: Found logo for '%s' -> %s" % [name, logo_path])
				return logo_path

		# Частичное совпадение (бренд содержится в названии)
		for brand_key in BRAND_LOGOS.keys():
			if name.contains(brand_key):
				var logo_path = BRAND_LOGOS_PATH + BRAND_LOGOS[brand_key]
				if ResourceLoader.exists(logo_path):
					print("BusinessSign: Found logo for '%s' (matched '%s') -> %s" % [name, brand_key, logo_path])
					return logo_path

	return ""


static func _create_logo_sign(sign_root: Node3D, logo_path: String, sign_color: Color, max_width: float = 4.0) -> void:
	"""Создаёт вывеску с логотипом на белой подложке"""
	# Загружаем текстуру логотипа (с кэшированием)
	var texture: Texture2D
	if _logo_cache.has(logo_path):
		texture = _logo_cache[logo_path]
	else:
		texture = load(logo_path)
		if texture:
			_logo_cache[logo_path] = texture

	if not texture:
		push_warning("BusinessSign: Failed to load logo: " + logo_path)
		return

	# Вычисляем размер вывески на основе пропорций логотипа
	var tex_size = texture.get_size()
	var aspect_ratio = tex_size.x / tex_size.y
	var logo_height = 0.7  # Базовая высота логотипа
	var logo_width = logo_height * aspect_ratio

	# Ограничиваем максимальную ширину
	if logo_width > max_width - SIGN_PADDING_H * 2:
		logo_width = max_width - SIGN_PADDING_H * 2
		logo_height = logo_width / aspect_ratio

	# Размер подложки = размер логотипа + отступы
	var sign_width = logo_width + SIGN_PADDING_H * 2
	var sign_height = logo_height + SIGN_PADDING_V * 2

	# 1. Создаём подложку (для Ozon - с диагональными полосами, для брендов - кастомный цвет)
	var background: MeshInstance3D
	var logo_file := logo_path.get_file()
	if logo_path.contains("ozon"):
		background = create_ozon_striped_box(sign_width, sign_height, SIGN_THICKNESS)
	elif BRAND_BACKGROUND_COLORS.has(logo_file):
		background = create_background_box(sign_width, sign_height, SIGN_THICKNESS, BRAND_BACKGROUND_COLORS[logo_file])
	else:
		background = create_background_box(sign_width, sign_height, SIGN_THICKNESS, LOGO_BACKGROUND_COLOR)
	background.position.z = -SIGN_THICKNESS / 2
	sign_root.add_child(background)

	# 2. Создаём Sprite3D с логотипом
	var sprite = Sprite3D.new()
	sprite.texture = texture
	sprite.pixel_size = logo_height / tex_size.y  # Масштабируем по высоте
	sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	sprite.no_depth_test = false
	sprite.render_priority = 10
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD  # Прозрачные части обрезаются
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.position.z = 0.04  # Чуть впереди подложки
	sign_root.add_child(sprite)


static func _create_text_sign(sign_root: Node3D, sign_text: String, sign_color: Color, max_width: float = 4.0, amenity_type: String = "") -> void:
	"""Создаёт текстовую вывеску с объёмным текстом на светлой подложке"""
	var font_size := 256
	var pixel_size := 0.001

	# Для аптек используем Roboto Slab Bold
	var font: Font = ThemeDB.fallback_font
	if amenity_type == "pharmacy":
		if _pharmacy_font == null:
			_pharmacy_font = load("res://ui/fonts/RobotoSlab-Bold.ttf")
		if _pharmacy_font:
			font = _pharmacy_font

	var text_size_px: Vector2 = font.get_string_size(sign_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)

	# Переводим пиксели в метры
	var text_width: float = text_size_px.x * pixel_size
	var text_height: float = text_size_px.y * pixel_size

	# Для аптек добавляем место под красный плюс слева
	var plus_width: float = 0.0
	var plus_gap: float = 0.0
	if amenity_type == "pharmacy":
		var plus_size_px: Vector2 = font.get_string_size("+", HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		plus_width = plus_size_px.x * pixel_size
		plus_gap = 0.04  # Отступ между плюсом и текстом

	# Размер подложки = размер текста + отступы (+ плюс для аптек)
	var padding_h: float = 0.08
	var padding_v: float = 0.05
	var total_content_width: float = text_width + plus_width + plus_gap
	var desired_sign_width: float = total_content_width + padding_h * 2
	var sign_width: float = clampf(desired_sign_width, 0.5, max_width)
	var sign_height: float = text_height + padding_v * 2

	# Если ширина была ограничена, масштабируем текст
	var text_scale: float = 1.0
	if desired_sign_width > max_width:
		text_scale = (max_width - padding_h * 2) / total_content_width
		sign_height = text_height * text_scale + padding_v * 2

	# 1. Создаём объёмную светлую подложку
	var background = create_background_box(sign_width, sign_height, SIGN_THICKNESS, SIGN_BACKGROUND_COLOR)
	background.position.z = -SIGN_THICKNESS / 2  # Центрируем по толщине
	sign_root.add_child(background)

	# 2. Создаём объёмный текст с цветом по типу заведения
	var text_color = get_text_color(amenity_type)

	# Для аптек добавляем красный плюс слева
	var text_offset_x: float = 0.0
	if amenity_type == "pharmacy" and _pharmacy_font:
		var plus_label = Label3D.new()
		plus_label.text = "+"
		plus_label.font = _pharmacy_font
		plus_label.font_size = 256
		plus_label.modulate = Color(0.85, 0.1, 0.1)  # Ярко-красный
		plus_label.outline_size = int(12 * text_scale)
		plus_label.outline_modulate = Color(0.5, 0.0, 0.0)  # Тёмно-красный контур
		plus_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		plus_label.no_depth_test = false
		plus_label.pixel_size = 0.001 * text_scale
		plus_label.render_priority = 10
		plus_label.alpha_cut = Label3D.ALPHA_CUT_DISABLED
		plus_label.position.z = 0.04
		# Позиционируем плюс слева от центра
		plus_label.position.x = -(text_width * text_scale / 2.0 + plus_gap * text_scale)
		sign_root.add_child(plus_label)
		# Сдвигаем основной текст вправо
		text_offset_x = (plus_width * text_scale + plus_gap * text_scale) / 2.0

	var label = Label3D.new()
	label.text = sign_text
	label.font_size = 256
	# Для аптек используем Roboto Slab Bold
	if amenity_type == "pharmacy" and _pharmacy_font:
		label.font = _pharmacy_font
	label.modulate = text_color  # Цвет текста по типу заведения
	label.outline_size = int(8 * text_scale)
	label.outline_modulate = text_color.darkened(0.3)  # Контур чуть темнее
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = false
	label.pixel_size = 0.001 * text_scale  # Масштабируем текст если нужно
	label.render_priority = 10
	label.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	label.position.z = 0.04  # Чуть впереди подложки
	label.position.x = text_offset_x  # Сдвиг для аптек
	sign_root.add_child(label)


static func get_sign_color(amenity_type: String) -> Color:
	"""Определяет цвет фона вывески по типу заведения (для свечения)"""
	return SIGN_COLORS.get(amenity_type, DEFAULT_COLOR)


static func get_text_color(amenity_type: String) -> Color:
	"""Определяет цвет текста по типу заведения (контрастный к светлому фону)"""
	return TEXT_COLORS.get(amenity_type, DEFAULT_TEXT_COLOR)


static func get_sign_text(tags: Dictionary) -> String:
	"""
	Извлекает текст вывески из OSM тегов
	Приоритет: name > brand > тип заведения
	"""
	# Приоритет: name > brand > тип заведения
	if tags.has("name"):
		var name = str(tags.get("name"))
		# Ограничиваем длину (макс 30 символов)
		if name.length() > 30:
			name = name.substr(0, 27) + "..."
		return name.to_upper()

	if tags.has("brand"):
		return str(tags.get("brand")).to_upper()

	# Fallback - название типа
	if tags.has("amenity"):
		return _amenity_to_text(str(tags.get("amenity")))

	if tags.has("shop"):
		return _shop_to_text(str(tags.get("shop")))

	return ""


static func create_background_quad(width: float, height: float, color: Color) -> MeshInstance3D:
	"""Создаёт цветной прямоугольник-фон для вывески (плоский, deprecated)"""
	var mesh_instance = MeshInstance3D.new()

	# Создаём QuadMesh
	var quad = QuadMesh.new()
	quad.size = Vector2(width, height)
	mesh_instance.mesh = quad

	# Создаём материал с цветом
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color * 0.3  # Лёгкое свечение
	material.emission_energy_multiplier = 1.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Видно с обеих сторон

	mesh_instance.material_override = material

	return mesh_instance


static func create_background_box(width: float, height: float, depth: float, color: Color) -> MeshInstance3D:
	"""Создаёт объёмную подложку для вывески (box с толщиной)"""
	var mesh_instance = MeshInstance3D.new()

	# Создаём BoxMesh с толщиной
	var box = BoxMesh.new()
	box.size = Vector3(width, height, depth)
	mesh_instance.mesh = box

	# Создаём материал
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color * 0.15  # Лёгкое свечение
	material.emission_energy_multiplier = 0.5
	material.roughness = 0.3
	material.metallic = 0.0

	mesh_instance.material_override = material

	return mesh_instance


static func create_ozon_striped_box(width: float, height: float, depth: float) -> MeshInstance3D:
	"""Создаёт подложку с диагональными полосами для Ozon"""
	var mesh_instance = MeshInstance3D.new()

	# Создаём BoxMesh
	var box = BoxMesh.new()
	box.size = Vector3(width, height, depth)
	mesh_instance.mesh = box

	# Загружаем шейдер с полосами
	var shader = load("res://shaders/ozon_stripes.gdshader")
	if shader:
		var material = ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("color1", Vector3(OZON_STRIPE_COLOR_1.r, OZON_STRIPE_COLOR_1.g, OZON_STRIPE_COLOR_1.b))
		material.set_shader_parameter("color2", Vector3(OZON_STRIPE_COLOR_2.r, OZON_STRIPE_COLOR_2.g, OZON_STRIPE_COLOR_2.b))
		material.set_shader_parameter("stripe_width", 0.12)
		material.set_shader_parameter("angle", 45.0)
		mesh_instance.material_override = material
	else:
		# Fallback на обычный материал
		var material = StandardMaterial3D.new()
		material.albedo_color = OZON_STRIPE_COLOR_1
		mesh_instance.material_override = material

	return mesh_instance


static func _amenity_to_text(amenity: String) -> String:
	"""Преобразует amenity тег в русский текст"""
	var names = {
		"restaurant": "РЕСТОРАН",
		"cafe": "КАФЕ",
		"fast_food": "ФАСТФУД",
		"bar": "БАР",
		"pub": "ПАБ",
		"hospital": "БОЛЬНИЦА",
		"pharmacy": "АПТЕКА",
		"bank": "БАНК",
		"fuel": "АЗС",
		"police": "ПОЛИЦИЯ",
	}
	return names.get(amenity, amenity.to_upper())


static func _shop_to_text(shop: String) -> String:
	"""Преобразует shop тег в русский текст"""
	var names = {
		"supermarket": "СУПЕРМАРКЕТ",
		"convenience": "МАГАЗИН",
		"bakery": "БУЛОЧНАЯ",
		"butcher": "МЯСНАЯ",
		"clothes": "ОДЕЖДА",
	}
	return names.get(shop, "МАГАЗИН")
