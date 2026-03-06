extends Node3D

## Главная сцена свободной езды - заменяет машину на выбранную игроком


func _ready() -> void:
	_replace_player_car()


func _replace_player_car() -> void:
	var old_car := get_node_or_null("Car")
	if not old_car:
		return

	# Если уже выбрана машина по умолчанию - только применяем статы
	var car_scene_path := CarSettings.get_car_scene_path()
	var default_path: String = CarSettings.CARS[CarSettings.DEFAULT_CAR]["scene"]
	if car_scene_path == default_path:
		CarSettings.apply_car_stats(old_car)
		return

	# Сохраняем дочерние ноды (VehicleController, LaneAssist)
	var children_to_move: Array[Node] = []
	for child in old_car.get_children():
		if child.name == "VehicleController" or child.name == "LaneAssist":
			children_to_move.append(child)

	for child in children_to_move:
		old_car.remove_child(child)

	# Загружаем выбранную машину
	var car_scene := load(car_scene_path) as PackedScene
	var new_car := car_scene.instantiate() as Node3D

	new_car.transform = old_car.transform
	new_car.name = "Car"
	new_car.add_to_group("car")
	new_car.add_to_group("player")

	# Заменяем в дереве
	var parent := old_car.get_parent()
	var index := old_car.get_index()
	old_car.queue_free()
	parent.add_child(new_car)
	parent.move_child(new_car, index)

	# Переносим сохранённые ноды
	for child in children_to_move:
		new_car.add_child(child)
		if child.name == "VehicleController" and child.get("vehicle_node") != null:
			child.vehicle_node = new_car

	# Применяем характеристики
	CarSettings.apply_car_stats(new_car)

	# Обновляем все ссылки
	_update_car_references(new_car)


func _update_car_references(new_car: Node3D) -> void:
	var osm_terrain := get_node_or_null("OSMTerrain")
	if osm_terrain and osm_terrain.get("car_path") != null:
		osm_terrain.car_path = osm_terrain.get_path_to(new_car)

	var cam_manager := get_node_or_null("CameraManager")
	if cam_manager and cam_manager.get("car_path") != null:
		cam_manager.car_path = cam_manager.get_path_to(new_car)

	for cam_name in ["ChaseCamera", "CinematicCamera", "TopDownCamera", "OrbitCamera"]:
		var cam := get_node_or_null("CameraManager/" + cam_name)
		if cam:
			if cam.get("target") != null:
				cam.target = cam.get_path_to(new_car)
			if cam.get("_target_node") != null:
				cam._target_node = new_car

	var hud := get_node_or_null("UI/HUD")
	if hud and hud.get("car_path") != null:
		hud.car_path = hud.get_path_to(new_car)

	var coords := get_node_or_null("UI/CoordsLabel")
	if coords and coords.get("car_path") != null:
		coords.car_path = coords.get_path_to(new_car)

	var main_menu := get_node_or_null("UI/MainMenu")
	if main_menu and main_menu.get("car_path") != null:
		main_menu.car_path = main_menu.get_path_to(new_car)

	var race_mgr := get_node_or_null("RaceManager")
	if race_mgr:
		if race_mgr.get("car_path") != null:
			race_mgr.car_path = race_mgr.get_path_to(new_car)
		if race_mgr.get("_car") != null:
			race_mgr._car = new_car
		if race_mgr.get("_car_rigidbody") != null:
			race_mgr._car_rigidbody = new_car if new_car is RigidBody3D else null
