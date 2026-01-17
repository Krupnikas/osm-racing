extends Node3D
class_name OSMTerrainGenerator

const OSMLoaderScript = preload("res://osm/osm_loader.gd")

@export var start_lat := 59.149886
@export var start_lon := 37.949370
@export var area_radius := 300.0  # метров

var osm_loader: Node
var terrain_mesh: MeshInstance3D
var terrain_body: StaticBody3D

# Цвета для разных типов поверхностей
const COLORS := {
	"road_primary": Color(0.3, 0.3, 0.3),
	"road_secondary": Color(0.4, 0.4, 0.4),
	"road_residential": Color(0.5, 0.5, 0.5),
	"road_path": Color(0.6, 0.5, 0.4),
	"building": Color(0.6, 0.4, 0.3),
	"water": Color(0.2, 0.4, 0.7),
	"grass": Color(0.3, 0.6, 0.3),
	"forest": Color(0.2, 0.5, 0.2),
	"farmland": Color(0.7, 0.7, 0.4),
	"default": Color(0.4, 0.5, 0.4),
}

const ROAD_WIDTHS := {
	"motorway": 12.0,
	"trunk": 10.0,
	"primary": 8.0,
	"secondary": 7.0,
	"tertiary": 6.0,
	"residential": 5.0,
	"service": 4.0,
	"footway": 2.0,
	"path": 1.5,
	"cycleway": 2.0,
	"track": 3.0,
}

func _ready() -> void:
	osm_loader = OSMLoaderScript.new()
	add_child(osm_loader)
	osm_loader.data_loaded.connect(_on_osm_data_loaded)
	osm_loader.load_failed.connect(_on_osm_load_failed)

	print("OSM: Starting data load...")
	osm_loader.load_area(start_lat, start_lon, area_radius)

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_osm_data_loaded(osm_data: Dictionary) -> void:
	print("OSM: Generating terrain from loaded data...")
	_generate_terrain(osm_data)

func _generate_terrain(osm_data: Dictionary) -> void:
	var ways: Array = osm_data.get("ways", [])
	var road_count := 0
	var building_count := 0

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])

		if nodes.size() < 2:
			continue

		if tags.has("highway"):
			_create_road(nodes, tags)
			road_count += 1
		elif tags.has("building"):
			_create_building(nodes, tags)
			building_count += 1
		elif tags.has("natural"):
			_create_natural(nodes, tags)
		elif tags.has("landuse"):
			_create_landuse(nodes, tags)
		elif tags.has("leisure"):
			_create_leisure(nodes, tags)
		elif tags.has("waterway"):
			_create_waterway(nodes, tags)

	print("OSM: Generated %d roads, %d buildings" % [road_count, building_count])

func _create_road(nodes: Array, tags: Dictionary) -> void:
	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	var color: Color
	match highway_type:
		"motorway", "trunk", "primary":
			color = COLORS["road_primary"]
		"secondary", "tertiary":
			color = COLORS["road_secondary"]
		"footway", "path", "cycleway", "track":
			color = COLORS["road_path"]
		_:
			color = COLORS["road_residential"]

	_create_path_mesh(nodes, width, color, 0.1)

func _create_path_mesh(nodes: Array, width: float, color: Color, height: float) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Создаём один меш для всей дороги
	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Видно с обеих сторон
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]

		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x) * width * 0.5

		var v1 := Vector3(p1.x - perp.x, height, p1.y - perp.y)
		var v2 := Vector3(p1.x + perp.x, height, p1.y + perp.y)
		var v3 := Vector3(p2.x + perp.x, height, p2.y + perp.y)
		var v4 := Vector3(p2.x - perp.x, height, p2.y - perp.y)

		# Первый треугольник (порядок против часовой стрелки для нормали вверх)
		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v2)

		# Второй треугольник
		im.surface_add_vertex(v1)
		im.surface_add_vertex(v4)
		im.surface_add_vertex(v3)

	im.surface_end()
	add_child(mesh)

