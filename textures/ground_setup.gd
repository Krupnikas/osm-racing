extends Node
class_name GroundSetup

## Настраивает материал земли при старте игры

const GroundMaterialClass = preload("res://textures/ground_material.gd")

@export var ground_mesh_path: NodePath
@export var night_mode_manager_path: NodePath

var _ground_mesh: MeshInstance3D
var _night_manager: Node
var _ground_material: StandardMaterial3D
var _is_wet: bool = false
var _is_night: bool = false


func _ready() -> void:
	if ground_mesh_path:
		_ground_mesh = get_node_or_null(ground_mesh_path) as MeshInstance3D

	if night_mode_manager_path:
		_night_manager = get_node_or_null(night_mode_manager_path)
		if _night_manager and _night_manager.has_signal("night_mode_changed"):
			_night_manager.connect("night_mode_changed", _on_night_mode_changed)
		if _night_manager and _night_manager.has_signal("rain_changed"):
			_night_manager.connect("rain_changed", _on_rain_changed)

	_setup_ground_material()


func _setup_ground_material() -> void:
	if not _ground_mesh:
		return

	_ground_material = GroundMaterialClass.create_ground_material(_is_wet, _is_night)
	_ground_mesh.set_surface_override_material(0, _ground_material)


func _on_night_mode_changed(is_night: bool) -> void:
	_is_night = is_night
	_update_ground_material()


func _on_rain_changed(is_rainy: bool) -> void:
	_is_wet = is_rainy
	_update_ground_material()


func _update_ground_material() -> void:
	if _ground_material:
		GroundMaterialClass.apply_weather_properties(_ground_material, _is_wet, _is_night)
