extends Control

## Спидометр в стиле NFS с круглой шкалой и стрелкой

@export var current_speed: float = 0.0  # В км/ч
@export var current_rpm: float = 0.0    # Обороты двигателя
@export var current_gear: String = "N"   # Текущая передача

# Константы для отрисовки (увеличиваем в 1.7 раза)
const GAUGE_RADIUS := 165.0
const GAUGE_CENTER := Vector2(210, 210)
const SCALE_START_ANGLE := 135.0  # Градусы (начало шкалы слева внизу)
const SCALE_END_ANGLE := 45.0     # Градусы (конец шкалы справа внизу)
const MAX_SPEED := 200.0          # Максимальная скорость на шкале (км/ч)

# Цвета
const COLOR_BG := Color(0.05, 0.05, 0.05, 0.9)
const COLOR_SCALE := Color(1, 1, 1, 0.8)
const COLOR_NUMBERS := Color(1, 1, 1, 1)
const COLOR_NEEDLE := Color(0.9, 0.1, 0.1, 1)
const COLOR_BLUE_RING := Color(0.2, 0.6, 1, 1)

# RPM gauge (маленький тахометр слева)
const RPM_RADIUS := 60.0
const RPM_CENTER := Vector2(80, 315)
const RPM_MAX := 8000.0

# Шрифты для текста
var _font_large: Font
var _font_medium: Font
var _font_small: Font

func _ready() -> void:
	print("Speedometer: _ready() called")
	# Устанавливаем размер (увеличиваем)
	custom_minimum_size = Vector2(450, 450)

	# Загружаем italic шрифт Roboto
	var italic_font := load("res://ui/fonts/Roboto-BoldItalic.ttf") as Font
	if italic_font:
		_font_large = italic_font
		_font_medium = italic_font
		_font_small = italic_font
		print("Speedometer: Roboto-BoldItalic font loaded")
	else:
		# Фоллбэк на системный шрифт
		_font_large = ThemeDB.fallback_font
		_font_medium = ThemeDB.fallback_font
		_font_small = ThemeDB.fallback_font
		print("Speedometer: Using fallback font")

	queue_redraw()
	print("Speedometer: setup complete")

func _draw() -> void:
	# Отрисовываем главный спидометр
	_draw_main_gauge()

	# Отрисовываем маленький тахометр
	_draw_rpm_gauge()

	# Отрисовываем панель с передачей и скоростью
	_draw_info_panel()

