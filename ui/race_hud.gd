extends Control

## HUD для режима гонки: загрузка → отсчёт → активная гонка → результаты.
## Визуальный слой — паперный пейс-нот + аналоговая приборка (ЖАЖДА СКОРОСТИ);
## переключается между «день» и «ночь» по сигналу NightModeManager.
## Логика сохранена с прошлой версии: все сигналы RaceManager обрабатываются здесь.

const RaceManagerScript = preload("res://race/race_manager.gd")

@export var race_manager_path: NodePath

var _race_manager  # RaceManager
var _near_miss_detector: Node
var _player_car: Node
var _car_rigidbody: RigidBody3D
var _is_night: bool = false

# Lightweight cache for live standings rebuild.
var _last_standings_time: float = 0.0


func _ready() -> void:
	print("RaceHUD._ready() START")
	# Race HUD is gated to actual races — free-roam shows nothing but
	# the persistent speedometer + minimap (those live in res://ui/hud.tscn).
	visible = false
	# Explicitly hide every race-only card on first paint so even a
	# split-second of visibility doesn't leak into free-roam.
	await get_tree().process_frame
	if has_node("TopLeftStack"):
		$TopLeftStack.visible = false
	if has_node("StandingsPanel"):
		$StandingsPanel.visible = false

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

	# Night mode swap — NightModeManager is a scene child (not autoload),
	# so we walk the current scene to find it.
	var night_mgr: Node = null
	var scene_root := get_tree().current_scene
	if scene_root:
		night_mgr = scene_root.find_child("NightModeManager", true, false)
	if night_mgr and night_mgr.has_signal("night_mode_changed"):
		night_mgr.night_mode_changed.connect(_on_night_mode_changed)
		var is_night_now: bool = false
		if night_mgr.get("is_night") != null:
			is_night_now = bool(night_mgr.is_night)
		_apply_night(is_night_now)

	# Near-miss combo card.
	_locate_near_miss_detector()

	# Locate the player's car for speed/gear readouts.
	_player_car = get_tree().get_first_node_in_group("car")
	if _player_car is RigidBody3D:
		_car_rigidbody = _player_car

	# Seed cards/track info with what the current track exposes.
	_refresh_track_info()


func _locate_near_miss_detector() -> void:
	# Scene tree shape: SceneRoot / [TrafficContainer or root]/ NearMissDetector
	var root := get_tree().current_scene
	if root:
		_near_miss_detector = root.find_child("NearMissDetector", true, false)
	if _near_miss_detector and _near_miss_detector.has_signal("near_miss"):
		_near_miss_detector.near_miss.connect(_on_near_miss)


func _on_night_mode_changed(enabled: bool) -> void:
	_apply_night(enabled)


func _apply_night(enabled: bool) -> void:
	_is_night = enabled
	$TopLeftStack/LapTimePanel.set_night(enabled)
	$TopLeftStack/TrackCard.set_night(enabled)
	$TopLeftStack/NextTurnCard.set_night(enabled)
	$TopLeftStack/NearMissCard.set_night(enabled)
	$StandingsPanel.set_night(enabled)
	# The round speedometer lives in the persistent HUD (res://ui/hud.tscn),
	# updated by its own night handler.


func _refresh_track_info() -> void:
	if not _race_manager or not _race_manager.current_track:
		return
	var track = _race_manager.current_track
	var name_text: String = String(track.track_name) if track.track_name != null else ""
	var dist: float = 0.0
	if track.get("route_points") != null:
		# Sum distances along route as a rough km figure.
		# (Mirrors how the minimap measures route length.)
		var points: Array = track.route_points
		# Fallback to waypoints if route_points is sparse.
		if points.size() < 2 and track.get("waypoints") != null:
			points = track.waypoints
		for i in range(points.size() - 1):
			var a = points[i]
			var b = points[i + 1]
			if a is Vector2 and b is Vector2:
				dist += _haversine_km(a.x, a.y, b.x, b.y)
	$TopLeftStack/TrackCard.set_track(name_text, dist)

	var total_laps: int = 1
	if track.get("total_laps") != null:
		total_laps = int(track.total_laps)
	$TopLeftStack/LapTimePanel.set_lap(1, total_laps)


