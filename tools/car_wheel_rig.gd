@tool
extends RefCounted
# NOTE: no class_name — this is always used via preload()/load(); a global class
# would clash with the `const CarWheelRig := preload(...)` in the setup scripts.

## Reusable wheel-rig stage of the new-car pipeline.
##
## Many car GLBs (Sketchfab "F_M_*_High" exports) group geometry by MATERIAL, so
## all four wheels live in a single merged "Tire"/"Rim" mesh. That cannot be
## reparented onto four spinning suspension nodes, and rotating the whole merged
## mesh makes wheels orbit the car centre instead of spinning in place.
##
## build() finds the wheel-component meshes, splits them into four XZ quadrants,
## RECENTRES each quadrant's geometry onto its own wheel centre, and emits four
## container Node3Ds (named wheel_FL/FR/RL/RR) placed at the wheel centres in the
## model's local frame. The original merged meshes are hidden.
##
## Each container's child MeshInstance3Ds are centred on the container origin, so
## rotating the container (or its children) about local X spins the wheel in place
## — works for the GEVP reparent-onto-wheel_node path (player) and for npc_car.gd's
## _update_wheel_rotation (NPC).
##
## Models that already ship four separate wheel nodes don't need this (reparent the
## existing nodes, Matiz-style); build() is for the merged-mesh case.

const DEFAULT_NAME_KEYS := ["tire", "tyre", "rim", "wheel", "brakedisc", "brake_disc", "caliper"]
const DEFAULT_MAT_KEYS := ["tire", "tyre", "rim", "wheel", "brakr", "brake", "caliper", "disk", "disc"]
# Body parts whose name/material contains a wheel-key SUBSTRING but are NOT wheels:
# "trim"→"rim", "steeringwheel"→"wheel", "windscreen"→... . A stray panel reparented
# onto a spinning wheel node spins a big slab instead of the wheel (Subaru rear bumper
# carbon "trim", interior steering wheel). Reject these even if a wheel key matched.
const DEFAULT_EXCLUDE_KEYS := [
	"trim", "steering", "spoiler", "bumper", "fender", "skirt", "mirror",
	"door", "hood", "bonnet", "exhaust", "grille", "grill", "boot", "trunk",
	"windscreen", "windshield",
]

