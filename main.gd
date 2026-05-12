extends Node3D

## Главная сцена свободной езды

const WorkManagerScript = preload("res://work/work_manager.gd")
const WorkHudScript = preload("res://work/work_hud.gd")


func _ready() -> void:
	CarSpawner.replace_player_car(self)

	if RaceState.is_work_mode:
		MusicManager.set_category(MusicManager.Category.WORK)
		_setup_work_mode()
	else:
		MusicManager.set_category(MusicManager.Category.RACE)


func _setup_work_mode() -> void:
	# Ждём кадр чтобы все ноды инициализировались
	await get_tree().process_frame

	var car := get_tree().get_first_node_in_group("car")
	var terrain := find_child("OSMTerrain", true, false)
	var hud := find_child("HUD", true, false)

	# Создаём WorkManager
	var work_manager := Node.new()
	work_manager.name = "WorkManager"
	work_manager.set_script(WorkManagerScript)
	add_child(work_manager)

	# Создаём WorkHUD
	var work_hud := CanvasLayer.new()
	work_hud.name = "WorkHUD"
	work_hud.layer = 10
	work_hud.set_script(WorkHudScript)
	add_child(work_hud)

	# Настраиваем связи
	work_manager.setup(car, terrain, work_hud)
	work_hud.setup(work_manager)

	print("Main: Work mode initialized")
