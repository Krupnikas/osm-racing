extends Node3D
## Interactive watermelon market stand (see docs/WATERMELON_STAND_PLAN.md).
##
## Intact = a pallet + a 4-layer pyramid of INDIVIDUAL FROZEN watermelon bodies (preferred path)
## + 2 display slices. The fruit bodies are RigidBody3D frozen FREEZE_MODE_KINEMATIC (no simulation
## → rock stable, no jitter). A single root Area3D is the one impact-decision point:
##   * low-speed hit (< smash_speed) → unfreeze the SAME bodies → they scatter/roll off the pallet;
##   * high-speed hit (>= smash_speed) → remove the fruit, spawn red pulp + green rind debris.
## No big invisible solid box — the pallet slab (layer 1) + each fruit's sphere collider (layer 4)
## are the only collision the car feels. Self-contained: build everything in _ready().

enum State { INTACT, ROLLING, SMASHED }

# --- placement / identity (set by the spawner before add_child) ---
@export var stand_index: int = 0            # deterministic seed base; also dedup
# --- interaction tuning ---
@export var smash_speed_mps: float = 8.33   # 30 km/h
# --- layout tuning ---
@export var pallet_footprint_x: float = 1.2   # m (long side); Z derived from asset aspect
@export var watermelon_diameter: float = 0.22 # m (target footprint of one fruit; sized so 5 fit across)
@export var slice_size: float = 0.27          # m (−10% vs original)
@export var slice_count: int = 1              # display slice(s) crowning the top (replaces the 4th layer)
@export var melon_darken: float = 0.55        # albedo tint for watermelons (they render over-bright)
@export var slice_darken: float = 0.8         # albedo tint for slices
@export var layer_shrink: Array = [1.0, 0.75, 0.52]
@export var layer_y_step_frac: float = 0.66   # vertical step between layers (× diameter)
@export var edge_margin_frac: float = 0.5     # pallet edge margin (× radius)
@export var pos_jitter_frac: float = 0.22     # per-slot XZ jitter (× radius)
# --- debug ---
@export var wmelon_debug: bool = false

# 3 watermelon layers (denser 2nd/3rd) + the slice crowns the top where a 4th layer would be.
const GRIDS := [[5, 3], [4, 2], [3, 2]]  # cols(X) × rows(Z) per layer → 15,8,6 = 29
const DEBRIS_CAP := 40
const PULP_PINK := Color(0.86, 0.18, 0.27)
const PULP_PINK_LT := Color(0.92, 0.34, 0.40)
const RIND_GREEN := Color(0.20, 0.55, 0.22)
const SEED_DARK := Color(0.08, 0.08, 0.06)

var _state: int = State.INTACT
var _triggered: bool = false
var _melons: Array[RigidBody3D] = []
var _slices: Array[RigidBody3D] = []

# baked assets
var _melon_mesh: Mesh
var _slice_mesh: Mesh
var _pallet_mesh: Mesh
var _melon_r: float = 0.13      # sphere collider radius (scaled)
var _melon_d: float = 0.26      # horizontal footprint (scaled)
var _pallet_top: float = 0.14   # top surface y of the pallet (scaled thickness)
var _slice_half_y: float = 0.07
var _pile_top: float = 0.7       # local Y of the pile top (set in _build_layout)

# shared debris resources (built lazily)
var _pulp_mesh: BoxMesh
var _mat_pink: StandardMaterial3D
var _mat_pink_lt: StandardMaterial3D
var _mat_rind: StandardMaterial3D
var _burst_proc: ParticleProcessMaterial
var _burst_draw: QuadMesh

# sfx
var _sfx_touch: AudioStream = null       # light touch (low-speed roll)
var _sfx_high: AudioStream = null        # smash (high-speed pulp)


