@tool
extends SceneTree

func _init():
	var paths := [
		"res://textures/buildings/111-126.jpg",
		"res://textures/buildings/111-126_normal.png",
		"res://textures/buildings/111-126_ambient.png",
		"res://textures/buildings/111-126_specular.png",
		"res://textures/buildings/111-126_displacement.png"
	]

	for path in paths:
		var tex := _load_texture(path)
		print("Path: ", path)
		print("  Loaded: ", tex != null)
		if tex:
			print("  Size: ", tex.get_width(), "x", tex.get_height())
		print("")

	quit()


func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	# Fallback: load as raw image
	var img := Image.new()
	var global_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		var err := img.load(global_path)
		if err == OK:
			return ImageTexture.create_from_image(img)
	return null
