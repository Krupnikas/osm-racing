class_name PoleCache
extends RefCounted

## Известные позиции придорожных столбов вдоль трассы (baked offline, data/race_poles/<track>.json).
## Spatial hash по XZ-ячейкам ~CELL м → O(1) запрос «столбы рядом с машиной» каждый кадр (Fray danger-map
## по ИЗВЕСТНОЙ позиции: без ray-gap, видит за поворотом). Столбы не двигаются → строим один раз на гонку.

const CELL := 20.0

var _cells: Dictionary = {}   # "cx_cz" -> Array[Vector2] (world XZ)
var count: int = 0


func add_poles(poles: Array) -> void:
	for p in poles:
		if not (p is Dictionary) or not p.has("x") or not p.has("z"):
			continue
		var v := Vector2(float(p["x"]), float(p["z"]))
		var k := _key(v.x, v.y)
		if not _cells.has(k):
			_cells[k] = []
		(_cells[k] as Array).append(v)
		count += 1


## Для стенда: принять список Vector3/Vector2 (world XZ) напрямую.
func add_points(points: Array) -> void:
	for p in points:
		var v: Vector2
		if p is Vector3:
			v = Vector2(p.x, p.z)
		elif p is Vector2:
			v = p
		else:
			continue
		var k := _key(v.x, v.y)
		if not _cells.has(k):
			_cells[k] = []
		(_cells[k] as Array).append(v)
		count += 1


func _key(x: float, z: float) -> String:
	return "%d_%d" % [int(floor(x / CELL)), int(floor(z / CELL))]


## Все столбы в radius (м) от мировой позиции. Возвращает Array[Vector2] (world XZ).
func query_near(world_pos: Vector3, radius: float) -> Array:
	var out: Array = []
	var here := Vector2(world_pos.x, world_pos.z)
	var cx := int(floor(world_pos.x / CELL))
	var cz := int(floor(world_pos.z / CELL))
	var r := int(ceil(radius / CELL))
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var k := "%d_%d" % [cx + dx, cz + dz]
			if _cells.has(k):
				for v in _cells[k]:
					if here.distance_to(v) <= radius:
						out.append(v)
	return out