func _ready() -> void:
	if ResourceLoader.exists("res://audio/sfx/watermelon_touch.mp3"):
		_sfx_touch = load("res://audio/sfx/watermelon_touch.mp3")
	if ResourceLoader.exists("res://audio/sfx/watermelon_high_speed.mp3"):
		_sfx_high = load("res://audio/sfx/watermelon_high_speed.mp3")
	_load_assets()
	_build_pallet()
	var layout := _build_layout()
	_build_melons(layout)
	_build_slices()
	_build_trigger()
	if wmelon_debug:
		_build_debug()
		print("[WMELON] stand %d built: %d melons, %d slices, pallet_top=%.3f d=%.3f r=%.3f" % [
			stand_index, _melons.size(), _slices.size(), _pallet_top, _melon_d, _melon_r])


# ---------------------------------------------------------------- assets

# Bake a GLB's single mesh (with its node transform applied), recenter, and scale to a target.
# mode "sphere": center on the AABB centre (origin) — for the watermelon.
# mode "base":   XZ-centred, base at y=0 — for the pallet / slice.
func _bake_mesh(path: String, mode: String, target: float, target_axis: String, darken: float = 1.0) -> Dictionary:
	var ps: PackedScene = load(path)
	if ps == null:
		push_warning("WMELON: missing asset " + path)
		return {}
	var inst := ps.instantiate()
	var mi: MeshInstance3D = null
	var stack: Array = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			mi = n
	if mi == null:
		inst.free()
		return {}
	# node transform relative to inst
	var t := Transform3D.IDENTITY
	var p: Node = mi
	while p != null and p != inst:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	# collect baked surfaces + AABB
	var src: Mesh = mi.mesh
	var surfs: Array = []
	var ab := AABB()
	var first := true
	for si in range(src.get_surface_count()):
		var arr := src.surface_get_arrays(si)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bv := PackedVector3Array()
		bv.resize(verts.size())
		for i in range(verts.size()):
			bv[i] = t * verts[i]
			if first:
				ab = AABB(bv[i], Vector3.ZERO); first = false
			else:
				ab = ab.expand(bv[i])
		arr[Mesh.ARRAY_VERTEX] = bv
		var norms = arr[Mesh.ARRAY_NORMAL]
		if norms != null and norms is PackedVector3Array:
			var nb := t.basis.inverse().transposed()
			var tn := PackedVector3Array()
			tn.resize(norms.size())
			for i in range(norms.size()):
				tn[i] = (nb * norms[i]).normalized()
			arr[Mesh.ARRAY_NORMAL] = tn
		surfs.append({"arr": arr, "mat": src.surface_get_material(si)})
	inst.free()
	var dim := ab.size.x
	if target_axis == "y": dim = ab.size.y
	elif target_axis == "maxxz": dim = maxf(ab.size.x, ab.size.z)
	var scl := (target / dim) if dim > 0.0 else 1.0
	var center := ab.get_center()
	var offset := -center
	if mode == "base":
		offset = Vector3(-center.x, -ab.position.y, -center.z)
	var out := ArrayMesh.new()
	for sf in surfs:
		var a: Array = sf.arr
		var vv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var o := PackedVector3Array()
		o.resize(vv.size())
		for i in range(vv.size()):
			o[i] = (vv[i] + offset) * scl
		a[Mesh.ARRAY_VERTEX] = o
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		var mat: Material = sf.mat
		if mat is StandardMaterial3D:
			# Force LIT (never glow at night — the watermelon-slice GLB ships UNSHADED) and tame the
			# over-bright look (darken albedo tint + rough, non-metallic so no specular bloom).
			var dm: StandardMaterial3D = (mat as StandardMaterial3D).duplicate()
			dm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			dm.metallic = 0.0
			dm.roughness = maxf(dm.roughness, 0.9)
			if darken < 1.0:
				dm.albedo_color = Color(darken, darken, darken, 1.0)
			mat = dm
		if mat:
			out.surface_set_material(out.get_surface_count() - 1, mat)
	return {"mesh": out, "size": ab.size * scl}


