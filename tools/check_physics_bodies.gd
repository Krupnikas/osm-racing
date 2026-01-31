extends SceneTree

# Быстрая проверка количества physics bodies в сцене

func _init():
	check()
	quit()

func check():
	print("\n========== PHYSICS BODIES CHECK ==========")
	
	# Статистика
	var total_bodies = Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
	print("Total active physics bodies: %d" % total_bodies)
	
	# Анализ NPC
	var npc_count = 0
	var estimated_npc_bodies = 0
	
	# Считаем VehicleBody3D в сцене
	var root = get_root()
	if root:
		for node in get_all_children(root):
			if node is VehicleBody3D and "NPC" in node.name:
				npc_count += 1
				# Каждый VehicleBody3D = 1 body + 4 wheels
				estimated_npc_bodies += 5
	
	print("NPCs found: %d" % npc_count)
	print("Estimated NPC bodies (5 per car): %d" % estimated_npc_bodies)
	print("Other physics bodies: %d" % (total_bodies - estimated_npc_bodies))
	print("==========================================\n")

func get_all_children(node: Node) -> Array:
	var children = []
	for child in node.get_children():
		children.append(child)
		children.append_array(get_all_children(child))
	return children
