extends Node3D

## Сцена гонки - загружается из главного меню с выбранным треком

@export var race_manager_path: NodePath
@export var hud_path: NodePath

var _race_manager
var _hud


func _ready() -> void:
	print("RaceScene._ready() START")

	# Заменяем машину на выбранную (до await!)
	_replace_player_car()

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


func _replace_player_car() -> void:
	"""Заменить машину в сцене на выбранную игроком"""
	var old_car := get_node_or_null("Car")
	if not old_car:
		print("RaceScene: No Car node found")
		return

	# Сохраняем VehicleController перед удалением старой машины
	var vehicle_controller := old_car.get_node_or_null("VehicleController")
	if vehicle_controller:
		old_car.remove_child(vehicle_controller)

	# Загружаем выбранную машину
	var car_scene_path := CarSettings.get_car_scene_path()
	print("RaceScene: Loading car from ", car_scene_path)
	var car_scene := load(car_scene_path) as PackedScene
	var new_car := car_scene.instantiate() as Node3D

	# Копируем трансформ
	new_car.transform = old_car.transform
	new_car.name = "Car"

	# Добавляем в группы
	new_car.add_to_group("car")
	new_car.add_to_group("player")

	# Заменяем в дереве
	var parent := old_car.get_parent()
	var index := old_car.get_index()
	old_car.queue_free()
	parent.add_child(new_car)
	parent.move_child(new_car, index)

	# Переносим VehicleController на новую машину
	if vehicle_controller:
		new_car.add_child(vehicle_controller)
		vehicle_controller.vehicle_node = new_car

	# Применяем характеристики машины (ускорение, управляемость)
	CarSettings.apply_car_stats(new_car)

	# Обновляем все ссылки на машину
	_update_car_references(new_car)

	print("RaceScene: Replaced car with ", CarSettings.selected_car_id)


func _update_car_references(new_car: Node3D) -> void:
	"""Обновить все ссылки на машину в других нодах"""
	# OSMTerrain
	var osm_terrain := get_node_or_null("OSMTerrain")
	if osm_terrain and osm_terrain.get("car_path") != null:
		osm_terrain.car_path = osm_terrain.get_path_to(new_car)

	# CameraManager
	var cam_manager := get_node_or_null("CameraManager")
	if cam_manager and cam_manager.get("car_path") != null:
		cam_manager.car_path = cam_manager.get_path_to(new_car)

	# Камеры - обновляем и NodePath и кешированный _target_node
	for cam_name in ["ChaseCamera", "CinematicCamera", "TopDownCamera", "OrbitCamera"]:
		var cam := get_node_or_null("CameraManager/" + cam_name)
		if cam:
			if cam.get("target") != null:
				cam.target = cam.get_path_to(new_car)
			if cam.get("_target_node") != null:
				cam._target_node = new_car

	# HUD (скорость)
	var hud := get_node_or_null("UI/HUD")
	if hud and hud.get("car_path") != null:
		hud.car_path = hud.get_path_to(new_car)

	# Координаты
	var coords := get_node_or_null("UI/CoordsLabel")
	if coords and coords.get("car_path") != null:
		coords.car_path = coords.get_path_to(new_car)

	# RaceManager - обновляем и NodePath и закешированные ссылки
	var race_mgr := get_node_or_null("RaceManager")
	if race_mgr:
		if race_mgr.get("car_path") != null:
			race_mgr.car_path = race_mgr.get_path_to(new_car)
		# Важно: обновляем закешированные ссылки напрямую
		if race_mgr.get("_car") != null:
			race_mgr._car = new_car
		if race_mgr.get("_car_rigidbody") != null:
			race_mgr._car_rigidbody = new_car if new_car is RigidBody3D else null
