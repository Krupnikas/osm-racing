extends Node

## Превью-харнесс для work_hud.gd (work/debug). Рендерит ОДНО состояние и
## выходит (процесс убивается после каждого скрина — по требованию).
## Использует НАСТОЯЩИЙ work_hud.gd, не дублирует его.
##
## Запуск:
##   Godot --path . res://work/debug/work_hud_preview.tscn -- \
##     --card=order|trip|result [--result=good|bad] [--night] --out=res://...png

const FakeWM := preload("res://work/debug/fake_work_manager.gd")
const WorkHud := preload("res://work/work_hud.gd")


func _ready() -> void:
	var args := _parse_args()
	var card: String = args.get("card", "order")
	var night: bool = args.has("night") or str(args.get("theme", "day")) == "night"
	var result_kind: String = str(args.get("result", "good"))
	var out: String = str(args.get("out", "res://artifacts/work_hud_preview/%s_%s.png" % [card, "night" if night else "day"]))

	DisplayServer.window_set_size(Vector2i(1280, 720))

	# Фон-доска, как в HTML-эталоне (чтобы полупрозрачность карточек читалась честно).
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.067, 0.071, 0.086) if night else Color(0.33, 0.345, 0.365)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var fake := FakeWM.new()
	add_child(fake)

	var hud: CanvasLayer = WorkHud.new()
	add_child(hud)
	hud.setup(fake)
	if night:
		hud.set_night(true)

	match card:
		"order":
			fake.state = 0
			hud.show_order_popup("ул. Ленина, д. 42", 450, 330.0, 2300.0)
		"trip":
			var c := Node3D.new()
			add_child(c)
			c.global_position = Vector3.ZERO
			fake.car = c
			fake.dropoff = Vector3(1100.0, 0.0, 0.0)
			fake.dest = "ул. Ленина"
			fake.elapsed = 192.0
			fake.estimated = 330.0
			fake.speed_pct = 0.8
			fake.safe_pct = 1.0
			fake.state = 2  # DRIVING → _process покажет карточку
			hud._on_bonus_updated(0.8, 1.0)
		"result":
			fake.state = 3
			if result_kind == "bad":
				hud.show_order_result({
					"stars": 1, "phrase": "Ужасная поездка!",
					"fare": 450, "speed_bonus": 0, "speed_pct": 0.0,
					"safe_bonus": 0, "safe_pct": 0.0, "total": 450})
			else:
				hud.show_order_result({
					"stars": 4, "phrase": "Спасибо, отличная поездка!",
					"fare": 450, "speed_bonus": 90, "speed_pct": 1.0,
					"safe_bonus": 90, "safe_pct": 1.0, "total": 630})

	await _capture(out)
	get_tree().quit()


func _capture(out_path: String) -> void:
	# Дать вёрстке разложиться (CenterContainer/min-size считаются с задержкой).
	for _i in range(5):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var abs_path := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := img.save_png(abs_path)
	print("[preview] saved=%s err=%d size=%s" % [abs_path, err, img.get_size()])


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var body := a.substr(2)
			if "=" in body:
				var kv := body.split("=", false, 1)
				out[kv[0]] = kv[1] if kv.size() > 1 else true
			else:
				out[body] = true
	return out
