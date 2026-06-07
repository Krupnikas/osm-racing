@tool
extends RefCounted
# NOTE: no class_name — always used via preload(), like CarWheelRig.

## Shared lamp-lens emissive helper for the new-car pipeline (player + NPC).
##
## Makes a car's REAL lamp-lens meshes emissive (front = warm white, rear = red) so the glow
## matches the lens shape and sits in the body — NEVER rectangular proxy boxes (see
## docs/CAR_INTEGRATION_PIPELINE.md §5b/§5c). Two identification modes:
##   • by_name : match each surface's material name (or the MeshInstance node name) against
##               front_keys / rear_keys substrings (lowercased).
##   • zsplit  : one shared lamp material used at both ends → split per-surface by the surface's
##               model-local centroid z (native front = +Z → white, rear → red).
##
## For NPCs, pass flag_unmerged=true: each matched lens mesh gets set_meta("npc_keep_unmerged")
## so traffic/npc_car.gd._merge_meshes() leaves it visible (otherwise the merge hides it and the
## glow never renders). Call BEFORE the NPC setup's `await` so it runs before the merge, and set
## the NPC root's "real_lens_lights" meta so npc_car_lights.gd skips its proxy boxes.
##
## Returns { head:[StandardMaterial3D...], tail:[StandardMaterial3D...] } — the caller toggles
## emission_energy_multiplier with night (front 0→~1.3, rear 0→~1.8, or rear baseline on player).

const FRONT_COLOR := Color(1.0, 0.96, 0.85)
const REAR_COLOR := Color(1.0, 0.05, 0.05)


