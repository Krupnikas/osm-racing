extends Node3D

## Скрипт для настройки модели Renault Logan 2004
## Скрывает колёса из модели, изменяет цвет кузова,
## настраивает стёкла (день/ночь), фары и габариты.
##
## Модель: Sketchfab GLTF, масштаб ~0.006
## Ключевые меши: Kuzov_low (кузов), Glass_low (стёкла),
## Fara (фары), Fonar (фонари), Rezina/Disk (колёса)


# Цвета стёкол для дня и ночи
var glass_color_day := Color(0.12, 0.14, 0.2, 0.5)
var glass_color_night := Color(0.05, 0.07, 0.12, 1.0)

var _glass_materials: Array[StandardMaterial3D] = []
var _taillight_materials: Array[StandardMaterial3D] = []
var _brake_lights: Array[SpotLight3D] = []
var _headlights: Array[SpotLight3D] = []
var _underglow_lights: Array[SpotLight3D] = []
var _underglow_material: StandardMaterial3D
var _underglow_enabled := false
var _underglow_color_index := 0
var _is_night := false
var _vehicle: Node
var _night_manager: Node

const UNDERGLOW_COLORS := [
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(0.8, 0.0, 1.0),   # Purple
	Color(1.0, 0.0, 0.5),   # Pink
	Color(0.0, 1.0, 0.3),   # Green
	Color(1.0, 0.5, 0.0),   # Orange
]

func _ready() -> void:
	_vehicle = get_parent()

	await get_tree().process_frame

	_change_body_color()
	_setup_gevp_wheels()
	_setup_taillights()
	_setup_headlights()
	_setup_underglow()

func _process(_delta: float) -> void:
	if not is_instance_valid(_night_manager):
		_night_manager = get_tree().current_scene.find_child("NightModeManager", true, false)
	if _night_manager and "is_night" in _night_manager:
		var current_night: bool = _night_manager.is_night
		if current_night != _is_night:
			_is_night = current_night
			_update_glass_materials()
			_update_headlights()
			_update_underglow_for_night()

	_update_taillight_brightness()


func _update_glass_materials() -> void:
	for material in _glass_materials:
		if not is_instance_valid(material):
			continue
		if _is_night:
			material.albedo_color = glass_color_night
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.metallic = 0.2
			material.metallic_specular = 0.8
			material.roughness = 0.1
			material.clearcoat = 0.9
			material.clearcoat_roughness = 0.05
		else:
			material.albedo_color = glass_color_day
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.metallic = 0.0
			material.metallic_specular = 0.5
			material.roughness = 0.05
			material.clearcoat = 0.0
			material.clearcoat_roughness = 0.0


func _setup_gevp_wheels() -> void:
	var vehicle = get_parent()

	# Check if parent is a GEVP vehicle with wheel exports
	if not vehicle.get("front_left_wheel"):
		# Not GEVP — just hide wheels (for VehicleBody3D racer scenes)
		var meshes := _find_all_meshes(self)
		for mesh in meshes:
			var mesh_name: String = mesh.name.to_lower()
			if "rezina" in mesh_name or "disk" in mesh_name or "wheel" in mesh_name:
				mesh.visible = false
		return

	# Find tire and disk MeshInstance3D nodes in the model
	var tire_node: MeshInstance3D = null
	var disk_node: MeshInstance3D = null

	var meshes := _find_all_meshes(self)
	for mesh in meshes:
		var mesh_name: String = mesh.name.to_lower()
		if "rezina" in mesh_name and mesh.mesh:
			tire_node = mesh
			mesh.visible = false
			print("Logan: Found tire mesh: ", mesh.name, " AABB=", mesh.mesh.get_aabb())
		elif "disk" in mesh_name and mesh.mesh:
			disk_node = mesh
			mesh.visible = false
			print("Logan: Found disk mesh: ", mesh.name, " AABB=", mesh.mesh.get_aabb())

	if not tire_node and not disk_node:
		print("Logan: No wheel meshes found")
		return

	# Get transform from mesh local space to vehicle local space
	# This encodes ALL GLTF hierarchy transforms + model transform automatically
	var tire_xform := Transform3D.IDENTITY
	if tire_node:
		tire_xform = vehicle.global_transform.affine_inverse() * tire_node.global_transform

	var disk_xform := Transform3D.IDENTITY
	if disk_node:
		disk_xform = vehicle.global_transform.affine_inverse() * disk_node.global_transform

	# Split combined meshes (all 4 wheels in one mesh) into 4 individual meshes
	var tire_parts: Array = _split_mesh_quadrants(tire_node.mesh) if tire_node else []
	var disk_parts: Array = _split_mesh_quadrants(disk_node.mesh) if disk_node else []

	# GEVP wheel rays
	var rays := [
		vehicle.front_left_wheel,
		vehicle.front_right_wheel,
		vehicle.rear_left_wheel,
		vehicle.rear_right_wheel,
	]

	# Assign each split quadrant to the nearest GEVP wheel
	for wi in range(4):
		var wheel_node: Node3D = rays[wi].wheel_node
		var wheel_pos: Vector3 = rays[wi].position  # RayCast3D position in vehicle space

		if tire_parts.size() == 4:
			var ti := _find_nearest_part(tire_parts, tire_xform, wheel_pos)
			if ti >= 0:
				var inst := MeshInstance3D.new()
				inst.mesh = tire_parts[ti]["mesh"]
				inst.transform = Transform3D(tire_xform.basis, Vector3.ZERO)
				wheel_node.add_child(inst)
				tire_parts[ti] = null  # Mark as used

		if disk_parts.size() == 4:
			var di := _find_nearest_part(disk_parts, disk_xform, wheel_pos)
			if di >= 0:
				var inst := MeshInstance3D.new()
				inst.mesh = disk_parts[di]["mesh"]
				inst.transform = Transform3D(disk_xform.basis, Vector3.ZERO)
				wheel_node.add_child(inst)
				disk_parts[di] = null

	print("Logan: GEVP wheels setup with split model meshes")


