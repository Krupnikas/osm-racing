extends Control

## Меню карьеры в стиле NFS Underground
##
## Экраны:
## 1. Выбор/создание профиля
## 2. Хаб карьеры (баланс, гараж, магазин, выезд в город, вызовы)
## 3. Гараж (свои машины)
## 4. Магазин (покупка машин)
## 5. Выбор локации (свободная езда)
## 6. Вызовы (гонки с призовыми)

const RaceTrackScript = preload("res://race/race_tracks.gd")

# Локации для свободной езды (те же что в главном меню)
const LOCATIONS := {
	"Череповец": [59.150406, 37.948805],
	"Новый Век": [59.123567, 37.982864],
	"Ледовый дворец": [59.089216, 37.917488],
	"Москва (Отрадное)": [55.860580, 37.599646],
	"Тбилиси (Важа-Пшавела)": [41.723972, 44.730502],
	"Дубай (Крик)": [25.208591, 55.344100],
}

signal back_to_main_menu

var _profile_panel: Panel
var _hub_panel: Panel
var _garage_panel: Panel
var _shop_panel: Panel
var _create_panel: Panel
var _delete_confirm_panel: Panel
var _location_panel: Panel
var _challenges_panel: Panel
var _tuning_panel: Panel
var _sell_confirm_panel: Panel
var _delete_profile_name: String = ""
var _sell_car_id: String = ""
var _tuning_car_id: String = ""

# Прямые ссылки на контейнеры
var _profiles_container: VBoxContainer
var _name_input: LineEdit
var _delete_title: Label
var _hub_profile_label: Label
var _hub_balance_label: Label
var _hub_stats_label: Label
var _hub_car_label: Label
var _hub_freeroam_btn: Button
var _hub_challenges_btn: Button
var _garage_cars_container: VBoxContainer
var _shop_balance_label: Label
var _shop_cars_container: VBoxContainer
var _challenges_container: VBoxContainer
var _tuning_container: VBoxContainer
var _tuning_title: Label
var _tuning_balance: Label
var _sell_title: Label
var _sell_price_label: Label


func _ready() -> void:
	visible = false
	_build_profile_panel()
	_build_create_panel()
	_build_delete_confirm_panel()
	_build_hub_panel()
	_build_garage_panel()
	_build_shop_panel()
	_build_location_panel()
	_build_challenges_panel()
	_build_tuning_panel()
	_build_sell_confirm_panel()


func show_menu() -> void:
	visible = true
	_show_profile_screen()


func hide_menu() -> void:
	visible = false
	_hide_all()


# === Построение UI ===

func _build_profile_panel() -> void:
	_profile_panel = _create_centered_panel("ProfilePanel", Vector2(500, 450))
	add_child(_profile_panel)

	var vbox := _create_inner_vbox(_profile_panel)

	var title := Label.new()
	title.text = "КАРЬЕРА"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 42)
	vbox.add_child(title)

	_add_spacer(vbox, 10)

	var subtitle := Label.new()
	subtitle.text = "Выберите профиль"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 24)
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(subtitle)

	_add_spacer(vbox, 15)

	_profiles_container = VBoxContainer.new()
	vbox.add_child(_profiles_container)

	var create_btn := Button.new()
	create_btn.text = "+ НОВЫЙ ПРОФИЛЬ"
	create_btn.custom_minimum_size = Vector2(0, 55)
	create_btn.add_theme_font_size_override("font_size", 24)
	create_btn.add_theme_color_override("font_color", Color(0.5, 1, 0.5))
	create_btn.pressed.connect(_on_create_profile_pressed)
	vbox.add_child(create_btn)

	_add_expand_spacer(vbox)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_profile_back)
	vbox.add_child(back_btn)


