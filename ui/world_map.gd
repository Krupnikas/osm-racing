extends Control

## Интерактивная карта мира на основе OSM raster tiles
## Pan: перетаскивание ЛКМ, Zoom: колесо / кнопки +/−, Клик: поставить флажок

signal location_selected(lat: float, lon: float)

# === TILE CONFIG ===
const TILE_SIZE := 256
const TILE_URL := "https://tile.openstreetmap.org/%d/%d/%d.png"
const TILE_CACHE_DIR := "user://map_tiles/"
const MIN_ZOOM := 3
const MAX_ZOOM := 15
const DEFAULT_ZOOM := 6
const MAX_CONCURRENT := 8
const MAX_CACHED_TEX := 200

# === STATE ===
var _zoom: int = DEFAULT_ZOOM
var _center_lat: float = 59.15
var _center_lon: float = 37.95
var _dragging_map := false
var _dragging_marker := false
var _drag_start: Vector2 = Vector2.ZERO
var _selected_marker: Vector2 = Vector2.ZERO  # lat, lon (0,0 = нет)

# Tile management
var _tile_container: Control
var _overlay: Control
var _loaded_tiles: Dictionary = {}
var _pending_requests: Dictionary = {}
var _tex_cache: Dictionary = {}
var _request_queue: Array = []

# UI buttons (добавляются как children)
var _btn_plus: Button
var _btn_minus: Button

# === CITY DATA ===
const GAME_LOCATIONS := {
	"Череповец": [59.150, 37.949],
	"Москва": [55.861, 37.600],
	"Тбилиси": [41.724, 44.731],
	"Дубай": [25.209, 55.344],
}

const REFERENCE_CITIES := {
	"Санкт-Петербург": [59.93, 30.32],
	"Минск": [53.90, 27.57],
	"Киев": [50.45, 30.52],
	"Стамбул": [41.01, 28.98],
	"Варшава": [52.23, 21.01],
	"Бухарест": [44.43, 26.10],
	"Хельсинки": [60.17, 24.94],
	"Баку": [40.41, 49.87],
	"Тегеран": [35.69, 51.39],
	"Каир": [30.04, 31.24],
	"Эр-Рияд": [24.71, 46.68],
}


# === TILE MATH ===

static func _lat_lon_to_tile(lat: float, lon: float, z: int) -> Vector2:
	var n := pow(2.0, z)
	var x := (lon + 180.0) / 360.0 * n
	var lat_rad := deg_to_rad(lat)
	var y := (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n
	return Vector2(x, y)


func _lat_lon_to_screen(lat: float, lon: float) -> Vector2:
	var center_tile := _lat_lon_to_tile(_center_lat, _center_lon, _zoom)
	var point_tile := _lat_lon_to_tile(lat, lon, _zoom)
	var diff := (point_tile - center_tile) * TILE_SIZE
	return size / 2.0 + diff


func _screen_to_lat_lon(screen_pos: Vector2) -> Vector2:
	var center_tile := _lat_lon_to_tile(_center_lat, _center_lon, _zoom)
	var diff := (screen_pos - size / 2.0) / TILE_SIZE
	var target := center_tile + diff
	var n := pow(2.0, _zoom)
	var lon := target.x / n * 360.0 - 180.0
	var lat_rad := atan(sinh(PI * (1.0 - 2.0 * target.y / n)))
	return Vector2(rad_to_deg(lat_rad), lon)


# === LIFECYCLE ===

func _ready() -> void:
	if not DirAccess.dir_exists_absolute(TILE_CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(TILE_CACHE_DIR)

	clip_contents = true
	mouse_filter = MOUSE_FILTER_STOP  # Перехватываем _gui_input

	# Tile container
	_tile_container = Control.new()
	_tile_container.name = "TileContainer"
	_tile_container.set_anchors_preset(PRESET_FULL_RECT)
	_tile_container.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_tile_container)

	# Overlay для маркеров/подписей
	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_preset(PRESET_FULL_RECT)
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_on_overlay_draw)
	add_child(_overlay)

	# Кнопки зума (+/−)
	_btn_plus = Button.new()
	_btn_plus.text = "+"
	_btn_plus.custom_minimum_size = Vector2(50, 50)
	_btn_plus.size = Vector2(50, 50)
	_btn_plus.add_theme_font_size_override("font_size", 32)
	_btn_plus.pressed.connect(_on_zoom_in)
	add_child(_btn_plus)

	_btn_minus = Button.new()
	_btn_minus.text = "−"
	_btn_minus.custom_minimum_size = Vector2(50, 50)
	_btn_minus.size = Vector2(50, 50)
	_btn_minus.add_theme_font_size_override("font_size", 32)
	_btn_minus.pressed.connect(_on_zoom_out)
	add_child(_btn_minus)

	_position_zoom_buttons()
	_update_tiles()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_position_zoom_buttons()