func _draw_main_gauge() -> void:
	# Синее кольцо сверху
	draw_arc(GAUGE_CENTER, GAUGE_RADIUS + 8, deg_to_rad(-100), deg_to_rad(-80), 32, COLOR_BLUE_RING, 12.0, true)

	# Фон спидометра
	draw_circle(GAUGE_CENTER, GAUGE_RADIUS + 5, COLOR_BG)

	# Рисуем деления и цифры шкалы
	for i in range(11):  # От 0 до 10
		var angle_deg: float = lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360.0, float(i) / 10.0)
		var angle_rad: float = deg_to_rad(angle_deg)

		# Длинное деление для каждой цифры
		var inner_point: Vector2 = GAUGE_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (GAUGE_RADIUS - 15)
		var outer_point: Vector2 = GAUGE_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (GAUGE_RADIUS - 5)
		draw_line(inner_point, outer_point, COLOR_SCALE, 2.0)

		# Рисуем цифры (0, 20, 40, ... 200 км/ч)
		if _font_small:
			var speed_value: int = i * 20
			var number_text: String = str(speed_value)
			var number_font_size: int = 16
			var text_size: Vector2 = _font_small.get_string_size(number_text, HORIZONTAL_ALIGNMENT_CENTER, -1, number_font_size)
			# Позиция текста дальше от центра (увеличили расстояние)
			var text_radius: float = GAUGE_RADIUS - 40
			var text_pos: Vector2 = GAUGE_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * text_radius
			# Центрируем текст
			text_pos -= text_size / 2.0
			draw_string(_font_small, text_pos, number_text, HORIZONTAL_ALIGNMENT_CENTER, -1, number_font_size, COLOR_NUMBERS)

		# Короткие деления между цифрами
		if i < 10:
			for j in range(1, 5):
				var next_angle_deg: float = lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360.0, float(i + 1) / 10.0)
				var sub_angle_deg: float = lerp(angle_deg, next_angle_deg, float(j) / 5.0)
				var sub_angle_rad: float = deg_to_rad(sub_angle_deg)
				var sub_inner: Vector2 = GAUGE_CENTER + Vector2(cos(sub_angle_rad), sin(sub_angle_rad)) * (GAUGE_RADIUS - 10)
				var sub_outer: Vector2 = GAUGE_CENTER + Vector2(cos(sub_angle_rad), sin(sub_angle_rad)) * (GAUGE_RADIUS - 5)
				draw_line(sub_inner, sub_outer, COLOR_SCALE, 1.0)

	# Красная зона (9-10)
	var red_start: float = deg_to_rad(lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360.0, 9.0 / 10.0))
	var red_end: float = deg_to_rad(lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360.0, 10.0 / 10.0))
	draw_arc(GAUGE_CENTER, GAUGE_RADIUS - 7, red_start, red_end, 32, Color(1, 0, 0, 0.6), 8.0, true)

	# Стрелка спидометра
	var speed_ratio: float = clamp(current_speed / MAX_SPEED, 0.0, 1.0)
	var needle_angle_deg: float = lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360.0, speed_ratio)
	var needle_angle_rad: float = deg_to_rad(needle_angle_deg)

	# Точка стрелки
	var needle_tip: Vector2 = GAUGE_CENTER + Vector2(cos(needle_angle_rad), sin(needle_angle_rad)) * (GAUGE_RADIUS - 20)
	var needle_base_left: Vector2 = GAUGE_CENTER + Vector2(cos(needle_angle_rad + PI/2), sin(needle_angle_rad + PI/2)) * 4
	var needle_base_right: Vector2 = GAUGE_CENTER + Vector2(cos(needle_angle_rad - PI/2), sin(needle_angle_rad - PI/2)) * 4

	# Рисуем стрелку как треугольник
	var needle_points := PackedVector2Array([needle_tip, needle_base_left, needle_base_right])
	draw_colored_polygon(needle_points, COLOR_NEEDLE)

	# Центральный круг
	draw_circle(GAUGE_CENTER, 6, COLOR_NEEDLE)

func _draw_rpm_gauge() -> void:
	# Фон тахометра
	draw_circle(RPM_CENTER, RPM_RADIUS + 3, COLOR_BG)

	# Шкала тахометра
	var rpm_start_angle: float = 150.0
	var rpm_end_angle: float = 30.0

	# Деления
	for i in range(9):  # 0, 1, 2... 8 (x1000 RPM)
		var angle_deg: float = lerp(rpm_start_angle, rpm_end_angle + 360.0, float(i) / 8.0)
		var angle_rad: float = deg_to_rad(angle_deg)

		var inner: Vector2 = RPM_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (RPM_RADIUS - 8)
		var outer: Vector2 = RPM_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (RPM_RADIUS - 2)
		draw_line(inner, outer, COLOR_SCALE, 1.5)

	# Красная зона (6-8)
	var rpm_red_start: float = deg_to_rad(lerp(rpm_start_angle, rpm_end_angle + 360.0, 6.0 / 8.0))
	var rpm_red_end: float = deg_to_rad(lerp(rpm_start_angle, rpm_end_angle + 360.0, 8.0 / 8.0))
	draw_arc(RPM_CENTER, RPM_RADIUS - 4, rpm_red_start, rpm_red_end, 16, Color(1, 0, 0, 0.6), 5.0, true)

	# Стрелка тахометра
	var rpm_ratio: float = clamp(current_rpm / RPM_MAX, 0.0, 1.0)
	var rpm_needle_angle_deg: float = lerp(rpm_start_angle, rpm_end_angle + 360.0, rpm_ratio)
	var rpm_needle_angle_rad: float = deg_to_rad(rpm_needle_angle_deg)

	var rpm_needle_tip: Vector2 = RPM_CENTER + Vector2(cos(rpm_needle_angle_rad), sin(rpm_needle_angle_rad)) * (RPM_RADIUS - 12)
	draw_line(RPM_CENTER, rpm_needle_tip, COLOR_NEEDLE, 2.0)
	draw_circle(RPM_CENTER, 3, COLOR_NEEDLE)

