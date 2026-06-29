extends CanvasLayer

## HUD режима «Извоз» (work mode) — рестайл под taxi-cards (день/ночь).
##
## ЭТО ТОЛЬКО ВИЗУАЛЬНЫЙ СЛОЙ. Вся логика — в work_manager.gd (не трогаем).
## Публичный API, который зовёт менеджер, сохранён 1:1:
##   setup(work_manager), show_order_popup(...), show_order_result(result),
##   _on_order_spawned/_on_order_completed/_on_balance_changed/_on_bonus_updated.
##
## Стиль/палитра/шрифты — как в гоночных плашках (lap_time_panel, standings_panel,
## round_speedometer): кремовый пейс-нот днём, графит+янтарь ночью; PanelContainer
## + StyleBoxFlat для панелей, кастомный _draw() для шашечек/баров (без blur).
## Эталон: Desktop/OSM Material/new-taxi-cards/export/taxi-cards.html + TAXI_CARDS_SPEC.md

# Шрифты — preload напрямую из ui/fonts, как во всех гоночных плашках.
const RUSSO := preload("res://ui/fonts/RussoOne-Regular.ttf")          # дисплей/крупные цифры/заголовки
const SHARETECH := preload("res://ui/fonts/ShareTechMono-Regular.ttf") # чистые числа/время (latin-only!)
const JBMONO := preload("res://ui/fonts/jbmono_regular.tres")          # подписи + строки с кириллицей
const JBMONO_WIDE := preload("res://ui/fonts/jbmono_wide.tres")        # трекнутые капс-подписи
const GOLOS := preload("res://ui/fonts/GolosText-Regular.ttf")         # цитата клиента

var _work_manager: Node
var _is_night: bool = false

# Реестр элементов, которым нужна перекраска по теме: [{n, kind, role}]
var _themed: Array = []

# --- Баланс ---
var _balance_label: Label

# --- Card 1 ВЫЗОВ ---
var _order_center: CenterContainer
var _order_panel: PanelContainer
var _order_dest: Label
var _order_fare_num: Label
var _order_fare_cur: Label
var _order_dist_val: Label
var _order_time_val: Label
var _accept_btn: Button
var _decline_btn: Button

# --- Card 2 ПОЕЗДКА ---
var _trip_panel: PanelContainer
var _trip_time: Label
var _trip_tgt: Label
var _speed_bar: _Bar
var _acc_bar: _Bar
var _speed_pct_lbl: Label
var _acc_pct_lbl: Label
var _trip_addr: Label
var _trip_target: float = 0.0

# --- Card 3 РЕЗУЛЬТАТ ---
var _result_center: CenterContainer
var _result_panel: PanelContainer
var _result_stars: Array[Label] = []
var _result_quote: Label
var _result_line_keys: Array[Label] = []
var _result_line_vals: Array[Label] = []
var _result_total_num: Label
var _result_total_cur: Label
var _result_ok_btn: Button
var _last_result: Dictionary = {}


func setup(work_manager: Node) -> void:
	_work_manager = work_manager
	_work_manager.order_spawned.connect(_on_order_spawned)
	_work_manager.order_completed.connect(_on_order_completed)
	_work_manager.balance_changed.connect(_on_balance_changed)
	_work_manager.bonus_updated.connect(_on_bonus_updated)

	_build_ui()
	_connect_night_mode()
	_refresh_theme()
	_update_balance()


# Подключаемся к NightModeManager так же, как hud.gd: это УЗЕЛ сцены (не autoload),
# ищем по дереву. В превью-сцене узла нет — тогда тема ставится через set_night().
func _connect_night_mode() -> void:
	var scene_root := get_tree().current_scene
	if not scene_root:
		return
	var nm: Node = scene_root.find_child("NightModeManager", true, false)
	if nm and nm.has_signal("night_mode_changed"):
		nm.night_mode_changed.connect(_on_night_mode_changed)
		if nm.get("is_night") != null:
			_is_night = bool(nm.is_night)


func _on_night_mode_changed(enabled: bool) -> void:
	set_night(enabled)


# Публичный переключатель темы (используется превью-харнессом).
func set_night(enabled: bool) -> void:
	if _is_night == enabled:
		return
	_is_night = enabled
	_refresh_theme()


