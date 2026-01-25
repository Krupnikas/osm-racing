extends AudioStreamPlayer3D

@export var vehicle : Vehicle
@export var sample_rpm := 4000.0

func _physics_process(delta):
	if not vehicle:
		return

	# Не играть звук если машина заморожена или скрыта (в меню)
	if vehicle.freeze or not vehicle.visible:
		if playing:
			stop()
		return

	# Включить звук если не играет
	if not playing:
		play()

	pitch_scale = vehicle.motor_rpm / sample_rpm
	volume_db = linear_to_db((vehicle.throttle_amount * 0.5) + 0.5)
