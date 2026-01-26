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


static func get_all_tracks() -> Array:
	return [_create_pionerskaya()]


static func _create_pionerskaya() -> Resource:
	var script = load("res://race/race_tracks.gd")
	var track = script.new()
	track.track_name = "Пионерская"
	track.track_id = "pionerskaya"
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


static func get_track_by_id(id: String) -> Resource:
	for track in get_all_tracks():
		if track.track_id == id:
			return track
	return null
