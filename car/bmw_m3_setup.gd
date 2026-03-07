extends Node3D

## Скрипт для настройки модели BMW M3 GTR E46 (NFS Most Wanted)
## Переносит колёса из модели на GEVP raycast ноды
## Скрывает подвеску/тормоза, настраивает фары

var _brake_lights: Array[SpotLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _is_night := false
var _vehicle: Node3D
var _night_manager: Node

# Маппинг: имя группы в модели -> имя GEVP wheel_node
const WHEEL_MAP = {
	"WHEEL_LF": "WheelFrontLeft/FrontLeftWheel",
	"WHEEL_RF": "WheelFrontRight/FrontRightWheel",
	"WHEEL_LR": "WheelRearLeft/RearLeftWheel",
	"WHEEL_RR": "WheelRearRight/RearRightWheel",
}
const WHEEL_VISUAL_SCALE := 1.0


func _ready() -> void:
	await get_tree().process_frame

	_vehicle = get_parent() as Node3D
	if not _vehicle:
		push_warning("BMW: Vehicle parent not found")
		return

	_reparent_wheels()
	_hide_suspension()
	_setup_headlights()
	_setup_brake_lights()

	print("BMW M3 GTR model setup complete")


func _process(_delta: float) -> void:
	if not is_instance_valid(_night_manager):
		var current_scene := get_tree().current_scene
		if current_scene:
			_night_manager = current_scene.find_child("NightModeManager", true, false)
	if _night_manager and "is_night" in _night_manager:
		var current_night: bool = _night_manager.is_night
		if current_night != _is_night:
			_is_night = current_night
			_update_headlights()

	_update_taillight_brightness()


func _reparent_wheels() -> void:
	## Переносит колёса из модели на GEVP wheel_node для физики
	for model_wheel_name in WHEEL_MAP:
		var gevp_path: String = WHEEL_MAP[model_wheel_name]
		var gevp_wheel_node: Node3D = _vehicle.get_node_or_null(gevp_path) as Node3D
		if not gevp_wheel_node:
			print("BMW: GEVP wheel node not found: ", gevp_path)
			continue

		# Ищем группу колеса в модели (рекурсивно)
		var model_wheel: Node3D = _find_node_by_name(self, model_wheel_name)
		if not model_wheel:
			print("BMW: Model wheel not found: ", model_wheel_name)
			continue

		var wheel_transform: Transform3D = gevp_wheel_node.global_transform.affine_inverse() * model_wheel.global_transform

		# Отсоединяем от модели и присоединяем к GEVP ноде
		var old_parent: Node = model_wheel.get_parent()
		old_parent.remove_child(model_wheel)
		_clear_owner_recursive(model_wheel)
		gevp_wheel_node.add_child(model_wheel)

		# Оставляем правильный базис колеса, но центрируем его на wheel_node.
		# Иначе колесо получает лишнее смещение и вращается не вокруг ступицы.
		model_wheel.transform = Transform3D(
			wheel_transform.basis.scaled(Vector3.ONE * WHEEL_VISUAL_SCALE),
			Vector3.ZERO
		)

		print("BMW: Reparented ", model_wheel_name, " -> ", gevp_path)


func _hide_suspension() -> void:
	## Скрывает подвеску и тормозные суппорты
	for mesh in _find_all_meshes(self):
		var mesh_name: String = mesh.name.to_lower()
		if "susp" in mesh_name or "caliper" in mesh_name:
			mesh.visible = false


func _find_node_by_name(root: Node, target_name: String) -> Node3D:
	## Рекурсивный поиск ноды по имени
	if root.name == target_name and root is Node3D:
		return root
	for child in root.get_children():
		var found: Node3D = _find_node_by_name(child, target_name)
		if found:
			return found
	return null


func _find_all_meshes(node: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))
	return meshes


func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)


func _setup_headlights() -> void:
	var headlight_positions := [
		Vector3(-0.65, 0.65, 2.0),
		Vector3(0.65, 0.65, 2.0),
	]

	for i in range(headlight_positions.size()):
		var light := SpotLight3D.new()
		light.name = "Headlight_%d" % i
		light.position = headlight_positions[i]
		light.rotation_degrees = Vector3(0, 180, 0)
		light.spot_range = 30.0
		light.spot_angle = 45.0
		light.light_energy = 2.0
		light.light_color = Color(1.0, 0.95, 0.8)
		light.shadow_enabled = true
		light.visible = _is_night

		_vehicle.add_child(light)
		_headlights.append(light)


func _setup_brake_lights() -> void:
	var brake_positions := [
		Vector3(-0.55, 0.55, -2.1),
		Vector3(0.55, 0.55, -2.1),
	]

	for i in range(brake_positions.size()):
		var light := SpotLight3D.new()
		light.name = "BrakeLight_%d" % i
		light.position = brake_positions[i]
		light.spot_range = 1.5
		light.spot_angle = 90.0
		light.light_energy = 0.3
		light.light_color = Color(1.0, 0.0, 0.0)
		light.shadow_enabled = false
		light.visible = true

		_vehicle.add_child(light)
		_brake_lights.append(light)


func _update_headlights() -> void:
	for light in _headlights:
		if is_instance_valid(light):
			light.visible = _is_night


func _update_taillight_brightness() -> void:
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1

	for light in _brake_lights:
		if is_instance_valid(light):
			light.light_energy = 2.0 if braking else 0.3
