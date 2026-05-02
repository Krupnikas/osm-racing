extends CanvasLayer

## HUD для режима работы
## Показывает баланс, попап заказа, результаты

var _work_manager: Node

# UI элементы
var _balance_label: Label
var _order_panel: PanelContainer
var _order_dest_label: Label
var _order_fare_label: Label
var _order_time_label: Label
var _accept_btn: Button
var _decline_btn: Button

var _result_panel: PanelContainer
var _result_labels: Array[Label] = []
var _result_phrase_label: Label
var _result_stars_label: Label
var _result_ok_btn: Button

var _status_label: Label  # Статус во время поездки (расстояние, бонусы)


func setup(work_manager: Node) -> void:
	_work_manager = work_manager
	_work_manager.order_spawned.connect(_on_order_spawned)
	_work_manager.order_completed.connect(_on_order_completed)
	_work_manager.balance_changed.connect(_on_balance_changed)
	_work_manager.bonus_updated.connect(_on_bonus_updated)

	_build_ui()
	_update_balance()


func _build_ui() -> void:
	# === Баланс (правый верхний угол) ===
	_balance_label = Label.new()
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_balance_label.add_theme_font_size_override("font_size", 24)
	_balance_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	_balance_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_balance_label.add_theme_constant_override("shadow_offset_x", 2)
	_balance_label.add_theme_constant_override("shadow_offset_y", 2)
	_balance_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_balance_label.offset_left = -250
	_balance_label.offset_top = 15
	_balance_label.offset_right = -15
	_balance_label.offset_bottom = 50
	add_child(_balance_label)

	# === Статус поездки (верхний центр) ===
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 20)
	_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_status_label.add_theme_constant_override("shadow_offset_x", 1)
	_status_label.add_theme_constant_override("shadow_offset_y", 1)
	_status_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_status_label.offset_left = -200
	_status_label.offset_top = 15
	_status_label.offset_right = 200
	_status_label.offset_bottom = 50
	_status_label.visible = false
	add_child(_status_label)

	# === Попап заказа (центр экрана) ===
	_build_order_popup()

	# === Попап результата ===
	_build_result_popup()


func _build_order_popup() -> void:
	_order_panel = PanelContainer.new()
	_order_panel.set_anchors_preset(Control.PRESET_CENTER)
	_order_panel.offset_left = -200
	_order_panel.offset_top = -150
	_order_panel.offset_right = 200
	_order_panel.offset_bottom = 150

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	style.border_color = Color(0.3, 0.6, 1.0, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(20)
	_order_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_order_panel.add_child(vbox)

	var title := Label.new()
	title.text = "НОВЫЙ ЗАКАЗ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
	vbox.add_child(title)

	_order_dest_label = Label.new()
	_order_dest_label.add_theme_font_size_override("font_size", 22)
	_order_dest_label.add_theme_color_override("font_color", Color(1, 1, 1))
	vbox.add_child(_order_dest_label)

	_order_fare_label = Label.new()
	_order_fare_label.add_theme_font_size_override("font_size", 24)
	_order_fare_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	vbox.add_child(_order_fare_label)

	_order_time_label = Label.new()
	_order_time_label.add_theme_font_size_override("font_size", 18)
	_order_time_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(_order_time_label)

	# Бонусы info
	var bonus_info := Label.new()
	bonus_info.text = "+20% за скорость  +20% за аккуратность"
	bonus_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bonus_info.add_theme_font_size_override("font_size", 16)
	bonus_info.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	vbox.add_child(bonus_info)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 5)
	vbox.add_child(spacer)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 20)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	_accept_btn = Button.new()
	_accept_btn.text = "ПРИНЯТЬ"
	_accept_btn.custom_minimum_size = Vector2(140, 45)
	_accept_btn.add_theme_font_size_override("font_size", 22)
	_accept_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	_accept_btn.pressed.connect(_on_accept_pressed)
	hbox.add_child(_accept_btn)

	_decline_btn = Button.new()
	_decline_btn.text = "ОТКЛОНИТЬ"
	_decline_btn.custom_minimum_size = Vector2(140, 45)
	_decline_btn.add_theme_font_size_override("font_size", 22)
	_decline_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	_decline_btn.pressed.connect(_on_decline_pressed)
	hbox.add_child(_decline_btn)

	_order_panel.visible = false
	add_child(_order_panel)


