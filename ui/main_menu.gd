extends Control

signal start_game
signal quit_game

@export var terrain_generator_path: NodePath
@export var car_path: NodePath
@export var world_root_path: NodePath
@export var hud_path: NodePath
@export var camera_path: NodePath

# Доступные локации: название -> [широта, долгота]
const LOCATIONS := {
	"Череповец": [59.150406, 37.948805],
	"Москва (Отрадное)": [55.860580, 37.599646],
	"Тбилиси (Важа-Пшавела)": [41.723972, 44.730502],
	"Дубай (Крик)": [25.208591, 55.344100],
}

var _terrain_generator: Node3D
var _car: Node3D  # VehicleController wrapper
var _car_rigidbody: RigidBody3D  # Actual Vehicle RigidBody3D
var _world_root: Node3D
var _hud: Control
var _camera: Camera3D
var _night_manager: Node
var _graphics_settings: Node
var _car_lights: Node3D
var _is_loading := false
var _game_started := false  # Игра уже была запущена
var _is_apply_settings_reload := false  # Флаг перезагрузки через Apply Settings
var _selected_location := "Череповец"

func _ready() -> void:
	# Показываем курсор в меню
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true

	# Получаем ссылки на объекты
	await get_tree().process_frame
	if terrain_generator_path:
		_terrain_generator = get_node(terrain_generator_path)
	if car_path:
		_car = get_node(car_path)
		# Теперь _car указывает прямо на RigidBody3D (как в аркаде)
		_car_rigidbody = _car if _car is RigidBody3D else null
		# КРИТИЧНО: Сразу замораживаем машину чтобы не упала до _hide_world()
		if _car_rigidbody and _car_rigidbody is RigidBody3D:
			_car_rigidbody.freeze = true
	if world_root_path:
		_world_root = get_node(world_root_path)
	if hud_path:
		_hud = get_node(hud_path)
	if camera_path:
		_camera = get_node(camera_path)

	# Находим NightModeManager
	_night_manager = get_tree().current_scene.find_child("NightModeManager", true, false)
	if _night_manager:
		_night_manager.night_mode_changed.connect(_on_night_mode_state_changed)
		_night_manager.rain_changed.connect(_on_rain_state_changed)

	# Находим GraphicsSettings
	_graphics_settings = get_tree().current_scene.find_child("GraphicsSettings", true, false)

	# Подключаем сигналы от генератора террейна
	if _terrain_generator:
		_terrain_generator.initial_load_started.connect(_on_load_started)
		_terrain_generator.initial_load_progress.connect(_on_load_progress)
		_terrain_generator.initial_load_complete.connect(_on_load_complete)

	# Скрываем мир до загрузки
	_hide_world()

	# Масштабируем UI для fullscreen (вызываем после layout)
	await get_tree().process_frame
	_scale_for_screen()

	# Автостарт через командную строку: --autostart [location_index]
	# В Godot пользовательские аргументы идут после '--'
	# Пример: godot -- --autostart 0
	var args := OS.get_cmdline_user_args()
	print("MainMenu: User args: ", args)

	# Проверяем есть ли --autostart в пользовательских аргументах
	var autostart_idx := -1
	for i in range(args.size()):
		if args[i] == "--autostart":
			autostart_idx = i
			break

	if autostart_idx >= 0:
		print("MainMenu: Autostart requested!")
		var location_idx := 0
		if autostart_idx + 1 < args.size():
			location_idx = int(args[autostart_idx + 1])
		print("MainMenu: Autostart location index: ", location_idx)
		var locations := LOCATIONS.keys()
		print("MainMenu: Available locations: ", locations)
		if location_idx >= 0 and location_idx < locations.size():
			_selected_location = locations[location_idx]
			print("MainMenu: Selected location for autostart: ", _selected_location)
		else:
			print("WARNING: Invalid location index ", location_idx, ", using default")
		await get_tree().process_frame
		print("MainMenu: Starting autostart loading...")
		_start_loading()
	else:
		print("MainMenu: No autostart - showing main menu")