func _build_create_panel() -> void:
	_create_panel = _create_centered_panel("CreatePanel", Vector2(450, 280))
	add_child(_create_panel)

	var vbox := _create_inner_vbox(_create_panel)

	var title := Label.new()
	title.text = "Новый профиль"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	vbox.add_child(title)

	_add_spacer(vbox, 15)

	var name_label := Label.new()
	name_label.text = "Имя игрока:"
	name_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(name_label)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Введите имя..."
	_name_input.custom_minimum_size = Vector2(0, 50)
	_name_input.add_theme_font_size_override("font_size", 24)
	_name_input.max_length = 20
	_name_input.text_submitted.connect(_on_name_submitted)
	vbox.add_child(_name_input)

	_add_spacer(vbox, 10)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var cancel_btn := Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(150, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.pressed.connect(_on_create_cancel)
	hbox.add_child(cancel_btn)

	var spacer_h := Control.new()
	spacer_h.custom_minimum_size = Vector2(20, 0)
	hbox.add_child(spacer_h)

	var ok_btn := Button.new()
	ok_btn.text = "Создать"
	ok_btn.custom_minimum_size = Vector2(150, 50)
	ok_btn.add_theme_font_size_override("font_size", 22)
	ok_btn.add_theme_color_override("font_color", Color(0.5, 1, 0.5))
	ok_btn.pressed.connect(_on_create_confirm)
	hbox.add_child(ok_btn)


func _build_delete_confirm_panel() -> void:
	_delete_confirm_panel = _create_centered_panel("DeleteConfirmPanel", Vector2(420, 200))
	add_child(_delete_confirm_panel)

	var vbox := _create_inner_vbox(_delete_confirm_panel)

	_delete_title = Label.new()
	_delete_title.text = "Удалить профиль?"
	_delete_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_delete_title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(_delete_title)

	_add_spacer(vbox, 10)

	var desc := Label.new()
	desc.text = "Весь прогресс будет потерян."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", 20)
	desc.add_theme_color_override("font_color", Color(1, 0.6, 0.6))
	vbox.add_child(desc)

	_add_expand_spacer(vbox)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var cancel_btn := Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(150, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.pressed.connect(_on_delete_cancel)
	hbox.add_child(cancel_btn)

	var spacer_h := Control.new()
	spacer_h.custom_minimum_size = Vector2(20, 0)
	hbox.add_child(spacer_h)

	var delete_btn := Button.new()
	delete_btn.text = "Удалить"
	delete_btn.custom_minimum_size = Vector2(150, 50)
	delete_btn.add_theme_font_size_override("font_size", 22)
	delete_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	delete_btn.pressed.connect(_on_delete_confirm)
	hbox.add_child(delete_btn)


func _build_hub_panel() -> void:
	_hub_panel = _create_centered_panel("HubPanel", Vector2(550, 550))
	add_child(_hub_panel)

	var vbox := _create_inner_vbox(_hub_panel)

	_hub_profile_label = Label.new()
	_hub_profile_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub_profile_label.add_theme_font_size_override("font_size", 36)
	vbox.add_child(_hub_profile_label)

	_add_spacer(vbox, 5)

	_hub_balance_label = Label.new()
	_hub_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub_balance_label.add_theme_font_size_override("font_size", 28)
	_hub_balance_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	vbox.add_child(_hub_balance_label)

	_add_spacer(vbox, 5)

	_hub_stats_label = Label.new()
	_hub_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub_stats_label.add_theme_font_size_override("font_size", 20)
	_hub_stats_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(_hub_stats_label)

	_add_spacer(vbox, 5)

	_hub_car_label = Label.new()
	_hub_car_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub_car_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_hub_car_label)

	_add_spacer(vbox, 15)

	# Работать (такси/доставка)
	_hub_freeroam_btn = Button.new()
	_hub_freeroam_btn.text = "РАБОТАТЬ"
	_hub_freeroam_btn.custom_minimum_size = Vector2(0, 65)
	_hub_freeroam_btn.add_theme_font_size_override("font_size", 30)
	_hub_freeroam_btn.add_theme_color_override("font_color", Color(1, 1, 0.5))
	_hub_freeroam_btn.pressed.connect(_on_work_pressed)
	vbox.add_child(_hub_freeroam_btn)

	# Гонки
	_hub_challenges_btn = Button.new()
	_hub_challenges_btn.text = "ГОНЯТЬСЯ"
	_hub_challenges_btn.custom_minimum_size = Vector2(0, 65)
	_hub_challenges_btn.add_theme_font_size_override("font_size", 30)
	_hub_challenges_btn.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	_hub_challenges_btn.pressed.connect(_on_challenges_pressed)
	vbox.add_child(_hub_challenges_btn)

	var garage_btn := Button.new()
	garage_btn.text = "ГАРАЖ"
	garage_btn.custom_minimum_size = Vector2(0, 55)
	garage_btn.add_theme_font_size_override("font_size", 26)
	garage_btn.add_theme_color_override("font_color", Color(0.5, 0.8, 1))
	garage_btn.pressed.connect(_on_garage_pressed)
	vbox.add_child(garage_btn)

	var shop_btn := Button.new()
	shop_btn.text = "АВТОСАЛОН"
	shop_btn.custom_minimum_size = Vector2(0, 55)
	shop_btn.add_theme_font_size_override("font_size", 26)
	shop_btn.add_theme_color_override("font_color", Color(1, 0.8, 0.2))
	shop_btn.pressed.connect(_on_shop_pressed)
	vbox.add_child(shop_btn)

	_add_expand_spacer(vbox)

	var switch_btn := Button.new()
	switch_btn.text = "Сменить профиль"
	switch_btn.custom_minimum_size = Vector2(0, 40)
	switch_btn.add_theme_font_size_override("font_size", 20)
	switch_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	switch_btn.pressed.connect(_on_switch_profile)
	vbox.add_child(switch_btn)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_hub_back)
	vbox.add_child(back_btn)


