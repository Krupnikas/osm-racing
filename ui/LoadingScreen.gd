# LoadingScreen.gd — centered "ЗАГРУЗКА" title + 40 chevron segments +
# percent + pulsing dots. API: set_progress(0..1).
extends Control

const SegmentChevron   = preload("res://ui/components/segment_chevron.gd")
const RadialGlowShader = preload("res://ui/radial_glow.gdshader")

@export_range(0.0, 1.0) var progress : float = 0.68 : set = _set_progress

const SEG_COUNT : int = 40
const PULSE_PERIOD : float = 1.2

@onready var _bar          : HBoxContainer = $Center/BarHolder/Bar
@onready var _percent_rich : RichTextLabel = $Center/PercentRowHolder/PercentRow/PercentRich
@onready var _segLabel     : Label         = $Center/PercentRowHolder/PercentRow/SegLabel
@onready var _dots         : HBoxContainer = $Center/DotsHolder/Dots

var _segs      : Array[Control] = []
var _dot_slots : Array[Control] = []
var _t : float = 0.0

func _ready() -> void:
	for i in range(SEG_COUNT):
		var s := SegmentChevron.new()
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.custom_minimum_size = Vector2(0, 22)
		s.fill_color = UI.INK_300
		s.skew_px = 8.0
		_bar.add_child(s)
		_segs.append(s)

	for i in range(3):
		_dots.add_child(_make_dot_slot(UI.NEON_MAGENTA))

	_apply_progress()
	set_process(true)


func _make_dot_slot(color: Color) -> Control:
	var slot_size := 26.0
	var dot_size := 14.0
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(slot_size, slot_size)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var glow := ColorRect.new()
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gm := ShaderMaterial.new()
	gm.shader = RadialGlowShader
	gm.set_shader_parameter("glow_color", color)
	gm.set_shader_parameter("falloff_pow", 6.0)
	gm.set_shader_parameter("intensity", 0.8)
	glow.material = gm
	slot.add_child(glow)

	var dot := SegmentChevron.new()
	dot.custom_minimum_size = Vector2(dot_size, dot_size)
	dot.size = Vector2(dot_size, dot_size)
	dot.fill_color = color
	dot.skew_px = 5.0
	dot.position = Vector2((slot_size - dot_size) * 0.5, (slot_size - dot_size) * 0.5)
	slot.add_child(dot)

	_dot_slots.append(slot)
	return slot


func _set_progress(v: float) -> void:
	progress = clamp(v, 0.0, 1.0)
	if is_node_ready(): _apply_progress()


func set_progress(v: float) -> void:
	_set_progress(v)


func _apply_progress() -> void:
	var filled: int = int(round(progress * SEG_COUNT))
	for i in range(_segs.size()):
		_segs[i].fill_color = UI.NEON_CYAN if i < filled else UI.INK_300
	if _percent_rich:
		var cyan_hex: String = UI.NEON_CYAN.to_html(false)
		var dim_hex: String  = UI.INK_500.to_html(false)
		_percent_rich.text = "[right][font_size=22][color=#%s]%d[/color][/font_size][font_size=12][color=#%s]%%[/color][/font_size][/right]" % [cyan_hex, int(round(progress * 100.0)), dim_hex]
	if _segLabel: _segLabel.text = "// %d / %d" % [filled, SEG_COUNT]


func _process(delta: float) -> void:
	_t += delta
	for i in range(_dot_slots.size()):
		var phase: float = fmod(_t / PULSE_PERIOD + float(i) * 0.33, 1.0)
		var s: float = max(0.0, sin(phase * PI))
		var a: float = 0.05 + 0.95 * s
		_dot_slots[i].modulate.a = a
