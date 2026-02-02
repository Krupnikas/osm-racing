extends Control

## Экран выбора машины в стиле NFS Underground

var _car_ids: Array = []
var _current_index: int = 0
var _preview_car: Node3D = null
var _initial_car_id: String = ""  # Машина при входе в меню (для отмены)


func _ready() -> void:
	_car_ids = CarSettings.get_car_ids()
	_initial_car_id = CarSettings.selected_car_id

	# Найти индекс текущей машины
	_current_index = _car_ids.find(CarSettings.selected_car_id)
	if _current_index < 0:
		_current_index = 0

	_update_preview()


func _process(delta: float) -> void:
	# Вращение машины для превью
	if _preview_car and visible:
		_preview_car.rotate_y(delta * 0.5)


func _update_preview() -> void:
	var car_id: String = _car_ids[_current_index]
	$CarouselContainer/CarNameLabel.text = CarSettings.get_car_name(car_id)

	# Удаляем старую превью
	var container := $PreviewViewport/SubViewport/CarPreviewContainer
	for child in container.get_children():
		child.queue_free()

	# Загружаем новую машину
	var scene_path: String = CarSettings.CARS[car_id]["scene"]
	var car_scene := load(scene_path) as PackedScene
	_preview_car = car_scene.instantiate()
	_preview_car.position = Vector3.ZERO

	# Отключаем физику для превью
	if _preview_car is RigidBody3D:
		_preview_car.freeze = true
	elif _preview_car is VehicleBody3D:
		_preview_car.set_physics_process(false)

	container.add_child(_preview_car)


func _on_prev_pressed() -> void:
	_current_index = (_current_index - 1 + _car_ids.size()) % _car_ids.size()
	_update_preview()


func _on_next_pressed() -> void:
	_current_index = (_current_index + 1) % _car_ids.size()
	_update_preview()


func _on_select_pressed() -> void:
	CarSettings.selected_car_id = _car_ids[_current_index]
	CarSettings.save_settings()
	_go_back()


func _on_back_pressed() -> void:
	# Восстанавливаем изначальный выбор
	_current_index = _car_ids.find(_initial_car_id)
	_go_back()


func _go_back() -> void:
	visible = false
	var main_menu := get_parent()
	if main_menu.has_node("VBox"):
		main_menu.get_node("VBox").visible = true


func show_selection() -> void:
	"""Показать экран выбора и обновить превью"""
	_initial_car_id = CarSettings.selected_car_id
	_current_index = _car_ids.find(_initial_car_id)
	if _current_index < 0:
		_current_index = 0
	visible = true
	_update_preview()