func _build_location_panel() -> void:
	_location_panel = _create_centered_panel("LocationPanel", Vector2(500, 450))
	add_child(_location_panel)

	var vbox := _create_inner_vbox(_location_panel)

	var title := Label.new()
	title.text = "Выберите город"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	vbox.add_child(title)

	_add_spacer(vbox, 15)

	for location_name in LOCATIONS.keys():
		var btn := Button.new()
		btn.text = location_name
		btn.custom_minimum_size = Vector2(0, 55)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(_on_location_selected.bind(location_name))
		vbox.add_child(btn)

	_add_expand_spacer(vbox)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_location_back)
	vbox.add_child(back_btn)


func _build_challenges_panel() -> void:
	_challenges_panel = _create_centered_panel("ChallengesPanel", Vector2(600, 500))
	add_child(_challenges_panel)

	var vbox := _create_inner_vbox(_challenges_panel)

	var title := Label.new()
	title.text = "ВЫЗОВЫ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	vbox.add_child(title)

	_add_spacer(vbox, 10)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 300)
	vbox.add_child(scroll)

	_challenges_container = VBoxContainer.new()
	_challenges_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_challenges_container)

	_add_spacer(vbox, 10)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_challenges_back)
	vbox.add_child(back_btn)


func _build_garage_panel() -> void:
	_garage_panel = _create_centered_panel("GaragePanel", Vector2(550, 500))
	add_child(_garage_panel)

	var vbox := _create_inner_vbox(_garage_panel)

	var title := Label.new()
	title.text = "ГАРАЖ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.5, 0.8, 1))
	vbox.add_child(title)

	_add_spacer(vbox, 15)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 280)
	vbox.add_child(scroll)

	_garage_cars_container = VBoxContainer.new()
	_garage_cars_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_garage_cars_container)

	_add_spacer(vbox, 10)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_garage_back)
	vbox.add_child(back_btn)


func _build_shop_panel() -> void:
	_shop_panel = _create_centered_panel("ShopPanel", Vector2(600, 550))
	add_child(_shop_panel)

	var vbox := _create_inner_vbox(_shop_panel)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title := Label.new()
	title.text = "АВТОСАЛОН"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(1, 0.8, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	_shop_balance_label = Label.new()
	_shop_balance_label.add_theme_font_size_override("font_size", 22)
	_shop_balance_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	title_row.add_child(_shop_balance_label)

	_add_spacer(vbox, 10)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 350)
	vbox.add_child(scroll)

	_shop_cars_container = VBoxContainer.new()
	_shop_cars_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_shop_cars_container)

	_add_spacer(vbox, 10)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_shop_back)
	vbox.add_child(back_btn)