static func _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var r := 6371.0
	var dlat := deg_to_rad(lat2 - lat1)
	var dlon := deg_to_rad(lon2 - lon1)
	var a := sin(dlat * 0.5) * sin(dlat * 0.5) + cos(deg_to_rad(lat1)) * cos(deg_to_rad(lat2)) * sin(dlon * 0.5) * sin(dlon * 0.5)
	return 2.0 * r * asin(min(1.0, sqrt(a)))


func _process(delta: float) -> void:
	if _race_manager and _race_manager.current_state == RaceManagerScript.State.RACING:
		var t_text: String = _race_manager.get_formatted_time()
		$TopLeftStack/LapTimePanel.set_time(t_text)

		# Checkpoint countdown stays mostly as before.
		if _race_manager.is_checkpoint_mode():
			var cp_time: float = _race_manager.get_checkpoint_timer()
			$CheckpointTimer/TimeLabel.text = "%.1f" % cp_time
			if cp_time <= 3.0:
				$CheckpointTimer/TimeLabel.modulate = Color(1.0, 0.3, 0.3)
			else:
				$CheckpointTimer/TimeLabel.modulate = Color.WHITE

	# Refresh standings ~5×/sec — cheap, no per-frame allocations needed.
	_last_standings_time += delta
	if _last_standings_time > 0.2:
		_last_standings_time = 0.0
		_update_standings()


# Pulls a simple live standings array out of RaceManager when available.
# RaceManager doesn't expose a `standings_changed` signal yet, so we poll
# at low frequency. If `get_live_standings()` is missing we fall back to
# a stub showing only the player.
func _update_standings() -> void:
	if not _race_manager:
		return
	var rows: Array = []
	var player_pos: int = 1
	var total: int = 1
	if _race_manager.has_method("get_live_standings"):
		var data = _race_manager.get_live_standings()
		if data is Dictionary:
			rows = data.get("rows", [])
			player_pos = int(data.get("player_pos", 1))
			total = int(data.get("total", rows.size()))
	if rows.is_empty():
		# Minimal placeholder so the panel still renders during early dev.
		rows = [{"name": "ВЫ", "gap_seconds": 0.0, "trend": 0, "is_player": true}]
		player_pos = 1
		total = 1
	$StandingsPanel.set_standings(rows, player_pos, total)


func _on_near_miss(combo_count: int) -> void:
	$TopLeftStack/NearMissCard.trigger(combo_count, combo_count * 100)


func show_hud() -> void:
	visible = true
	$CountdownLabel.visible = false
	$TimerLabel.visible = false
	$CheckpointTimer.visible = false
	$ResultPanel.visible = false
	$LoadingScreen.visible = false
	# New components stay hidden until race starts.
	$TopLeftStack.visible = false
	$StandingsPanel.visible = false


func hide_hud() -> void:
	visible = false
	$CountdownLabel.visible = false
	$TimerLabel.visible = false
	$CheckpointTimer.visible = false
	$FinishBanner.visible = false
	$ResultPanel.visible = false
	$LoadingScreen.visible = false
	$TopLeftStack.visible = false
	$StandingsPanel.visible = false
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
	# Cards appear right after loading completes (alongside the
	# persistent speedometer) so the player sees the chrome before
	# the countdown ticks down.
	$TopLeftStack.visible = true
	$StandingsPanel.visible = true


func _on_countdown_tick(number: int) -> void:
	$CountdownLabel.visible = true
	$CountdownLabel.text = str(number)

	var tween := create_tween()
	$CountdownLabel.scale = Vector2(2.0, 2.0)
	tween.tween_property($CountdownLabel, "scale", Vector2(1.0, 1.0), 0.5).set_ease(Tween.EASE_OUT)