# ============================================================================
#  ПАЛИТРА (1:1 с гоночными плашками: bg .58, те же hex)
# ============================================================================
func _c_bg() -> Color: return Color(0.078, 0.067, 0.055, 0.58) if _is_night else Color(0.957, 0.925, 0.831, 0.58)
func _c_border() -> Color: return Color(1.0, 0.706, 0.314, 0.18) if _is_night else Color(0.235, 0.157, 0.078, 0.30)
func _c_ink() -> Color: return Color("#ffd17a") if _is_night else Color("#1c1612")
func _c_dim() -> Color: return Color(0.953, 0.847, 0.640, 0.55) if _is_night else Color(0.110, 0.086, 0.071, 0.55)
func _c_dimmer() -> Color: return Color(0.953, 0.847, 0.640, 0.38) if _is_night else Color(0.110, 0.086, 0.071, 0.40)
func _c_red() -> Color: return Color("#ff6b5a") if _is_night else Color("#b3251e")
func _c_green() -> Color: return Color("#9ddc7a") if _is_night else Color("#3f8a1e")
func _c_cyan() -> Color: return Color("#5fd8e8") if _is_night else Color("#1a8a8a")
func _c_checker() -> Color: return Color(1.0, 0.819, 0.478, 0.80) if _is_night else Color(0.110, 0.086, 0.071, 0.85)
func _c_track() -> Color: return Color(1.0, 0.706, 0.314, 0.14) if _is_night else Color(0.235, 0.157, 0.078, 0.16)


func _color_for(role: String) -> Color:
	match role:
		"ink": return _c_ink()
		"dim": return _c_dim()
		"dimmer": return _c_dimmer()
		"red": return _c_red()
		"green": return _c_green()
		"cyan": return _c_cyan()
	return _c_ink()


# ============================================================================
#  РЕЕСТР ТЕМЫ
# ============================================================================
func _reg(n: Node, kind: String, role: String) -> void:
	_themed.append({"n": n, "kind": kind, "role": role})
	_apply_one(n, kind, role)


func _apply_one(n: Node, kind: String, role: String) -> void:
	match kind:
		"label":
			(n as Label).add_theme_color_override("font_color", _color_for(role))
		"panel":
			(n as PanelContainer).add_theme_stylebox_override("panel", _panel_style(role))
		"button":
			_style_button(n as Button, role)
		"checker":
			(n as _Checker).set_col(_c_checker())
		"dash":
			(n as _Dash).set_col(_c_border())
		"pin":
			(n as _Pin).set_col(_c_red())


func _refresh_theme() -> void:
	for e in _themed:
		if is_instance_valid(e.n):
			_apply_one(e.n, e.kind, e.role)
	_retheme_bars()
	_paint_stars()
	_paint_result_lines()
	if _balance_label:
		_balance_label.add_theme_color_override("font_color", _c_green())


func _panel_style(role: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(2)
	if role == "stamp":
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = _c_red()
		sb.set_border_width_all(2)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 1
		sb.content_margin_bottom = 2
	else:
		sb.bg_color = _c_bg()
		sb.border_color = _c_border()
		sb.set_border_width_all(1)
		# content_margin = 0, чтобы полоса шашечек шла вровень с краем карточки;
		# внутренние отступы делает MarginContainer внутри.
		sb.content_margin_left = 0
		sb.content_margin_right = 0
		sb.content_margin_top = 0
		sb.content_margin_bottom = 0
	return sb


func _style_button(btn: Button, role: String) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(2)
	var fg: Color
	match role:
		"accept":
			sb.bg_color = _c_green()
			sb.border_color = _c_green()
			sb.set_border_width_all(2)
			fg = Color("#0a140c")
		"decline":
			sb.bg_color = Color(0, 0, 0, 0)
			sb.border_color = _c_red()
			sb.set_border_width_all(2)
			fg = _c_red()
		_: # ok
			sb.bg_color = Color(0, 0, 0, 0)
			sb.border_color = _c_border()
			sb.set_border_width_all(1)
			fg = _c_ink()
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 13
	sb.content_margin_bottom = 13
	for st in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(st, sb)
	btn.add_theme_color_override("font_color", fg)
	btn.add_theme_color_override("font_hover_color", fg)
	btn.add_theme_color_override("font_pressed_color", fg)
	btn.add_theme_color_override("font_focus_color", fg)


func _retheme_bars() -> void:
	if _speed_bar:
		_speed_bar.set_bar_colors(_c_cyan(), _c_track(), _is_night)
	if _acc_bar:
		_acc_bar.set_bar_colors(_c_green(), _c_track(), _is_night)


# ============================================================================
#  ФАБРИКИ
# ============================================================================
func _lbl(text: String, font: Font, fsize: int, role: String, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fsize)
	l.horizontal_alignment = align
	_reg(l, "label", role)
	return l


# Карточка: PanelContainer → VBox(checker, MarginContainer(content VBox)).
func _make_card(width: float, compact: bool) -> Dictionary:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = width
	_reg(panel, "panel", "compact" if compact else "modal")

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	panel.add_child(outer)

	var checker := _Checker.new(_c_checker(), 8.0 if compact else 10.0, 6.0 if compact else 7.0)
	outer.add_child(checker)
	_reg(checker, "checker", "")

	var margin := MarginContainer.new()
	var ph := 16 if compact else 24
	var pv := 12 if compact else 18
	margin.add_theme_constant_override("margin_left", ph)
	margin.add_theme_constant_override("margin_right", ph)
	margin.add_theme_constant_override("margin_top", pv)
	margin.add_theme_constant_override("margin_bottom", pv + 4)
	outer.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10 if not compact else 8)
	margin.add_child(content)

	return {"panel": panel, "content": content}


