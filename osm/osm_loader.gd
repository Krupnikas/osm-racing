extends Node
class_name OSMLoader

signal data_loaded(osm_data: Dictionary)
signal load_failed(error: String)

# Список серверов Overpass API (fallback)
const OVERPASS_SERVERS := [
	"https://overpass.kumi.systems/api/interpreter",
	"https://overpass-api.de/api/interpreter",
	"https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

var http_request: HTTPRequest
var center_lat: float
var center_lon: float
var radius_meters: float
var current_server_index := 0
var retry_count := 0
var max_retries := 3
var pending_query: String = ""

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

	# Overpass запрос для получения дорог, зданий, водоёмов, зелени, amenity
	var query := """
[out:json][timeout:30];
(
  way["highway"](%s);
  way["building"](%s);
  way["landuse"](%s);
  way["natural"](%s);
  way["leisure"](%s);
  way["waterway"](%s);
  way["amenity"](%s);
);
out body;
>;
out skel qt;
""" % [bbox, bbox, bbox, bbox, bbox, bbox, bbox]

	pending_query = query
	current_server_index = 0
	retry_count = 0
	_send_request()

func _send_request() -> void:
	var server_url: String = OVERPASS_SERVERS[current_server_index]
	var headers := ["Content-Type: application/x-www-form-urlencoded"]
	var body := "data=" + pending_query.uri_encode()

	print("OSM: Trying server %s (attempt %d)" % [server_url, retry_count + 1])
	var error := http_request.request(server_url, headers, HTTPClient.METHOD_POST, body)

	if error != OK:
		_try_next_server("HTTP request failed: " + str(error))

func _try_next_server(reason: String) -> void:
	print("OSM: Server failed - %s" % reason)
	retry_count += 1

	if retry_count < max_retries:
		current_server_index = (current_server_index + 1) % OVERPASS_SERVERS.size()
		print("OSM: Retrying with next server...")
		_send_request()
	else:
		load_failed.emit("All servers failed after %d attempts. Last error: %s" % [max_retries, reason])

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_try_next_server("Request failed with result: " + str(result))
		return

	if response_code != 200:
		_try_next_server("HTTP error: " + str(response_code))
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
