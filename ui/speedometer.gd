extends Control

## Спидометр в стиле NFS с круглой шкалой и стрелкой

@export var current_speed: float = 0.0  # В MPH
@export var current_rpm: float = 0.0    # Обороты двигателя
@export var current_gear: String = "N"   # Текущая передача

# Константы для отрисовки (увеличиваем в 1.5 раза)
const GAUGE_RADIUS := 140.0
const GAUGE_CENTER := Vector2(180, 180)
const SCALE_START_ANGLE := 135.0  # Градусы (начало шкалы слева внизу)
const SCALE_END_ANGLE := 45.0     # Градусы (конец шкалы справа внизу)
const MAX_SPEED := 200.0          # Максимальная скорость на шкале (MPH)

# Цвета
const COLOR_BG := Color(0.05, 0.05, 0.05, 0.9)
const COLOR_SCALE := Color(1, 1, 1, 0.8)
const COLOR_NUMBERS := Color(1, 1, 1, 1)
const COLOR_NEEDLE := Color(0.9, 0.1, 0.1, 1)
const COLOR_BLUE_RING := Color(0.2, 0.6, 1, 1)

# RPM gauge (маленький тахометр слева)
const RPM_RADIUS := 50.0
const RPM_CENTER := Vector2(70, 270)
const RPM_MAX := 8000.0

# Label узлы для текста
var _gear_label: Label
var _speed_label: Label
var _mph_label: Label

func _ready() -> void:
	print("Speedometer: _ready() called")
	# Устанавливаем размер (увеличиваем)
	custom_minimum_size = Vector2(380, 380)

	# Создаём Label для передачи (выравниваем по центру панели)
	_gear_label = Label.new()
	_gear_label.position = Vector2(330, 100)
	_gear_label.add_theme_font_size_override("font_size", 48)
	_gear_label.add_theme_color_override("font_color", Color.WHITE)
	_gear_label.text = "N"
	add_child(_gear_label)

	# Создаём Label для скорости (выравниваем по центру панели)
	_speed_label = Label.new()
	_speed_label.position = Vector2(318, 160)
	_speed_label.add_theme_font_size_override("font_size", 32)
	_speed_label.add_theme_color_override("font_color", Color.WHITE)
	_speed_label.text = "000"
	add_child(_speed_label)

	# Создаём Label для MPH (выравниваем по центру панели)
	_mph_label = Label.new()
	_mph_label.position = Vector2(325, 195)
	_mph_label.add_theme_font_size_override("font_size", 16)
	_mph_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_mph_label.text = "MPH"
	add_child(_mph_label)

	queue_redraw()
	print("Speedometer: setup complete")

func _draw() -> void:
	print("Speedometer: _draw() called")

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
	# Серая панель для передачи и скорости (увеличиваем и выравниваем)
	var panel_pos: Vector2 = Vector2(GAUGE_CENTER.x + GAUGE_RADIUS + 20, GAUGE_CENTER.y - 70)
	var panel_size: Vector2 = Vector2(90, 140)

	# Фон панели
	draw_rect(Rect2(panel_pos, panel_size), Color(0.2, 0.2, 0.2, 0.85))

	# Белый треугольник (индикатор) - указывает на передачу
	var triangle_center: Vector2 = panel_pos + Vector2(-10, 45)
	var triangle_points := PackedVector2Array([
		triangle_center,
		triangle_center + Vector2(10, -6),
		triangle_center + Vector2(10, 6)
	])
	draw_colored_polygon(triangle_points, Color(1, 1, 1, 1))

func update_values(speed: float, rpm: float, gear: String) -> void:
	current_speed = speed
	current_rpm = rpm
	current_gear = gear

	# Обновляем текст в Label'ах
	if _gear_label:
		_gear_label.text = gear
	if _speed_label:
		_speed_label.text = "%03d" % int(speed)

	queue_redraw()  # Перерисовываем при обновлении значений