func _find_nearest_part(parts: Array, mesh_xform: Transform3D, target_pos: Vector3) -> int:
	var best_idx := -1
	var best_dist := INF
	for i in range(parts.size()):
		if parts[i] == null:
			continue
		# Convert quadrant center from mesh local space to vehicle space
		var center_vehicle: Vector3 = mesh_xform * parts[i]["center"]
		var dist := center_vehicle.distance_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best_idx = i
	return best_idx


func _split_mesh_quadrants(source_mesh: Mesh) -> Array:
	## Splits a combined 4-wheel mesh into 4 individual meshes centered at origin.
	## Returns Array of {"mesh": ArrayMesh, "center": Vector3} or null entries.
	var mdt := MeshDataTool.new()
	if mdt.create_from_surface(source_mesh, 0) != OK:
		return []

	var aabb := source_mesh.get_aabb()
	var center := aabb.get_center()
	var size := aabb.size

	# Split on the two largest axes (left-right and front-back)
	var axes := [
		{"i": 0, "s": size.x},
		{"i": 1, "s": size.y},
		{"i": 2, "s": size.z},
	]
	axes.sort_custom(func(a, b): return a["s"] > b["s"])
	var ax_a: int = axes[0]["i"]
	var ax_b: int = axes[1]["i"]

	print("Logan: Splitting mesh AABB=", aabb, " axes=", ax_a, ",", ax_b)

	# Group faces into 4 quadrants
	var groups: Array = [[], [], [], []]
	for fi in range(mdt.get_face_count()):
		var v0 := mdt.get_vertex(mdt.get_face_vertex(fi, 0))
		var v1 := mdt.get_vertex(mdt.get_face_vertex(fi, 1))
		var v2 := mdt.get_vertex(mdt.get_face_vertex(fi, 2))
		var fc := (v0 + v1 + v2) / 3.0

		var qa := 1 if fc[ax_a] > center[ax_a] else 0
		var qb := 1 if fc[ax_b] > center[ax_b] else 0
		groups[qa * 2 + qb].append(fi)

	# Build 4 separate meshes
	var material: Material = source_mesh.surface_get_material(0)
	var result: Array = []

	for g in range(4):
		if groups[g].is_empty():
			result.append(null)
			continue

		# Calculate center of this group's vertices
		var g_center := Vector3.ZERO
		var vc := 0
		for fi in groups[g]:
			for vi in range(3):
				g_center += mdt.get_vertex(mdt.get_face_vertex(fi, vi))
				vc += 1
		g_center /= float(vc)

		# Build mesh with vertices centered at origin
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

		for fi in groups[g]:
			for vi in range(3):
				var idx := mdt.get_face_vertex(fi, vi)
				st.set_normal(mdt.get_vertex_normal(idx))
				st.set_uv(mdt.get_vertex_uv(idx))
				st.add_vertex(mdt.get_vertex(idx) - g_center)

		st.generate_tangents()
		var mesh := st.commit()
		if material:
			mesh.surface_set_material(0, material)

		result.append({"mesh": mesh, "center": g_center})
		print("Logan: Quadrant ", g, " faces=", groups[g].size(), " center=", g_center)

	return result


func _find_all_meshes(node: Node) -> Array:
	var meshes: Array = []
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		meshes.append_array(_find_all_meshes(child))
	return meshes