func _build_result_popup() -> void:
	_result_panel = PanelContainer.new()
	_result_panel.set_anchors_preset(Control.PRESET_CENTER)
	_result_panel.offset_left = -220
	_result_panel.offset_top = -180
	_result_panel.offset_right = 220
	_result_panel.offset_bottom = 180

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.08, 0.95)
	style.border_color = Color(0.3, 0.8, 0.3, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(20)
	_result_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_result_panel.add_child(vbox)

	var title := Label.new()
	title.text = "ЗАКАЗ ВЫПОЛНЕН"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	vbox.add_child(title)

	# Звёзды
	_result_stars_label = Label.new()
	_result_stars_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_stars_label.add_theme_font_size_override("font_size", 36)
	_result_stars_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	vbox.add_child(_result_stars_label)

	# Фраза клиента
	_result_phrase_label = Label.new()
	_result_phrase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_phrase_label.add_theme_font_size_override("font_size", 20)
	_result_phrase_label.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_result_phrase_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_result_phrase_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 5)
	vbox.add_child(spacer)

	# 4 строки: стоимость, бонус скорости, бонус безопасности, итого
	var labels_data := ["Стоимость поездки:", "Бонус за скорость:", "Бонус за аккуратность:", "ИТОГО:"]
	for text in labels_data:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 20)
		lbl.add_theme_color_override("font_color", Color(1, 1, 1))
		vbox.add_child(lbl)
		_result_labels.append(lbl)

	# Итого выделяем
	_result_labels[3].add_theme_font_size_override("font_size", 24)
	_result_labels[3].add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 5)
	vbox.add_child(spacer2)

	_result_ok_btn = Button.new()
	_result_ok_btn.text = "OK"
	_result_ok_btn.custom_minimum_size = Vector2(0, 45)
	_result_ok_btn.add_theme_font_size_override("font_size", 22)
	_result_ok_btn.pressed.connect(_on_result_ok_pressed)
	vbox.add_child(_result_ok_btn)

	_result_panel.visible = false
	add_child(_result_panel)


func _process(_delta: float) -> void:
	if not _work_manager:
		return
	var state: int = _work_manager.get_state()
	# Обновляем статус только во время поездки
	if state == 2:  # DRIVING
		_update_driving_status()
	else:
		_status_label.visible = false


func _update_driving_status() -> void:
	if not _work_manager:
		return
	var car: Node3D = _work_manager.get_car()
	if not car or not is_instance_valid(car):
		return
	var car_pos: Vector3 = car.global_position
	var dropoff: Vector3 = _work_manager.get_dropoff_pos()
	var dist: float = car_pos.distance_to(dropoff)
	var dist_text: String
	if dist > 1000:
		dist_text = "%.1f км" % (dist / 1000.0)
	else:
		dist_text = "%d м" % int(dist)
	_status_label.text = "%s | %s" % [_work_manager.get_destination_name(), dist_text]
	_status_label.visible = true




func _update_balance() -> void:
	if CareerState:
		_balance_label.text = CareerState.format_money(CareerState.balance)


# === Попап заказа ===

func show_order_popup(destination: String, fare: int, estimated_time: float, trip_dist: float = 0.0) -> void:
	_order_dest_label.text = destination
	_order_fare_label.text = CareerState.format_money(fare) if CareerState else "%d руб." % fare
	var minutes := int(estimated_time / 60.0)
	var seconds := int(fmod(estimated_time, 60.0))
	var dist_km := trip_dist / 1000.0
	_order_time_label.text = "~%.1f км | %d:%02d" % [dist_km, minutes, seconds]
	_order_panel.visible = true
	_status_label.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_accept_btn.grab_focus()


func _on_accept_pressed() -> void:
	_order_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _work_manager:
		_work_manager.accept_order()


func _on_decline_pressed() -> void:
	_order_panel.visible = false
	_status_label.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _work_manager:
		_work_manager.decline_order()


# === Результат заказа ===

func show_order_result(result: Dictionary) -> void:
	# Звёзды
	var stars: int = result.get("stars", 3)
	_result_stars_label.text = "★".repeat(stars) + "☆".repeat(5 - stars)

	_result_phrase_label.text = "\"%s\"" % result.phrase
	_result_labels[0].text = "Стоимость поездки: %s" % (CareerState.format_money(result.fare) if CareerState else "%d руб." % result.fare)

	if result.speed_bonus > 0:
		_result_labels[1].text = "Бонус за скорость: +%s (%d%%)" % [
			CareerState.format_money(result.speed_bonus) if CareerState else "%d руб." % result.speed_bonus,
			int(result.speed_pct * 100)]
		_result_labels[1].add_theme_color_override("font_color", Color(0.3, 0.9, 1.0))
	else:
		_result_labels[1].text = "Бонус за скорость: нет"
		_result_labels[1].add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))

	if result.safe_bonus > 0:
		_result_labels[2].text = "Бонус за аккуратность: +%s (%d%%)" % [
			CareerState.format_money(result.safe_bonus) if CareerState else "%d руб." % result.safe_bonus,
			int(result.safe_pct * 100)]
		_result_labels[2].add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	else:
		_result_labels[2].text = "Бонус за аккуратность: нет"
		_result_labels[2].add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))

	_result_labels[3].text = "ИТОГО: %s" % (CareerState.format_money(result.total) if CareerState else "%d руб." % result.total)

	_result_panel.visible = true
	_status_label.visible = false
	_update_balance()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_result_ok_btn.grab_focus()


func _on_result_ok_pressed() -> void:
	_result_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _work_manager:
		_work_manager.finish_result_screen()


# === Сигналы от WorkManager ===

func _on_order_spawned(_pickup_pos: Vector3) -> void:
	_status_label.visible = true


func _on_order_completed(_result: Dictionary) -> void:
	pass  # Обработка через show_order_result


func _on_balance_changed(_new_balance: int) -> void:
	_update_balance()


func _on_bonus_updated(speed_pct: float, safe_pct: float) -> void:
	# Можно обновить индикатор бонусов если нужно
	pass
