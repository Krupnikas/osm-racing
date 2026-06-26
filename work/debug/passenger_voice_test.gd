extends Node

## Headless-тест PassengerVoice — проверяет автомат воспроизведения, выбор клипа,
## фиксацию голоса, даккинг и безопасность при отсутствии ассета БЕЗ реальной поездки.
## Запуск: Godot --headless --path . res://work/debug/passenger_voice_test.tscn

const PassengerVoiceScript = preload("res://work/passenger_voice.gd")
const FakeWM := preload("res://work/debug/fake_work_manager.gd")

var _pass := 0
var _fail := 0


func _ready() -> void:
	var fake := FakeWM.new()
	add_child(fake)
	var car := _FakeCar.new()
	add_child(car)

	var pv: Node = PassengerVoiceScript.new()
	pv.name = "PassengerVoice"
	add_child(pv)
	pv.setup(fake, car)

	# --- старт поездки с фиксированным голосом ---
	fake.state = 2  # DRIVING
	fake.voice = "oleg"
	fake.order_accepted.emit(450, "ул. Ленина")
	_check("voice locked to oleg", pv._voice == "oleg")

	# 1) торможение → играет, дак вкл, клип oleg/breaking
	pv.debug_trigger("brake")
	var s1: Dictionary = pv.debug_state()
	_check("brake playing", s1.is_playing == true)
	_check("brake duck ON", s1.ducked == true)
	_check("brake clip = oleg/breaking", String(s1.stream).contains("/oleg/breaking-"))

	# 2) второй триггер во время речи → ОТБРОШЕН (стрим не меняется)
	var stream_before: String = String(s1.stream)
	pv.debug_trigger("speed")
	var s2: Dictionary = pv.debug_state()
	_check("overlap discarded (still playing)", s2.is_playing == true)
	_check("overlap discarded (stream unchanged)", String(s2.stream) == stream_before)

	# 3) клип кончился → не играет, дак выкл
	pv._on_finished()
	var s3: Dictionary = pv.debug_state()
	_check("after finish not playing", s3.is_playing == false)
	_check("after finish duck OFF", s3.ducked == false)

	# 4) speed → speeding клип
	pv.debug_trigger("speed")
	var s4: Dictionary = pv.debug_state()
	_check("speed playing", s4.is_playing == true)
	_check("speed clip = oleg/speeding", String(s4.stream).contains("/oleg/speeding-"))
	pv._on_finished()

	# 5) offroad → not-on-road клип
	pv.debug_trigger("offroad")
	var s5: Dictionary = pv.debug_state()
	_check("offroad clip = oleg/not-on-road", String(s5.stream).contains("/oleg/not-on-road-"))
	pv._on_finished()

	# 6) анти-повтор: 12 торможений подряд без немедленного дубля
	var seen := {}
	var prev := ""
	var immediate_repeat := false
	for _i in range(12):
		pv.debug_trigger("brake")
		var st := String(pv.debug_state().stream)
		seen[st] = true
		if st == prev:
			immediate_repeat = true
		prev = st
		pv._on_finished()
	_check("no immediate clip repeat", not immediate_repeat)
	_check("brake used >=2 distinct clips", seen.size() >= 2)

	# 7) несуществующий голос → не падает, не играет, нет дака
	pv.debug_set_voice("nonexistent")
	pv.debug_trigger("brake")
	var s7: Dictionary = pv.debug_state()
	_check("missing voice: not playing", s7.is_playing == false)
	_check("missing voice: duck OFF", s7.ducked == false)

	# 8) конец поездки очищает голос/речь/дак
	pv.debug_set_voice("oleg")
	pv.debug_trigger("brake")
	fake.order_completed.emit({})
	var s8: Dictionary = pv.debug_state()
	_check("trip end cleared voice", String(s8.voice) == "")
	_check("trip end stopped speech", s8.is_playing == false)
	_check("trip end duck OFF", s8.ducked == false)

	print("\n[PVTEST] PASS=%d FAIL=%d  %s" % [_pass, _fail, "OK" if _fail == 0 else "FAILURES!"])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(label: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("[PVTEST] ok   - %s" % label)
	else:
		_fail += 1
		print("[PVTEST] FAIL - %s" % label)


class _FakeCar extends Node3D:
	var linear_velocity := Vector3.ZERO
