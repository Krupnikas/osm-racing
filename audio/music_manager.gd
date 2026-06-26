extends Node

## Глобальный менеджер фоновой музыки
## Управляет плейлистом и автоматическим переключением треков

# Сигнал для уведомления о начале трека
signal track_started(track_name: String, artist: String)

enum Category { MENU, RACE, WORK }

# Главная тема — всегда играет первой при запуске игры
const MAIN_THEME := "res://audio/music/petya_pavlov_ya_hochu_skorosti.mp3"

# Информация о треках: filename -> [artist, title, category]
var track_info := {
	"petya_pavlov_ya_hochu_skorosti.mp3": ["Петя Павлов", "Я хочу скорости", Category.MENU],
	"maloy_dzhon_ron_don_don_5.mp3": ["Малой Джон", "Рон дон дон 5", Category.MENU],
	"nate_pyos_zhmi_na_gaz.mp3": ["Нате Пёс", "Жми на газ", Category.MENU],
	"stariy_pes_i_dimon_morison_vsadniki_grozy.mp3": ["Старый Пёс и Димон Морисон", "Всадники грозы", Category.MENU],
	"ti_35.mp3": ["ТИ", "35", Category.MENU],
	"chernoglazik_nakachay_ego.mp3": ["Черноглазик", "Накачай его", Category.WORK],
	"kristalniy_metod_rodilsya_medlennym.mp3": ["Кристальный метод", "Рожденный медленным", Category.RACE],
	"element_80_s_menya_hvatit.mp3": ["Элемент-80", "С меня хватит", Category.RACE],
	"tuhliy_bez_kontrolya.mp3": ["Тухлый", "Без контроля", Category.RACE],
	"luka_fiasko_v_tilte.mp3": ["Лука Фиаско", "В тильте", Category.RACE],
	"rps_delay_delo.mp3": ["Р₽С", "Делай дело (feat. Молодой Дро)", Category.MENU],
	"lihoy_bugi_klikuha_moya.mp3": ["Лихой Буги", "Кликуха Моя", Category.RACE],
	"staticheskiy_he_edinstvenniy.mp3": ["Статический Хэ", "Единственный", Category.RACE],
	"dvuhpoloska.mp3": ["Двухполоска", "Двухполоска", Category.RACE],
	"istoriya_goda_i_geroy_utonet.mp3": ["История года", "И герой утонет", Category.RACE],
	"reper_petya_s_nitryachkom.mp3": ["Рэпер Петя", "С нитрячком!", Category.RACE],
	"fond_aziatskogo_dublyazha_krepost_evropy.mp3": ["Фонд Азиатского Дубляжа", "Крепость Европа", Category.RACE],
}

const ALL_CATEGORIES: int = -1
var current_category: int = Category.MENU
var current_track_path: String = ""
var music_player: AudioStreamPlayer

# Дакинг под речь пассажира («Извоз»): приглушаем ОФФСЕТ плеера, а не громкость
# шины «Music» (она — пользовательская настройка). Restore всегда в 0.0.
const SPEECH_DUCK_DB := -7.0
var _speech_ducked := false
var _duck_tween: Tween

func _ready() -> void:
	music_player = AudioStreamPlayer.new()
	music_player.bus = "Music"
	music_player.volume_db = 0.0
	music_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(music_player)
	music_player.finished.connect(_on_track_finished)

	# Главная тема первой
	_play_path(MAIN_THEME)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_M:
			play_next_track()

func set_category(category: int) -> void:
	if current_category == category:
		return
	current_category = category
	play_next_track()

func play_next_track() -> void:
	var tracks := _get_category_tracks(current_category)
	if tracks.is_empty():
		return
	if tracks.size() == 1:
		_play_path(tracks[0])
		return
	var next := tracks[randi() % tracks.size()]
	while next == current_track_path:
		next = tracks[randi() % tracks.size()]
	_play_path(next)

func play_random_track() -> void:
	play_next_track()

func play_previous_track() -> void:
	play_next_track()

func stop_music() -> void:
	music_player.stop()

## Лёгкий даккинг музыки на время реплики пассажира. Тянем volume_db ПЛЕЕРА
## (база 0.0) — относительно пользовательской громкости шины «Music».
func set_speech_duck(on: bool) -> void:
	if _speech_ducked == on:
		return
	_speech_ducked = on
	if not is_instance_valid(music_player):
		return
	if _duck_tween and _duck_tween.is_valid():
		_duck_tween.kill()
	var target: float = SPEECH_DUCK_DB if on else 0.0
	var dur: float = 0.2 if on else 0.4
	_duck_tween = create_tween()
	_duck_tween.tween_property(music_player, "volume_db", target, dur)

func get_current_track_name() -> String:
	return current_track_path.get_file().get_basename()

func _on_track_finished() -> void:
	play_next_track()

func _play_path(path: String) -> void:
	var stream := load(path) as AudioStream
	if not stream:
		push_error("MusicManager: Failed to load track: %s" % path)
		return

	current_track_path = path
	music_player.stream = stream
	music_player.play()

	var filename := path.get_file()
	var info: Array = track_info.get(filename, ["Unknown Artist", "Unknown Track", Category.RACE])
	var artist: String = info[0]
	var title: String = info[1]

	var cat_name: String = "all" if current_category == ALL_CATEGORIES else Category.keys()[current_category].to_lower()
	print("MusicManager: Now playing: %s - %s [%s]" % [artist, title, cat_name])
	track_started.emit(title, artist)

func _get_category_tracks(category: int) -> Array[String]:
	var result: Array[String] = []
	for filename: String in track_info:
		if category == ALL_CATEGORIES:
			result.append("res://audio/music/" + filename)
		elif track_info[filename][2] == category:
			result.append("res://audio/music/" + filename)
	return result
