extends CanvasLayer
## Живой оверлей слежения за ИИ-соперниками (для визуальной проверки рулёжки в гонке).
##
## По каждому сопернику показывает в реальном времени:
##   руль    — команда рулежки [-1..1] (главное: не должна прыгать в упор ±1)
##   скорость— км/ч
##   снос    — боковое смещение от осевой маршрута, м
##   рысканье— число смен знака руля за последнее окно (высокое = виляет/синусоида)
## Подсветка: зелёный ≤2, жёлтый ≤5, красный >5 смен.
##
## Ничего в логике ИИ НЕ меняет — только читает. Инжектится в main.tscn на время гонки.

const WINDOW := 1.2  # окно подсчёта смен знака руля, c

var _rt: RichTextLabel
var _hist: Dictionary = {}   # instance_id -> {t:Array, s:Array}
var _t := 0.0
var _player: Node3D = null


func _ready() -> void:
	layer = 128
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true
	_rt.fit_content = true
	_rt.scroll_active = false
	_rt.custom_minimum_size = Vector2(600, 0)
	_rt.position = Vector2(20, 130)
	_rt.add_theme_font_size_override("normal_font_size", 17)
	_rt.add_theme_font_size_override("bold_font_size", 17)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_content_margin_all(10)
	_rt.add_theme_stylebox_override("normal", bg)
	add_child(_rt)


func _process(delta: float) -> void:
	_t += delta
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()

	var opponents := get_tree().get_nodes_in_group("race_opponent")
	opponents.sort_custom(func(a, b): return float(a.race_progress) > float(b.race_progress))

	var lines: Array = ["[b]ГОНЩИКИ — руль / скорость / снос / рысканье[/b]"]
	var place := 1
	for opp in opponents:
		if not is_instance_valid(opp):
			continue
		var id := opp.get_instance_id()
		if not _hist.has(id):
			_hist[id] = {"t": [], "s": []}
		var h: Dictionary = _hist[id]
		var steer: float = opp.steering_input
		var t_buf: Array = h["t"]
		var s_buf: Array = h["s"]
		t_buf.append(_t)
		s_buf.append(steer)
		while t_buf.size() > 0 and _t - float(t_buf[0]) > WINDOW:
			t_buf.pop_front()
			s_buf.pop_front()

		var flips := 0
		var last_sign := 0
		for sv in s_buf:
			if absf(sv) > 0.03:
				var sg := 1 if sv > 0.0 else -1
				if last_sign != 0 and sg != last_sign:
					flips += 1
				last_sign = sg

		var rname: String = opp.racer_name
		var spd: float = opp.current_speed_kmh
		var lat: float = opp._cur_lateral_offset
		var dist_txt := ""
		if _player and is_instance_valid(_player):
			dist_txt = "  %4.0f м от вас" % opp.global_position.distance_to(_player.global_position)

		var col := "#66ff66"
		if flips > 5:
			col = "#ff5555"
		elif flips > 2:
			col = "#ffcc44"

		lines.append("P%d [b]%s[/b]   %3.0f км/ч   руль %+.2f   снос %.1f м   [color=%s]рысканье %d[/color]%s" % [
			place, rname, spd, steer, lat, col, flips, dist_txt])
		place += 1

	if opponents.is_empty():
		lines.append("[color=#ff8888]нет активных соперников (гонка ещё не идёт?)[/color]")

	_rt.text = "\n".join(lines)


func _find_player() -> Node3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var stack: Array = [scene]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n is Vehicle:
			return n
		for c in n.get_children():
			stack.append(c)
	return null