func _build_tuning_panel() -> void:
	_tuning_panel = _create_centered_panel("TuningPanel", Vector2(550, 480))
	add_child(_tuning_panel)

	var vbox := _create_inner_vbox(_tuning_panel)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	_tuning_title = Label.new()
	_tuning_title.text = "ТЮНИНГ"
	_tuning_title.add_theme_font_size_override("font_size", 32)
	_tuning_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_tuning_title)

	_tuning_balance = Label.new()
	_tuning_balance.add_theme_font_size_override("font_size", 20)
	_tuning_balance.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	title_row.add_child(_tuning_balance)

	_add_spacer(vbox, 15)

	_tuning_container = VBoxContainer.new()
	_tuning_container.add_theme_constant_override("separation", 8)
	vbox.add_child(_tuning_container)

	_add_expand_spacer(vbox)

	var back_btn := _create_back_button()
	back_btn.pressed.connect(_on_tuning_back)
	vbox.add_child(back_btn)


func _build_sell_confirm_panel() -> void:
	_sell_confirm_panel = _create_centered_panel("SellConfirmPanel", Vector2(420, 230))
	add_child(_sell_confirm_panel)

	var vbox := _create_inner_vbox(_sell_confirm_panel)

	_sell_title = Label.new()
	_sell_title.text = "Продать машину?"
	_sell_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sell_title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(_sell_title)

	_add_spacer(vbox, 8)

	_sell_price_label = Label.new()
	_sell_price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sell_price_label.add_theme_font_size_override("font_size", 22)
	_sell_price_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	vbox.add_child(_sell_price_label)

	var warn := Label.new()
	warn.text = "Тюнинг будет потерян!"
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.add_theme_font_size_override("font_size", 18)
	warn.add_theme_color_override("font_color", Color(1, 0.6, 0.6))
	vbox.add_child(warn)

	_add_expand_spacer(vbox)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var cancel_btn := Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(150, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.pressed.connect(_on_sell_cancel)
	hbox.add_child(cancel_btn)

	var spacer_h := Control.new()
	spacer_h.custom_minimum_size = Vector2(20, 0)
	hbox.add_child(spacer_h)

	var sell_btn := Button.new()
	sell_btn.text = "Продать"
	sell_btn.custom_minimum_size = Vector2(150, 50)
	sell_btn.add_theme_font_size_override("font_size", 22)
	sell_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	sell_btn.pressed.connect(_on_sell_confirm)
	hbox.add_child(sell_btn)


# === Навигация ===

func _hide_all() -> void:
	_profile_panel.visible = false
	_hub_panel.visible = false
	_garage_panel.visible = false
	_shop_panel.visible = false
	_create_panel.visible = false
	_delete_confirm_panel.visible = false
	_location_panel.visible = false
	_challenges_panel.visible = false
	_tuning_panel.visible = false
	_sell_confirm_panel.visible = false


func _show_profile_screen() -> void:
	_hide_all()
	_profile_panel.visible = true
	_populate_profiles()


func _show_hub() -> void:
	_hide_all()
	_hub_panel.visible = true
	_update_hub()


func _show_garage() -> void:
	_hide_all()
	_garage_panel.visible = true
	_populate_garage()


func _show_shop() -> void:
	_hide_all()
	_shop_panel.visible = true
	_populate_shop()


func _has_car() -> bool:
	return CareerState.selected_car != "" and CareerState.selected_car in CareerState.owned_cars


# === Профили ===

func _populate_profiles() -> void:
	for child in _profiles_container.get_children():
		child.queue_free()

	var profiles := CareerState.get_profile_names()
	for profile_name in profiles:
		var hbox := HBoxContainer.new()
		_profiles_container.add_child(hbox)

		var btn := Button.new()
		btn.text = profile_name
		btn.custom_minimum_size = Vector2(0, 55)
		btn.add_theme_font_size_override("font_size", 26)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_profile_selected.bind(profile_name))
		hbox.add_child(btn)

		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.custom_minimum_size = Vector2(55, 55)
		del_btn.add_theme_font_size_override("font_size", 22)
		del_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		del_btn.pressed.connect(_on_delete_profile_pressed.bind(profile_name))
		hbox.add_child(del_btn)


func _on_profile_selected(profile_name: String) -> void:
	if CareerState.load_profile(profile_name):
		_show_hub()


