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
	"вкусно и точка": "vkusnoitochka.png",
	"вкусно — и точка": "vkusnoitochka.png",
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

# Цвета фонов по типу заведения
const SIGN_COLORS := {
	"restaurant": Color(0.8, 0.3, 0.2),  # Красно-коричневый
	"cafe": Color(0.6, 0.4, 0.2),        # Коричневый
	"fast_food": Color(0.9, 0.2, 0.2),   # Красный
	"bar": Color(0.3, 0.2, 0.5),         # Фиолетовый
	"pub": Color(0.4, 0.3, 0.2),         # Тёмно-коричневый
	"hospital": Color(0.95, 0.95, 0.95), # Белый
	"pharmacy": Color(0.2, 0.7, 0.3),    # Зелёный
	"bank": Color(0.3, 0.4, 0.6),        # Синий
	"shop": Color(0.2, 0.5, 0.8),        # Голубой (универсальный)
	"fuel": Color(0.9, 0.8, 0.2),        # Жёлтый
}

const DEFAULT_COLOR := Color(0.3, 0.3, 0.4)  # Серо-синий


static func create_sign(tags: Dictionary) -> Node3D:
	"""
	Создаёт 3D вывеску для заведения

	Args:
		tags: Словарь OSM тегов с amenity/shop и name

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

	# Масштабируем всю вывеску в 3 раза
	sign_root.scale = Vector3(3.0, 3.0, 3.0)

	# Проверяем, есть ли логотип для этого бренда
	var logo_file = _find_brand_logo(tags)

	if logo_file != "":
		# Создаём вывеску с логотипом
		_create_logo_sign(sign_root, logo_file, sign_color)
	else:
		# Создаём текстовую вывеску (старое поведение)
		_create_text_sign(sign_root, sign_text, sign_color)

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
					print("BusinessSign: Found logo (partial) for '%s' contains '%s' -> %s" % [name, brand_key, logo_path])
					return logo_path

	# Debug: показываем что не нашли
	if not names_to_check.is_empty():
		print("BusinessSign: No logo found for: %s" % str(names_to_check))

	return ""


static func _create_logo_sign(sign_root: Node3D, logo_path: String, sign_color: Color) -> void:
	"""Создаёт вывеску с логотипом"""
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
	var sign_height = 0.8  # Базовая высота
	var sign_width = sign_height * aspect_ratio

	# Ограничиваем максимальную ширину
	if sign_width > 4.0:
		sign_width = 4.0
		sign_height = sign_width / aspect_ratio

	# Создаём Sprite3D с логотипом
	var sprite = Sprite3D.new()
	sprite.texture = texture
	sprite.pixel_size = sign_height / tex_size.y  # Масштабируем по высоте
	sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	sprite.no_depth_test = false
	sprite.render_priority = 10
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD  # Прозрачные части обрезаются
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.position.z = 0.05  # Чуть впереди фона
	sign_root.add_child(sprite)

	# Опционально: добавляем полупрозрачный фон за логотипом
	# (закомментировано - логотипы обычно лучше смотрятся без фона)
	# var background = create_background_quad(sign_width + 0.2, sign_height + 0.1, Color(1, 1, 1, 0.9))
	# background.position.z = -0.05
	# sign_root.add_child(background)


static func _create_text_sign(sign_root: Node3D, sign_text: String, sign_color: Color) -> void:
	"""Создаёт текстовую вывеску (оригинальное поведение)"""
	# Вычисляем размер фона (компактный, под размер текста)
	var text_length = sign_text.length()
	var sign_width = max(2.0, text_length * 0.25)  # Компактная подложка
	var sign_height = 0.8  # Компактная высота

	# 1. Создаём фон
	var background = create_background_quad(sign_width, sign_height, sign_color)
	background.position.z = -0.1  # Чуть позади текста
	sign_root.add_child(background)

	# 2. Создаём текст
	var label = Label3D.new()
	label.text = sign_text
	label.font_size = 256
	label.modulate = Color(1, 1, 1)  # Белый текст
	label.outline_size = 12
	label.outline_modulate = Color(0, 0, 0)  # Чёрный контур
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = false
	label.pixel_size = 0.001
	label.render_priority = 10
	label.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	label.position.z = 0.2
	sign_root.add_child(label)


static func get_sign_color(amenity_type: String) -> Color:
	"""Определяет цвет фона вывески по типу заведения"""
	return SIGN_COLORS.get(amenity_type, DEFAULT_COLOR)


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
	"""Создаёт цветной прямоугольник-фон для вывески"""
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
