extends Node3D

## Сцена гонки - загружается из главного меню с выбранным треком

@export var race_manager_path: NodePath
@export var hud_path: NodePath

var _race_manager
var _hud


func _ready() -> void:
	print("RaceScene._ready() START")

	# Заменяем машину на выбранную (до await!)
	CarSpawner.replace_player_car(self)

	await get_tree().process_frame

	if race_manager_path:
		_race_manager = get_node_or_null(race_manager_path)
		print("RaceScene: _race_manager = ", _race_manager)
	if hud_path:
		_hud = get_node_or_null(hud_path)
		print("RaceScene: _hud = ", _hud)

	# Показываем HUD
	if _hud and _hud.has_method("show_hud"):
		_hud.show_hud()

	# Музыка автоматически запускается в MusicManager._ready()

	# Автостарт гонки если есть выбранный трек
	print("RaceScene: RaceState.selected_track = ", RaceState.selected_track)
	if RaceState.selected_track:
		print("RaceScene: Auto-starting race on track: ", RaceState.selected_track.track_name)
		var track = RaceState.selected_track
		RaceState.selected_track = null  # Очищаем чтобы не запускать повторно при reload

		# Небольшая задержка для инициализации
		await get_tree().process_frame

		if _race_manager:
			print("RaceScene: Calling _race_manager.start_race()")
			_race_manager.start_race(track)
		else:
			print("ERROR: RaceManager not found!")
	else:
		print("RaceScene: No track selected, waiting for manual start")