func _on_create_profile_pressed() -> void:
	_profile_panel.visible = false
	_create_panel.visible = true
	_name_input.text = ""
	_name_input.grab_focus()


func _on_create_confirm() -> void:
	var profile_name := _name_input.text.strip_edges()
	if profile_name == "":
		return
	if profile_name in CareerState.get_profile_names():
		return
	CareerState.create_profile(profile_name)
	_create_panel.visible = false
	_show_hub()


func _on_name_submitted(_text: String) -> void:
	_on_create_confirm()


func _on_create_cancel() -> void:
	_create_panel.visible = false
	_profile_panel.visible = true


func _on_delete_profile_pressed(profile_name: String) -> void:
	_delete_profile_name = profile_name
	_profile_panel.visible = false
	_delete_confirm_panel.visible = true
	_delete_title.text = "Удалить \"%s\"?" % profile_name


func _on_delete_confirm() -> void:
	CareerState.delete_profile(_delete_profile_name)
	_delete_profile_name = ""
	_delete_confirm_panel.visible = false
	_show_profile_screen()


func _on_delete_cancel() -> void:
	_delete_profile_name = ""
	_delete_confirm_panel.visible = false
	_profile_panel.visible = true


func _on_profile_back() -> void:
	hide_menu()
	back_to_main_menu.emit()


# === Хаб карьеры ===

func _update_hub() -> void:
	_hub_profile_label.text = CareerState.active_profile
	_hub_balance_label.text = CareerState.format_money(CareerState.balance)
	_hub_stats_label.text = "Побед: %d / Гонок: %d | Заказов: %d" % [
		CareerState.races_won, CareerState.total_races, CareerState.orders_completed]

	var has_car := _has_car()
	if has_car:
		var car_name := CarSettings.get_car_name(CareerState.selected_car)
		_hub_car_label.text = "Машина: %s" % car_name
		_hub_car_label.remove_theme_color_override("font_color")
	else:
		_hub_car_label.text = "Сначала купите машину!"
		_hub_car_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))

	_hub_freeroam_btn.disabled = not has_car
	_hub_challenges_btn.disabled = not has_car


func _on_work_pressed() -> void:
	if not _has_car():
		return
	_hide_all()
	_location_panel.visible = true


func _on_challenges_pressed() -> void:
	if not _has_car():
		return
	_hide_all()
	_challenges_panel.visible = true
	_populate_challenges()


func _on_garage_pressed() -> void:
	_show_garage()


func _on_shop_pressed() -> void:
	_show_shop()


func _on_switch_profile() -> void:
	_show_profile_screen()


func _on_hub_back() -> void:
	hide_menu()
	back_to_main_menu.emit()


# === Выезд в город ===

func _on_location_selected(location_name: String) -> void:
	var coords: Array = LOCATIONS[location_name]
	RaceState.free_roam_location = location_name
	RaceState.free_roam_lat = coords[0]
	RaceState.free_roam_lon = coords[1]
	RaceState.selected_track = null
	RaceState.is_career_race = false
	RaceState.is_work_mode = true
	if MusicManager:
		MusicManager.play_next_track()
	get_tree().change_scene_to_file("res://main.tscn")


func _on_location_back() -> void:
	_show_hub()


# === Вызовы ===

