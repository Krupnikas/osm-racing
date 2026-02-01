extends Node
class_name TestTracks

## Тестовые трассы (процедурные, без OSM)

static func get_all_test_tracks() -> Array:
	return [
		_create_flat_track(),
		_create_suspension_track(),
		_create_npc_track(),
	]

static func _create_flat_track() -> Dictionary:
	return {
		"track_id": "test_flat",
		"track_name": "Плоская трасса",
		"description": "Ровная дорога-кольцо для тестирования физики и скорости",
	}

static func _create_suspension_track() -> Dictionary:
	return {
		"track_id": "test_suspension",
		"track_name": "Тест подвески",
		"description": "Дорога с бугорками и ямами для тестирования подвески",
	}

static func _create_npc_track() -> Dictionary:
	return {
		"track_id": "test_npc",
		"track_name": "Много НПС",
		"description": "Овальная трасса с большим количеством NPC машин",
	}
