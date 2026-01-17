extends Control

@export var car_path: NodePath

var _car: VehicleBody3D

func _ready() -> void:
	visible = false
	await get_tree().process_frame

	if car_path:
		_car = get_node(car_path) as VehicleBody3D
	else:
		_car = get_tree().get_first_node_in_group("car") as VehicleBody3D

	if _car and _car.has_signal("speed_changed"):
		_car.speed_changed.connect(_on_speed_changed)
		_car.rpm_changed.connect(_on_rpm_changed)
		_car.gear_changed.connect(_on_gear_changed)


func _on_speed_changed(speed: float) -> void:
	$SpeedLabel.text = "%d" % int(speed)


func _on_rpm_changed(rpm: float) -> void:
	$RPMBar.value = rpm


func _on_gear_changed(gear: int) -> void:
	match gear:
		0: $GearLabel.text = "R"
		1: $GearLabel.text = "N"
		_: $GearLabel.text = str(gear - 1)


func show_hud() -> void:
	visible = true


func hide_hud() -> void:
	visible = false