func _populate_challenges() -> void:
	for child in _challenges_container.get_children():
		child.queue_free()

	var tracks: Array = RaceTrackScript.get_all_tracks()
	for track in tracks:
		if not track:
			continue
		var track_id: String = track.track_id
		var prize := CareerState.get_challenge_prize(track_id)
		var entry_fee := CareerState.get_entry_fee(track_id)
		var can_enter := CareerState.can_afford_entry(track_id)

		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 95)
		_challenges_container.add_child(panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 15)
		panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = track.track_name
		name_label.add_theme_font_size_override("font_size", 26)
		info_vbox.add_child(name_label)

		var mode_text := "Спринт" if track.race_mode == "sprint" else "Чекпоинт"
		var desc_label := Label.new()
		desc_label.text = "%s  |  Приз: %s" % [mode_text, CareerState.format_money(prize)]
		desc_label.add_theme_font_size_override("font_size", 17)
		desc_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		info_vbox.add_child(desc_label)

		var fee_label := Label.new()
		fee_label.text = "Взнос: %s" % CareerState.format_money(entry_fee)
		fee_label.add_theme_font_size_override("font_size", 16)
		if can_enter:
			fee_label.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		else:
			fee_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		info_vbox.add_child(fee_label)

		var race_btn := Button.new()
		race_btn.text = "Гонка!"
		race_btn.custom_minimum_size = Vector2(120, 50)
		race_btn.add_theme_font_size_override("font_size", 22)
		race_btn.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		if not can_enter:
			race_btn.disabled = true
			# Показываем помощь от администрации
			var help_btn := Button.new()
			help_btn.text = "Получить 5 000 руб."
			help_btn.custom_minimum_size = Vector2(180, 40)
			help_btn.add_theme_font_size_override("font_size", 16)
			help_btn.tooltip_text = "Помощь от администрации"
			help_btn.pressed.connect(_on_admin_help.bind(help_btn, race_btn))
			hbox.add_child(help_btn)
		else:
			race_btn.pressed.connect(_on_challenge_selected.bind(track))
		hbox.add_child(race_btn)


func _on_admin_help(_help_btn: Button, _race_btn: Button) -> void:
	CareerState.balance += 5000
	CareerState.save_profile()
	_hub_balance_label.text = CareerState.format_money(CareerState.balance)
	# Перестраиваем вызовы чтобы обновить кнопки
	_populate_challenges()


func _on_challenge_selected(track) -> void:
	# Списываем взнос
	CareerState.pay_entry_fee(track.track_id)
	RaceState.selected_track = track
	RaceState.free_roam_location = ""
	RaceState.is_career_race = true
	RaceState.is_work_mode = false
	if MusicManager:
		MusicManager.play_next_track()
	get_tree().change_scene_to_file("res://race/race_scene.tscn")


func _on_challenges_back() -> void:
	_show_hub()


# === Гараж ===

func _populate_garage() -> void:
	for child in _garage_cars_container.get_children():
		child.queue_free()

	if CareerState.owned_cars.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Гараж пуст. Купите машину в автосалоне!"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_font_size_override("font_size", 22)
		empty_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_garage_cars_container.add_child(empty_label)
		return

	for car_id in CareerState.owned_cars:
		var is_selected := car_id == CareerState.selected_car
		var car_name := CarSettings.get_car_name(car_id)

		var row_panel := PanelContainer.new()
		row_panel.custom_minimum_size = Vector2(0, 70)
		_garage_cars_container.add_child(row_panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 10)
		row_panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = car_name
		name_label.add_theme_font_size_override("font_size", 22)
		if is_selected:
			name_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
		info_vbox.add_child(name_label)

		# Показываем уровни тюнинга
		var tuning_parts: Array[String] = []
		for cat in CareerState.TUNING_CATEGORIES:
			var lvl := CareerState.get_tuning_level(car_id, cat)
			if lvl > 0:
				tuning_parts.append("%s %d" % [CareerState.TUNING_NAMES[cat], lvl])
		if not tuning_parts.is_empty():
			var tuning_label := Label.new()
			tuning_label.text = ", ".join(tuning_parts)
			tuning_label.add_theme_font_size_override("font_size", 14)
			tuning_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
			info_vbox.add_child(tuning_label)

		# Кнопки
		if is_selected:
			var badge := Label.new()
			badge.text = "V"
			badge.add_theme_font_size_override("font_size", 20)
			badge.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
			hbox.add_child(badge)
		else:
			var select_btn := Button.new()
			select_btn.text = "Выбрать"
			select_btn.custom_minimum_size = Vector2(90, 0)
			select_btn.add_theme_font_size_override("font_size", 16)
			select_btn.pressed.connect(_on_garage_select.bind(car_id))
			hbox.add_child(select_btn)

		var tuning_btn := Button.new()
		tuning_btn.text = "Тюнинг"
		tuning_btn.custom_minimum_size = Vector2(90, 0)
		tuning_btn.add_theme_font_size_override("font_size", 16)
		tuning_btn.add_theme_color_override("font_color", Color(0.5, 0.8, 1))
		tuning_btn.pressed.connect(_on_tuning_pressed.bind(car_id))
		hbox.add_child(tuning_btn)

		var sell_btn := Button.new()
		sell_btn.text = "Продать"
		sell_btn.custom_minimum_size = Vector2(90, 0)
		sell_btn.add_theme_font_size_override("font_size", 16)
		sell_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		sell_btn.pressed.connect(_on_sell_pressed.bind(car_id))
		hbox.add_child(sell_btn)