func _on_continue_pressed() -> void:
	# Просто продолжаем игру без повторной загрузки
	hide_menu()

func _on_start_pressed() -> void:
	if _is_loading:
		return

	# Показываем панель выбора локации (и для первого старта, и для новой игры)
	$VBox.visible = false
	$LocationPanel.visible = true

func _on_location_selected(location_name: String) -> void:
	_selected_location = location_name
	_start_loading()

func _on_location_back_pressed() -> void:
	$LocationPanel.visible = false
	$VBox.visible = true

func _on_cherepovets_pressed() -> void:
	_on_location_selected("Череповец")

func _on_moscow_pressed() -> void:
	_on_location_selected("Москва (Отрадное)")

func _on_tbilisi_pressed() -> void:
	_on_location_selected("Тбилиси (Важа-Пшавела)")

func _on_dubai_pressed() -> void:
	_on_location_selected("Дубай (Крик)")

func _start_loading() -> void:
	print("MainMenu: _start_loading() called")
	_is_loading = true

	# Скрываем панель выбора, показываем экран загрузки
	$LocationPanel.visible = false
	$LoadingPanel.visible = true
	$LoadingPanel/VBox/ProgressBar.value = 0
	$LoadingPanel/VBox/StatusLabel.text = "Подготовка..."

	# Если игра уже была запущена - сбрасываем террейн
	if _game_started and _terrain_generator:
		print("MainMenu: Resetting terrain...")
		_terrain_generator.reset_terrain()

	# Сбрасываем машину на начальную позицию
	if _car_rigidbody and _car_rigidbody is RigidBody3D:
		# КРИТИЧНО: Сначала обнуляем скорости, потом замораживаем
		_car_rigidbody.linear_velocity = Vector3.ZERO
		_car_rigidbody.angular_velocity = Vector3.ZERO
		_car_rigidbody.freeze = true
		# Сбрасываем позицию только после заморозки
		_car.global_position = Vector3(0, 2, 0)
		_car.rotation = Vector3.ZERO
	elif _car:
		print("WARNING: Car RigidBody not found, cannot reset safely!")

	# Сбрасываем камеру
	if _camera and _camera.has_method("reset_camera"):
		_camera.reset_camera()

	# Устанавливаем координаты для генератора
	if _terrain_generator:
		print("MainMenu: Setting coordinates and starting terrain loading...")
		var coords: Array = LOCATIONS[_selected_location]
		_terrain_generator.start_lat = coords[0]
		_terrain_generator.start_lon = coords[1]
		print("MainMenu: Calling terrain_generator.start_loading()...")
		_terrain_generator.start_loading()
		print("MainMenu: terrain_generator.start_loading() returned")
	else:
		print("MainMenu: No terrain generator, starting game immediately")
		# Если нет генератора - сразу показываем игру
		_start_game()

func _on_load_started() -> void:
	print("MainMenu: _on_load_started() called!")
	$LoadingPanel/VBox/ProgressBar.value = 0
	$LoadingPanel/VBox/StatusLabel.text = "Загрузка карты..."

func _on_load_progress(progress: float, status: String) -> void:
	$LoadingPanel/VBox/ProgressBar.value = progress * 100.0
	$LoadingPanel/VBox/StatusLabel.text = status

func _on_load_complete() -> void:
	$LoadingPanel/VBox/ProgressBar.value = 100
	$LoadingPanel/VBox/StatusLabel.text = "Готово!"

	# Небольшая задержка для отображения 100%
	await get_tree().create_timer(0.3).timeout

	# ВАЖНО: Проверяем что загрузка всё ещё активна после await
	if not _is_loading:
		print("WARNING: Loading was cancelled during completion delay")
		return

	_start_game()

