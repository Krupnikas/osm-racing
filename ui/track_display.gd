extends CanvasLayer

## Track ticker: corner-bracket reveal animation per design spec.
##
## Phases (asymmetric in/out):
##   1 FADE IN   (500ms) — TL+BR brackets appear tucked together at frame TL
##   2 EXPAND   (1000ms) — BR slides to frame BR; frame fades in (delay 380ms,
##                         320ms), label fades in (delay 460ms, 320ms)
##   3 HOLD     (show_duration)
##   4 COLLAPSE (1100ms) — label fades out (200ms), then frame (240ms),
##                         then BR returns to tucked (delay 280ms, 1000ms)
##   5 FADE OUT (500ms)  — both brackets fade

const FRAME_LEFT := 90.0
const FRAME_BOTTOM := -96.0
const FRAME_HEIGHT := 38.0
const FRAME_WIDTH := 580.0
const PAD := 9.0
const BSIZE := 15.0
const BTHICK := 2.0

# Computed once in _ready
var _frame_top: float
var _tl_pos: Vector2
var _br_tucked: Vector2
var _br_expanded: Vector2

var frame: Panel
var label: Label
var tl_bracket: Control
var br_bracket: Control

var show_duration: float = 5.0
var _anim: Tween
var _play_id: int = 0


func _ready() -> void:
	_frame_top = -FRAME_HEIGHT + FRAME_BOTTOM   # frame.offset_top relative to viewport bottom
	_tl_pos       = Vector2(FRAME_LEFT - 1.0,                    _frame_top - 1.0)
	_br_tucked    = Vector2(_tl_pos.x + BSIZE + 2.0,             _tl_pos.y + BSIZE + 2.0)
	_br_expanded  = Vector2(FRAME_LEFT + FRAME_WIDTH - BSIZE + 1.0, FRAME_BOTTOM - BSIZE + 1.0)

	# Frame
	frame = Panel.new()
	frame.name = "Frame"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = UI.INK_300
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	frame.add_theme_stylebox_override("panel", sb)
	frame.anchor_left = 0.0
	frame.anchor_top = 1.0
	frame.anchor_right = 0.0
	frame.anchor_bottom = 1.0
	frame.offset_left   = FRAME_LEFT
	frame.offset_top    = _frame_top
	frame.offset_right  = FRAME_LEFT + FRAME_WIDTH
	frame.offset_bottom = FRAME_BOTTOM
	frame.modulate.a = 0.0
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	label = Label.new()
	label.name = "Label"
	label.theme_type_variation = &"MonoLabel"
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", UI.INK_700)
	label.anchor_left = 0.0
	label.anchor_top = 0.0
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = PAD
	label.offset_right = -PAD
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.modulate.a = 0.0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(label)

	tl_bracket = _make_bracket(true)
	tl_bracket.name = "TLBracket"
	add_child(tl_bracket)
	_set_bracket_pos(tl_bracket, _tl_pos)
	tl_bracket.modulate.a = 0.0

	br_bracket = _make_bracket(false)
	br_bracket.name = "BRBracket"
	add_child(br_bracket)
	_set_bracket_pos(br_bracket, _br_tucked)
	br_bracket.modulate.a = 0.0

	await get_tree().process_frame
	if has_node("/root/MusicManager"):
		var mm = get_node("/root/MusicManager")
		if mm.has_signal("track_started"):
			mm.track_started.connect(_on_track_started)
			var idx: int = mm.current_track_index
			if idx >= 0 and idx < mm.playlist.size():
				var fname: String = mm.playlist[idx].get_file()
				var info: Array = mm.track_info.get(fname, ["Unknown Artist", "Unknown Track"])
				_on_track_started(info[1], info[0])