func _stamp(text: String, rot_deg: float) -> Control:
	# Штамп «ИЗВОЗ» — рамка red, поворот. Обёртка-Control держит поворот вокруг центра.
	var holder := Control.new()
	var pc := PanelContainer.new()
	_reg(pc, "panel", "stamp")
	var l := _lbl(text, RUSSO, 11, "red")
	pc.add_child(l)
	holder.add_child(pc)
	pc.reset_size()
	holder.custom_minimum_size = pc.get_combined_minimum_size()
	pc.pivot_offset = pc.size * 0.5
	pc.rotation = deg_to_rad(rot_deg)
	return holder


# ============================================================================
#  СБОРКА UI
# ============================================================================
func _build_ui() -> void:
	_build_balance()
	_build_order_card()
	_build_trip_card()
	_build_result_card()


func _build_balance() -> void:
	_balance_label = Label.new()
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_balance_label.add_theme_font_override("font", RUSSO)
	_balance_label.add_theme_font_size_override("font_size", 22)
	_balance_label.add_theme_color_override("font_color", _c_green())
	_balance_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_balance_label.offset_left = -320
	_balance_label.offset_top = 16
	_balance_label.offset_right = -20
	_balance_label.offset_bottom = 52
	_balance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_balance_label)


func _build_order_card() -> void:
	var card := _make_card(640.0, false)
	_order_panel = card.panel
	var content: VBoxContainer = card.content

	# --- head: (kicker + ВЫЗОВ) <-> stamp ---
	var head := HBoxContainer.new()
	var head_left := VBoxContainer.new()
	head_left.add_theme_constant_override("separation", 2)
	head_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_left.add_child(_lbl("НОВЫЙ ЗАКАЗ", JBMONO, 11, "dim"))
	head_left.add_child(_lbl("ВЫЗОВ", RUSSO, 44, "ink"))
	head.add_child(head_left)
	var stamp := _stamp("ИЗВОЗ", -2.0)
	stamp.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	head.add_child(stamp)
	content.add_child(head)

	# --- address ---
	var addr := HBoxContainer.new()
	addr.add_theme_constant_override("separation", 10)
	var pin := _Pin.new(_c_red(), 16, 20)
	addr.add_child(pin)
	_reg(pin, "pin", "")
	_order_dest = _lbl("ул. Ленина, д. 42", RUSSO, 26, "ink")
	_order_dest.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	addr.add_child(_order_dest)
	content.add_child(addr)

	# --- fare <-> metrics ---
	var farerow := HBoxContainer.new()
	farerow.add_theme_constant_override("separation", 24)
	var farebox := HBoxContainer.new()
	farebox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	farebox.size_flags_vertical = Control.SIZE_SHRINK_END
	_order_fare_num = _lbl("450", RUSSO, 76, "red")
	_order_fare_cur = _lbl(" руб.", RUSSO, 40, "red")
	_order_fare_cur.size_flags_vertical = Control.SIZE_SHRINK_END
	farebox.add_child(_order_fare_num)
	farebox.add_child(_order_fare_cur)
	farerow.add_child(farebox)

	var metrics := HBoxContainer.new()
	metrics.add_theme_constant_override("separation", 28)
	metrics.size_flags_vertical = Control.SIZE_SHRINK_END
	_order_dist_val = _make_metric(metrics, "РАССТОЯНИЕ", "~2.3 км", JBMONO)
	_order_time_val = _make_metric(metrics, "В ПУТИ", "~5:30", SHARETECH)
	farerow.add_child(metrics)
	content.add_child(farerow)

	# --- dashed rule ---
	var rule := _Dash.new()
	content.add_child(rule)
	_reg(rule, "dash", "")

	# --- bonus line ---
	var bonus := HBoxContainer.new()
	bonus.add_theme_constant_override("separation", 8)
	bonus.add_child(_lbl("★", RUSSO, 15, "green"))
	bonus.add_child(_lbl("+20% за скорость · +20% за аккуратность", JBMONO, 14, "green"))
	content.add_child(bonus)

	# --- actions ---
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	_accept_btn = _make_button("ПРИНЯТЬ", "accept", 1.3)
	_accept_btn.pressed.connect(_on_accept_pressed)
	_decline_btn = _make_button("ОТКЛОНИТЬ", "decline", 1.0)
	_decline_btn.pressed.connect(_on_decline_pressed)
	actions.add_child(_accept_btn)
	actions.add_child(_decline_btn)
	content.add_child(actions)

	# центрируем по экрану
	_order_center = CenterContainer.new()
	_order_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_order_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_order_center.add_child(_order_panel)
	_order_panel.visible = false
	add_child(_order_center)


