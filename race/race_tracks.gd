extends Resource
class_name RaceTrack

## Данные трассы для режима гонки

@export var track_name: String
@export var track_id: String
@export var start_lat: float
@export var start_lon: float
@export var finish_lat: float
@export var finish_lon: float
@export var waypoints: Array  # lat/lon точки для предзагрузки чанков (Vector2)

# Checkpoint mode fields
@export var race_mode: String = "sprint"  # "sprint" или "checkpoint"
@export var checkpoints: Array = []        # [{lat, lon, time_limit}] для checkpoint mode
@export var default_checkpoint_time: float = 30.0


static func get_all_tracks() -> Array:
	return [_create_pionerskaya(), _create_fanera()]


static func get_sprint_tracks() -> Array:
	var tracks := []
	for track in get_all_tracks():
		if track.race_mode == "sprint":
			tracks.append(track)
	return tracks


static func get_checkpoint_tracks() -> Array:
	var tracks := []
	for track in get_all_tracks():
		if track.race_mode == "checkpoint":
			tracks.append(track)
	return tracks


static func _create_pionerskaya() -> Resource:
	var script = load("res://race/race_tracks.gd")
	var track = script.new()
	track.track_name = "Пионерская"
	track.track_id = "pionerskaya"
	track.race_mode = "sprint"
	track.start_lat = 59.149827
	track.start_lon = 37.948859
	track.finish_lat = 59.142110
	track.finish_lon = 37.943897
	# Waypoints для предзагрузки чанков вдоль маршрута
	track.waypoints = [
		Vector2(59.149827, 37.948859),  # Старт
		Vector2(59.148, 37.947),         # Промежуточная 1
		Vector2(59.146, 37.946),         # Промежуточная 2
		Vector2(59.144, 37.945),         # Промежуточная 3
		Vector2(59.142110, 37.943897)   # Финиш
	]
	return track


static func _create_fanera() -> Resource:
	var script = load("res://race/race_tracks.gd")
	var track = script.new()
	track.track_name = "Фанера"
	track.track_id = "fanera"
	track.race_mode = "checkpoint"
	track.start_lat = 59.149827  # Такой же старт как Пионерская
	track.start_lon = 37.948859
	track.finish_lat = 59.141354
	track.finish_lon = 37.943516
	track.default_checkpoint_time = 30.0
	# Чекпоинты с временем на прохождение
	track.checkpoints = [
		{"lat": 59.144251, "lon": 37.944562, "time_limit": 30.0},  # CP1
		{"lat": 59.144855, "lon": 37.938141, "time_limit": 30.0},  # CP2
		{"lat": 59.141942, "lon": 37.937057, "time_limit": 30.0}   # CP3
	]
	# Waypoints для предзагрузки чанков вдоль маршрута
	track.waypoints = [
		Vector2(59.149827, 37.948859),  # Старт
		Vector2(59.147, 37.946),         # Промежуточная
		Vector2(59.144251, 37.944562),  # CP1
		Vector2(59.144855, 37.938141),  # CP2
		Vector2(59.141942, 37.937057),  # CP3
		Vector2(59.141354, 37.943516)   # Финиш
	]
	return track


static func get_track_by_id(id: String) -> Resource:
	for track in get_all_tracks():
		if track.track_id == id:
			return track
	return null
