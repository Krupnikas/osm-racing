class_name BusinessSignGenerator

## Генератор 3D вывесок для заведений (кафе, магазины, больницы и т.д.)
## Создаёт процедурные вывески с Label3D текстом на цветном фоне

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
		Node3D с вывеской (Background + Label3D + Light)
	"""
	var sign_root = Node3D.new()
	sign_root.name = "BusinessSign"

	# Получаем тип и цвет
	var amenity_type = tags.get("amenity", tags.get("shop", ""))
	var sign_color = get_sign_color(amenity_type)
	var sign_text = get_sign_text(tags)

	if sign_text == "":
		return sign_root  # Пустая вывеска если нет текста

	# Вычисляем размер фона (компактный, под размер текста)
	var text_length = sign_text.length()
	var sign_width = max(2.0, text_length * 0.25)  # Компактная подложка
	var sign_height = 0.8  # Компактная высота

	# Масштабируем всю вывеску в 3 раза
	sign_root.scale = Vector3(3.0, 3.0, 3.0)

	# 1. Создаём фон
	var background = create_background_quad(sign_width, sign_height, sign_color)
	background.position.z = -0.1  # Чуть позади текста
	sign_root.add_child(background)

	# 2. Создаём текст
	var label = Label3D.new()
	label.text = sign_text
	label.font_size = 256  # ЗНАЧИТЕЛЬНО увеличили (было 128)
	label.modulate = Color(1, 1, 1)  # Белый текст
	label.outline_size = 12  # Увеличили (было 8)
	label.outline_modulate = Color(0, 0, 0)  # Чёрный контур
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = false  # Нормальная отрисовка с учетом глубины
	label.pixel_size = 0.001  # Ещё меньше = ещё больше текст (было 0.002)
	label.render_priority = 10  # Рисуется поверх обычных объектов
	label.alpha_cut = Label3D.ALPHA_CUT_DISABLED  # Без обрезки альфа-канала
	label.position.z = 0.2  # Выдвигаем текст дальше вперед (было 0.15)
	sign_root.add_child(label)

	# 3. Добавляем подсветку для ночи
	var light = OmniLight3D.new()
	light.light_energy = 1.5
	light.light_color = sign_color.lightened(0.3)
	light.omni_range = 8.0
	light.position.y = -0.2
	sign_root.add_child(light)

	return sign_root


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