func _load_assets() -> void:
	var pal := _bake_mesh("res://models/market/pallet.glb", "base", pallet_footprint_x, "x")
	if not pal.is_empty():
		_pallet_mesh = pal.mesh
		_pallet_top = (pal.size as Vector3).y
	var wm := _bake_mesh("res://models/market/watermelon.glb", "sphere", watermelon_diameter, "maxxz", melon_darken)
	if not wm.is_empty():
		_melon_mesh = wm.mesh
		var s: Vector3 = wm.size
		_melon_d = maxf(s.x, s.z)
		_melon_r = (s.x + s.y + s.z) / 6.0  # avg radius → rolls believably
	var sl := _bake_mesh("res://models/market/watermelon-slice.glb", "base", slice_size, "maxxz", slice_darken)
	if not sl.is_empty():
		_slice_mesh = sl.mesh
		_slice_half_y = (sl.size as Vector3).y * 0.5


# ---------------------------------------------------------------- pallet

func _build_pallet() -> void:
	if _pallet_mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "Pallet"
	mi.mesh = _pallet_mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.visibility_range_end = 160.0
	add_child(mi)
	# thin slab collider on layer 1 (drive onto it like a low kerb) — NOT a tall box
	var body := StaticBody3D.new()
	body.name = "PalletBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# footprint from pallet aspect: x already target; z = x * (80.173/120.129)
	var fz := pallet_footprint_x * (80.173 / 120.129)
	box.size = Vector3(pallet_footprint_x, _pallet_top, fz)
	cs.shape = box
	cs.position.y = _pallet_top * 0.5
	body.add_child(cs)
	add_child(body)


# ---------------------------------------------------------------- layout

# Returns Array of {pos:Vector3, rot:Basis, s:float} in stand-local space.
func _build_layout() -> Array:
	var layout: Array = []
	var fz_pallet := pallet_footprint_x * (80.173 / 120.129)
	var margin := edge_margin_frac * _melon_r
	var usable_x := pallet_footprint_x - 2.0 * margin
	var usable_z := fz_pallet - 2.0 * margin
	var y_step := _melon_d * layer_y_step_frac
	_pile_top = _pallet_top + _melon_r + float(maxi(GRIDS.size() - 1, 0)) * y_step + _melon_r
	var idx := 0
	for k in range(GRIDS.size()):
		var shrink: float = float(layer_shrink[k]) if k < layer_shrink.size() else 0.5
		var lw := usable_x * shrink
		var ll := usable_z * shrink
		var cols: int = GRIDS[k][0]
		var rows: int = GRIDS[k][1]
		var layer_y := _pallet_top + _melon_r + float(k) * y_step
		# nestle alternate layers into the gaps below (half-cell shift)
		var off_x := (0.25 * lw / maxf(cols, 1)) if (k % 2 == 1) else 0.0
		var off_z := (0.25 * ll / maxf(rows, 1)) if (k % 2 == 1) else 0.0
		for cxi in range(cols):
			for czi in range(rows):
				var rng := RandomNumberGenerator.new()
				rng.seed = abs(hash("%d_%d" % [stand_index, idx]))
				var px := (float(cxi) + 0.5) / float(cols) * lw - lw * 0.5 + off_x
				var pz := (float(czi) + 0.5) / float(rows) * ll - ll * 0.5 + off_z
				px += rng.randf_range(-1.0, 1.0) * pos_jitter_frac * _melon_r
				pz += rng.randf_range(-1.0, 1.0) * pos_jitter_frac * _melon_r
				var py := layer_y + rng.randf_range(-0.06, 0.06) * _melon_r
				var yaw := rng.randf_range(0.0, TAU)
				var pitch := deg_to_rad(rng.randf_range(-8.0, 8.0))
				var roll := deg_to_rad(rng.randf_range(-8.0, 8.0))
				var b := Basis.from_euler(Vector3(pitch, yaw, roll))
				var s := rng.randf_range(0.9, 1.1)
				layout.append({"pos": Vector3(px, py, pz), "rot": b, "s": s})
				idx += 1
	return layout


# ---------------------------------------------------------------- fruit bodies

func _build_melons(layout: Array) -> void:
	if _melon_mesh == null:
		return
	for i in range(layout.size()):
		var d: Dictionary = layout[i]
		var body := RigidBody3D.new()
		body.name = "Watermelon_%d" % i
		body.mass = 2.5
		body.transform = Transform3D(d.rot, d.pos)
		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.collision_layer = 4
		body.collision_mask = 0
		body.linear_damp = 0.25
		body.angular_damp = 0.35
		var mi := MeshInstance3D.new()
		mi.mesh = _melon_mesh
		mi.scale = Vector3.ONE * float(d.s)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.visibility_range_end = 160.0
		body.add_child(mi)
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = _melon_r * float(d.s)
		cs.shape = sph
		body.add_child(cs)
		add_child(body)
		_melons.append(body)


