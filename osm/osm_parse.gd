class_name OSMParse
extends RefCounted

# Shared OSM element → game-data transformation.
#
# Single source of truth for turning an Overpass-shaped `elements` array into the
# parsed dictionary consumed by osm_terrain_generator. Used by BOTH:
#   - OSMLoader  (network/Overpass path) — see osm/osm_loader.gd
#   - LocalOSMSource / LocalOSMLoader (offline .osm.pbf path)
# so both paths produce byte-identical output (cache v11 shape, incl. landmarks).
#
# `elements` entries follow the Overpass `out body geom` convention:
#   node:     {type:"node", id, lat, lon, tags}
#   way:      {type:"way",  id, nodes:[node_id...], tags}   (nodes resolved via node table)
#   relation: {type:"relation", id, members:[{type,ref,role,geometry:[{lat,lon}]}], tags}
# For ways, either `nodes` (ids resolvable against the node map built here) or an inline
# `geometry:[{lat,lon}]` may be supplied; LocalOSMSource supplies resolved node ids.


## Transforms an Overpass-style `elements` array into the parsed game-data dict.
## Mirrors the previous OSMLoader._parse_osm_data() exactly.
static func parse_elements(elements: Array, center_lat: float, center_lon: float) -> Dictionary:
	var nodes := {}
	var ways := []
	var way_by_id := {}  # Для связи relation -> way
	var point_objects := []  # Точечные объекты (деревья, знаки, фонари)
	var entrance_nodes := []  # Входы в здания
	var poi_nodes := []  # Точечные заведения (shop, amenity как node)
	var bus_stops := []  # Автобусные остановки
	var tram_stops := []  # Трамвайные остановки
	var pedestrian_areas := []  # Пешеходные площади (relation highway=pedestrian area=yes)
	var bridge_decks := []  # Bridge deck outlines (relation man_made=bridge type=multipolygon)
	var traffic_signals := []  # Светофоры (node highway=traffic_signals) — с сохранением node id для дедупликации
	var give_way_nodes := []  # Знаки «уступи дорогу» (node highway=give_way) — node id сохраняется (Wave 1C)
	var landmarks := []  # Кастомные лэндмарки (OSMLandmarks): footprint+rel_id; процедурная геометрия подавлена
	var landmark_member_way_ids := {}  # way_id → true: member ways лэндмарк-relations, удаляются из ways

	# Собираем все узлы
	for element in elements:
		if element.get("type") == "node":
			nodes[element.id] = {
				"lat": element.lat,
				"lon": element.lon
			}
			# Проверяем есть ли теги - это точечный объект
			var tags: Dictionary = element.get("tags", {})
			if not tags.is_empty():
				# Отдельно сохраняем entrance nodes
				if tags.has("entrance"):
					entrance_nodes.append({
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Точечные заведения (shop или amenity с названием)
				if (tags.has("shop") or tags.has("amenity")) and (tags.has("name") or tags.has("brand")):
					poi_nodes.append({
						"id": element.id,
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Автобусные остановки (highway=bus_stop, amenity=bus_station, public_transport=platform/station)
				var is_bus_stop: bool = tags.get("highway", "") == "bus_stop"
				var is_bus_station: bool = tags.get("amenity", "") == "bus_station"
				var pt_value: String = tags.get("public_transport", "")
				var is_platform: bool = pt_value == "platform" or pt_value == "station"
				if is_bus_stop or is_bus_station or is_platform:
					bus_stops.append({
						"id": element.id,  # node id → stable bus-stop sign dedup
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Трамвайные остановки
				if tags.get("railway", "") == "tram_stop":
					tram_stops.append({
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

				# Светофоры: отдельный массив с node id (единственный источник для расстановки светофоров).
				# НЕ добавляем в generic point_objects, чтобы их не создал какой-либо точечный пайплайн.
				if tags.get("highway", "") == "traffic_signals":
					traffic_signals.append({
						"id": element.id,
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})
				elif tags.get("highway", "") == "give_way":
					# Give-way: dedicated array w/ node id (Wave 1C). Excluded from generic
					# point_objects so no other pipeline spawns it.
					give_way_nodes.append({
						"id": element.id,
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})
				else:
					point_objects.append({
						"id": element.id,  # preserve node id (traffic_sign et al.) — future dedup, cheap
						"lat": element.lat,
						"lon": element.lon,
						"tags": tags
					})

	# Собираем все пути (и сохраняем по id для relation)
	for element in elements:
		if element.get("type") == "way":
			var way_nodes := []
			for node_id in element.get("nodes", []):
				if nodes.has(node_id):
					way_nodes.append(nodes[node_id])

			if way_nodes.size() > 1:
				var tags_d: Dictionary = element.get("tags", {})
				# A closed way tagged man_made=bridge is a single-polygon
				# bridge deck outline (no relation needed). Route it to
				# bridge_decks so the deck mesh builder picks it up.
				if tags_d.get("man_made", "") == "bridge" and way_nodes.size() > 2:
					bridge_decks.append({
						"nodes": way_nodes,
						"tags": tags_d,
						"relation_id": element.get("id", 0),
					})
					way_by_id[element.id] = way_nodes
					continue
				var way_data := {
					"id": element.id,
					"nodes": way_nodes,
					"tags": tags_d
				}
				if tags_d.get("railway", "") == "tram":
					print("[TRAM] Loaded tram way %d with %d nodes, tags=%s" % [element.id, way_nodes.size(), str(tags_d)])
				ways.append(way_data)
				way_by_id[element.id] = way_nodes

	# Обрабатываем relation (multipolygon для крупных зданий)
	# С out geom геометрия включена напрямую в members
	var relations_found := 0
	var relations_with_nodes := 0
	var relation_member_way_ids: Dictionary = {}  # way_id → true (member ways of building relations)
	for element in elements:
		if element.get("type") == "relation":
			relations_found += 1
			var tags: Dictionary = element.get("tags", {})
			# Custom landmark override (detected by RELATION id, not name): capture the outer
			# footprint for footprint-aligned GLB placement and suppress ALL procedural geometry
			# (rings + every member way) so no walls/roof/footprint/duplicate polygons remain.
			var rel_id_int: int = int(element.get("id", 0))
			if OSMLandmarks.has_relation(rel_id_int):
				var lm_footprint: Array = []
				for member in element.get("members", []):
					if member.get("type") == "way":
						var mref: int = int(member.get("ref", 0))
						if mref > 0:
							landmark_member_way_ids[mref] = true
						if member.get("role", "outer") == "outer":
							for point in member.get("geometry", []):
								lm_footprint.append({
									"lat": point.get("lat", 0.0),
									"lon": point.get("lon", 0.0)
								})
				# Optional fit-way footprint (e.g. the pedestrian ring the stadium is inscribed in).
				# It is NOT a relation member → it is NOT suppressed; we only read its geometry.
				var lm_fit_footprint: Array = []
				var fit_way_id: int = int(OSMLandmarks.get_config(rel_id_int).get("fit_way_id", 0))
				if fit_way_id > 0 and way_by_id.has(fit_way_id):
					for nd in way_by_id[fit_way_id]:
						lm_fit_footprint.append({
							"lat": nd.get("lat", 0.0),
							"lon": nd.get("lon", 0.0)
						})
				landmarks.append({
					"rel_id": rel_id_int,
					"footprint": lm_footprint,
					"fit_footprint": lm_fit_footprint,
					"tags": tags
				})
				print("OSM: Custom landmark relation %d ('%s') — %d footprint pts, %d fit-way pts, %d member ways suppressed" % [rel_id_int, tags.get("name", "?"), lm_footprint.size(), lm_fit_footprint.size(), landmark_member_way_ids.size()])
				continue  # do NOT generate any procedural geometry for this relation
			# Multipolygon: outer members are individual ways (often open lines) that need to
			# be JOINED head-to-tail into closed rings. Concatenating them naively or treating
			# each as a polygon both produce broken geometry for relations like the Rybinsk
			# Reservoir water (637 members forming many separate rings).
			var is_building_relation: bool = tags.has("building") or tags.has("amenity")
			var outer_member_ways: Array = []  # Array[ {nodes: Array, way_ref: int} ]
			for member in element.get("members", []):
				if member.get("type") == "way" and member.get("role", "outer") == "outer":
					var ref_id: int = member.get("ref", 0)
					# Запоминаем member way IDs чтобы не дублировать building из relation
					if is_building_relation and ref_id > 0:
						relation_member_way_ids[ref_id] = true
					var member_nodes: Array = []
					var geometry: Array = member.get("geometry", [])
					if geometry.size() > 0:
						for point in geometry:
							member_nodes.append({
								"lat": point.get("lat", 0.0),
								"lon": point.get("lon", 0.0)
							})
					elif way_by_id.has(ref_id):
						for node in way_by_id[ref_id]:
							member_nodes.append(node)
					if member_nodes.size() >= 2:
						outer_member_ways.append({"nodes": member_nodes, "way_ref": ref_id})

			# Join member ways into closed rings (each ring is a separate polygon)
			var outer_rings: Array = _join_relation_rings(outer_member_ways)

			if not outer_rings.is_empty():
				relations_with_nodes += 1
				if tags.get("man_made", "") == "bridge":
					# Bridge deck outlines go to a separate array.
					# Each ring is a closed polygon of the bridge platform area.
					for ring in outer_rings:
						if ring.nodes.size() > 2:
							bridge_decks.append({
								"nodes": ring.nodes,
								"tags": tags,
								"relation_id": element.get("id", 0)
							})
				elif tags.get("highway", "") == "pedestrian" and tags.get("area", "") == "yes":
					# Pedestrian areas go to separate array (not mixed with roads).
					for ring in outer_rings:
						if ring.nodes.size() > 2:
							pedestrian_areas.append(ring.nodes)
				else:
					for ring in outer_rings:
						if ring.nodes.size() > 2:
							ways.append({
								"id": ring.way_ref,
								"nodes": ring.nodes,
								"tags": tags
							})

	# Убираем building/amenity теги у ways которые являются members building-relations
	# (relation уже добавлен как целый building, individual way не нужен)
	if not relation_member_way_ids.is_empty():
		var deduped := 0
		for way_data in ways:
			var wid: int = int(way_data.get("id", 0))
			if wid > 0 and relation_member_way_ids.has(wid):
				var wtags: Dictionary = way_data.get("tags", {})
				if wtags.has("building") or wtags.has("amenity"):
					wtags.erase("building")
					wtags.erase("amenity")
					deduped += 1
		if deduped > 0:
			print("OSM: Deduped %d ways that are members of building/amenity relations" % deduped)

	# Fully remove member ways of custom-landmark relations so no procedural geometry
	# (including any standalone member-way building) survives — the GLB replaces them.
	if not landmark_member_way_ids.is_empty():
		var kept: Array = []
		for way_data in ways:
			if not landmark_member_way_ids.has(int(way_data.get("id", 0))):
				kept.append(way_data)
		var removed: int = ways.size() - kept.size()
		ways = kept
		if removed > 0:
			print("OSM: Removed %d member ways for %d custom landmark(s)" % [removed, landmarks.size()])

	if relations_found > 0:
		print("OSM: Found %d relations, %d with valid geometry" % [relations_found, relations_with_nodes])

	print("OSM: Parsed %d nodes, %d ways, %d point objects, %d entrances, %d POI nodes, %d bus stops, %d tram stops, %d pedestrian areas, %d bridge decks, %d traffic signals, %d give-way" % [nodes.size(), ways.size(), point_objects.size(), entrance_nodes.size(), poi_nodes.size(), bus_stops.size(), tram_stops.size(), pedestrian_areas.size(), bridge_decks.size(), traffic_signals.size(), give_way_nodes.size()])

	return {
		"center_lat": center_lat,
		"center_lon": center_lon,
		"nodes": nodes,
		"ways": ways,
		"point_objects": point_objects,
		"entrance_nodes": entrance_nodes,
		"poi_nodes": poi_nodes,
		"bus_stops": bus_stops,
		"tram_stops": tram_stops,
		"pedestrian_areas": pedestrian_areas,
		"bridge_decks": bridge_decks,
		"traffic_signals": traffic_signals,
		"give_way_nodes": give_way_nodes,
		"landmarks": landmarks,
	}


## Joins relation outer member ways head-to-tail into closed rings.
## Each member is an open polyline; consecutive members chain via shared endpoints.
## Returns Array of {nodes: Array, way_ref: int}, each entry being one closed (or auto-closed) ring.
static func _join_relation_rings(member_ways: Array) -> Array:
	var rings: Array = []
	var pending: Array = member_ways.duplicate()
	while not pending.is_empty():
		var current: Dictionary = pending.pop_front()
		var ring_nodes: Array = (current["nodes"] as Array).duplicate()
		var ring_way_ref: int = int(current.get("way_ref", 0))
		while true:
			if ring_nodes.size() < 2:
				break
			var first: Dictionary = ring_nodes[0]
			var last: Dictionary = ring_nodes[ring_nodes.size() - 1]
			if _nodes_equal(first, last):
				break  # closed
			var found_idx: int = -1
			var found_reverse: bool = false
			for i in range(pending.size()):
				var w_dict: Dictionary = pending[i]
				var w_nodes: Array = w_dict["nodes"]
				if w_nodes.is_empty():
					continue
				var w_first: Dictionary = w_nodes[0]
				var w_last: Dictionary = w_nodes[w_nodes.size() - 1]
				if _nodes_equal(w_first, last):
					found_idx = i
					found_reverse = false
					break
				if _nodes_equal(w_last, last):
					found_idx = i
					found_reverse = true
					break
			if found_idx < 0:
				break  # no more chainable members
			var next_member: Dictionary = pending[found_idx]
			pending.remove_at(found_idx)
			var next_nodes: Array = (next_member["nodes"] as Array).duplicate()
			if found_reverse:
				next_nodes.reverse()
			# skip first node (duplicate of our last)
			for j in range(1, next_nodes.size()):
				ring_nodes.append(next_nodes[j])
		# Auto-close ring if not naturally closed (data clipped at bbox)
		if ring_nodes.size() >= 3:
			var first2: Dictionary = ring_nodes[0]
			var last2: Dictionary = ring_nodes[ring_nodes.size() - 1]
			if not _nodes_equal(first2, last2):
				ring_nodes.append(first2)
		rings.append({"nodes": ring_nodes, "way_ref": ring_way_ref})
	return rings


static func _nodes_equal(a: Dictionary, b: Dictionary) -> bool:
	# Tolerance ~0.01m at this latitude
	return absf(float(a["lat"]) - float(b["lat"])) < 1e-7 and absf(float(a["lon"]) - float(b["lon"])) < 1e-7