func _position_zoom_buttons() -> void:
	if not _btn_plus or not _btn_minus:
		return
	_btn_plus.position = Vector2(size.x - 70, size.y / 2.0 - 60)
	_btn_minus.position = Vector2(size.x - 70, size.y / 2.0 + 10)


func _process(_delta: float) -> void:
	if not _request_queue.is_empty() and _pending_requests.size() < MAX_CONCURRENT:
		var batch_count := mini(_request_queue.size(), MAX_CONCURRENT - _pending_requests.size())
		for i in range(batch_count):
			var req: Dictionary = _request_queue.pop_front()
			if _loaded_tiles.has(req.key) and not _pending_requests.has(req.key):
				_fetch_tile_network(req.key, req.tx, req.ty)


# === TILE LOADING ===

func _update_tiles() -> void:
	var screen_size := size
	if screen_size.x < 1 or screen_size.y < 1:
		return

	var center_tile := _lat_lon_to_tile(_center_lat, _center_lon, _zoom)
	var half_x := int(ceil(screen_size.x / TILE_SIZE / 2.0)) + 1
	var half_y := int(ceil(screen_size.y / TILE_SIZE / 2.0)) + 1
	var cx := int(floor(center_tile.x))
	var cy := int(floor(center_tile.y))
	var frac_x := center_tile.x - cx
	var frac_y := center_tile.y - cy
	var n := int(pow(2, _zoom))

	var visible_keys: Dictionary = {}

	for dx in range(-half_x, half_x + 1):
		for dy in range(-half_y, half_y + 1):
			var tx := (cx + dx) % n
			if tx < 0:
				tx += n
			var ty := cy + dy
			if ty < 0 or ty >= n:
				continue

			var key := "%d/%d/%d" % [_zoom, tx, ty]
			visible_keys[key] = true

			var sx := screen_size.x / 2.0 + (dx - frac_x) * TILE_SIZE
			var sy := screen_size.y / 2.0 + (dy - frac_y) * TILE_SIZE

			if _loaded_tiles.has(key):
				var rect: TextureRect = _loaded_tiles[key]
				if is_instance_valid(rect):
					rect.position = Vector2(sx, sy)
			else:
				_load_tile(key, tx, ty, Vector2(sx, sy))

	var to_remove: Array = []
	for key in _loaded_tiles:
		if not visible_keys.has(key):
			to_remove.append(key)
	for key in to_remove:
		var rect: TextureRect = _loaded_tiles[key]
		if is_instance_valid(rect):
			rect.queue_free()
		_loaded_tiles.erase(key)

	_overlay.queue_redraw()


