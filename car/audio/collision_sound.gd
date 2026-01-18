extends Node
class_name CollisionSound

## Звук и эффект столкновения

@export var min_impact_velocity := 2.0
@export var max_volume := 5.0
@export var min_volume := -5.0

var _car: VehicleBody3D = null
var _last_velocity := Vector3.ZERO
var _cooldown := 0.0
var _initialized := false

var _audio_player: AudioStreamPlayer
var _crash_sounds: Array[AudioStreamWAV] = []

func _ready() -> void:
	# Создаём аудио плеер как дочерний узел
	_audio_player = AudioStreamPlayer.new()
	_audio_player.bus = "Master"
	_audio_player.volume_db = max_volume
	add_child(_audio_player)

	# Генерируем звуки
	for i in range(5):
		_crash_sounds.append(_generate_crash_sound(i))

	# Ищем машину
	var parent = get_parent()
	if parent is VehicleBody3D:
		_car = parent

func _physics_process(delta: float) -> void:
	if _cooldown > 0:
		_cooldown -= delta

	# Ищем машину
	if not _car:
		var parent = get_parent()
		if parent is VehicleBody3D:
			_car = parent
		return

	var current_velocity := _car.linear_velocity

	# Инициализация
	if not _initialized:
		_last_velocity = current_velocity
		_initialized = true
		return

	# Изменение скорости
	var velocity_change := (current_velocity - _last_velocity).length()
	_last_velocity = current_velocity

	# Столкновение
	if velocity_change > min_impact_velocity and _cooldown <= 0:
		_play_crash(velocity_change)
		_spawn_sparks(velocity_change)
		_cooldown = 0.25

func _play_crash(impact: float) -> void:
	var sound := _crash_sounds[randi() % _crash_sounds.size()]
	_audio_player.stream = sound
	_audio_player.volume_db = lerp(min_volume, max_volume, clamp(impact / 10.0, 0.0, 1.0))
	_audio_player.pitch_scale = randf_range(0.8, 1.2)
	_audio_player.play()

