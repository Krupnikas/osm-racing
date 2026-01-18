extends Control

## Спидометр в стиле NFS с круглой шкалой и стрелкой

@export var current_speed: float = 0.0  # В MPH
@export var current_rpm: float = 0.0    # Обороты двигателя
@export var current_gear: String = "N"   # Текущая передача

# Константы для отрисовки
const GAUGE_RADIUS := 100.0
const GAUGE_CENTER := Vector2(130, 130)
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
const RPM_RADIUS := 35.0
const RPM_CENTER := Vector2(50, 195)
const RPM_MAX := 8000.0

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

	# Надпись NFS
	draw_string(ThemeDB.fallback_font, GAUGE_CENTER + Vector2(-15, -75), "NFS", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, COLOR_BLUE_RING)

	# Фон спидометра
	draw_circle(GAUGE_CENTER, GAUGE_RADIUS + 5, COLOR_BG)

	# Рисуем деления и цифры шкалы
	for i in range(11):  # От 0 до 10
		var angle_deg := lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360, i / 10.0)
		var angle_rad := deg_to_rad(angle_deg)

		# Длинное деление для каждой цифры
		var inner_point := GAUGE_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (GAUGE_RADIUS - 15)
		var outer_point := GAUGE_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (GAUGE_RADIUS - 5)
		draw_line(inner_point, outer_point, COLOR_SCALE, 2.0)

		# Цифры
		var number_pos := GAUGE_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (GAUGE_RADIUS - 30)
		draw_string(ThemeDB.fallback_font, number_pos - Vector2(5, -5), str(i), HORIZONTAL_ALIGNMENT_CENTER, -1, 16, COLOR_NUMBERS)

		# Короткие деления между цифрами
		if i < 10:
			for j in range(1, 5):
				var sub_angle_deg := lerp(angle_deg, lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360, (i + 1) / 10.0), j / 5.0)
				var sub_angle_rad := deg_to_rad(sub_angle_deg)
				var sub_inner := GAUGE_CENTER + Vector2(cos(sub_angle_rad), sin(sub_angle_rad)) * (GAUGE_RADIUS - 10)
				var sub_outer := GAUGE_CENTER + Vector2(cos(sub_angle_rad), sin(sub_angle_rad)) * (GAUGE_RADIUS - 5)
				draw_line(sub_inner, sub_outer, COLOR_SCALE, 1.0)

	# Красная зона (9-10)
	var red_start := deg_to_rad(lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360, 9.0 / 10.0))
	var red_end := deg_to_rad(lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360, 10.0 / 10.0))
	draw_arc(GAUGE_CENTER, GAUGE_RADIUS - 7, red_start, red_end, 32, Color(1, 0, 0, 0.6), 8.0, true)

	# Стрелка спидометра
	var speed_ratio := clamp(current_speed / MAX_SPEED, 0.0, 1.0)
	var needle_angle_deg := lerp(SCALE_START_ANGLE, SCALE_END_ANGLE + 360, speed_ratio)
	var needle_angle_rad := deg_to_rad(needle_angle_deg)

	# Точка стрелки
	var needle_tip := GAUGE_CENTER + Vector2(cos(needle_angle_rad), sin(needle_angle_rad)) * (GAUGE_RADIUS - 20)
	var needle_base_left := GAUGE_CENTER + Vector2(cos(needle_angle_rad + PI/2), sin(needle_angle_rad + PI/2)) * 4
	var needle_base_right := GAUGE_CENTER + Vector2(cos(needle_angle_rad - PI/2), sin(needle_angle_rad - PI/2)) * 4

	# Рисуем стрелку как треугольник
	var needle_points := PackedVector2Array([needle_tip, needle_base_left, needle_base_right])
	draw_colored_polygon(needle_points, COLOR_NEEDLE)

	# Центральный круг
	draw_circle(GAUGE_CENTER, 6, COLOR_NEEDLE)

func _draw_rpm_gauge() -> void:
	# Фон тахометра
	draw_circle(RPM_CENTER, RPM_RADIUS + 3, COLOR_BG)

	# Шкала тахометра (от -30 до 30 градусов сверху, или 150 к 30)
	var rpm_start_angle := 150.0
	var rpm_end_angle := 30.0

	# Деления
	for i in range(9):  # 0, 1, 2... 8 (x1000 RPM)
		var angle_deg := lerp(rpm_start_angle, rpm_end_angle + 360, i / 8.0)
		var angle_rad := deg_to_rad(angle_deg)

		var inner := RPM_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (RPM_RADIUS - 8)
		var outer := RPM_CENTER + Vector2(cos(angle_rad), sin(angle_rad)) * (RPM_RADIUS - 2)
		draw_line(inner, outer, COLOR_SCALE, 1.5)

	# Красная зона (6-8)
	var rpm_red_start := deg_to_rad(lerp(rpm_start_angle, rpm_end_angle + 360, 6.0 / 8.0))
	var rpm_red_end := deg_to_rad(lerp(rpm_start_angle, rpm_end_angle + 360, 8.0 / 8.0))
	draw_arc(RPM_CENTER, RPM_RADIUS - 4, rpm_red_start, rpm_red_end, 16, Color(1, 0, 0, 0.6), 5.0, true)

	# Стрелка тахометра
	var rpm_ratio := clamp(current_rpm / RPM_MAX, 0.0, 1.0)
	var rpm_needle_angle_deg := lerp(rpm_start_angle, rpm_end_angle + 360, rpm_ratio)
	var rpm_needle_angle_rad := deg_to_rad(rpm_needle_angle_deg)

	var rpm_needle_tip := RPM_CENTER + Vector2(cos(rpm_needle_angle_rad), sin(rpm_needle_angle_rad)) * (RPM_RADIUS - 12)
	draw_line(RPM_CENTER, rpm_needle_tip, COLOR_NEEDLE, 2.0)
	draw_circle(RPM_CENTER, 3, COLOR_NEEDLE)

func _draw_info_panel() -> void:
	# Серая панель для передачи и скорости (как на картинке справа)
	var panel_pos := Vector2(GAUGE_CENTER.x + GAUGE_RADIUS + 15, GAUGE_CENTER.y - 50)
	var panel_size := Vector2(60, 100)

	# Фон панели
	draw_rect(Rect2(panel_pos, panel_size), Color(0.2, 0.2, 0.2, 0.8))

	# Белый треугольник (индикатор)
	var triangle_center := panel_pos + Vector2(-8, 30)
	var triangle_points := PackedVector2Array([
		triangle_center,
		triangle_center + Vector2(8, -5),
		triangle_center + Vector2(8, 5)
	])
	draw_colored_polygon(triangle_points, Color(1, 1, 1, 1))

	# Передача (большая буква)
	draw_string(ThemeDB.fallback_font, panel_pos + Vector2(15, 35), current_gear, HORIZONTAL_ALIGNMENT_CENTER, -1, 32, COLOR_NUMBERS)

	# Скорость (цифры)
	var speed_text := "%03d" % int(current_speed)
	draw_string(ThemeDB.fallback_font, panel_pos + Vector2(5, 75), speed_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 24, COLOR_NUMBERS)

	# MPH
	draw_string(ThemeDB.fallback_font, panel_pos + Vector2(10, 95), "MPH", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color(0.7, 0.7, 0.7, 1))

func update_values(speed: float, rpm: float, gear: String) -> void:
	current_speed = speed
	current_rpm = rpm
	current_gear = gear
	queue_redraw()  # Перерисовываем при обновлении значений

func _process(_delta: float) -> void:
	# Постоянная перерисовка для анимации
	queue_redraw()
