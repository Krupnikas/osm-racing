extends Node3D
## Clutter test bench — validates size / collision / effects for clutter models in
## isolation. _ready() builds a flat lit stage + a 1 m red reference cube + fixed camera.
## Models are spawned/hit on demand via the helper methods below (driven from
## execute_game_script), so scales and colliders can be iterated without editing the scene.

var bodies: Array = []          # spawned RigidBody3D
var report: Dictionary = {}     # name -> {native, scale, scaled}


func _ready() -> void:
	_make_ground()
	_make_light()
	_make_ref_cube(Vector3(-3.0, 0.0, 0.0))
	_make_camera(Vector3(6.0, 0.0, 0.0))


func _make_ground() -> void:
	var sb := StaticBody3D.new()
	sb.name = "Ground"
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(80.0, 1.0, 40.0)
	cs.shape = bs
	cs.position = Vector3(0.0, -0.5, 0.0)
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80.0, 40.0)
	mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.42, 0.42)
	mi.material_override = mat
	sb.add_child(mi)
	add_child(sb)


func _make_light() -> void:
	var dl := DirectionalLight3D.new()
	dl.rotation_degrees = Vector3(-50.0, -40.0, 0.0)
	dl.shadow_enabled = true
	add_child(dl)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.6, 0.72, 0.88)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.6)
	e.ambient_light_energy = 1.0
	we.environment = e
	add_child(we)


func _make_ref_cube(base: Vector3) -> void:
	# 1 m cube resting on the ground — visual scale reference
	var mi := MeshInstance3D.new()
	mi.name = "Ref1m"
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	mi.mesh = bm
	mi.position = base + Vector3(0.0, 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.1, 0.1)
	mi.material_override = mat
	add_child(mi)


func _make_camera(center: Vector3) -> void:
	var cam := Camera3D.new()
	cam.name = "BenchCam"
	cam.position = center + Vector3(0.0, 5.0, 12.0)
	cam.look_at(center + Vector3(0.0, 0.4, 0.0), Vector3.UP)
	cam.current = true
	add_child(cam)


## Merged AABB of a node's meshes, expressed in the node's own local space.
func node_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var root_inv := node.global_transform.affine_inverse()
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = mi.get_aabb()
		var gt: Transform3D = mi.global_transform
		for i in range(8):
			var corner := a.position + Vector3(
				a.size.x if (i & 1) else 0.0,
				a.size.y if (i & 2) else 0.0,
				a.size.z if (i & 4) else 0.0)
			var local := root_inv * (gt * corner)
			if first:
				out = AABB(local, Vector3.ZERO)
				first = false
			else:
				out = out.expand(local)
	return out


## Spawn one model as a RigidBody, auto-scaled so its height == target_h, dropped from drop_y.
## spec keys: name, path, target_h, mass, lin_damp, ang_damp, bounce, shape("cyl"|"box"), x
func spawn_model(spec: Dictionary, drop_y: float = 3.0) -> void:
	var scene: Node3D = load(spec.path).instantiate()
	add_child(scene)  # add first so nested global transforms resolve
	var aabb := node_aabb(scene)
	var h: float = maxf(aabb.size.y, 0.0001)
	var s: float = float(spec.get("target_h", 1.0)) / h
	report[spec.name] = {"native": aabb.size, "scale": s, "scaled": aabb.size * s}
	remove_child(scene)

	var rb := RigidBody3D.new()
	rb.name = "RB_%s" % spec.name
	rb.set_meta("clutter_name", spec.name)
	rb.mass = float(spec.get("mass", 5.0))
	rb.linear_damp = float(spec.get("lin_damp", 0.0))
	rb.angular_damp = float(spec.get("ang_damp", 0.1))
	var pmat := PhysicsMaterial.new()
	pmat.bounce = float(spec.get("bounce", 0.1))
	pmat.friction = 0.9
	rb.physics_material_override = pmat

	# center model in XZ, base at y=0
	scene.scale = Vector3(s, s, s)
	scene.position = Vector3(
		-(aabb.position.x + aabb.size.x * 0.5) * s,
		-aabb.position.y * s,
		-(aabb.position.z + aabb.size.z * 0.5) * s)
	rb.add_child(scene)

	var sz: Vector3 = aabb.size * s
	var col := CollisionShape3D.new()
	if String(spec.get("shape", "box")) == "cyl":
		var cy := CylinderShape3D.new()
		cy.height = sz.y
		cy.radius = maxf(sz.x, sz.z) * 0.5
		col.shape = cy
	else:
		var bx := BoxShape3D.new()
		bx.size = sz
		col.shape = bx
	col.position = Vector3(0.0, sz.y * 0.5, 0.0)
	rb.add_child(col)

	rb.position = Vector3(float(spec.get("x", 0.0)), drop_y, 0.0)
	add_child(rb)
	bodies.append(rb)


## Lateral impulse ~ mass * dv (a ~dv m/s clip) to test fly/flop behaviour.
func apply_hits(dv: float = 8.0) -> void:
	for rb in bodies:
		rb.apply_central_impulse(Vector3(dv * rb.mass, 0.3 * rb.mass, 0.0))


func positions() -> Dictionary:
	var d := {}
	for rb in bodies:
		if is_instance_valid(rb):
			d[rb.get_meta("clutter_name", rb.name)] = rb.global_position
	return d
