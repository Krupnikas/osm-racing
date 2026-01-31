extends Node
class_name TestTracks

## Test tracks для тестирования различных аспектов игры

static func get_all_test_tracks() -> Array:
	"""Возвращает список всех тестовых трасс"""
	return [
		_create_flat_track(),
		_create_suspension_track(),
		_create_buildings_track(),
		_create_npc_track(),
		_create_elevation_track(),
	]

static func _create_flat_track() -> Resource:
	"""Плоская трасса - для тестирования скорости и базовой физики"""
	var track = load("res://race/race_track.gd").new()
	track.track_id = "test_flat"
	track.track_name = "Плоская трасса"
	track.start_lat = 59.12  # Череповец, промзона
	track.start_lon = 37.95
	track.finish_lat = 59.12
	track.finish_lon = 37.96
	track.waypoints = []
	return track

static func _create_suspension_track() -> Resource:
	"""Тест подвески - холмистая местность"""
	var track = load("res://race/race_track.gd").new()
	track.track_id = "test_suspension"
	track.track_name = "Тест подвески"
	# Тбилиси - холмистая местность
	track.start_lat = 41.72
	track.start_lon = 44.73
	track.finish_lat = 41.73
	track.finish_lon = 44.74
	track.waypoints = []
	return track

static func _create_buildings_track() -> Resource:
	"""Куча зданий - плотная застройка для теста производительности"""
	var track = load("res://race/race_track.gd").new()
	track.track_id = "test_buildings"
	track.track_name = "Куча зданий"
	# Москва центр - плотная застройка
	track.start_lat = 55.75
	track.start_lon = 37.62
	track.finish_lat = 55.76
	track.finish_lon = 37.63
	track.waypoints = []
	return track

static func _create_npc_track() -> Resource:
	"""НПС тест - для тестирования траффика"""
	var track = load("res://race/race_track.gd").new()
	track.track_id = "test_npc"
	track.track_name = "Тест НПС"
	# Москва, оживлённая улица
	track.start_lat = 55.76
	track.start_lon = 37.63
	track.finish_lat = 55.77
	track.finish_lon = 37.64
	track.waypoints = []
	return track

static func _create_elevation_track() -> Resource:
	"""Элевейшн - горная местность с перепадами высот"""
	var track = load("res://race/race_track.gd").new()
	track.track_id = "test_elevation"
	track.track_name = "Тест элевейшн"
	# Тбилиси, горные районы
	track.start_lat = 41.69
	track.start_lon = 44.80
	track.finish_lat = 41.70
	track.finish_lon = 44.81
	track.waypoints = []
	return track