func _make_metric(parent: HBoxContainer, caption: String, value: String, value_font: Font) -> Label:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(_lbl(caption, JBMONO, 11, "dim", HORIZONTAL_ALIGNMENT_RIGHT))
	var val := _lbl(value, value_font, 28, "ink", HORIZONTAL_ALIGNMENT_RIGHT)
	col.add_child(val)
	parent.add_child(col)
	return val


func _make_button(text: String, role: String, ratio: float) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", RUSSO)
	b.add_theme_font_size_override("font_size", 18)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_stretch_ratio = ratio
	_reg(b, "button", role)
	return b


func _build_trip_card() -> void:
	var card := _make_card(320.0, true)
	_trip_panel = card.panel
	_trip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var content: VBoxContainer = card.content

	# row1: «поездка» <-> таймер
	var row1 := HBoxContainer.new()
	var lab := _lbl("ПОЕЗДКА", JBMONO, 10, "dim")
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.size_flags_vertical = Control.SIZE_SHRINK_END
	row1.add_child(lab)
	var timebox := HBoxContainer.new()
	timebox.size_flags_vertical = Control.SIZE_SHRINK_END
	_trip_time = _lbl("3:12", SHARETECH, 22, "ink")
	_trip_tgt = _lbl(" / ~5:30", SHARETECH, 15, "dim")
	_trip_tgt.size_flags_vertical = Control.SIZE_SHRINK_END
	timebox.add_child(_trip_time)
	timebox.add_child(_trip_tgt)
	row1.add_child(timebox)
	content.add_child(row1)

	# meters
	var res_speed := _make_meter("СКОРОСТЬ")
	_speed_pct_lbl = res_speed.pct
	_speed_bar = res_speed.bar
	content.add_child(res_speed.row)
	var res_acc := _make_meter("АККУРАТНОСТЬ")
	_acc_pct_lbl = res_acc.pct
	_acc_bar = res_acc.bar
	content.add_child(res_acc.row)
	_retheme_bars()

	# addr2 (опц.)
	var addr2 := HBoxContainer.new()
	addr2.add_theme_constant_override("separation", 6)
	var pin := _Pin.new(_c_dim(), 9, 11)
	addr2.add_child(pin)
	# pin для addr2 — dim, не red; регистрируем как «pin» но он перекрасится в red.
	# Используем отдельную окраску: оставим dim вручную (не регистрируем).
	pin.set_col(_c_dim())
	_trip_addr = _lbl("ул. Ленина · 1.1 км", JBMONO, 11, "dim")
	addr2.add_child(_trip_addr)
	content.add_child(addr2)

	_trip_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_trip_panel.offset_left = 20
	_trip_panel.offset_top = 20
	_trip_panel.visible = false
	add_child(_trip_panel)