func _build_slices() -> void:
	if _slice_mesh == null or _melons.is_empty():
		return
	# The slice CROWNS the top (where the 4th watermelon layer used to be): centred over the top
	# layer, resting on the top watermelons (no floating).
	var max_y := -1e9
	for m in _melons:
		if m.position.y > max_y:
			max_y = m.position.y
	var cx := 0.0
	var cz := 0.0
	var cn := 0
	for m in _melons:
		if m.position.y > max_y - _melon_d * 0.4:
			cx += m.position.x
			cz += m.position.z
			cn += 1
	if cn > 0:
		cx /= float(cn)
		cz /= float(cn)
	var n := maxi(slice_count, 1)
	for i in range(n):
		var rng := RandomNumberGenerator.new()
		rng.seed = abs(hash("%d_slice_%d" % [stand_index, i]))
		# slice base (mesh base at body origin) perches just onto the top watermelons
		var spread := 0.0 if n == 1 else (float(i) - float(n - 1) * 0.5) * _melon_d * 0.6
		var spot := Vector3(cx + spread + rng.randf_range(-0.02, 0.02), max_y + _melon_r * 0.5, cz + rng.randf_range(-0.02, 0.02))
		var body := RigidBody3D.new()
		body.name = "Slice_%d" % i
		body.mass = 1.2
		var yaw := rng.randf_range(0.0, TAU)
		var tilt := deg_to_rad(rng.randf_range(-12.0, 12.0))
		body.transform = Transform3D(Basis.from_euler(Vector3(tilt, yaw, deg_to_rad(rng.randf_range(-12.0, 12.0)))), spot)
		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.collision_layer = 4
		body.collision_mask = 0
		var mi := MeshInstance3D.new()
		mi.mesh = _slice_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.visibility_range_end = 160.0
		body.add_child(mi)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(slice_size * 0.9, maxf(_slice_half_y * 2.0, 0.05), slice_size * 0.9)
		cs.shape = box
		body.add_child(cs)
		add_child(body)
		_slices.append(body)


# ---------------------------------------------------------------- trigger

func _build_trigger() -> void:
	var area := Area3D.new()
	area.name = "ImpactTrigger"
	area.collision_layer = 0
	area.collision_mask = 1  # player only
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var fz_pallet := pallet_footprint_x * (80.173 / 120.129)
	var h := _pile_top + 0.4
	box.size = Vector3(pallet_footprint_x + 0.3, h, fz_pallet + 0.3)
	cs.shape = box
	cs.position.y = h * 0.5
	area.add_child(cs)
	area.body_entered.connect(_on_impact)
	add_child(area)


func _on_impact(body: Node) -> void:
	if _state != State.INTACT or _triggered:
		return
	if not (body is Node3D):
		return
	if not (body.is_in_group("player") or body is RigidBody3D or body is VehicleBody3D):
		return
	_triggered = true
	var car := body as Node3D
	var to_stand := global_position - car.global_position
	to_stand.y = 0.0
	var dir := to_stand.normalized() if to_stand.length_squared() > 0.0001 else Vector3.FORWARD
	var v := Vector3.ZERO
	if body is RigidBody3D:
		v = (body as RigidBody3D).linear_velocity
	elif body is VehicleBody3D:
		v = (body as VehicleBody3D).linear_velocity
	# approach speed = car velocity projected toward the stand (fallback: magnitude)
	var impact := maxf(0.0, v.dot(dir))
	if impact < 0.1:
		impact = v.length()
	if wmelon_debug:
		print("[WMELON] stand %d hit at %.1f km/h → %s" % [stand_index, impact * 3.6, "HIGH" if impact >= smash_speed_mps else "LOW"])
	if impact >= smash_speed_mps:
		_state = State.SMASHED
		_do_high_speed(car, dir, impact)
	else:
		_state = State.ROLLING
		_do_low_speed(car, dir, impact)


