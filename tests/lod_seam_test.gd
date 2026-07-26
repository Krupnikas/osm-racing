extends Node3D

## LOD0↔LOD2 стык-тест. Форсирует ОДИН чанк (под машиной) в LOD0, а всех соседей — в
## плоский LOD2 (через маленький lod0_distance=105 < размера чанка). Камера ставится на
## общий край между LOD0-чанком и южным LOD2-соседом и смотрит поперёк стыка — чтобы
## визуально проверять/добиваться бесшовного перехода травы.
##
## Запуск (GUI):
##   Godot --path . tests/lod_seam_test.tscn
##   DEBUG_LOD2_MAGENTA=1 Godot --path . tests/lod_seam_test.tscn   # LOD2 подсветить магентой
## Флаги: --load-wait=SEC, --cam-h=METERS (высота камеры над стыком),
##        --cam-back=METERS (сколько метров севернее края), --cam-pitch=DEG

@export var shot_lat := 59.149827
@export var shot_lon := 37.948859
@export var load_wait := 16.0

var osm_terrain: Node
var camera: Camera3D
var _car: Node3D

var cam_h := 2.6
var cam_back := 7.0
var cam_pitch := -14.0
var do_quit := true
var lod0_dist := 105.0   # --lod0-dist= : поднять чтобы сосед тоже стал LOD0 (диагностика)
var with_buildings := false  # --with-buildings : показать LOD2 коробки зданий

const OUT_DIR := "res://screenshots/visual/"


func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if a.begins_with("--load-wait="): load_wait = float(a.substr(12))
		elif a.begins_with("--cam-h="): cam_h = float(a.substr(8))
		elif a.begins_with("--cam-back="): cam_back = float(a.substr(11))
		elif a.begins_with("--cam-pitch="): cam_pitch = float(a.substr(12))
		elif a.begins_with("--lod0-dist="): lod0_dist = float(a.substr(12))
		elif a == "--with-buildings": with_buildings = true
		elif a == "--no-quit": do_quit = false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	osm_terrain = get_node_or_null("OSMTerrain")
	if osm_terrain:
		osm_terrain.spawn_lat = shot_lat
		osm_terrain.spawn_lon = shot_lon
		# Форсируем LOD геометрией: lod0_distance=105 (< chunk_size 210) → только чанк,
		# чей центр ближе 105м (т.е. под машиной), будет LOD0; все соседи (центр в 210м) — LOD2.
		osm_terrain.enable_lod = true
		osm_terrain.lod0_distance = lod0_dist
		osm_terrain.lod1_distance = lod0_dist    # пустая полоса LOD1 → сосед сразу LOD2
		osm_terrain.lod2_distance = 4000.0
		osm_terrain.lod_hysteresis = 0.0
		# Чистый вид на стык травы: без зданий/растительности (если не --with-buildings)
		osm_terrain.enable_buildings = with_buildings
		osm_terrain.enable_vegetation = false

	camera = Camera3D.new()
	camera.name = "SeamCamera"
	camera.fov = 55.0
	camera.far = 3000.0
	add_child(camera)
	camera.global_position = Vector3(0, 400, 0)
	camera.current = true

	print("\n===== LOD SEAM TEST =====")
	print("Location (%.6f, %.6f)  load_wait=%.0fs" % [shot_lat, shot_lon, load_wait])
	print("=========================\n")
	_run.call_deferred()


func _chunk_center() -> Vector2:
	# Центр чанка, содержащего спавн-точку.
	var off: Vector2 = osm_terrain.get_spawn_world_position()
	var cs: float = osm_terrain.chunk_size
	var cx := int(floor(off.x / cs))
	var cz := int(floor(off.y / cs))
	return Vector2(cx * cs + cs * 0.5, cz * cs + cs * 0.5)


func _ground_y(x: float, z: float) -> float:
	# Реальная высота поверхности (рейкаст вниз; фолбэк — сэмпл высоты).
	var space := get_viewport().world_3d.direct_space_state
	var elev: float = osm_terrain._sample_elevation(x, z) if osm_terrain.has_method("_sample_elevation") else 120.0
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, elev + 150.0, z), Vector3(x, elev - 150.0, z))
	q.collision_mask = 1
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		return hit.position.y
	return elev


func _run() -> void:
	# 1) Дать террейну инициализироваться, поставить машину в ЦЕНТР её чанка (LOD0-остров).
	await get_tree().create_timer(1.0).timeout
	_car = get_node_or_null("Car")
	var center := _chunk_center()
	var cs: float = osm_terrain.chunk_size
	var prov_y: float = (osm_terrain._sample_elevation(center.x, center.y) if osm_terrain.has_method("_sample_elevation") else 120.0)
	if _car:
		if _car is RigidBody3D:
			_car.freeze = true
			_car.linear_velocity = Vector3.ZERO
			_car.angular_velocity = Vector3.ZERO
		_car.global_position = Vector3(center.x, prov_y + 0.5, center.y)

	# 2) Ждём стрим чанков (машина в центре → её чанк LOD0, соседи LOD2).
	print("[seam] waiting %.0fs for chunks (LOD0 island + LOD2 neighbours)..." % load_wait)
	await get_tree().create_timer(load_wait).timeout
	await _settle(6)

	# 3) Точная высота + камера на ЮЖНОМ крае чанка, взгляд на юг (+Z) поперёк стыка.
	var gy := _ground_y(center.x, center.y)
	if _car:
		_car.global_position = Vector3(center.x, gy + 0.4, center.y)
	var cz_chunk := int(floor(center.y / cs))
	var edge_z: float = (cz_chunk + 1) * cs   # граница с южным соседом (LOD2)
	var edge_gy := _ground_y(center.x, edge_z)
	camera.global_position = Vector3(center.x, edge_gy + cam_h, edge_z - cam_back)
	camera.rotation = Vector3.ZERO
	camera.rotation_degrees = Vector3(cam_pitch, 0, 0)  # смотрит на -Z? нет: по умолчанию -Z. нужно +Z
	# Камера смотрит на ЮГ (+Z): развернём на 180° по Y, затем наклон вниз.
	camera.rotation_degrees = Vector3(cam_pitch, 180.0, 0)
	print("[seam] chunk_center=%s edge_z=%.1f gy=%.1f cam=%s (looking south across seam)" % [center, edge_z, edge_gy, camera.global_position])

	await _settle(6)
	await get_tree().create_timer(3.0).timeout   # добрать генерацию LOD2-соседа
	await _settle(6)
	_shoot("lod_seam")

	print("[seam] DONE")
	if do_quit:
		await _safe_quit()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shoot(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := OUT_DIR + tag + ".png"
	var err := img.save_png(ProjectSettings.globalize_path(path))
	print("[seam] saved %s (%dx%d) err=%d" % [path, img.get_width(), img.get_height(), err])


func _safe_quit() -> void:
	print("[seam] hard-exit (SIGKILL) to skip crashy engine teardown")
	await _settle(2)
	OS.kill(OS.get_process_id())
