@tool
extends RefCounted
# NOTE: no class_name — always used via load(); avoids a global-class clash.

## Reusable model-analysis stage of the new-car integration pipeline.
##
## Loads a car model (external .glb/.gltf by absolute path, OR a res:// imported
## scene) and produces a structured diagnostic used to drive scale normalization,
## orientation, wheel setup, light placement and body recolor.
##
## IMPORTANT: all bounding boxes are computed from REAL vertices
## (surface arrays), never get_aabb()/visual AABB — imported GLBs frequently
## store an inflated AABB (see memory: clutter-getaabb-gotcha). Grounding/scale
## off get_aabb() makes models float or mis-scale.
##
## Usage (editor script):
##   var A = load("res://tools/car_model_analyzer.gd")
##   var rep = A.analyze("/abs/path/model.glb", {"target_length": 4.7})
##   _mcp_print(A.format_report(rep))

# ---- model loading -------------------------------------------------------

static func load_model_root(path: String) -> Node3D:
	if path.begins_with("res://"):
		var ps = load(path)
		if ps is PackedScene:
			return ps.instantiate()
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		return null
	return doc.generate_scene(state)

static func _collect_meshes(node: Node, out: Array) -> void:
	if node is ImporterMeshInstance3D or node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_collect_meshes(c, out)