func _make_bracket(is_top_left: bool) -> Control:
	# 16x16 control with 2 colored rects forming an L. is_top_left=true → L sits
	# at top-left corner; false → L sits at bottom-right corner.
	var c := Control.new()
	c.custom_minimum_size = Vector2(BSIZE, BSIZE)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var horiz := ColorRect.new()
	horiz.color = UI.NEON_CYAN
	horiz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	horiz.size = Vector2(BSIZE, BTHICK)
	if is_top_left:
		horiz.position = Vector2(0, 0)
	else:
		horiz.position = Vector2(0, BSIZE - BTHICK)
	c.add_child(horiz)

	var vert := ColorRect.new()
	vert.color = UI.NEON_CYAN
	vert.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vert.size = Vector2(BTHICK, BSIZE)
	if is_top_left:
		vert.position = Vector2(0, 0)
	else:
		vert.position = Vector2(BSIZE - BTHICK, 0)
	c.add_child(vert)

	return c


func _set_bracket_pos(b: Control, pos: Vector2) -> void:
	# All brackets use anchor bottom-left of viewport so y is offset-from-bottom.
	b.anchor_left = 0.0
	b.anchor_top = 1.0
	b.anchor_right = 0.0
	b.anchor_bottom = 1.0
	b.offset_left   = pos.x
	b.offset_top    = pos.y
	b.offset_right  = pos.x + BSIZE
	b.offset_bottom = pos.y + BSIZE


func _tween_bracket_to(tw: Tween, b: Control, pos: Vector2, dur: float, delay: float = 0.0) -> void:
	var tl := tw.tween_property(b, "offset_left", pos.x, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if delay > 0.0: tl.set_delay(delay)
	var tt := tw.tween_property(b, "offset_top", pos.y, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if delay > 0.0: tt.set_delay(delay)
	var tr := tw.tween_property(b, "offset_right", pos.x + BSIZE, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if delay > 0.0: tr.set_delay(delay)
	var tb := tw.tween_property(b, "offset_bottom", pos.y + BSIZE, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if delay > 0.0: tb.set_delay(delay)


func _on_track_started(track_name: String, artist: String) -> void:
	label.text = ("СЕЙЧАС ИГРАЕТ · %s — %s" % [artist, track_name]).to_upper()
	_play()


func _play() -> void:
	if _anim and _anim.is_valid():
		_anim.kill()

	_play_id += 1
	var my_id := _play_id

	# Reset state
	_set_bracket_pos(br_bracket, _br_tucked)
	tl_bracket.modulate.a = 0.0
	br_bracket.modulate.a = 0.0
	frame.modulate.a = 0.0
	label.modulate.a = 0.0

	# Phase 1 — fade in brackets together
	_anim = create_tween().set_parallel()
	_anim.tween_property(tl_bracket, "modulate:a", 1.0, 0.5)
	_anim.tween_property(br_bracket, "modulate:a", 1.0, 0.5)
	await _anim.finished
	if my_id != _play_id: return

	# Phase 2 — BR slides; frame + label fade in with offsets
	_anim = create_tween().set_parallel()
	_tween_bracket_to(_anim, br_bracket, _br_expanded, 1.0)
	_anim.tween_property(frame, "modulate:a", 1.0, 0.32).set_delay(0.38)
	_anim.tween_property(label, "modulate:a", 1.0, 0.32).set_delay(0.46)
	await _anim.finished
	if my_id != _play_id: return

	# Phase 3 — HOLD
	await get_tree().create_timer(show_duration).timeout
	if my_id != _play_id: return

	# Phase 4 — collapse: label out → frame out → BR retracts
	_anim = create_tween().set_parallel()
	_anim.tween_property(label, "modulate:a", 0.0, 0.2)
	_anim.tween_property(frame, "modulate:a", 0.0, 0.24).set_delay(0.05)
	_tween_bracket_to(_anim, br_bracket, _br_tucked, 1.0, 0.28)
	await _anim.finished
	if my_id != _play_id: return

	# Phase 5 — fade out brackets
	_anim = create_tween().set_parallel()
	_anim.tween_property(tl_bracket, "modulate:a", 0.0, 0.5)
	_anim.tween_property(br_bracket, "modulate:a", 0.0, 0.5)
	await _anim.finished


func show_track(track_name: String, artist: String) -> void:
	_on_track_started(track_name, artist)