func _start_game() -> void:
	_game_started = true

	# Спавним машину на дороге только при первом запуске
	# При Apply Settings машина уже на дороге, просто возвращаем её
	if not _is_apply_settings_reload:
		_spawn_car_on_road()

	# КРИТИЧНО: Ждём один физический кадр чтобы машина стабилизировалась
	await get_tree().physics_frame

	# ВАЖНО: Проверяем что загрузка не была прервана во время await
	if not _is_loading:
		print("WARNING: Loading flag was cleared during await, aborting _start_game()")
		return

	# ВАЖНО: Проверяем что машина всё ещё существует после await
	if not is_instance_valid(_car):
		print("ERROR: Car was deleted during await!")
		_is_loading = false
		return

	# Показываем мир (размораживаем машину)
	_show_world()

	# КРИТИЧНО: Снимаем флаги загрузки только после полной инициализации
	_is_loading = false
	_is_apply_settings_reload = false  # Сбрасываем флаг перезагрузки

	# Показываем HUD
	if _hud:
		_hud.show_hud()

	# Переключаем на следующий трек после загрузки
	# MusicManager - это autoload (синглтон), доступен напрямую
	if MusicManager:
		print("MainMenu: calling play_next_track(), current index = ", MusicManager.current_track_index)
		MusicManager.play_next_track()
		print("MainMenu: after play_next_track(), new index = ", MusicManager.current_track_index)

	# Скрываем меню
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	start_game.emit()


func _spawn_car_on_road() -> void:
	"""Спавнит машину на ближайшей дороге вдоль направления движения"""
	if not _car:
		return

	# Находим TrafficManager для доступа к RoadNetwork
	var traffic_manager = get_tree().current_scene.find_child("TrafficManager", true, false)
	if not traffic_manager or not traffic_manager.has_method("get_road_network"):
		print("MainMenu: TrafficManager not found, using default spawn")
		return

	var road_network = traffic_manager.get_road_network()
	if road_network == null or road_network.all_waypoints.is_empty():
		print("MainMenu: No road network available, using default spawn")
		return

	# Текущая позиция машины (начальная точка)
	var current_pos := _car.global_position

	# Ищем ближайший waypoint
	var nearest_wp = road_network.get_nearest_waypoint(current_pos)
	if nearest_wp == null:
		print("MainMenu: No waypoints found, using default spawn")
		return

	# Получаем позицию и направление дороги
	var road_pos: Vector3 = nearest_wp.position
	var road_dir: Vector3 = nearest_wp.direction

	# ПРОВЕРКА: Убедимся что позиция валидна
	if not road_pos.is_finite():
		print("ERROR: road_pos is NaN! Using default spawn position")
		road_pos = Vector3(0, 2, 0)
	if not road_dir.is_finite():
		print("ERROR: road_dir is NaN! Using default direction")
		road_dir = Vector3(0, 0, 1)

	# Поднимаем машину чуть выше дороги
	road_pos.y += 0.5

	# КРИТИЧНО: Сначала замораживаем машину перед изменением transform
	if not (_car_rigidbody is RigidBody3D):
		print("ERROR: Car RigidBody not found! Cannot spawn safely.")
		return

	_car_rigidbody.linear_velocity = Vector3.ZERO
	_car_rigidbody.angular_velocity = Vector3.ZERO
	_car_rigidbody.freeze = true

	# Устанавливаем позицию (машина уже заморожена)
	# Используем VehicleController родителя для позиционирования
	_car.global_position = road_pos

	# ПРОВЕРКА: Убедимся что позиция не стала NaN после установки
	if not _car.global_position.is_finite():
		print("ERROR: Car position became NaN after assignment! Road pos was: ", road_pos)
		_car.global_position = Vector3(0, 2, 0)

	# Поворачиваем машину вдоль дороги
	# direction - это нормализованный вектор направления движения
	var final_yaw := 0.0
	if road_dir.length_squared() > 0.01:
		var yaw := atan2(road_dir.x, road_dir.z)
		_car.rotation = Vector3(0, yaw, 0)
		final_yaw = yaw

	# ПРОВЕРКА: Убедимся что rotation не стал NaN
	if not _car.rotation.is_finite():
		print("ERROR: Car rotation became NaN! Yaw was: ", final_yaw)
		_car.rotation = Vector3.ZERO

	print("MainMenu: Spawned car on road at (%.1f, %.1f, %.1f), heading %.0f°" % [
		_car.global_position.x, _car.global_position.y, _car.global_position.z, rad_to_deg(final_yaw)
	])

	# Для GEVP Vehicle - переключаем на 1-ю передачу и включаем автомат
	if _car_rigidbody and _car_rigidbody.has_method("set"):
		if _car_rigidbody.get("current_gear") != null:
			_car_rigidbody.current_gear = 1  # 1-я передача
			if _car_rigidbody.get("automatic_transmission") != null:
				_car_rigidbody.automatic_transmission = true
			print("MainMenu: Set GEVP to gear 1 with automatic transmission")