func _load_tile(key: String, tx: int, ty: int, screen_pos: Vector2) -> void:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(TILE_SIZE, TILE_SIZE)
	rect.size = Vector2(TILE_SIZE, TILE_SIZE)
	rect.position = screen_pos
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = MOUSE_FILTER_IGNORE
	_tile_container.add_child(rect)
	_loaded_tiles[key] = rect

	# 1. Memory cache
	if _tex_cache.has(key):
		rect.texture = _tex_cache[key]
		return

	# 2. Disk cache
	var cache_path := TILE_CACHE_DIR + key.replace("/", "_") + ".png"
	if FileAccess.file_exists(cache_path):
		var img := Image.new()
		if img.load(ProjectSettings.globalize_path(cache_path)) == OK:
			var tex := ImageTexture.create_from_image(img)
			rect.texture = tex
			_tex_cache[key] = tex
			return

	# 3. Network
	if _pending_requests.has(key):
		return
	if _pending_requests.size() >= MAX_CONCURRENT:
		_request_queue.append({"key": key, "tx": tx, "ty": ty})
		return
	_fetch_tile_network(key, tx, ty)


func _fetch_tile_network(key: String, tx: int, ty: int) -> void:
	var parts := key.split("/")
	var z := int(parts[0])
	var url := TILE_URL % [z, tx, ty]
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	_pending_requests[key] = http

	var cache_path := TILE_CACHE_DIR + key.replace("/", "_") + ".png"
	http.request_completed.connect(_on_tile_downloaded.bind(key, cache_path, http))
	http.request(url, ["User-Agent: OSMRacing/0.1"])


func _on_tile_downloaded(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray, key: String, cache_path: String, http: HTTPRequest) -> void:
	_pending_requests.erase(key)
	if is_instance_valid(http):
		http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return

	var img := Image.new()
	if img.load_png_from_buffer(body) != OK:
		return

	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex

	if _loaded_tiles.has(key):
		var rect: TextureRect = _loaded_tiles[key]
		if is_instance_valid(rect):
			rect.texture = tex

	# Save to disk
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if file:
		file.store_buffer(body)
		file.close()

	# LRU eviction
	if _tex_cache.size() > MAX_CACHED_TEX:
		var oldest: String = _tex_cache.keys()[0]
		_tex_cache.erase(oldest)


# === INPUT ===

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Проверяем: клик по существующему маркеру? → начинаем drag маркера
				if _selected_marker != Vector2.ZERO:
					var marker_screen := _lat_lon_to_screen(_selected_marker.x, _selected_marker.y)
					if mb.position.distance_to(marker_screen) < 25.0:
						_dragging_marker = true
						accept_event()
						return
				_dragging_map = true
				_drag_start = mb.position
			else:
				if _dragging_marker:
					_dragging_marker = false
					# Финальная позиция маркера
					var geo := _screen_to_lat_lon(mb.position)
					_selected_marker = Vector2(geo.x, geo.y)
					location_selected.emit(geo.x, geo.y)
					_overlay.queue_redraw()
				elif _dragging_map:
					# Если не двигали — это клик: ставим маркер
					if mb.position.distance_to(_drag_start) < 5.0:
						_place_marker(mb.position)
					_dragging_map = false
			accept_event()

		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, -1)
			accept_event()

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging_marker:
			# Перетаскиваем маркер
			var geo := _screen_to_lat_lon(motion.position)
			_selected_marker = Vector2(geo.x, geo.y)
			location_selected.emit(geo.x, geo.y)
			_overlay.queue_redraw()
			accept_event()
		elif _dragging_map:
			_pan_by_pixels(motion.relative)
			accept_event()

	elif event is InputEventPanGesture:
		# Тачпад: двухпальцевое перетаскивание = пан
		var pan := event as InputEventPanGesture
		_pan_by_pixels(-pan.delta * 15.0)
		accept_event()

	elif event is InputEventMagnifyGesture:
		# Тачпад: pinch-to-zoom
		var mag := event as InputEventMagnifyGesture
		if mag.factor > 1.0:
			_zoom_at(mag.position, 1)
		elif mag.factor < 1.0:
			_zoom_at(mag.position, -1)
		accept_event()


