extends Node3D
class_name OSMTerrainGenerator

@export var start_lat := 59.149886
@export var start_lon := 37.949370
@export var area_radius := 300.0  # метров

var osm_loader: OSMLoader
var terrain_mesh: MeshInstance3D
var terrain_body: StaticBody3D

# Цвета для разных типов поверхностей
const COLORS := {
	"road_primary": Color(0.3, 0.3, 0.3),      # Тёмно-серый - главные дороги
	"road_secondary": Color(0.4, 0.4, 0.4),    # Серый - второстепенные
	"road_residential": Color(0.5, 0.5, 0.5),  # Светло-серый - жилые
	"road_path": Color(0.6, 0.5, 0.4),         # Коричневатый - тропинки
	"building": Color(0.6, 0.4, 0.3),          # Коричневый - здания
	"water": Color(0.2, 0.4, 0.7),             # Синий - вода
	"grass": Color(0.3, 0.6, 0.3),             # Зелёный - трава/парки
	"forest": Color(0.2, 0.5, 0.2),            # Тёмно-зелёный - лес
	"farmland": Color(0.7, 0.7, 0.4),          # Жёлто-зелёный - поля
	"default": Color(0.4, 0.5, 0.4),           # Базовый цвет земли
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
	osm_loader = OSMLoader.new()
	add_child(osm_loader)
	osm_loader.data_loaded.connect(_on_osm_data_loaded)
	osm_loader.load_failed.connect(_on_osm_load_failed)

	_create_base_terrain()
	osm_loader.load_area(start_lat, start_lon, area_radius)

func _create_base_terrain() -> void:
	# Базовая плоскость
	terrain_body = StaticBody3D.new()
	terrain_body.name = "TerrainBody"
	add_child(terrain_body)

	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(area_radius * 2.5, 1, area_radius * 2.5)
	collision.shape = box_shape
	collision.position.y = -0.5
	terrain_body.add_child(collision)

	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "TerrainMesh"
	var plane := PlaneMesh.new()
	plane.size = Vector2(area_radius * 2.5, area_radius * 2.5)
	terrain_mesh.mesh = plane

	var material := StandardMaterial3D.new()
	material.albedo_color = COLORS["default"]
	terrain_mesh.material_override = material
	terrain_body.add_child(terrain_mesh)

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_osm_data_loaded(osm_data: Dictionary) -> void:
	print("OSM: Generating terrain from loaded data...")
	_generate_terrain(osm_data)

func _generate_terrain(osm_data: Dictionary) -> void:
	var ways: Array = osm_data.get("ways", [])

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])

		if nodes.size() < 2:
			continue

		# Определяем тип объекта и создаём геометрию
		if tags.has("highway"):
			_create_road(nodes, tags)
		elif tags.has("building"):
			_create_building(nodes, tags)
		elif tags.has("natural"):
			_create_natural(nodes, tags)
		elif tags.has("landuse"):
			_create_landuse(nodes, tags)
		elif tags.has("leisure"):
			_create_leisure(nodes, tags)
		elif tags.has("waterway"):
			_create_waterway(nodes, tags)

	print("OSM: Terrain generation complete!")

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

	_create_path_mesh(nodes, width, color, 0.02)

func _create_path_mesh(nodes: Array, width: float, color: Color, height: float) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local := osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Создаём меш для каждого сегмента дороги
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]

		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x) * width * 0.5

		var mesh := MeshInstance3D.new()
		var im := ImmediateMesh.new()
		mesh.mesh = im

		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material_override = material

		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

		# Два треугольника для сегмента дороги
		var v1 := Vector3(p1.x - perp.x, height, p1.y - perp.y)
		var v2 := Vector3(p1.x + perp.x, height, p1.y + perp.y)
		var v3 := Vector3(p2.x + perp.x, height, p2.y + perp.y)
		var v4 := Vector3(p2.x - perp.x, height, p2.y - perp.y)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v2)
		im.surface_add_vertex(v3)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v4)

		im.surface_end()

		add_child(mesh)

func _create_building(nodes: Array, _tags: Dictionary) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local := osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Простой полигон для здания (на земле)
	_create_polygon_mesh(points, COLORS["building"], 0.03)

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
		var local := osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.01)

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
		var local := osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.005)

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
		var local := osm_loader.latlon_to_local(node.lat, node.lon)
		points.append(local)

	_create_polygon_mesh(points, color, 0.01)

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

	_create_path_mesh(nodes, width, COLORS["water"], 0.01)

func _create_polygon_mesh(points: PackedVector2Array, color: Color, height: float) -> void:
	if points.size() < 3:
		return

	# Простая триангуляция (fan от первой точки)
	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var center := Vector2.ZERO
	for p in points:
		center += p
	center /= points.size()

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		im.surface_add_vertex(Vector3(center.x, height, center.y))
		im.surface_add_vertex(Vector3(p1.x, height, p1.y))
		im.surface_add_vertex(Vector3(p2.x, height, p2.y))

	im.surface_end()

	add_child(mesh)