# ---------------------------------------------------------------- low speed

func _do_low_speed(car: Node3D, dir: Vector3, impact: float) -> void:
	_play_sfx(_sfx_touch)  # light touch as watermelons scatter
	var bodies: Array[RigidBody3D] = []
	bodies.append_array(_melons)
	bodies.append_array(_slices)
	for b in bodies:
		if not is_instance_valid(b):
			continue
		b.freeze = false
		b.collision_mask = 1  # ground only
		if car is PhysicsBody3D:
			b.add_collision_exception_with(car)
		var away := b.global_position - car.global_position
		away.y = 0.0
		if away.length_squared() < 0.0001:
			away = dir
		away = away.normalized()
		# stronger on fruit nearest the impact point
		var dist := maxf(0.2, b.global_position.distance_to(car.global_position))
		var dv := clampf(impact, 2.0, 8.0) * clampf(1.6 / dist, 0.4, 1.6)
		var imp := (away + Vector3(0, 0.35, 0)).normalized() * dv * b.mass
		b.apply_central_impulse(imp)
		b.apply_torque_impulse(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * dv * b.mass * 0.12)
	# settled fruit auto-sleep (cheap) and are freed on chunk unload; no forced TTL (would pop visible fruit)


# ---------------------------------------------------------------- high speed

func _do_high_speed(car: Node3D, dir: Vector3, impact: float) -> void:
	_play_sfx(_sfx_high)  # juicy smash on the pulp burst
	var origin := global_position + Vector3(0, _pallet_top + _melon_d, 0)
	# remove the intact fruit + slices before spawning debris
	for b in _melons:
		if is_instance_valid(b):
			b.queue_free()
	for b in _slices:
		if is_instance_valid(b):
			b.queue_free()
	_melons.clear()
	_slices.clear()
	_ensure_debris_resources()
	var dv := clampf(impact, 8.0, 20.0)
	var spawned := 0
	# red flesh chunks
	for i in range(28):
		if spawned >= DEBRIS_CAP:
			break
		var mat := _mat_pink if (i % 3 != 0) else _mat_pink_lt
		_spawn_chunk(origin, dir, dv, _pulp_mesh, mat, randf_range(0.9, 1.7))
		spawned += 1
	# green rind shards
	for i in range(8):
		if spawned >= DEBRIS_CAP:
			break
		_spawn_chunk(origin, dir, dv * 0.9, _pulp_mesh, _mat_rind, randf_range(1.2, 2.2))
		spawned += 1
	# red juice particle burst (one-shot)
	_spawn_burst(origin)


func _spawn_chunk(origin: Vector3, dir: Vector3, dv: float, mesh: Mesh, mat: Material, sscale: float) -> void:
	var body := RigidBody3D.new()
	body.mass = 0.15
	body.collision_layer = 4
	body.collision_mask = 1
	body.gravity_scale = 1.0
	body.global_position = origin + Vector3(randf_range(-0.2, 0.2), randf_range(-0.05, 0.25), randf_range(-0.2, 0.2))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.scale = Vector3.ONE * sscale
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.13, 0.13, 0.13) * sscale
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	var spread := dir.rotated(Vector3.UP, randf_range(-1.2, 1.2))
	# keep chunks fairly local so they pile up as readable pulp rather than rocketing out of frame
	body.linear_velocity = spread * (dv * randf_range(0.2, 0.45)) + Vector3.UP * randf_range(2.0, 4.0)
	body.angular_velocity = Vector3(randf_range(-14, 14), randf_range(-14, 14), randf_range(-14, 14))
	var ttl := randf_range(8.0, 11.0)
	get_tree().create_timer(ttl).timeout.connect(func() -> void:
		if is_instance_valid(body):
			body.queue_free())