func _place_marker(screen_pos: Vector2) -> void:
	# Сначала проверяем клик по игровой локации
	for city_name in GAME_LOCATIONS:
		var coords: Array = GAME_LOCATIONS[city_name]
		var city_screen := _lat_lon_to_screen(coords[0], coords[1])
		if screen_pos.distance_to(city_screen) < 30.0:
			_selected_marker = Vector2(coords[0], coords[1])
			location_selected.emit(coords[0], coords[1])
			_overlay.queue_redraw()
			return

	# Ставим маркер в любое место
	var geo := _screen_to_lat_lon(screen_pos)
	_selected_marker = Vector2(geo.x, geo.y)
	location_selected.emit(geo.x, geo.y)
	_overlay.queue_redraw()


func _pan_by_pixels(delta: Vector2) -> void:
	var n := pow(2.0, _zoom)
	var dlon := -delta.x / TILE_SIZE / n * 360.0
	var center_tile := _lat_lon_to_tile(_center_lat, _center_lon, _zoom)
	var new_tile_y := center_tile.y - delta.y / TILE_SIZE
	var lat_rad := atan(sinh(PI * (1.0 - 2.0 * new_tile_y / n)))
	_center_lat = clamp(rad_to_deg(lat_rad), -85.0, 85.0)
	_center_lon = wrapf(_center_lon + dlon, -180.0, 180.0)
	_update_tiles()


func _zoom_at(mouse_pos: Vector2, delta: int) -> void:
	var old_zoom := _zoom
	_zoom = clampi(_zoom + delta, MIN_ZOOM, MAX_ZOOM)
	if _zoom == old_zoom:
		return

	var geo := _screen_to_lat_lon(mouse_pos)
	_clear_all_tiles()

	# Keep point under cursor fixed
	_center_lat = geo.x
	_center_lon = geo.y
	var screen_center := size / 2.0
	var pixel_offset := mouse_pos - screen_center
	var n := pow(2.0, _zoom)
	var dlon := pixel_offset.x / TILE_SIZE / n * 360.0
	var center_tile := _lat_lon_to_tile(_center_lat, _center_lon, _zoom)
	var new_tile_y := center_tile.y + pixel_offset.y / TILE_SIZE
	var lat_rad := atan(sinh(PI * (1.0 - 2.0 * new_tile_y / n)))
	_center_lat = clamp(rad_to_deg(lat_rad), -85.0, 85.0)
	_center_lon = wrapf(_center_lon + dlon, -180.0, 180.0)

	_update_tiles()


func _on_zoom_in() -> void:
	_zoom_at(size / 2.0, 1)


func _on_zoom_out() -> void:
	_zoom_at(size / 2.0, -1)


func _clear_all_tiles() -> void:
	for key in _loaded_tiles:
		var rect: TextureRect = _loaded_tiles[key]
		if is_instance_valid(rect):
			rect.queue_free()
	_loaded_tiles.clear()
	for key in _pending_requests:
		var http: HTTPRequest = _pending_requests[key]
		if is_instance_valid(http):
			http.queue_free()
	_pending_requests.clear()
	_request_queue.clear()


# === DRAW OVERLAY ===

