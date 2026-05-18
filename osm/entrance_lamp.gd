class_name EntranceLamp
extends OmniLight3D

## OmniLight3D for facade-driven entrance porches. Lights up only at
## night — listens to NightModeManager.night_mode_changed and toggles
## `visible` (which fully disables the light without re-allocating it).
## Matches the project convention used by hud.gd / race_hud.gd / npc_car.gd
## for finding the NightModeManager via the scene tree.

func _ready() -> void:
	visible = false  # default off; turned on if it's already night
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var night_mgr: Node = scene_root.find_child("NightModeManager", true, false)
	if night_mgr == null:
		return
	if night_mgr.has_signal("night_mode_changed"):
		night_mgr.night_mode_changed.connect(_on_night_mode_changed)
	var is_night: bool = false
	if night_mgr.get("is_night") != null:
		is_night = bool(night_mgr.is_night)
	_on_night_mode_changed(is_night)


func _on_night_mode_changed(enabled: bool) -> void:
	visible = enabled