func _hide_world() -> void:
	# Скрываем машину
	if _car:
		_car.visible = false
		# Замораживаем физику машины
		if _car_rigidbody is RigidBody3D:
			_car_rigidbody.freeze = true

func _show_world() -> void:
	# Показываем машину
	if _car:
		_car.visible = true
		# Размораживаем физику машины
		if _car_rigidbody is RigidBody3D:
			# КРИТИЧНО: Перед размораживанием проверяем что скорости нулевые
			_car_rigidbody.linear_velocity = Vector3.ZERO
			_car_rigidbody.angular_velocity = Vector3.ZERO
			# Проверяем что позиция валидна
			if not _car.global_position.is_finite():
				print("ERROR: Car position is NaN before unfreeze! Resetting...")
				_car.global_position = Vector3(0, 2, 0)
			if not _car.rotation.is_finite():
				print("ERROR: Car rotation is NaN before unfreeze! Resetting...")
				_car.rotation = Vector3.ZERO
			_car_rigidbody.freeze = false

func _on_controls_pressed() -> void:
	$ControlsPanel.visible = not $ControlsPanel.visible

func _on_quit_pressed() -> void:
	quit_game.emit()
	get_tree().quit()

func _on_back_pressed() -> void:
	$ControlsPanel.visible = false

func _input(event: InputEvent) -> void:
	# Escape открывает/закрывает меню (но не во время загрузки)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _is_loading:
			return
		if not visible:
			show_menu()

func show_menu() -> void:
	visible = true
	$VBox.visible = true
	$LoadingPanel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true
	if _hud:
		_hud.hide_hud()

	# Показываем кнопку "Продолжить" если игра уже запущена
	$VBox/ContinueButton.visible = _game_started
	# Меняем текст кнопки "Старт" если игра уже запущена
	$VBox/StartButton.text = "Новая игра" if _game_started else "Старт"

func hide_menu() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false
	if _hud:
		_hud.show_hud()

func _scale_for_screen() -> void:
	# Не масштабируем - используем большие шрифты в tscn
	pass


# === Настройки ===

func _on_settings_pressed() -> void:
	$VBox.visible = false
	$SettingsPanel.visible = true
	# Синхронизируем чекбоксы с текущим состоянием
	if _night_manager:
		$SettingsPanel/VBox/NightModeCheck.set_pressed_no_signal(_night_manager.is_night)
		$SettingsPanel/VBox/RainCheck.set_pressed_no_signal(_night_manager.is_raining)
	# Синхронизируем неон
	_update_underglow_checkbox()
	# Синхронизируем графические настройки
	_update_graphics_checkboxes()


