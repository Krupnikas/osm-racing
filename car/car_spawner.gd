class_name CarSpawner
extends RefCounted

## Хелпер для замены машины игрока на выбранную в CarSettings.
## Используется в main.tscn, race_scene.tscn, test_track_scene.tscn.


static func replace_player_car(scene_root: Node3D) -> Node3D:
	"""Заменяет Car в сцене на выбранную игроком, обновляет все ссылки.
	Возвращает новую машину (или старую если замена не нужна)."""
	var old_car := scene_root.get_node_or_null("Car")
	if not old_car:
		return null

	# Если уже выбрана машина по умолчанию - только применяем статы
	var car_scene_path := CarSettings.get_car_scene_path()
	var default_path: String = CarSettings.CARS[CarSettings.DEFAULT_CAR]["scene"]
	if car_scene_path == default_path:
		CarSettings.apply_car_stats(old_car)
		return old_car

	# Сохраняем дочерние ноды (VehicleController, LaneAssist и т.д.)
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

	# Обновляем все ссылки на машину
	_update_car_references(scene_root, new_car)

	return new_car


static func _update_car_references(scene_root: Node3D, new_car: Node3D) -> void:
	"""Обновить все ссылки на машину — универсально для любой сцены."""
	# Перебираем все ноды с car_path
	for node_path in [
		"OSMTerrain", "CameraManager", "UI/HUD", "UI/CoordsLabel",
		"UI/MainMenu", "RaceManager",
	]:
		var node := scene_root.get_node_or_null(node_path)
		if node and node.get("car_path") != null:
			node.car_path = node.get_path_to(new_car)

	# Камеры — обновляем target NodePath и кешированный _target_node
	for cam_name in ["ChaseCamera", "CinematicCamera", "TopDownCamera", "OrbitCamera"]:
		var cam := scene_root.get_node_or_null("CameraManager/" + cam_name)
		if cam:
			if cam.get("target") != null:
				cam.target = cam.get_path_to(new_car)
			if cam.get("_target_node") != null:
				cam._target_node = new_car

	# RaceManager — дополнительные закешированные ссылки
	var race_mgr := scene_root.get_node_or_null("RaceManager")
	if race_mgr:
		if race_mgr.get("_car") != null:
			race_mgr._car = new_car
		if race_mgr.get("_car_rigidbody") != null:
			race_mgr._car_rigidbody = new_car if new_car is RigidBody3D else null


static func spawn_car_at(parent: Node, position: Vector3, rotation_y: float = 0.0) -> Node3D:
	"""Создаёт выбранную машину в указанной позиции"""
	var car_scene_path := CarSettings.get_car_scene_path()
	var car_scene := load(car_scene_path) as PackedScene
	var car := car_scene.instantiate() as Node3D

	car.name = "Car"
	car.position = position
	car.rotation.y = rotation_y
	car.add_to_group("car")
	car.add_to_group("player")

	parent.add_child(car)
	return car
