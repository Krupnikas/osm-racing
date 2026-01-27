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
	# Менее агрессивный звук: меньший диапазон громкости и плавнее изменение
	var throttle_factor = (vehicle.throttle_amount * 0.3) + 0.4  # Диапазон 0.4-0.7 вместо 0.5-1.0
	volume_db = linear_to_db(throttle_factor) - 6.0  # -6 дБ = вдвое тише