func _change_body_color() -> void:
	var meshes := _find_all_meshes(self)

	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue

		var mesh_name: String = mesh.name.to_lower()

		# Определяем тип детали по имени меша
		# Стёкла: Glass_low (окна), стекло фар (Fara_1)
		var is_glass: bool = ("glass" in mesh_name and not "fara" in mesh_name)
		# Фары и фонари
		var is_light: bool = "fara" in mesh_name or "fonar" in mesh_name or "protivotumanki" in mesh_name
		# Колёса
		var is_wheel: bool = "rezina" in mesh_name or "disk" in mesh_name
		# Шасси/подвеска/салон — пропускаем
		var is_chassis: bool = "dno" in mesh_name or "vihlop" in mesh_name or "bak" in mesh_name \
			or "salon" in mesh_name or "sidenie" in mesh_name or "podkrilok" in mesh_name \
			or "bolt" in mesh_name or "ramka" in mesh_name or "nomer" in mesh_name

		if is_light or is_wheel or is_chassis:
			continue

		var surface_count: int = mesh.get_surface_override_material_count()
		if surface_count == 0 and mesh.mesh:
			surface_count = mesh.mesh.get_surface_count()

		for i in range(surface_count):
			var material: Material = mesh.get_surface_override_material(i)
			if not material and mesh.mesh:
				var original_mat: Material = mesh.mesh.surface_get_material(i)
				if original_mat:
					material = original_mat.duplicate()
					mesh.set_surface_override_material(i, material)

			if material is StandardMaterial3D:
				var mat_name := ""
				if material.resource_name:
					mat_name = material.resource_name.to_lower()

				# Материал Podveska_Salon — пропускаем (внутренности)
				if "podveska" in mat_name or "salon" in mat_name:
					continue

				if is_glass or "glass" in mat_name:
					material.albedo_texture = null
					material.normal_texture = null
					material.albedo_color = glass_color_day
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
					material.metallic = 0.0
					material.metallic_specular = 0.5
					material.roughness = 0.05
					_glass_materials.append(material)


func _setup_taillights() -> void:
	var meshes := _find_all_meshes(self)
	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue
		var mesh_name: String = mesh.name.to_lower()
		if "fonar" in mesh_name:
			print("Logan: Found taillight mesh: ", mesh.name)
			_setup_taillight_material(mesh)

	# SpotLight3D для стоп-сигналов (направлены назад, +Z)
	# Позиции подгоняются под модель
	var brake_positions := [
		Vector3(-0.55, 0.85, 2.0),  # Левый
		Vector3(0.55, 0.85, 2.0),   # Правый
	]

	for i in range(brake_positions.size()):
		var light := SpotLight3D.new()
		light.name = "BrakeLight_%d" % i
		light.position = brake_positions[i]
		light.rotation_degrees = Vector3(0, 180, 0)
		light.spot_range = 1.5
		light.spot_angle = 90.0
		light.light_energy = 0.3
		light.light_color = Color(1.0, 0.0, 0.0)
		light.shadow_enabled = false
		light.visible = true
		get_parent().add_child(light)
		_brake_lights.append(light)
		print("  -> Created brake SpotLight at ", brake_positions[i])


func _setup_taillight_material(mesh: MeshInstance3D) -> void:
	var surface_count: int = mesh.get_surface_override_material_count()
	if surface_count == 0 and mesh.mesh:
		surface_count = mesh.mesh.get_surface_count()

	for i in range(surface_count):
		var material: Material = mesh.get_surface_override_material(i)
		if not material and mesh.mesh:
			var original_mat: Material = mesh.mesh.surface_get_material(i)
			if original_mat:
				material = original_mat.duplicate()
				mesh.set_surface_override_material(i, material)

		if material is StandardMaterial3D:
			material.emission_enabled = true
			material.emission = Color(1.0, 0.1, 0.1)
			material.emission_energy_multiplier = 0.5
			_taillight_materials.append(material)
			print("  -> Added taillight material")


func _setup_headlights() -> void:
	# SpotLight3D для передних фар (направлены вперёд, -Z)
	var headlight_positions := [
		Vector3(-0.55, 0.7, -2.0),  # Левая фара
		Vector3(0.55, 0.7, -2.0),   # Правая фара
	]

	for i in range(headlight_positions.size()):
		var light := SpotLight3D.new()
		light.name = "Headlight_%d" % i
		light.position = headlight_positions[i]
		light.rotation_degrees = Vector3(0, 0, 0)
		light.spot_range = 30.0
		light.spot_angle = 45.0
		light.light_energy = 2.0
		light.light_color = Color(1.0, 0.95, 0.8)
		light.shadow_enabled = true
		light.visible = _is_night
		get_parent().add_child(light)
		_headlights.append(light)
		print("  -> Created headlight SpotLight at ", headlight_positions[i])

	# Emission на фарах
	var meshes := _find_all_meshes(self)
	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue
		var mesh_name: String = mesh.name.to_lower()
		if "fara_lamp" in mesh_name or "fara_2" in mesh_name:
			_setup_headlight_material(mesh)