func _on_apply_settings_pressed() -> void:
	# Применяем настройки - перезагружаем террейн для применения Normal Maps
	if _is_loading:
		print("MainMenu: Cannot apply settings while loading")
		return
	if _terrain_generator and _game_started:
		print("MainMenu: Applying graphics settings - reloading terrain...")

		# КРИТИЧНО: Устанавливаем флаги загрузки
		_is_loading = true
		_is_apply_settings_reload = true  # Это перезагрузка, не первый запуск

		# Скрываем панель настроек, показываем экран загрузки
		$SettingsPanel.visible = false
		$LoadingPanel.visible = true
		$LoadingPanel/VBox/ProgressBar.value = 0
		$LoadingPanel/VBox/StatusLabel.text = "Применение настроек..."

		# Прячем HUD
		if _hud:
			_hud.hide_hud()

		# КРИТИЧНО: Скрываем и замораживаем машину ПЕРЕД снятием паузы
		if _car and _car_rigidbody is RigidBody3D:
			_car.visible = false
			# Сначала обнуляем скорости, потом замораживаем
			_car_rigidbody.linear_velocity = Vector3.ZERO
			_car_rigidbody.angular_velocity = Vector3.ZERO
			_car_rigidbody.freeze = true
			# НЕ сбрасываем позицию - оставляем машину где она была
		elif _car:
			print("WARNING: Car RigidBody not found in Apply settings!")

		# ВАЖНО: Снимаем паузу для загрузки ПОСЛЕ заморозки машины
		get_tree().paused = false

		# Сбрасываем террейн
		_terrain_generator.reset_terrain()

		# Запускаем перезагрузку
		var coords: Array = LOCATIONS[_selected_location]
		_terrain_generator.start_lat = coords[0]
		_terrain_generator.start_lon = coords[1]
		_terrain_generator.start_loading()
	else:
		print("MainMenu: Settings will be applied on next game start")
		# Просто закрываем настройки
		$SettingsPanel.visible = false
		$VBox.visible = true


func _on_settings_back_pressed() -> void:
	$SettingsPanel.visible = false
	$VBox.visible = true


func _on_night_mode_toggled(toggled_on: bool) -> void:
	if not _night_manager:
		return
	if toggled_on and not _night_manager.is_night:
		_night_manager.enable_night_mode()
	elif not toggled_on and _night_manager.is_night:
		_night_manager.disable_night_mode()


func _on_rain_toggled(toggled_on: bool) -> void:
	if not _night_manager:
		return
	if toggled_on != _night_manager.is_raining:
		_night_manager.toggle_rain()


func _on_night_mode_state_changed(enabled: bool) -> void:
	# Обновляем чекбокс при изменении извне (клавиша N)
	if has_node("SettingsPanel/VBox/NightModeCheck"):
		$SettingsPanel/VBox/NightModeCheck.set_pressed_no_signal(enabled)


func _on_rain_state_changed(enabled: bool) -> void:
	# Обновляем чекбокс при изменении извне (клавиша R)
	if has_node("SettingsPanel/VBox/RainCheck"):
		$SettingsPanel/VBox/RainCheck.set_pressed_no_signal(enabled)


func _on_underglow_toggled(toggled_on: bool) -> void:
	var car_lights := _get_car_lights()
	if car_lights and car_lights.has_method("set_underglow_enabled"):
		car_lights.set_underglow_enabled(toggled_on)


func _update_underglow_checkbox() -> void:
	var car_lights := _get_car_lights()
	if car_lights and has_node("SettingsPanel/VBox/UnderglowCheck"):
		$SettingsPanel/VBox/UnderglowCheck.set_pressed_no_signal(car_lights.underglow_enabled)


func _get_car_lights() -> Node3D:
	if _car_lights:
		return _car_lights
	if _car:
		_car_lights = _car.find_child("CarLights", true, false)
	return _car_lights


# === Графические настройки ===