func _on_overlay_draw() -> void:
	var w := size.x
	var h := size.y

	# Top bar
	_overlay.draw_rect(Rect2(0, 0, w, 40), Color(0, 0, 0, 0.6))
	var coords_text := "%.4f, %.4f   Zoom: %d" % [_center_lat, _center_lon, _zoom]
	_overlay.draw_string(ThemeDB.fallback_font, Vector2(10, 28), coords_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)

	# Crosshair
	var cx := w / 2.0
	var cy := h / 2.0
	_overlay.draw_line(Vector2(cx - 12, cy), Vector2(cx + 12, cy), Color(1, 1, 1, 0.5), 1.0)
	_overlay.draw_line(Vector2(cx, cy - 12), Vector2(cx, cy + 12), Color(1, 1, 1, 0.5), 1.0)

	# Game location markers (золотые)
	for city_name in GAME_LOCATIONS:
		var coords: Array = GAME_LOCATIONS[city_name]
		var sp := _lat_lon_to_screen(coords[0], coords[1])
		if _is_on_screen(sp):
			_draw_game_marker(sp, city_name)

	# Reference cities (серые, zoom >= 4)
	if _zoom >= 4:
		for city_name in REFERENCE_CITIES:
			var coords: Array = REFERENCE_CITIES[city_name]
			var sp := _lat_lon_to_screen(coords[0], coords[1])
			if _is_on_screen(sp):
				_draw_ref_label(sp, city_name)

	# Выбранный маркер (красный флажок)
	if _selected_marker != Vector2.ZERO:
		var sp := _lat_lon_to_screen(_selected_marker.x, _selected_marker.y)
		if _is_on_screen(sp):
			# Ножка флажка
			_overlay.draw_line(sp, sp + Vector2(0, -30), Color(0.9, 0.1, 0.1), 2.5)
			# Флажок (треугольник)
			var flag_pts := PackedVector2Array([
				sp + Vector2(0, -30),
				sp + Vector2(18, -24),
				sp + Vector2(0, -18),
			])
			_overlay.draw_colored_polygon(flag_pts, Color(1.0, 0.15, 0.15))
			# Основание
			_overlay.draw_circle(sp, 4.0, Color(0.9, 0.1, 0.1))

	# Bottom hint bar
	_overlay.draw_rect(Rect2(0, h - 35, w, 35), Color(0, 0, 0, 0.6))
	var hint := "Кликните чтобы поставить флажок | Перетащите флажок для точной позиции"
	var font := ThemeDB.fallback_font
	var hint_size := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
	_overlay.draw_string(font, Vector2((w - hint_size.x) / 2.0, h - 12), hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.8, 0.8))


func _draw_game_marker(pos: Vector2, city_name: String) -> void:
	var marker_color := Color(1.0, 0.7, 0.0)
	_overlay.draw_circle(pos, 8.0, marker_color)
	_overlay.draw_arc(pos, 10.0, 0, TAU, 24, Color.WHITE, 2.0)

	var font := ThemeDB.fallback_font
	var label_pos := pos + Vector2(14, 5)
	var text_size := font.get_string_size(city_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
	_overlay.draw_rect(Rect2(label_pos.x - 4, label_pos.y - text_size.y - 2,
			text_size.x + 8, text_size.y + 6), Color(0, 0, 0, 0.7))
	_overlay.draw_string(font, label_pos, city_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)


func _draw_ref_label(pos: Vector2, city_name: String) -> void:
	_overlay.draw_circle(pos, 3.0, Color(0.7, 0.7, 0.7, 0.8))
	_overlay.draw_string(ThemeDB.fallback_font, pos + Vector2(6, 4), city_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.85, 0.85, 0.85, 0.85))


func _is_on_screen(pos: Vector2) -> bool:
	return pos.x >= -50 and pos.x <= size.x + 50 and pos.y >= -50 and pos.y <= size.y + 50


# === PUBLIC API ===

func show_map() -> void:
	visible = true
	_selected_marker = Vector2.ZERO
	_dragging_map = false
	_dragging_marker = false
	_update_tiles()


func hide_map() -> void:
	visible = false
	_dragging_map = false
	_dragging_marker = false
	for key in _pending_requests:
		var http: HTTPRequest = _pending_requests[key]
		if is_instance_valid(http):
			http.queue_free()
	_pending_requests.clear()
	_request_queue.clear()


func center_on(lat: float, lon: float, zoom: int = -1) -> void:
	_center_lat = lat
	_center_lon = lon
	if zoom > 0:
		_zoom = clampi(zoom, MIN_ZOOM, MAX_ZOOM)
	_clear_all_tiles()
	_update_tiles()
