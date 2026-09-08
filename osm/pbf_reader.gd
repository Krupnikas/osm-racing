class_name PbfReader
extends RefCounted

# Pure-GDScript decoder for OpenStreetMap PBF files (.osm.pbf).
#
# PBF layout (fileformat.proto + osmformat.proto):
#   File   = repeat[ 4-byte BE uint32 = len(BlobHeader) | BlobHeader | Blob ]
#   BlobHeader = { 1:type(string "OSMHeader"|"OSMData"), 3:datasize(int32) }
#   Blob       = { 1:raw(bytes) | 2:raw_size(int32) + 3:zlib_data(bytes) }
#   OSMHeader payload = HeaderBlock  { 1:bbox(HeaderBBox in nanodegrees, sint64) }
#   OSMData   payload = PrimitiveBlock{ 1:stringtable, 2:primitivegroup*, 17:granularity,
#                                       19:lat_offset, 20:lon_offset }
#
# We handle uncompressed `raw` and `zlib_data` blobs. A zlib stream is
# [2-byte header][raw DEFLATE][4-byte adler32]; Godot's PackedByteArray.decompress
# with COMPRESSION_DEFLATE expects raw DEFLATE, so we strip the 2 header + 4 trailer bytes.
#
# Generic decoder: returns ALL nodes/ways/relations. Game-specific tag filtering and
# spatial slicing live in osm/local_osm_source.gd.
#
# Returned dictionary:
#   {
#     "bbox":      {min_lat, min_lon, max_lat, max_lon}  (degrees; empty if no header bbox)
#     "node_lat":  { node_id:int -> lat:float }
#     "node_lon":  { node_id:int -> lon:float }
#     "node_tags": { node_id:int -> {String:String} }   (only nodes that carry tags)
#     "ways":      [ {id:int, refs:PackedInt64Array, tags:{String:String}} ]
#     "relations": [ {id:int, members:[{type:int, ref:int, role:String}], tags:{String:String}} ]
#   }
# Member type enum: 0 = node, 1 = way, 2 = relation.


# --- Minimal protobuf cursor over a PackedByteArray slice ---
class _Reader:
	var data: PackedByteArray
	var pos: int
	var end: int

	func _init(d: PackedByteArray, start: int = 0, e: int = -1) -> void:
		data = d
		pos = start
		end = e if e >= 0 else d.size()

	func eof() -> bool:
		return pos >= end

	func varint() -> int:
		var result := 0
		var shift := 0
		while true:
			var b := data[pos]
			pos += 1
			result |= (b & 0x7f) << shift
			if (b & 0x80) == 0:
				break
			shift += 7
		return result

	# Zigzag-decoded signed varint (protobuf sint32/sint64).
	func svarint() -> int:
		var n := varint()
		return (n >> 1) ^ -(n & 1)

	# Returns Vector2i(field_number, wire_type).
	func tag() -> Vector2i:
		var t := varint()
		return Vector2i(t >> 3, t & 0x7)

	func take(n: int) -> PackedByteArray:
		var s := data.slice(pos, pos + n)
		pos += n
		return s

	func read_string(n: int) -> String:
		var s := data.slice(pos, pos + n).get_string_from_utf8()
		pos += n
		return s

	# Skips a field of the given wire type (0=varint,1=64b,2=len-delim,5=32b).
	func skip(wire: int) -> void:
		match wire:
			0: varint()
			1: pos += 8
			2: pos += varint()
			5: pos += 4
			_: push_error("PBF: unknown wire type %d" % wire)


