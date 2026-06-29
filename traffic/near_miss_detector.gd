extends Node
class_name NearMissDetector

## Детектор "near miss" — фиксирует проезд игрока вплотную к NPC на высокой скорости.
## Эмитит сигнал near_miss(combo_count) для внешних систем (стиль, нитро).
## Показывает титр через HUD.show_event_title().

signal near_miss(combo_count: int)

@export var min_speed_kmh := 60.0
@export var near_miss_distance := 4.0
@export var combo_window := 3.0
@export var cooldown_per_npc := 2.0

var player_car: Node3D
var traffic_manager: TrafficManager
var hud: Control

var _combo_count := 0
var _combo_timer := 0.0
var _recently_triggered: Dictionary = {}  # instance_id → timestamp


func _ready() -> void:
	player_car = get_tree().get_first_node_in_group("car")
	traffic_manager = get_parent().get_node_or_null("TrafficManager") as TrafficManager
	var ui_layer: Node = get_parent().get_node_or_null("UI")
	if ui_layer:
		hud = ui_layer.get_node_or_null("HUD")


func _physics_process(delta: float) -> void:
	# Lazy re-acquire: _ready() can run before the player car joins the "car"
	# group (or before TrafficManager exists), which left these null forever
	# and silently disabled near-miss detection.
	if not is_instance_valid(player_car):
		player_car = get_tree().get_first_node_in_group("car")
	if not is_instance_valid(traffic_manager):
		traffic_manager = get_parent().get_node_or_null("TrafficManager") as TrafficManager
	if not player_car or not traffic_manager:
		return

	# Комбо-таймер
	if _combo_timer > 0.0:
		_combo_timer -= delta
		if _combo_timer <= 0.0:
			_combo_count = 0

	# Скорость игрока
	var speed_kmh := 0.0
	if player_car is RigidBody3D:
		speed_kmh = player_car.linear_velocity.length() * 3.6
	elif player_car.get("current_speed_kmh") != null:
		speed_kmh = player_car.current_speed_kmh
	if speed_kmh < min_speed_kmh:
		return

	var player_pos := player_car.global_position
	var now := Time.get_ticks_msec() / 1000.0
	var dist_sq_threshold := near_miss_distance * near_miss_distance

	# Чистим старые записи
	var to_erase: Array = []
	for id in _recently_triggered:
		if now - _recently_triggered[id] > cooldown_per_npc:
			to_erase.append(id)
	for id in to_erase:
		_recently_triggered.erase(id)

	# Проверяем NPC
	for npc in traffic_manager.active_npcs:
		if not is_instance_valid(npc):
			continue
		var dist_sq: float = player_pos.distance_squared_to(npc.global_position)
		if dist_sq > dist_sq_threshold:
			continue

		var npc_id: int = npc.get_instance_id()
		if _recently_triggered.has(npc_id):
			continue

		# Near miss!
		_recently_triggered[npc_id] = now
		_combo_count += 1
		_combo_timer = combo_window
		near_miss.emit(_combo_count)
		_show_title()


func _show_title() -> void:
	if not hud or not hud.has_method("show_event_title"):
		return
	var text := "Near Miss" if _combo_count <= 1 else "Near Miss x%d" % _combo_count
	hud.show_event_title(text, combo_window)