func _make_meter(caption: String) -> Dictionary:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	var ml := HBoxContainer.new()
	var cap := _lbl(caption, JBMONO, 9, "dim")
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ml.add_child(cap)
	var pct := _lbl("100%", JBMONO, 9, "dim", HORIZONTAL_ALIGNMENT_RIGHT)
	ml.add_child(pct)
	row.add_child(ml)
	var bar := _Bar.new()
	row.add_child(bar)
	return {"row": row, "pct": pct, "bar": bar}


func _build_result_card() -> void:
	var card := _make_card(640.0, false)
	_result_panel = card.panel
	var content: VBoxContainer = card.content

	# head: title <-> stars
	var head := HBoxContainer.new()
	var title := _lbl("ЗАКАЗ ВЫПОЛНЕН", RUSSO, 40, "ink")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var stars := HBoxContainer.new()
	stars.add_theme_constant_override("separation", 4)
	stars.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for i in range(5):
		var s := Label.new()
		s.text = "★"
		s.add_theme_font_size_override("font_size", 34)
		stars.add_child(s)
		_result_stars.append(s)
	head.add_child(stars)
	content.add_child(head)

	# quote
	_result_quote = _lbl("«Спасибо, отличная поездка!»", GOLOS, 17, "ink")
	_result_quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_result_quote)

	# lines
	var lines := VBoxContainer.new()
	lines.add_theme_constant_override("separation", 11)
	var keys := ["Стоимость поездки", "Бонус за скорость", "Бонус за аккуратность"]
	for k in keys:
		var line := HBoxContainer.new()
		var key := _lbl(k, JBMONO, 16, "dim")
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(key)
		var val := Label.new()
		val.add_theme_font_override("font", JBMONO)
		val.add_theme_font_size_override("font_size", 16)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(val)
		lines.add_child(line)
		_result_line_keys.append(key)
		_result_line_vals.append(val)
	content.add_child(lines)

	# dashed rule
	var rule := _Dash.new()
	content.add_child(rule)
	_reg(rule, "dash", "")

	# total
	var total := HBoxContainer.new()
	var tk := _lbl("ИТОГО", RUSSO, 22, "ink")
	tk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tk.size_flags_vertical = Control.SIZE_SHRINK_END
	total.add_child(tk)
	_result_total_num = _lbl("630", RUSSO, 52, "red")
	_result_total_cur = _lbl(" руб.", RUSSO, 28, "red")
	_result_total_cur.size_flags_vertical = Control.SIZE_SHRINK_END
	total.add_child(_result_total_num)
	total.add_child(_result_total_cur)
	content.add_child(total)

	# ok
	var okrow := HBoxContainer.new()
	okrow.alignment = BoxContainer.ALIGNMENT_END
	_result_ok_btn = Button.new()
	_result_ok_btn.text = "ОК"
	_result_ok_btn.add_theme_font_override("font", RUSSO)
	_result_ok_btn.add_theme_font_size_override("font_size", 18)
	_result_ok_btn.custom_minimum_size = Vector2(160, 0)
	_result_ok_btn.pressed.connect(_on_result_ok_pressed)
	_reg(_result_ok_btn, "button", "ok")
	okrow.add_child(_result_ok_btn)
	content.add_child(okrow)

	_result_center = CenterContainer.new()
	_result_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_result_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_center.add_child(_result_panel)
	_result_panel.visible = false
	add_child(_result_center)


# ============================================================================
#  ПРОЦЕСС / ЖИВАЯ КАРТОЧКА ПОЕЗДКИ
# ============================================================================
func _process(_delta: float) -> void:
	if not _work_manager:
		return
	var st: int = _work_manager.get_state()
	if st == 2: # DRIVING
		if not _trip_panel.visible:
			_trip_panel.visible = true
		_update_trip_card()
	else:
		if _trip_panel.visible:
			_trip_panel.visible = false