func _on_countdown_go() -> void:
	$CountdownLabel.text = "СТАРТ!"
	$CountdownLabel.modulate = Color.GREEN

	var tween := create_tween()
	$CountdownLabel.scale = Vector2(2.0, 2.0)
	tween.tween_property($CountdownLabel, "scale", Vector2(1.0, 1.0), 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_property($CountdownLabel, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func(): $CountdownLabel.visible = false; $CountdownLabel.modulate = Color.WHITE)


func _on_race_started() -> void:
	# New HUD takes over the visible-on-screen elements.
	$TopLeftStack.visible = true
	$StandingsPanel.visible = true
	$TopLeftStack/LapTimePanel.set_time("00:00.000")
	$TopLeftStack/LapTimePanel.set_delta(NAN)
	$TopLeftStack/NearMissCard.visible = false

	# Old centred TimerLabel stays hidden in racing; only used by results flow.
	$TimerLabel.visible = false

	if _race_manager and _race_manager.is_checkpoint_mode():
		$CheckpointTimer.visible = true
		$CheckpointTimer/TimeDiff.visible = false
		$CheckpointTimer/TimeLabel.modulate = Color.WHITE


var _last_race_time: float = 0.0
var _last_race_results: Array = []

func _on_race_finished(time: float, results: Array = []) -> void:
	_last_race_time = time
	_last_race_results = results

	# Hide in-race chrome, show finish banner.
	$CheckpointTimer.visible = false
	$TopLeftStack.visible = false
	$StandingsPanel.visible = false

	$FinishBanner/BannerText.text = "ЗАЕЗД ОКОНЧЕН"
	$FinishBanner/BannerText.modulate = Color(0.85, 0.7, 0.1)
	$FinishBanner.visible = true
	$FinishBanner.modulate.a = 0.0

	$TimerLabel.visible = true
	$TimerLabel.position.y = 70
	var minutes := int(time) / 60
	var seconds := int(time) % 60
	var ms := int((time - int(time)) * 100)
	$TimerLabel.text = "%02d:%02d.%02d" % [minutes, seconds, ms]

	var tween := create_tween()
	tween.tween_property($FinishBanner, "modulate:a", 1.0, 0.3)

	await get_tree().create_timer(5.0).timeout
	_show_results_screen()


func _show_results_screen() -> void:
	$FinishBanner.visible = false
	$TimerLabel.visible = false
	$ResultPanel.visible = true

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_clear_standings()

	if _race_manager and _race_manager.current_track:
		$ResultPanel/VBox/TrackLabel.text = "Трасса: " + _race_manager.current_track.track_name

	var is_checkpoint: bool = _race_manager != null and _race_manager.is_checkpoint_mode()

	var player_position := 1
	for result in _last_race_results:
		if result.is_player:
			player_position = result.position
			break

	if is_checkpoint or _last_race_results.is_empty():
		$ResultPanel/VBox/FinishLabel.text = "РЕЗУЛЬТАТЫ"
		$ResultPanel/VBox/FinishLabel.modulate = Color(0, 1, 0)
		$ResultPanel/VBox/TimeTitle.text = "Ваше время:"
		$ResultPanel/VBox/TimeTitle.visible = true
		$ResultPanel/VBox/TimeLabel.visible = true

		var time_str := _format_time(_last_race_time)
		$ResultPanel/VBox/TimeLabel.text = time_str
	else:
		$ResultPanel/VBox/FinishLabel.text = "%d МЕСТО!" % player_position
		if player_position == 1:
			$ResultPanel/VBox/FinishLabel.modulate = Color(1, 0.85, 0)
		elif player_position == 2:
			$ResultPanel/VBox/FinishLabel.modulate = Color(0.8, 0.8, 0.8)
		elif player_position == 3:
			$ResultPanel/VBox/FinishLabel.modulate = Color(0.8, 0.5, 0.2)
		else:
			$ResultPanel/VBox/FinishLabel.modulate = Color(0.6, 0.6, 0.6)
		$ResultPanel/VBox/TimeTitle.visible = false
		$ResultPanel/VBox/TimeLabel.visible = false

		_create_standings()

	_award_career_prize(player_position)


func _award_career_prize(player_position: int) -> void:
	if not RaceState.is_career_race:
		return
	var track = _race_manager.current_track if _race_manager else null
	if not track:
		return
	if CareerState.active_profile == "":
		return

	var track_id: String = track.track_id
	var prize := CareerState.award_race_prize(track_id, player_position)

	var vbox := get_node_or_null("ResultPanel/VBox")
	if not vbox:
		return

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

	var finish_idx := 0
	var finish_label := vbox.get_node_or_null("FinishLabel")
	if finish_label:
		finish_idx = finish_label.get_index() + 1
	vbox.add_child(prize_label)
	vbox.move_child(prize_label, finish_idx)

	RaceState.is_career_race = false


func _format_time(time: float) -> String:
	var minutes := int(time) / 60
	var seconds := int(time) % 60
	var ms := int((time - int(time)) * 100)
	return "%02d:%02d.%02d" % [minutes, seconds, ms]


func _clear_standings() -> void:
	var vbox := get_node_or_null("ResultPanel/VBox")
	if not vbox:
		return
	var standings_container := vbox.get_node_or_null("StandingsContainer")
	if standings_container:
		standings_container.queue_free()


func _create_standings() -> void:
	var container := VBoxContainer.new()
	container.name = "StandingsContainer"
	container.add_theme_constant_override("separation", 8)

	for result in _last_race_results:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 20)

		var pos_label := Label.new()
		pos_label.text = "%d." % result.position
		pos_label.custom_minimum_size = Vector2(50, 0)
		pos_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pos_label.add_theme_font_size_override("font_size", 32)
		if result.is_player:
			pos_label.add_theme_color_override("font_color", Color(1, 0.85, 0))
		else:
			pos_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		row.add_child(pos_label)

		var name_label := Label.new()
		name_label.text = result.name
		name_label.custom_minimum_size = Vector2(200, 0)
		name_label.add_theme_font_size_override("font_size", 32)
		if result.is_player:
			name_label.add_theme_color_override("font_color", Color(1, 0.85, 0))
		else:
			name_label.add_theme_color_override("font_color", Color.WHITE)
		row.add_child(name_label)

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

	var vbox := $ResultPanel/VBox
	var spacer_idx := vbox.get_node("HSpacer2").get_index()
	vbox.add_child(container)
	vbox.move_child(container, spacer_idx + 1)