## Cheaply reads just the OSMHeader bbox (degrees) without decoding the whole file.
## Returns {} if no header bbox is present. Used for coverage/file selection.
static func decode_header_bbox(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	# First blob is the OSMHeader; read only enough to parse it.
	var len_buf := f.get_buffer(4)
	if len_buf.size() < 4:
		return {}
	var hlen := (len_buf[0] << 24) | (len_buf[1] << 16) | (len_buf[2] << 8) | len_buf[3]
	var header_bytes := f.get_buffer(hlen)
	var blob_type := ""
	var datasize := 0
	var hr := _Reader.new(header_bytes)
	while not hr.eof():
		var t := hr.tag()
		if t.x == 1 and t.y == 2:
			blob_type = hr.read_string(hr.varint())
		elif t.x == 3 and t.y == 0:
			datasize = hr.varint()
		else:
			hr.skip(t.y)
	if blob_type != "OSMHeader" or datasize <= 0:
		return {}
	var blob := f.get_buffer(datasize)
	f.close()
	var payload := _inflate_blob(blob)
	if payload.is_empty():
		return {}
	var result := {"bbox": {}}
	_parse_header_block(payload, result)
	return result.get("bbox", {})


static func decode(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("PBF: could not read or empty file: " + path)
		return {}

	var result := {
		"bbox": {},
		"node_lat": {},
		"node_lon": {},
		"node_tags": {},
		"ways": [],
		"relations": [],
	}

	var n := bytes.size()
	var cursor := 0
	while cursor + 4 <= n:
		# 4-byte big-endian BlobHeader length
		var hlen := (bytes[cursor] << 24) | (bytes[cursor + 1] << 16) | (bytes[cursor + 2] << 8) | bytes[cursor + 3]
		cursor += 4
		if hlen <= 0 or cursor + hlen > n:
			break
		var blob_type := ""
		var datasize := 0
		var hr := _Reader.new(bytes, cursor, cursor + hlen)
		while not hr.eof():
			var t := hr.tag()
			if t.x == 1 and t.y == 2:
				blob_type = hr.read_string(hr.varint())
			elif t.x == 3 and t.y == 0:
				datasize = hr.varint()
			else:
				hr.skip(t.y)
		cursor += hlen

		if datasize <= 0 or cursor + datasize > n:
			break
		var blob := bytes.slice(cursor, cursor + datasize)
		cursor += datasize

		var payload := _inflate_blob(blob)
		if payload.is_empty():
			continue
		if blob_type == "OSMHeader":
			_parse_header_block(payload, result)
		elif blob_type == "OSMData":
			_parse_primitive_block(payload, result)

	return result


# Extracts the raw/decompressed payload bytes from a Blob message.
static func _inflate_blob(blob: PackedByteArray) -> PackedByteArray:
	var r := _Reader.new(blob)
	var raw := PackedByteArray()
	var raw_size := 0
	var zlib := PackedByteArray()
	while not r.eof():
		var t := r.tag()
		match t.x:
			1:  # raw (uncompressed)
				raw = r.take(r.varint())
			2:  # raw_size
				raw_size = r.varint()
			3:  # zlib_data
				zlib = r.take(r.varint())
			_:
				r.skip(t.y)
	if raw.size() > 0:
		return raw
	if zlib.size() > 6:
		# Godot's COMPRESSION_DEFLATE inflates the full zlib-wrapped stream (header + adler32),
		# NOT header-stripped raw deflate. decompress_dynamic handles the whole stream.
		var out := zlib.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
		if out.is_empty():
			push_error("PBF: DEFLATE decompress failed (raw_size=%d)" % raw_size)
		return out
	return PackedByteArray()


static func _parse_header_block(payload: PackedByteArray, result: Dictionary) -> void:
	var r := _Reader.new(payload)
	while not r.eof():
		var t := r.tag()
		if t.x == 1 and t.y == 2:  # bbox
			var blen := r.varint()
			var br := _Reader.new(payload, r.pos, r.pos + blen)
			r.pos += blen
			var left := 0
			var right := 0
			var top := 0
			var bottom := 0
			while not br.eof():
				var ft := br.tag()
				match ft.x:
					1: left = br.svarint()
					2: right = br.svarint()
					3: top = br.svarint()
					4: bottom = br.svarint()
					_: br.skip(ft.y)
			result["bbox"] = {
				"min_lon": left * 1e-9,
				"max_lon": right * 1e-9,
				"max_lat": top * 1e-9,
				"min_lat": bottom * 1e-9,
			}
		else:
			r.skip(t.y)


static func _parse_primitive_block(payload: PackedByteArray, result: Dictionary) -> void:
	# Two passes: field order puts primitivegroup (2) before granularity (17)/offsets (19,20),
	# but we need those to decode coordinates. First pass records the stringtable + settings
	# + group byte-ranges; second pass decodes each group.
	var r := _Reader.new(payload)
	var st_start := -1
	var st_end := -1
	var group_ranges: Array = []  # [ [start,end], ... ]
	var granularity := 100
	var lat_offset := 0
	var lon_offset := 0
	while not r.eof():
		var t := r.tag()
		match t.x:
			1:  # stringtable
				var n := r.varint()
				st_start = r.pos
				st_end = r.pos + n
				r.pos += n
			2:  # primitivegroup
				var n := r.varint()
				group_ranges.append([r.pos, r.pos + n])
				r.pos += n
			17: granularity = r.varint()
			19: lat_offset = r.varint()
			20: lon_offset = r.varint()
			_: r.skip(t.y)

	var strings := _parse_stringtable(payload, st_start, st_end)

	for gr in group_ranges:
		_parse_group(payload, gr[0], gr[1], strings, granularity, lat_offset, lon_offset, result)


static func _parse_stringtable(payload: PackedByteArray, start: int, end: int) -> PackedStringArray:
	var out := PackedStringArray()
	if start < 0:
		return out
	var r := _Reader.new(payload, start, end)
	while not r.eof():
		var t := r.tag()
		if t.x == 1 and t.y == 2:
			out.append(r.read_string(r.varint()))
		else:
			r.skip(t.y)
	return out


static func _parse_group(payload: PackedByteArray, start: int, end: int, strings: PackedStringArray, granularity: int, lat_offset: int, lon_offset: int, result: Dictionary) -> void:
	var r := _Reader.new(payload, start, end)
	while not r.eof():
		var t := r.tag()
		var n := r.varint() if t.y == 2 else 0
		match t.x:
			1:  # nodes (non-dense)
				_parse_node(payload, r.pos, r.pos + n, strings, granularity, lat_offset, lon_offset, result)
				r.pos += n
			2:  # dense
				_parse_dense(payload, r.pos, r.pos + n, strings, granularity, lat_offset, lon_offset, result)
				r.pos += n
			3:  # way
				_parse_way(payload, r.pos, r.pos + n, strings, result)
				r.pos += n
			4:  # relation
				_parse_relation(payload, r.pos, r.pos + n, strings, result)
				r.pos += n
			_:
				# already consumed length for wire 2; otherwise skip scalar
				if t.y != 2:
					r.skip(t.y)


static func _read_packed(r: _Reader, out: PackedInt64Array, zigzag: bool) -> void:
	var n := r.varint()
	var e := r.pos + n
	while r.pos < e:
		out.append(r.svarint() if zigzag else r.varint())


static func _parse_dense(payload: PackedByteArray, start: int, end: int, strings: PackedStringArray, granularity: int, lat_offset: int, lon_offset: int, result: Dictionary) -> void:
	var r := _Reader.new(payload, start, end)
	var ids := PackedInt64Array()
	var lats := PackedInt64Array()
	var lons := PackedInt64Array()
	var keys_vals := PackedInt64Array()
	while not r.eof():
		var t := r.tag()
		match t.x:
			1: _read_packed(r, ids, true)       # id (delta, sint64)
			8: _read_packed(r, lats, true)      # lat (delta, sint64)
			9: _read_packed(r, lons, true)      # lon (delta, sint64)
			10: _read_packed(r, keys_vals, false)  # key/val string indices, 0-delimited
			_: r.skip(t.y)

	var node_lat: Dictionary = result["node_lat"]
	var node_lon: Dictionary = result["node_lon"]
	var node_tags: Dictionary = result["node_tags"]
	var has_kv := keys_vals.size() > 0
	var id := 0
	var lat := 0
	var lon := 0
	var kv := 0
	var count := ids.size()
	for i in count:
		id += ids[i]
		lat += lats[i]
		lon += lons[i]
		node_lat[id] = (lat_offset + granularity * lat) * 1e-9
		node_lon[id] = (lon_offset + granularity * lon) * 1e-9
		if has_kv:
			var tags := {}
			while kv < keys_vals.size() and keys_vals[kv] != 0:
				tags[strings[keys_vals[kv]]] = strings[keys_vals[kv + 1]]
				kv += 2
			kv += 1  # skip the 0 delimiter
			if not tags.is_empty():
				node_tags[id] = tags


static func _parse_node(payload: PackedByteArray, start: int, end: int, strings: PackedStringArray, granularity: int, lat_offset: int, lon_offset: int, result: Dictionary) -> void:
	# Rare non-dense node. Fields: 1 id(sint64), 2 keys, 3 vals, 8 lat(sint64), 9 lon(sint64).
	var r := _Reader.new(payload, start, end)
	var id := 0
	var lat := 0
	var lon := 0
	var keys := PackedInt64Array()
	var vals := PackedInt64Array()
	while not r.eof():
		var t := r.tag()
		match t.x:
			1: id = r.svarint()
			2: _read_packed(r, keys, false)
			3: _read_packed(r, vals, false)
			8: lat = r.svarint()
			9: lon = r.svarint()
			_: r.skip(t.y)
	result["node_lat"][id] = (lat_offset + granularity * lat) * 1e-9
	result["node_lon"][id] = (lon_offset + granularity * lon) * 1e-9
	if keys.size() > 0:
		var tags := {}
		for i in keys.size():
			tags[strings[keys[i]]] = strings[vals[i]]
		result["node_tags"][id] = tags


static func _parse_way(payload: PackedByteArray, start: int, end: int, strings: PackedStringArray, result: Dictionary) -> void:
	var r := _Reader.new(payload, start, end)
	var id := 0
	var keys := PackedInt64Array()
	var vals := PackedInt64Array()
	var refs_delta := PackedInt64Array()
	while not r.eof():
		var t := r.tag()
		match t.x:
			1: id = r.varint()
			2: _read_packed(r, keys, false)
			3: _read_packed(r, vals, false)
			8: _read_packed(r, refs_delta, true)  # node refs, delta sint64
			_: r.skip(t.y)
	var tags := {}
	for i in keys.size():
		tags[strings[keys[i]]] = strings[vals[i]]
	var refs := PackedInt64Array()
	var acc := 0
	for i in refs_delta.size():
		acc += refs_delta[i]
		refs.append(acc)
	result["ways"].append({"id": id, "refs": refs, "tags": tags})


static func _parse_relation(payload: PackedByteArray, start: int, end: int, strings: PackedStringArray, result: Dictionary) -> void:
	var r := _Reader.new(payload, start, end)
	var id := 0
	var keys := PackedInt64Array()
	var vals := PackedInt64Array()
	var roles := PackedInt64Array()
	var memids_delta := PackedInt64Array()
	var types := PackedInt64Array()
	while not r.eof():
		var t := r.tag()
		match t.x:
			1: id = r.varint()
			2: _read_packed(r, keys, false)
			3: _read_packed(r, vals, false)
			8: _read_packed(r, roles, false)         # roles_sid (string indices)
			9: _read_packed(r, memids_delta, true)   # member ids, delta sint64
			10: _read_packed(r, types, false)        # member type enum
			_: r.skip(t.y)
	var tags := {}
	for i in keys.size():
		tags[strings[keys[i]]] = strings[vals[i]]
	var members: Array = []
	var mid := 0
	for i in memids_delta.size():
		mid += memids_delta[i]
		var role := strings[roles[i]] if i < roles.size() else ""
		members.append({"type": int(types[i]) if i < types.size() else 0, "ref": mid, "role": role})
	result["relations"].append({"id": id, "members": members, "tags": tags})
