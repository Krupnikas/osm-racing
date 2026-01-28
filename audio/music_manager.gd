extends Node

## Глобальный менеджер фоновой музыки
## Управляет плейлистом и автоматическим переключением треков

# Сигнал для уведомления о начале трека
signal track_started(track_name: String, artist: String)

# Playlist с путями к аудио файлам
var playlist: Array[String] = []
var current_track_index: int = 0

# Информация о треках (artist, title)
var track_info := {
	"petya_pavlov_ya_hochu_skorosti.ogg": ["Петя Павлов", "Я хочу скорости"],
	"kristalniy_metod_rodilsya_medlennym.ogg": ["Кристальный метод", "Рожденный медленным"],
	"stariy_pes_i_dimon_morison_vsadniki_grozy.ogg": ["Старый Пёс и Димон Морисон", "Всадники грозы"],
	"element_80_s_menya_hvatit.ogg": ["Элемент-80", "С меня хватит"],
}

# Audio player
var music_player: AudioStreamPlayer

# Настройки
var volume_db: float = -5.0  # Громкость музыки

func _ready() -> void:
	# Создаём основной music player
	music_player = AudioStreamPlayer.new()
	music_player.bus = "Music"
	music_player.volume_db = volume_db
	music_player.process_mode = Node.PROCESS_MODE_ALWAYS  # Работает даже во время паузы
	add_child(music_player)

	# Подключаем сигнал окончания трека
	music_player.finished.connect(_on_track_finished)

	# Инициализируем playlist
	_initialize_playlist()

	# Запускаем первый трек
	play_track(0)

func _initialize_playlist() -> void:
	"""Инициализирует список треков"""
	playlist = [
		"res://audio/music/petya_pavlov_ya_hochu_skorosti.ogg",
		"res://audio/music/kristalniy_metod_rodilsya_medlennym.ogg",
		"res://audio/music/stariy_pes_i_dimon_morison_vsadniki_grozy.ogg",
		"res://audio/music/element_80_s_menya_hvatit.ogg",
	]

func play_track(index: int) -> void:
	"""Воспроизводит трек по индексу"""
	if index < 0 or index >= playlist.size():
		return

	current_track_index = index
	var track_path := playlist[index]

	# Загружаем аудио файл
	var stream := load(track_path) as AudioStream
	if not stream:
		push_error("MusicManager: Failed to load track: %s" % track_path)
		return

	music_player.stream = stream
	music_player.play()

	# Получаем информацию о треке
	var filename := track_path.get_file()
	var info: Array = track_info.get(filename, ["Unknown Artist", "Unknown Track"])
	var artist: String = info[0]
	var title: String = info[1]

	print("MusicManager: Now playing track %d: %s - %s" % [index, artist, title])

	# Отправляем сигнал
	track_started.emit(title, artist)

func _on_track_finished() -> void:
	"""Вызывается когда трек заканчивается"""
	# Переходим к следующему треку
	play_next_track()

func play_next_track() -> void:
	"""Переключается на следующий трек в плейлисте"""
	current_track_index = (current_track_index + 1) % playlist.size()
	play_track(current_track_index)

func play_random_track() -> void:
	"""Переключается на случайный трек (отличный от текущего)"""
	if playlist.size() <= 1:
		play_track(0)
		return
	var new_index := current_track_index
	while new_index == current_track_index:
		new_index = randi() % playlist.size()
	play_track(new_index)

func play_previous_track() -> void:
	"""Переключается на предыдущий трек"""
	current_track_index = (current_track_index - 1 + playlist.size()) % playlist.size()
	play_track(current_track_index)

func stop_music() -> void:
	"""Останавливает музыку"""
	music_player.stop()

func set_volume(db: float) -> void:
	"""Устанавливает громкость музыки в dB"""
	volume_db = db
	music_player.volume_db = db

func add_track(track_path: String) -> void:
	"""Добавляет трек в плейлист"""
	if not playlist.has(track_path):
		playlist.append(track_path)
		print("MusicManager: Added track: %s" % track_path.get_file())

func get_current_track_name() -> String:
	"""Возвращает имя текущего трека"""
	if current_track_index >= 0 and current_track_index < playlist.size():
		return playlist[current_track_index].get_file().get_basename()
	return ""
