extends Node
class_name LocalOSMLoader

# Drop-in replacement for OSMLoader backed by a bundled .osm.pbf (LocalOSMSource).
# Same public contract: `load_area(lat, lon, radius)` + `data_loaded` / `load_failed`
# signals, and it is a Node the consumer queue_free()s after handling the callback.
#
# Emits asynchronously (next _process tick) to match the network loader's timing and
# avoid re-entrancy into the chunk pipeline from inside _load_chunk().

signal data_loaded(osm_data: Dictionary)
signal load_failed(error: String)

var _source: LocalOSMSource
var _pending := false
var _lat := 0.0
var _lon := 0.0
var _radius := 0.0


func _init(source: LocalOSMSource) -> void:
	_source = source


func load_area(lat: float, lon: float, radius: float = 500.0) -> void:
	_lat = lat
	_lon = lon
	_radius = radius
	if _source == null:
		set_process(false)
		call_deferred("_emit_failed", "LocalOSMLoader: no source")
		return
	# Defer the actual slice/emit to _process so the callback fires asynchronously.
	_pending = true
	set_process(true)


func _process(_delta: float) -> void:
	if not _pending:
		set_process(false)
		return
	if not _source.is_ready():
		return  # index still building on the worker thread
	_pending = false
	set_process(false)
	if _source.load_failed():
		_emit_failed("LocalOSMSource: .pbf decode failed")
		return
	var elements := _source.build_elements(_lat, _lon, _radius)
	var parsed := OSMParse.parse_elements(elements, _lat, _lon)
	data_loaded.emit(parsed)


func _emit_failed(msg: String) -> void:
	load_failed.emit(msg)
