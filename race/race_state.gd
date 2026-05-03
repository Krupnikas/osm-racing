extends Node

## Глобальное состояние гонки (Autoload)
## Используется для передачи данных между сценами

# Выбранный трек для загрузки в RaceScene
var selected_track = null

# Свободная езда - локация и координаты
var free_roam_location: String = ""
var free_roam_lat: float = 0.0
var free_roam_lon: float = 0.0

# Optional spawn-heading override (radians). NAN = no override (use road direction).
# Consumed once by main_menu._spawn_car_on_road() and reset to NAN.
var spawn_heading_yaw: float = NAN

# Тестовая трасса (без OSM)
var test_track_id: String = ""  # "test_flat" или "test_suspension"

# Карьера — если true, после гонки начисляется приз
var is_career_race: bool = false

# Режим работы (такси/доставка)
var is_work_mode: bool = false

# (Legacy) Трасса для автозапуска после перезагрузки сцены
var pending_track = null

## Маппинг русских имён на track_id для CLI
const _TRACK_NAME_MAP := {
	"плоская": "test_flat",
	"flat": "test_flat",
	"подвеска": "test_suspension",
	"suspension": "test_suspension",
	"нпс": "test_npc",
	"npc": "test_npc",
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--test-track="):
			var value := arg.substr("--test-track=".length()).strip_edges().to_lower()
			var tid := _resolve_track_id(value)
			if tid != "":
				test_track_id = tid
				print("RaceState: CLI --test-track=", value, " -> ", tid)
				call_deferred("_auto_launch_test_track")
			else:
				push_error("RaceState: Unknown test track: ", value)
				print("RaceState: Available tracks: flat, подвеска/suspension, нпс/npc")


func _resolve_track_id(name: String) -> String:
	# Сначала проверяем прямое совпадение с track_id
	if name.begins_with("test_"):
		for track in TestTracks.get_all_test_tracks():
			if track["track_id"] == name:
				return name
	# Потом по маппингу имён
	if _TRACK_NAME_MAP.has(name):
		return _TRACK_NAME_MAP[name]
	return ""


func _auto_launch_test_track() -> void:
	print("RaceState: Auto-launching test track: ", test_track_id)
	get_tree().change_scene_to_file("res://race/test_track_scene.tscn")