func _spawn_sparks(impact: float) -> void:
	if not _car:
		return

	var impact_factor: float = clamp(impact / 15.0, 0.0, 1.0)

	# Позиция взрыва - впереди машины (точка контакта)
	var forward_dir := _car.global_transform.basis.z
	var collision_pos := _car.global_position + forward_dir * 2.0 + Vector3(0, 0.5, 0)

	# === ГЛАВНЫЙ ВЗРЫВ - много больших ярких искр ===
	var explosion := GPUParticles3D.new()
	explosion.emitting = true
	explosion.one_shot = true
	explosion.explosiveness = 1.0
	explosion.amount = int(300 + impact_factor * 700)  # 300-1000 искр
	explosion.lifetime = 1.0 + impact_factor * 0.5

	var exp_mat := ParticleProcessMaterial.new()
	exp_mat.direction = Vector3(0, 1, 0)
	exp_mat.spread = 180.0
	exp_mat.initial_velocity_min = 10.0 + impact_factor * 15.0
	exp_mat.initial_velocity_max = 30.0 + impact_factor * 40.0
	exp_mat.gravity = Vector3(0, -8, 0)
	exp_mat.scale_min = 0.05 + impact_factor * 0.05
	exp_mat.scale_max = 0.2 + impact_factor * 0.3
	exp_mat.damping_min = 0.5
	exp_mat.damping_max = 2.0
	# Яркий оранжево-жёлтый цвет
	exp_mat.color = Color(1.0, 0.8, 0.3, 1.0)
	explosion.process_material = exp_mat

	var exp_mesh := SphereMesh.new()
	exp_mesh.radius = 0.08
	exp_mesh.height = 0.16
	var exp_mesh_mat := StandardMaterial3D.new()
	exp_mesh_mat.albedo_color = Color(1.0, 0.95, 0.6)
	exp_mesh_mat.emission_enabled = true
	exp_mesh_mat.emission = Color(1.0, 0.8, 0.2)
	exp_mesh_mat.emission_energy_multiplier = 8.0 + impact_factor * 12.0
	exp_mesh.material = exp_mesh_mat
	explosion.draw_pass_1 = exp_mesh
	explosion.global_position = collision_pos
	get_tree().current_scene.add_child(explosion)

	# === ОГНЕННОЕ ЯДРО - яркая вспышка в центре ===
	var core := GPUParticles3D.new()
	core.emitting = true
	core.one_shot = true
	core.explosiveness = 1.0
	core.amount = int(50 + impact_factor * 100)
	core.lifetime = 0.3 + impact_factor * 0.2

	var core_mat := ParticleProcessMaterial.new()
	core_mat.direction = Vector3(0, 1, 0)
	core_mat.spread = 180.0
	core_mat.initial_velocity_min = 2.0
	core_mat.initial_velocity_max = 8.0
	core_mat.gravity = Vector3(0, 2, 0)  # Поднимаются вверх
	core_mat.scale_min = 0.3 + impact_factor * 0.2
	core_mat.scale_max = 0.6 + impact_factor * 0.4
	core_mat.color = Color(1.0, 1.0, 0.8, 1.0)  # Почти белый
	core.process_material = core_mat

	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.15
	core_mesh.height = 0.3
	var core_mesh_mat := StandardMaterial3D.new()
	core_mesh_mat.albedo_color = Color(1.0, 1.0, 0.9)
	core_mesh_mat.emission_enabled = true
	core_mesh_mat.emission = Color(1.0, 0.95, 0.7)
	core_mesh_mat.emission_energy_multiplier = 15.0 + impact_factor * 15.0
	core_mesh.material = core_mesh_mat
	core.draw_pass_1 = core_mesh
	core.global_position = collision_pos
	get_tree().current_scene.add_child(core)

	# === РАЗЛЕТАЮЩИЕСЯ ИСКРЫ - длинные следы ===
	var trails := GPUParticles3D.new()
	trails.emitting = true
	trails.one_shot = true
	trails.explosiveness = 0.9
	trails.amount = int(100 + impact_factor * 200)
	trails.lifetime = 1.5 + impact_factor * 1.0

	var trails_mat := ParticleProcessMaterial.new()
	trails_mat.direction = Vector3(0, 0.5, 0)
	trails_mat.spread = 180.0
	trails_mat.initial_velocity_min = 15.0 + impact_factor * 20.0
	trails_mat.initial_velocity_max = 40.0 + impact_factor * 50.0
	trails_mat.gravity = Vector3(0, -15, 0)
	trails_mat.scale_min = 0.02
	trails_mat.scale_max = 0.06
	trails_mat.damping_min = 0.2
	trails_mat.damping_max = 1.0
	trails_mat.color = Color(1.0, 0.6, 0.1, 1.0)  # Оранжевый
	trails.process_material = trails_mat

	var trails_mesh := SphereMesh.new()
	trails_mesh.radius = 0.04
	trails_mesh.height = 0.08
	var trails_mesh_mat := StandardMaterial3D.new()
	trails_mesh_mat.albedo_color = Color(1.0, 0.7, 0.3)
	trails_mesh_mat.emission_enabled = true
	trails_mesh_mat.emission = Color(1.0, 0.5, 0.1)
	trails_mesh_mat.emission_energy_multiplier = 6.0
	trails_mesh.material = trails_mesh_mat
	trails.draw_pass_1 = trails_mesh
	trails.global_position = collision_pos
	get_tree().current_scene.add_child(trails)

	# Удаляем все частицы через время
	var timer := get_tree().create_timer(3.0)
	timer.timeout.connect(func():
		if is_instance_valid(explosion): explosion.queue_free()
		if is_instance_valid(core): core.queue_free()
		if is_instance_valid(trails): trails.queue_free()
	)

func _generate_crash_sound(variant: int) -> AudioStreamWAV:
	var sample_rate := 44100
	var duration := 0.25 + variant * 0.05
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	var decay := 8.0 + variant * 2.0
	var freq1 := 1500.0 + variant * 500.0
	var freq2 := 2500.0 + variant * 400.0
	var impact_freq := 50.0 + variant * 15.0

	seed(variant * 54321)

	for i in range(samples):
		var t := float(i) / sample_rate
		var env := exp(-t * decay)

		var sample := 0.0
		sample += (randf() - 0.5) * 0.5 * env  # Шум
		sample += sin(t * freq1 * TAU) * 0.15 * env  # Высокий звон
		sample += sin(t * freq2 * TAU) * 0.1 * env * exp(-t * 12.0)
		sample += sin(t * impact_freq * TAU) * 0.4 * exp(-t * 20.0)  # Удар

		sample = clamp(sample, -0.95, 0.95)

		var sample_int := int(sample * 32767)
		data[i * 2] = sample_int & 0xFF
		data[i * 2 + 1] = (sample_int >> 8) & 0xFF

	randomize()

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = data

	return wav
