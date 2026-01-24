extends Node

## Управление видимостью колес GEVP
## Переключается клавишей P (ToggleWheels)

@export var vehicle: Node3D

var wheels_visible := false

func _ready() -> void:
	# Скрываем колеса при старте
	_set_wheels_visibility(false)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ToggleWheels"):
		wheels_visible = !wheels_visible
		_set_wheels_visibility(wheels_visible)
		print("Wheels visibility: ", wheels_visible)

func _set_wheels_visibility(visible: bool) -> void:
	if not vehicle:
		return

	# Находим все меши колес в модели
	var meshes := _find_all_meshes(vehicle)
	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()
		# Скрываем/показываем только меши колес
		if "wheel" in mesh_name or "tire" in mesh_name or "rim" in mesh_name or "brakedisk" in mesh_name:
			mesh.visible = visible

func _find_all_meshes(node: Node) -> Array:
	"""Рекурсивно находит все MeshInstance3D"""
	var meshes: Array = []

	if node is MeshInstance3D:
		meshes.append(node)

	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))

	return meshes