func _update_trip_card() -> void:
	var el: float = _work_manager.get_trip_elapsed() if _work_manager.has_method("get_trip_elapsed") else 0.0
	var tgt: float = _trip_target
	if tgt <= 0.0 and _work_manager.has_method("get_estimated_time"):
		tgt = _work_manager.get_estimated_time()
	_trip_time.text = _fmt_mmss(el)
	_trip_tgt.text = " / ~%s" % _fmt_mmss(tgt)

	var sp: float = clampf(_norm(_work_manager.get_speed_pct()) if _work_manager.has_method("get_speed_pct") else 1.0, 0.0, 1.0)
	var sf: float = clampf(_norm(_work_manager.get_safe_pct()) if _work_manager.has_method("get_safe_pct") else 1.0, 0.0, 1.0)
	_speed_bar.set_pct(sp)
	_acc_bar.set_pct(sf)
	_speed_pct_lbl.text = "%d%%" % int(round(sp * 100.0))
	_acc_pct_lbl.text = "%d%%" % int(round(sf * 100.0))

	if _work_manager.has_method("get_car") and _work_manager.has_method("get_dropoff_pos"):
		var car: Node3D = _work_manager.get_car()
		if car and is_instance_valid(car):
			var dp: Vector3 = _work_manager.get_dropoff_pos()
			var dist: float = Vector2(car.global_position.x, car.global_position.z).distance_to(Vector2(dp.x, dp.z))
			var ds := ("%.1f км" % (dist / 1000.0)) if dist > 1000.0 else ("%d м" % int(dist))
			var dest: String = _work_manager.get_destination_name() if _work_manager.has_method("get_destination_name") else ""
			_trip_addr.text = "%s · %s" % [dest, ds]


# Терпим оба соглашения (0..1 и 0..100).
func _norm(v: float) -> float:
	return v / 100.0 if v > 1.0 else v


func _fmt_mmss(sec: float) -> String:
	var s := int(maxf(0.0, sec))
	return "%d:%02d" % [s / 60, s % 60]


# ============================================================================
#  БАЛАНС
# ============================================================================
func _update_balance() -> void:
	if CareerState and _balance_label:
		_balance_label.text = CareerState.format_money(CareerState.balance)


# ============================================================================
#  CARD 1 — ВЫЗОВ
# ============================================================================
func show_order_popup(destination: String, fare: int, estimated_time: float, trip_dist: float = 0.0) -> void:
	_order_dest.text = destination
	var num_cur := _split_money(fare)
	_order_fare_num.text = num_cur[0]
	_order_fare_cur.text = " " + num_cur[1]
	_order_dist_val.text = "~%.1f км" % (trip_dist / 1000.0)
	_order_time_val.text = "~%s" % _fmt_mmss(estimated_time)
	_trip_target = estimated_time
	_order_panel.visible = true
	_trip_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_accept_btn.grab_focus()


func _split_money(amount: int) -> Array:
	if CareerState:
		var parts: PackedStringArray = CareerState.format_money(amount).rsplit(" ", true, 1)
		if parts.size() == 2:
			return [parts[0], parts[1]]
		return [str(amount), "руб."]
	return [str(amount), "руб."]


func _on_accept_pressed() -> void:
	_order_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _work_manager:
		_work_manager.accept_order()


func _on_decline_pressed() -> void:
	_order_panel.visible = false
	_trip_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _work_manager:
		_work_manager.decline_order()


# ============================================================================
#  CARD 3 — РЕЗУЛЬТАТ
# ============================================================================
func show_order_result(result: Dictionary) -> void:
	_last_result = result
	_result_quote.text = "«%s»" % str(result.get("phrase", ""))
	_paint_stars()
	_paint_result_lines()
	_result_panel.visible = true
	_trip_panel.visible = false
	_update_balance()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_result_ok_btn.grab_focus()


func _paint_stars() -> void:
	if _result_stars.is_empty():
		return
	var stars: int = int(_last_result.get("stars", 0))
	for i in range(_result_stars.size()):
		var lbl := _result_stars[i]
		lbl.add_theme_color_override("font_color", _c_red() if i < stars else _c_dimmer())


func _paint_result_lines() -> void:
	if _result_line_vals.is_empty() or _last_result.is_empty():
		return
	# line 0 — стоимость
	var nc := _split_money(int(_last_result.get("fare", 0)))
	_result_line_vals[0].text = "%s %s" % [nc[0], nc[1]]
	_result_line_vals[0].add_theme_color_override("font_color", _c_ink())
	# line 1 — бонус скорости, line 2 — бонус аккуратности
	_paint_bonus_line(1, int(_last_result.get("speed_bonus", 0)), float(_last_result.get("speed_pct", 0.0)))
	_paint_bonus_line(2, int(_last_result.get("safe_bonus", 0)), float(_last_result.get("safe_pct", 0.0)))
	# total
	var tc := _split_money(int(_last_result.get("total", 0)))
	_result_total_num.text = tc[0]
	_result_total_cur.text = " " + tc[1]


