extends Control

## HUD для режима гонки: обратный отсчёт, таймер, результаты

const RaceManagerScript = preload("res://race/race_manager.gd")

@export var race_manager_path: NodePath

var _race_manager  # RaceManager


func _ready() -> void:
	print("RaceHUD._ready() START")
	visible = false
	await get_tree().process_frame

	if race_manager_path:
		_race_manager = get_node_or_null(race_manager_path)
		print("RaceHUD: _race_manager = ", _race_manager)

	if _race_manager:
		print("RaceHUD: Connecting signals to RaceManager")
		_race_manager.race_loading_started.connect(_on_loading_started)
		_race_manager.race_loading_progress.connect(_on_loading_progress)
		_race_manager.race_ready.connect(_on_race_ready)
		_race_manager.countdown_tick.connect(_on_countdown_tick)
		_race_manager.countdown_go.connect(_on_countdown_go)
		_race_manager.race_started.connect(_on_race_started)
		_race_manager.race_finished.connect(_on_race_finished)
		_race_manager.race_cancelled.connect(_on_race_cancelled)
		_race_manager.checkpoint_passed.connect(_on_checkpoint_passed)
		_race_manager.checkpoint_timeout.connect(_on_checkpoint_timeout)


func _process(_delta: float) -> void:
	if _race_manager and _race_manager.current_state == RaceManagerScript.State.RACING:
		$TimerLabel.text = _race_manager.get_formatted_time()

		# Обновляем таймер чекпоинтов
		if _race_manager.is_checkpoint_mode():
			var cp_time: float = _race_manager.get_checkpoint_timer()
			$CheckpointTimer/TimeLabel.text = "%.1f" % cp_time

			# Красный цвет при малом времени
			if cp_time <= 3.0:
				$CheckpointTimer/TimeLabel.modulate = Color(1.0, 0.3, 0.3)
			else:
				$CheckpointTimer/TimeLabel.modulate = Color.WHITE


func show_hud() -> void:
	visible = true
	$CountdownLabel.visible = false
	$TimerLabel.visible = false
	$CheckpointTimer.visible = false
	$ResultPanel.visible = false
	$LoadingScreen.visible = false


func hide_hud() -> void:
	visible = false
	# Сбрасываем все панели
	$CountdownLabel.visible = false
	$TimerLabel.visible = false
	$CheckpointTimer.visible = false
	$FinishBanner.visible = false
	$ResultPanel.visible = false
	$LoadingScreen.visible = false
	_clear_standings()


func _on_loading_started() -> void:
	print("RaceHUD._on_loading_started() - SIGNAL RECEIVED!")
	show_hud()
	$LoadingScreen.visible = true
	$LoadingScreen.set_progress(0.0)
	$LoadingScreen.set_status("Загрузка трассы...")


func _on_loading_progress(progress: float, status: String) -> void:
	$LoadingScreen.set_progress(progress )
	$LoadingScreen.set_status(status)


func _on_race_ready() -> void:
	$LoadingScreen.visible = false


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

	# Показываем таймер чекпоинтов в checkpoint mode
	if _race_manager and _race_manager.is_checkpoint_mode():
		$CheckpointTimer.visible = true
		$CheckpointTimer/TimeDiff.visible = false
		$CheckpointTimer/TimeLabel.modulate = Color.WHITE


var _last_race_time: float = 0.0
var _last_race_results: Array = []