static func _all_meshes(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_all_meshes(c, out)


static func _xform_to_root(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


static func _name_matches(s: String, keys: Array) -> bool:
	for k in keys:
		if k != "" and k in s:
			return true
	return false


# Apply a per-surface emissive override; record it in `bucket`; optionally flag the mesh.
static func _emit(mesh: MeshInstance3D, i: int, src: Material, color: Color, energy: float, bucket: Array, flag_unmerged: bool) -> void:
	var mat: Material = mesh.get_surface_override_material(i)
	if not mat:
		mat = src.duplicate()
		mesh.set_surface_override_material(i, mat)
	if not (mat is StandardMaterial3D):
		return
	mat.emission_enabled = true
	# Clear any emission texture — otherwise the glow is the TEXTURE tinted by our colour
	# (e.g. RX-8 "Light_C" has a green-ish emission map that turned the headlights green).
	mat.emission_texture = null
	mat.emission = color
	mat.emission_energy_multiplier = energy
	# Some models ship the lamp lens as a normally-hidden LOD mesh; un-hide it so it glows.
	mesh.visible = true
	bucket.append(mat)
	if flag_unmerged:
		mesh.set_meta("npc_keep_unmerged", true)


# front_keys / rear_keys: substrings matched against material name (and node name if match_mesh_name).
static func apply_by_name(root: Node3D, front_keys: Array, rear_keys: Array, front_energy := 0.0, rear_energy := 0.7, match_mesh_name := false, flag_unmerged := false) -> Dictionary:
	var out := {"head": [], "tail": []}
	var meshes: Array = []
	_all_meshes(root, meshes)
	for mesh in meshes:
		if mesh.mesh == null:
			continue
		var node_name: String = String(mesh.name).to_lower()
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			var mn := (src.resource_name.to_lower() if src else "")
			var is_front := _name_matches(mn, front_keys) or (match_mesh_name and _name_matches(node_name, front_keys))
			var is_rear := _name_matches(mn, rear_keys) or (match_mesh_name and _name_matches(node_name, rear_keys))
			if is_rear:
				_emit(mesh, i, src, REAR_COLOR, rear_energy, out["tail"], flag_unmerged)
			elif is_front:
				_emit(mesh, i, src, FRONT_COLOR, front_energy, out["head"], flag_unmerged)
	return out


# For a SINGLE lens mesh that SPANS both ends (one surface, centroid ≈ 0 so per-surface
# z-split fails — e.g. Evo "lightglass"): split its TRIANGLES by model-space centroid z into a
# front (white) and rear (red) sub-mesh, add them as siblings, and hide the original. Returns
# {head:[mat], tail:[mat]}. flag_unmerged marks the new sub-meshes so the NPC merge keeps them.
static func split_lens_mesh(root: Node3D, lens_keys: Array, front_energy := 0.0, rear_energy := 0.7, native_front_z_positive := true, flag_unmerged := false) -> Dictionary:
	var out := {"head": [], "tail": []}
	var meshes: Array = []
	_all_meshes(root, meshes)
	for mesh in meshes:
		if mesh.mesh == null:
			continue
		var did_split := false
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			var mn := (src.resource_name.to_lower() if src else "")
			if not _name_matches(mn, lens_keys):
				continue
			var t := _xform_to_root(mesh, root)
			var arr = mesh.mesh.surface_get_arrays(i)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if verts.size() == 0:
				continue
			var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var has_idx := idx.size() > 0
			var tri_count := (idx.size() / 3) if has_idx else (verts.size() / 3)
			var st_f := SurfaceTool.new(); st_f.begin(Mesh.PRIMITIVE_TRIANGLES)
			var st_r := SurfaceTool.new(); st_r.begin(Mesh.PRIMITIVE_TRIANGLES)
			var nf := 0; var nr := 0
			for tri in range(tri_count):
				var a: int = idx[tri * 3] if has_idx else tri * 3
				var b: int = idx[tri * 3 + 1] if has_idx else tri * 3 + 1
				var c: int = idx[tri * 3 + 2] if has_idx else tri * 3 + 2
				var cz := ((t * verts[a]).z + (t * verts[b]).z + (t * verts[c]).z) / 3.0
				var is_front := (cz >= 0.0) if native_front_z_positive else (cz < 0.0)
				var st := st_f if is_front else st_r
				for vi in [a, b, c]:
					if norms.size() > vi:
						st.set_normal(norms[vi])
					st.add_vertex(verts[vi])
				if is_front: nf += 1
				else: nr += 1
			var parent: Node = mesh.get_parent()
			if nf > 0:
				var fmat := StandardMaterial3D.new()
				fmat.albedo_color = Color(0.75, 0.75, 0.72)
				fmat.emission_enabled = true; fmat.emission = FRONT_COLOR; fmat.emission_energy_multiplier = front_energy
				var fi := MeshInstance3D.new(); fi.name = "LensFront"; fi.mesh = st_f.commit(); fi.transform = mesh.transform
				fi.material_override = fmat
				parent.add_child(fi)
				if flag_unmerged: fi.set_meta("npc_keep_unmerged", true)
				out["head"].append(fmat)
			if nr > 0:
				var rmat := StandardMaterial3D.new()
				rmat.albedo_color = Color(0.4, 0.05, 0.05)
				rmat.emission_enabled = true; rmat.emission = REAR_COLOR; rmat.emission_energy_multiplier = rear_energy
				var ri := MeshInstance3D.new(); ri.name = "LensRear"; ri.mesh = st_r.commit(); ri.transform = mesh.transform
				ri.material_override = rmat
				parent.add_child(ri)
				if flag_unmerged: ri.set_meta("npc_keep_unmerged", true)
				out["tail"].append(rmat)
			did_split = true
		if did_split:
			mesh.visible = false
	return out


# Like split_lens_mesh, but for ONE surface (exact material name) of a possibly MULTI-surface
# mesh (e.g. the Lada "headlight" node where "headlight_glass" is one surface spanning the front
# headlight glass AND the rear corner taillights). Splits that surface's triangles by model-z:
# rear → red sub-mesh (returned), front → a clear sub-mesh with the original material; the
# original surface is hidden (transparent override) so only the rear corners glow.
static func split_surface(root: Node3D, material_exact: String, native_front_z_positive := true, rear_energy := 0.7, flag_unmerged := false, exclude_node_substr := "") -> Array:
	var out: Array = []
	var meshes: Array = []
	_all_meshes(root, meshes)
	for mesh in meshes:
		if mesh.mesh == null:
			continue
		if exclude_node_substr != "" and exclude_node_substr in String(mesh.name).to_lower():
			continue
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			if src == null or src.resource_name.to_lower() != material_exact:
				continue
			var t := _xform_to_root(mesh, root)
			var arr = mesh.mesh.surface_get_arrays(i)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if verts.size() == 0:
				continue
			var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var has_idx := idx.size() > 0
			var tri_count := (idx.size() / 3) if has_idx else (verts.size() / 3)
			var st_f := SurfaceTool.new(); st_f.begin(Mesh.PRIMITIVE_TRIANGLES)
			var st_r := SurfaceTool.new(); st_r.begin(Mesh.PRIMITIVE_TRIANGLES)
			var nf := 0; var nr := 0
			for tri in range(tri_count):
				var a: int = idx[tri * 3] if has_idx else tri * 3
				var b: int = idx[tri * 3 + 1] if has_idx else tri * 3 + 1
				var c: int = idx[tri * 3 + 2] if has_idx else tri * 3 + 2
				var cz := ((t * verts[a]).z + (t * verts[b]).z + (t * verts[c]).z) / 3.0
				var is_front := (cz >= 0.0) if native_front_z_positive else (cz < 0.0)
				var st := st_f if is_front else st_r
				for vi in [a, b, c]:
					if norms.size() > vi: st.set_normal(norms[vi])
					if uvs.size() > vi: st.set_uv(uvs[vi])
					st.add_vertex(verts[vi])
				if is_front: nf += 1
				else: nr += 1
			var parent: Node = mesh.get_parent()
			# hide the original spanning surface (transparent), keep the mesh's other surfaces
			var clear: Material = src.duplicate()
			if clear is StandardMaterial3D:
				clear.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				clear.albedo_color = Color(clear.albedo_color.r, clear.albedo_color.g, clear.albedo_color.b, 0.0)
			mesh.set_surface_override_material(i, clear)
			if nf > 0:
				var fi := MeshInstance3D.new(); fi.name = "GlassFrontSplit"; fi.mesh = st_f.commit(); fi.transform = mesh.transform
				fi.material_override = src.duplicate()
				parent.add_child(fi)
				if flag_unmerged: fi.set_meta("npc_keep_unmerged", true)
			if nr > 0:
				var rmat := StandardMaterial3D.new()
				rmat.albedo_color = Color(0.4, 0.05, 0.05)
				rmat.emission_enabled = true; rmat.emission = REAR_COLOR; rmat.emission_energy_multiplier = rear_energy
				var ri := MeshInstance3D.new(); ri.name = "TailSplit"; ri.mesh = st_r.commit(); ri.transform = mesh.transform
				ri.material_override = rmat
				parent.add_child(ri)
				if flag_unmerged: ri.set_meta("npc_keep_unmerged", true)
				out.append(rmat)
	return out


# lamp_keys: substrings for a SHARED lamp material; split per-surface by centroid z.
# native_front_z_positive: true when the model's native front is +Z (default).
static func apply_zsplit(root: Node3D, lamp_keys: Array, front_energy := 0.0, rear_energy := 0.7, native_front_z_positive := true, flag_unmerged := false) -> Dictionary:
	var out := {"head": [], "tail": []}
	var meshes: Array = []
	_all_meshes(root, meshes)
	for mesh in meshes:
		if mesh.mesh == null:
			continue
		var t := _xform_to_root(mesh, root)
		for i in range(mesh.mesh.get_surface_count()):
			var src: Material = mesh.mesh.surface_get_material(i)
			var mn := (src.resource_name.to_lower() if src else "")
			if not _name_matches(mn, lamp_keys):
				continue
			var arr = mesh.mesh.surface_get_arrays(i)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if verts.size() == 0:
				continue
			var cz := 0.0
			for v in verts:
				cz += (t * v).z
			cz /= verts.size()
			var is_front := (cz >= 0.0) if native_front_z_positive else (cz < 0.0)
			if is_front:
				_emit(mesh, i, src, FRONT_COLOR, front_energy, out["head"], flag_unmerged)
			else:
				_emit(mesh, i, src, REAR_COLOR, rear_energy, out["tail"], flag_unmerged)
	return out
