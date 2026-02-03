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

# Route visualization - густые точки маршрута для миникарты (не влияют на геймплей)
@export var route_points: Array = []  # Array[Vector2(lat, lon)] каждые ~30м


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
	# Густые точки маршрута для визуализации на миникарте (каждые ~30м)
	track.route_points = [
		Vector2(59.149827, 37.948859),
		Vector2(59.149307, 37.948601),
		Vector2(59.148223, 37.947829),
		Vector2(59.147065, 37.94704),
		Vector2(59.146691, 37.946772),
		Vector2(59.146212, 37.946402),
		Vector2(59.145588, 37.945919),
		Vector2(59.144677, 37.945254),
		Vector2(59.144251, 37.944948),
		Vector2(59.144204, 37.944905),
		Vector2(59.144234, 37.94468),
		Vector2(59.144564, 37.942051),
		Vector2(59.145029, 37.938409),
		Vector2(59.145043, 37.938243),
		Vector2(59.144952, 37.938189),
		Vector2(59.14397, 37.937706),
		Vector2(59.143021, 37.937234),
		Vector2(59.142036, 37.936757),
		Vector2(59.141978, 37.936741),
		Vector2(59.141554, 37.939927),
		Vector2(59.141153, 37.942953),
		Vector2(59.141131, 37.943237),
		Vector2(59.141166, 37.943414),
		Vector2(59.141354, 37.943516),
	]
	return track


static func get_track_by_id(id: String) -> Resource:
	for track in get_all_tracks():
		if track.track_id == id:
			return track
	return null
