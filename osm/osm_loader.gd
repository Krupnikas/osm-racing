extends Node
class_name OSMLoader

signal data_loaded(osm_data: Dictionary)
signal load_failed(error: String)

const OVERPASS_URL = "https://overpass-api.de/api/interpreter"

var http_request: HTTPRequest
var center_lat: float
var center_lon: float
var radius_meters: float

func _ready() -> void:
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)

func load_area(lat: float, lon: float, radius: float = 500.0) -> void:
	center_lat = lat
	center_lon = lon
	radius_meters = radius

	# Конвертируем радиус в градусы (приблизительно)
	var lat_delta := radius / 111000.0  # 111км на градус широты
	var lon_delta := radius / (111000.0 * cos(deg_to_rad(lat)))

	var bbox := "%f,%f,%f,%f" % [
		lat - lat_delta,
		lon - lon_delta,
		lat + lat_delta,
		lon + lon_delta
	]

	# Overpass запрос для получения дорог, зданий, водоёмов, зелени
	var query := """
[out:json][timeout:30];
(
  way["highway"](%s);
  way["building"](%s);
  way["landuse"](%s);
  way["natural"](%s);
  way["leisure"](%s);
  way["waterway"](%s);
);
out body;
>;
out skel qt;
""" % [bbox, bbox, bbox, bbox, bbox, bbox]

	var headers := ["Content-Type: application/x-www-form-urlencoded"]
	var body := "data=" + query.uri_encode()

	print("OSM: Loading area around %.6f, %.6f with radius %.0fm" % [lat, lon, radius])
	var error := http_request.request(OVERPASS_URL, headers, HTTPClient.METHOD_POST, body)

	if error != OK:
		load_failed.emit("HTTP request failed: " + str(error))

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		load_failed.emit("Request failed with result: " + str(result))
		return

	if response_code != 200:
		load_failed.emit("HTTP error: " + str(response_code))
		return

	var json_string := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_result := json.parse(json_string)

	if parse_result != OK:
		load_failed.emit("JSON parse error: " + json.get_error_message())
		return

	var data: Dictionary = json.data
	var parsed := _parse_osm_data(data)
	data_loaded.emit(parsed)

func _parse_osm_data(data: Dictionary) -> Dictionary:
	var nodes := {}
	var ways := []

	# Собираем все узлы
	for element in data.get("elements", []):
		if element.get("type") == "node":
			nodes[element.id] = {
				"lat": element.lat,
				"lon": element.lon
			}

	# Собираем все пути
	for element in data.get("elements", []):
		if element.get("type") == "way":
			var way_nodes := []
			for node_id in element.get("nodes", []):
				if nodes.has(node_id):
					way_nodes.append(nodes[node_id])

			if way_nodes.size() > 1:
				ways.append({
					"nodes": way_nodes,
					"tags": element.get("tags", {})
				})

	print("OSM: Parsed %d nodes and %d ways" % [nodes.size(), ways.size()])

	return {
		"center_lat": center_lat,
		"center_lon": center_lon,
		"nodes": nodes,
		"ways": ways
	}

# Конвертация координат в локальные метры относительно центра
func latlon_to_local(lat: float, lon: float) -> Vector2:
	var dx := (lon - center_lon) * 111000.0 * cos(deg_to_rad(center_lat))
	var dz := (lat - center_lat) * 111000.0
	return Vector2(dx, dz)
