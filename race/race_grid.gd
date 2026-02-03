extends RefCounted
class_name RaceGrid

## Расчёт стартовой сетки для гонки
## Размещает соперников в 2 ряда позади игрока

# Константы стартовой сетки
const ROW_SPACING := 8.0      # Расстояние между рядами (метры)
const COLUMN_OFFSET := 3.0    # Смещение от центра влево/вправо (метры)
const HEIGHT_OFFSET := 1.0    # Высота над землёй для спавна


## Рассчитывает позиции соперников на стартовой сетке
## player_pos - позиция игрока (центр первого ряда)
## forward_dir - направление движения (вперёд)
## count - количество соперников
## Возвращает массив Transform3D для каждого соперника
static func calculate_positions(player_pos: Vector3, forward_dir: Vector3, count: int) -> Array:
	var positions: Array = []  # Array of Transform3D

	if count <= 0:
		return positions

	# Нормализуем направление
	var forward := forward_dir.normalized()
	if forward.length() < 0.1:
		forward = Vector3.FORWARD

	# Вычисляем вектор вправо (перпендикулярно направлению движения)
	var right := forward.cross(Vector3.UP).normalized()

	# Размещаем соперников в 2 ряда
	# Ряд 1: позиции 0, 1 (слева и справа)
	# Ряд 2: позиции 2, 3 (слева и справа)
	# и т.д.

	for i in range(count):
		var row := (i / 2) + 1  # Номер ряда (1, 1, 2, 2, 3, 3...)
		var is_left := (i % 2) == 0  # Чередуем левую и правую стороны

		# Смещение назад от игрока
		var back_offset := -forward * (row * ROW_SPACING)

		# Смещение влево/вправо
		var side_offset := right * (COLUMN_OFFSET if not is_left else -COLUMN_OFFSET)

		# Финальная позиция
		var pos := player_pos + back_offset + side_offset
		pos.y = player_pos.y + HEIGHT_OFFSET  # Немного выше для спавна

		# Создаём трансформацию с правильным поворотом
		var transform := Transform3D()
		transform.origin = pos

		# Поворот в направлении движения
		# + PI чтобы -Z (forward VehicleBody3D) смотрел в направлении движения
		var yaw := atan2(forward.x, forward.z) + PI
		transform.basis = Basis(Vector3.UP, yaw)

		positions.append(transform)

	return positions


## Отладочная визуализация стартовой сетки
## Возвращает строку с описанием позиций
static func debug_grid_layout(count: int) -> String:
	var lines := ["Стартовая сетка:"]
	lines.append("        [Игрок]           <- Ряд 0")

	var row := 1
	var i := 0
	while i < count:
		var row_str := "    "
		if i < count:
			row_str += "[AI %d]  " % (i + 1)
			i += 1
		else:
			row_str += "        "

		if i < count:
			row_str += "[AI %d]" % (i + 1)
			i += 1

		row_str += "        <- Ряд %d (-%dм)" % [row, row * int(ROW_SPACING)]
		lines.append(row_str)
		row += 1

	return "\n".join(lines)