func _paint_bonus_line(idx: int, bonus: int, pct: float) -> void:
	var v := _result_line_vals[idx]
	if bonus > 0:
		var nc := _split_money(bonus)
		v.text = "+%s %s (%d%%)" % [nc[0], nc[1], int(round(_norm(pct) * 100.0))]
		v.add_theme_color_override("font_color", _c_green())
	else:
		v.text = "нет"
		v.add_theme_color_override("font_color", _c_dim())


func _on_result_ok_pressed() -> void:
	_result_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _work_manager:
		_work_manager.finish_result_screen()


# ============================================================================
#  СИГНАЛЫ ОТ WorkManager
# ============================================================================
func _on_order_spawned(_pickup_pos: Vector3) -> void:
	pass


func _on_order_completed(_result: Dictionary) -> void:
	pass  # отображение через show_order_result


func _on_balance_changed(_new_balance: int) -> void:
	_update_balance()


func _on_bonus_updated(speed_pct: float, safe_pct: float) -> void:
	# Немедленная реакция на событие (съезд/удар). Непрерывное обновление —
	# в _process через геттеры менеджера.
	if _speed_bar:
		_speed_bar.set_pct(clampf(_norm(speed_pct), 0.0, 1.0))
	if _acc_bar:
		_acc_bar.set_pct(clampf(_norm(safe_pct), 0.0, 1.0))


# ============================================================================
#  ВНУТРЕННИЕ КОНТРОЛЫ (custom _draw, как minimap/speedometer — без blur)
# ============================================================================
class _Checker extends Control:
	var col := Color.BLACK
	var sq := 7.0

	func _init(c: Color, h: float, square_px: float) -> void:
		col = c
		sq = square_px
		custom_minimum_size = Vector2(0, h)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func set_col(c: Color) -> void:
		col = c
		queue_redraw()

	func _draw() -> void:
		var cols := int(ceil(size.x / sq)) + 1
		var rows := int(ceil(size.y / sq)) + 1
		for r in range(rows):
			for cc in range(cols):
				if (r + cc) % 2 == 0:
					draw_rect(Rect2(cc * sq, r * sq, sq, sq), col)


class _Bar extends Control:
	var pct := 1.0
	var fill := Color(0.1, 0.55, 0.6)
	var track := Color(0, 0, 0, 0.16)
	var glow := false

	func _init() -> void:
		custom_minimum_size = Vector2(0, 8)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_bar_colors(f: Color, t: Color, g: bool) -> void:
		fill = f
		track = t
		glow = g
		queue_redraw()

	func set_pct(p: float) -> void:
		pct = clampf(p, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), track)
		var fw := w * pct
		if fw <= 0.0:
			return
		if glow:
			var gcol := fill
			gcol.a = 0.30
			draw_rect(Rect2(-2, -2, fw + 4, h + 4), gcol)
		draw_rect(Rect2(0, 0, fw, h), fill)


class _Pin extends Control:
	var col := Color("#b3251e")

	func _init(c: Color, w: float = 16, h: float = 20) -> void:
		col = c
		custom_minimum_size = Vector2(w, h)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_col(c: Color) -> void:
		col = c
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var cx := w * 0.5
		var r := w * 0.42
		var cy := r + 1.0
		draw_arc(Vector2(cx, cy), r, 0.0, TAU, 22, col, 2.0, true)
		var tip := Vector2(cx, size.y - 1.0)
		draw_line(Vector2(cx - r * 0.72, cy + r * 0.5), tip, col, 2.0, true)
		draw_line(Vector2(cx + r * 0.72, cy + r * 0.5), tip, col, 2.0, true)
		draw_circle(Vector2(cx, cy), r * 0.34, col)


class _Dash extends Control:
	var col := Color(0, 0, 0, 0.3)

	func _init() -> void:
		custom_minimum_size = Vector2(0, 1)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_col(c: Color) -> void:
		col = c
		queue_redraw()

	func _draw() -> void:
		var x := 0.0
		var dash := 5.0
		var gap := 4.0
		while x < size.x:
			draw_line(Vector2(x, 0.5), Vector2(minf(x + dash, size.x), 0.5), col, 1.0)
			x += dash + gap