func _draw_info_panel() -> void:
	# Панель в стиле NFS - две узкие подложки
	# Выравниваем по правому краю
	var panel_right_edge: float = 310.0  # Правый край плашек (ещё левее)
	var base_y: float = GAUGE_CENTER.y - 70.0

	if _font_large:
		# === ПЕРЕДАЧА ===
		var gear_text: String = current_gear
		var gear_font_size: int = 54  # Уменьшили с 64
		# Вычисляем размер текста для подложки
		var gear_size: Vector2 = _font_large.get_string_size(gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, gear_font_size)
		var gear_panel_size: Vector2 = Vector2(gear_size.x + 20, gear_size.y + 15)
		# Позиционируем от правого края
		var gear_panel_pos: Vector2 = Vector2(panel_right_edge - gear_panel_size.x, base_y)

		# Подложка для передачи
		draw_rect(Rect2(gear_panel_pos, gear_panel_size), Color(0.2, 0.2, 0.2, 0.85))

		# Белый треугольник слева от подложки передачи
		var triangle_center: Vector2 = gear_panel_pos + Vector2(-8, gear_panel_size.y / 2.0)
		var triangle_points := PackedVector2Array([
			triangle_center,
			triangle_center + Vector2(8, -5),
			triangle_center + Vector2(8, 5)
		])
		draw_colored_polygon(triangle_points, Color(1, 1, 1, 1))

		# Текст передачи (italic шрифт)
		var gear_x: float = gear_panel_pos.x + 10
		var gear_y: float = gear_panel_pos.y + gear_size.y + 5
		draw_string(_font_large, Vector2(gear_x, gear_y), gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, gear_font_size, Color.WHITE)

		# === СКОРОСТЬ ===
		var speed_text: String = "%03d" % int(current_speed)
		var speed_font_size: int = 38  # Уменьшили с 44
		var speed_size: Vector2 = _font_medium.get_string_size(speed_text, HORIZONTAL_ALIGNMENT_LEFT, -1, speed_font_size)
		var speed_panel_size: Vector2 = Vector2(speed_size.x + 20, speed_size.y + 12)
		# Позиционируем от правого края (та же линия что и передача)
		var speed_panel_pos: Vector2 = Vector2(panel_right_edge - speed_panel_size.x, base_y + gear_panel_size.y + 10)

		# Подложка для скорости
		draw_rect(Rect2(speed_panel_pos, speed_panel_size), Color(0.2, 0.2, 0.2, 0.85))

		# Текст скорости (italic шрифт)
		var speed_x: float = speed_panel_pos.x + 10
		var speed_y: float = speed_panel_pos.y + speed_size.y + 4
		draw_string(_font_medium, Vector2(speed_x, speed_y), speed_text, HORIZONTAL_ALIGNMENT_LEFT, -1, speed_font_size, Color.WHITE)

		# === KM/H (БЕЗ ПОДЛОЖКИ) ===
		var kmh_text: String = "KM/H"
		var kmh_font_size: int = 18  # Уменьшили с 20
		var kmh_size: Vector2 = _font_small.get_string_size(kmh_text, HORIZONTAL_ALIGNMENT_LEFT, -1, kmh_font_size)
		# Центрируем KM/H под плашкой скорости
		var kmh_x: float = speed_panel_pos.x + (speed_panel_size.x - kmh_size.x) / 2.0
		var kmh_y: float = speed_panel_pos.y + speed_panel_size.y + kmh_size.y + 8

		# KM/H без подложки (italic шрифт)
		draw_string(_font_small, Vector2(kmh_x, kmh_y), kmh_text, HORIZONTAL_ALIGNMENT_LEFT, -1, kmh_font_size, Color(0.8, 0.8, 0.8))

func update_values(speed: float, rpm: float, gear: String) -> void:
	current_speed = speed
	current_rpm = rpm
	current_gear = gear
	queue_redraw()  # Перерисовываем при обновлении значений