func _create_building(nodes: Array, tags: Dictionary) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Определяем высоту здания
	var height := 8.0  # По умолчанию ~2-3 этажа
	if tags.has("building:levels"):
		var levels = int(tags.get("building:levels", "3"))
		height = levels * 3.0  # 3 метра на этаж
	elif tags.has("height"):
		height = float(tags.get("height", "8"))

	_create_3d_building(points, COLORS["building"], height)

func _create_natural(nodes: Array, tags: Dictionary) -> void:
	if nodes.size() < 3:
		return

	var natural_type: String = tags.get("natural", "")
	var color: Color

	match natural_type:
		"water":
			color = COLORS["water"]
		"wood", "tree_row":
			color = COLORS["forest"]
		"grassland", "scrub":
			color = COLORS["grass"]
		_:
			color = COLORS["grass"]

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.04)

func _create_landuse(nodes: Array, tags: Dictionary) -> void:
	if nodes.size() < 3:
		return

	var landuse_type: String = tags.get("landuse", "")
	var color: Color

	match landuse_type:
		"residential":
			color = COLORS["default"]
		"commercial", "industrial":
			color = COLORS["building"]
		"farmland", "farm":
			color = COLORS["farmland"]
		"forest":
			color = COLORS["forest"]
		"grass", "meadow", "recreation_ground":
			color = COLORS["grass"]
		"reservoir", "basin":
			color = COLORS["water"]
		_:
			color = COLORS["default"]

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.02)

func _create_leisure(nodes: Array, tags: Dictionary) -> void:
	if nodes.size() < 3:
		return

	var leisure_type: String = tags.get("leisure", "")
	var color: Color

	match leisure_type:
		"park", "garden":
			color = COLORS["grass"]
		"pitch", "stadium":
			color = Color(0.3, 0.5, 0.3)
		"swimming_pool":
			color = COLORS["water"]
		_:
			color = COLORS["grass"]

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.04)

func _create_waterway(nodes: Array, tags: Dictionary) -> void:
	var waterway_type: String = tags.get("waterway", "")
	var width: float

	match waterway_type:
		"river":
			width = 15.0
		"stream":
			width = 3.0
		"canal":
			width = 8.0
		"ditch", "drain":
			width = 2.0
		_:
			width = 5.0

	_create_path_mesh(nodes, width, COLORS["water"], 0.03)

func _create_3d_building(points: PackedVector2Array, color: Color, building_height: float) -> void:
	if points.size() < 3:
		return

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Крыша (верхняя грань)
	var center := Vector2.ZERO
	for p in points:
		center += p
	center /= points.size()

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		im.surface_add_vertex(Vector3(center.x, building_height, center.y))
		im.surface_add_vertex(Vector3(p1.x, building_height, p1.y))
		im.surface_add_vertex(Vector3(p2.x, building_height, p2.y))

	# Стены
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Два треугольника для каждой стены
		var v1 := Vector3(p1.x, 0, p1.y)
		var v2 := Vector3(p2.x, 0, p2.y)
		var v3 := Vector3(p2.x, building_height, p2.y)
		var v4 := Vector3(p1.x, building_height, p1.y)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v2)
		im.surface_add_vertex(v3)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v4)

	im.surface_end()

	# Добавляем коллизию для здания
	var body := StaticBody3D.new()
	body.add_child(mesh)

	# Простая коллизия - бокс вокруг здания
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()

	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	box.size = Vector3(max_x - min_x, building_height, max_z - min_z)
	collision.shape = box
	collision.position = Vector3((min_x + max_x) / 2, building_height / 2, (min_z + max_z) / 2)
	body.add_child(collision)

	add_child(body)

func _create_polygon_mesh(points: PackedVector2Array, color: Color, height: float) -> void:
	if points.size() < 3:
		return

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Видно с обеих сторон
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var center := Vector2.ZERO
	for p in points:
		center += p
	center /= points.size()

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Порядок против часовой стрелки для нормали вверх
		im.surface_add_vertex(Vector3(center.x, height, center.y))
		im.surface_add_vertex(Vector3(p2.x, height, p2.y))
		im.surface_add_vertex(Vector3(p1.x, height, p1.y))

	im.surface_end()

	add_child(mesh)
