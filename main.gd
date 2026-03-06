extends Node3D

## Главная сцена свободной езды


func _ready() -> void:
	CarSpawner.replace_player_car(self)