func _on_race_finished(time: float, results: Array = []) -> void:
	_last_race_time = time
	_last_race_results = results

	# Скрываем таймер чекпоинтов
	$CheckpointTimer.visible = false

	# Показываем баннер в стиле Underground
	$FinishBanner/BannerText.text = "ЗАЕЗД ОКОНЧЕН"
	$FinishBanner/BannerText.modulate = Color(0.85, 0.7, 0.1)
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

	# Очищаем предыдущую таблицу результатов (если есть)
	_clear_standings()

	# Название трассы
	if _race_manager and _race_manager.current_track:
		$ResultPanel/VBox/TrackLabel.text = "Трасса: " + _race_manager.current_track.track_name

	# Проверяем режим: checkpoint или sprint
	var is_checkpoint: bool = _race_manager != null and _race_manager.is_checkpoint_mode()

	# Определяем позицию игрока
	var player_position := 1
	for result in _last_race_results:
		if result.is_player:
			player_position = result.position
			break

	if is_checkpoint or _last_race_results.is_empty():
		# Checkpoint mode: показываем только своё время
		$ResultPanel/VBox/FinishLabel.text = "РЕЗУЛЬТАТЫ"
		$ResultPanel/VBox/FinishLabel.modulate = Color(0, 1, 0)
		$ResultPanel/VBox/TimeTitle.text = "Ваше время:"
		$ResultPanel/VBox/TimeTitle.visible = true
		$ResultPanel/VBox/TimeLabel.visible = true

		# Форматируем время
		var time_str := _format_time(_last_race_time)
		$ResultPanel/VBox/TimeLabel.text = time_str
	else:
		# Sprint mode: показываем таблицу результатов
		$ResultPanel/VBox/FinishLabel.text = "%d МЕСТО!" % player_position
		if player_position == 1:
			$ResultPanel/VBox/FinishLabel.modulate = Color(1, 0.85, 0)  # Золотой
		elif player_position == 2:
			$ResultPanel/VBox/FinishLabel.modulate = Color(0.8, 0.8, 0.8)  # Серебро
		elif player_position == 3:
			$ResultPanel/VBox/FinishLabel.modulate = Color(0.8, 0.5, 0.2)  # Бронза
		else:
			$ResultPanel/VBox/FinishLabel.modulate = Color(0.6, 0.6, 0.6)
		$ResultPanel/VBox/TimeTitle.visible = false
		$ResultPanel/VBox/TimeLabel.visible = false

		# Создаём таблицу результатов
		_create_standings()

	# Начисляем приз за карьерную гонку
	_award_career_prize(player_position)


func _award_career_prize(player_position: int) -> void:
	"""Начислить приз за карьерную гонку и показать на экране результатов"""
	if not RaceState.is_career_race:
		return
	var track = _race_manager.current_track if _race_manager else null
	if not track:
		return
	if CareerState.active_profile == "":
		return

	var track_id: String = track.track_id
	var prize := CareerState.award_race_prize(track_id, player_position)

	# Показываем приз на экране результатов
	var vbox := get_node_or_null("ResultPanel/VBox")
	if not vbox:
		return

	# Удаляем предыдущий лейбл приза (если есть)
	var old_prize := vbox.get_node_or_null("PrizeLabel")
	if old_prize:
		old_prize.queue_free()

	var prize_label := Label.new()
	prize_label.name = "PrizeLabel"
	prize_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prize_label.add_theme_font_size_override("font_size", 32)

	if prize > 0:
		prize_label.text = "+ %s" % CareerState.format_money(prize)
		prize_label.add_theme_color_override("font_color", Color(0.2, 1, 0.2))
	else:
		prize_label.text = "Без приза"
		prize_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

	# Вставляем после FinishLabel
	var finish_idx := 0
	var finish_label := vbox.get_node_or_null("FinishLabel")
	if finish_label:
		finish_idx = finish_label.get_index() + 1
	vbox.add_child(prize_label)
	vbox.move_child(prize_label, finish_idx)

	RaceState.is_career_race = false


func _format_time(time: float) -> String:
	"""Форматирует время в MM:SS.ms"""
	var minutes := int(time) / 60
	var seconds := int(time) % 60
	var ms := int((time - int(time)) * 100)
	return "%02d:%02d.%02d" % [minutes, seconds, ms]


func _clear_standings() -> void:
	"""Удаляет предыдущую таблицу результатов"""
	var vbox := get_node_or_null("ResultPanel/VBox")
	if not vbox:
		return
	var standings_container := vbox.get_node_or_null("StandingsContainer")
	if standings_container:
		standings_container.queue_free()


