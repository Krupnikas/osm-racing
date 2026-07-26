extends Node

## Детерминированная проверка скоростного форсажа LOD0 вперёд.
## Инстансит генератор БЕЗ дерева/загрузки и напрямую зовёт _get_needed_chunks
## с мок-направлением движения (юг, +Z) на разных скоростях, печатает дальность
## LOD0 вперёд / назад / вбок.

func _ready() -> void:
	var GenScript = load("res://osm/osm_terrain_generator.gd")
	var gen = GenScript.new()
	gen.chunk_size = 210.0
	gen.enable_lod = true
	gen.lod0_distance = 250.0
	gen.lod1_distance = 250.0
	gen.lod2_distance = 1200.0
	gen.lod0_speed_factor = 6.0
	gen.lod0_forward_max_bonus = 300.0
	gen.min_speed_for_prediction = 5.0
	gen._cached_velocity_dir = Vector3(0, 0, 1)  # едем на юг (+Z)

	print("\n===== LOD0 FORWARD BOOST TEST (dir=+Z) =====")
	var ppos := Vector3(105, 0, 105)  # центр чанка (0,0) — симметричный базис
	for spd in [0.0, 15.0, 30.0, 60.0]:
		gen._chunk_lod.clear()
		var chunks = gen._get_needed_chunks(ppos, float(spd))
		var ahead := _extent(gen, 0, 1)
		var behind := _extent(gen, 0, -1)
		var side := _extent(gen, 1, 0)
		var lod0_count := 0
		for k in gen._chunk_lod:
			if gen._chunk_lod[k] == 0:
				lod0_count += 1
		print("speed=%2.0f m/s | LOD0 ahead=%4dm  behind=%4dm  side=%4dm | LOD0 chunks=%d  total=%d" % [
			spd, ahead, behind, side, lod0_count, chunks.size()])
	print("============================================\n")
	gen.free()
	OS.kill(OS.get_process_id())


func _extent(gen, dirx: int, dirz: int) -> int:
	# Дальность самого дальнего LOD0-чанка вдоль направления (метры до центра).
	var maxd := 0
	for i in range(0, 10):
		var key := "%d,%d" % [dirx * i, dirz * i]
		if gen._chunk_lod.get(key, -1) == 0:
			maxd = int(i * 210 + 105)
	return maxd
