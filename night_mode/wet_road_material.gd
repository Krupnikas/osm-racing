extends RefCounted
class_name WetRoadMaterial

## Утилиты для создания эффекта мокрого асфальта

# Параметры мокрой дороги - более отражающий асфальт
const WET_METALLIC := 0.6
const WET_ROUGHNESS := 0.02
const WET_SPECULAR := 1.0

# Параметры сухой дороги
const DRY_METALLIC := 0.0
const DRY_ROUGHNESS := 0.85
const DRY_SPECULAR := 0.5


static func apply_wet_properties(material: StandardMaterial3D, is_wet: bool) -> void:
	if not material:
		return

	if is_wet:
		material.metallic = WET_METALLIC
		material.roughness = WET_ROUGHNESS
		material.metallic_specular = WET_SPECULAR
		# Немного затемняем для мокрого эффекта
		var color := material.albedo_color
		material.albedo_color = color.darkened(0.15)
	else:
		material.metallic = DRY_METALLIC
		material.roughness = DRY_ROUGHNESS
		material.metallic_specular = DRY_SPECULAR


static func create_wet_road_material(base_color: Color = Color(0.18, 0.18, 0.2)) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color.darkened(0.15)
	mat.metallic = WET_METALLIC
	mat.roughness = WET_ROUGHNESS
	mat.metallic_specular = WET_SPECULAR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func create_dry_road_material(base_color: Color = Color(0.2, 0.2, 0.22)) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	mat.metallic = DRY_METALLIC
	mat.roughness = DRY_ROUGHNESS
	mat.metallic_specular = DRY_SPECULAR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