func _on_garage_select(car_id: String) -> void:
	CareerState.select_car(car_id)
	_populate_garage()


func _on_garage_back() -> void:
	_show_hub()


# === Продажа ===

func _on_sell_pressed(car_id: String) -> void:
	_sell_car_id = car_id
	var car_name := CarSettings.get_car_name(car_id)
	var sell_price := CareerState.get_sell_price(car_id)
	_sell_title.text = "Продать %s?" % car_name
	_sell_price_label.text = "+ %s" % CareerState.format_money(sell_price)
	_garage_panel.visible = false
	_sell_confirm_panel.visible = true


func _on_sell_confirm() -> void:
	CareerState.sell_car(_sell_car_id)
	_sell_car_id = ""
	_sell_confirm_panel.visible = false
	_show_garage()


func _on_sell_cancel() -> void:
	_sell_car_id = ""
	_sell_confirm_panel.visible = false
	_garage_panel.visible = true


# === Тюнинг ===

func _on_tuning_pressed(car_id: String) -> void:
	_tuning_car_id = car_id
	_hide_all()
	_tuning_panel.visible = true
	_populate_tuning()


func _populate_tuning() -> void:
	var car_name := CarSettings.get_car_name(_tuning_car_id)
	_tuning_title.text = "Тюнинг: %s" % car_name
	_tuning_balance.text = CareerState.format_money(CareerState.balance)

	for child in _tuning_container.get_children():
		child.queue_free()

	for category in CareerState.TUNING_CATEGORIES:
		var cat_name: String = CareerState.TUNING_NAMES[category]
		var level := CareerState.get_tuning_level(_tuning_car_id, category)
		var max_level: int = CareerState.TUNING_MAX_LEVEL

		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 75)
		_tuning_container.add_child(panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 15)
		panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = cat_name
		name_label.add_theme_font_size_override("font_size", 24)
		info_vbox.add_child(name_label)

		# Уровень: шкала из блоков
		var level_hbox := HBoxContainer.new()
		level_hbox.add_theme_constant_override("separation", 4)
		info_vbox.add_child(level_hbox)

		var lvl_label := Label.new()
		lvl_label.text = "Ур. "
		lvl_label.add_theme_font_size_override("font_size", 16)
		lvl_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		level_hbox.add_child(lvl_label)

		for i in range(max_level):
			var block := Label.new()
			block.text = "■" if i < level else "□"
			block.add_theme_font_size_override("font_size", 18)
			if i < level:
				block.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
			else:
				block.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
			level_hbox.add_child(block)

		if level < max_level:
			var price := CareerState.get_tuning_upgrade_price(_tuning_car_id, category)
			var can_afford := CareerState.balance >= price

			var right_vbox := VBoxContainer.new()
			right_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
			hbox.add_child(right_vbox)

			var price_label := Label.new()
			price_label.text = CareerState.format_money(price)
			price_label.add_theme_font_size_override("font_size", 16)
			if can_afford:
				price_label.add_theme_color_override("font_color", Color(1, 1, 1))
			else:
				price_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
			right_vbox.add_child(price_label)

			var upgrade_btn := Button.new()
			upgrade_btn.text = "Улучшить"
			upgrade_btn.custom_minimum_size = Vector2(110, 35)
			upgrade_btn.add_theme_font_size_override("font_size", 18)
			upgrade_btn.disabled = not can_afford
			upgrade_btn.pressed.connect(_on_upgrade_pressed.bind(category))
			right_vbox.add_child(upgrade_btn)
		else:
			var max_label := Label.new()
			max_label.text = "МАКС"
			max_label.add_theme_font_size_override("font_size", 20)
			max_label.add_theme_color_override("font_color", Color(1, 0.85, 0))
			hbox.add_child(max_label)