func _on_race_cancelled() -> void:
	hide_hud()


func _on_back_to_menu_pressed() -> void:
	if _race_manager:
		_race_manager.reset()

	if MusicManager:
		MusicManager.play_next_track()

	get_tree().change_scene_to_file("res://ui/standalone_main_menu.tscn")


func _on_checkpoint_passed(_index: int, time_bonus: float) -> void:
	var diff_label := $CheckpointTimer/TimeDiff
	diff_label.text = "+%.1f" % time_bonus
	diff_label.modulate = Color(0.2, 1.0, 0.2)
	diff_label.visible = true
	diff_label.scale = Vector2(1.3, 1.3)

	var tween := create_tween()
	tween.tween_property(diff_label, "scale", Vector2(1.0, 1.0), 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_interval(2.7)
	tween.tween_callback(func(): diff_label.visible = false)


func _on_checkpoint_timeout() -> void:
	$CheckpointTimer.visible = false
	$TopLeftStack.visible = false
	$StandingsPanel.visible = false

	$FinishBanner/BannerText.text = "ЗАЕЗД ОКОНЧЕН"
	$FinishBanner/BannerText.modulate = Color(1.0, 0.3, 0.3)
	$FinishBanner.visible = true
	$FinishBanner.modulate.a = 0.0

	var tween := create_tween()
	tween.tween_property($FinishBanner, "modulate:a", 1.0, 0.3)

	await get_tree().create_timer(3.0).timeout
	_show_timeout_results()


func _show_timeout_results() -> void:
	$FinishBanner.visible = false
	$TimerLabel.visible = false
	$ResultPanel.visible = true

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_clear_standings()

	$ResultPanel/VBox/FinishLabel.text = "ПОРАЖЕНИЕ"
	$ResultPanel/VBox/FinishLabel.modulate = Color(1.0, 0.3, 0.3)
	$ResultPanel/VBox/TimeTitle.text = "Время закончилось"
	$ResultPanel/VBox/TimeTitle.visible = true
	$ResultPanel/VBox/TimeLabel.text = ""
	$ResultPanel/VBox/TimeLabel.visible = false

	if _race_manager and _race_manager.current_track:
		$ResultPanel/VBox/TrackLabel.text = "Трасса: " + _race_manager.current_track.track_name


func _on_restart_pressed() -> void:
	_clear_standings()
	$ResultPanel/VBox/FinishLabel.text = "РЕЗУЛЬТАТЫ"
	$ResultPanel/VBox/FinishLabel.modulate = Color.WHITE
	$ResultPanel/VBox/TimeTitle.text = "Ваше время:"
	$ResultPanel/VBox/TimeTitle.visible = true
	$ResultPanel/VBox/TimeLabel.visible = true
	$FinishBanner/BannerText.text = "ЗАЕЗД ОКОНЧЕН"
	$FinishBanner/BannerText.modulate = Color(0.85, 0.7, 0.1)

	if _race_manager and _race_manager.current_track:
		RaceState.selected_track = _race_manager.current_track
		get_tree().reload_current_scene()