func _spawn_burst(origin: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 70
	p.lifetime = 1.6
	p.one_shot = true
	p.explosiveness = 0.85
	p.process_material = _burst_proc
	p.draw_pass_1 = _burst_draw
	p.global_position = origin
	p.visibility_aabb = AABB(Vector3(-2.5, -1.0, -2.5), Vector3(5, 5, 5))
	add_child(p)
	p.emitting = true
	get_tree().create_timer(2.6).timeout.connect(func() -> void:
		if is_instance_valid(p):
			p.queue_free())


func _ensure_debris_resources() -> void:
	if _pulp_mesh != null:
		return
	_pulp_mesh = BoxMesh.new()
	_pulp_mesh.size = Vector3(0.13, 0.13, 0.13)
	_mat_pink = _flat_mat(PULP_PINK)
	_mat_pink_lt = _flat_mat(PULP_PINK_LT)
	_mat_rind = _flat_mat(RIND_GREEN)
	# red juice puff
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	grad.colors = PackedColorArray([Color(1.0, 0.22, 0.30, 1.0), Color(0.90, 0.16, 0.26, 0.9), Color(0.86, 0.16, 0.26, 0.0)])
	var puff := GradientTexture2D.new()
	puff.gradient = grad
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	puff.width = 64
	puff.height = 64
	var dm := StandardMaterial3D.new()
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_texture = puff
	dm.vertex_color_use_as_albedo = true
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.billboard_keep_scale = true
	# UNSHADED so the smash burst is clearly visible day or night (transient VFX, not the static pile).
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_burst_draw = QuadMesh.new()
	_burst_draw.size = Vector2(0.85, 0.85)
	_burst_draw.material = dm
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.35
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 75.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 6.5
	pm.gravity = Vector3(0, -4.0, 0)
	pm.scale_min = 1.6
	pm.scale_max = 3.6
	var aramp := Gradient.new()
	aramp.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	aramp.colors = PackedColorArray([Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.0)])
	var artex := GradientTexture1D.new()
	artex.gradient = aramp
	pm.color_ramp = artex
	_burst_proc = pm


func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.unit_size = 6.0
	p.max_distance = 60.0
	add_child(p)
	p.global_position = global_position + Vector3(0, _pallet_top + _melon_d * 0.5, 0)
	p.play()
	p.finished.connect(func() -> void:
		if is_instance_valid(p):
			p.queue_free())


func _flat_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	m.metallic = 0.0
	return m


# ---------------------------------------------------------------- debug + force-test (MCP)

func _build_debug() -> void:
	var marker := MeshInstance3D.new()
	marker.name = "DebugAnchor"
	var sm := SphereMesh.new()
	sm.radius = 0.12
	sm.height = 0.24
	marker.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat
	marker.position.y = 0.05
	add_child(marker)


func force_low_speed_hit() -> void:
	_triggered = false
	_state = State.INTACT
	var fake := global_position - global_transform.basis.z * 2.0
	_simulate_hit(fake, 4.0)


func force_high_speed_smash() -> void:
	_triggered = false
	_state = State.INTACT
	var fake := global_position - global_transform.basis.z * 2.0
	_simulate_hit(fake, 14.0)


func _simulate_hit(from_pos: Vector3, speed: float) -> void:
	if _state != State.INTACT or _triggered:
		return
	_triggered = true
	var dir := global_position - from_pos
	dir.y = 0.0
	dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD
	var car := get_tree().get_first_node_in_group("player") as Node3D
	if wmelon_debug:
		print("[WMELON] stand %d FORCED hit %.1f km/h → %s" % [stand_index, speed * 3.6, "HIGH" if speed >= smash_speed_mps else "LOW"])
	if speed >= smash_speed_mps:
		_state = State.SMASHED
		_do_high_speed(car if car else self, dir, speed)
	else:
		_state = State.ROLLING
		_do_low_speed(car if car else self, dir, speed)


func reset_to_intact() -> void:
	for b in _melons:
		if is_instance_valid(b):
			b.queue_free()
	for b in _slices:
		if is_instance_valid(b):
			b.queue_free()
	_melons.clear()
	_slices.clear()
	for c in get_children():
		if c.name.begins_with("Watermelon_") or c.name.begins_with("Slice_") or c is GPUParticles3D:
			c.queue_free()
	_state = State.INTACT
	_triggered = false
	var layout := _build_layout()
	_build_melons(layout)
	_build_slices()