func _create_standings() -> void:
	"""Создаёт таблицу результатов для sprint mode"""
	var container := VBoxContainer.new()
	container.name = "StandingsContainer"
	container.add_theme_constant_override("separation", 8)

	for result in _last_race_results:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 20)

		# Позиция (1, 2, 3...)
		var pos_label := Label.new()
		pos_label.text = "%d." % result.position
		pos_label.custom_minimum_size = Vector2(50, 0)
		pos_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pos_label.add_theme_font_size_override("font_size", 32)
		if result.is_player:
			pos_label.add_theme_color_override("font_color", Color(1, 0.85, 0))  # Золотой
		else:
			pos_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		row.add_child(pos_label)

		# Имя
		var name_label := Label.new()
		name_label.text = result.name
		name_label.custom_minimum_size = Vector2(200, 0)
		name_label.add_theme_font_size_override("font_size", 32)
		if result.is_player:
			name_label.add_theme_color_override("font_color", Color(1, 0.85, 0))
		else:
			name_label.add_theme_color_override("font_color", Color.WHITE)
		row.add_child(name_label)

		# Время
		var time_label := Label.new()
		time_label.text = _format_time(result.time)
		time_label.custom_minimum_size = Vector2(150, 0)
		time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		time_label.add_theme_font_size_override("font_size", 32)
		if result.is_player:
			time_label.add_theme_color_override("font_color", Color(1, 0.85, 0))
		else:
			time_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(time_label)

		container.add_child(row)

	# Вставляем контейнер перед кнопками (после HSpacer2)
	var vbox := $ResultPanel/VBox
	var spacer_idx := vbox.get_node("HSpacer2").get_index()
	vbox.add_child(container)
	vbox.move_child(container, spacer_idx + 1)


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


func _on_checkpoint_passed(_index: int, time_bonus: float) -> void:
	"""Показать анимацию при проезде чекпоинта"""
	var diff_label := $CheckpointTimer/TimeDiff
	diff_label.text = "+%.1f" % time_bonus
	diff_label.modulate = Color(0.2, 1.0, 0.2)
	diff_label.visible = true
	diff_label.scale = Vector2(1.3, 1.3)

	# Анимация scale down и затем скрытие
	var tween := create_tween()
	tween.tween_property(diff_label, "scale", Vector2(1.0, 1.0), 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_interval(2.7)
	tween.tween_callback(func(): diff_label.visible = false)


func _on_checkpoint_timeout() -> void:
	"""Время истекло - показываем сообщение о поражении"""
	# Скрываем таймер чекпоинтов
	$CheckpointTimer.visible = false

	# Показываем баннер "ЗАЕЗД ОКОНЧЕН" красным
	$FinishBanner/BannerText.text = "ЗАЕЗД ОКОНЧЕН"
	$FinishBanner/BannerText.modulate = Color(1.0, 0.3, 0.3)
	$FinishBanner.visible = true
	$FinishBanner.modulate.a = 0.0

	var tween := create_tween()
	tween.tween_property($FinishBanner, "modulate:a", 1.0, 0.3)

	# Через 3 секунды показываем экран результатов
	await get_tree().create_timer(3.0).timeout
	_show_timeout_results()


func _show_timeout_results() -> void:
	"""Показать экран результатов при поражении (только checkpoint mode)"""
	$FinishBanner.visible = false
	$TimerLabel.visible = false
	$ResultPanel.visible = true

	# Показываем курсор
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Очищаем standings (на всякий случай)
	_clear_standings()

	# Меняем текст на поражение
	$ResultPanel/VBox/FinishLabel.text = "ПОРАЖЕНИЕ"
	$ResultPanel/VBox/FinishLabel.modulate = Color(1.0, 0.3, 0.3)
	$ResultPanel/VBox/TimeTitle.text = "Время закончилось"
	$ResultPanel/VBox/TimeTitle.visible = true
	$ResultPanel/VBox/TimeLabel.text = ""
	$ResultPanel/VBox/TimeLabel.visible = false

	# Название трассы
	if _race_manager and _race_manager.current_track:
		$ResultPanel/VBox/TrackLabel.text = "Трасса: " + _race_manager.current_track.track_name


func _on_restart_pressed() -> void:
	"""Перезапустить гонку - полная перезагрузка сцены"""
	# Сбрасываем стили результатов перед перезагрузкой
	_clear_standings()
	$ResultPanel/VBox/FinishLabel.text = "РЕЗУЛЬТАТЫ"
	$ResultPanel/VBox/FinishLabel.modulate = Color.WHITE
	$ResultPanel/VBox/TimeTitle.text = "Ваше время:"
	$ResultPanel/VBox/TimeTitle.visible = true
	$ResultPanel/VBox/TimeLabel.visible = true
	$FinishBanner/BannerText.text = "ЗАЕЗД ОКОНЧЕН"
	$FinishBanner/BannerText.modulate = Color(0.85, 0.7, 0.1)

	if _race_manager and _race_manager.current_track:
		# Сохраняем трек для автозапуска после перезагрузки
		RaceState.selected_track = _race_manager.current_track
		get_tree().reload_current_scene()