func _on_upgrade_pressed(category: String) -> void:
	CareerState.upgrade_tuning(_tuning_car_id, category)
	_populate_tuning()


func _on_tuning_back() -> void:
	_tuning_car_id = ""
	_show_garage()


# === Магазин ===

func _populate_shop() -> void:
	_shop_balance_label.text = CareerState.format_money(CareerState.balance)

	for child in _shop_cars_container.get_children():
		child.queue_free()

	# Сортируем по цене
	var car_ids := CarSettings.get_car_ids()
	var sorted_ids: Array[String] = []
	for cid in car_ids:
		sorted_ids.append(cid)
	sorted_ids.sort_custom(func(a: String, b: String) -> bool:
		return CareerState.get_car_price(a) < CareerState.get_car_price(b)
	)

	for car_id in sorted_ids:
		var price := CareerState.get_car_price(car_id)
		if price <= 0:
			continue
		var owned := car_id in CareerState.owned_cars
		var can_afford := CareerState.can_afford(car_id)
		var car_name := CarSettings.get_car_name(car_id)

		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 80)
		_shop_cars_container.add_child(panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 15)
		panel.add_child(hbox)

		var info_vbox := VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(info_vbox)

		var name_label := Label.new()
		name_label.text = car_name
		name_label.add_theme_font_size_override("font_size", 24)
		info_vbox.add_child(name_label)

		var stats: Dictionary = CarSettings.DISPLAY_STATS.get(car_id, {})
		if not stats.is_empty():
			var stats_text := "Разгон: %.0f  Скорость: %.0f  Управление: %.0f" % [
				stats.get("accel", 0.5) * 10,
				stats.get("speed", 0.5) * 10,
				stats.get("handling", 0.5) * 10
			]
			var stats_label := Label.new()
			stats_label.text = stats_text
			stats_label.add_theme_font_size_override("font_size", 16)
			stats_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			info_vbox.add_child(stats_label)

		var right_vbox := VBoxContainer.new()
		right_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		hbox.add_child(right_vbox)

		if owned:
			var owned_label := Label.new()
			owned_label.text = "В гараже"
			owned_label.add_theme_font_size_override("font_size", 20)
			owned_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
			right_vbox.add_child(owned_label)
		else:
			var price_label := Label.new()
			price_label.text = CareerState.format_money(price)
			price_label.add_theme_font_size_override("font_size", 18)
			if can_afford:
				price_label.add_theme_color_override("font_color", Color(1, 1, 1))
			else:
				price_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
			right_vbox.add_child(price_label)

			var buy_btn := Button.new()
			buy_btn.text = "Купить"
			buy_btn.custom_minimum_size = Vector2(120, 40)
			buy_btn.add_theme_font_size_override("font_size", 20)
			buy_btn.disabled = not can_afford
			buy_btn.pressed.connect(_on_shop_buy.bind(car_id))
			right_vbox.add_child(buy_btn)


func _on_shop_buy(car_id: String) -> void:
	if CareerState.buy_car(car_id):
		if CareerState.owned_cars.size() == 1:
			CareerState.select_car(car_id)
		_populate_shop()


func _on_shop_back() -> void:
	_show_hub()


# === Хелперы для построения UI ===

func _create_centered_panel(panel_name: String, size: Vector2) -> Panel:
	var panel := Panel.new()
	panel.name = panel_name
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -size.x / 2
	panel.offset_right = size.x / 2
	panel.offset_top = -size.y / 2
	panel.offset_bottom = size.y / 2
	panel.visible = false
	return panel


func _create_inner_vbox(panel: Panel) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 30
	vbox.offset_top = 25
	vbox.offset_right = -30
	vbox.offset_bottom = -25
	panel.add_child(vbox)
	return vbox


func _create_back_button() -> Button:
	var btn := Button.new()
	btn.text = "Назад"
	btn.custom_minimum_size = Vector2(0, 50)
	btn.add_theme_font_size_override("font_size", 24)
	return btn


func _add_spacer(parent: Control, height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	parent.add_child(spacer)


func _add_expand_spacer(parent: Control) -> void:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)
