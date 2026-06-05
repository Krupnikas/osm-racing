extends Node3D
## Постоянный менеджер интерактивного реквизита (урны, конусы, мешки…).
##
## НЕ привязан к чанкам — поэтому объекты не пропадают при перегенерации/тримминге
## чанков (именно из-за этого падали площадки дорожных работ). Терреногенератор
## РЕГИСТРИРУЕТ «дремлющие» записи (только позиции), а реальные RigidBody этот узел
## создаёт лишь рядом с игроком и убирает вдали. Записи постоянны, поэтому реквизит
## стабильно появляется снова, когда игрок возвращается.

const ACTIVATE_R := 140.0      # ближе этого — спавним инстанс
const DEACTIVATE_R := 175.0    # дальше этого — убираем (гистерезис)
const SCAN_INTERVAL := 0.2     # как часто пересматриваем записи (сек)
const BUILD_BUDGET := 6        # макс. инстансов за один скан (без спайков)

var _terrain: Node3D                 # OSMTerrain — строит инстансы и сэмплит высоту
var _player: Node3D
var _records: Array = []             # [{type:String, pos:Vector2, instance:RigidBody3D|null}]
var _seen: Dictionary = {}           # "type:ix:iz" -> true (дедуп)
var _scan_accum := 0.0


func setup(terrain: Node3D) -> void:
	_terrain = terrain


## Регистрирует дремлющую запись реквизита (идемпотентно по округлённой позиции).
func register(type: String, pos: Vector2) -> void:
	var key := "%s:%d:%d" % [type, int(pos.x), int(pos.y)]
	if _seen.has(key):
		return
	_seen[key] = true
	_records.append({"type": type, "pos": pos, "instance": null})


func _process(delta: float) -> void:
	if _terrain == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	_scan_accum += delta
	if _scan_accum < SCAN_INTERVAL:
		return
	_scan_accum = 0.0

	var pp := Vector2(_player.global_position.x, _player.global_position.z)
	var act2 := ACTIVATE_R * ACTIVATE_R
	var deact2 := DEACTIVATE_R * DEACTIVATE_R
	var built := 0
	for rec in _records:
		var d2: float = pp.distance_squared_to(rec.pos)
		if rec.instance == null:
			if d2 < act2 and built < BUILD_BUDGET:
				rec.instance = _build(rec)
				if rec.instance != null:
					built += 1
		elif d2 > deact2:
			if is_instance_valid(rec.instance):
				rec.instance.queue_free()
			rec.instance = null


func _build(rec: Dictionary) -> RigidBody3D:
	var pos: Vector2 = rec.pos
	var elev: float = _terrain._sample_elevation(pos.x, pos.y)
	var rot: float = float(int(absf(pos.x * 11.0 + pos.y * 17.0)) % 360) * (PI / 180.0)
	match rec.type:
		"bin":
			return _terrain._create_bin_immediate(pos, elev, rot, self)
		"cone":
			return _terrain._create_cone_immediate(pos, elev, rot, self)
	return null


## Полный сброс (при смене локации).
func clear_all() -> void:
	for rec in _records:
		if rec.instance != null and is_instance_valid(rec.instance):
			rec.instance.queue_free()
	_records.clear()
	_seen.clear()
	_scan_accum = 0.0