# Returns:
# { ok:bool, radius:float, center_y:float, centers:{FL:Vector3,...},
#   containers:{FL:Node3D,...}, source_meshes:int, note:String }
# All vectors are in model_root LOCAL space (multiply by the model node scale for
# scene-space). Containers are added as children of model_root.
static func build(model_root: Node3D, name_keys: Array = DEFAULT_NAME_KEYS, mat_keys: Array = DEFAULT_MAT_KEYS, extra_mat_keys: Array = []) -> Dictionary:
	var all_mat_keys := mat_keys.duplicate()
	for k in extra_mat_keys:
		all_mat_keys.append(k)
	var sources: Array = []
	_collect_wheel_meshes(model_root, name_keys, all_mat_keys, sources)
	if sources.is_empty():
		return {"ok": false, "note": "no wheel meshes found", "containers": {}}

	# ---- lateral stray filter -------------------------------------------------
	# Messy models name body parts with wheel-key SUBSTRINGS ("CarPaint_Trim" → "rim",
	# "SteeringWheel" → "wheel"), so _collect_wheel_meshes grabs steering wheels, bumpers,
	# diffusers, exhausts, etc. Two model styles:
	#  * MERGED wheels (one mesh per type spanning BOTH sides) → every candidate is centred
	#    on x≈0, so max|x| is small vs the track width — leave untouched.
	#  * SEPARATE corner wheels → the real wheels sit at the track edges (|x|≈track/2) while
	#    strays cluster on the lateral centreline (x≈0). Only here, drop centreline candidates.
	if sources.size() >= 4:
		var caabb: Array = []
		var trackw := AABB()
		var firstt := true
		for s in sources:
			var ab: AABB = _mesh_aabb_local(s, model_root)
			caabb.append(ab)
			if firstt:
				trackw = ab; firstt = false
			else:
				trackw = trackw.merge(ab)
		var track_x: float = trackw.size.x
		var max_abs_x := 0.0
		for ab in caabb:
			max_abs_x = max(max_abs_x, absf(ab.get_center().x))
		# separate-wheel model only when the outermost candidate is well off-centre
		if track_x > 0.0 and max_abs_x > 0.30 * track_x:
			var thr := 0.45 * max_abs_x
			var kept: Array = []
			for i in range(sources.size()):
				if absf((caabb[i] as AABB).get_center().x) >= thr or (caabb[i] as AABB).size.x >= 0.5 * track_x:  # keep corner wheels AND track-spanning merged wheel meshes (all-4-tires-as-one → else they hula-hoop); drop only small centreline strays
					kept.append(sources[i])
			if kept.size() >= 2:
				sources = kept

	# ---- PASS 1: classify triangles into quadrants, compute wheel centres ----
	# Determine the XZ split origin from the combined wheel bounds (robust if the
	# model origin isn't exactly at car centre).
	var wb := AABB()
	var firstb := true
	for s in sources:
		var ab: AABB = _mesh_aabb_local(s, model_root)
		if firstb:
			wb = ab; firstb = false
		else:
			wb = wb.merge(ab)
	var split := wb.get_center()  # x,z used as quadrant split

	var quad_pts := {"FL": [], "FR": [], "RL": [], "RR": []}
	for s in sources:
		var mi: MeshInstance3D = s
		var xf := _xform_local(mi, model_root)
		for si in range(mi.mesh.get_surface_count()):
			var arr = mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var indices = arr[Mesh.ARRAY_INDEX]
			var n_tris: int = (indices.size() / 3) if (indices != null and indices.size() > 0) else (verts.size() / 3)
			for t in range(n_tris):
				var i0; var i1; var i2
				if indices != null and indices.size() > 0:
					i0 = indices[t * 3]; i1 = indices[t * 3 + 1]; i2 = indices[t * 3 + 2]
				else:
					i0 = t * 3; i1 = t * 3 + 1; i2 = t * 3 + 2
				var w0: Vector3 = xf * verts[i0]
				var w1: Vector3 = xf * verts[i1]
				var w2: Vector3 = xf * verts[i2]
				var q := _quadrant((w0 + w1 + w2) / 3.0, split)
				quad_pts[q].append(w0); quad_pts[q].append(w1); quad_pts[q].append(w2)

	var centers := {}
	var radius_acc := 0.0
	var rad_n := 0
	var ylo := 1e9
	var yhi := -1e9
	for q in ["FL", "FR", "RL", "RR"]:
		var pts: Array = quad_pts[q]
		if pts.is_empty():
			centers[q] = Vector3.ZERO
			continue
		var ab := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			ab = ab.expand(p)
		centers[q] = ab.get_center()
		radius_acc += ab.size.y * 0.5
		rad_n += 1
		ylo = min(ylo, ab.position.y)
		yhi = max(yhi, ab.position.y + ab.size.y)

	# ---- PASS 2: rebuild per-quadrant meshes with vertices recentred on the
	# wheel centre, so a child mesh spins in place under rotate_x. ----
	var quads := {"FL": {}, "FR": {}, "RL": {}, "RR": {}}  # quad -> {matkey: SurfaceTool}
	var quad_tan := {"FL": {}, "FR": {}, "RL": {}, "RR": {}}  # quad -> {matkey: bool can_tangent}
	var qmat := {}
	for s in sources:
		var mi: MeshInstance3D = s
		var xf := _xform_local(mi, model_root)
		for si in range(mi.mesh.get_surface_count()):
			var arr = mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var normals = arr[Mesh.ARRAY_NORMAL]
			var uvs = arr[Mesh.ARRAY_TEX_UV]
			var indices = arr[Mesh.ARRAY_INDEX]
			var has_n: bool = normals != null and normals.size() == verts.size()
			var has_uv: bool = uvs != null and uvs.size() == verts.size()
			var matkey := str(mi.name) + "#" + str(si)
			qmat[matkey] = mi.get_active_material(si)
			var nbasis := xf.basis
			var n_tris: int = (indices.size() / 3) if (indices != null and indices.size() > 0) else (verts.size() / 3)
			for t in range(n_tris):
				var ii := []
				if indices != null and indices.size() > 0:
					ii = [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]]
				else:
					ii = [t * 3, t * 3 + 1, t * 3 + 2]
				var w := [xf * verts[ii[0]], xf * verts[ii[1]], xf * verts[ii[2]]]
				var q := _quadrant((w[0] + w[1] + w[2]) / 3.0, split)
				var ctr: Vector3 = centers[q]
				if not quads[q].has(matkey):
					var stx := SurfaceTool.new()
					stx.begin(Mesh.PRIMITIVE_TRIANGLES)
					quads[q][matkey] = stx
					quad_tan[q][matkey] = has_n and has_uv
				var st: SurfaceTool = quads[q][matkey]
				for k in range(3):
					if has_n:
						st.set_normal((nbasis * normals[ii[k]]).normalized())
					if has_uv:
						st.set_uv(uvs[ii[k]])
					st.add_vertex(w[k] - ctr)  # recentred on wheel centre

	var containers := {}
	for q in ["FL", "FR", "RL", "RR"]:
		var cont := Node3D.new()
		cont.name = "wheel_" + q
		cont.transform.origin = centers[q]
		model_root.add_child(cont)
		var ci := 0
		for matkey in quads[q].keys():
			var st: SurfaceTool = quads[q][matkey]
			if quad_tan[q].get(matkey, false):
				st.generate_tangents()
			var amesh: ArrayMesh = st.commit()
			var mi2 := MeshInstance3D.new()
			mi2.mesh = amesh
			# UNIQUE name per piece (disk + tire) so npc_car collects + spins ALL of them, not just the
			# first — duplicate names get auto-renamed to "@MeshInstance3D@N" and skipped → static disks.
			mi2.name = "wheelmesh_%s_%d" % [q, ci]
			ci += 1
			var mat: Material = qmat.get(matkey, null)
			if mat:
				mi2.set_surface_override_material(0, mat)
			mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			cont.add_child(mi2)
		containers[q] = cont

	# Hide originals
	for s in sources:
		s.visible = false

	var radius := (radius_acc / rad_n) if rad_n > 0 else 0.0
	return {
		"ok": true,
		"radius": radius,
		"center_y": (ylo + yhi) * 0.5 if rad_n > 0 else 0.0,
		"y_low": ylo,
		"centers": centers,
		"containers": containers,
		"source_meshes": sources.size(),
		"note": "ok",
	}

