class_name CarSpawner
extends RefCounted

## Хелпер для динамической замены машины игрока в сценах


static func replace_car(scene_root: Node, old_car: Node3D) -> Node3D:
	"""Заменяет машину на выбранную, сохраняя позицию и группы"""
	var car_scene_path := CarSettings.get_car_scene_path()
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

	return new_car


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
