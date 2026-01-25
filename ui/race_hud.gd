extends Control

## HUD для режима гонки: обратный отсчёт, таймер, результаты

const RaceManagerScript = preload("res://race/race_manager.gd")

@export var race_manager_path: NodePath

var _race_manager  # RaceManager


func _ready() -> void:
	visible = false
	await get_tree().process_frame

	if race_manager_path:
		_race_manager = get_node_or_null(race_manager_path)

	if _race_manager:
		_race_manager.race_loading_started.connect(_on_loading_started)
		_race_manager.race_loading_progress.connect(_on_loading_progress)
		_race_manager.race_ready.connect(_on_race_ready)
		_race_manager.countdown_tick.connect(_on_countdown_tick)
		_race_manager.countdown_go.connect(_on_countdown_go)
		_race_manager.race_started.connect(_on_race_started)
		_race_manager.race_finished.connect(_on_race_finished)
		_race_manager.race_cancelled.connect(_on_race_cancelled)


func _process(_delta: float) -> void:
	if _race_manager and _race_manager.current_state == RaceManagerScript.State.RACING:
		$TimerLabel.text = _race_manager.get_formatted_time()


func show_hud() -> void:
	visible = true
	$CountdownLabel.visible = false
	$TimerLabel.visible = false
	$ResultPanel.visible = false
	$LoadingPanel.visible = false


func hide_hud() -> void:
	visible = false
	# Сбрасываем все панели
	$CountdownLabel.visible = false
	$TimerLabel.visible = false
	$FinishBanner.visible = false
	$ResultPanel.visible = false
	$LoadingPanel.visible = false


func _on_loading_started() -> void:
	show_hud()
	$LoadingPanel.visible = true
	$LoadingPanel/VBox/ProgressBar.value = 0
	$LoadingPanel/VBox/StatusLabel.text = "Загрузка трассы..."


func _on_loading_progress(progress: float, status: String) -> void:
	$LoadingPanel/VBox/ProgressBar.value = progress * 100.0
	$LoadingPanel/VBox/StatusLabel.text = status


func _on_race_ready() -> void:
	$LoadingPanel.visible = false


func _on_countdown_tick(number: int) -> void:
	$CountdownLabel.visible = true
	$CountdownLabel.text = str(number)

	# Анимация масштаба
	var tween := create_tween()
	$CountdownLabel.scale = Vector2(2.0, 2.0)
	tween.tween_property($CountdownLabel, "scale", Vector2(1.0, 1.0), 0.5).set_ease(Tween.EASE_OUT)


func _on_countdown_go() -> void:
	$CountdownLabel.text = "СТАРТ!"
	$CountdownLabel.modulate = Color.GREEN

	# Анимация и скрытие
	var tween := create_tween()
	$CountdownLabel.scale = Vector2(2.0, 2.0)
	tween.tween_property($CountdownLabel, "scale", Vector2(1.0, 1.0), 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_property($CountdownLabel, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func(): $CountdownLabel.visible = false; $CountdownLabel.modulate = Color.WHITE)


func _on_race_started() -> void:
	$TimerLabel.visible = true
	$TimerLabel.text = "00:00.00"


var _last_race_time: float = 0.0

func _on_race_finished(time: float) -> void:
	_last_race_time = time

	# Показываем баннер в стиле Underground
	$FinishBanner.visible = true
	$FinishBanner.modulate.a = 0.0

	# Показываем время под баннером
	$TimerLabel.visible = true
	$TimerLabel.position.y = 70  # Сдвигаем ниже баннера
	var minutes := int(time) / 60
	var seconds := int(time) % 60
	var ms := int((time - int(time)) * 100)
	$TimerLabel.text = "%02d:%02d.%02d" % [minutes, seconds, ms]

	# Анимация появления баннера
	var tween := create_tween()
	tween.tween_property($FinishBanner, "modulate:a", 1.0, 0.3)

	# Через 5 секунд переходим к экрану результатов
	await get_tree().create_timer(5.0).timeout
	_show_results_screen()


func _show_results_screen() -> void:
	"""Показать полноэкранный экран результатов"""
	$FinishBanner.visible = false
	$TimerLabel.visible = false
	$ResultPanel.visible = true

	# Показываем курсор для кнопок
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Форматируем время
	var minutes := int(_last_race_time) / 60
	var seconds := int(_last_race_time) % 60
	var ms := int((_last_race_time - int(_last_race_time)) * 100)
	var time_str := "%02d:%02d.%02d" % [minutes, seconds, ms]

	$ResultPanel/VBox/TimeLabel.text = time_str

	# Название трассы
	if _race_manager and _race_manager.current_track:
		$ResultPanel/VBox/TrackLabel.text = "Трасса: " + _race_manager.current_track.track_name


func _on_race_cancelled() -> void:
	hide_hud()


func _on_back_to_menu_pressed() -> void:
	"""Выйти в главное меню (отдельная сцена)"""
	if _race_manager:
		_race_manager.reset()

	# Переключаем музыку
	if MusicManager:
		MusicManager.play_next_track()

	# Переходим в главное меню
	get_tree().change_scene_to_file("res://ui/standalone_main_menu.tscn")


func _on_restart_pressed() -> void:
	"""Перезапустить гонку - полная перезагрузка сцены"""
	if _race_manager and _race_manager.current_track:
		# Сохраняем трек для автозапуска после перезагрузки
		RaceState.selected_track = _race_manager.current_track
		get_tree().reload_current_scene()