static func _xform_to_root(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t

# Returns {aabb:AABB, verts:int, mats:Array[String]}
static func _part_info(mi: Node, root: Node) -> Dictionary:
	var xf := _xform_to_root(mi, root)
	var ab := AABB()
	var first := true
	var vtot := 0
	var mats := []
	var mesh = mi.mesh
	if mesh == null:
		return {"aabb": ab, "verts": 0, "mats": mats}
	var surf: int = mesh.get_surface_count()
	for si in range(surf):
		var arr
		var mat
		if mi is ImporterMeshInstance3D:
			arr = mesh.get_surface_arrays(si)
			mat = mesh.get_surface_material(si)
		else:
			arr = mesh.surface_get_arrays(si)
			mat = mi.get_active_material(si)
		if arr == null or arr.size() <= Mesh.ARRAY_VERTEX:
			continue
		var verts = arr[Mesh.ARRAY_VERTEX]
		vtot += verts.size()
		mats.append(mat.resource_name if mat else "")
		for v in verts:
			var wv: Vector3 = xf * v
			if first:
				ab = AABB(wv, Vector3.ZERO); first = false
			else:
				ab = ab.expand(wv)
	return {"aabb": ab, "verts": vtot, "mats": mats}

# ---- classification ------------------------------------------------------

static func _classify(part_name: String, mats: Array) -> String:
	var s := part_name.to_lower()
	for m in mats:
		s += " " + String(m).to_lower()
	# wheels first (rim/tyre/disk/wheel/brake or FL/FR/RL/RR tokens)
	if _has_any(s, ["wheel", "tyre", "tire", "rim", "brakedisk", "brake_disc", "caliper"]):
		return "wheel"
	if _is_corner_token(part_name):
		return "wheel"
	if _has_any(s, ["red_glass", "redglass", "tail", "rear_light", "rearlight", "stop", "brakelight"]):
		return "light_rear"
	if _has_any(s, ["headlight", "head_light", "frontlight", "front_light", "light_r", "light_l", " lights", "lights", "lamp"]):
		return "light_front"
	if _has_any(s, ["glass", "window", "windshield", "windscreen"]):
		return "glass"
	if _has_any(s, ["chrome", "mirror"]):
		return "chrome"
	if _has_any(s, ["interior", "internal", "seat", "leather", "plate", "license"]):
		return "interior"
	if _has_any(s, ["paint", "body", "capaint", "chassis"]):
		return "body"
	return "other"

static func _has_any(s: String, keys: Array) -> bool:
	for k in keys:
		if k in s:
			return true
	return false

static func _is_corner_token(nm: String) -> bool:
	var s := nm.to_lower()
	for tok in ["fl", "fr", "rl", "rr"]:
		if s == tok or s.begins_with(tok + "_") or s.begins_with(tok + "__") or ("_" + tok + "_") in ("_" + s + "_"):
			return true
	for tok in ["front_left", "front_right", "rear_left", "rear_right", "frontleft", "frontright", "rearleft", "rearright"]:
		if tok in s:
			return true
	return false

# ---- main analysis -------------------------------------------------------

static func analyze(path: String, opts: Dictionary = {}) -> Dictionary:
	var root := load_model_root(path)
	if root == null:
		return {"ok": false, "error": "could not load " + path}
	var target_length: float = opts.get("target_length", 0.0)

	var meshes := []
	_collect_meshes(root, meshes)

	var parts := []
	var total := AABB()
	var first := true
	var total_verts := 0
	for mi in meshes:
		var info := _part_info(mi, root)
		if info.verts == 0:
			continue
		var ab: AABB = info.aabb
		var cls := _classify(String(mi.name), info.mats)
		parts.append({
			"name": String(mi.name),
			"cls": cls,
			"verts": info.verts,
			"center": ab.get_center(),
			"size": ab.size,
			"aabb": ab,
			"mats": info.mats,
		})
		total_verts += info.verts
		if first:
			total = ab; first = false
		else:
			total = total.merge(ab)

	# length axis = the larger horizontal extent
	var size := total.size
	var length_axis := "z"
	var car_length: float = size.z
	var car_width: float = size.x
	if size.x > size.z:
		length_axis = "x"
		car_length = size.x
		car_width = size.z

	# wheels
	var wheels := []
	for p in parts:
		if p.cls == "wheel":
			wheels.append(p)
	var wheel_report := _wheels_report(wheels, length_axis)

	# lights
	var lights_front := []
	var lights_rear := []
	for p in parts:
		if p.cls == "light_front":
			lights_front.append(p)
		elif p.cls == "light_rear":
			lights_rear.append(p)

	# body materials (unique)
	var body_mats := {}
	for p in parts:
		if p.cls == "body":
			for m in p.mats:
				if String(m) != "":
					body_mats[String(m)] = true

	var scale_factor := 0.0
	if target_length > 0.0 and car_length > 0.0:
		scale_factor = target_length / car_length

	var result := {
		"ok": true,
		"path": path,
		"root_name": String(root.name),
		"mesh_parts": parts.size(),
		"total_verts": total_verts,
		"aabb_size": size,
		"aabb_center": total.get_center(),
		"aabb_min": total.position,
		"aabb_max": total.position + total.size,
		"lowest_y": total.position.y,
		"length_axis": length_axis,
		"car_length": car_length,
		"car_width": car_width,
		"car_height": size.y,
		"target_length": target_length,
		"scale_factor": scale_factor,
		"scaled_length": car_length * scale_factor if scale_factor > 0 else car_length,
		"scaled_width": car_width * scale_factor if scale_factor > 0 else car_width,
		"scaled_height": size.y * scale_factor if scale_factor > 0 else size.y,
		"wheels": wheel_report,
		"lights_front": _light_summ(lights_front),
		"lights_rear": _light_summ(lights_rear),
		"body_materials": body_mats.keys(),
		"parts": parts,
	}
	root.queue_free()
	return result

static func _wheels_report(wheels: Array, length_axis: String) -> Dictionary:
	if wheels.is_empty():
		return {"count": 0, "note": "no wheel parts detected by name/material"}
	# group by quadrant: x sign (left/right), length-axis sign (front/rear)
	var groups := {"FL": [], "FR": [], "RL": [], "RR": []}
	# determine which end is "front": we cannot know yet; just label by sign.
	for w in wheels:
		var c: Vector3 = w.center
		var lr := "L" if c.x < 0.0 else "R"
		var fr: String
		if length_axis == "z":
			fr = "neg" if c.z < 0.0 else "pos"
		else:
			fr = "neg" if c.x < 0.0 else "pos"
		# map neg/pos along length to F/R placeholder (neg=A, pos=B)
		var key := ("A" if fr == "neg" else "B") + lr
		if not groups.has(key):
			groups[key] = []
		groups[key].append(w)
	var radii := []
	var centers := {}
	for w in wheels:
		radii.append(w.size.y * 0.5)
	var avg_r := 0.0
	for r in radii:
		avg_r += r
	avg_r /= max(1, radii.size())
	# compute end centers
	var ends := {}  # along-length sign -> avg center
	for w in wheels:
		var c: Vector3 = w.center
		var along: float = (c.z if length_axis == "z" else c.x)
		var endk := "neg" if along < 0.0 else "pos"
		if not ends.has(endk):
			ends[endk] = []
		ends[endk].append(c)
	var summary := {"count": wheels.size(), "avg_radius": avg_r, "min_radius": (radii.min() if radii.size() else 0.0), "max_radius": (radii.max() if radii.size() else 0.0)}
	var per := []
	for w in wheels:
		per.append({"name": w.name, "center": w.center, "radius_y": w.size.y * 0.5, "size": w.size})
	summary["per_wheel"] = per
	# wheelbase/track estimate
	var xs := []
	var ls := []
	for w in wheels:
		xs.append(w.center.x)
		ls.append(w.center.z if length_axis == "z" else w.center.x)
	if xs.size() >= 2:
		summary["track"] = absf(xs.max() - xs.min())
	if ls.size() >= 2:
		summary["wheelbase"] = absf(ls.max() - ls.min())
	return summary

static func _light_summ(arr: Array) -> Array:
	var out := []
	for p in arr:
		out.append({"name": p.name, "center": p.center, "size": p.size, "mats": p.mats})
	return out

# ---- pretty printer ------------------------------------------------------

static func format_report(d: Dictionary) -> String:
	if not d.get("ok", false):
		return "ANALYZE FAILED: " + str(d.get("error", "?"))
	var L := []
	L.append("=== CAR MODEL ANALYSIS ===")
	L.append("path: " + d.path)
	L.append("root: %s   parts=%d  verts=%d" % [d.root_name, d.mesh_parts, d.total_verts])
	L.append("AABB size=(%.3f, %.3f, %.3f)  center=(%.3f, %.3f, %.3f)" % [d.aabb_size.x, d.aabb_size.y, d.aabb_size.z, d.aabb_center.x, d.aabb_center.y, d.aabb_center.z])
	L.append("lowest_y=%.3f   length_axis=%s  L=%.3f W=%.3f H=%.3f" % [d.lowest_y, d.length_axis, d.car_length, d.car_width, d.car_height])
	if d.target_length > 0:
		L.append("target_length=%.2f -> scale_factor=%.4f  =>  scaled L=%.2f W=%.2f H=%.2f" % [d.target_length, d.scale_factor, d.scaled_length, d.scaled_width, d.scaled_height])
	var w = d.wheels
	L.append("-- WHEELS: count=%d  avg_r=%.3f (min %.3f max %.3f)  track=%s wheelbase=%s" % [w.get("count",0), w.get("avg_radius",0.0), w.get("min_radius",0.0), w.get("max_radius",0.0), str(w.get("track","?")), str(w.get("wheelbase","?"))])
	for pw in w.get("per_wheel", []):
		L.append("   %s  center=(%.3f,%.3f,%.3f) r=%.3f" % [pw.name, pw.center.x, pw.center.y, pw.center.z, pw.radius_y])
	L.append("-- LIGHTS FRONT: %d" % d.lights_front.size())
	for lf in d.lights_front:
		L.append("   %s center=(%.3f,%.3f,%.3f) mats=%s" % [lf.name, lf.center.x, lf.center.y, lf.center.z, str(lf.mats)])
	L.append("-- LIGHTS REAR: %d" % d.lights_rear.size())
	for lr in d.lights_rear:
		L.append("   %s center=(%.3f,%.3f,%.3f) mats=%s" % [lr.name, lr.center.x, lr.center.y, lr.center.z, str(lr.mats)])
	L.append("-- BODY MATERIALS: " + str(d.body_materials))
	L.append("-- ALL PARTS (name | class | verts | center | size | mats):")
	for p in d.parts:
		L.append("   %-42s %-11s v=%-6d c=(%.2f,%.2f,%.2f) s=(%.2f,%.2f,%.2f) %s" % [p.name, p.cls, p.verts, p.center.x, p.center.y, p.center.z, p.size.x, p.size.y, p.size.z, str(p.mats)])
	return "\n".join(L)