func _setup_headlight_material(mesh: MeshInstance3D) -> void:
	var surface_count: int = mesh.get_surface_override_material_count()
	if surface_count == 0 and mesh.mesh:
		surface_count = mesh.mesh.get_surface_count()

	for i in range(surface_count):
		var material: Material = mesh.get_surface_override_material(i)
		if not material and mesh.mesh:
			var original_mat: Material = mesh.mesh.surface_get_material(i)
			if original_mat:
				material = original_mat.duplicate()
				mesh.set_surface_override_material(i, material)

		if material is StandardMaterial3D:
			material.emission_enabled = true
			material.emission = Color(1.0, 0.95, 0.8)
			material.emission_energy_multiplier = 0.3


func _update_taillight_brightness() -> void:
	var braking := false
	if _vehicle and "brake_input" in _vehicle:
		braking = _vehicle.brake_input > 0.1

	for material in _taillight_materials:
		if is_instance_valid(material):
			material.emission_energy_multiplier = 2.0 if braking else 0.5

	for light in _brake_lights:
		if is_instance_valid(light):
			light.light_energy = 2.0 if braking else 0.3


func _update_headlights() -> void:
	for light in _headlights:
		if is_instance_valid(light):
			light.visible = _is_night


func _setup_underglow() -> void:
	var color := UNDERGLOW_COLORS[0]

	_underglow_material = StandardMaterial3D.new()
	_underglow_material.albedo_color = color
	_underglow_material.emission_enabled = true
	_underglow_material.emission = color
	_underglow_material.emission_energy_multiplier = 3.0

	var left_positions: Array[Vector3] = []
	var right_positions: Array[Vector3] = []
	for i in range(5):
		var z: float = 0.8 - (i * 0.4)
		left_positions.append(Vector3(-0.7, 0.37, z))
		right_positions.append(Vector3(0.7, 0.37, z))

	var rear_positions: Array[Vector3] = []
	for i in range(3):
		var x: float = -0.45 + (i * 0.45)
		rear_positions.append(Vector3(x, 0.37, 1.7))

	var front_positions: Array[Vector3] = []
	for i in range(3):
		var x: float = -0.45 + (i * 0.45)
		front_positions.append(Vector3(x, 0.32, -1.7))

	var side_count: int = left_positions.size() + right_positions.size()
	for i in range(side_count):
		var pos: Vector3
		if i < left_positions.size():
			pos = left_positions[i]
		else:
			pos = right_positions[i - left_positions.size()]
		var light := SpotLight3D.new()
		light.name = "Underglow_%d" % i
		light.position = pos
		light.rotation_degrees = Vector3(-90, 0, 0)
		light.spot_range = 1.0
		light.spot_angle = 60.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	for i in range(rear_positions.size()):
		var light := SpotLight3D.new()
		light.name = "UnderglowRear_%d" % i
		light.position = rear_positions[i]
		light.rotation_degrees = Vector3(-90, 0, 0)
		light.spot_range = 1.0
		light.spot_angle = 70.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	for i in range(front_positions.size()):
		var light := SpotLight3D.new()
		light.name = "UnderglowFront_%d" % i
		light.position = front_positions[i]
		light.rotation_degrees = Vector3(-90, 0, 0)
		light.spot_range = 1.0
		light.spot_angle = 90.0
		light.light_energy = 0.8
		light.light_color = color
		light.shadow_enabled = true
		light.visible = _underglow_enabled
		get_parent().add_child(light)
		_underglow_lights.append(light)

	print("  -> Created underglow with %d lights" % _underglow_lights.size())


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			_toggle_underglow()


func _update_underglow_for_night() -> void:
	_underglow_enabled = _is_night
	for light in _underglow_lights:
		if is_instance_valid(light):
			light.visible = _underglow_enabled


func _toggle_underglow() -> void:
	_underglow_enabled = not _underglow_enabled

	if _underglow_enabled:
		_underglow_color_index = (_underglow_color_index + 1) % UNDERGLOW_COLORS.size()
		var new_color: Color = UNDERGLOW_COLORS[_underglow_color_index]
		for light in _underglow_lights:
			if is_instance_valid(light):
				light.light_color = new_color
		if _underglow_material:
			_underglow_material.albedo_color = new_color
			_underglow_material.emission = new_color

	for light in _underglow_lights:
		if is_instance_valid(light):
			light.visible = _underglow_enabled

	print("Underglow: ", "ON (color %d)" % _underglow_color_index if _underglow_enabled else "OFF")
