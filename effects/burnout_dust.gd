extends GPUParticles3D

@export var vehicle: RigidBody3D
@export var min_longitudinal_slip := 0.55
@export var min_wheel_spin := 18.0


func _process(_delta: float) -> void:
	if not is_instance_valid(vehicle):
		return
	if not bool(vehicle.get("burnout_active")):
		return

	_emit_for_wheel(vehicle.get("rear_left_wheel"))
	_emit_for_wheel(vehicle.get("rear_right_wheel"))


func _emit_for_wheel(wheel: Variant) -> void:
	var wheel_raycast := wheel as RayCast3D
	if wheel_raycast == null or not wheel_raycast.is_colliding():
		return

	var slip_vector: Variant = wheel_raycast.get("slip_vector")
	var slip := absf(slip_vector.y) if slip_vector is Vector2 else 0.0
	var spin_value: Variant = wheel_raycast.get("spin")
	var spin := absf(float(spin_value)) if spin_value is float or spin_value is int else 0.0
	if slip < min_longitudinal_slip and spin < min_wheel_spin:
		return

	var particle_count := clampi(6 + int((spin - min_wheel_spin) * 0.15) + int(slip * 10.0), 6, 24)
	var particle_color := Color(0.78, 0.78, 0.78, 1.0)
	var surface_type := String(wheel_raycast.get("surface_type"))
	if surface_type == "Dirt" or surface_type == "Grass":
		particle_color = Color(0.55, 0.47, 0.36, 1.0)

	for i in particle_count:
		var t := Transform3D.IDENTITY
		var contact_point: Variant = wheel_raycast.get("last_collision_point")
		t.origin = contact_point if contact_point is Vector3 else wheel_raycast.global_position
		t.origin.x += randf_range(-0.1, 0.1)
		t.origin.y += randf_range(0.03, 0.08)
		t.origin.z += randf_range(-0.1, 0.1)

		var rearward := vehicle.global_transform.basis.z * randf_range(1.8, 3.3)
		var sideways := wheel_raycast.global_transform.basis.x * randf_range(-1.1, 1.1)
		var upward := Vector3.UP * randf_range(1.0, 2.2)
		var velocity := rearward + sideways + upward + (vehicle.linear_velocity * 0.12)

		emit_particle(t, velocity, particle_color, particle_color, 5)