static func _quadrant(c: Vector3, split: Vector3) -> String:
	# Convention: front = +Z (caller rotates the model for the physics frame).
	var fb := "F" if c.z > split.z else "R"
	var lr := "L" if c.x < split.x else "R"
	return fb + lr

static func _collect_wheel_meshes(node: Node, name_keys: Array, mat_keys: Array, out: Array) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var nm := str(mi.name).to_lower()
		var hit := false
		for k in name_keys:
			if k in nm:
				hit = true; break
		if not hit and mi.mesh:
			for si in range(mi.mesh.get_surface_count()):
				var mat := mi.get_active_material(si)
				var mn := (mat.resource_name if mat else "").to_lower()
				for k in mat_keys:
					if k in mn:
						hit = true; break
				if hit: break
		if hit:
			# Reject body parts that merely contain a wheel-key substring.
			for ex in DEFAULT_EXCLUDE_KEYS:
				if ex in nm:
					hit = false; break
		if hit:
			out.append(mi)
	for c in node.get_children():
		_collect_wheel_meshes(c, name_keys, mat_keys, out)

static func _xform_local(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t

static func _mesh_aabb_local(mi: MeshInstance3D, root: Node) -> AABB:
	var xf := _xform_local(mi, root)
	var ab := AABB()
	var first := true
	var mesh: Mesh = mi.mesh
	for si in range(mesh.get_surface_count()):
		var arr = mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v in verts:
			var wv: Vector3 = xf * v
			if first:
				ab = AABB(wv, Vector3.ZERO); first = false
			else:
				ab = ab.expand(wv)
	return ab