func _update_graphics_checkboxes() -> void:
	if not _graphics_settings:
		return
	$SettingsPanel/VBox/SSRCheck.set_pressed_no_signal(_graphics_settings.ssr_enabled)
	$SettingsPanel/VBox/FogCheck.set_pressed_no_signal(_graphics_settings.fog_enabled)
	$SettingsPanel/VBox/GlowCheck.set_pressed_no_signal(_graphics_settings.glow_enabled)
	$SettingsPanel/VBox/SSAOCheck.set_pressed_no_signal(_graphics_settings.ssao_enabled)
	$SettingsPanel/VBox/NormalMapsCheck.set_pressed_no_signal(_graphics_settings.normal_maps_enabled)
	$SettingsPanel/VBox/CloudsCheck.set_pressed_no_signal(_graphics_settings.clouds_enabled)
	$SettingsPanel/VBox/TAACheck.set_pressed_no_signal(_graphics_settings.taa_enabled)
	$SettingsPanel/VBox/FXAACheck.set_pressed_no_signal(_graphics_settings.fxaa_enabled)
	$SettingsPanel/VBox/DOFCheck.set_pressed_no_signal(_graphics_settings.dof_enabled)
	$SettingsPanel/VBox/VignetteCheck.set_pressed_no_signal(_graphics_settings.vignette_enabled)
	# MSAA option
	var msaa_idx := 0
	match _graphics_settings.msaa_mode:
		Viewport.MSAA_DISABLED:
			msaa_idx = 0
		Viewport.MSAA_2X:
			msaa_idx = 1
		Viewport.MSAA_4X:
			msaa_idx = 2
	$SettingsPanel/VBox/MSAAOption.select(msaa_idx)
	# Render distance slider
	var slider := $SettingsPanel/VBox/RenderDistBox/RenderDistSlider as HSlider
	if slider:
		slider.set_value_no_signal(_graphics_settings.render_distance)
	var label := $SettingsPanel/VBox/RenderDistBox/RenderDistValue as Label
	if label:
		label.text = "%.0f м" % _graphics_settings.render_distance


func _on_ssr_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.ssr_enabled = toggled_on
		_graphics_settings._apply_ssr()
		_graphics_settings.settings_changed.emit()


func _on_fog_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.fog_enabled = toggled_on
		_graphics_settings._apply_fog()
		_graphics_settings.settings_changed.emit()


func _on_glow_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.glow_enabled = toggled_on
		_graphics_settings._apply_glow()
		_graphics_settings.settings_changed.emit()


func _on_ssao_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.ssao_enabled = toggled_on
		_graphics_settings._apply_ssao()
		_graphics_settings.settings_changed.emit()


func _on_normal_maps_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.normal_maps_enabled = toggled_on
		_graphics_settings.settings_changed.emit()


func _on_clouds_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.clouds_enabled = toggled_on
		_graphics_settings.settings_changed.emit()


func _on_taa_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.taa_enabled = toggled_on
		_graphics_settings._apply_taa()
		_graphics_settings.settings_changed.emit()


func _on_fxaa_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.fxaa_enabled = toggled_on
		_graphics_settings._apply_fxaa()
		_graphics_settings.settings_changed.emit()


func _on_msaa_selected(index: int) -> void:
	if _graphics_settings:
		var mode: Viewport.MSAA
		match index:
			0:
				mode = Viewport.MSAA_DISABLED
			1:
				mode = Viewport.MSAA_2X
			2:
				mode = Viewport.MSAA_4X
			_:
				mode = Viewport.MSAA_DISABLED
		_graphics_settings.set_msaa(mode)


func _on_dof_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.dof_enabled = toggled_on
		_graphics_settings._apply_dof()
		_graphics_settings.settings_changed.emit()


func _on_vignette_toggled(toggled_on: bool) -> void:
	if _graphics_settings:
		_graphics_settings.vignette_enabled = toggled_on
		_graphics_settings._apply_vignette()
		_graphics_settings.settings_changed.emit()


func _on_render_dist_changed(value: float) -> void:
	if _graphics_settings:
		_graphics_settings.set_render_distance(value)
	# Обновляем метку
	var label := $SettingsPanel/VBox/RenderDistBox/RenderDistValue as Label
	if label:
		label.text = "%.0f м" % value
