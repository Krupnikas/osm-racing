extends Node3D
class_name OSMTerrainGenerator

signal initial_load_started
signal initial_load_progress(progress: float, status: String)  # 0.0-1.0 прогресс + текст статуса
signal initial_load_complete

const OSMLoaderScript = preload("res://osm/osm_loader.gd")
const TextureGeneratorScript = preload("res://textures/texture_generator.gd")
const BuildingWallShader = preload("res://osm/building_wall.gdshader")
const BuildingWallCustomShader = preload("res://osm/building_wall_custom.gdshader")
const WetRoadMaterial = preload("res://night_mode/wet_road_material.gd")
const EntranceGroupGenerator = preload("res://osm/entrance_group_generator.gd")
const MarsEntranceGeneratorScript = preload("res://osm/mars_entrance_generator.gd")
const LEAF_TREE_SCENE = preload("res://models/trees/leaf/scene.gltf")
const PINE_TREE_SCENE = preload("res://models/trees/pine/scene.gltf")
const TreeBillboardShader = preload("res://shaders/tree_billboard.gdshader")
const BUS_STOP_SCENE = preload("res://models/bus_stop/scene.gltf")
const GARBAGE_CONTAINER_SCENE = preload("res://models/garbage_container/scene.gltf")
const STREET_LAMP_SCENE = preload("res://models/street_lamp/Lone_Street_Lamp_on_Hex_post.glb")
const TireTrackManagerScript = preload("res://tracks/tire_track_manager.gd")
const CROSSING_SIGN_TEXTURE = preload("res://textures/signs/pedestrian_crossing.png")
const PARKING_SIGN_TEXTURE = preload("res://textures/signs/parking.png")
const DecorationLayerScript = preload("res://osm/decoration_layer.gd")


# Decoration Layer для добавления атмосферы поверх OSM данных
var _decoration_layer: Node = null  # DecorationLayer

# Кэш текстур (создаются один раз)
var _road_textures: Dictionary = {}
var _building_textures: Dictionary = {}
var _window_shader: Shader = null  # Кэш шейдера окон (создается один раз)
var _shop_back_wall_shader: Shader = null  # Кэш шейдера задней стенки магазина
var _ground_textures: Dictionary = {}
var _normal_textures: Dictionary = {}  # Normal maps
var _noise_textures: Dictionary = {}  # Noise textures for road shader
var _ground_shader_material: ShaderMaterial = null  # Shared material for all grass chunks
var _textures_initialized := false

# Текстуры люков
var _manhole_albedo: Texture2D
var _manhole_normal: Texture2D
var _manhole_opacity: Texture2D

@export var start_lat := 59.150066
@export var start_lon := 37.949370
var _lon_scale := 0.0  # Cached cos(deg_to_rad(start_lat)) * 111000.0
@export var chunk_size := 300.0  # Размер чанка в метрах
@export var load_distance := 500.0  # Дистанция подгрузки чанков
@export var unload_distance := 800.0  # Дистанция выгрузки чанков
@export var render_distance := 400.0  # Дальность прорисовки (и начало тумана)
@export var fog_enabled := true  # Включить туман для скрытия края мира
@export var car_path: NodePath
@export var camera_path: NodePath
@export var debug_print := false  # Выключить debug output для производительности

## Feature Flags для A/B тестирования производительности
@export_group("Features", "enable_")
@export var enable_buildings := true  # Включить здания
@export var enable_windows := true  # Включить окна в зданиях
@export var enable_roads := true  # Включить дороги
@export var enable_curbs := true  # Включить бордюры
@export var enable_vegetation := true  # Включить деревья/растительность
@export var enable_street_lamps := true  # Включить уличные фонари
@export var enable_traffic_signs := true  # Включить дорожные знаки
@export var enable_traffic_lights := true  # Включить светофоры
@export var enable_night_mode_windows := true  # Включить подсветку окон ночью
@export var enable_frustum_culling := true  # Включить frustum culling чанков
@export var enable_manholes := true  # Включить люки на дорогах
@export var enable_crossing_signs := true  # Включить знаки пешеходных переходов
@export var manhole_spacing := 100.0  # Расстояние между люками (метры)

## Тестовый режим: провайдер данных вместо HTTP (Callable(lat, lon, size) -> Dictionary)
var test_data_provider: Callable = Callable()
## Тестовый режим: провайдер высот (Callable(chunk_key, lat, lon) -> Dictionary)

var osm_loader: Node
var _car: Node3D
var _camera: Camera3D
var _profiler: PerformanceProfiler  # Для измерения производительности
var _loaded_chunks: Dictionary = {}  # key: "x,z" -> value: Node3D (chunk node)
var _loading_chunks: Dictionary = {}  # key: "x,z" -> value: timestamp (start time in msec)
const CHUNK_LOAD_TIMEOUT := 30.0  # Таймаут загрузки чанка (секунд)
var _last_check_pos := Vector3.ZERO
var _check_interval := 0.5  # Проверка каждые 0.5 сек
var _check_timer := 0.0
var _chunks_to_unload: Array[String] = []  # Очередь на выгрузку (1 чанк за кадр)
var _initial_loading := false  # Флаг начальной загрузки
var _initial_chunks_needed: Array[String] = []  # Чанки нужные для старта
var _initial_chunks_loaded: int = 0  # Количество загруженных начальных чанков
var _loading_paused := false  # Загрузка НЕ на паузе - автоматический старт
var _load_generation := 0  # Инкрементируется при reset для игнорирования старых callback'ов
var _entrance_nodes: Array = []  # Входы в здания/заведения из OSM
var _poi_nodes: Array = []  # Точечные заведения (shop/amenity как node)
var _parking_polygons: Array[PackedVector2Array] = []  # Полигоны парковок для исключения фонарей
var _parking_bounds: Array = []  # Cached {center: Vector2, radius: float} per parking polygon
var _parking_spatial_hash: Dictionary = {}  # Spatial hash: Vector2i → Array of {polygon_idx: int, p1: Vector2, p2: Vector2}
const PARKING_CELL_SIZE := 30.0
var _road_segments: Array = []  # Сегменты дорог для позиционирования знаков парковки
var _road_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска дорог
const ROAD_CELL_SIZE := 20.0  # Размер ячейки spatial hash для дорог
var _building_segments: Array = []  # Сегменты стен зданий {p1: Vector2, p2: Vector2}
var _building_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска зданий
const BUILDING_CELL_SIZE := 20.0  # Размер ячейки spatial hash для зданий
var _intersection_positions: Array[Vector2] = []  # Позиции перекрёстков (центры)
var _intersection_radii: Array[Vector2] = []  # Полуоси эллипсов (x=вдоль широкой дороги, y=вдоль узкой)
var _intersection_angles: Array[float] = []  # Углы поворота эллипсов (радианы, направление широкой дороги)
var _intersection_types: Array[bool] = []  # true = равнозначный (все дороги одного типа)
var _intersection_roads: Array = []  # [i] = [{direction: Vector2, width: float}, ...] — входящие дороги
var _intersection_contours: Array = []  # [i] = PackedVector2Array — контур перекрёстка (или пустой для fallback)
var _intersection_curb_contours: Array = []  # [i] = PackedVector2Array — увеличенный контур для обрезки бордюров
var _intersection_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска перекрёстков
const INTERSECTION_CELL_SIZE := 50.0  # Размер ячейки spatial hash в метрах
var _created_lamp_positions: Dictionary = {}  # Позиции созданных фонарей для избежания дубликатов (ключ: chunk_key)
var _created_sign_positions: Dictionary = {}  # Позиции созданных знаков для избежания дубликатов
var _created_bus_stop_positions: Dictionary = {}  # Позиции созданных остановок для избежания дубликатов
var _custom_model_cache: Dictionary = {}  # path -> PackedScene
var _pending_lamps: Array = []  # Отложенные фонари (создаются после загрузки всех парковок)
var _lamps_created := false  # Флаг что фонари уже созданы
var _pending_parking_signs: Array = []  # Отложенные знаки парковки
var _crossing_sign_front_mat: StandardMaterial3D
var _crossing_sign_back_mat: StandardMaterial3D
var _parking_sign_front_mat: StandardMaterial3D
var _deferred_lamp_queue: Array = []  # Deferred lamp generation from road apply
var _deferred_manhole_queue: Array = []  # Deferred manhole generation from road apply
var _deferred_traffic_queue: Array = []  # Deferred traffic network extraction
var _finalization_state := 0  # 0=not started, 1=lamps, 2=signs, 3=done

# Многопоточная генерация зданий
var _building_queue: Array = []  # Очередь данных зданий для генерации
var _building_results: Array = []  # Готовые данные мешей из потоков
var _building_mutex: Mutex  # Для синхронизации доступа к результатам
var _pending_building_tasks: int = 0  # Счётчик активных задач в пуле
var _last_queue_size: int = 0  # Для отслеживания прогресса очереди
var _queue_stuck_time: float = 0.0  # Время зависания очереди
const QUEUE_STUCK_TIMEOUT := 5.0  # Таймаут зависшей очереди (секунд)

# Отложенная генерация инфраструктуры (фонари, знаки, светофоры)
var _infrastructure_queue: Array = []  # Очередь {type, pos, elevation, parent, ...}

# Camera-based frustum culling для чанков
var _culling_camera: Camera3D = null  # Ссылка на камеру для culling
var _culling_update_timer: float = 0.0  # Таймер обновления culling
const CULLING_UPDATE_INTERVAL := 0.2  # Обновлять каждые 200ms (5 раз в секунду)

var _culling_debug_counter := 0

# Отложенная генерация дорог и других тяжёлых объектов
var _road_queue: Array = []  # Очередь {nodes, tags, parent}
var _road_queue_sorted := false
var _curb_queue: Array = []  # Очередь бордюров (создаются после детекции перекрёстков)

# Threaded road processing — smoothing + geometry in worker threads
var _road_mutex: Mutex
var _road_results: Array = []  # Готовые результаты из worker threads
var _pending_road_tasks: int = 0  # Счётчик активных задач

# Road batching system - накопление geometry данных для mesh merging
var _road_batch_data: Dictionary = {}  # key: chunk_key -> { "highway": {vertices, uvs, normals, indices}, "primary": {...}, ...}
var _pending_batch_chunks: Array[String] = []  # Чанки с pending road batches (нужно финализировать)
var _chunk_terrain_roads: Dictionary = {}  # chunk_key → Array[{points: PackedVector2Array, width: float}] — для отложенного выреза террейна

# Window batching system - ONE MultiMesh per chunk instead of per-building
var _window_batch_data: Dictionary = {}  # key: chunk_key -> {transforms: Array[Transform3D], colors: Array[Color], parent: Node3D}
var _window_batch_materials: Array[ShaderMaterial] = []  # Материалы всех window batches для обновления is_night параметра

# BUILDING GEOMETRY MERGE: объединяем все стены/крыши чанка в один ArrayMesh для снижения draw calls
var _building_geo_batch: Dictionary = {}  # chunk_key -> {parent, panel_walls: {verts,uvs,normals,indices}, brick_walls, wall_walls, roofs, collisions, decorations}
var _building_geo_finalize_queue: Array[String] = []  # Очередь chunk_key для финализации
var _window_finalize_queue: Array[String] = []  # Progressive window finalization queue
var _window_finalize_progress: Dictionary = {}  # chunk_key -> {buf, offset, mm, transforms, colors, parent, mat, mm_instance}
var _building_wall_materials: Dictionary = {}  # texture_type -> ShaderMaterial (shared)
var _building_roof_material: StandardMaterial3D = null  # shared
var _building_parapet_material: StandardMaterial3D = null  # shared
var _building_foundation_materials: Array[StandardMaterial3D] = []  # 4 random colors

# ENTRANCE GEOMETRY MERGE: объединяем все подъезды чанка в один ArrayMesh
var _entrance_batch: Dictionary = {}  # chunk_key -> {parent, concrete: {vertices,normals,indices}, red_metal, ...}
var _entrance_lights: Array[OmniLight3D] = []  # Светильники подъездов (для ночного режима)
const ResidentialEntranceScript = preload("res://osm/residential_entrance_generator.gd")

# Lamp lights - для управления ночным режимом
var _lamp_batch_lights: Array[OmniLight3D] = []  # Все OmniLight3D (теперь без батчинга, по одному фонарю за раз)

var _curb_smoothed_queue: Array = []  # Очередь сглаженных бордюров для генерации меша
var _curb_mesh_state: Dictionary = {}  # Текущее состояние генерации меша бордюра (для разбивки по кадрам)
var _curb_geo_batch: Dictionary = {}  # chunk_key -> {parent, vertices, normals, indices}
var _curb_material: StandardMaterial3D = null  # Shared material для всех бордюров

# Vegetation batching system - MultiMesh with LOD
var _tree_batch_data: Dictionary = {}  # key: chunk_key -> {leaf_transforms: [], pine_transforms: [], collisions: [], parent: Node3D}
var _tree_batches_to_finalize: Array[String] = []  # Chunk keys ready for finalization
# Threaded vegetation processing
var _veg_mutex: Mutex
var _veg_thread_results: Array = []  # Готовые результаты из воркер-тредов
var _pending_veg_tasks: int = 0  # Счётчик активных задач
var _tree_mesh_leaf: ArrayMesh  # Меш лиственного дерева LOD0
var _tree_mesh_leaf_lod1: ArrayMesh  # Меш лиственного дерева LOD1 (декимация 50%)
var _tree_mesh_pine: ArrayMesh  # Меш сосны LOD0
var _tree_mesh_pine_lod1: ArrayMesh  # Меш сосны LOD1 (декимация 50%)

# Garbage container mesh
var _garbage_container_mesh: Mesh

# LOD2 billboard meshes
var _tree_billboard_leaf: ArrayMesh  # Billboard cross-plane для leaf
var _tree_billboard_pine: ArrayMesh  # Billboard cross-plane для pine
var _tree_billboard_mat_leaf: ShaderMaterial  # Billboard материал leaf
var _tree_billboard_mat_pine: ShaderMaterial  # Billboard материал pine
# Shadow-only cross meshes (simplified geometry for shadow pass)
var _tree_shadow_mesh_leaf: ArrayMesh
var _tree_shadow_mesh_pine: ArrayMesh

# LOD distances for trees
const TREE_LOD0_END := 50.0    # Full mesh: 0-50m
const TREE_LOD1_BEGIN := 50.0  # Simplified mesh: 50-150m
const TREE_LOD1_END := 150.0
const TREE_LOD2_BEGIN := 150.0 # Billboard: 150-250m
const TREE_LOD2_END := 250.0
# Pine mix ratio in forests
const PINE_MIX_RATIO := 0.15  # 15% сосен среди лиственных
var _tree_simplified := false  # true = процедурный меш, false = GLTF модель

# Lamp batching system - MultiMesh with per-chunk batching
var _lamp_batch_data: Dictionary = {}  # key: chunk_key -> batch data
#   pole_transforms: Array[Transform3D]
#   arm_transforms: Array[Transform3D]
#   globe_transforms: Array[Transform3D]
#   globe_colors: Array[Color]
#   light_data: Array[Dictionary]  # {position: Vector3, broken: bool}
#   parent: Node3D
var _lamp_batches_to_finalize: Array[String] = []  # Chunk keys ready for finalization

# Street lamp model mesh (loaded from GLB, decimated)
var _lamp_model_mesh: ArrayMesh
var _lamp_light_offset := Vector3(0, 6.0, 0)  # Позиция OmniLight3D относительно основания

# Keep for night mode updates and chunk association
var _lamp_lights_by_chunk: Dictionary = {}  # chunk_key -> Array[OmniLight3D]

# Billboard batching - created from DecorationLayer
var _billboard_batches_to_finalize: Array[String] = []  # Chunk keys ready for billboard finalization

# Building shadow LOD - only cast shadows for close buildings
var _building_shadow_lod_distance: float = 300.0  # Chunk center distance for shadow LOD
# Tree shadow LOD - track shadow MultiMesh nodes per chunk
var _chunk_tree_shadow_nodes: Dictionary = {}  # chunk_key -> Array[MultiMeshInstance3D]
var _tree_shadow_lod_distance: float = 300.0

var _curb_collision_results: Array = []  # Результаты расчёта коллизий из worker threads
var _curb_collision_mutex: Mutex  # Для синхронизации доступа к результатам коллизий

# Iron bar fence batching (per-chunk ArrayMesh with LOD)
var _fence_geo_batch: Dictionary = {}  # chunk_key -> {parent, lod0:{vertices,normals,indices}, lod1:{...}}
var _fence_batches_to_finalize: Array[String] = []
var _fence_material: StandardMaterial3D = null

# Метрики времени для профилирования
var _perf_metrics: Dictionary = {}
var _perf_frame_count: int = 0
var _perf_enabled: bool = true

# Подсчет draw calls по категориям (для диагностики)
var _draw_call_stats: Dictionary = {
	"roads": 0,
	"buildings": 0,
	"windows": 0,
	"curbs": 0,
	"lamps": 0,
	"signs": 0,
	"vegetation": 0,
	"terrain": 0,
	"neon_signs": 0,
	"traffic_lights": 0,
	"npc_cars": 0,
	"other": 0
}
var _draw_call_logging_enabled := true  # PHASE 1 DIAGNOSTIC: Track draw calls by category

# Отложенная генерация terrain объектов (natural, landuse, leisure)

var _terrain_objects_queue: Array = []  # Очередь {type, nodes, tags, parent}
# Очередь растительности (деревья, кусты, трава) - обрабатывается отдельно с меньшим приоритетом
var _vegetation_queue: Array = []  # Очередь {type, points, parent, dense}

# FPS статистика для отображения на экране
var _fps_samples: Array[float] = []
var _fps_update_timer := 0.0
var _debug_label: Label = null
var _viewport_rid: RID  # Кешируем viewport RID для CPU/GPU метрик
@export var show_debug_stats := true  # Показывать статистику на экране

# Скользящее окно для per-function breakdown на экране (последние N кадров)
var _perf_window: Dictionary = {}  # name → Array[float] (мс, последние 60 кадров)
const PERF_WINDOW_SIZE := 60  # 1 секунда при 60fps
# Собираем данные текущего кадра для slow-frame лога
var _current_frame_perf: Dictionary = {}  # name → float (мс), заполняется каждый кадр

# Slow frame tracking
var _slow_frame_cooldown := 0.0  # Ограничиваем частоту логирования (не чаще 1 раз в сек)

# Terrain clipping via WorkerThreadPool — результаты из worker потоков
var _terrain_thread_results: Array = []  # Results from terrain worker threads
var _terrain_thread_mutex: Mutex
var _pending_terrain_tasks: int = 0

# Очереди отложенного создания нод (бюджет: N нод за кадр)
var _deferred_building_collisions: Array = []  # [{parent, collisions, idx}]
var _deferred_lamp_lights: Array = []  # [{container, lights, idx, chunk_key, is_night}]
var _deferred_tree_collisions: Array = []  # [{parent, collisions, idx}]
var _deferred_road_collisions: Array = []  # [{body, vertices, indices}]
var _deferred_terrain_collisions: Array = []  # [{parent, vertices, indices}]
var _deferred_footway_queue: Array = []  # [{smoothed_points, width, tags, parent}]
var _deferred_billboard_queue: Array = []  # [{billboard, elevation, parent}]
var _finalize_phase: int = 0  # Round-robin: 0=roads, 1=curbs, 2=lamps, 3=buildings, 4=windows, 5=trees, 6=billboards
var _chunk_activation_pending: Dictionary = {}  # chunk_key -> state (-1=waiting, >=0=RS activation index)

# Global add_child budget — limits scene tree insertions per frame
const ADD_CHILD_BUDGET_PER_FRAME := 2
var _add_child_count: int = 0
var _deferred_add_child_queue: Array = []  # [{parent: Node, child: Node}]

# RenderingServer direct instances — bypass scene tree for zero-spike mesh display
var _chunk_rs_instances: Dictionary = {}  # chunk_key -> Array[RID]
var _chunk_rs_meshes: Dictionary = {}  # chunk_key -> Array[Mesh] (prevent GC)
var _chunk_road_materials: Dictionary = {}  # chunk_key -> Array[ShaderMaterial] (wet mode)
var _chunk_building_rs: Dictionary = {}  # chunk_key -> Array[RID] (shadow LOD)

# Debug визуализация границ чанков
var _show_chunk_boundaries := false
var _chunk_boundary_meshes: Dictionary = {}  # chunk_key -> MeshInstance3D

# Предиктивная загрузка чанков
@export_group("Predictive Loading")
@export var prediction_time_horizon := 15.0  # Горизонт предсказания (секунд)
@export var forward_load_multiplier := 2.0   # Множитель дистанции вперёд
@export var side_load_multiplier := 0.5      # Множитель дистанции сбоку
@export var min_speed_for_prediction := 5.0  # м/с - ниже этого радиальная загрузка

var _smoothed_velocity := Vector3.ZERO
var _velocity_smoothing := 0.7  # Фактор сглаживания скорости
var _chunk_load_queue: Array[Dictionary] = []  # Очередь загрузки {key, priority, distance}
var _current_load_count := 0
const MAX_CONCURRENT_LOADS := 5  # Макс параллельных запросов к OSM API (увеличено для маленьких чанков)
const PREDICTION_INTERVALS := 3  # Точки предсказания (5с, 10с, 15с)

# Сцены для припаркованных машин
var _parked_car_scene: PackedScene
var _parked_lada_scene: PackedScene
var _parked_taxi_scene: PackedScene

# Цвета для припаркованных машин
const PARKED_CAR_COLORS := [
	Color(0.8, 0.1, 0.1),  # Красный
	Color(0.1, 0.3, 0.8),  # Синий
	Color(0.9, 0.9, 0.9),  # Белый
	Color(0.1, 0.1, 0.1),  # Чёрный
	Color(0.5, 0.5, 0.5),  # Серый
	Color(0.2, 0.5, 0.2),  # Зелёный
	Color(0.9, 0.7, 0.1),  # Жёлтый
]

# Цвета для разных типов поверхностей
const COLORS := {
	"road_primary": Color(0.3, 0.3, 0.3),
	"road_secondary": Color(0.4, 0.4, 0.4),
	"road_residential": Color(0.5, 0.5, 0.5),
	"road_path": Color(0.6, 0.5, 0.4),
	"building": Color(0.6, 0.4, 0.3),
	"water": Color(0.2, 0.4, 0.7),
	"grass": Color(0.3, 0.6, 0.3),
	"forest": Color(0.2, 0.5, 0.2),
	"farmland": Color(0.7, 0.7, 0.4),
	"default": Color(0.4, 0.5, 0.4)
}

const ROAD_WIDTHS := {
	"motorway": 16.0,
	"trunk": 14.0,
	"primary": 12.0,
	"secondary": 10.0,
	"tertiary": 8.0,
	"residential": 6.0,
	"unclassified": 5.0,
	"service": 4.0,
	"footway": 2.0,
	"path": 1.5,
	"cycleway": 2.5,
	"track": 3.5
}

# Константы для мостов и туннелей
# Эталон: Северное шоссе (way 63269622) - 107.5м длина, 3м высота
const BRIDGE_REFERENCE_LENGTH := 100.0  # Эталонная длина моста для полной высоты (метры)
const BRIDGE_BASE_HEIGHT := 3.0         # Базовая высота для эталонного моста (метры)
const BRIDGE_MIN_HEIGHT := 0.5          # Минимальная высота моста (метры) - очень пологий
const LAYER_HEIGHT := 3.0               # Высота на один layer (разделение уровней)
const BRIDGE_RAMP_RATIO := 0.4          # Рампа = 40% от длины моста (более пологий подъём)
const BRIDGE_MAX_RAMP := 35.0           # Максимальная длина рампы (метры)
const BRIDGE_MIN_LENGTH_FOR_PILLARS := 60.0  # Минимальная длина моста для опор (метры)
const BRIDGE_PILLAR_SPACING := 20.0     # Расстояние между опорами моста
const BRIDGE_PILLAR_RADIUS := 0.5       # Радиус опоры моста
const BRIDGE_PILLAR_COLOR := Color(0.55, 0.53, 0.5)  # Цвет бетонных опор

func _ready() -> void:
	# Cache cosine for _latlon_to_local (avoids cos() every call)
	_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0

	# Добавляем в группу для поиска из MiniMap
	add_to_group("terrain_generator")

	# Инициализируем mutex для многопоточности
	_building_mutex = Mutex.new()
	_curb_collision_mutex = Mutex.new()
	_road_mutex = Mutex.new()
	_veg_mutex = Mutex.new()
	_terrain_thread_mutex = Mutex.new()

	osm_loader = OSMLoaderScript.new()
	add_child(osm_loader)
	osm_loader.data_loaded.connect(_on_osm_data_loaded)
	osm_loader.load_failed.connect(_on_osm_load_failed)

	# Инициализируем Decoration Layer
	_decoration_layer = DecorationLayerScript.new()
	_decoration_layer.set_terrain_generator(self)
	add_child(_decoration_layer)

	# Создаём debug label для статистики
	if show_debug_stats:
		_create_debug_label()

	# Инициализируем текстуры
	_init_textures()

	# Инициализируем tree meshes для LOD
	_init_tree_meshes()
	_init_tree_billboards()
	_init_garbage_container_mesh()

	# Инициализируем lamp meshes для батчинга
	_init_lamp_meshes()

	# Материалы знака пешеходного перехода (shared)
	_crossing_sign_front_mat = StandardMaterial3D.new()
	_crossing_sign_front_mat.albedo_texture = CROSSING_SIGN_TEXTURE
	_crossing_sign_front_mat.metallic = 0.3
	_crossing_sign_front_mat.roughness = 0.5
	_crossing_sign_back_mat = StandardMaterial3D.new()
	_crossing_sign_back_mat.albedo_color = Color(0.45, 0.45, 0.42)
	_crossing_sign_back_mat.metallic = 0.6
	_crossing_sign_back_mat.roughness = 0.7

	_parking_sign_front_mat = StandardMaterial3D.new()
	_parking_sign_front_mat.albedo_texture = PARKING_SIGN_TEXTURE
	_parking_sign_front_mat.metallic = 0.3
	_parking_sign_front_mat.roughness = 0.5

	# Инициализируем шейдер окон (один раз для всех батчей)
	_init_window_shader()

	# Загружаем сцены для припаркованных машин
	_parked_car_scene = preload("res://traffic/npc_car.tscn")
	_parked_lada_scene = preload("res://traffic/npc_lada_2109.tscn")
	_parked_taxi_scene = preload("res://traffic/npc_taxi.tscn")

	# Найти профайлер для измерения производительности
	_profiler = get_node_or_null("/root/Main/PerformanceProfiler")
	if not _profiler:
		_profiler = get_tree().get_first_node_in_group("profiler")
	if not _profiler:
		# Создать профайлер для диагностики
		var profiler_script = load("res://debug/performance_profiler.gd")
		if profiler_script:
			_profiler = profiler_script.new()
			_profiler.print_interval = 5.0
			add_child(_profiler)
			print("[OSMTerrain] Profiler created for diagnostics")
	if _profiler:
		print("OSMTerrainGenerator: Profiler connected - road performance will be measured")
	else:
		print("OSMTerrainGenerator: WARNING - Profiler not found, performance won't be measured")

	# Найти машину
	if car_path:
		_car = get_node(car_path)
	else:
		# Попробуем найти автоматически
		await get_tree().process_frame
		_car = get_tree().get_first_node_in_group("car")
		if not _car:
			var car_node = get_parent().get_node_or_null("Car")
			if car_node:
				_car = car_node

	# Найти камеру (для загрузки при полёте)
	if camera_path:
		_camera = get_node(camera_path)

	# Tire track manager (грязные следы на траве)
	if _car and _ground_shader_material:
		var track_mgr := TireTrackManagerScript.new()
		track_mgr.name = "TireTrackManager"
		add_child(track_mgr)
		track_mgr.setup(_car, _ground_shader_material)
		print("OSM: TireTrackManager initialized")

	# Подключаемся к NightModeManager
	await get_tree().process_frame
	_connect_to_night_mode()

	# Настраиваем дальность прорисовки и туман
	_setup_render_distance()

	print("OSM: Ready for loading (waiting for start_loading call)...")

func _init_textures() -> void:
	if _textures_initialized:
		return

	print("OSM: Initializing textures...")
	var start_time := Time.get_ticks_msec()

	# Текстуры дорог
	_road_textures["highway"] = TextureGeneratorScript.create_highway_texture(512, 4)
	_road_textures["primary"] = TextureGeneratorScript.create_primary_texture(512, 4)  # Одна сплошная в центре
	_road_textures["residential"] = TextureGeneratorScript.create_road_texture(256, 2, true, false)
	_road_textures["path"] = TextureGeneratorScript.create_sidewalk_texture(256)
	_road_textures["crossing"] = TextureGeneratorScript.create_crossing_texture(256)
	_road_textures["intersection"] = TextureGeneratorScript.create_intersection_texture(256)  # Чистый асфальт

	# Текстуры люков
	_manhole_albedo = load("res://textures/road/manhole/color_alpha.png")
	_manhole_normal = load("res://textures/road/manhole/normal.png")
	print("OSM Manholes: textures loaded - albedo=%s, normal=%s" % [_manhole_albedo != null, _manhole_normal != null])

	# Текстуры зданий (без окон - окна добавляются как 3D объекты)
	# Уменьшено до 256 для performance (было 512)
	_building_textures["panel"] = TextureGeneratorScript.create_panel_building_no_windows(256, 5)
	_building_textures["brick"] = TextureGeneratorScript.create_brick_building_no_windows(256)
	_building_textures["wall"] = TextureGeneratorScript.create_wall_texture(256)
	_building_textures["roof"] = TextureGeneratorScript.create_roof_texture(256)

	# Shared материалы зданий (создаются один раз, переиспользуются для merged meshes)
	for tex_type in ["panel", "brick", "wall"]:
		var mat := ShaderMaterial.new()
		mat.shader = BuildingWallShader
		if _building_textures.has(tex_type):
			mat.set_shader_parameter("albedo_texture", _building_textures[tex_type])
			mat.set_shader_parameter("use_texture", true)
		else:
			mat.set_shader_parameter("albedo_color", Color(0.7, 0.6, 0.5))
			mat.set_shader_parameter("use_texture", false)
		_building_wall_materials[tex_type] = mat

	_building_roof_material = StandardMaterial3D.new()
	_building_roof_material.cull_mode = BaseMaterial3D.CULL_BACK
	if _building_textures.has("roof"):
		_building_roof_material.albedo_texture = _building_textures["roof"]
		_building_roof_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		_building_roof_material.albedo_color = Color(0.15, 0.15, 0.15)

	_building_parapet_material = StandardMaterial3D.new()
	_building_parapet_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_building_parapet_material.albedo_color = Color(0.5, 0.5, 0.5)

	_building_foundation_materials.clear()
	var foundation_colors: Array[Color] = [
		Color(0.4, 0.15, 0.12),   # бордовый
		Color(0.15, 0.3, 0.15),   # тёмно-зелёный
		Color(0.15, 0.15, 0.35),  # тёмно-синий
		Color(0.35, 0.35, 0.35),  # серый
	]
	for fc in foundation_colors:
		var fm := StandardMaterial3D.new()
		fm.cull_mode = BaseMaterial3D.CULL_DISABLED
		fm.albedo_color = fc
		fm.roughness = 0.7  # Дешёвая краска — не гладкая, но слегка блестит
		fm.metallic = 0.05
		fm.metallic_specular = 0.3
		_building_foundation_materials.append(fm)

	# Shared material бордюров
	_curb_material = StandardMaterial3D.new()
	_curb_material.albedo_color = Color(0.78, 0.76, 0.72)
	_curb_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_curb_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS

	# Shared material for iron bar fences
	_fence_material = StandardMaterial3D.new()
	_fence_material.albedo_color = Color(0.25, 0.25, 0.28)
	_fence_material.metallic = 0.35
	_fence_material.roughness = 0.85
	_fence_material.cull_mode = BaseMaterial3D.CULL_BACK

	# Текстуры земли - загружаем PBR текстуру травы (Ground037 — дикая трава с проплешинами)
	var grass_img := Image.load_from_file("res://textures/Ground037_1K-JPG_Color.jpg")
	if grass_img:
		_ground_textures["grass"] = ImageTexture.create_from_image(grass_img)
	else:
		_ground_textures["grass"] = TextureGeneratorScript.create_forest_texture(256)
	var grass_normal_img := Image.load_from_file("res://textures/Ground037_1K-JPG_NormalGL.jpg")
	if grass_normal_img:
		_ground_textures["grass_normal"] = ImageTexture.create_from_image(grass_normal_img)
	var grass_rough_img := Image.load_from_file("res://textures/Ground037_1K-JPG_Roughness.jpg")
	if grass_rough_img:
		_ground_textures["grass_roughness"] = ImageTexture.create_from_image(grass_rough_img)
	_ground_textures["forest"] = TextureGeneratorScript.create_forest_texture(256)
	_ground_textures["water"] = TextureGeneratorScript.create_water_texture(256)

	# Normal maps
	_normal_textures["asphalt"] = TextureGeneratorScript.create_asphalt_normal(256)
	_normal_textures["brick"] = TextureGeneratorScript.create_brick_normal(256)
	_normal_textures["concrete"] = TextureGeneratorScript.create_concrete_normal(256)
	_normal_textures["panel"] = TextureGeneratorScript.create_panel_building_normal(256, 5, 4)  # Было 512

	# Noise текстуры для дорожного шейдера
	_noise_textures["micro"] = TextureGeneratorScript.create_noise_micro(256)
	_noise_textures["macro"] = TextureGeneratorScript.create_noise_macro(512)

	# Shared ground shader material для всех травяных чанков
	var ground_shader := load("res://shaders/ground.gdshader") as Shader
	if ground_shader:
		_ground_shader_material = ShaderMaterial.new()
		_ground_shader_material.shader = ground_shader
		_ground_shader_material.set_shader_parameter("albedo_tex", _ground_textures.get("grass"))
		_ground_shader_material.set_shader_parameter("normal_tex", _ground_textures.get("grass_normal"))
		_ground_shader_material.set_shader_parameter("roughness_tex", _ground_textures.get("grass_roughness"))
		_ground_shader_material.set_shader_parameter("noise_macro_tex", _noise_textures.get("macro"))
		_ground_shader_material.set_shader_parameter("noise_micro_tex", _noise_textures.get("micro"))
		print("OSM: Ground shader material created")

	_textures_initialized = true
	var elapsed := Time.get_ticks_msec() - start_time
	print("OSM: Textures initialized in %d ms" % elapsed)

func _init_window_shader() -> void:
	if _window_shader:
		return

	print("OSM: Initializing window shader (compile once, reuse for all batches)...")
	_window_shader = Shader.new()
	_window_shader.code = """
shader_type spatial;
render_mode specular_schlick_ggx;

uniform bool is_night = false;

void fragment() {
	// Проверяем, выключено ли окно (чёрный цвет = выключено)
	bool is_off = (COLOR.r < 0.01 && COLOR.g < 0.01 && COLOR.b < 0.01);

	// Стекло: высокая отражаемость, низкая шероховатость
	METALLIC = 0.3;
	ROUGHNESS = 0.05;
	SPECULAR = 0.8;

	if (is_night && !is_off) {
		// Ночью включенные окна светятся
		float brightness = COLOR.a;
		ALBEDO = COLOR.rgb * brightness;
		EMISSION = COLOR.rgb * brightness;
		ROUGHNESS = 0.1;
	} else {
		// Днём все окна тёмные и отражающие, ночью выключенные тоже
		ALBEDO = vec3(0.05, 0.07, 0.1);
		EMISSION = vec3(0.0);
	}
}
"""
	print("OSM: Window shader compiled")

func _init_tree_meshes() -> void:
	# Проверяем настройку упрощённых деревьев из конфига
	var use_simplified := false
	var config := ConfigFile.new()
	if config.load("user://graphics.cfg") == OK:
		use_simplified = config.get_value("graphics", "simplified_trees", false)

	if use_simplified:
		_init_tree_meshes_simplified()
		return

	_init_tree_meshes_model()


func _init_tree_meshes_simplified() -> void:
	"""Создаёт упрощённый процедурный меш дерева (ствол + крона) для MultiMesh"""
	print("OSM: Initializing simplified tree mesh...")

	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.3
	trunk.bottom_radius = 0.4
	trunk.height = 5.0
	trunk.radial_segments = 6
	trunk.rings = 1

	var crown := SphereMesh.new()
	crown.radius = 2.8
	crown.height = 5.5
	crown.radial_segments = 8
	crown.rings = 4

	_tree_mesh_leaf = ArrayMesh.new()

	# Surface 0: ствол (сдвинут вверх на 2.5)
	var trunk_arrays := trunk.get_mesh_arrays()
	var trunk_verts: PackedVector3Array = trunk_arrays[Mesh.ARRAY_VERTEX]
	for i in range(trunk_verts.size()):
		trunk_verts[i].y += 2.5
	trunk_arrays[Mesh.ARRAY_VERTEX] = trunk_verts
	_tree_mesh_leaf.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arrays)

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.35, 0.22, 0.1)
	_tree_mesh_leaf.surface_set_material(0, trunk_mat)

	# Surface 1: крона (сдвинута вверх на 6.5)
	var crown_arrays := crown.get_mesh_arrays()
	var crown_verts: PackedVector3Array = crown_arrays[Mesh.ARRAY_VERTEX]
	for i in range(crown_verts.size()):
		crown_verts[i].y += 6.5
	crown_arrays[Mesh.ARRAY_VERTEX] = crown_verts
	_tree_mesh_leaf.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, crown_arrays)

	var crown_mat := StandardMaterial3D.new()
	crown_mat.albedo_color = Color(0.2, 0.5, 0.15)
	_tree_mesh_leaf.surface_set_material(1, crown_mat)

	# Для упрощённого режима pine = leaf и LOD1 = LOD0
	_tree_mesh_pine = _tree_mesh_leaf
	_tree_mesh_leaf_lod1 = _tree_mesh_leaf
	_tree_mesh_pine_lod1 = _tree_mesh_leaf

	_tree_simplified = true
	print("OSM: Simplified tree mesh initialized (trunk + crown, 2 surfaces)")


func _init_tree_meshes_model() -> void:
	"""Загружает leaf и pine модели деревьев с нормализацией pivot + LOD1 декимация"""
	print("OSM: Initializing tree meshes from GLTF models...")

	_tree_mesh_leaf = _load_tree_mesh_normalized(LEAF_TREE_SCENE, 10.0)
	_tree_mesh_leaf_lod1 = _create_lod1_with_trunk(_tree_mesh_leaf, 10.0, 0.7)
	print("OSM: Leaf tree: %d verts, %d tris" % [
		_tree_mesh_leaf.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		_tree_mesh_leaf.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
	])

	_tree_mesh_pine = _load_tree_mesh_normalized(PINE_TREE_SCENE, 12.0)
	_tree_mesh_pine_lod1 = _create_lod1_with_trunk(_tree_mesh_pine, 12.0, 0.55)
	print("OSM: Pine tree: %d verts, %d tris" % [
		_tree_mesh_pine.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		_tree_mesh_pine.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
	])


func _init_garbage_container_mesh() -> void:
	var scene_inst: Node3D = GARBAGE_CONTAINER_SCENE.instantiate()
	var mesh_instances: Array[MeshInstance3D] = []
	_collect_mesh_instances(scene_inst, mesh_instances)
	if mesh_instances.size() > 0:
		_garbage_container_mesh = mesh_instances[0].mesh
		print("OSM: Garbage container mesh loaded: %d surfaces" % _garbage_container_mesh.get_surface_count())
	else:
		push_warning("OSM: Failed to load garbage container mesh")
	scene_inst.queue_free()


## Загружает GLTF сцену дерева, извлекает меш, нормализует pivot (XZ по центру, Y=0 основание)
## и масштабирует до target_height метров
func _load_tree_mesh_normalized(scene: PackedScene, target_height: float) -> ArrayMesh:
	var scene_inst: Node3D = scene.instantiate()
	var mesh_instances: Array[MeshInstance3D] = []
	_collect_mesh_instances(scene_inst, mesh_instances)

	# Собираем все surface с трансформированными вершинами
	var surfaces: Array = []  # [{arrays: Array, material: Material}]

	for mi in mesh_instances:
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var xform := _get_node_transform_recursive(mi)

		for surf_idx in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surf_idx)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var norms = arrays[Mesh.ARRAY_NORMAL]

			# Трансформируем вершины
			var transformed_verts := PackedVector3Array()
			transformed_verts.resize(verts.size())
			for i in range(verts.size()):
				transformed_verts[i] = xform * verts[i]
			arrays[Mesh.ARRAY_VERTEX] = transformed_verts

			# Трансформируем нормали
			if norms != null and norms is PackedVector3Array:
				var normal_basis := xform.basis.inverse().transposed()
				var transformed_norms := PackedVector3Array()
				transformed_norms.resize(norms.size())
				for i in range(norms.size()):
					transformed_norms[i] = (normal_basis * norms[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = transformed_norms

			surfaces.append({
				"arrays": arrays,
				"material": mesh.surface_get_material(surf_idx)
			})

	scene_inst.queue_free()

	# Вычисляем AABB всех поверхностей
	var aabb_min := Vector3(INF, INF, INF)
	var aabb_max := Vector3(-INF, -INF, -INF)
	for surf in surfaces:
		var verts: PackedVector3Array = surf["arrays"][Mesh.ARRAY_VERTEX]
		for v in verts:
			aabb_min.x = min(aabb_min.x, v.x)
			aabb_min.y = min(aabb_min.y, v.y)
			aabb_min.z = min(aabb_min.z, v.z)
			aabb_max.x = max(aabb_max.x, v.x)
			aabb_max.y = max(aabb_max.y, v.y)
			aabb_max.z = max(aabb_max.z, v.z)

	# Нормализация pivot: центр XZ → 0, основание Y → 0
	var center_x := (aabb_min.x + aabb_max.x) / 2.0
	var center_z := (aabb_min.z + aabb_max.z) / 2.0
	var offset := Vector3(center_x, aabb_min.y, center_z)
	var current_height := aabb_max.y - aabb_min.y
	var scale_f := target_height / current_height if current_height > 0.001 else 1.0

	# Применяем нормализацию и масштаб
	var result_mesh := ArrayMesh.new()
	for surf in surfaces:
		var arrays: Array = surf["arrays"]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normalized_verts := PackedVector3Array()
		normalized_verts.resize(verts.size())
		for i in range(verts.size()):
			normalized_verts[i] = (verts[i] - offset) * scale_f
		arrays[Mesh.ARRAY_VERTEX] = normalized_verts

		result_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: Material = surf["material"]
		if mat:
			result_mesh.surface_set_material(result_mesh.get_surface_count() - 1, mat)

	print("OSM: Tree normalized: AABB (%.1f, %.1f, %.1f)→(%.1f, %.1f, %.1f), height %.1f→%.1fm, scale=%.4f" % [
		aabb_min.x, aabb_min.y, aabb_min.z, aabb_max.x, aabb_max.y, aabb_max.z,
		current_height, target_height, scale_f
	])

	return result_mesh


## Создаёт упрощённую копию меша: оставляет каждый N-й треугольник
static func _decimate_mesh(source: ArrayMesh, keep_step: int) -> ArrayMesh:
	var result := ArrayMesh.new()
	for surf_idx in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(surf_idx)
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices != null and indices is PackedInt32Array:
			var src_indices: PackedInt32Array = indices
			var tri_count: int = src_indices.size() / 3
			var new_indices := PackedInt32Array()
			var write_pos := 0
			var tri_idx := 0
			while tri_idx < tri_count:
				var base: int = tri_idx * 3
				new_indices.append(src_indices[base])
				new_indices.append(src_indices[base + 1])
				new_indices.append(src_indices[base + 2])
				write_pos += 3
				tri_idx += keep_step
			arrays[Mesh.ARRAY_INDEX] = new_indices
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := source.surface_get_material(surf_idx)
		if mat:
			result.surface_set_material(result.get_surface_count() - 1, mat)
	return result


## Создаёт LOD1 меш: копия исходного дерева + толстый процедурный цилиндр-ствол для видимости на 50-150м
func _create_lod1_with_trunk(source: ArrayMesh, tree_height: float, trunk_radius: float) -> ArrayMesh:
	var result := ArrayMesh.new()

	# Копируем все surface из исходного меша
	for surf_idx in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(surf_idx)
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := source.surface_get_material(surf_idx)
		if mat:
			result.surface_set_material(result.get_surface_count() - 1, mat)

	# Генерируем цилиндр-ствол
	var segments := 6
	var trunk_height := tree_height * 0.55  # ствол — нижние 55% дерева
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Верхняя и нижняя окружности
	for i in range(segments):
		var angle := float(i) / float(segments) * TAU
		var nx := cos(angle)
		var nz := sin(angle)
		var x := nx * trunk_radius
		var z := nz * trunk_radius
		var normal := Vector3(nx, 0, nz)
		var u := float(i) / float(segments)

		# Нижняя вершина
		verts.append(Vector3(x, 0, z))
		norms.append(normal)
		uvs.append(Vector2(u, 1.0))

		# Верхняя вершина
		verts.append(Vector3(x, trunk_height, z))
		norms.append(normal)
		uvs.append(Vector2(u, 0.0))

	# Индексы боковых граней
	for i in range(segments):
		var bl := i * 2       # bottom-left
		var tl := i * 2 + 1   # top-left
		var br := ((i + 1) % segments) * 2       # bottom-right
		var tr := ((i + 1) % segments) * 2 + 1   # top-right
		indices.append_array([bl, br, tr, bl, tr, tl])

	var trunk_arrays := []
	trunk_arrays.resize(Mesh.ARRAY_MAX)
	trunk_arrays[Mesh.ARRAY_VERTEX] = verts
	trunk_arrays[Mesh.ARRAY_NORMAL] = norms
	trunk_arrays[Mesh.ARRAY_TEX_UV] = uvs
	trunk_arrays[Mesh.ARRAY_INDEX] = indices
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arrays)

	# Коричневый материал для ствола
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.45, 0.3, 0.15)
	trunk_mat.roughness = 1.0
	result.surface_set_material(result.get_surface_count() - 1, trunk_mat)

	return result


## Создаёт cross-plane billboard меш (2 пересекающиеся плоскости) заданного размера
static func _create_billboard_cross_mesh(width: float, height: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var hw := width / 2.0

	# Plane 1: вдоль X (нормаль Z)
	verts.append(Vector3(-hw, 0, 0))
	verts.append(Vector3(hw, 0, 0))
	verts.append(Vector3(hw, height, 0))
	verts.append(Vector3(-hw, height, 0))
	for _i in range(4):
		norms.append(Vector3(0, 0, 1))
	uvs.append(Vector2(0, 1))
	uvs.append(Vector2(1, 1))
	uvs.append(Vector2(1, 0))
	uvs.append(Vector2(0, 0))
	indices.append_array([0, 1, 2, 0, 2, 3])

	# Plane 2: вдоль Z (нормаль X)
	verts.append(Vector3(0, 0, -hw))
	verts.append(Vector3(0, 0, hw))
	verts.append(Vector3(0, height, hw))
	verts.append(Vector3(0, height, -hw))
	for _i in range(4):
		norms.append(Vector3(1, 0, 0))
	uvs.append(Vector2(0, 1))
	uvs.append(Vector2(1, 1))
	uvs.append(Vector2(1, 0))
	uvs.append(Vector2(0, 0))
	indices.append_array([4, 5, 6, 4, 6, 7])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Генерирует процедурную billboard текстуру дерева (овальный силуэт кроны + ствол)
static func _generate_tree_billboard_texture(crown_color: Color, trunk_color: Color, is_conifer: bool) -> ImageTexture:
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)

	# Ствол: узкая полоса внизу по центру
	var trunk_width := 4
	var trunk_height := int(size * 0.35)
	var trunk_top := size - 1
	var trunk_bottom := trunk_top - trunk_height
	for y in range(trunk_bottom, trunk_top + 1):
		for x in range(size / 2 - trunk_width / 2, size / 2 + trunk_width / 2):
			image.set_pixel(x, y, trunk_color)

	# Крона: для лиственного — овал, для хвойного — треугольник
	var crown_center_y := int(size * 0.35)
	if is_conifer:
		# Треугольная крона (конус)
		var tip_y := 2
		var base_y := trunk_bottom
		for y in range(tip_y, base_y):
			var t := float(y - tip_y) / float(base_y - tip_y)
			var half_w := int(t * size * 0.45)
			for x in range(size / 2 - half_w, size / 2 + half_w):
				if x >= 0 and x < size:
					var shade := 0.85 + randf() * 0.15  # Лёгкий шум
					image.set_pixel(x, y, Color(crown_color.r * shade, crown_color.g * shade, crown_color.b * shade, 1.0))
	else:
		# Овальная крона
		var rx := size * 0.42
		var ry := size * 0.35
		for y in range(size):
			for x in range(size):
				var dx := (x - size / 2.0) / rx
				var dy := (y - crown_center_y) / ry
				if dx * dx + dy * dy <= 1.0:
					var shade := 0.85 + randf() * 0.15
					image.set_pixel(x, y, Color(crown_color.r * shade, crown_color.g * shade, crown_color.b * shade, 1.0))

	return ImageTexture.create_from_image(image)


## Инициализирует billboard меши и материалы для LOD2 деревьев
func _init_tree_billboards() -> void:
	if _tree_simplified:
		return

	print("OSM: Initializing tree billboard meshes...")

	# Создаём billboard cross-plane меши
	_tree_billboard_leaf = _create_billboard_cross_mesh(8.0, 10.0)
	_tree_billboard_pine = _create_billboard_cross_mesh(6.0, 12.0)

	# Процедурные placeholder текстуры (заменяются SubViewport рендером позже)
	var leaf_tex := _generate_tree_billboard_texture(
		Color(0.2, 0.45, 0.15), Color(0.35, 0.22, 0.1), false)
	var pine_tex := _generate_tree_billboard_texture(
		Color(0.1, 0.35, 0.12), Color(0.3, 0.2, 0.08), true)

	_tree_billboard_mat_leaf = ShaderMaterial.new()
	_tree_billboard_mat_leaf.shader = TreeBillboardShader
	_tree_billboard_mat_leaf.set_shader_parameter("billboard_texture", leaf_tex)
	_tree_billboard_mat_leaf.set_shader_parameter("alpha_scissor_threshold", 0.5)

	_tree_billboard_mat_pine = ShaderMaterial.new()
	_tree_billboard_mat_pine.shader = TreeBillboardShader
	_tree_billboard_mat_pine.set_shader_parameter("billboard_texture", pine_tex)
	_tree_billboard_mat_pine.set_shader_parameter("alpha_scissor_threshold", 0.5)

	_tree_billboard_leaf.surface_set_material(0, _tree_billboard_mat_leaf)
	_tree_billboard_pine.surface_set_material(0, _tree_billboard_mat_pine)

	# Shadow-only cross meshes with alpha silhouette for realistic shadow shape
	_tree_shadow_mesh_leaf = _create_billboard_cross_mesh(6.0, 10.0)
	_tree_shadow_mesh_pine = _create_billboard_cross_mesh(4.0, 12.0)

	# Shadow materials with tree silhouette alpha textures
	var shadow_leaf_tex := _generate_tree_billboard_texture(
		Color(1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0), false)
	var shadow_pine_tex := _generate_tree_billboard_texture(
		Color(1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0), true)

	var shadow_mat_leaf := StandardMaterial3D.new()
	shadow_mat_leaf.albedo_texture = shadow_leaf_tex
	shadow_mat_leaf.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	shadow_mat_leaf.alpha_scissor_threshold = 0.5
	shadow_mat_leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
	shadow_mat_leaf.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tree_shadow_mesh_leaf.surface_set_material(0, shadow_mat_leaf)

	var shadow_mat_pine := StandardMaterial3D.new()
	shadow_mat_pine.albedo_texture = shadow_pine_tex
	shadow_mat_pine.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	shadow_mat_pine.alpha_scissor_threshold = 0.5
	shadow_mat_pine.cull_mode = BaseMaterial3D.CULL_DISABLED
	shadow_mat_pine.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tree_shadow_mesh_pine.surface_set_material(0, shadow_mat_pine)

	call_deferred("_render_billboard_textures_async")

	print("OSM: Tree billboard meshes ready (SubViewport render deferred)")


## Рендерит billboard текстуру одного дерева через SubViewport (ортогональная камера сбоку)
func _render_single_billboard(tree_mesh: ArrayMesh, height: float) -> ImageTexture:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	# Сначала добавляем viewport в дерево, чтобы look_at работал
	add_child(viewport)

	# Камера ортогональная, смотрит сбоку
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = height * 1.2
	camera.position = Vector3(30, height / 2.0, 0)
	camera.near = 0.1
	camera.far = 100.0
	viewport.add_child(camera)
	camera.look_at(Vector3(0, height / 2.0, 0))

	# Мягкий направленный свет
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -30, 0)
	light.light_energy = 1.2
	viewport.add_child(light)

	# Меш дерева
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = tree_mesh
	viewport.add_child(mesh_inst)

	# Ждём 2 кадра чтобы viewport отрендерился
	await get_tree().process_frame
	await get_tree().process_frame

	var image := viewport.get_texture().get_image()
	viewport.queue_free()

	return ImageTexture.create_from_image(image)


## Async: рендерит billboard текстуры через SubViewport и обновляет материалы
func _render_billboard_textures_async() -> void:
	print("OSM: Starting SubViewport billboard render...")

	var leaf_tex := await _render_single_billboard(_tree_mesh_leaf, 10.0)
	_tree_billboard_mat_leaf.set_shader_parameter("billboard_texture", leaf_tex)

	var pine_tex := await _render_single_billboard(_tree_mesh_pine, 12.0)
	_tree_billboard_mat_pine.set_shader_parameter("billboard_texture", pine_tex)

	print("OSM: Billboard textures updated from SubViewport render")


## Рекурсивно собирает все MeshInstance3D из дерева узлов
static func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, result)


## Вычисляет полный трансформ узла от корня (для узлов не в SceneTree)
static func _get_node_transform_recursive(node: Node3D) -> Transform3D:
	var xform := node.transform
	var parent := node.get_parent()
	while parent != null and parent is Node3D:
		xform = parent.transform * xform
		parent = parent.get_parent()
	return xform

func _init_lamp_meshes() -> void:
	"""Load street lamp GLB model, normalize pivot, decimate for performance"""
	print("OSM: Loading street lamp model from GLB...")

	# Загружаем модель с нормализацией (Y=0 у основания, масштаб до 6м)
	var target_height := 6.0
	_lamp_model_mesh = _load_tree_mesh_normalized(STREET_LAMP_SCENE, target_height)

	# Определяем позицию света — верхняя точка модели
	var aabb := _lamp_model_mesh.get_aabb()
	_lamp_light_offset = Vector3(-0.6, aabb.end.y - 0.3, 0)

	var total_tris := 0
	for s in range(_lamp_model_mesh.get_surface_count()):
		var idx = _lamp_model_mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
		if idx:
			total_tris += idx.size() / 3
	print("OSM: Street lamp model loaded: %d surfaces, %d tris, light at Y=%.1f" % [
		_lamp_model_mesh.get_surface_count(), total_tris, _lamp_light_offset.y
	])

func _process(delta: float) -> void:
	var _frame_start := Time.get_ticks_usec()
	_current_frame_perf.clear()
	_slow_frame_cooldown -= delta

	# Reset add_child budget and drain deferred queue
	_add_child_count = 0
	while not _deferred_add_child_queue.is_empty() and _add_child_count < ADD_CHILD_BUDGET_PER_FRAME:
		var ac_item: Dictionary = _deferred_add_child_queue[0]
		if is_instance_valid(ac_item["parent"]) and is_instance_valid(ac_item["child"]):
			ac_item["parent"].add_child(ac_item["child"])
			_add_child_count += 1
		_deferred_add_child_queue.pop_front()

	# Обрабатываем готовые здания из worker threads (даже на паузе)
	var t0 := Time.get_ticks_usec()
	_process_building_results()
	var t_building := Time.get_ticks_usec() - t0
	_record_perf("building_results", t_building)

	# Общий бюджет на все очереди — 5ms (90fps = 11ms, рендер ~4ms, физика ~2ms)
	const FRAME_BUDGET_USEC := 5000

	# Обрабатываем очередь дорог
	t0 = Time.get_ticks_usec()
	_process_road_queue()
	var t_road := Time.get_ticks_usec() - t0
	_record_perf("road_queue", t_road)

	# Обрабатываем очередь terrain объектов
	var t_terrain := 0
	if (Time.get_ticks_usec() - _frame_start) < FRAME_BUDGET_USEC:
		t0 = Time.get_ticks_usec()
		_process_terrain_objects_queue()
		t_terrain = Time.get_ticks_usec() - t0
		_record_perf("terrain_queue", t_terrain)

	# Обрабатываем очередь инфраструктуры
	var t_infra := 0
	if (Time.get_ticks_usec() - _frame_start) < FRAME_BUDGET_USEC:
		t0 = Time.get_ticks_usec()
		_process_infrastructure_queue()
		t_infra = Time.get_ticks_usec() - t0
		_record_perf("infra_queue", t_infra)

	# Диспетчер растительности (отправка в воркер-треды, мгновенно)
	var t_veg := 0
	t0 = Time.get_ticks_usec()
	_process_vegetation_queue()
	t_veg = Time.get_ticks_usec() - t0
	_record_perf("vegetation_queue", t_veg)

	# Применяем результаты из воркер-тредов деревьев
	t0 = Time.get_ticks_usec()
	_apply_veg_thread_results()
	var t_veg_apply := Time.get_ticks_usec() - t0
	_record_perf("veg_results_apply", t_veg_apply)

	# Применяем коллизии бордюров из worker threads
	t0 = Time.get_ticks_usec()
	_apply_curb_collisions()
	var t_curb := Time.get_ticks_usec() - t0
	_record_perf("curb_collisions", t_curb)

	# Создаём отложенные ноды с бюджетом (buildings, trees, lamps, roads collision)
	t0 = Time.get_ticks_usec()
	_process_deferred_nodes()
	var t_deferred := Time.get_ticks_usec() - t0
	_record_perf("deferred_nodes", t_deferred)

	# Применяем готовые результаты клиппинга террейна из worker threads
	t0 = Time.get_ticks_usec()
	_apply_terrain_thread_results()
	var t_terrain_gen := Time.get_ticks_usec() - t0
	_record_perf("terrain_gen", t_terrain_gen)

	# Lazy chunk activation — включаем видимость через N кадров после финализации
	_process_chunk_activation()

	# Camera-based frustum culling для чанков (каждые 200ms)
	_culling_update_timer += delta
	if _culling_update_timer >= CULLING_UPDATE_INTERVAL:
		_culling_update_timer = 0.0
		t0 = Time.get_ticks_usec()
		_update_chunk_culling()
		var t_culling := Time.get_ticks_usec() - t0
		_record_perf("chunk_culling", t_culling)

	var _frame_time := (Time.get_ticks_usec() - _frame_start) / 1000.0
	_record_perf("total_frame", int(_frame_time * 1000))

	# Детальное логирование при FPS < 30 (frame > 33ms), не чаще раза в секунду
	var _total_frame_ms := 1000.0 / Engine.get_frames_per_second() if Engine.get_frames_per_second() > 0 else 0.0
	if _total_frame_ms > 33.0 and _slow_frame_cooldown <= 0.0:
		_slow_frame_cooldown = 1.0
		if not _viewport_rid.is_valid():
			_viewport_rid = get_viewport().get_viewport_rid()
		var sf_render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		var sf_render_gpu := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var sf_process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var sf_physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var sf_draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var sf_vertices := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		var sf_objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		var sf_phys_bodies := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
		var sf_phys_pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		var sf_nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var sf_resources := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		var sf_vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
		# GPU timing на macOS/Metal может возвращать 0 — не показывать misleading label
		var sf_bottleneck: String
		if sf_render_gpu < 0.01 and sf_render_cpu < 0.01:
			sf_bottleneck = "GPU timing N/A"
		elif sf_render_cpu > sf_render_gpu:
			sf_bottleneck = "CPU-bound"
		else:
			sf_bottleneck = "GPU-bound"
		print("")
		print("===== SLOW FRAME #%d (%.0f FPS, %.1fms) [%s] =====" % [
			Engine.get_process_frames(), Engine.get_frames_per_second(), _total_frame_ms, sf_bottleneck])
		print("  Render: CPU=%.1fms GPU=%.1fms | Godot: Process=%.1fms Physics=%.1fms" % [
			sf_render_cpu, sf_render_gpu, sf_process_ms, sf_physics_ms])
		# Our _process breakdown (этот кадр)
		print("  OSM _process: %.1fms breakdown:" % _frame_time)
		print("    building_results=%.2fms road_queue=%.2fms terrain_queue=%.2fms" % [
			t_building / 1000.0, t_road / 1000.0, t_terrain / 1000.0])
		print("    infra_queue=%.2fms vegetation_queue=%.2fms veg_results_apply=%.2fms" % [
			t_infra / 1000.0, t_veg / 1000.0, t_veg_apply / 1000.0])
		print("    curb_collisions=%.2fms terrain_gen=%.2fms" % [t_curb / 1000.0, t_terrain_gen / 1000.0])
		# Unaccounted time (разница между total и суммой подсистем)
		var accounted := (t_building + t_road + t_terrain + t_infra + t_veg + t_veg_apply + t_curb + t_terrain_gen) / 1000.0
		print("    unaccounted=%.2fms (overhead/other)" % maxf(0.0, _frame_time - accounted))
		# Scene stats
		print("  Scene: draws=%d verts=%.1fM objects=%d nodes=%d resources=%d" % [
			sf_draw_calls, sf_vertices / 1_000_000.0, sf_objects, sf_nodes, sf_resources])
		print("  Physics: bodies=%d pairs=%d | VRAM=%.0fMB" % [
			sf_phys_bodies, sf_phys_pairs, sf_vram])
		# Queues
		print("  Queues: roads=%d terrain=%d infra=%d buildings=%d curbs=%d" % [
			_road_queue.size(), _terrain_objects_queue.size(), _infrastructure_queue.size(),
			_building_results.size(), _curb_queue.size() + _curb_smoothed_queue.size()])
		# Loaded chunks
		print("  Chunks loaded: %d, loading: %d" % [_loaded_chunks.size(), _loading_chunks.size()])
		# Draw call breakdown по категориям (если есть)
		if _draw_call_logging_enabled:
			var dc_parts: PackedStringArray = []
			for cat in _draw_call_stats:
				if _draw_call_stats[cat] > 0:
					dc_parts.append("%s=%d" % [cat, _draw_call_stats[cat]])
			if dc_parts.size() > 0:
				print("  Draw calls by type: %s" % " ".join(dc_parts))
		print("===========================================")

	_perf_frame_count += 1
	if _perf_enabled and _perf_frame_count % 600 == 0:  # Каждые 10 сек при 60fps
		_print_perf_metrics()
		_print_draw_call_stats()

	# Обновляем debug статистику
	_update_debug_stats(delta)

	# Проверяем завершение начальной загрузки (когда очереди опустошились)
	if _initial_loading:
		_check_initial_load_complete()

	# Не обновляем чанки если загрузка на паузе
	if _loading_paused:
		return

	# Выгружаем 1 чанк за кадр (из очереди) — spread across frames
	if not _chunks_to_unload.is_empty():
		var unload_key: String = _chunks_to_unload.pop_front()
		if _loaded_chunks.has(unload_key):
			_unload_chunk(unload_key)

	_check_timer += delta
	if _check_timer < _check_interval:
		return
	_check_timer = 0.0

	# Определяем позицию для загрузки чанков
	# Всегда используем позицию машины — камера может быть далеко (fly mode, cinematic)
	var player_pos := Vector3.ZERO
	if _car:
		player_pos = _car.global_position
	else:
		var viewport := get_viewport()
		if viewport:
			var current_cam := viewport.get_camera_3d()
			if current_cam:
				player_pos = current_cam.global_position

	# Проверяем нужны ли новые чанки
	_update_chunks(player_pos)

	# Обновляем тени зданий и деревьев по расстоянию до игрока
	_update_building_shadows(player_pos)
	_update_tree_shadows(player_pos)

# Начать загрузку карты
func start_loading() -> void:
	print("OSM: Starting initial loading... (generation %d)" % _load_generation)
	print("OSM: State before start: _loaded_chunks=%d, _loading_chunks=%d" % [_loaded_chunks.size(), _loading_chunks.size()])

	# ПРИНУДИТЕЛЬНАЯ очистка на случай если reset_terrain не очистил
	if _loaded_chunks.size() > 0:
		print("OSM: WARNING - _loaded_chunks not empty, clearing...")
		_loaded_chunks.clear()
	if _loading_chunks.size() > 0:
		print("OSM: WARNING - _loading_chunks not empty, clearing...")
		_loading_chunks.clear()

	_loading_paused = false
	_initial_loading = true
	_initial_chunks_loaded = 0
	_parking_polygons.clear()  # Очищаем парковки при новой загрузке
	_parking_bounds.clear()
	_parking_spatial_hash.clear()
	_created_lamp_positions.clear()  # Очищаем позиции фонарей
	_created_bus_stop_positions.clear()  # Очищаем позиции остановок
	_pending_lamps.clear()  # Очищаем отложенные фонари
	_pending_parking_signs.clear()  # Очищаем отложенные знаки парковки
	_deferred_lamp_queue.clear()
	_deferred_manhole_queue.clear()
	_deferred_traffic_queue.clear()
	_deferred_billboard_queue.clear()
	_chunk_activation_pending.clear()
	_lamps_created = false  # Сбрасываем флаг
	_intersection_positions.clear()  # Очищаем перекрёстки
	_intersection_radii.clear()
	_intersection_angles.clear()
	_intersection_types.clear()
	_intersection_roads.clear()
	_intersection_contours.clear()
	_intersection_curb_contours.clear()
	_intersection_spatial_hash.clear()  # Очищаем spatial hash
	_curb_queue.clear()  # Очищаем очередь бордюров
	_curb_smoothed_queue.clear()  # Очищаем очередь сглаженных бордюров
	_curb_mesh_state.clear()  # Очищаем состояние генерации меша
	_curb_collision_mutex.lock()
	_curb_collision_results.clear()  # Очищаем очередь коллизий
	_curb_collision_mutex.unlock()
	_road_batch_data.clear()  # Очищаем road batch data
	_chunk_terrain_roads.clear()

	# Reconnect night mode after reset
	_connect_to_night_mode()

	# Определяем какие чанки нужны для старта
	# Используем позицию машины если она есть, иначе Vector3.ZERO
	var spawn_pos := Vector3.ZERO
	if _car:
		spawn_pos = _car.global_position
		print("OSM: Loading chunks around car position (%.1f, %.1f, %.1f)" % [spawn_pos.x, spawn_pos.y, spawn_pos.z])
	else:
		print("OSM: Loading chunks around spawn point (0, 0, 0)")

	_initial_chunks_needed = _get_needed_chunks(spawn_pos)
	print("OSM: Need to load %d chunks for initial area" % _initial_chunks_needed.size())

	print("OSM: Emitting initial_load_started signal...")
	initial_load_started.emit()
	print("OSM: initial_load_started signal emitted")

	# Загружаем начальные чанки
	var chunks_to_load := 0
	for chunk_key in _initial_chunks_needed:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)
			chunks_to_load += 1
		else:
			if _loaded_chunks.has(chunk_key):
				print("OSM: Chunk %s already loaded, skipping" % chunk_key)
			if _loading_chunks.has(chunk_key):
				print("OSM: Chunk %s already loading, skipping" % chunk_key)

	print("OSM: Started loading %d chunks (total needed: %d, already loaded: %d)" % [chunks_to_load, _initial_chunks_needed.size(), _initial_chunks_needed.size() - chunks_to_load])

	# Если нет чанков для загрузки - сразу завершаем
	if chunks_to_load == 0:
		print("OSM: No chunks to load, completing immediately")
		_initial_loading = false
		initial_load_complete.emit()

# Проверяем завершение начальной загрузки
func _check_initial_load_complete() -> void:
	if not _initial_loading:
		return

	# Считаем сколько начальных чанков загружено
	var loaded_count := 0
	for chunk_key in _initial_chunks_needed:
		if _loaded_chunks.has(chunk_key):
			loaded_count += 1

	_initial_chunks_loaded = loaded_count

	# Считаем общий прогресс: 50% на чанки, 50% на очереди
	var total_chunks: int = _initial_chunks_needed.size()
	var chunk_progress: float = float(loaded_count) / float(max(1, total_chunks))  # 0.0-1.0

	# Считаем размер всех очередей (включая финализацию визуала)
	# Deferred collisions/lights НЕ учитываем — они продолжают работу после загрузки
	var total_queued: int = _building_results.size() + _road_queue.size() + _terrain_objects_queue.size() + _infrastructure_queue.size() + _pending_building_tasks + _pending_road_tasks + _pending_veg_tasks + _pending_terrain_tasks + _deferred_lamp_queue.size() + _deferred_manhole_queue.size() + _deferred_traffic_queue.size() + _pending_batch_chunks.size() + _building_geo_finalize_queue.size() + _curb_geo_batch.size() + _lamp_batches_to_finalize.size() + _tree_batches_to_finalize.size() + _billboard_batches_to_finalize.size() + _window_finalize_queue.size() + _deferred_footway_queue.size() + _deferred_billboard_queue.size() + _chunk_activation_pending.size()

	# DEBUG: Детальное логирование очередей
	if loaded_count >= total_chunks and total_queued > 0:
		print("OSM DEBUG: Chunks loaded %d/%d, queues=%d:" % [loaded_count, total_chunks, total_queued])
		print("  data: bld=%d road=%d(thr:%d) terr=%d infra=%d pBld=%d pRoad=%d pVeg=%d pTerr=%d lamp=%d manhole=%d traffic=%d" % [_building_results.size(), _road_queue.size(), _pending_road_tasks, _terrain_objects_queue.size(), _infrastructure_queue.size(), _pending_building_tasks, _pending_road_tasks, _pending_veg_tasks, _pending_terrain_tasks, _deferred_lamp_queue.size(), _deferred_manhole_queue.size(), _deferred_traffic_queue.size()])
		print("  finalize: roadBatch=%d bldGeo=%d curb=%d lamp=%d tree=%d billboard=%d window=%d" % [_pending_batch_chunks.size(), _building_geo_finalize_queue.size(), _curb_geo_batch.size(), _lamp_batches_to_finalize.size(), _tree_batches_to_finalize.size(), _billboard_batches_to_finalize.size(), _window_finalize_queue.size()])

	# DEBUG: Проверяем зависшие чанки в _loading_chunks
	if loaded_count < total_chunks:
		var missing_chunks: Array[String] = []
		for chunk_key in _initial_chunks_needed:
			if not _loaded_chunks.has(chunk_key):
				missing_chunks.append(chunk_key)

		if missing_chunks.size() > 0:
			print("OSM DEBUG: Missing chunks (%d): %s" % [missing_chunks.size(), str(missing_chunks)])
			print("  - Currently loading: %s" % str(_loading_chunks.keys()))

			# Проверяем таймауты для загружающихся чанков
			var current_time := Time.get_ticks_msec()
			var timed_out_chunks: Array[String] = []
			for chunk_key in _loading_chunks.keys():
				var load_start_time: int = _loading_chunks[chunk_key]
				var elapsed_sec := float(current_time - load_start_time) / 1000.0
				if elapsed_sec > CHUNK_LOAD_TIMEOUT:
					timed_out_chunks.append(chunk_key)
					print("OSM WARNING: Chunk %s timed out after %.1f seconds!" % [chunk_key, elapsed_sec])

			# Убираем зависшие чанки и пытаемся загрузить заново
			for chunk_key in timed_out_chunks:
				_loading_chunks.erase(chunk_key)
				_current_load_count = max(0, _current_load_count - 1)
				print("OSM: Retrying timed out chunk %s..." % chunk_key)
				# Перезагружаем чанк
				var coords: Array = chunk_key.split(",")
				var chunk_x := int(coords[0])
				var chunk_z := int(coords[1])
				_load_chunk(chunk_x, chunk_z)

	# Статус
	var status: String
	if loaded_count < total_chunks:
		status = "Загрузка чанков: %d / %d" % [loaded_count, total_chunks]
	elif total_queued > 0:
		status = "Генерация объектов: %d в очереди" % total_queued
	else:
		status = "Финализация..."

	# Общий прогресс: 60% - чанки, 40% - очереди
	var total_progress: float = chunk_progress * 0.6 + (1.0 - float(total_queued) / float(max(1, total_queued + 100))) * 0.4
	total_progress = clampf(total_progress, 0.0, 1.0)

	initial_load_progress.emit(total_progress, status)

	# Все начальные чанки загружены?
	if loaded_count >= total_chunks:
		# Проверяем что все очереди обработаны (для плавности старта)
		# Visual queues: must be empty before hiding loading screen
		# Deferred collisions/lights are NOT blocking — they continue in background
		var queues_empty := _building_results.is_empty() and _road_queue.is_empty() and _terrain_objects_queue.is_empty() and _infrastructure_queue.is_empty() and _pending_building_tasks <= 0 and _pending_road_tasks <= 0 and _pending_veg_tasks <= 0 and _pending_batch_chunks.is_empty() and _building_geo_finalize_queue.is_empty() and _curb_geo_batch.is_empty() and _lamp_batches_to_finalize.is_empty() and _tree_batches_to_finalize.is_empty() and _billboard_batches_to_finalize.is_empty() and _window_finalize_queue.is_empty() and _deferred_footway_queue.is_empty() and _deferred_billboard_queue.is_empty() and _chunk_activation_pending.is_empty()
		if not queues_empty:
			# Отслеживаем зависание очереди
			if total_queued == _last_queue_size:
				_queue_stuck_time += get_process_delta_time()
				if _queue_stuck_time >= QUEUE_STUCK_TIMEOUT:
					# Очередь зависла - принудительно сбрасываем pending tasks и переходим к финализации
					print("OSM: Queue stuck at %d items for %.1fs, forcing completion..." % [total_queued, _queue_stuck_time])
					_pending_building_tasks = 0
					_pending_road_tasks = 0
					_pending_veg_tasks = 0
					_queue_stuck_time = 0.0
					# НЕ делаем return - продолжаем к финализации ниже
				else:
					# Очередь ещё не зависла, ждём дальше
					return
			else:
				# Размер очереди изменился - сбрасываем таймер и ждём
				_last_queue_size = total_queued
				_queue_stuck_time = 0.0
				return
			# Если мы тут - очередь зависла и мы форсируем завершение

		# Финализация: создаём фонари и знаки парковки СРАЗУ (без батчинга)
		if _finalization_state == 0:
			print("OSM: Starting finalization...")
			_finalization_state = 1
			initial_load_progress.emit(0.95, "Финализация: батчинг фонарей...")
			# OLD: Создаём все фонари сразу (DEPRECATED - now using batching)
			# _create_pending_lamps()
			print("OSM: Lamp batching queued, starting parking signs...")
			_finalization_state = 2
			initial_load_progress.emit(0.98, "Финализация: создание знаков парковки (%d)..." % _pending_parking_signs.size())
			# Создаём все знаки парковки сразу
			_create_pending_parking_signs()
			print("OSM: Parking signs done")
			_finalization_state = 3

		_initial_loading = false
		print("OSM: Initial loading complete! %d chunks loaded" % loaded_count)

		initial_load_complete.emit()

func _update_chunks(player_pos: Vector3) -> void:
	# Определяем какие чанки нужны
	var needed_chunks := _get_needed_chunks(player_pos)

	# Загружаем недостающие
	for chunk_key in needed_chunks:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)

	# Выгружаем далёкие чанки (ставим в очередь — 1 за кадр)
	for chunk_key in _loaded_chunks:
		if _chunks_to_unload.has(chunk_key):
			continue
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector3(chunk_x * chunk_size + chunk_size / 2, 0, chunk_z * chunk_size + chunk_size / 2)
		var dist := player_pos.distance_to(chunk_center)
		if dist > unload_distance:
			_chunks_to_unload.append(chunk_key)

func _get_needed_chunks(player_pos: Vector3) -> Array[String]:
	var result: Array[String] = []
	var player_chunk_x := int(floor(player_pos.x / chunk_size))
	var player_chunk_z := int(floor(player_pos.z / chunk_size))

	# Радиус в чанках
	var radius_chunks := int(ceil(load_distance / chunk_size))

	for dx in range(-radius_chunks, radius_chunks + 1):
		for dz in range(-radius_chunks, radius_chunks + 1):
			var cx := player_chunk_x + dx
			var cz := player_chunk_z + dz
			var chunk_center := Vector3(cx * chunk_size + chunk_size / 2, 0, cz * chunk_size + chunk_size / 2)
			if player_pos.distance_to(chunk_center) <= load_distance:
				result.append("%d,%d" % [cx, cz])

	return result


## Простая предиктивная загрузка - загружаем чанки впереди по движению
func _update_chunks_simple_predictive(player_pos: Vector3, velocity: Vector3) -> void:
	var speed := velocity.length()

	# Базовые чанки вокруг игрока (всегда)
	var needed_chunks := _get_needed_chunks(player_pos)

	# При быстром движении добавляем чанки впереди
	if speed > min_speed_for_prediction:
		var look_ahead := velocity.normalized() * load_distance * forward_load_multiplier
		var ahead_pos := player_pos + look_ahead
		var ahead_chunks := _get_needed_chunks(ahead_pos)
		for chunk_key in ahead_chunks:
			if chunk_key not in needed_chunks:
				needed_chunks.append(chunk_key)

	# Загружаем недостающие
	for chunk_key in needed_chunks:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			var coords: Array = chunk_key.split(",")
			var chunk_x := int(coords[0])
			var chunk_z := int(coords[1])
			_load_chunk(chunk_x, chunk_z)

	# Выгружаем далёкие чанки (простая радиальная выгрузка)
	var chunks_to_unload: Array[String] = []
	for chunk_key in _loaded_chunks:
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector3(chunk_x * chunk_size + chunk_size / 2, 0, chunk_z * chunk_size + chunk_size / 2)
		var dist := player_pos.distance_to(chunk_center)
		if dist > unload_distance:
			chunks_to_unload.append(chunk_key)

	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)


## Старая сложная предиктивная загрузка (отключена)
func _update_chunks_predictive(player_pos: Vector3, velocity: Vector3) -> void:
	# Получаем приоритизированный список чанков
	var predicted_chunks := _get_predicted_chunks(player_pos, velocity)

	# Добавляем новые чанки в очередь
	for chunk_data in predicted_chunks:
		var chunk_key: String = chunk_data["key"]

		# Пропускаем уже загруженные/загружающиеся
		if _loaded_chunks.has(chunk_key) or _loading_chunks.has(chunk_key):
			continue

		# Проверяем, есть ли уже в очереди
		var in_queue := false
		for queued in _chunk_load_queue:
			if queued["key"] == chunk_key:
				# Обновляем приоритет если выше
				if chunk_data["priority"] > queued["priority"]:
					queued["priority"] = chunk_data["priority"]
				in_queue = true
				break

		if not in_queue:
			_chunk_load_queue.append(chunk_data)

	# Сортируем очередь по приоритету (убывание)
	_chunk_load_queue.sort_custom(func(a, b): return a["priority"] > b["priority"])

	# Обрабатываем очередь (ограничиваем параллельные загрузки)
	while _current_load_count < MAX_CONCURRENT_LOADS and _chunk_load_queue.size() > 0:
		var next_chunk: Dictionary = _chunk_load_queue.pop_front()
		var chunk_key: String = next_chunk["key"]

		# Повторная проверка (могло загрузиться пока ждало в очереди)
		if _loaded_chunks.has(chunk_key) or _loading_chunks.has(chunk_key):
			continue

		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		_load_chunk_tracked(chunk_x, chunk_z)

	# Направленная выгрузка
	_unload_distant_chunks(player_pos, velocity)


## Загрузка чанка с отслеживанием количества
func _load_chunk_tracked(chunk_x: int, chunk_z: int) -> void:
	_current_load_count += 1
	_load_chunk(chunk_x, chunk_z)


## Получает приоритизированный список чанков на основе предсказания
func _get_predicted_chunks(player_pos: Vector3, velocity: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var added_chunks: Dictionary = {}
	var speed := velocity.length()

	# При низкой скорости - радиальная загрузка
	if speed < min_speed_for_prediction:
		var radial_chunks := _get_needed_chunks(player_pos)
		for chunk_key in radial_chunks:
			result.append({
				"key": chunk_key,
				"priority": 1.0,
				"distance": _get_chunk_distance(chunk_key, player_pos)
			})
		return result

	# Направление движения (XZ плоскость)
	var move_dir := Vector3(velocity.x, 0, velocity.z).normalized()

	# 1. Сначала добавляем ближайшие чанки (безопасность)
	var immediate_chunks := _get_needed_chunks(player_pos)
	for chunk_key in immediate_chunks:
		if not added_chunks.has(chunk_key):
			added_chunks[chunk_key] = true
			result.append({
				"key": chunk_key,
				"priority": 10.0,  # Высший приоритет
				"distance": _get_chunk_distance(chunk_key, player_pos)
			})

	# 2. Добавляем чанки по предсказанным позициям
	for i in range(PREDICTION_INTERVALS):
		var t := (i + 1) * (prediction_time_horizon / PREDICTION_INTERVALS)
		var predicted_pos := player_pos + velocity * t

		# Чанки вокруг предсказанной позиции с направленным смещением
		var predicted_chunks := _get_directional_chunks(predicted_pos, move_dir, speed)

		for chunk_data in predicted_chunks:
			var chunk_key: String = chunk_data["key"]
			if not added_chunks.has(chunk_key):
				added_chunks[chunk_key] = true
				# Приоритет уменьшается с временем предсказания
				chunk_data["priority"] = 5.0 / (i + 1)
				result.append(chunk_data)

	# Сортируем по приоритету
	result.sort_custom(func(a, b): return a["priority"] > b["priority"])

	return result


## Чанки вокруг позиции с учётом направления движения
func _get_directional_chunks(center_pos: Vector3, move_dir: Vector3, speed: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var center_chunk_x := int(floor(center_pos.x / chunk_size))
	var center_chunk_z := int(floor(center_pos.z / chunk_size))

	# Эффективные радиусы
	var forward_radius := load_distance * forward_load_multiplier
	var side_radius := load_distance * side_load_multiplier

	# Адаптация по скорости (быстрее = дальше смотрим)
	var speed_factor: float = clampf(speed / 30.0, 1.0, 2.0)  # 30 м/с = 108 км/ч
	forward_radius *= speed_factor

	var radius_chunks := int(ceil(forward_radius / chunk_size))

	for dx in range(-radius_chunks, radius_chunks + 1):
		for dz in range(-radius_chunks, radius_chunks + 1):
			var cx := center_chunk_x + dx
			var cz := center_chunk_z + dz
			var chunk_center := Vector3(
				cx * chunk_size + chunk_size / 2,
				0,
				cz * chunk_size + chunk_size / 2
			)

			var to_chunk := chunk_center - center_pos
			to_chunk.y = 0
			var dist := to_chunk.length()

			if dist < 0.01:
				# Чанк в центре
				result.append({
					"key": "%d,%d" % [cx, cz],
					"priority": 1.0,
					"distance": dist
				})
				continue

			var dir_to_chunk := to_chunk.normalized()

			# Выравнивание с направлением движения (-1 до 1)
			var alignment := move_dir.dot(dir_to_chunk)

			# Эффективный радиус по направлению
			var effective_radius: float
			if alignment > 0:
				effective_radius = lerpf(side_radius, forward_radius, alignment)
			else:
				effective_radius = side_radius * (1.0 + alignment * 0.5)  # Сжимаем сзади

			if dist <= effective_radius:
				var dist_factor := 1.0 - (dist / forward_radius)
				var priority := (alignment + 1.0) * 0.5 * dist_factor

				result.append({
					"key": "%d,%d" % [cx, cz],
					"priority": priority,
					"distance": dist
				})

	return result


## Выгрузка чанков с учётом направления движения
func _unload_distant_chunks(player_pos: Vector3, velocity: Vector3) -> void:
	var speed := velocity.length()
	var move_dir := Vector3(velocity.x, 0, velocity.z).normalized() if speed > 0.1 else Vector3.ZERO

	var chunks_to_unload: Array[String] = []

	for chunk_key in _loaded_chunks:
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector3(
			chunk_x * chunk_size + chunk_size / 2,
			0,
			chunk_z * chunk_size + chunk_size / 2
		)

		var dist := player_pos.distance_to(chunk_center)

		# При низкой скорости - стандартная радиальная выгрузка
		if speed < min_speed_for_prediction:
			if dist > unload_distance:
				chunks_to_unload.append(chunk_key)
			continue

		# Направленная выгрузка
		var to_chunk := chunk_center - player_pos
		to_chunk.y = 0
		var dir_to_chunk := to_chunk.normalized() if to_chunk.length() > 0.01 else Vector3.ZERO
		var alignment := move_dir.dot(dir_to_chunk)

		# Пороги выгрузки по направлению
		var effective_unload_dist: float
		if alignment > 0.3:  # Впереди
			effective_unload_dist = unload_distance * 1.5
		elif alignment < -0.3:  # Сзади
			effective_unload_dist = unload_distance * 0.7
		else:  # Сбоку
			effective_unload_dist = unload_distance

		if dist > effective_unload_dist:
			chunks_to_unload.append(chunk_key)

	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)
		# Удаляем из очереди если там есть
		_chunk_load_queue = _chunk_load_queue.filter(func(c): return c["key"] != chunk_key)


## Расстояние до центра чанка
func _get_chunk_distance(chunk_key: String, pos: Vector3) -> float:
	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var chunk_center := Vector3(
		chunk_x * chunk_size + chunk_size / 2,
		0,
		chunk_z * chunk_size + chunk_size / 2
	)
	return pos.distance_to(chunk_center)


func _load_chunk(chunk_x: int, chunk_z: int) -> void:
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]
	_loading_chunks[chunk_key] = Time.get_ticks_msec()  # Сохраняем время начала загрузки

	# Вычисляем центр чанка в координатах lat/lon
	var center_x := chunk_x * chunk_size + chunk_size / 2
	var center_z := chunk_z * chunk_size + chunk_size / 2

	# Конвертируем локальные координаты обратно в lat/lon
	# Z инвертирован в системе координат, поэтому вычитаем
	var chunk_lat := start_lat - center_z / 111000.0
	var chunk_lon := start_lon + center_x / (111000.0 * cos(deg_to_rad(start_lat)))

	print("OSM: Loading chunk %s at lat=%.4f, lon=%.4f" % [chunk_key, chunk_lat, chunk_lon])

	# Тестовый режим — данные без HTTP, но тот же async flow что и в игре
	if test_data_provider.is_valid():
		var osm_data: Dictionary = test_data_provider.call(chunk_lat, chunk_lon, chunk_size)
		osm_data["center_lat"] = chunk_lat
		osm_data["center_lon"] = chunk_lon
		var fake_loader := Node.new()
		fake_loader.name = "FakeLoader_" + chunk_key
		add_child(fake_loader)
		_on_chunk_data_loaded(osm_data, chunk_key, fake_loader, _load_generation)
		return

	# Создаём отдельный загрузчик для этого чанка
	var loader := OSMLoaderScript.new()
	add_child(loader)
	var gen := _load_generation  # Захватываем текущую генерацию
	loader.data_loaded.connect(_on_chunk_data_loaded.bind(chunk_key, loader, gen))
	loader.load_failed.connect(_on_chunk_load_failed.bind(chunk_key, loader, gen))
	loader.load_area(chunk_lat, chunk_lon, chunk_size / 2 + 100)  # +100м overlap для зданий на границах

func _load_chunk_at_position(pos: Vector3) -> void:
	var chunk_x := int(floor(pos.x / chunk_size))
	var chunk_z := int(floor(pos.z / chunk_size))
	_load_chunk(chunk_x, chunk_z)

func _unload_chunk(chunk_key: String) -> void:
	if _loaded_chunks.has(chunk_key):
		# NEW: Clean up lamp batch data if not yet finalized
		if _lamp_batch_data.has(chunk_key):
			_lamp_batch_data.erase(chunk_key)
		var lamp_finalize_idx := _lamp_batches_to_finalize.find(chunk_key)
		if lamp_finalize_idx >= 0:
			_lamp_batches_to_finalize.remove_at(lamp_finalize_idx)

		# NEW: Explicitly free lamp lights to prevent memory leak
		if _lamp_lights_by_chunk.has(chunk_key):
			for light in _lamp_lights_by_chunk[chunk_key]:
				if is_instance_valid(light):
					light.queue_free()
			_lamp_lights_by_chunk.erase(chunk_key)

		# Clean up tree batch data if not yet finalized
		if _tree_batch_data.has(chunk_key):
			_tree_batch_data.erase(chunk_key)
		var finalize_idx := _tree_batches_to_finalize.find(chunk_key)
		if finalize_idx >= 0:
			_tree_batches_to_finalize.remove_at(finalize_idx)

		# Clean up pending vegetation thread results for this chunk
		_veg_mutex.lock()
		var filtered_veg: Array = []
		for veg_result in _veg_thread_results:
			if veg_result.chunk_key != chunk_key:
				filtered_veg.append(veg_result)
		_veg_thread_results = filtered_veg
		_veg_mutex.unlock()

		# Clean up billboard batch data
		var billboard_finalize_idx := _billboard_batches_to_finalize.find(chunk_key)
		if billboard_finalize_idx >= 0:
			_billboard_batches_to_finalize.remove_at(billboard_finalize_idx)

		# Clean up curb geo batch
		if _curb_geo_batch.has(chunk_key):
			_curb_geo_batch.erase(chunk_key)

		# Clean up building geometry merge batch
		if _building_geo_batch.has(chunk_key):
			_building_geo_batch.erase(chunk_key)
		var building_finalize_idx := _building_geo_finalize_queue.find(chunk_key)
		if building_finalize_idx >= 0:
			_building_geo_finalize_queue.remove_at(building_finalize_idx)

		# Clean up window batch data if not yet finalized
		if _window_batch_data.has(chunk_key):
			_window_batch_data.erase(chunk_key)
		if _window_finalize_progress.has(chunk_key):
			_window_finalize_progress.erase(chunk_key)
			var wfq_idx := _window_finalize_queue.find(chunk_key)
			if wfq_idx >= 0:
				_window_finalize_queue.remove_at(wfq_idx)

		# Clean up pending batch chunks
		var pending_idx := _pending_batch_chunks.find(chunk_key)
		if pending_idx >= 0:
			_pending_batch_chunks.remove_at(pending_idx)

		# Clean up terrain roads data for this chunk
		_chunk_terrain_roads.erase(chunk_key)

		# Clean up pending terrain thread results for this chunk
		_terrain_thread_mutex.lock()
		var filtered_terrain: Array = []
		for tr in _terrain_thread_results:
			if tr.chunk_key != chunk_key:
				filtered_terrain.append(tr)
			else:
				_pending_terrain_tasks -= 1
		_terrain_thread_results = filtered_terrain
		_terrain_thread_mutex.unlock()

		# Clean up deferred node queues for this chunk
		_deferred_building_collisions = _deferred_building_collisions.filter(
			func(item): return is_instance_valid(item.get("parent")))
		_deferred_tree_collisions = _deferred_tree_collisions.filter(
			func(item): return is_instance_valid(item.get("parent")))
		_deferred_lamp_lights = _deferred_lamp_lights.filter(
			func(item): return is_instance_valid(item.get("container")))
		_deferred_road_collisions = _deferred_road_collisions.filter(
			func(item): return is_instance_valid(item.get("body")))
		_deferred_terrain_collisions = _deferred_terrain_collisions.filter(
			func(item): return is_instance_valid(item.get("parent")))
		_deferred_footway_queue = _deferred_footway_queue.filter(
			func(item): return is_instance_valid(item.get("parent")))
		_deferred_billboard_queue = _deferred_billboard_queue.filter(
			func(item): return is_instance_valid(item.get("parent")))
		_deferred_add_child_queue = _deferred_add_child_queue.filter(
			func(item): return is_instance_valid(item.get("parent")) and is_instance_valid(item.get("child")))

		# Prune invalid window batch materials (freed with chunk node)
		var valid_mats: Array[ShaderMaterial] = []
		for mat in _window_batch_materials:
			if is_instance_valid(mat):
				valid_mats.append(mat)
		_window_batch_materials = valid_mats

		# Clean up lazy activation
		_chunk_activation_pending.erase(chunk_key)

		# Free RenderingServer instances for this chunk
		if _chunk_rs_instances.has(chunk_key):
			for rid in _chunk_rs_instances[chunk_key]:
				RenderingServer.free_rid(rid)
			_chunk_rs_instances.erase(chunk_key)
		_chunk_rs_meshes.erase(chunk_key)
		_chunk_road_materials.erase(chunk_key)
		_chunk_building_rs.erase(chunk_key)
		_chunk_tree_shadow_nodes.erase(chunk_key)

		var chunk_node: Node3D = _loaded_chunks[chunk_key]
		chunk_node.queue_free()
		_loaded_chunks.erase(chunk_key)

		# Очищаем позиции фонарей и знаков в выгруженном чанке
		_clear_chunk_objects_positions(chunk_key)

		print("OSM: Unloaded chunk %s" % chunk_key)


## Очищает позиции объектов (фонарей, знаков) в границах чанка
func _clear_chunk_objects_positions(chunk_key: String) -> void:
	var coords := chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])

	# Границы чанка в мировых координатах
	var min_x := chunk_x * chunk_size
	var max_x := min_x + chunk_size
	var min_z := chunk_z * chunk_size
	var max_z := min_z + chunk_size

	# Очищаем позиции фонарей в этом чанке
	var lamps_to_remove: Array = []
	for pos_key in _created_lamp_positions.keys():
		var parts: PackedStringArray = pos_key.split("_")
		if parts.size() >= 2:
			var x := int(parts[0])
			var z := int(parts[1])
			if x >= min_x and x < max_x and z >= min_z and z < max_z:
				lamps_to_remove.append(pos_key)

	for key in lamps_to_remove:
		_created_lamp_positions.erase(key)

	# Очищаем позиции знаков в этом чанке
	# Ключи: "%d_%d" (parking), "ts_%d_%d" (traffic), "ys_%d_%d" (yield)
	var signs_to_remove: Array = []
	for pos_key in _created_sign_positions.keys():
		var parts: PackedStringArray = pos_key.split("_")
		var x: int
		var z: int
		if parts.size() == 2:
			# Формат "%d_%d"
			x = int(parts[0])
			z = int(parts[1])
		elif parts.size() == 3:
			# Формат "prefix_%d_%d"
			x = int(parts[1])
			z = int(parts[2])
		else:
			continue
		if x >= min_x and x < max_x and z >= min_z and z < max_z:
			signs_to_remove.append(pos_key)

	for key in signs_to_remove:
		_created_sign_positions.erase(key)


# Сбрасывает все загруженные чанки (для смены локации)
func reset_terrain() -> void:
	print("OSM: Resetting terrain...")
	# Recalculate cached cosine (start_lat may have changed)
	_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0
	# Инкрементируем generation чтобы игнорировать callback'и от старых загрузок
	_load_generation += 1
	print("OSM: Load generation incremented to %d" % _load_generation)
	# Выгружаем все чанки
	var chunks_to_unload: Array[String] = []
	for chunk_key in _loaded_chunks:
		chunks_to_unload.append(chunk_key)
	for chunk_key in chunks_to_unload:
		_unload_chunk(chunk_key)

	# Сбрасываем состояние
	_loading_chunks.clear()
	_initial_loading = false
	_initial_chunks_needed.clear()
	_initial_chunks_loaded = 0
	_loading_paused = true
	_finalization_state = 0  # Сбрасываем состояние финализации
	# Предиктивная загрузка
	_chunk_load_queue.clear()
	_current_load_count = 0
	_smoothed_velocity = Vector3.ZERO
	# Сбрасываем таймеры зависания
	_queue_stuck_time = 0.0
	_last_queue_size = 0
	_road_queue_sorted = false

	# КРИТИЧНО: Очищаем все очереди генерации объектов
	_building_mutex.lock()
	_building_results.clear()
	_pending_building_tasks = 0
	_building_mutex.unlock()
	_curb_collision_mutex.lock()
	_curb_collision_results.clear()
	_curb_collision_mutex.unlock()
	_road_queue.clear()
	_road_mutex.lock()
	_road_results.clear()
	_pending_road_tasks = 0
	_road_mutex.unlock()
	_veg_mutex.lock()
	_veg_thread_results.clear()
	_pending_veg_tasks = 0
	_veg_mutex.unlock()
	_terrain_objects_queue.clear()
	_infrastructure_queue.clear()
	_vegetation_queue.clear()
	_pending_lamps.clear()
	_pending_parking_signs.clear()
	_lamps_created = false
	_curb_queue.clear()
	_curb_smoothed_queue.clear()
	_curb_mesh_state.clear()

	# Очищаем словари позиций объектов и парковок
	_created_lamp_positions.clear()
	_created_sign_positions.clear()
	_created_bus_stop_positions.clear()
	_road_segments.clear()
	_road_spatial_hash.clear()
	_building_segments.clear()
	_building_spatial_hash.clear()
	_parking_polygons.clear()
	_parking_bounds.clear()
	_parking_spatial_hash.clear()
	_deferred_lamp_queue.clear()
	_deferred_manhole_queue.clear()
	_deferred_traffic_queue.clear()
	_deferred_billboard_queue.clear()
	_chunk_activation_pending.clear()

	# Clear ALL batching data on reset
	_lamp_batch_data.clear()
	_lamp_batches_to_finalize.clear()
	_lamp_lights_by_chunk.clear()
	_lamp_batch_lights.clear()
	_tree_batch_data.clear()
	_tree_batches_to_finalize.clear()
	_building_geo_batch.clear()
	_building_geo_finalize_queue.clear()
	_window_finalize_queue.clear()
	_window_finalize_progress.clear()
	_curb_geo_batch.clear()
	_fence_geo_batch.clear()
	_fence_batches_to_finalize.clear()
	_window_batch_data.clear()
	_window_batch_materials.clear()
	_pending_batch_chunks.clear()
	_road_batch_data.clear()
	_chunk_terrain_roads.clear()

	# Reset draw call stats (prevent stale stats across location changes)
	for key in _draw_call_stats:
		_draw_call_stats[key] = 0

	# Disconnect night mode signal to prevent stale callbacks
	if _night_mode_connected and _night_mode_manager and is_instance_valid(_night_mode_manager):
		if _night_mode_manager.night_mode_changed.is_connected(_on_night_mode_changed):
			_night_mode_manager.night_mode_changed.disconnect(_on_night_mode_changed)
		_night_mode_connected = false

	print("OSM: Terrain reset complete (all batch data cleared)")

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_chunk_load_failed(error: String, chunk_key: String, loader: Node, gen: int) -> void:
	# Игнорируем callback если это от старой загрузки
	if gen != _load_generation:
		print("OSM: Ignoring stale failed chunk %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		loader.queue_free()
		return

	push_error("OSM chunk %s load failed: %s" % [chunk_key, error])
	_loading_chunks.erase(chunk_key)
	_current_load_count = max(0, _current_load_count - 1)  # Декремент счётчика
	loader.queue_free()

func _on_osm_data_loaded(osm_data: Dictionary) -> void:
	print("OSM: Initial data loaded")
	# Запускаем генерацию асинхронно (не блокируя callback)
	_generate_terrain(osm_data, null)

func _on_chunk_data_loaded(osm_data: Dictionary, chunk_key: String, loader: Node, gen: int) -> void:
	# Игнорируем callback если это от старой загрузки (после reset_terrain)
	if gen != _load_generation:
		print("OSM: Ignoring stale chunk %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		loader.queue_free()
		return

	print("OSM: Chunk %s data loaded" % chunk_key)
	_loading_chunks.erase(chunk_key)
	_current_load_count = max(0, _current_load_count - 1)  # Декремент счётчика

	# Создаём контейнер для чанка (невидимый — активируется после финализации)
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	chunk_node.visible = false
	add_child(chunk_node)
	_loaded_chunks[chunk_key] = chunk_node
	_chunk_activation_pending[chunk_key] = -1  # -1 = ждём финализации


	# Генерируем объекты асинхронно (с frame budgeting)
	_generate_chunk_async(osm_data, chunk_node, chunk_key, loader, gen)

# Асинхронная генерация чанка с frame budgeting
func _generate_chunk_async(osm_data: Dictionary, chunk_node: Node3D, chunk_key: String, loader: Node, gen: int) -> void:
	await _generate_terrain(osm_data, chunk_node, chunk_key)
	loader.queue_free()

	# После await проверяем что это не устаревшая загрузка
	if gen != _load_generation:
		print("OSM: Ignoring stale chunk generation %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		return

	# OLD: Создаём фонари для этого чанка (DEPRECATED - now using batching)
	if not _initial_loading:
		# Batching happens automatically in _process() via _lamp_batches_to_finalize
		pass
		# _create_pending_lamps()  # DISABLED

	# Добавляем чанк в очередь для создания билбордов из DecorationLayer
	if _decoration_layer and not _billboard_batches_to_finalize.has(chunk_key):
		_billboard_batches_to_finalize.append(chunk_key)


	# Если ночь уже включена - активируем свет в новом чанке
	_apply_night_mode_to_chunk(chunk_node)

	# Проверяем завершение начальной загрузки
	_check_initial_load_complete()

func _generate_terrain(osm_data: Dictionary, parent: Node3D, chunk_key: String = "") -> void:
	var _profile_start := Time.get_ticks_msec()
	var _profile_last := _profile_start

	# Frame budgeting counter - yield каждые N объектов для предотвращения фризов
	var objects_this_frame := 0
	const OBJECTS_PER_FRAME := 3  # Количество лёгких объектов перед yield
	var target: Node3D = parent if parent else self
	var ways: Array = osm_data.get("ways", [])
	var road_count := 0
	var building_count := 0

	# Получаем loader для конвертации координат
	var loader: Node = null
	if parent:
		# Для чанков используем временный loader с правильным центром
		loader = OSMLoaderScript.new()
		loader.center_lat = osm_data.get("center_lat", start_lat)
		loader.center_lon = osm_data.get("center_lon", start_lon)
	else:
		loader = osm_loader

	# Вычисляем границы чанка для фильтрации дубликатов
	var chunk_min_x := 0.0
	var chunk_max_x := 0.0
	var chunk_min_z := 0.0
	var chunk_max_z := 0.0
	var filter_by_chunk := false

	if chunk_key != "":
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		chunk_min_x = chunk_x * chunk_size
		chunk_max_x = chunk_min_x + chunk_size
		chunk_min_z = chunk_z * chunk_size
		chunk_max_z = chunk_min_z + chunk_size
		filter_by_chunk = true

	# Получаем входы и POI для ТЕКУЩЕГО чанка
	# ВАЖНО: Сбрасываем POI перед обработкой каждого чанка!
	# POI используют систему координат текущего loader'а
	_entrance_nodes = osm_data.get("entrance_nodes", [])
	_poi_nodes = osm_data.get("poi_nodes", [])
	# НЕ очищаем _parking_polygons и _road_segments - накапливаем из всех чанков
	# _road_segments нужны для позиционирования знаков парковки

	if not _entrance_nodes.is_empty():
		print("OSM: Found %d entrance nodes in chunk" % _entrance_nodes.size())
	if not _poi_nodes.is_empty():
		print("OSM: Found %d POI nodes in chunk" % _poi_nodes.size())

	# Первый проход: собираем полигоны парковок, сегменты дорог и зданий из ВСЕХ OSM данных
	# (включая объекты за пределами чанка - они нужны для корректной проверки расстояний)
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])
		if tags.get("amenity") == "parking" and nodes.size() >= 3:
			var points: PackedVector2Array = []
			for node in nodes:
				var local: Vector2 = _latlon_to_local(node.lat, node.lon)
				points.append(local)
			_parking_polygons.append(points)
			# Cache bounds for fast rejection
			var center := Vector2.ZERO
			for p in points:
				center += p
			center /= points.size()
			var max_r := 0.0
			for p in points:
				var d: float = center.distance_to(p)
				if d > max_r:
					max_r = d
			_parking_bounds.append({"center": center, "radius": max_r})
			# Add parking edges to spatial hash
			var pidx: int = _parking_polygons.size() - 1
			for ei in range(points.size()):
				var ep1: Vector2 = points[ei]
				var ep2: Vector2 = points[(ei + 1) % points.size()]
				var emin_x: float = minf(ep1.x, ep2.x)
				var emax_x: float = maxf(ep1.x, ep2.x)
				var emin_y: float = minf(ep1.y, ep2.y)
				var emax_y: float = maxf(ep1.y, ep2.y)
				var cx0: int = int(floor(emin_x / PARKING_CELL_SIZE))
				var cx1: int = int(floor(emax_x / PARKING_CELL_SIZE))
				var cy0: int = int(floor(emin_y / PARKING_CELL_SIZE))
				var cy1: int = int(floor(emax_y / PARKING_CELL_SIZE))
				for cx in range(cx0, cx1 + 1):
					for cy in range(cy0, cy1 + 1):
						var cell_key := Vector2i(cx, cy)
						if not _parking_spatial_hash.has(cell_key):
							_parking_spatial_hash[cell_key] = []
						_parking_spatial_hash[cell_key].append({"idx": pidx, "p1": ep1, "p2": ep2})

		# Все дороги из OSM данных -> spatial hash (для проверки расстояний при генерации деревьев/фонарей)
		# Используем сглаженные координаты — чтобы spatial hash соответствовал реальной геометрии дорог
		if tags.has("highway") and nodes.size() >= 2:
			var highway_type: String = tags.get("highway", "residential")
			var road_w: float = ROAD_WIDTHS.get(highway_type, 5.0)
			var raw_pts := PackedVector2Array()
			raw_pts.resize(nodes.size())
			for j in range(nodes.size()):
				raw_pts[j] = _latlon_to_local(nodes[j].lat, nodes[j].lon)
			var smoothed_pts := _smooth_road_corners(raw_pts)
			for j in range(smoothed_pts.size() - 1):
				var rseg := {"p1": smoothed_pts[j], "p2": smoothed_pts[j + 1], "width": road_w}
				# Добавляем только в spatial hash (не в _road_segments чтобы избежать дубликатов)
				_add_road_segment_to_spatial_hash(rseg)

		# Все здания из OSM данных -> spatial hash
		if (tags.has("building") or (tags.has("amenity") and not tags.has("highway"))) and nodes.size() >= 3:
			var bpoints: PackedVector2Array = []
			for node in nodes:
				bpoints.append(_latlon_to_local(node.lat, node.lon))
			for j in range(bpoints.size()):
				var bp1 := bpoints[j]
				var bp2 := bpoints[(j + 1) % bpoints.size()]
				var bseg := {"p1": bp1, "p2": bp2}
				_add_building_segment_to_spatial_hash(bseg)

	# Сбор перекрёстков (узлы, где сходятся несколько дорог)
	# НЕ очищаем массивы - накапливаем из всех чанков (очистка в start_loading)
	var node_usage: Dictionary = {}  # node_key -> {pos: Vector2, types: Array[String], widths: Array[float], directions: Array[Vector2]}
	var node_arms: Dictionary = {}  # node_key -> Array[{direction: Vector2, width: float}] — ВСЕ рукава (без дедупликации)

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])

		if not tags.has("highway") or way_nodes.size() < 2:
			continue

		var highway_type: String = tags.get("highway", "")
		# Пропускаем пешеходные дорожки
		if highway_type in ["footway", "path", "cycleway", "track", "steps"]:
			continue

		var road_width: float = ROAD_WIDTHS.get(highway_type, 5.0)

		# Проверяем ВСЕ узлы дороги для детекции Т-образных перекрёстков
		for i in range(way_nodes.size()):
			var node = way_nodes[i]
			var node_key := "%.6f,%.6f" % [node.lat, node.lon]
			var local: Vector2 = _latlon_to_local(node.lat, node.lon)

			# Вычисляем направление дороги в этой точке
			var direction := Vector2.ZERO
			if i > 0:
				var prev_local: Vector2 = _latlon_to_local(way_nodes[i - 1].lat, way_nodes[i - 1].lon)
				direction = (local - prev_local).normalized()
			elif i < way_nodes.size() - 1:
				var next_local: Vector2 = _latlon_to_local(way_nodes[i + 1].lat, way_nodes[i + 1].lon)
				direction = (next_local - local).normalized()

			if not node_usage.has(node_key):
				node_usage[node_key] = {"pos": local, "types": [], "widths": [], "directions": []}

			if highway_type not in node_usage[node_key]["types"]:
				node_usage[node_key]["types"].append(highway_type)
				node_usage[node_key]["widths"].append(road_width)
				node_usage[node_key]["directions"].append(direction)

			# Собираем ВСЕ рукава дорог (направления наружу от перекрёстка)
			if not node_arms.has(node_key):
				node_arms[node_key] = []
			# Рукав назад (к предыдущему узлу) — направление наружу
			if i > 0:
				var prev_local2: Vector2 = _latlon_to_local(way_nodes[i - 1].lat, way_nodes[i - 1].lon)
				var outward_prev := (prev_local2 - local).normalized()
				node_arms[node_key].append({"direction": outward_prev, "width": road_width})
			# Рукав вперёд (к следующему узлу) — направление наружу
			if i < way_nodes.size() - 1:
				var next_local2: Vector2 = _latlon_to_local(way_nodes[i + 1].lat, way_nodes[i + 1].lon)
				var outward_next := (next_local2 - local).normalized()
				node_arms[node_key].append({"direction": outward_next, "width": road_width})

	# Определяем перекрёстки (2+ дороги сходятся ИЛИ 3+ рукава для однотипных T-образных)
	for node_key in node_usage:
		var info: Dictionary = node_usage[node_key]
		var types: Array = info["types"]

		# Вычисляем фильтрованные рукава ДО проверки (нужны для однотипных перекрёстков)
		var arms: Array = node_arms.get(node_key, [])
		var filtered_arms: Array = []
		for arm in arms:
			var dominated := false
			for existing in filtered_arms:
				var angle_diff := absf(arm["direction"].angle_to(existing["direction"]))
				if angle_diff < deg_to_rad(10.0):
					dominated = true
					# Оставляем более широкий
					if arm["width"] > existing["width"]:
						existing["direction"] = arm["direction"]
						existing["width"] = arm["width"]
					break
			if not dominated:
				filtered_arms.append(arm.duplicate())

		# Перекрёсток: 2+ типа дорог ИЛИ 3+ уникальных рукава (Т-образные однотипные)
		if types.size() < 2 and filtered_arms.size() < 3:
			continue

		# Проверяем на дубликат (перекрёсток уже есть рядом)
		var is_duplicate := false
		for existing_pos in _intersection_positions:
			if existing_pos.distance_to(info["pos"]) < 2.0:
				is_duplicate = true
				break
		if is_duplicate:
			continue

		_intersection_positions.append(info["pos"])

		# Находим самую широкую и вторую по ширине дорогу (из рукавов)
		var max_width := 0.0
		var second_width := 0.0
		var max_dir := Vector2.RIGHT
		for fa in filtered_arms:
			var w: float = fa["width"]
			if w > max_width:
				second_width = max_width
				max_width = w
				max_dir = fa["direction"]
			elif w > second_width:
				second_width = w
		if second_width == 0.0:
			second_width = max_width

		# Полуоси эллипса = половина ширины дорог
		var radius_a := max_width * 0.5  # вдоль широкой дороги
		var radius_b := second_width * 0.5  # вдоль узкой дороги
		_intersection_radii.append(Vector2(radius_a, radius_b))

		# Угол поворота = направление широкой дороги + 90 градусов
		var angle := atan2(max_dir.y, max_dir.x) + PI * 0.5
		_intersection_angles.append(angle)

		# Вычисляем максимальную разницу в приоритетах дорог
		var min_priority := 999
		var max_priority := 0
		for t in types:
			var p := _get_road_priority(t)
			min_priority = mini(min_priority, p)
			max_priority = maxi(max_priority, p)
		# true если разница в приоритетах <= 1 (нужна заплатка без разметки)
		var needs_patch := (max_priority - min_priority) <= 1
		_intersection_types.append(needs_patch)

		_intersection_roads.append(filtered_arms)

		# Строим контур перекрёстка
		var contour := _build_intersection_contour(_intersection_positions.size() - 1)
		_intersection_contours.append(contour)
		# Увеличенный контур для обрезки бордюров (+0.3м от контура)
		if contour.size() > 0:
			var center_pos: Vector2 = info["pos"]
			var curb_contour := PackedVector2Array()
			for cp in contour:
				var offset_dir := (cp - center_pos).normalized()
				curb_contour.append(cp + offset_dir * 0.3)
			_intersection_curb_contours.append(curb_contour)
		else:
			_intersection_curb_contours.append(PackedVector2Array())

		# Debug: выводим информацию о перекрёстке
		var arm_info := ""
		for fa in filtered_arms:
			arm_info += " w=%.1f" % fa["width"]
		print("  Intersection #%d at (%.1f, %.1f): %d arms%s, contour=%d pts" % [
			_intersection_positions.size() - 1, info["pos"].x, info["pos"].y,
			filtered_arms.size(), arm_info,
			contour.size()])

		# Добавляем в spatial hash — используем bounding radius контура
		var idx := _intersection_positions.size() - 1
		var hash_radius := maxf(radius_a, radius_b)
		if contour.size() > 0:
			for cp in contour:
				hash_radius = maxf(hash_radius, cp.distance_to(info["pos"]))
		# Запас для curb contour
		hash_radius += 1.0
		_add_intersection_to_spatial_hash(info["pos"], Vector2(hash_radius, hash_radius), idx)

	# Второй проход: создаём все объекты
	var skipped_buildings := 0
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])

		if nodes.size() < 2:
			continue

		# Фильтруем по принадлежности к чанку
		if filter_by_chunk:
			# Для линейных объектов (дороги) - проверяем пересечение с чанком
			# Для полигонов (здания) - проверяем центр
			var dominated_by_chunk := false
			if tags.has("highway"):
				# Дорога принадлежит чанку если хотя бы одна точка внутри
				# Дубликаты допустимы - дороги длинные и проходят через много чанков
				for node in nodes:
					var local: Vector2 = _latlon_to_local(node.lat, node.lon)
					if local.x >= chunk_min_x and local.x < chunk_max_x and local.y >= chunk_min_z and local.y < chunk_max_z:
						dominated_by_chunk = true
						break
			elif tags.has("waterway"):
				# Водные пути (реки) - рисуем если хотя бы одна точка в чанке
				# Дубликаты допустимы, т.к. реки длинные и проходят через много чанков
				for node in nodes:
					var local: Vector2 = _latlon_to_local(node.lat, node.lon)
					if local.x >= chunk_min_x and local.x < chunk_max_x and local.y >= chunk_min_z and local.y < chunk_max_z:
						dominated_by_chunk = true
						break
			elif tags.has("building") or tags.has("amenity"):
				# Здания - рисуем только если ЦЕНТР здания в чанке (по центру, не по точкам).
				# Иначе здания на границе чанков дублируются из-за OSM overlap.
				var center := _get_way_center(nodes)
				dominated_by_chunk = center.x >= chunk_min_x and center.x < chunk_max_x and center.y >= chunk_min_z and center.y < chunk_max_z
			else:
				# Для остальных полигонов (landuse, natural, leisure) проверяем центр
				var center := _get_way_center(nodes)
				dominated_by_chunk = center.x >= chunk_min_x and center.x < chunk_max_x and center.y >= chunk_min_z and center.y < chunk_max_z

			if not dominated_by_chunk:
				if tags.has("building") or tags.has("amenity"):
					skipped_buildings += 1
				continue

		# Пропускаем конкретные way по ID (нерелевантные/ошибочные дороги)
		var way_id_raw: int = int(way.get("id", 0))
		if way_id_raw in [75621890]:  # service road, не существует
			continue

		var _t0 := Time.get_ticks_msec()
		if tags.has("highway"):
			_create_road(nodes, tags, target, loader, way_id_raw)
			road_count += 1
			objects_this_frame += 1
		elif tags.has("building"):
			var way_id: int = int(way.get("id", 0))  # Ensure int conversion from JSON float
			_create_building(nodes, tags, target, loader, way_id)
			building_count += 1
			# Здания теперь в thread pool - не нужен await
		elif tags.has("amenity") and not tags.has("building"):
			# Amenity без building тега - создаём как здание
			_create_amenity_building(nodes, tags, target, loader)
			building_count += 1
		elif tags.has("natural"):
			_terrain_objects_queue.append({
				"type": "natural",
				"nodes": nodes,
				"tags": tags,
				"parent": target
			})
		elif tags.has("landuse"):
			_terrain_objects_queue.append({
				"type": "landuse",
				"nodes": nodes,
				"tags": tags,
				"parent": target,
				"way_id": int(way.get("id", 0))
			})
		elif tags.has("leisure"):
			_terrain_objects_queue.append({
				"type": "leisure",
				"nodes": nodes,
				"tags": tags,
				"parent": target
			})
		elif tags.has("waterway"):
			_create_waterway(nodes, tags, target, loader)
			objects_this_frame += 1

		# Frame budgeting ОТКЛЮЧЕН - вызывает исчезновение бизнес-вывесок
		# См. bisect: проблема появилась в коммите 00b311f
		# if objects_this_frame >= OBJECTS_PER_FRAME:
		# 	objects_this_frame = 0
		# 	await get_tree().process_frame
		pass

	# Ищем перекрёстки (узлы, которые используются несколькими дорогами)
	# Для Т-образных перекрёстков: проверяем ВСЕ узлы дорог
	var node_road_count: Dictionary = {}  # node_key -> count (сколько дорог проходит через узел)
	var node_positions: Dictionary = {}  # node_key -> Vector2
	var node_road_types: Dictionary = {}  # node_key -> Array of highway types

	for way in ways:
		var way_tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])

		if not way_tags.has("highway"):
			continue

		var highway_type: String = way_tags.get("highway", "")
		# Исключаем пешеходные дороги из детекции перекрёстков
		if highway_type in ["footway", "path", "cycleway", "steps", "pedestrian"]:
			continue

		if way_nodes.size() < 2:
			continue

		# Проверяем ВСЕ узлы дороги (не только концы) для детекции Т-образных перекрёстков
		for node in way_nodes:
			var node_key := "%.5f,%.5f" % [node.lat, node.lon]
			var local: Vector2 = _latlon_to_local(node.lat, node.lon)

			# Фильтруем по чанку
			if filter_by_chunk:
				if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
					continue

			if not node_road_count.has(node_key):
				node_road_count[node_key] = 0
				node_positions[node_key] = local
				node_road_types[node_key] = []

			node_road_count[node_key] += 1
			if highway_type not in node_road_types[node_key]:
				node_road_types[node_key].append(highway_type)

	# Создаём светофоры, знаки и заплатки на перекрёстках
	var intersection_count := 0
	for node_key in node_road_count:
		if node_road_count[node_key] >= 2:  # Перекрёсток - 2+ дороги сходятся концами
			var pos: Vector2 = node_positions[node_key]
			var road_types: Array = node_road_types[node_key]
			var elevation := 0.0

			# Считаем дороги для которых делаем заплатки и бордюры
			var major_road_count := 0
			var max_width := 0.0
			var max_height_offset := 0.006  # default (residential)
			for t in road_types:
				if t in ["motorway", "trunk", "primary", "secondary", "tertiary", "residential", "service"]:
					major_road_count += 1
				var w: float = ROAD_WIDTHS.get(t, 6.0)
				max_width = maxf(max_width, w)
				# height_offset по типу дороги (совпадает с _create_road_immediate)
				var ho := 0.006
				match t:
					"motorway", "trunk": ho = 0.012
					"primary": ho = 0.010
					"secondary": ho = 0.008
					"tertiary": ho = 0.007
					"residential", "unclassified": ho = 0.006
					"service": ho = 0.004
				max_height_offset = maxf(max_height_offset, ho)
			# Ищем данные эллипса для этого перекрёстка
			var intersection_idx := _find_nearest_intersection(pos, 2.0)

			# Смещение знаков/светофоров к краю дороги (перпендикулярно направлению)
			var sign_offset := Vector2(5, 5)  # Fallback
			if intersection_idx >= 0:
				var angle: float = _intersection_angles[intersection_idx]
				# Перпендикуляр к направлению дороги
				var perp := Vector2(cos(angle), sin(angle))
				sign_offset = perp * (max_width * 0.5 + 0.5)  # К краю дороги + 0.5м

			# На крупных перекрёстках - светофор, на мелких - знаки
			var has_primary := "primary" in road_types or "secondary" in road_types
			if has_primary and node_road_count[node_key] >= 3:
				_create_traffic_light(pos + sign_offset, elevation, target)
			else:
				# На обычных перекрёстках - один знак
				_create_yield_sign(pos + sign_offset, elevation, target)

			# Создаём заплатку без разметки если есть хотя бы 1 дорога (service+)
			if major_road_count >= 1:
				_create_intersection_patch(pos, target, intersection_idx, max_height_offset, chunk_key)

			# Бордюры перекрёстков теперь генерируются по краям террейна в _create_chunk_ground_terrain
			if intersection_idx < 0:
				print("  NO intersection contour: pos=(%.1f,%.1f) types=%s major=%d idx=%d" % [pos.x, pos.y, str(road_types), major_road_count, intersection_idx])

			intersection_count += 1

	# Обрабатываем точечные объекты (деревья, знаки, фонари)
	var point_objects: Array = osm_data.get("point_objects", [])
	var tree_count := 0
	var sign_count := 0
	var lamp_count := 0

	for obj in point_objects:
		var tags: Dictionary = obj.get("tags", {})
		var lat: float = obj.get("lat", 0.0)
		var lon: float = obj.get("lon", 0.0)
		var local: Vector2 = _latlon_to_local(lat, lon)

		# Фильтруем по чанку
		if filter_by_chunk:
			if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
				continue

		var elevation := 0.0

		if tags.get("natural") == "tree":
			# Пропускаем деревья слишком близко к дорогам
			if not _is_point_near_road(local, 3.0):
				var tree_chunk_key := chunk_key
				if tree_chunk_key.is_empty():
					var cx := int(floor(local.x / chunk_size))
					var cz := int(floor(local.y / chunk_size))
					tree_chunk_key = "%d,%d" % [cx, cz]
				_add_tree_to_batch(tree_chunk_key, local, elevation, target)
				tree_count += 1
		elif tags.get("amenity") == "waste_disposal":
			_create_garbage_container(local, elevation, target)
		elif tags.has("traffic_sign"):
			_create_traffic_sign(local, elevation, tags, target)
			sign_count += 1
		elif tags.get("highway") == "street_lamp":
			# Не ставим фонари на парковках
			if not _is_point_in_any_parking(local):
				if chunk_key != "":
					# Use batching for OSM point lamps too
					var lamp_pos := Vector3(local.x, elevation, local.y)
					# Direction toward nearest road (approximate - use zero if not near road)
					var road_dir := Vector3.FORWARD
					_add_lamp_to_batch(chunk_key, lamp_pos, road_dir, target)
				else:
					_create_street_lamp(local, elevation, target)
				lamp_count += 1

	print("OSM: Generated %d roads, %d buildings, %d trees, %d signs, %d lamps, %d intersections" % [road_count, building_count, tree_count, sign_count, lamp_count, intersection_count])

	# Обрабатываем автобусные остановки
	var bus_stops: Array = osm_data.get("bus_stops", [])
	var bus_stop_count := 0
	# Список остановок для исключения (не существуют в реальности)
	var excluded_stops := ["Улица Партизана Окинина"]
	for stop in bus_stops:
		var lat: float = stop.get("lat", 0.0)
		var lon: float = stop.get("lon", 0.0)
		var tags: Dictionary = stop.get("tags", {})
		var stop_name: String = tags.get("name", "")

		# Пропускаем исключённые остановки
		if stop_name in excluded_stops:
			continue

		var local: Vector2 = _latlon_to_local(lat, lon)

		# Фильтруем по чанку
		if filter_by_chunk:
			if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
				continue

		var elevation := 0.0
		_create_bus_stop(local, elevation, tags, target)
		bus_stop_count += 1

	if bus_stop_count > 0:
		print("OSM: Created %d bus stops" % bus_stop_count)

	# Custom models (гаражи, веранды и т.д. из JSON)
	if chunk_key != "":
		_place_custom_models_for_chunk(chunk_key, target)

	# Деревья по площади чанка (террейн создаётся позже в _finalize_road_batches_for_chunk)
	if chunk_key != "":
		_generate_trees_for_chunk(chunk_key, target)

	# OPTIMIZATION: Помечаем чанк для финализации road batches (когда road_queue опустеет)
	var batch_chunk_key := chunk_key if chunk_key != "" else "initial"
	if not _pending_batch_chunks.has(batch_chunk_key):
		_pending_batch_chunks.append(batch_chunk_key)
		print("OSM: Marked chunk '%s' for road batch finalization" % batch_chunk_key)


## Вычисляет высоту дороги с учётом моста/туннеля/layer
## Возвращает словарь {height: float, is_bridge: bool, is_tunnel: bool, layer: int, ramp_length: float}
func _calculate_road_elevation(tags: Dictionary, base_elevation: float, road_length: float = 0.0) -> Dictionary:
	var result := {
		"height": base_elevation,
		"is_bridge": false,
		"is_tunnel": false,
		"layer": 0,
		"bridge_height": 0.0,
		"ramp_length": 0.0
	}

	# Парсим layer (по умолчанию 0)
	var layer: int = 0
	if tags.has("layer"):
		var layer_str: String = str(tags.get("layer", "0"))
		layer = int(layer_str) if layer_str.is_valid_int() else 0
		layer = clamp(layer, -5, 5)
	result.layer = layer

	# Проверяем bridge
	var bridge_val: String = str(tags.get("bridge", ""))
	if bridge_val == "yes" or bridge_val == "viaduct" or bridge_val == "true":
		result.is_bridge = true
		# Высота моста пропорциональна длине (эталон: 100м → 3м)
		# Короткие мосты ниже и с более пологими рампами
		var length_ratio: float = clampf(road_length / BRIDGE_REFERENCE_LENGTH, 0.0, 1.0) if road_length > 0.0 else 1.0
		var base_height: float = maxf(BRIDGE_MIN_HEIGHT, BRIDGE_BASE_HEIGHT * length_ratio)
		# Добавляем layer если есть
		var bridge_height: float = base_height + maxf(0, layer) * LAYER_HEIGHT
		result.bridge_height = bridge_height
		result.height = base_elevation + bridge_height
		# Рампа пропорциональна длине моста (30% с каждой стороны, макс 30м)
		var ramp_from_ratio: float = road_length * BRIDGE_RAMP_RATIO if road_length > 0.0 else BRIDGE_MAX_RAMP
		result.ramp_length = minf(BRIDGE_MAX_RAMP, ramp_from_ratio)

	# Проверяем tunnel
	elif str(tags.get("tunnel", "")) == "yes":
		result.is_tunnel = true
		# Туннели пока просто помечаем, не опускаем под землю (сложно визуализировать)
		result.height = base_elevation

	# Только layer без bridge/tunnel - поднимаем эстакады
	elif layer > 0:
		# Эстакада (layer > 0 без bridge=yes) - тоже поднимаем
		result.is_bridge = true
		# Для эстакад тоже применяем пропорцию
		var length_ratio: float = clampf(road_length / BRIDGE_REFERENCE_LENGTH, 0.0, 1.0) if road_length > 0.0 else 1.0
		var base_height: float = maxf(BRIDGE_MIN_HEIGHT, BRIDGE_BASE_HEIGHT * length_ratio)
		result.bridge_height = base_height + (layer - 1) * LAYER_HEIGHT  # layer уже учтён в base
		result.height = base_elevation + result.bridge_height
		var ramp_from_ratio: float = road_length * BRIDGE_RAMP_RATIO if road_length > 0.0 else BRIDGE_MAX_RAMP
		result.ramp_length = minf(BRIDGE_MAX_RAMP, ramp_from_ratio)

	return result


## Smooth step interpolation для плавных рамп (ease in/out)
func _smooth_step(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Вычисляет усреднённые перпендикуляры для каждой точки пути
## Для сглаживания углов дороги на поворотах
func _compute_averaged_perpendiculars(points: PackedVector2Array) -> Array[Vector2]:
	var perpendiculars: Array[Vector2] = []

	for i in range(points.size()):
		var perp: Vector2

		if i == 0:
			# Первая точка - перпендикуляр к первому сегменту
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == points.size() - 1:
			# Последняя точка - перпендикуляр к последнему сегменту
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			# Средняя точка - усреднённый перпендикуляр
			var dir1: Vector2 = (points[i] - points[i - 1]).normalized()
			var dir2: Vector2 = (points[i + 1] - points[i]).normalized()
			var avg_dir: Vector2 = (dir1 + dir2).normalized()
			perp = Vector2(-avg_dir.y, avg_dir.x)

		perpendiculars.append(perp)

	return perpendiculars


func _create_road(nodes: Array, tags: Dictionary, parent: Node3D, _loader: Node, way_id: int = 0) -> void:
	if not enable_roads:
		return
	# Добавляем в очередь для отложенного создания
	_road_queue.append({
		"nodes": nodes,
		"tags": tags,
		"parent": parent,
		"way_id": way_id
	})

	# Сегменты дорог сохраняем сразу (нужны для знаков парковки и проверки фонарей)
	# Используем сглаженные координаты — чтобы spatial hash соответствовал реальной геометрии дорог
	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)
	var raw_pts := PackedVector2Array()
	raw_pts.resize(nodes.size())
	for i in range(nodes.size()):
		raw_pts[i] = _latlon_to_local(nodes[i].lat, nodes[i].lon)
	var smoothed_pts := _smooth_road_corners(raw_pts)
	for i in range(smoothed_pts.size() - 1):
		var seg := {"p1": smoothed_pts[i], "p2": smoothed_pts[i + 1], "width": width}
		_road_segments.append(seg)
		_add_road_segment_to_spatial_hash(seg)


## Немедленное создание дороги (вызывается из очереди)
func _create_road_immediate(nodes: Array, tags: Dictionary, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	# Pre-compute local points ONCE (avoids 5x redundant _latlon_to_local calls)
	var local_points := PackedVector2Array()
	local_points.resize(nodes.size())
	for i in range(nodes.size()):
		local_points[i] = _latlon_to_local(nodes[i].lat, nodes[i].lon)

	# Вычисляем длину дороги для расчёта рамп
	var road_length := 0.0
	for i in range(local_points.size() - 1):
		road_length += local_points[i].distance_to(local_points[i + 1])

	# Проверяем является ли дорога мостом/туннелем
	var elevation_info := _calculate_road_elevation(tags, 0.0, road_length)
	var is_bridge: bool = elevation_info.get("is_bridge", false)

	var texture_key: String
	var height_offset: float
	var curb_height: float
	match highway_type:
		"motorway", "trunk":
			texture_key = "highway"
			height_offset = 0.012
			curb_height = 0.0
		"primary":
			texture_key = "primary"
			height_offset = 0.010
			curb_height = 0.0
		"secondary":
			texture_key = "primary"
			height_offset = 0.008
			curb_height = 0.0
		"tertiary":
			texture_key = "residential"
			height_offset = 0.007
			curb_height = 0.0
		"residential", "unclassified":
			texture_key = "residential"
			height_offset = 0.006
			curb_height = 0.0
		"service":
			texture_key = "residential"
			height_offset = 0.004
			curb_height = 0.0
		"footway", "path", "cycleway", "track":
			texture_key = "path"
			height_offset = 0.23
			curb_height = 0.0
		_:
			texture_key = "residential"
			height_offset = 0.006
			curb_height = 0.0

	# Сглаживаем точки один раз — используются и для дороги, и для бордюров
	var smoothed_points: PackedVector2Array = _smooth_road_corners(local_points)

	# Создаём дорогу - обычную или мост
	if is_bridge:
		_create_bridge_road(nodes, width, texture_key, height_offset, elevation_info, parent)
		var b_height: float = elevation_info.get("bridge_height", 0.0)
		var b_ramp: float = elevation_info.get("ramp_length", 0.0)
		var b_layer: int = elevation_info.get("layer", 0)
		if b_height > 0:
			print("OSM: Bridge created: height=%.1fm, ramp=%.1fm, layer=%d" % [b_height, b_ramp, b_layer])
	else:
		# Пешеходные дорожки: crossing на уровне дороги, off-road — elevated
		if highway_type in ["footway", "path"] and smoothed_points.size() >= 2:
			var is_tagged_crossing: bool = tags.get("footway", "") == "crossing"
			var on_road: Array[bool] = []
			for p in smoothed_points:
				on_road.append(_is_point_on_vehicle_road(p))
			var current_pts := PackedVector2Array()
			current_pts.append(smoothed_points[0])
			var current_on := on_road[0]
			var last_off_road_pt := smoothed_points[0]  # fallback: начало пути
			var has_before_off := true  # smoothed_points[0] всегда годится как reference
			if not current_on:
				last_off_road_pt = smoothed_points[0]
			for i in range(1, smoothed_points.size()):
				if on_road[i] != current_on:
					var edge_pt := _find_road_edge_point(smoothed_points[i - 1], current_on, smoothed_points[i])
					current_pts.append(edge_pt)
					if current_pts.size() >= 2:
						if current_on:
							if is_tagged_crossing or (has_before_off and _is_full_road_crossing(last_off_road_pt, smoothed_points[i])):
								_add_road_to_batch_fast(current_pts, width, "crossing", 0.013, parent)
								if enable_crossing_signs:
									_enqueue_crossing_signs(current_pts, parent)
						else:
							_add_road_to_batch_fast(current_pts, width, "path", 0.23, parent)
							last_off_road_pt = smoothed_points[i - 1]
							has_before_off = true
					current_pts = PackedVector2Array()
					current_pts.append(edge_pt)
					current_on = on_road[i]
				else:
					if not current_on:
						last_off_road_pt = smoothed_points[i]
						has_before_off = true
				current_pts.append(smoothed_points[i])
			if current_pts.size() >= 2:
				if current_on:
					var last_pt: Vector2 = smoothed_points[smoothed_points.size() - 1]
					if is_tagged_crossing or (has_before_off and _is_full_road_crossing(last_off_road_pt, last_pt)):
						_add_road_to_batch_fast(current_pts, width, "crossing", 0.013, parent)
						if enable_crossing_signs:
							_enqueue_crossing_signs(current_pts, parent)
				else:
					_add_road_to_batch_fast(current_pts, width, "path", 0.23, parent)
		else:
			_add_road_to_batch_fast(smoothed_points, width, texture_key, height_offset, parent)

	if curb_height > 0.0:
		_curb_queue.append({
			"local_points": smoothed_points,
			"width": width,
			"height_offset": height_offset,
			"curb_height": curb_height,
			"parent": parent,
			"is_bridge": is_bridge,
			"bridge_info": elevation_info
		})

	# Фонари (только крупные дороги)
	if highway_type in ["motorway", "trunk", "primary", "secondary", "tertiary"]:
		_generate_street_lamps_fast(smoothed_points, width, parent)

	# Люки
	if highway_type in ["primary", "secondary", "tertiary", "residential", "unclassified"]:
		_generate_manholes_fast(smoothed_points, width, parent)

	# RoadNetwork для NPC
	_extract_road_for_traffic_fast(smoothed_points, tags, elevation_info)


## Вычисляет геометрию дороги в worker thread (чистая математика, thread-safe)
func _compute_road_geometry_thread(task_data: Dictionary) -> void:
	var nodes: Array = task_data.nodes
	var tags: Dictionary = task_data.tags
	var t_chunk_size: float = task_data.chunk_size
	var t_start_lat: float = task_data.start_lat
	var t_start_lon: float = task_data.start_lon
	var t_lon_scale: float = task_data.lon_scale
	var chunk_key: String = task_data.chunk_key

	var highway_type: String = tags.get("highway", "residential")
	var width: float = ROAD_WIDTHS.get(highway_type, 5.0)

	# lat/lon → local (thread-safe: uses only passed constants)
	var local_points := PackedVector2Array()
	local_points.resize(nodes.size())
	for i in range(nodes.size()):
		var dx: float = (nodes[i].lon - t_start_lon) * t_lon_scale
		var dz: float = (nodes[i].lat - t_start_lat) * 111000.0
		local_points[i] = Vector2(dx, -dz)

	# Road length
	var road_length := 0.0
	for i in range(local_points.size() - 1):
		road_length += local_points[i].distance_to(local_points[i + 1])

	# Bridge check
	var elevation_info := _calculate_road_elevation(tags, 0.0, road_length)
	var is_bridge: bool = elevation_info.get("is_bridge", false)

	# Road parameters
	var texture_key: String
	var height_offset: float
	var curb_height: float
	match highway_type:
		"motorway", "trunk":
			texture_key = "highway"
			height_offset = 0.012
			curb_height = 0.0
		"primary":
			texture_key = "primary"
			height_offset = 0.010
			curb_height = 0.0
		"secondary":
			texture_key = "primary"
			height_offset = 0.008
			curb_height = 0.0
		"tertiary":
			texture_key = "residential"
			height_offset = 0.007
			curb_height = 0.0
		"residential", "unclassified":
			texture_key = "residential"
			height_offset = 0.006
			curb_height = 0.0
		"service":
			texture_key = "residential"
			height_offset = 0.004
			curb_height = 0.0
		"footway", "path", "cycleway", "track":
			texture_key = "path"
			height_offset = 0.23
			curb_height = 0.0
		_:
			texture_key = "residential"
			height_offset = 0.006
			curb_height = 0.0

	# Smoothing (thread-safe: pure math)
	var smoothed_points: PackedVector2Array = _smooth_road_corners(local_points)

	# Build geometry if not bridge
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	if not is_bridge and highway_type not in ["footway", "path"]:
		# Validate + clip (thread-safe: pure math)
		# Skip vertex gen for footway/path — they get re-split on main thread anyway
		var points: PackedVector2Array = _validate_road_direction(smoothed_points)
		if chunk_key != "initial" and chunk_key != "":
			var ck_parts: PackedStringArray = chunk_key.split(",")
			var ck_x := int(ck_parts[0])
			var ck_z := int(ck_parts[1])
			var margin := width + 5.0
			points = _clip_polyline_to_rect(points,
				float(ck_x) * t_chunk_size - margin,
				float(ck_x + 1) * t_chunk_size + margin,
				float(ck_z) * t_chunk_size - margin,
				float(ck_z + 1) * t_chunk_size + margin)

		if points.size() >= 2:
			var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
			var z_offset: float = hash_val * 0.00003
			var half_w: float = width * 0.5
			var h: float = height_offset + z_offset
			var n_points: int = points.size()

			# Perpendiculars
			var perpendiculars := PackedVector2Array()
			perpendiculars.resize(n_points)
			for i in range(n_points):
				var perp: Vector2
				if i == 0:
					var dir: Vector2 = (points[1] - points[0]).normalized()
					perp = Vector2(-dir.y, dir.x)
				elif i == n_points - 1:
					var dir: Vector2 = (points[i] - points[i - 1]).normalized()
					perp = Vector2(-dir.y, dir.x)
				else:
					var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
					perp = Vector2(-dir_out.y, dir_out.x)
				perpendiculars[i] = perp

			# Vertices
			var accumulated_length: float = 0.0
			var uv_scale: float = 0.1
			for i in range(n_points):
				var p: Vector2 = points[i]
				var perp: Vector2 = perpendiculars[i]
				if i > 0:
					accumulated_length += points[i - 1].distance_to(p)
				var uv_y: float = accumulated_length * uv_scale
				var left_pos := Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w)
				var right_pos := Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w)
				vertices.append(Vector3(left_pos.x, h, left_pos.y))
				uvs.append(Vector2(0.0, uv_y))
				normals.append(Vector3.UP)
				vertices.append(Vector3(right_pos.x, h, right_pos.y))
				uvs.append(Vector2(1.0, uv_y))
				normals.append(Vector3.UP)

			# Indices
			for i in range(n_points - 1):
				var idx: int = i * 2
				indices.append(idx)
				indices.append(idx + 3)
				indices.append(idx + 1)
				indices.append(idx)
				indices.append(idx + 2)
				indices.append(idx + 3)

	# Store result via mutex
	var result := {
		"smoothed_points": smoothed_points,
		"vertices": vertices,
		"uvs": uvs,
		"normals": normals,
		"indices": indices,
		"texture_key": texture_key,
		"width": width,
		"height_offset": height_offset,
		"curb_height": curb_height,
		"highway_type": highway_type,
		"chunk_key": chunk_key,
		"parent": task_data.parent,
		"tags": tags,
		"nodes": nodes,
		"is_bridge": is_bridge,
		"elevation_info": elevation_info,
		"way_id": task_data.get("way_id", 0)
	}
	_road_mutex.lock()
	_road_results.append(result)
	_pending_road_tasks -= 1
	_road_mutex.unlock()


## Применяет результат road geometry из worker thread (main thread only)
func _apply_road_result(result: Dictionary) -> void:
	var parent: Node3D = result.parent
	if not is_instance_valid(parent):
		return

	var chunk_key: String = result.chunk_key
	var texture_key: String = result.texture_key
	var smoothed_points: PackedVector2Array = result.smoothed_points
	var width: float = result.width
	var height_offset: float = result.height_offset
	var curb_height: float = result.curb_height
	var highway_type: String = result.highway_type
	var is_bridge: bool = result.is_bridge
	var elevation_info: Dictionary = result.elevation_info

	if is_bridge:
		_create_bridge_road(result.nodes, width, texture_key, height_offset, elevation_info, parent)
	elif highway_type in ["footway", "path"] and smoothed_points.size() >= 2:
		# Defer footway splitting + vertex gen to avoid 10-15ms spikes from
		# _is_point_on_vehicle_road (spatial hash + intersection contours per point)
		var cleaned: PackedVector2Array = _remove_polyline_zigzag(smoothed_points)
		if cleaned.size() >= 2:
			_deferred_footway_queue.append({
				"smoothed_points": cleaned,
				"width": width,
				"tags": result.get("tags", {}),
				"parent": parent
			})
	else:
		# Merge geometry into batch data
		var verts: PackedVector3Array = result.vertices
		if verts.size() >= 4:
			if not _road_batch_data.has(chunk_key):
				_road_batch_data[chunk_key] = {}
			if not _road_batch_data[chunk_key].has(texture_key):
				_road_batch_data[chunk_key][texture_key] = {
					"vertices": PackedVector3Array(),
					"uvs": PackedVector2Array(),
					"normals": PackedVector3Array(),
					"indices": PackedInt32Array(),
					"parent": parent
				}
			var batch: Dictionary = _road_batch_data[chunk_key][texture_key]
			var vertex_offset: int = batch["vertices"].size()
			batch["vertices"].append_array(verts)
			batch["uvs"].append_array(result.uvs)
			batch["normals"].append_array(result.normals)
			# Offset indices — pre-offset in bulk instead of per-element append
			var src_indices: PackedInt32Array = result.indices
			if vertex_offset > 0:
				var offset_indices := PackedInt32Array()
				offset_indices.resize(src_indices.size())
				for k in range(src_indices.size()):
					offset_indices[k] = src_indices[k] + vertex_offset
				batch["indices"].append_array(offset_indices)
			else:
				batch["indices"].append_array(src_indices)

	# Строим коридор-полигон из НЕОБРЕЗАННЫХ сглаженных точек дороги для выреза террейна
	# Используем smoothed_points + width → перпендикуляры → left edge + right edge
	# Это гарантирует что коридор покрывает всю длину дороги и совпадает с мешем
	if not is_bridge and highway_type not in ["footway", "path", "cycleway", "track", "steps"] and smoothed_points.size() >= 2:
		var validated: PackedVector2Array = _validate_road_direction(smoothed_points)
		if validated.size() >= 2:
			var half_w: float = width * 0.5
			var n_pts: int = validated.size()
			# Вычисляем перпендикуляры (аналогично _add_road_to_batch_fast)
			var perps := PackedVector2Array()
			perps.resize(n_pts)
			for i in range(n_pts):
				var perp: Vector2
				if i == 0:
					var d: Vector2 = (validated[1] - validated[0]).normalized()
					perp = Vector2(-d.y, d.x)
				elif i == n_pts - 1:
					var d: Vector2 = (validated[i] - validated[i - 1]).normalized()
					perp = Vector2(-d.y, d.x)
				else:
					var d: Vector2 = (validated[i + 1] - validated[i]).normalized()
					perp = Vector2(-d.y, d.x)
				perps[i] = perp
			# Коридор: left edge forward, right edge backward
			var corridor := PackedVector2Array()
			for i in range(n_pts):
				corridor.append(validated[i] - perps[i] * half_w)
			for i in range(n_pts - 1, -1, -1):
				corridor.append(validated[i] + perps[i] * half_w)
			# Регистрируем во ВСЕХ чанках, которые коридор пересекает
			var corr_min_x := corridor[0].x
			var corr_max_x := corridor[0].x
			var corr_min_z := corridor[0].y
			var corr_max_z := corridor[0].y
			for ci in range(1, corridor.size()):
				corr_min_x = minf(corr_min_x, corridor[ci].x)
				corr_max_x = maxf(corr_max_x, corridor[ci].x)
				corr_min_z = minf(corr_min_z, corridor[ci].y)
				corr_max_z = maxf(corr_max_z, corridor[ci].y)
			var ck0_x := int(floorf(corr_min_x / chunk_size))
			var ck1_x := int(floorf(corr_max_x / chunk_size))
			var ck0_z := int(floorf(corr_min_z / chunk_size))
			var ck1_z := int(floorf(corr_max_z / chunk_size))
			for cx in range(ck0_x, ck1_x + 1):
				for cz in range(ck0_z, ck1_z + 1):
					var ck := "%d,%d" % [cx, cz]
					if not _chunk_terrain_roads.has(ck):
						_chunk_terrain_roads[ck] = []
					_chunk_terrain_roads[ck].append(corridor)

	# Curbs
	if curb_height > 0.0:
		_curb_queue.append({
			"local_points": smoothed_points,
			"width": width,
			"height_offset": height_offset,
			"curb_height": curb_height,
			"parent": parent,
			"is_bridge": is_bridge,
			"bridge_info": elevation_info
		})

	# Lamps (major roads only) - deferred to avoid blocking apply
	if highway_type in ["motorway", "trunk", "primary", "secondary", "tertiary"]:
		_deferred_lamp_queue.append({"points": smoothed_points, "width": width, "parent": parent})

	# Manholes - deferred
	if highway_type in ["primary", "secondary", "tertiary", "residential", "unclassified"]:
		_deferred_manhole_queue.append({"points": smoothed_points, "width": width, "parent": parent})

	# Road network for NPC - deferred
	_deferred_traffic_queue.append({"points": smoothed_points, "tags": result.tags, "elevation_info": elevation_info})



## Создаёт дорогу-мост с рампами подъёма/спуска и опорами
func _create_bridge_road(nodes: Array, width: float, texture_key: String, height_offset: float, bridge_info: Dictionary, parent: Node3D) -> void:
	if nodes.size() < 2:
		return

	# Конвертируем в локальные координаты
	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Вычисляем общую длину моста
	var total_length := 0.0
	for i in range(points.size() - 1):
		total_length += points[i].distance_to(points[i + 1])

	if total_length < 1.0:
		return

	# Добавляем промежуточные точки для плавных рамп (минимум каждые 10м)
	const BRIDGE_SEGMENT_LENGTH := 10.0
	if total_length > BRIDGE_SEGMENT_LENGTH * 2:
		var refined_points: PackedVector2Array = []
		for i in range(points.size() - 1):
			var p1: Vector2 = points[i]
			var p2: Vector2 = points[i + 1]
			var seg_length: float = p1.distance_to(p2)
			var num_subdivs: int = max(1, int(ceil(seg_length / BRIDGE_SEGMENT_LENGTH)))

			refined_points.append(p1)
			for j in range(1, num_subdivs):
				var t: float = float(j) / float(num_subdivs)
				refined_points.append(p1.lerp(p2, t))
		refined_points.append(points[points.size() - 1])
		points = refined_points

	# Параметры моста
	var bridge_height: float = bridge_info.get("bridge_height", BRIDGE_BASE_HEIGHT)
	var ramp_length: float = bridge_info.get("ramp_length", minf(BRIDGE_MAX_RAMP, total_length * BRIDGE_RAMP_RATIO))

	# Создаём массивы для меша
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	var half_w := width * 0.5
	var accumulated_length := 0.0

	# Вычисляем перпендикуляры для каждой точки (усреднённые для сглаживания)
	var perpendiculars: Array[Vector2] = _compute_averaged_perpendiculars(points)

	for i in range(points.size()):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]

		var base_elev: float = height_offset

		# Вычисляем высоту моста в этой точке с учётом рамп
		var point_height := base_elev
		if ramp_length > 0.1:
			# Рампа в начале
			if accumulated_length < ramp_length:
				var t: float = accumulated_length / ramp_length
				t = _smooth_step(t)
				point_height = base_elev + bridge_height * t
			# Рампа в конце
			elif accumulated_length > total_length - ramp_length:
				var t: float = (total_length - accumulated_length) / ramp_length
				t = _smooth_step(t)
				point_height = base_elev + bridge_height * t
			# Плоская часть моста
			else:
				point_height = base_elev + bridge_height
		else:
			# Короткий мост - просто приподнимаем
			point_height = base_elev + bridge_height

		# Добавляем вершины (левая и правая сторона дороги)
		var left := Vector3(p.x - perp.x * half_w, point_height, p.y - perp.y * half_w)
		var right := Vector3(p.x + perp.x * half_w, point_height, p.y + perp.y * half_w)

		vertices.append(left)
		vertices.append(right)

		# UV координаты
		uvs.append(Vector2(0.0, accumulated_length * 0.1))
		uvs.append(Vector2(1.0, accumulated_length * 0.1))

		# Нормали (вверх)
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)

		# Обновляем накопленную длину
		if i < points.size() - 1:
			accumulated_length += points[i].distance_to(points[i + 1])

	# Создаём индексы (квады -> треугольники)
	for i in range(points.size() - 1):
		var base_idx := i * 2
		# Первый треугольник
		indices.append(base_idx)
		indices.append(base_idx + 2)
		indices.append(base_idx + 1)
		# Второй треугольник
		indices.append(base_idx + 1)
		indices.append(base_idx + 2)
		indices.append(base_idx + 3)

	# Создаём меш
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Материал
	var material: Material = WetRoadMaterial.create_road_shader_material(
		_road_textures.get(texture_key, null),
		_normal_textures.get("asphalt", null),
		_is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null)
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, texture_key)

	# Создаём MeshInstance3D
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BridgeRoad"
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material  # Используем material_override для обновления wet mode
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh_instance)

	# Создаём коллизию для моста
	_create_bridge_collision(vertices, indices, parent)

	# Создаём опоры моста
	_create_bridge_pillars(points, bridge_height, ramp_length, total_length, parent)

	# Создаём отбойники по краям моста
	_create_bridge_barriers(points, width, bridge_height, ramp_length, total_length, height_offset, parent)


## Создаёт коллизию для моста
func _create_bridge_collision(vertices: PackedVector3Array, indices: PackedInt32Array, parent: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "BridgeCollision"
	body.collision_layer = 1  # Road layer

	var shape := CollisionShape3D.new()
	var coll_shape := ConcavePolygonShape3D.new()

	# Конвертируем индексы в PackedVector3Array для faces
	var faces := PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(vertices[indices[i]])
		faces.append(vertices[indices[i + 1]])
		faces.append(vertices[indices[i + 2]])

	coll_shape.set_faces(faces)
	shape.shape = coll_shape
	body.add_child(shape)
	parent.add_child(body)


## Создаёт опоры моста
func _create_bridge_pillars(points: PackedVector2Array, bridge_height: float, ramp_length: float, total_length: float, parent: Node3D) -> void:
	# Короткие и низкие мосты не нуждаются в опорах
	if bridge_height < 1.5 or total_length < BRIDGE_MIN_LENGTH_FOR_PILLARS:
		return

	# Создаём опоры только на плоской части моста (не на рампах)
	var accumulated := 0.0
	var last_pillar_pos := -BRIDGE_PILLAR_SPACING  # Чтобы первая опора была сразу после рампы

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var segment_length := p1.distance_to(p2)

		# Начало и конец сегмента в терминах accumulated distance
		var seg_start := accumulated
		var seg_end := accumulated + segment_length

		# Границы плоской части (после рампы в начале, до рампы в конце)
		var flat_start := ramp_length
		var flat_end := total_length - ramp_length

		# Пересечение сегмента с плоской частью
		var check_start := maxf(seg_start, flat_start)
		var check_end := minf(seg_end, flat_end)

		if check_start < check_end:
			# Создаём опоры вдоль этого сегмента
			var pos := check_start
			while pos <= check_end:
				if pos - last_pillar_pos >= BRIDGE_PILLAR_SPACING:
					# Интерполируем позицию на сегменте
					var t := (pos - seg_start) / segment_length if segment_length > 0 else 0.0
					t = clampf(t, 0.0, 1.0)
					var pillar_pos_2d := p1.lerp(p2, t)
					var ground_elev := 0.0

					# Создаём опору
					_create_single_pillar(pillar_pos_2d, ground_elev, bridge_height, parent)
					last_pillar_pos = pos

				pos += BRIDGE_PILLAR_SPACING * 0.5  # Шаг проверки меньше spacing для точности

		accumulated += segment_length


## Создаёт одну опору моста
func _create_single_pillar(pos: Vector2, ground_elev: float, bridge_height: float, parent: Node3D) -> void:
	var pillar := MeshInstance3D.new()
	pillar.name = "BridgePillar"

	# Создаём цилиндрический меш для опоры
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = BRIDGE_PILLAR_RADIUS
	cylinder.bottom_radius = BRIDGE_PILLAR_RADIUS * 1.3  # Немного шире внизу для устойчивости
	cylinder.height = bridge_height
	pillar.mesh = cylinder

	# Материал опоры (бетон)
	var material := StandardMaterial3D.new()
	material.albedo_color = BRIDGE_PILLAR_COLOR
	material.roughness = 0.85
	material.metallic = 0.0
	pillar.material_override = material

	# Позиция: центр цилиндра на половине высоты от земли
	pillar.position = Vector3(pos.x, ground_elev + bridge_height * 0.5, pos.y)

	parent.add_child(pillar)

	# Добавляем коллизию для опоры
	var body := StaticBody3D.new()
	body.name = "PillarCollision"
	body.collision_layer = 2  # Obstacle layer

	var shape := CollisionShape3D.new()
	var coll_shape := CylinderShape3D.new()
	coll_shape.radius = BRIDGE_PILLAR_RADIUS * 1.3
	coll_shape.height = bridge_height
	shape.shape = coll_shape

	body.add_child(shape)
	pillar.add_child(body)


## Создаёт отбойники по краям моста
func _create_bridge_barriers(points: PackedVector2Array, road_width: float, bridge_height: float, ramp_length: float, total_length: float, height_offset: float, parent: Node3D) -> void:
	if points.size() < 2:
		return

	const BARRIER_HEIGHT := 0.8  # Высота отбойника
	const BARRIER_WIDTH := 0.15  # Толщина отбойника
	const BARRIER_COLOR := Color(0.6, 0.6, 0.6)  # Серый металл

	var half_road := road_width * 0.5
	var perpendiculars: Array[Vector2] = _compute_averaged_perpendiculars(points)

	# Создаём меши для левого и правого отбойника
	for side in [-1, 1]:  # -1 = левый, 1 = правый
		var vertices := PackedVector3Array()
		var indices := PackedInt32Array()
		var normals := PackedVector3Array()

		var accumulated := 0.0

		for i in range(points.size()):
			var p: Vector2 = points[i]
			var perp: Vector2 = perpendiculars[i]

			# Базовая высота
			var base_elev: float = 0.0 + height_offset

			# Высота моста в этой точке
			var bridge_y := 0.0
			if ramp_length > 0.1:
				if accumulated < ramp_length:
					var t: float = accumulated / ramp_length
					bridge_y = _smooth_step(t) * bridge_height
				elif accumulated > total_length - ramp_length:
					var t: float = (total_length - accumulated) / ramp_length
					bridge_y = _smooth_step(t) * bridge_height
				else:
					bridge_y = bridge_height
			else:
				bridge_y = bridge_height

			var road_y: float = base_elev + bridge_y

			# Позиция отбойника (на краю дороги)
			var barrier_x: float = p.x + perp.x * half_road * side
			var barrier_z: float = p.y + perp.y * half_road * side

			# Добавляем 4 вершины для этой секции (низ и верх, внутри и снаружи)
			var inner_offset: float = BARRIER_WIDTH * 0.5 * (-side)
			var outer_offset: float = BARRIER_WIDTH * 0.5 * side

			# Нижняя внутренняя
			vertices.append(Vector3(barrier_x + perp.x * inner_offset, road_y, barrier_z + perp.y * inner_offset))
			# Нижняя внешняя
			vertices.append(Vector3(barrier_x + perp.x * outer_offset, road_y, barrier_z + perp.y * outer_offset))
			# Верхняя внутренняя
			vertices.append(Vector3(barrier_x + perp.x * inner_offset, road_y + BARRIER_HEIGHT, barrier_z + perp.y * inner_offset))
			# Верхняя внешняя
			vertices.append(Vector3(barrier_x + perp.x * outer_offset, road_y + BARRIER_HEIGHT, barrier_z + perp.y * outer_offset))

			# Нормали (направлены наружу от дороги)
			var normal := Vector3(perp.x * side, 0, perp.y * side)
			for _j in range(4):
				normals.append(normal)

			# Обновляем accumulated
			if i < points.size() - 1:
				accumulated += points[i].distance_to(points[i + 1])

		# Создаём индексы для граней
		for i in range(points.size() - 1):
			var base_idx := i * 4

			# Внешняя стенка (2 треугольника)
			indices.append(base_idx + 1)
			indices.append(base_idx + 5)
			indices.append(base_idx + 3)

			indices.append(base_idx + 3)
			indices.append(base_idx + 5)
			indices.append(base_idx + 7)

			# Верхняя грань
			indices.append(base_idx + 2)
			indices.append(base_idx + 3)
			indices.append(base_idx + 6)

			indices.append(base_idx + 6)
			indices.append(base_idx + 3)
			indices.append(base_idx + 7)

		if vertices.size() < 8:
			continue

		# Создаём меш
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices

		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		# Материал отбойника
		var material := StandardMaterial3D.new()
		material.albedo_color = BARRIER_COLOR
		material.metallic = 0.6
		material.roughness = 0.4
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.surface_set_material(0, material)

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "BridgeBarrier_" + ("Left" if side == -1 else "Right")
		mesh_instance.mesh = mesh
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mesh_instance)

		# Коллизия для отбойника
		var body := StaticBody3D.new()
		body.name = "BarrierCollision"
		body.collision_layer = 2  # Obstacle layer

		var coll_shape := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()

		var faces := PackedVector3Array()
		for j in range(0, indices.size(), 3):
			faces.append(vertices[indices[j]])
			faces.append(vertices[indices[j + 1]])
			faces.append(vertices[indices[j + 2]])

		shape.set_faces(faces)
		coll_shape.shape = shape
		body.add_child(coll_shape)
		parent.add_child(body)


func _create_road_mesh_with_texture(nodes: Array, width: float, texture_key: String, height_offset: float, parent: Node3D) -> void:
	var prof_start := 0
	if _profiler:
		prof_start = _profiler.start_measure("road_generation")

	if nodes.size() < 2:
		if _profiler:
			_profiler.end_measure("road_generation", prof_start)
		return

	# Convert to local coordinates
	var raw_points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		raw_points.append(local)

	# Smooth sharp corners with Catmull-Rom interpolation
	var smooth_start := 0
	if _profiler:
		smooth_start = _profiler.start_measure("road_smoothing")
	var points: PackedVector2Array = _smooth_road_corners(raw_points)
	if _profiler:
		_profiler.end_measure("road_smoothing", smooth_start)

	# Validate and fix points that create loops/flips
	var validate_start := 0
	if _profiler:
		validate_start = _profiler.start_measure("road_validation")
	points = _validate_road_direction(points)
	if _profiler:
		_profiler.end_measure("road_validation", validate_start)

	# Z-fighting offset based on hash
	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.00003

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()

	var uv_scale: float = 0.1
	var accumulated_length: float = 0.0
	var half_w: float = width * 0.5

	# Precompute averaged perpendiculars at each point to eliminate gaps
	var perpendiculars: PackedVector2Array = PackedVector2Array()
	for i in range(points.size()):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == points.size() - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			# Use outgoing direction only - no averaging to prevent flip
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			perp = Vector2(-dir_out.y, dir_out.x)
		perpendiculars.append(perp)

	# Generate 2 vertices per point (left and right edge) - shared between segments
	for i in range(points.size()):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]

		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale

		# Sample elevation at left, center, right — use max(center, edge) to prevent grass mid-road
		var left_pos := Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w)
		var right_pos := Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w)
		var h_center: float = 0.0 + height_offset + z_offset
		var h_left: float = maxf(0.0 + height_offset + z_offset, h_center)
		var h_right: float = maxf(0.0 + height_offset + z_offset, h_center)

		# Left vertex
		vertices.append(Vector3(left_pos.x, h_left, left_pos.y))
		uvs.append(Vector2(0.0, uv_y))
		normals.append(Vector3.UP)

		# Right vertex
		vertices.append(Vector3(right_pos.x, h_right, right_pos.y))
		uvs.append(Vector2(1.0, uv_y))
		normals.append(Vector3.UP)

	# Generate triangle indices (triangle strip with shared vertices)
	for i in range(points.size() - 1):
		var idx: int = i * 2

		# Triangle 1
		indices.append(idx + 0)
		indices.append(idx + 3)
		indices.append(idx + 1)

		# Triangle 2
		indices.append(idx + 0)
		indices.append(idx + 2)
		indices.append(idx + 3)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh: ArrayMesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = arr_mesh

	# Материал с текстурой (используем шейдер с noise вариацией)
	var albedo_tex: Texture2D = _road_textures.get(texture_key, null)
	var normal_tex: Texture2D = _normal_textures.get("asphalt", null)
	var material: Material = WetRoadMaterial.create_road_shader_material(
		albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null)
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, texture_key)
	mesh.material_override = material

	# Создаём коллизию дороги с группой Road для GEVP
	var road_body := StaticBody3D.new()
	road_body.name = "RoadCollision"
	road_body.collision_layer = 1
	road_body.collision_mask = 1
	road_body.add_to_group("Road")  # GEVP - дорога (отличное сцепление)
	road_body.add_child(mesh)

	# Создаём trimesh коллизию из меша дороги
	mesh.create_trimesh_collision()
	for child in mesh.get_children():
		if child is StaticBody3D:
			var col_shape := child.get_child(0)
			if col_shape is CollisionShape3D:
				child.remove_child(col_shape)
				road_body.add_child(col_shape)
			child.queue_free()

	parent.add_child(road_body)

	if _profiler:
		_profiler.end_measure("road_generation", prof_start)

# OPTIMIZATION: Road Batching System (Mesh Merging)
# Добавляет дорогу в batch вместо создания отдельного MeshInstance3D
func _add_road_to_batch(nodes: Array, width: float, texture_key: String, height_offset: float, parent: Node3D) -> void:
	if nodes.size() < 2:
		return

	# Извлекаем chunk_key из parent node name
	var chunk_key := ""
	if parent.name.begins_with("Chunk_"):
		chunk_key = parent.name.substr(6)  # Убираем "Chunk_" префикс
	else:
		# Для начальной загрузки (parent = root) используем "initial"
		chunk_key = "initial"

	# Инициализируем batch data для этого чанка если ещё нет
	if not _road_batch_data.has(chunk_key):
		_road_batch_data[chunk_key] = {}

	if not _road_batch_data[chunk_key].has(texture_key):
		_road_batch_data[chunk_key][texture_key] = {
			"vertices": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"parent": parent  # Сохраняем parent для создания MeshInstance3D позже
		}

	# Convert to local coordinates and smooth
	var raw_points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		raw_points.append(local)

	var points: PackedVector2Array = _smooth_road_corners(raw_points)

	# Validate and fix points that create loops/flips
	points = _validate_road_direction(points)

	# Клиппинг дороги по границам чанка (с запасом на ширину дороги)
	# Без этого дороги из Overpass API (загружены с +100м overlap) уходят далеко за чанк,
	if chunk_key != "initial":
		var ck_parts: PackedStringArray = chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		var margin := width + 5.0  # Запас на ширину дороги + бордюры
		var clip_min_x := float(ck_x) * chunk_size - margin
		var clip_max_x := float(ck_x + 1) * chunk_size + margin
		var clip_min_z := float(ck_z) * chunk_size - margin
		var clip_max_z := float(ck_z + 1) * chunk_size + margin
		points = _clip_polyline_to_rect(points, clip_min_x, clip_max_x, clip_min_z, clip_max_z)
		if points.size() < 2:
			return

	# Z-fighting offset
	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.00003

	# Генерируем geometry для этого road segment
	var batch: Dictionary = _road_batch_data[chunk_key][texture_key]
	var vertex_offset: int = batch["vertices"].size()  # Offset для индексов

	var uv_scale: float = 0.1
	var accumulated_length: float = 0.0
	var half_w: float = width * 0.5

	# Precompute averaged perpendiculars
	var perpendiculars: PackedVector2Array = PackedVector2Array()
	for i in range(points.size()):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == points.size() - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			# Use outgoing direction only - no averaging to prevent flip
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			perp = Vector2(-dir_out.y, dir_out.x)
		perpendiculars.append(perp)

	# Generate vertices (добавляем в существующий batch)
	for i in range(points.size()):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]

		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale

		# Sample elevation at left, center, right — use max(center, edge) to prevent grass mid-road
		var left_pos := Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w)
		var right_pos := Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w)
		var h_center: float = 0.0 + height_offset + z_offset
		var h_left: float = maxf(0.0 + height_offset + z_offset, h_center)
		var h_right: float = maxf(0.0 + height_offset + z_offset, h_center)

		# Left vertex
		batch["vertices"].append(Vector3(left_pos.x, h_left, left_pos.y))
		batch["uvs"].append(Vector2(0.0, uv_y))
		batch["normals"].append(Vector3.UP)

		# Right vertex
		batch["vertices"].append(Vector3(right_pos.x, h_right, right_pos.y))
		batch["uvs"].append(Vector2(1.0, uv_y))
		batch["normals"].append(Vector3.UP)

	# Generate indices (с учётом vertex_offset)
	for i in range(points.size() - 1):
		var idx: int = vertex_offset + i * 2

		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 3)
		batch["indices"].append(idx + 1)

		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 2)
		batch["indices"].append(idx + 3)

## Incremental footway splitting: processes N points per frame to stay under budget.
## Item dict stores progress state: _pt_idx, _on_road, _in_parking.
## Returns true when fully processed, false when needs more frames.
func _process_footway_incremental(item: Dictionary, budget_end: int) -> bool:
	var smoothed_points: PackedVector2Array = item.smoothed_points
	var width: float = item.width
	var parent: Node3D = item.parent

	# Phase 1: classify points (on_road / in_parking) incrementally
	var pt_idx: int = item.get("_pt_idx", 0)
	var on_road: Array = item.get("_on_road", [])
	var in_parking: Array = item.get("_in_parking", [])

	while pt_idx < smoothed_points.size():
		if Time.get_ticks_usec() > budget_end:
			item["_pt_idx"] = pt_idx
			item["_on_road"] = on_road
			item["_in_parking"] = in_parking
			return false  # resume next frame
		var p: Vector2 = smoothed_points[pt_idx]
		on_road.append(_is_point_on_vehicle_road(p))
		var ip := false
		for poly in _parking_polygons:
			if poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly):
				ip = true
				break
		in_parking.append(ip)
		pt_idx += 1

	# Phase 2: postprocess parking adjacency + split + vertex gen (fast, no budget needed)
	for i in range(on_road.size()):
		if not on_road[i]:
			continue
		var has_parking_before := false
		for j in range(i - 1, -1, -1):
			if in_parking[j]:
				has_parking_before = true
				break
			if i - j > 20:
				break
		if not has_parking_before:
			continue
		var has_parking_after := false
		for j in range(i + 1, on_road.size()):
			if in_parking[j]:
				has_parking_after = true
				break
			if j - i > 20:
				break
		if has_parking_after:
			on_road[i] = false

	var is_tagged_crossing: bool = item.tags.get("footway", "") == "crossing"
	var current_pts := PackedVector2Array()
	current_pts.append(smoothed_points[0])
	var current_on: bool = on_road[0]
	var last_off_road_pt := smoothed_points[0]
	var has_before_off := true
	for i in range(1, smoothed_points.size()):
		if on_road[i] != current_on:
			var edge_pt := _find_road_edge_point(smoothed_points[i - 1], current_on, smoothed_points[i])
			current_pts.append(edge_pt)
			if current_pts.size() >= 2:
				if current_on:
					var is_full: bool = is_tagged_crossing or (has_before_off and _is_full_road_crossing(last_off_road_pt, smoothed_points[i]))
					if is_full:
						_add_road_to_batch_fast(current_pts, width, "crossing", 0.013, parent)
						if enable_crossing_signs:
							_enqueue_crossing_signs(current_pts, parent)
				else:
					_add_road_to_batch_fast(current_pts, width, "path", 0.23, parent)
					last_off_road_pt = smoothed_points[i - 1]
					has_before_off = true
			current_pts = PackedVector2Array()
			current_pts.append(edge_pt)
			current_on = on_road[i]
		else:
			if not current_on:
				last_off_road_pt = smoothed_points[i]
				has_before_off = true
		current_pts.append(smoothed_points[i])
	if current_pts.size() >= 2:
		if current_on:
			var last_pt: Vector2 = smoothed_points[smoothed_points.size() - 1]
			if is_tagged_crossing or (has_before_off and _is_full_road_crossing(last_off_road_pt, last_pt)):
				_add_road_to_batch_fast(current_pts, width, "crossing", 0.013, parent)
				if enable_crossing_signs:
					_enqueue_crossing_signs(current_pts, parent)
		else:
			_add_road_to_batch_fast(current_pts, width, "path", 0.23, parent)
	return true


# Fast variant: accepts pre-computed local_points (avoids redundant _latlon_to_local)
func _add_road_to_batch_fast(raw_points: PackedVector2Array, width: float, texture_key: String, height_offset: float, parent: Node3D) -> void:
	if raw_points.size() < 2:
		return

	var chunk_key := ""
	if parent.name.begins_with("Chunk_"):
		chunk_key = parent.name.substr(6)
	else:
		chunk_key = "initial"

	if not _road_batch_data.has(chunk_key):
		_road_batch_data[chunk_key] = {}

	if not _road_batch_data[chunk_key].has(texture_key):
		_road_batch_data[chunk_key][texture_key] = {
			"vertices": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"parent": parent
		}

	# Точки уже сглажены вызывающей стороной — только validate
	var points: PackedVector2Array = _validate_road_direction(raw_points)

	if chunk_key != "initial":
		var ck_parts: PackedStringArray = chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		var margin := width + 5.0
		var clip_min_x := float(ck_x) * chunk_size - margin
		var clip_max_x := float(ck_x + 1) * chunk_size + margin
		var clip_min_z := float(ck_z) * chunk_size - margin
		var clip_max_z := float(ck_z + 1) * chunk_size + margin
		points = _clip_polyline_to_rect(points, clip_min_x, clip_max_x, clip_min_z, clip_max_z)
		if points.size() < 2:
			return

	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.00003

	var batch: Dictionary = _road_batch_data[chunk_key][texture_key]
	var vertex_offset: int = batch["vertices"].size()
	var uv_scale: float = 0.1
	var accumulated_length: float = 0.0
	var half_w: float = width * 0.5
	var n_points: int = points.size()

	# Precompute perpendiculars
	var perpendiculars := PackedVector2Array()
	perpendiculars.resize(n_points)
	for i in range(n_points):
		var perp: Vector2
		if i == 0:
			var dir: Vector2 = (points[1] - points[0]).normalized()
			perp = Vector2(-dir.y, dir.x)
		elif i == n_points - 1:
			var dir: Vector2 = (points[i] - points[i - 1]).normalized()
			perp = Vector2(-dir.y, dir.x)
		else:
			var dir_out: Vector2 = (points[i + 1] - points[i]).normalized()
			perp = Vector2(-dir_out.y, dir_out.x)
		perpendiculars[i] = perp

	var h: float = height_offset + z_offset
	for i in range(n_points):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]

		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale

		var left_pos := Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w)
		var right_pos := Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w)

		batch["vertices"].append(Vector3(left_pos.x, h, left_pos.y))
		batch["uvs"].append(Vector2(0.0, uv_y))
		batch["normals"].append(Vector3.UP)

		batch["vertices"].append(Vector3(right_pos.x, h, right_pos.y))
		batch["uvs"].append(Vector2(1.0, uv_y))
		batch["normals"].append(Vector3.UP)

	# Generate indices
	for i in range(n_points - 1):
		var idx: int = vertex_offset + i * 2
		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 3)
		batch["indices"].append(idx + 1)
		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 2)
		batch["indices"].append(idx + 3)


# Финализирует road batches для чанка - создаёт merged meshes
func _finalize_road_batches_for_chunk(chunk_key: String) -> void:
	var prof_start_total = 0
	if _profiler:
		prof_start_total = _profiler.start_measure("road_batch_finalize_total_" + chunk_key)

	if not _road_batch_data.has(chunk_key):
		# Нет дорог — но террейн всё равно создаём
		_create_deferred_terrain(chunk_key)
		if _profiler:
			_profiler.end_measure("road_batch_finalize_total_" + chunk_key, prof_start_total)
		return

	var chunk_batches: Dictionary = _road_batch_data[chunk_key]

	# Финализируем ОДИН тип дороги за вызов (round-robin через очередь)
	var keys: Array = chunk_batches.keys()
	if keys.is_empty():
		_road_batch_data.erase(chunk_key)
		_create_deferred_terrain(chunk_key)
		return

	var texture_key: String = keys[0]
	var batch: Dictionary = chunk_batches[texture_key]

	# Удаляем этот batch из данных
	chunk_batches.erase(texture_key)

	# Если остались ещё типы — re-enqueue для следующего кадра
	if not chunk_batches.is_empty():
		if not _pending_batch_chunks.has(chunk_key):
			_pending_batch_chunks.append(chunk_key)
	else:
		# Последний тип — очищаем и создаём террейн
		_road_batch_data.erase(chunk_key)
		_create_deferred_terrain(chunk_key)

	# Проверяем что есть geometry
	if batch["vertices"].size() == 0:
		if _profiler:
			_profiler.end_measure("road_batch_finalize_total_" + chunk_key, prof_start_total)
		return

	# Создаём ArrayMesh из накопленных данных
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = batch["vertices"]
	arrays[Mesh.ARRAY_TEX_UV] = batch["uvs"]
	arrays[Mesh.ARRAY_NORMAL] = batch["normals"]
	arrays[Mesh.ARRAY_INDEX] = batch["indices"]

	var arr_mesh: ArrayMesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Track draw calls
	if _draw_call_logging_enabled:
		_draw_call_stats["roads"] += 1

	# Создаём материал с шейдером (noise вариация roughness + лужи)
	var albedo_tex: Texture2D = _road_textures.get(texture_key, null)
	var normal_tex: Texture2D = _normal_textures.get("asphalt", null)
	var material: Material = WetRoadMaterial.create_road_shader_material(
		albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null)
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, texture_key)

	# Добавляем в parent (chunk node)
	var parent: Node3D = batch["parent"]

	# SAFETY: Проверяем что parent ещё существует (чанк не был выгружен)
	if not is_instance_valid(parent):
		print("OSM: ⚠️ Skipped road batch %s/%s - chunk was unloaded" % [chunk_key, texture_key])
		if _profiler:
			_profiler.end_measure("road_batch_finalize_total_" + chunk_key, prof_start_total)
		return

	# Road visual — RenderingServer (no scene tree overhead)
	_rs_add_mesh(chunk_key, arr_mesh, material)

	# Track material for wet mode toggle
	if material is ShaderMaterial:
		if not _chunk_road_materials.has(chunk_key):
			_chunk_road_materials[chunk_key] = []
		_chunk_road_materials[chunk_key].append(material)

	# Road collision — StaticBody3D (deferred shape creation)
	var road_body := StaticBody3D.new()
	road_body.name = "RoadBatchCollision_" + texture_key
	road_body.collision_layer = 1
	road_body.collision_mask = 1
	road_body.add_to_group("Road")  # GEVP - дорога

	_budgeted_add_child(parent, road_body)

	# Collision shape — отложенное создание (ConcavePolygonShape3D ~5-26ms)
	_deferred_road_collisions.append({
		"body": road_body,
		"vertices": batch["vertices"],
		"indices": batch["indices"]
	})

	# DEBUG: Всегда выводим информацию о созданных road batches
	var mat_info: String = "ShaderMaterial" if material is ShaderMaterial else str(material.albedo_texture) if material is StandardMaterial3D and material.albedo_texture else "color only"
	print("OSM: ✅ Finalized road batch %s/%s: %d vertices, %d triangles, material: %s" % [
		chunk_key, texture_key, batch["vertices"].size(), batch["indices"].size() / 3, mat_info
	])

	# Измерить общее время финализации
	if _profiler:
		_profiler.end_measure("road_batch_finalize_total_" + chunk_key, prof_start_total)
		var total_time_ms = (Time.get_ticks_usec() - prof_start_total) / 1000.0
		if total_time_ms > 8.0:
			print("⚠️ SLOW: road batch finalization took %.1f ms for chunk %s" % [total_time_ms, chunk_key])

## Создаёт террейн чанка используя сглажённые точки из road rendering thread.
## Теперь НЕ выполняет тяжёлый клиппинг синхронно, а ставит задачу в инкрементальную очередь.
func _create_deferred_terrain(chunk_key: String) -> void:
	if chunk_key == "" or chunk_key == "initial":
		return
	var parent_node: Node3D = _loaded_chunks.get(chunk_key, null)
	if not parent_node or not is_instance_valid(parent_node):
		return
	# Собираем сглажённые коридоры из текущего чанка И соседних
	# Коридоры хранятся во всех чанках которые пересекают (см. _apply_road_result)
	var terrain_roads: Array = []
	var ck_parts: PackedStringArray = chunk_key.split(",")
	var ck_x := int(ck_parts[0])
	var ck_z := int(ck_parts[1])
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var nk := "%d,%d" % [ck_x + dx, ck_z + dz]
			if _chunk_terrain_roads.has(nk):
				terrain_roads.append_array(_chunk_terrain_roads[nk])
	var ch_min_x := float(ck_x) * chunk_size
	var ch_max_x := ch_min_x + chunk_size
	var ch_min_z := float(ck_z) * chunk_size
	var ch_max_z := ch_min_z + chunk_size

	# Собираем перекрёстки и парковки, относящиеся к этому чанку (предфильтрация)
	var relevant_contours: Array[PackedVector2Array] = []
	var relevant_contour_positions: Array[Vector2] = []
	for i in range(_intersection_contours.size()):
		var ipos: Vector2 = _intersection_positions[i]
		if ipos.x >= ch_min_x - 30.0 and ipos.x <= ch_max_x + 30.0 and ipos.y >= ch_min_z - 30.0 and ipos.y <= ch_max_z + 30.0:
			var contour: PackedVector2Array = _intersection_contours[i]
			if contour.size() >= 3:
				relevant_contours.append(contour)
				relevant_contour_positions.append(ipos)

	var relevant_parking: Array[PackedVector2Array] = []
	for parking_poly in _parking_polygons:
		if parking_poly.size() < 3:
			continue
		var in_chunk := false
		for pp in parking_poly:
			if pp.x >= ch_min_x - 5.0 and pp.x <= ch_max_x + 5.0 and pp.y >= ch_min_z - 5.0 and pp.y <= ch_max_z + 5.0:
				in_chunk = true
				break
		if in_chunk:
			relevant_parking.append(parking_poly)

	# Отправляем клиппинг в worker thread (тяжёлая операция O(n²))
	var chunk_rect := PackedVector2Array([
		Vector2(ch_min_x, ch_min_z),
		Vector2(ch_max_x, ch_min_z),
		Vector2(ch_max_x, ch_max_z),
		Vector2(ch_min_x, ch_max_z),
	])
	var task_data := {
		"chunk_key": chunk_key,
		"road_polylines": terrain_roads,
		"contours": relevant_contours,
		"parking": relevant_parking,
		"chunk_rect": chunk_rect,
		"chunk_size": chunk_size
	}
	_pending_terrain_tasks += 1
	WorkerThreadPool.add_task(_compute_terrain_clipping_thread.bind(task_data))
	# NOTE: НЕ удаляем _chunk_terrain_roads[chunk_key] здесь — соседние чанки
	# могут ещё не получить свой террейн и будут ссылаться на наши коридоры.
	# Очистка произойдёт при _unload_chunk.


func _finalize_window_batches_for_chunk(chunk_key: String) -> void:
	if not _window_batch_data.has(chunk_key):
		return
	if not enable_windows:
		_window_batch_data.erase(chunk_key)
		return

	var batch: Dictionary = _window_batch_data[chunk_key]
	var transforms: Array = batch.get("transforms", [])
	var colors: Array = batch.get("colors", [])
	var parent: Node3D = batch.get("parent", null)

	if transforms.is_empty() or not parent or not is_instance_valid(parent):
		_window_batch_data.erase(chunk_key)
		return

	# Create MultiMesh + instance upfront, buffer filled progressively
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = false
	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 1.2)
	mm.mesh = quad
	mm.instance_count = transforms.size()

	var instance_count: int = transforms.size()
	var buf := PackedFloat32Array()
	buf.resize(instance_count * 16)

	if not _window_shader:
		push_error("OSM: Window shader not initialized!")
		_window_batch_data.erase(chunk_key)
		return

	var mat := ShaderMaterial.new()
	mat.shader = _window_shader
	_window_batch_materials.append(mat)

	var is_night := false
	if _night_mode_manager and is_instance_valid(_night_mode_manager) and "is_night" in _night_mode_manager:
		is_night = _night_mode_manager.is_night
	mat.set_shader_parameter("is_night", is_night)

	var mm_instance := MultiMeshInstance3D.new()
	mm_instance.multimesh = mm
	mm_instance.material_override = mat
	mm_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mm_instance.visibility_range_end = render_distance
	mm_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	mm_instance.name = "WindowBatch"


	if _draw_call_logging_enabled:
		_draw_call_stats["windows"] += 1

	# Queue progressive fill
	_window_finalize_progress[chunk_key] = {
		"buf": buf,
		"offset": 0,
		"mm": mm,
		"transforms": transforms,
		"colors": colors,
		"parent": parent,
		"mm_instance": mm_instance
	}
	if not _window_finalize_queue.has(chunk_key):
		_window_finalize_queue.append(chunk_key)

	_window_batch_data.erase(chunk_key)


# Progressive window buffer fill - returns true when done with current chunk
# Processes up to WINDOW_BATCH_SIZE windows per call, respecting time budget
const WINDOW_BATCH_SIZE := 500
func _progress_window_finalize(budget_end_usec: int) -> bool:
	if _window_finalize_queue.is_empty():
		return true  # Nothing to do

	var chunk_key: String = _window_finalize_queue[0]
	if not _window_finalize_progress.has(chunk_key):
		_window_finalize_queue.remove_at(0)
		return not _window_finalize_queue.is_empty()

	var state: Dictionary = _window_finalize_progress[chunk_key]
	var buf: PackedFloat32Array = state["buf"]
	var offset: int = state["offset"]
	var transforms: Array = state["transforms"]
	var colors: Array = state["colors"]
	var parent: Node3D = state["parent"]
	var mm: MultiMesh = state["mm"]
	var mm_instance: MultiMeshInstance3D = state["mm_instance"]
	var total: int = transforms.size()

	# Check parent still valid
	if not parent or not is_instance_valid(parent):
		_window_finalize_progress.erase(chunk_key)
		_window_finalize_queue.remove_at(0)
		return not _window_finalize_queue.is_empty()

	# Fill buffer in batches
	var end: int = mini(offset + WINDOW_BATCH_SIZE, total)
	var colors_size: int = colors.size()
	for i in range(offset, end):
		var t: Transform3D = transforms[i]
		var idx: int = i * 16
		buf[idx + 0] = t.basis.x.x
		buf[idx + 1] = t.basis.y.x
		buf[idx + 2] = t.basis.z.x
		buf[idx + 3] = t.origin.x
		buf[idx + 4] = t.basis.x.y
		buf[idx + 5] = t.basis.y.y
		buf[idx + 6] = t.basis.z.y
		buf[idx + 7] = t.origin.y
		buf[idx + 8] = t.basis.x.z
		buf[idx + 9] = t.basis.y.z
		buf[idx + 10] = t.basis.z.z
		buf[idx + 11] = t.origin.z
		if i < colors_size:
			var c: Color = colors[i]
			buf[idx + 12] = c.r
			buf[idx + 13] = c.g
			buf[idx + 14] = c.b
			buf[idx + 15] = c.a
		else:
			buf[idx + 12] = 1.0
			buf[idx + 13] = 1.0
			buf[idx + 14] = 1.0
			buf[idx + 15] = 1.0

	state["offset"] = end

	if end >= total:
		# Done - assign buffer and add to scene
		mm.buffer = buf
		_budgeted_add_child(parent, mm_instance)
		_window_finalize_progress.erase(chunk_key)
		_window_finalize_queue.remove_at(0)
		return true  # Completed this chunk

	# Not done yet, check if we have budget for another batch
	if Time.get_ticks_usec() < budget_end_usec:
		return _progress_window_finalize(budget_end_usec)  # Continue filling

	return false  # Out of budget, continue next frame

# Обновляет is_night параметр для всех window batch материалов (вызывается при переключении ночного режима)
func update_window_night_mode(is_night: bool) -> void:
	var updated_count := 0
	for mat in _window_batch_materials:
		if is_instance_valid(mat):
			mat.set_shader_parameter("is_night", is_night)
			updated_count += 1

	# Prune invalid materials to prevent unbounded growth
	var before_size := _window_batch_materials.size()
	var valid_mats: Array[ShaderMaterial] = []
	for m in _window_batch_materials:
		if is_instance_valid(m):
			valid_mats.append(m)
	_window_batch_materials = valid_mats

	# Переключаем светильники подъездов
	var light_count := 0
	for light in _entrance_lights:
		if is_instance_valid(light):
			light.light_energy = 2.0 if is_night else 0.0
			light_count += 1

	var icon := "🌙" if is_night else "☀️"
	print("OSM: %s Updated %d window batch materials, %d entrance lights: is_night=%s (pruned %d stale)" % [
		icon, updated_count, light_count, is_night, before_size - _window_batch_materials.size()
	])


# Создаёт бордюры вдоль дороги (старая версия для обратной совместимости)
func _create_curbs(nodes: Array, road_width: float, road_height: float, curb_height: float, parent: Node3D) -> void:
	if not enable_curbs or nodes.size() < 2:
		return

	var raw_points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		raw_points.append(local)

	# Сглаживаем точки бордюров так же, как дороги
	var points: PackedVector2Array = _smooth_road_corners(raw_points)

	# Клиппинг по чанку (аналогично дорогам)
	var chunk_key := _get_chunk_key_from_node(parent)
	if chunk_key != "":
		var ck_parts: PackedStringArray = chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		var margin := road_width + 5.0
		var clip_min_x := float(ck_x) * chunk_size - margin
		var clip_max_x := float(ck_x + 1) * chunk_size + margin
		var clip_min_z := float(ck_z) * chunk_size - margin
		var clip_max_z := float(ck_z + 1) * chunk_size + margin
		points = _clip_polyline_to_rect(points, clip_min_x, clip_max_x, clip_min_z, clip_max_z)
		if points.size() < 2:
			return

	_create_curbs_from_points(points, road_width, road_height, curb_height, parent)


# Создаёт бордюры из уже сглаженных точек
func _create_curbs_from_points(points: PackedVector2Array, road_width: float, road_height: float, curb_height: float, parent: Node3D) -> void:
	if points.size() < 2:
		return

	var curb_width := 0.15  # Ширина бордюра 15 см

	# Добавляем небольшое случайное смещение по высоте для предотвращения z-fighting
	# на пересечениях (используем хэш от первой точки дороги)
	var hash_val := int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset := hash_val * 0.00003  # Совпадает с z_offset дороги

	# Создаём меш для бордюров
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	# Сначала собираем валидные сегменты (не в контурах перекрёстков)
	# Проверяем точки на краях дороги, а не на центральной линии
	var valid_segments: Array[int] = []
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var offset := perp * (road_width * 0.5)
		# Проверяем левый и правый края бордюра
		var left1 := p1 + offset
		var left2 := p2 + offset
		var right1 := p1 - offset
		var right2 := p2 - offset
		# Сегмент валиден только если ОБА края вне контуров перекрёстков
		if _is_point_in_intersection_shape(left1, true) < 0 and \
		   _is_point_in_intersection_shape(left2, true) < 0 and \
		   _is_point_in_intersection_shape(right1, true) < 0 and \
		   _is_point_in_intersection_shape(right2, true) < 0:
			valid_segments.append(i)

	if valid_segments.is_empty():
		return

	# Разбиваем на группы непрерывных сегментов
	var groups: Array[Array] = []
	var current_group: Array[int] = []
	for seg_idx in valid_segments:
		if current_group.is_empty() or current_group[current_group.size() - 1] == seg_idx - 1:
			current_group.append(seg_idx)
		else:
			if not current_group.is_empty():
				groups.append(current_group.duplicate())
			current_group = [seg_idx]
	if not current_group.is_empty():
		groups.append(current_group)

	# Генерируем бордюры для каждой группы
	for group in groups:
		var is_first_in_group := true
		var is_last_in_group := false

		for g_idx in range(group.size()):
			var i: int = group[g_idx]
			is_last_in_group = (g_idx == group.size() - 1)

			var p1 := points[i]
			var p2 := points[i + 1]

			var dir := (p2 - p1).normalized()
			var perp := Vector2(-dir.y, dir.x)

			# Elevation в центре и на краях — max(edge, center) как дорога
			var h_center1 := 0.0
			var h_center2 := 0.0

			# Левый бордюр
			var left_inner1 := p1 + perp * (road_width * 0.5)
			var left_outer1 := p1 + perp * (road_width * 0.5 + curb_width)
			var left_inner2 := p2 + perp * (road_width * 0.5)
			var left_outer2 := p2 + perp * (road_width * 0.5 + curb_width)

			# Правый бордюр
			var right_inner1 := p1 - perp * (road_width * 0.5)
			var right_outer1 := p1 - perp * (road_width * 0.5 + curb_width)
			var right_inner2 := p2 - perp * (road_width * 0.5)
			var right_outer2 := p2 - perp * (road_width * 0.5 + curb_width)

			# Высота края = max(elevation_edge, elevation_center) — повторяет логику дороги
			var h_left1 := maxf(0.0, h_center1)
			var h_left2 := maxf(0.0, h_center2)
			var h_right1 := maxf(0.0, h_center1)
			var h_right2 := maxf(0.0, h_center2)

			# Высоты для левого бордюра
			var left_road_y1 := h_left1 + road_height + z_offset
			var left_road_y2 := h_left2 + road_height + z_offset
			var left_curb_y1 := h_left1 + road_height + curb_height + z_offset
			var left_curb_y2 := h_left2 + road_height + curb_height + z_offset
			var left_bottom_y1 := left_curb_y1 - 1.0
			var left_bottom_y2 := left_curb_y2 - 1.0

			# Высоты для правого бордюра
			var right_road_y1 := h_right1 + road_height + z_offset
			var right_road_y2 := h_right2 + road_height + z_offset
			var right_curb_y1 := h_right1 + road_height + curb_height + z_offset
			var right_curb_y2 := h_right2 + road_height + curb_height + z_offset
			var right_bottom_y1 := right_curb_y1 - 1.0
			var right_bottom_y2 := right_curb_y2 - 1.0

			var idx := vertices.size()
			var norm_left_in := Vector3(-perp.x, 0, -perp.y)
			var norm_left_out := Vector3(perp.x, 0, perp.y)
			var norm_right_in := Vector3(perp.x, 0, perp.y)
			var norm_right_out := Vector3(-perp.x, 0, -perp.y)
			var norm_fwd := Vector3(dir.x, 0, dir.y)
			var norm_back := Vector3(-dir.x, 0, -dir.y)

			# === Левый бордюр ===
			# Внутренняя стенка (от дороги до верха бордюра)
			vertices.append(Vector3(left_inner1.x, left_road_y1, left_inner1.y))
			vertices.append(Vector3(left_inner2.x, left_road_y2, left_inner2.y))
			vertices.append(Vector3(left_inner2.x, left_curb_y2, left_inner2.y))
			vertices.append(Vector3(left_inner1.x, left_curb_y1, left_inner1.y))
			for _j in 4: normals.append(norm_left_in)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
			idx = vertices.size()

			# Верхняя грань
			vertices.append(Vector3(left_inner1.x, left_curb_y1, left_inner1.y))
			vertices.append(Vector3(left_inner2.x, left_curb_y2, left_inner2.y))
			vertices.append(Vector3(left_outer2.x, left_curb_y2, left_outer2.y))
			vertices.append(Vector3(left_outer1.x, left_curb_y1, left_outer1.y))
			for _j in 4: normals.append(Vector3.UP)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
			idx = vertices.size()

			# Наружная стенка (от земли до верха бордюра)
			vertices.append(Vector3(left_outer1.x, left_bottom_y1, left_outer1.y))
			vertices.append(Vector3(left_outer2.x, left_bottom_y2, left_outer2.y))
			vertices.append(Vector3(left_outer2.x, left_curb_y2, left_outer2.y))
			vertices.append(Vector3(left_outer1.x, left_curb_y1, left_outer1.y))
			for _j in 4: normals.append(norm_left_out)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
			idx = vertices.size()

			# Торец левого бордюра в начале группы
			if is_first_in_group:
				vertices.append(Vector3(left_inner1.x, left_road_y1, left_inner1.y))
				vertices.append(Vector3(left_outer1.x, left_bottom_y1, left_outer1.y))
				vertices.append(Vector3(left_outer1.x, left_curb_y1, left_outer1.y))
				vertices.append(Vector3(left_inner1.x, left_curb_y1, left_inner1.y))
				for _j in 4: normals.append(norm_back)
				indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
				indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
				idx = vertices.size()

			# Торец левого бордюра в конце группы
			if is_last_in_group:
				vertices.append(Vector3(left_inner2.x, left_road_y2, left_inner2.y))
				vertices.append(Vector3(left_outer2.x, left_bottom_y2, left_outer2.y))
				vertices.append(Vector3(left_outer2.x, left_curb_y2, left_outer2.y))
				vertices.append(Vector3(left_inner2.x, left_curb_y2, left_inner2.y))
				for _j in 4: normals.append(norm_fwd)
				indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
				indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
				idx = vertices.size()

			# === Правый бордюр ===
			# Внутренняя стенка (от дороги до верха бордюра)
			vertices.append(Vector3(right_inner1.x, right_road_y1, right_inner1.y))
			vertices.append(Vector3(right_inner2.x, right_road_y2, right_inner2.y))
			vertices.append(Vector3(right_inner2.x, right_curb_y2, right_inner2.y))
			vertices.append(Vector3(right_inner1.x, right_curb_y1, right_inner1.y))
			for _j in 4: normals.append(norm_right_in)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
			idx = vertices.size()

			# Верхняя грань
			vertices.append(Vector3(right_inner1.x, right_curb_y1, right_inner1.y))
			vertices.append(Vector3(right_inner2.x, right_curb_y2, right_inner2.y))
			vertices.append(Vector3(right_outer2.x, right_curb_y2, right_outer2.y))
			vertices.append(Vector3(right_outer1.x, right_curb_y1, right_outer1.y))
			for _j in 4: normals.append(Vector3.UP)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
			idx = vertices.size()

			# Наружная стенка (от земли до верха бордюра)
			vertices.append(Vector3(right_outer1.x, right_bottom_y1, right_outer1.y))
			vertices.append(Vector3(right_outer2.x, right_bottom_y2, right_outer2.y))
			vertices.append(Vector3(right_outer2.x, right_curb_y2, right_outer2.y))
			vertices.append(Vector3(right_outer1.x, right_curb_y1, right_outer1.y))
			for _j in 4: normals.append(norm_right_out)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
			idx = vertices.size()

			# Торец правого бордюра в начале группы
			if is_first_in_group:
				vertices.append(Vector3(right_inner1.x, right_road_y1, right_inner1.y))
				vertices.append(Vector3(right_outer1.x, right_bottom_y1, right_outer1.y))
				vertices.append(Vector3(right_outer1.x, right_curb_y1, right_outer1.y))
				vertices.append(Vector3(right_inner1.x, right_curb_y1, right_inner1.y))
				for _j in 4: normals.append(norm_back)
				indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
				indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
				idx = vertices.size()

			# Торец правого бордюра в конце группы
			if is_last_in_group:
				vertices.append(Vector3(right_inner2.x, right_road_y2, right_inner2.y))
				vertices.append(Vector3(right_outer2.x, right_bottom_y2, right_outer2.y))
				vertices.append(Vector3(right_outer2.x, right_curb_y2, right_outer2.y))
				vertices.append(Vector3(right_inner2.x, right_curb_y2, right_inner2.y))
				for _j in 4: normals.append(norm_fwd)
				indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
				indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)

			is_first_in_group = false

	if vertices.size() == 0:
		return

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Материал бордюра - серый бетон
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.6, 0.58)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Добавляем depth bias для устранения z-fighting на пересечениях
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mesh.material_override = material

	# Track draw calls
	if _draw_call_logging_enabled:
		_draw_call_stats["curbs"] += 1

	parent.add_child(mesh)
	# Примечание: коллизии создаются через инкрементальную систему (_finalize_curb_mesh)


## Вычисляет коллизии бордюра в worker thread
func _compute_curb_collisions_thread(task: Dictionary) -> void:
	var points: PackedVector2Array = task.points
	var groups: Array = task.groups  # Уже вычисленные валидные сегменты из главного потока
	var road_width: float = task.road_width
	var road_height: float = task.road_height
	var curb_height: float = task.curb_height
	var curb_width: float = task.curb_width
	var z_offset: float = task.z_offset

	var collision_boxes: Array = []

	# Создаём коллизии для каждого 3-го сегмента из валидных групп
	var step := 3
	for group in groups:
		var g_idx := 0
		while g_idx < group.size():
			var i: int = group[g_idx]
			# Берём конечную точку с учётом шага
			var end_g_idx := mini(g_idx + step, group.size() - 1)
			var end_i: int = group[end_g_idx]

			var p1 := points[i]
			var p2 := points[mini(end_i + 1, points.size() - 1)]

			var segment_length := p1.distance_to(p2)
			if segment_length < 0.5:
				g_idx += step
				continue

			var dir := (p2 - p1).normalized()
			var perp := Vector2(-dir.y, dir.x)

			var h_center1 := 0.0
			var h_center2 := 0.0
			var slab_thickness := 0.02  # 2 см толщина
			var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

			# Левый бордюр — elevation на краю дороги, max с центром
			var left_edge1 := p1 + perp * (road_width * 0.5)
			var left_edge2 := p2 + perp * (road_width * 0.5)
			var h_left1 := maxf(0.0, h_center1)
			var h_left2 := maxf(0.0, h_center2)
			var left_top1 := h_left1 + road_height + curb_height + z_offset
			var left_top2 := h_left2 + road_height + curb_height + z_offset
			var left_top_y := (left_top1 + left_top2) / 2.0
			var left_dh := left_top2 - left_top1
			var left_pitch := atan2(left_dh, segment_length)
			var left_len_3d := sqrt(segment_length * segment_length + left_dh * left_dh)
			var left_center := (p1 + p2) / 2 + perp * (road_width * 0.5 + curb_width * 0.5)
			collision_boxes.append({
				"position": Vector3(left_center.x, left_top_y, left_center.y),
				"size": Vector3(left_len_3d, slab_thickness, curb_width),
				"rotation_y": -wall_angle,
				"rotation_z": left_pitch
			})

			# Правый бордюр — elevation на краю дороги, max с центром
			var right_edge1 := p1 - perp * (road_width * 0.5)
			var right_edge2 := p2 - perp * (road_width * 0.5)
			var h_right1 := maxf(0.0, h_center1)
			var h_right2 := maxf(0.0, h_center2)
			var right_top1 := h_right1 + road_height + curb_height + z_offset
			var right_top2 := h_right2 + road_height + curb_height + z_offset
			var right_top_y := (right_top1 + right_top2) / 2.0
			var right_dh := right_top2 - right_top1
			var right_pitch := atan2(right_dh, segment_length)
			var right_len_3d := sqrt(segment_length * segment_length + right_dh * right_dh)
			var right_center := (p1 + p2) / 2 - perp * (road_width * 0.5 + curb_width * 0.5)
			collision_boxes.append({
				"position": Vector3(right_center.x, right_top_y, right_center.y),
				"size": Vector3(right_len_3d, slab_thickness, curb_width),
				"rotation_y": -wall_angle,
				"rotation_z": right_pitch
			})

			g_idx += step

	# Добавляем результат в очередь
	if collision_boxes.size() > 0:
		_curb_collision_mutex.lock()
		_curb_collision_results.append({
			"parent": task.parent,
			"boxes": collision_boxes
		})
		_curb_collision_mutex.unlock()


## Применяет рассчитанные коллизии бордюров (вызывается из _process)
func _apply_curb_collisions() -> void:
	if _curb_collision_results.is_empty():
		return

	_curb_collision_mutex.lock()
	var results := _curb_collision_results.duplicate()
	_curb_collision_results.clear()
	_curb_collision_mutex.unlock()

	# Time-budgeted curb collision application (1ms)
	const CURB_COLLISION_BUDGET_USEC := 1000
	var curb_start := Time.get_ticks_usec()
	var applied := 0
	for i in range(results.size()):
		if applied > 0 and (Time.get_ticks_usec() - curb_start) > CURB_COLLISION_BUDGET_USEC:
			# Return remaining results
			_curb_collision_mutex.lock()
			for j in range(i, results.size()):
				_curb_collision_results.append(results[j])
			_curb_collision_mutex.unlock()
			break

		var result = results[i]
		if not is_instance_valid(result.parent):
			continue

		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.add_to_group("Road")

		for box in result.boxes:
			var collision := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = box.size
			collision.shape = shape
			collision.position = box.position
			collision.rotation.y = box.rotation_y
			collision.rotation.z = box.get("rotation_z", 0.0)
			body.add_child(collision)

		result.parent.add_child(body)
		applied += 1


## Создаёт отложенные ноды с бюджетом — building/tree/lamp/road collisions.
## Вместо 170-500 нод за кадр создаём ~25 нод за кадр.
func _process_deferred_nodes() -> void:
	const BUDGET_USEC := 2000  # 2ms
	var start := Time.get_ticks_usec()

	# 1. Road/terrain collisions (тяжёлые — 1 за кадр, ConcavePolygonShape3D ~5-15ms)
	if not _deferred_road_collisions.is_empty():
		if _add_child_count >= ADD_CHILD_BUDGET_PER_FRAME:
			return
		var item: Dictionary = _deferred_road_collisions.pop_front()
		if is_instance_valid(item["body"]):
			var verts: PackedVector3Array = item["vertices"]
			var idxs: PackedInt32Array = item["indices"]
			var faces := PackedVector3Array()
			faces.resize(idxs.size())
			for fi in range(idxs.size()):
				faces[fi] = verts[idxs[fi]]
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			var col_shape := CollisionShape3D.new()
			col_shape.shape = shape
			_budgeted_add_child(item["body"], col_shape)
		_record_perf("deferred_road_coll", Time.get_ticks_usec() - start)
		return  # 1 heavy collision за кадр

	if not _deferred_terrain_collisions.is_empty():
		if _add_child_count >= ADD_CHILD_BUDGET_PER_FRAME:
			return
		var item: Dictionary = _deferred_terrain_collisions.pop_front()
		var t_parent: Node3D = item["parent"]
		if is_instance_valid(t_parent):
			var verts: PackedVector3Array = item["vertices"]
			var idxs: PackedInt32Array = item["indices"]
			var faces := PackedVector3Array()
			for i in range(0, idxs.size(), 3):
				faces.append(verts[idxs[i]])
				faces.append(verts[idxs[i + 1]])
				faces.append(verts[idxs[i + 2]])
			var body := StaticBody3D.new()
			body.name = "TerrainCollision"
			body.collision_layer = 1
			body.collision_mask = 0
			body.add_to_group("Grass")  # GEVP/tire tracks — определение поверхности
			var col_shape := CollisionShape3D.new()
			var concave := ConcavePolygonShape3D.new()
			concave.set_faces(faces)
			col_shape.shape = concave
			body.add_child(col_shape)
			_budgeted_add_child(t_parent, body)
		_record_perf("deferred_terrain_coll", Time.get_ticks_usec() - start)
		return

	# 2. Building collisions (budgeted)
	while not _deferred_building_collisions.is_empty():
		if _add_child_count >= ADD_CHILD_BUDGET_PER_FRAME or (Time.get_ticks_usec() - start) > BUDGET_USEC:
			return
		var item: Dictionary = _deferred_building_collisions[0]
		var parent: Node3D = item["parent"]
		if not is_instance_valid(parent):
			_deferred_building_collisions.pop_front()
			continue
		var collisions: Array = item["collisions"]
		var idx: int = item["idx"]
		while idx < collisions.size() and _add_child_count < ADD_CHILD_BUDGET_PER_FRAME:
			if (Time.get_ticks_usec() - start) > BUDGET_USEC:
				item["idx"] = idx
				return
			var coll_data: Dictionary = collisions[idx]
			var body := StaticBody3D.new()
			body.collision_layer = 2
			body.collision_mask = 0
			_budgeted_add_child(parent, body)
			_create_building_collisions_deferred.call_deferred(
				body, coll_data["points"], coll_data["base_elev"], coll_data["building_height"])
			idx += 1
		if idx >= collisions.size():
			_deferred_building_collisions.pop_front()
		else:
			item["idx"] = idx
			return

	# 3. Tree collisions (budgeted)
	while not _deferred_tree_collisions.is_empty():
		if _add_child_count >= ADD_CHILD_BUDGET_PER_FRAME or (Time.get_ticks_usec() - start) > BUDGET_USEC:
			return
		var item: Dictionary = _deferred_tree_collisions[0]
		var parent_node: Node3D = item["parent"]
		if not is_instance_valid(parent_node):
			_deferred_tree_collisions.pop_front()
			continue
		var collisions: Array = item["collisions"]
		var idx: int = item["idx"]
		while idx < collisions.size() and _add_child_count < ADD_CHILD_BUDGET_PER_FRAME:
			var collision_data: Dictionary = collisions[idx]
			var coll_pos: Vector3 = collision_data["position"]
			if _is_point_near_road(Vector2(coll_pos.x, coll_pos.z), 60.0):
				var body := StaticBody3D.new()
				body.collision_layer = 2
				body.collision_mask = 0
				body.position = coll_pos
				var collision := CollisionShape3D.new()
				var cyl_shape := CylinderShape3D.new()
				cyl_shape.radius = collision_data["radius"]
				cyl_shape.height = 8.0
				collision.position = Vector3(0, 4.0, 0)
				collision.shape = cyl_shape
				body.add_child(collision)
				_budgeted_add_child(parent_node, body)
			idx += 1
		if idx >= collisions.size():
			_deferred_tree_collisions.pop_front()
		else:
			item["idx"] = idx
			return

	# 4. Lamp lights (budgeted)
	while not _deferred_lamp_lights.is_empty():
		if _add_child_count >= ADD_CHILD_BUDGET_PER_FRAME or (Time.get_ticks_usec() - start) > BUDGET_USEC:
			return
		var item: Dictionary = _deferred_lamp_lights[0]
		var container: Node3D = item["container"]
		if not is_instance_valid(container):
			_deferred_lamp_lights.pop_front()
			continue
		var lights: Array = item["lights"]
		var idx: int = item["idx"]
		var chunk_key: String = item["chunk_key"]
		var is_night: bool = item["is_night"]
		while idx < lights.size() and _add_child_count < ADD_CHILD_BUDGET_PER_FRAME:
			var light_data: Dictionary = lights[idx]
			var light := OmniLight3D.new()
			light.position = light_data.position
			light.omni_range = 12.0
			light.omni_attenuation = 1.2
			light.light_energy = 1.5
			light.light_color = Color(1.0, 0.65, 0.2)
			light.shadow_enabled = false
			light.light_bake_mode = Light3D.BAKE_DISABLED
			light.visible = is_night and not light_data.broken
			light.set_meta("broken", light_data.broken)
			_budgeted_add_child(container, light)
			if _lamp_lights_by_chunk.has(chunk_key):
				_lamp_lights_by_chunk[chunk_key].append(light)
			idx += 1
		if idx >= lights.size():
			_deferred_lamp_lights.pop_front()
		else:
			item["idx"] = idx
			return


# Старая версия без текстур (для совместимости)
func _create_path_mesh(nodes: Array, width: float, color: Color, height_offset: float, parent: Node3D, loader: Node) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	im.surface_set_normal(Vector3.UP)  # Нормаль вверх для дорог

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]

		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x) * width * 0.5

		# Получаем высоты для каждой точки
		var h1 := 0.0 + height_offset
		var h2 := 0.0 + height_offset

		var v1 := Vector3(p1.x - perp.x, h1, p1.y - perp.y)
		var v2 := Vector3(p1.x + perp.x, h1, p1.y + perp.y)
		var v3 := Vector3(p2.x + perp.x, h2, p2.y + perp.y)
		var v4 := Vector3(p2.x - perp.x, h2, p2.y - perp.y)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v2)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v4)
		im.surface_add_vertex(v3)

	im.surface_end()
	parent.add_child(mesh)

func _create_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, way_id: int = 0) -> void:
	if not enable_buildings or nodes.size() < 3:
		return

		var ck: String = _get_chunk_key_from_node(parent)

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Сохраняем рёбра здания для проверки расстояния при генерации деревьев
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var seg := {"p1": p1, "p2": p2}
		_building_segments.append(seg)
		_add_building_segment_to_spatial_hash(seg)

	# Debug name для отладки конкретных зданий
	var addr_street: String = str(tags.get("addr:street", ""))
	var addr_housenumber: String = str(tags.get("addr:housenumber", ""))
	var debug_name := ""
	if addr_street != "" and addr_housenumber != "":
		debug_name = "%s %s" % [addr_street, addr_housenumber]

	# Определяем высоту здания из OSM данных
	var building_height := 0.0

	# Приоритет 1: точная высота в метрах
	if tags.has("height"):
		var h_str: String = str(tags.get("height", ""))
		# Убираем "m" если есть
		h_str = h_str.replace(" m", "").replace("m", "").strip_edges()
		if h_str.is_valid_float():
			building_height = float(h_str)

	# Приоритет 2: количество этажей
	if building_height <= 0.0 and tags.has("building:levels"):
		var levels_str: String = str(tags.get("building:levels", ""))
		if levels_str.is_valid_int():
			var levels := int(levels_str)
			building_height = levels * 3.2  # ~3.2м на этаж

	# Приоритет 3: тип здания
	if building_height <= 0.0:
		var building_type: String = str(tags.get("building", "yes"))
		match building_type:
			"house", "detached", "semidetached_house":
				building_height = 7.0  # 2 этажа
			"residential", "apartments":
				building_height = 15.0  # 5 этажей
			"commercial", "office":
				building_height = 12.0  # 4 этажа
			"industrial", "warehouse":
				building_height = 8.0
			"garage", "garages":
				building_height = 3.0
			"shed", "hut":
				building_height = 2.5
			"church", "cathedral":
				building_height = 20.0
			"school", "university":
				building_height = 12.0
			"hospital":
				building_height = 18.0
			_:
				building_height = 8.0  # По умолчанию ~3 этажа

	# Ограничиваем высоту разумными пределами
	building_height = clamp(building_height, 2.5, 100.0)

	# Определяем цвет здания
	var color := COLORS["building"]

	# Приоритет 1: явно указанный цвет в OSM
	if tags.has("building:colour"):
		var colour_str: String = str(tags.get("building:colour", ""))
		var parsed_color := Color.from_string(colour_str, Color(-1, -1, -1))
		if parsed_color.r >= 0:
			color = parsed_color
	elif tags.has("building:color"):
		var colour_str: String = str(tags.get("building:color", ""))
		var parsed_color := Color.from_string(colour_str, Color(-1, -1, -1))
		if parsed_color.r >= 0:
			color = parsed_color
	else:
		# Приоритет 2: цвет на основе amenity (важнее чем building type)
		var amenity_type: String = str(tags.get("amenity", ""))
		var building_type: String = str(tags.get("building", "yes"))

		# Сначала проверяем amenity - они имеют приоритет
		if amenity_type == "kindergarten":
			color = Color(0.5, 0.75, 0.9)  # Голубой для детских садов
		elif amenity_type == "school":
			color = Color(0.3, 0.5, 0.8)  # Синий для школ
		elif amenity_type == "university" or amenity_type == "college":
			color = Color(0.4, 0.45, 0.7)  # Тёмно-синий для вузов
		elif amenity_type == "hospital":
			color = Color(0.95, 0.95, 0.95)  # Белый для больниц
		elif amenity_type == "clinic":
			color = Color(0.9, 0.9, 0.95)  # Бело-голубой для поликлиник
		elif amenity_type == "police":
			color = Color(0.3, 0.4, 0.6)  # Тёмно-синий для полиции
		elif amenity_type == "fire_station":
			color = Color(0.85, 0.3, 0.25)  # Красный для пожарных
		elif amenity_type == "place_of_worship":
			color = Color(0.95, 0.9, 0.75)  # Золотистый для церквей
		elif amenity_type == "bank":
			color = Color(0.5, 0.6, 0.5)  # Серо-зелёный для банков
		elif amenity_type == "post_office":
			color = Color(0.3, 0.45, 0.7)  # Синий для почты
		elif amenity_type in ["restaurant", "cafe", "fast_food", "bar", "pub"]:
			color = Color(0.8, 0.6, 0.4)  # Оранжево-коричневый для еды
		elif amenity_type == "fuel":
			color = Color(0.85, 0.75, 0.3)  # Жёлтый для заправок
		elif amenity_type == "theatre" or amenity_type == "cinema":
			color = Color(0.6, 0.35, 0.5)  # Пурпурный для театров/кино
		elif amenity_type == "library":
			color = Color(0.55, 0.45, 0.35)  # Коричневый для библиотек
		else:
			# Иначе по типу здания
			match building_type:
				"house", "detached", "semidetached_house":
					color = Color(0.75, 0.65, 0.55)  # Светло-бежевый
				"residential", "apartments":
					color = Color(0.7, 0.6, 0.5)  # Бежевый
				"commercial", "retail":
					color = Color(0.6, 0.65, 0.7)  # Серо-голубой
				"office":
					color = Color(0.55, 0.6, 0.65)  # Сине-серый
				"industrial":
					color = Color(0.4, 0.4, 0.45)  # Тёмно-серый для промышленных
				"warehouse":
					color = Color(0.45, 0.45, 0.5)  # Серый для складов
				"garage", "garages":
					color = Color(0.5, 0.5, 0.48)  # Серый для гаражей
				"shed", "hut":
					color = Color(0.6, 0.5, 0.4)  # Коричневый
				"church", "cathedral", "chapel":
					color = Color(0.95, 0.9, 0.75)  # Золотисто-кремовый
				"kindergarten":
					color = Color(0.5, 0.75, 0.9)  # Голубой
				"school":
					color = Color(0.3, 0.5, 0.8)  # Синий
				"university", "college":
					color = Color(0.4, 0.45, 0.7)  # Тёмно-синий
				"hospital":
					color = Color(0.95, 0.95, 0.95)  # Белый
				"hotel":
					color = Color(0.7, 0.55, 0.45)  # Тёплый коричневый
				"public":
					color = Color(0.6, 0.6, 0.55)  # Серо-оливковый
				"construction":
					color = Color(0.8, 0.7, 0.4)  # Жёлто-коричневый
				"ruins":
					color = Color(0.5, 0.45, 0.4)  # Тёмно-коричневый
				_:
					color = Color(0.65, 0.55, 0.45)  # Стандартный коричневатый

	var center := _get_polygon_center(points)
	var base_elev := 0.22  # Уровень террейна (sidewalk_height)

	# Вычисляем расстояние до игрока для LOD (shadows)
	var distance_to_player: float = 0.0
	if _car:
		var building_pos_3d := Vector3(center.x, 0.0, center.y)
		distance_to_player = _car.global_position.distance_to(building_pos_3d)

	# Проверяем есть ли override для этого здания (из DecorationLayer)
	var building_override = null  # BuildingOverride
	if _decoration_layer and way_id > 0:
		building_override = _decoration_layer.get_building_override_for_way(way_id)

	# Применяем height_override если задан
	if building_override and building_override.height_override > 0:
		building_height = building_override.height_override

	# Если есть override с текстурой или цветом, используем прямой рендеринг вместо батчинга
	if building_override and building_override.wall_texture_path != "":
		# Кастомная текстура с опциональным normal map
		_create_3d_building_with_custom_texture(points, building_height, building_override, parent, base_elev, debug_name)
		print("OSM: Building override applied for way %d with texture %s" % [way_id, building_override.wall_texture_path])
	elif building_override and building_override.use_color_tint:
		var override_color: Color = building_override.color_tint
		_create_3d_building(points, override_color, building_height, parent, base_elev, debug_name)
		print("OSM: Building override applied for way %d with color %s" % [way_id, override_color])
	else:
		# Определяем тип текстуры здания
		var building_type: String = str(tags.get("building", "yes"))
		var texture_type := "panel"  # По умолчанию панельки
		if building_height > 15.0:
			texture_type = "panel"  # Высотки - панельные
		elif building_type in ["house", "detached", "semidetached_house"]:
			texture_type = "brick"  # Частные дома - кирпич
		elif building_type in ["industrial", "warehouse", "garage", "garages"]:
			texture_type = "wall"  # Промышленные - простая штукатурка
		else:
			texture_type = "brick"  # Остальное - кирпич

		# Используем многопоточную генерацию зданий
		_queue_building_for_thread(points, building_height, texture_type, parent, base_elev, distance_to_player)

	# Добавляем вывески для заведений (amenity/shop с названием)
	# Вывески создаются синхронно т.к. они лёгкие
	_add_business_signs_simple(points, tags, parent, building_height, base_elev, loader, way_id)

	# Добавляем подъезды жилых домов (из building_overrides JSON)
	if way_id > 0 and _decoration_layer:
		_add_residential_entrances(points, parent, base_elev, way_id)

	# Добавляем входные группы магазинов (из building_overrides JSON)
	if way_id > 0 and _decoration_layer:
		_add_shop_entrances_from_override(points, parent, building_height, base_elev, way_id)

	# Добавляем кастомные входные группы (МАРС и т.д.)
	if way_id > 0 and _decoration_layer:
		_add_custom_entrances_from_override(points, parent, building_height, base_elev, way_id)


func _create_parking(points: PackedVector2Array, parent: Node3D) -> void:
	"""Создаёт парковку: асфальтовую поверхность + знак P (знак отложен) + припаркованные машины"""
	if points.size() < 3:
		return

	# Примечание: полигон уже добавлен в _parking_polygons в первом проходе

	# 1. Создаём асфальтовую поверхность
	_create_parking_surface(points, parent)

	# 2. Сохраняем данные для отложенного создания знака
	# (знак создаётся после загрузки всех чанков, когда все дороги известны)
	_pending_parking_signs.append({
		"points": points,
		"parent": parent
	})

	# 3. Добавляем припаркованные машины (0-2 штуки)
	_spawn_parked_cars(points, parent)


func _find_parking_sign_position(parking_points: PackedVector2Array) -> Dictionary:
	"""Находит позицию для знака парковки: в дальнем от дороги углу"""
	if parking_points.size() < 3 or _road_segments.is_empty():
		return {}

	# Сначала находим ближайшую дорогу к парковке (по центру)
	var parking_center := Vector2.ZERO
	for pt in parking_points:
		parking_center += pt
	parking_center /= parking_points.size()

	var nearest_road_point := Vector2.ZERO
	var min_center_dist := INF

	for seg in _road_segments:
		var road_p1: Vector2 = seg.p1
		var road_p2: Vector2 = seg.p2
		var road_vec: Vector2 = road_p2 - road_p1
		var road_len: float = road_vec.length()
		if road_len < 0.1:
			continue
		var t: float = clamp((parking_center - road_p1).dot(road_vec) / (road_len * road_len), 0.0, 1.0)
		var closest: Vector2 = road_p1 + road_vec * t
		var dist: float = parking_center.distance_to(closest)
		if dist < min_center_dist:
			min_center_dist = dist
			nearest_road_point = closest

	if min_center_dist > 100.0:
		return {}

	# Теперь ищем угол парковки, ДАЛЬНИЙ от этой точки дороги
	var max_dist := 0.0
	var best_corner := Vector2.ZERO

	for corner in parking_points:
		var dist: float = corner.distance_to(nearest_road_point)
		if dist > max_dist:
			max_dist = dist
			best_corner = corner

	# Знак ставим в этом дальнем углу
	var to_road: Vector2 = (nearest_road_point - best_corner).normalized()
	var sign_pos: Vector2 = best_corner + to_road * 0.5  # 0.5м от угла к дороге

	# Знак смотрит в сторону дороги
	var rotation: float = atan2(to_road.x, to_road.y)

	return {"position": sign_pos, "rotation": rotation}


func _create_parking_surface(points: PackedVector2Array, parent: Node3D) -> void:
	"""Создаёт асфальтовую поверхность парковки"""
	# Триангулируем полигон
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.is_empty():
		return

	var mesh := MeshInstance3D.new()
	mesh.name = "ParkingSurface"

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Создаём материал с текстурой асфальта
	var material := StandardMaterial3D.new()
	material.albedo_texture = _road_textures.get("residential", null)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.uv1_scale = Vector3(0.1, 0.1, 1.0)  # Масштаб UV для текстуры
	# Normal map
	if _normal_textures.has("asphalt"):
		material.normal_enabled = true
		material.normal_texture = _normal_textures["asphalt"]
		material.normal_scale = 0.3  # Уменьшено для меньшего шума

	if _is_wet_mode:
		WetRoadMaterial.apply_wet_properties(material, true, _is_night_mode)

	st.set_material(material)

	# Высота парковки вровень с дорогами (service = 0.004)
	var height_offset := 0.005

	# Добавляем вершины треугольников
	for i in range(0, indices.size(), 3):
		for j in range(3):
			var idx = indices[i + j]
			var p = points[idx]
			var h = 0.0 + height_offset

			# UV координаты для текстуры
			st.set_uv(Vector2(p.x * 0.1, p.y * 0.1))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(p.x, h, p.y))

	mesh.mesh = st.commit()
	parent.add_child(mesh)


func _spawn_parked_cars(parking_points: PackedVector2Array, parent: Node3D) -> void:
	"""Спавнит 0-2 припаркованных машины на парковке"""
	if parking_points.size() < 3:
		return

	# Количество машин: 0, 1 или 2 (случайно)
	var car_count: int = randi() % 3
	if car_count == 0:
		return

	# Вычисляем центр парковки
	var center := Vector2.ZERO
	for pt in parking_points:
		center += pt
	center /= parking_points.size()

	# Направление "вдоль" парковки (параллельно ближайшей дороге)
	var parking_dir := _get_parking_direction(parking_points, center)

	# Позиции для машин (разнесённые)
	var spawned_positions: Array[Vector2] = []

	for i in range(car_count):
		var pos := _find_parking_spot(parking_points, center, i, spawned_positions)
		if pos == Vector2.ZERO:
			continue

		spawned_positions.append(pos)

		# Выбираем случайную модель (60% коробка, 20% такси, 20% лада ДПС)
		var car: Node3D
		var rand := randf()
		if rand < 0.6:
			car = _parked_car_scene.instantiate()
		elif rand < 0.8:
			car = _parked_taxi_scene.instantiate()
		else:
			car = _parked_lada_scene.instantiate()

		# Получаем высоту
		var elevation: float = 0.0

		# Позиционируем
		car.position = Vector3(pos.x, elevation, pos.y)

		# Поворот вдоль парковки (+ небольшая вариация ±5°)
		var rotation_variation: float = (randf() - 0.5) * deg_to_rad(10)
		car.rotation.y = atan2(parking_dir.x, parking_dir.y) + rotation_variation

		# Отключаем только AI/управление, физика остаётся для столкновений
		# freeze = false - машина реагирует на удары
		car.set_process(false)  # Отключаем _process (AI логику)
		# Оставляем physics_process для физики столкновений

		# Применяем случайный цвет
		_apply_parked_car_color(car)

		parent.add_child(car)


func _find_parking_spot(parking_points: PackedVector2Array, center: Vector2, index: int, existing: Array[Vector2]) -> Vector2:
	"""Находит свободное место на парковке"""
	# Смещения от центра для разных машин
	var offsets := [
		Vector2(-4, -3), Vector2(4, 3),
		Vector2(-3, 4), Vector2(3, -4),
		Vector2(0, -5), Vector2(0, 5),
	]

	for attempt in range(15):
		var offset = offsets[index % offsets.size()]
		# Добавляем случайность
		offset += Vector2(randf() - 0.5, randf() - 0.5) * (attempt * 0.5)
		var test_pos = center + offset * (1.0 + attempt * 0.2)

		# Проверяем что точка внутри парковки
		if not Geometry2D.is_point_in_polygon(test_pos, parking_points):
			continue

		# Проверяем минимальное расстояние до других машин (4м)
		var too_close := false
		for other in existing:
			if test_pos.distance_to(other) < 4.0:
				too_close = true
				break
		if too_close:
			continue

		return test_pos

	return Vector2.ZERO


func _get_parking_direction(parking_points: PackedVector2Array, center: Vector2) -> Vector2:
	"""Определяет направление 'вдоль' парковки (параллельно ближайшей дороге)"""
	if _road_segments.is_empty():
		# Если дорог нет, используем самую длинную сторону полигона
		return _get_longest_edge_direction(parking_points)

	# Находим ближайший сегмент дороги
	var min_dist := INF
	var best_road_dir := Vector2(1, 0)

	for seg in _road_segments:
		var road_p1: Vector2 = seg.p1
		var road_p2: Vector2 = seg.p2
		var road_vec: Vector2 = road_p2 - road_p1
		var road_len: float = road_vec.length()
		if road_len < 0.1:
			continue

		var t: float = clamp((center - road_p1).dot(road_vec) / (road_len * road_len), 0.0, 1.0)
		var closest: Vector2 = road_p1 + road_vec * t
		var dist: float = center.distance_to(closest)

		if dist < min_dist:
			min_dist = dist
			best_road_dir = road_vec.normalized()

	return best_road_dir


func _get_longest_edge_direction(points: PackedVector2Array) -> Vector2:
	"""Находит направление самой длинной стороны полигона"""
	var max_len := 0.0
	var best_dir := Vector2(1, 0)

	for i in range(points.size()):
		var p1 = points[i]
		var p2 = points[(i + 1) % points.size()]
		var edge = p2 - p1
		var length = edge.length()

		if length > max_len:
			max_len = length
			best_dir = edge.normalized()

	return best_dir


func _apply_parked_car_color(car: Node3D) -> void:
	"""Применяет случайный цвет к припаркованной машине"""
	var color: Color = PARKED_CAR_COLORS[randi() % PARKED_CAR_COLORS.size()]

	# Ищем меши с материалами кузова
	for child in car.get_children():
		if child is MeshInstance3D:
			var mesh_name: String = child.name.to_lower()
			# Пропускаем колёса, стёкла, фары
			if "wheel" in mesh_name or "glass" in mesh_name or "light" in mesh_name:
				continue
			if "tire" in mesh_name or "rim" in mesh_name or "brake" in mesh_name:
				continue

			# Применяем цвет к кузову
			if child.mesh and child.mesh.get_surface_count() > 0:
				var mat = child.get_active_material(0)
				if mat and mat is StandardMaterial3D:
					var new_mat = mat.duplicate()
					new_mat.albedo_color = color
					child.material_override = new_mat


func _create_parking_sign(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	"""Добавляет знак парковки в очередь для отложенного создания"""
	# Смещаем знак с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Проверяем, не создан ли уже знак в этой позиции (избегаем дубликатов)
	var pos_key := "%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "parking_sign",
		"pos": safe_pos,
		"elevation": elevation,
		"parent": parent,
		"rotation": rotation_y
	})


# Немедленное создание знака парковки (вызывается из очереди)
func _create_parking_sign_immediate(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	# RigidBody3D как корневой узел для физики
	var body := RigidBody3D.new()
	body.name = "ParkingSign"
	body.position = Vector3(pos.x, elevation, pos.y)
	body.rotation.y = rotation_y
	body.collision_layer = 4  # Слой 4 - разрушаемые знаки (отдельный от статики)
	body.collision_mask = 7  # Машины(1) + статика(2) + другие знаки(4)
	body.mass = 15.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4  # Больше контактов для надёжности
	body.body_entered.connect(_on_sign_hit.bind(body))

	# Коллизия для столба
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)

	# Столб - серый тонкий цилиндр
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.5
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Лицевая сторона знака (текстура парковки)
	var sign_front := MeshInstance3D.new()
	var front_mesh := QuadMesh.new()
	front_mesh.size = Vector2(0.6, 0.6)
	sign_front.mesh = front_mesh
	sign_front.material_override = _parking_sign_front_mat
	sign_front.position = Vector3(0, 2.3, -0.051)
	sign_front.rotation.y = PI
	sign_front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_front)

	# Обратная сторона (серый изношенный металл)
	var sign_back := MeshInstance3D.new()
	var back_mesh := QuadMesh.new()
	back_mesh.size = Vector2(0.6, 0.6)
	sign_back.mesh = back_mesh
	sign_back.material_override = _crossing_sign_back_mat
	sign_back.position = Vector3(0, 2.3, -0.029)
	sign_back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_back)

	pole.visibility_range_end = 150.0
	sign_front.visibility_range_end = 150.0
	sign_back.visibility_range_end = 150.0

	if _draw_call_logging_enabled:
		_draw_call_stats["signs"] += 2

	parent.add_child(body)


# Обработчик столкновения со знаком - активирует физику
func _on_sign_hit(other_body: Node, rigid_body: RigidBody3D) -> void:
	# Проверяем, что столкновение с машиной (VehicleBody3D, RigidBody3D или группа "car")
	var is_vehicle := other_body is VehicleBody3D or other_body is RigidBody3D or other_body.is_in_group("car")
	if is_vehicle and other_body != rigid_body:
		# Размораживаем знак - теперь он подвержен физике
		rigid_body.freeze = false
		# Добавляем импульс в направлении от машины
		var impulse_dir: Vector3 = (rigid_body.global_position - other_body.global_position).normalized()
		impulse_dir.y = 0.3  # Немного вверх для реалистичного отлёта
		var car_speed: float = 0.0
		if other_body is RigidBody3D:
			car_speed = (other_body as RigidBody3D).linear_velocity.length()
		elif other_body is VehicleBody3D:
			car_speed = (other_body as VehicleBody3D).linear_velocity.length()
		var impulse_strength: float = clamp(car_speed * 20.0, 100.0, 800.0)
		rigid_body.apply_central_impulse(impulse_dir * impulse_strength)
		# Добавляем вращение для реалистичности
		var torque := Vector3(randf_range(-5, 5), randf_range(-2, 2), randf_range(-5, 5))
		rigid_body.apply_torque_impulse(torque * impulse_strength * 0.1)


## Ставит два знака пешеходного перехода (по одному на каждое направление движения)
func _enqueue_crossing_signs(crossing_pts: PackedVector2Array, parent: Node3D) -> void:
	if crossing_pts.size() < 2:
		return
	var mid := (crossing_pts[0] + crossing_pts[crossing_pts.size() - 1]) * 0.5


	# Ищем ближайший дорожный сегмент через spatial hash
	var cell_x := int(floor(mid.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(mid.y / ROAD_CELL_SIZE))
	var best_dist := 999.0
	var best_seg: Dictionary = {}
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue
			for seg in _road_spatial_hash[key]:
				if seg.width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(mid, seg.p1, seg.p2)
				var dist: float = mid.distance_to(closest)
				if dist < best_dist:
					best_dist = dist
					best_seg = seg
	if best_seg.is_empty() or best_dist > 30.0:
		return

	var road_dir: Vector2 = (best_seg.p2 - best_seg.p1).normalized()
	var road_perp: Vector2 = Vector2(-road_dir.y, road_dir.x)
	var half_road_w: float = best_seg.width / 2.0
	var sign_offset_along := 2.0
	var sign_offset_from_edge := 1.0

	# Sign A: правая сторона для машин, едущих в road_dir (знак ДО перехода)
	var pos_a: Vector2 = mid + road_dir * sign_offset_along + Vector2(road_dir.y, -road_dir.x) * (half_road_w + sign_offset_from_edge)
	var rot_a: float = atan2(road_dir.x, road_dir.y)
	_enqueue_single_crossing_sign(pos_a, rot_a, parent)

	# Sign B: правая сторона для машин, едущих в -road_dir (знак ДО перехода для них)
	var pos_b: Vector2 = mid - road_dir * sign_offset_along + Vector2(-road_dir.y, road_dir.x) * (half_road_w + sign_offset_from_edge)
	var rot_b: float = atan2(-road_dir.x, -road_dir.y)
	_enqueue_single_crossing_sign(pos_b, rot_b, parent)


func _enqueue_single_crossing_sign(pos: Vector2, rotation_y: float, parent: Node3D) -> void:
	var safe_pos := _move_object_off_road(pos, 0.3, 3)
	var pos_key := "cs_%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true
	_infrastructure_queue.append({
		"type": "crossing_sign",
		"pos": safe_pos,
		"elevation": 0.0,
		"parent": parent,
		"rotation": rotation_y,
	})


func _create_crossing_sign_immediate(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return
	var body := RigidBody3D.new()
	body.name = "CrossingSign"
	body.position = Vector3(pos.x, elevation, pos.y)
	if elevation != 0.0:
		body.set_meta("_elevation_applied", true)
	body.rotation.y = rotation_y
	body.collision_layer = 4
	body.collision_mask = 7
	body.mass = 15.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.body_entered.connect(_on_sign_hit.bind(body))

	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)

	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.5
	pole.mesh = pole_mesh
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Лицевая сторона знака (текстура пешеходного перехода)
	var sign_front := MeshInstance3D.new()
	var front_mesh := QuadMesh.new()
	front_mesh.size = Vector2(0.6, 0.6)
	sign_front.mesh = front_mesh
	sign_front.material_override = _crossing_sign_front_mat
	sign_front.position = Vector3(0, 2.3, 0.051)
	sign_front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_front)

	# Обратная сторона (серый изношенный металл)
	var sign_back := MeshInstance3D.new()
	var back_mesh := QuadMesh.new()
	back_mesh.size = Vector2(0.6, 0.6)
	sign_back.mesh = back_mesh
	sign_back.material_override = _crossing_sign_back_mat
	sign_back.position = Vector3(0, 2.3, 0.029)
	sign_back.rotation.y = PI
	sign_back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_back)

	pole.visibility_range_end = 150.0
	sign_front.visibility_range_end = 150.0
	sign_back.visibility_range_end = 150.0

	if _draw_call_logging_enabled:
		_draw_call_stats["signs"] += 2

	parent.add_child(body)


## Немедленное создание природного объекта (вызывается из очереди)
func _create_natural_immediate(nodes: Array, tags: Dictionary, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return
	if nodes.size() < 3:
		return

	var natural_type: String = tags.get("natural", "")
	var texture_key := "grass"
	var is_water := false

	match natural_type:
		"water":
			texture_key = "water"
			is_water = true
		"wood", "tree_row":
			texture_key = "forest"
		"grassland", "scrub":
			texture_key = "grass"
		_:
			texture_key = "grass"

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Трава уже покрыта per-chunk terrain, пропускаем чтобы не было z-fighting
	if texture_key == "grass":
		return
	_create_polygon_mesh_with_texture(points, texture_key, -0.02, parent, is_water)

	# Генерируем густые деревья внутри лесных полигонов
	if natural_type in ["wood", "tree_row"]:
		_generate_trees_in_polygon(points, parent, true)


## Немедленное создание землепользования (вызывается из очереди)
func _create_landuse_immediate(nodes: Array, tags: Dictionary, parent: Node3D, way_id: int = 0) -> void:
	if not is_instance_valid(parent):
		return
	if nodes.size() < 3:
		return

	var landuse_type: String = tags.get("landuse", "")

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Индустриальные и коммерческие зоны - рисуем забор и генерируем здания внутри
	if landuse_type in ["industrial", "commercial"]:
		_add_fence_to_batch(points, parent)
		_generate_industrial_buildings(points, parent)
		return

	var texture_key := "grass"
	var is_water := false
	match landuse_type:
		"residential":
			texture_key = "grass"  # Жилые районы - трава
		"farmland", "farm":
			texture_key = "grass"  # Поля - трава (позже можно добавить специальную текстуру)
		"forest":
			texture_key = "forest"
		"grass", "meadow", "recreation_ground":
			texture_key = "grass"
		"reservoir", "basin":
			texture_key = "water"
			is_water = true
		_:
			texture_key = "grass"

	# Деревья для конкретных landuse зон по way_id (из JSON оверрайдов)
	if _decoration_layer and way_id > 0:
		var tree_override = _decoration_layer.get_landuse_tree_override(way_id)
		if tree_override:
			var dense_override: bool = tree_override.get("dense", false)
			_generate_trees_in_polygon(points, parent, dense_override)

	# Трава уже покрыта per-chunk terrain, пропускаем чтобы не было z-fighting
	if texture_key == "grass":
		return
	_create_polygon_mesh_with_texture(points, texture_key, -0.02, parent, is_water)

	# Генерируем густые деревья внутри лесных полигонов
	if landuse_type == "forest":
		_generate_trees_in_polygon(points, parent, true)


## Немедленное создание объекта отдыха (вызывается из очереди)
func _create_leisure_immediate(nodes: Array, tags: Dictionary, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return
	if nodes.size() < 3:
		return

	var leisure_type: String = tags.get("leisure", "")
	var texture_key := "grass"
	var is_water := false

	match leisure_type:
		"park", "garden":
			texture_key = "grass"
		"pitch", "stadium":
			texture_key = "grass"  # Можно добавить специальную текстуру для стадионов
		"swimming_pool":
			texture_key = "water"
			is_water = true
		_:
			texture_key = "grass"

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Добавляем коллизию с группой Park для высокого сопротивления качению
	if leisure_type in ["park", "garden", "pitch"]:
		_create_park_collision(points, parent)

	# Генерируем деревья в парках и садах
	if leisure_type in ["park", "garden"]:
		_generate_trees_in_polygon(points, parent, false)

	# Трава уже покрыта per-chunk terrain, пропускаем чтобы не было z-fighting
	if texture_key == "grass":
		return
	_create_polygon_mesh_with_texture(points, texture_key, -0.02, parent, is_water)

func _create_amenity_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
	if nodes.size() < 3:
		return

		var ck: String = _get_chunk_key_from_node(parent)

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Сохраняем рёбра для проверки расстояния при генерации деревьев
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var seg := {"p1": p1, "p2": p2}
		_building_segments.append(seg)
		_add_building_segment_to_spatial_hash(seg)

	var amenity_type: String = str(tags.get("amenity", ""))

	# Территории (школы, детсады, университеты, пожарные станции, полиция) - рисуем забор, а не здание
	# Здание внутри рисуется отдельно если есть building тег
	var territory_types := ["school", "kindergarten", "college", "university", "fire_station", "police"]
	if amenity_type in territory_types:
		_add_fence_to_batch(points, parent)
		return

	# Заправки не создаём как здания
	if amenity_type == "fuel":
		return

	# Парковки обрабатываем отдельно
	if amenity_type == "parking":
		_create_parking(points, parent)
		return

	# Остальные amenity - создаём как маленькие здания
	var building_height: float
	var color: Color

	match amenity_type:
		"hospital":
			building_height = 18.0
			color = Color(0.95, 0.95, 0.95)  # Белый
		"clinic":
			building_height = 12.0
			color = Color(0.9, 0.9, 0.95)  # Бело-голубой
		"police":
			building_height = 10.0
			color = Color(0.3, 0.4, 0.6)  # Тёмно-синий
		"fire_station":
			building_height = 10.0
			color = Color(0.85, 0.3, 0.25)  # Красный
		"place_of_worship", "church":
			building_height = 20.0
			color = Color(0.95, 0.9, 0.75)  # Золотистый
		"bank":
			building_height = 12.0
			color = Color(0.5, 0.6, 0.5)  # Серо-зелёный
		"post_office":
			building_height = 8.0
			color = Color(0.3, 0.45, 0.7)  # Синий
		"restaurant", "cafe", "fast_food", "bar", "pub":
			building_height = 5.0
			color = Color(0.8, 0.6, 0.4)  # Оранжево-коричневый
		"fuel":
			building_height = 4.0
			color = Color(0.85, 0.75, 0.3)  # Жёлтый
		"theatre", "cinema":
			building_height = 15.0
			color = Color(0.6, 0.35, 0.5)  # Пурпурный
		"library":
			building_height = 10.0
			color = Color(0.55, 0.45, 0.35)  # Коричневый
		_:
			building_height = 8.0
			color = Color(0.6, 0.5, 0.5)

	_create_3d_building(points, color, building_height, parent, 0.0)

## ─── Iron bar fence system ───────────────────────────────────────────

## Append a box (24 verts, 36 indices) to geometry arrays.
## center: world-space center of box
## hs: Vector3(half_width, half_height, half_depth)
## fwd/right: orientation vectors (unit length, XZ plane)
static func _append_fence_box(verts: PackedVector3Array, norms: PackedVector3Array,
		idxs: PackedInt32Array, center: Vector3, hs: Vector3,
		fwd: Vector3, right: Vector3) -> void:
	var up := Vector3.UP
	var r := right * hs.x
	var u := up * hs.y
	var f := fwd * hs.z
	# 6 faces × 4 verts = 24 verts, 6 faces × 6 indices = 36 indices
	var faces := [
		[f, r, u, fwd],       # front
		[-f, -r, u, -fwd],    # back
		[r, -f, u, right],    # right
		[-r, f, u, -right],   # left
		[u, r, f, up],        # top
		[-u, -r, f, -up],     # bottom
	]
	for face in faces:
		var n: Vector3 = face[3]
		var o: Vector3 = center + face[0]   # face center offset
		var a: Vector3 = face[1]            # axis 1 (half-extent)
		var b: Vector3 = face[2]            # axis 2 (half-extent)
		var bi := verts.size()
		verts.append(o - a - b)
		verts.append(o + a - b)
		verts.append(o + a + b)
		verts.append(o - a + b)
		norms.append(n); norms.append(n); norms.append(n); norms.append(n)
		idxs.append(bi); idxs.append(bi + 1); idxs.append(bi + 2)
		idxs.append(bi); idxs.append(bi + 2); idxs.append(bi + 3)


## Generate one fence section between p1 and p2, appending geometry to lod0/lod1 batch dicts.
func _generate_fence_segment(p1: Vector2, p2: Vector2,
		lod0: Dictionary, lod1: Dictionary, rng_seed: int) -> void:
	const FENCE_HEIGHT := 2.2
	const POST_HS := Vector3(0.04, 1.1, 0.04)       # 80×2200×80 mm
	const BAR_HS := Vector3(0.0125, 1.1, 0.0125)     # 25×2200×25 mm
	const RAIL_HS_Y := 0.02                           # rail half-height (40mm)
	const RAIL_HS_Z := 0.015                          # rail half-depth (30mm)
	const BAR_SPACING := 0.12
	const BOTTOM_RAIL_Y := 0.15
	const TOP_RAIL_Y := 2.0
	const BASE_Y := 0.12  # ground offset

	var seg_dir := (p2 - p1).normalized()
	var seg_len := p1.distance_to(p2)
	var fwd := Vector3(seg_dir.x, 0.0, seg_dir.y)
	var right := Vector3(-seg_dir.y, 0.0, seg_dir.x)

	# Height variation from seed
	var h_var := 1.0 + (float((rng_seed * 2654435761) & 0xFFFF) / 65535.0 - 0.5) * 0.06  # ±3%
	var fence_h := FENCE_HEIGHT * h_var
	var post_hs := Vector3(POST_HS.x, fence_h * 0.5, POST_HS.z)
	var bar_hs := Vector3(BAR_HS.x, fence_h * 0.5, BAR_HS.z)

	var center_y := BASE_Y + fence_h * 0.5

	# Posts at both ends — into both LODs
	var p1_c := Vector3(p1.x, center_y, p1.y)
	var p2_c := Vector3(p2.x, center_y, p2.y)
	_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, p1_c, post_hs, fwd, right)
	_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, p2_c, post_hs, fwd, right)
	_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, p1_c, post_hs, fwd, right)
	_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, p2_c, post_hs, fwd, right)

	# Vertical bars
	var num_bars := int(seg_len / BAR_SPACING)
	if num_bars > 1:
		for i in range(1, num_bars):
			var t := float(i) / float(num_bars)
			var bp := p1.lerp(p2, t)
			var bc := Vector3(bp.x, center_y, bp.y)
			_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, bc, bar_hs, fwd, right)
			if i % 2 == 0:
				_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, bc, bar_hs, fwd, right)

	# Horizontal rails (both LODs)
	var mid := p1.lerp(p2, 0.5)
	var rail_hs := Vector3(RAIL_HS_Z, RAIL_HS_Y, seg_len * 0.5)
	# Bottom rail
	var rc_bot := Vector3(mid.x, BASE_Y + BOTTOM_RAIL_Y, mid.y)
	_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, rc_bot, rail_hs, fwd, right)
	_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, rc_bot, rail_hs, fwd, right)
	# Top rail
	var rc_top := Vector3(mid.x, BASE_Y + TOP_RAIL_Y, mid.y)
	_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, rc_top, rail_hs, fwd, right)
	_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, rc_top, rail_hs, fwd, right)


## Add iron bar fence along polyline to chunk batch
func _add_fence_to_batch(points: PackedVector2Array, parent: Node3D) -> void:
	if points.size() < 3:
		return

	var chunk_key := _get_chunk_key_from_node(parent)
	if chunk_key.is_empty():
		chunk_key = "default"

	if not _fence_geo_batch.has(chunk_key):
		_fence_geo_batch[chunk_key] = {
			"parent": parent,
			"lod0": {"vertices": PackedVector3Array(), "normals": PackedVector3Array(), "indices": PackedInt32Array()},
			"lod1": {"vertices": PackedVector3Array(), "normals": PackedVector3Array(), "indices": PackedInt32Array()},
			"edges": []  # Array of {p1: Vector2, p2: Vector2} for collision
		}

	var batch: Dictionary = _fence_geo_batch[chunk_key]
	var fence_offset := 0.3  # Match existing fence offset from contour

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Apply outward offset (same as old _create_fence)
		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x) * fence_offset
		p1 = p1 + outward
		p2 = p2 + outward

		var seg_len := p1.distance_to(p2)
		if seg_len < 0.5:
			continue

		# Store edge for collision (one box per full edge, not per subdivision)
		batch.edges.append({"p1": p1, "p2": p2})

		# Subdivide into ~2.25m sections
		var num_sections := maxi(1, int(round(seg_len / 2.25)))
		for j in range(num_sections):
			var t1 := float(j) / float(num_sections)
			var t2 := float(j + 1) / float(num_sections)
			var sp1 := p1.lerp(p2, t1)
			var sp2 := p1.lerp(p2, t2)
			var seed_val := int(sp1.x * 1000.0) ^ int(sp1.y * 1000.0) ^ (i * 997 + j)
			_generate_fence_segment(sp1, sp2, batch.lod0, batch.lod1, seed_val)

	if not _fence_batches_to_finalize.has(chunk_key):
		_fence_batches_to_finalize.append(chunk_key)


## Finalize fence batch: create two RS instances (LOD0 + LOD1) per chunk
func _finalize_fence_batches_for_chunk(chunk_key: String) -> void:
	if not _fence_geo_batch.has(chunk_key):
		return
	var batch: Dictionary = _fence_geo_batch[chunk_key]
	if not is_instance_valid(batch.parent):
		_fence_geo_batch.erase(chunk_key)
		return

	var lod0: Dictionary = batch.lod0
	var lod1: Dictionary = batch.lod1
	var lod0_verts: PackedVector3Array = lod0.vertices
	var lod1_verts: PackedVector3Array = lod1.vertices
	var lod0_count: int = lod0_verts.size()
	var lod1_count: int = lod1_verts.size()

	if lod0_count > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = lod0_verts
		arrays[Mesh.ARRAY_NORMAL] = lod0.normals
		arrays[Mesh.ARRAY_INDEX] = lod0.indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_rs_add_mesh(chunk_key, mesh, _fence_material,
			RenderingServer.SHADOW_CASTING_SETTING_OFF, 50.0)

	if lod1_count > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = lod1_verts
		arrays[Mesh.ARRAY_NORMAL] = lod1.normals
		arrays[Mesh.ARRAY_INDEX] = lod1.indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_rs_add_mesh(chunk_key, mesh, _fence_material,
			RenderingServer.SHADOW_CASTING_SETTING_OFF, 150.0, 50.0)

	# Collision: one StaticBody3D per chunk with box per edge
	var edges: Array = batch.edges
	if not edges.is_empty():
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		for edge in edges:
			var ep1: Vector2 = edge.p1
			var ep2: Vector2 = edge.p2
			var mid := ep1.lerp(ep2, 0.5)
			var elen := ep1.distance_to(ep2)
			var edir := (ep2 - ep1).normalized()
			var angle := atan2(edir.y, edir.x)

			var collision := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(elen, 2.2, 0.08)  # length × fence height × thin wall
			collision.shape = box
			collision.position = Vector3(mid.x, 0.12 + 1.1, mid.y)  # BASE_Y + half height
			collision.rotation.y = -angle
			body.add_child(collision)
		_budgeted_add_child(batch.parent, body)

	print("OSM: Finalized fence batch %s: LOD0 %d verts, LOD1 %d verts, %d collision edges" % [chunk_key, lod0_count, lod1_count, edges.size()])
	_fence_geo_batch.erase(chunk_key)


## ─── End iron bar fence system ──────────────────────────────────────

func _create_fence(points: PackedVector2Array, parent: Node3D) -> void:
	# Создаём забор по контуру территории
	if points.size() < 3:
		return

	var fence_height := 2.0  # Высота забора в метрах
	var fence_color := Color(0.4, 0.35, 0.3)  # Коричневый/серый
	var fence_offset := 0.3  # Отступ забора от контура здания для предотвращения z-fighting

	var mesh := MeshInstance3D.new()
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Используем шейдер для правильного двустороннего освещения
	var material := ShaderMaterial.new()
	material.shader = BuildingWallShader
	material.set_shader_parameter("albedo_color", fence_color)
	material.set_shader_parameter("use_texture", false)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)

	# Рисуем забор как стены по периметру с небольшим отступом наружу
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Вычисляем направление наружу для отступа
		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x) * fence_offset
		p1 = p1 + outward
		p2 = p2 + outward

		var h1 := 0.0 + 0.12
		var h2 := 0.0 + 0.12

		var v1 := Vector3(p1.x, h1, p1.y)
		var v2 := Vector3(p2.x, h2, p2.y)
		var v3 := Vector3(p2.x, h2 + fence_height, p2.y)
		var v4 := Vector3(p1.x, h1 + fence_height, p1.y)

		# Нормаль стены (наружу)
		var wall_normal := Vector3(-dir.y, 0, dir.x)

		# Внешняя сторона (два треугольника)
		st.set_normal(wall_normal)
		st.add_vertex(v1)
		st.set_normal(wall_normal)
		st.add_vertex(v2)
		st.set_normal(wall_normal)
		st.add_vertex(v3)

		st.set_normal(wall_normal)
		st.add_vertex(v1)
		st.set_normal(wall_normal)
		st.add_vertex(v3)
		st.set_normal(wall_normal)
		st.add_vertex(v4)

	mesh.mesh = st.commit()
	mesh.material_override = material

	# Добавляем коллизию для забора
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0  # Статика не проверяет коллизии
	body.add_child(mesh)

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		# Применяем тот же отступ что и для визуала
		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x) * fence_offset
		p1 = p1 + outward
		p2 = p2 + outward

		var wall_length := p1.distance_to(p2)
		if wall_length < 0.5:
			continue

		var h1 := 0.0 + 0.12
		var h2 := 0.0 + 0.12
		var avg_h := (h1 + h2) / 2.0

		var wall_center := Vector3((p1.x + p2.x) / 2, avg_h + fence_height / 2, (p1.y + p2.y) / 2)
		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(wall_length, fence_height, 0.15)
		collision.shape = box
		collision.position = wall_center
		collision.rotation.y = -wall_angle

		body.add_child(collision)

	parent.add_child(body)

func _create_waterway(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node) -> void:
	var waterway_type: String = tags.get("waterway", "")
	var width: float

	match waterway_type:
		"river":
			width = 15.0
		"stream":
			width = 3.0
		"canal":
			width = 8.0
		"ditch", "drain":
			width = 2.0
		_:
			width = 5.0

	_create_path_mesh(nodes, width, COLORS["water"], 0.03, parent, null)

func _create_3d_building(points: PackedVector2Array, color: Color, building_height: float, parent: Node3D, base_elev: float = 0.0, _debug_name: String = "") -> void:
	# Минимум 4 точки для нормального здания (3 - треугольник, плохо)
	if points.size() < 4:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Проверка на слишком маленькие или вырожденные здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var size_x := max_x - min_x
	var size_z := max_z - min_z

	# Пропускаем слишком маленькие здания (< 3м)
	if size_x < 3.0 or size_z < 3.0:
		return

	# Пропускаем слишком большие здания (возможно ошибка данных > 200м)
	if size_x > 200.0 or size_z > 200.0:
		return

	# Проверка на соотношение сторон (слишком вытянутые - вероятно ошибка)
	var min_size: float = min(size_x, size_z)
	if min_size < 0.1:
		return
	var aspect: float = max(size_x, size_z) / min_size
	if aspect > 20.0:
		return

	# Проверка на площадь (слишком маленькая площадь = плохие данные)
	var area: float = _calculate_polygon_area(points)
	if area < 10.0:  # Меньше 10 м²
		return

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON  # Отбрасывать тень

	# Используем шейдер для правильного двустороннего освещения
	var material := ShaderMaterial.new()
	material.shader = BuildingWallShader
	material.set_shader_parameter("albedo_color", color)
	material.set_shader_parameter("use_texture", false)
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Высоты с учётом террейна
	var fnd_h := _get_foundation_height(points)
	var floor_y := base_elev + fnd_h
	var foundation_y := base_elev + fnd_h
	var roof_y := base_elev + building_height

	# Крыша - используем триангуляцию для корректной работы с невыпуклыми полигонами
	var roof_indices := Geometry2D.triangulate_polygon(points)
	if roof_indices.size() >= 3:
		im.surface_set_normal(Vector3.UP)  # Нормаль вверх для крыши
		for i in range(0, roof_indices.size(), 3):
			var p1 := points[roof_indices[i]]
			var p2 := points[roof_indices[i + 1]]
			var p3 := points[roof_indices[i + 2]]
			im.surface_add_vertex(Vector3(p1.x, roof_y, p1.y))
			im.surface_add_vertex(Vector3(p2.x, roof_y, p2.y))
			im.surface_add_vertex(Vector3(p3.x, roof_y, p3.y))

	# Определяем направление обхода для корректных нормалей наружу
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	# Стены
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var v1 := Vector3(p1.x, foundation_y, p1.y)
		var v2 := Vector3(p2.x, foundation_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		# Вычисляем нормаль стены (наружу) — учитываем направление обхода полигона
		var wall_dir := Vector2(p2.x - p1.x, p2.y - p1.y).normalized()
		var wall_normal := Vector3(-wall_dir.y * normal_sign, 0, wall_dir.x * normal_sign)
		im.surface_set_normal(wall_normal)

		# Внешняя сторона
		im.surface_add_vertex(v1)
		im.surface_add_vertex(v2)
		im.surface_add_vertex(v3)

		im.surface_add_vertex(v1)
		im.surface_add_vertex(v3)
		im.surface_add_vertex(v4)

	im.surface_end()

	# === ФУНДАМЕНТ ===
	var fnd_color_idx := int(abs(points[0].x * 73.0 + points[0].y * 137.0)) % 4
	var fnd_mesh := MeshInstance3D.new()
	var fnd_im := ImmediateMesh.new()
	fnd_mesh.mesh = fnd_im
	fnd_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var fnd_mat := StandardMaterial3D.new()
	fnd_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var fnd_src := _building_foundation_materials[fnd_color_idx]
	fnd_mat.albedo_color = fnd_src.albedo_color
	# Рандомная дешёвая краска: roughness 0.5-0.9, metallic 0.02-0.10
	var fnd_hash := fmod(abs(points[0].x * 41.0 + points[0].y * 59.0), 1.0)
	fnd_mat.roughness = 0.5 + fnd_hash * 0.4
	fnd_mat.metallic = 0.02 + fnd_hash * 0.08
	fnd_mat.metallic_specular = 0.3
	fnd_mesh.material_override = fnd_mat
	var fnd_top := base_elev + fnd_h
	var fnd_bottom := base_elev
	fnd_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(points.size()):
		var fp1 := points[i]
		var fp2 := points[(i + 1) % points.size()]
		var fdir := Vector2(fp2.x - fp1.x, fp2.y - fp1.y).normalized()
		var fnorm := Vector3(-fdir.y * normal_sign, 0, fdir.x * normal_sign)
		fnd_im.surface_set_normal(fnorm)
		var fv1 := Vector3(fp1.x, fnd_top, fp1.y)
		var fv2 := Vector3(fp2.x, fnd_top, fp2.y)
		var fv3 := Vector3(fp2.x, fnd_bottom, fp2.y)
		var fv4 := Vector3(fp1.x, fnd_bottom, fp1.y)
		fnd_im.surface_add_vertex(fv1)
		fnd_im.surface_add_vertex(fv2)
		fnd_im.surface_add_vertex(fv3)
		fnd_im.surface_add_vertex(fv1)
		fnd_im.surface_add_vertex(fv3)
		fnd_im.surface_add_vertex(fv4)
	fnd_im.surface_end()

	var body := StaticBody3D.new()
	body.collision_layer = 2  # Слой 2 для зданий
	body.collision_mask = 0   # Статика не проверяет коллизии (машина проверяет со зданиями)
	body.add_child(mesh)
	body.add_child(fnd_mesh)

	# Коллизия только на уровне земли (0.5м) — машина не врезается во второй этаж
	var collision_h := 0.5
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_center := Vector3((p1.x + p2.x) / 2, base_elev + collision_h / 2, (p1.y + p2.y) / 2)
		var wall_length := p1.distance_to(p2)

		if wall_length < 0.5:
			continue

		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(wall_length, collision_h, 0.3)
		collision.shape = box
		collision.position = wall_center
		collision.rotation.y = -wall_angle

		body.add_child(collision)

	parent.add_child(body)


# === МНОГОПОТОЧНАЯ ГЕНЕРАЦИЯ ЗДАНИЙ ===

## Добавляет здание в очередь для генерации в worker thread
func _queue_building_for_thread(points: PackedVector2Array, building_height: float, texture_type: String, parent: Node3D, base_elev: float, distance_to_player: float = INF) -> void:
	var task_data := {
		"points": points,
		"building_height": building_height,
		"texture_type": texture_type,
		"parent": parent,
		"base_elev": base_elev,
		"distance_to_player": distance_to_player  # For shadow LOD
	}

	# Добавляем задачу в пул потоков
	_pending_building_tasks += 1
	WorkerThreadPool.add_task(_compute_building_mesh_thread.bind(task_data))


## Вычисляет геометрию здания в worker thread (без создания Node)
func _compute_building_mesh_thread(task_data: Dictionary) -> void:
	var points: PackedVector2Array = task_data.points
	var building_height: float = task_data.building_height
	var base_elev: float = task_data.base_elev

	# Валидация (повторяем проверки без раннего выхода - просто отмечаем как invalid)
	var valid := true

	if points.size() < 4:
		valid = false

	# Убираем дубликат последней точки
	if valid and points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points = points.duplicate()
		points.remove_at(points.size() - 1)

	if valid and points.size() < 3:
		valid = false

	# Проверка размеров
	if valid:
		var min_x := points[0].x
		var max_x := points[0].x
		var min_z := points[0].y
		var max_z := points[0].y
		for p in points:
			min_x = min(min_x, p.x)
			max_x = max(max_x, p.x)
			min_z = min(min_z, p.y)
			max_z = max(max_z, p.y)
		var size_x := max_x - min_x
		var size_z := max_z - min_z
		if size_x < 3.0 or size_z < 3.0 or size_x > 200.0 or size_z > 200.0:
			valid = false
		var min_size: float = min(size_x, size_z)
		if min_size < 0.1 or max(size_x, size_z) / min_size > 20.0:
			valid = false
		# Площадь (inline расчёт для thread-safety)
		if valid:
			var area := 0.0
			var n := points.size()
			for i in range(n):
				var j := (i + 1) % n
				area += points[i].x * points[j].y
				area -= points[j].x * points[i].y
			area = abs(area) / 2.0
			if area < 10.0:
				valid = false

	if not valid:
		# Добавляем пустой результат чтобы уменьшить счётчик
		_building_mutex.lock()
		_building_results.append({"valid": false})
		_pending_building_tasks -= 1
		_building_mutex.unlock()
		return

	# === ВЫЧИСЛЕНИЕ ГЕОМЕТРИИ СТЕН ===
	var fnd_h := _get_foundation_height(points)
	var floor_y := base_elev + fnd_h
	var foundation_y := base_elev + fnd_h
	var roof_y := base_elev + building_height

	var wall_vertices := PackedVector3Array()
	var wall_uvs := PackedVector2Array()
	var wall_normals := PackedVector3Array()
	var wall_indices := PackedInt32Array()

	var uv_scale_x := 0.1
	var uv_scale_y := 0.1
	var accumulated_width := 0.0

	# Определяем направление полигона для корректных нормалей
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var wall_width := p1.distance_to(p2)

		var v1 := Vector3(p1.x, foundation_y, p1.y)
		var v2 := Vector3(p2.x, foundation_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		var dir := (p2 - p1).normalized()
		# Нормаль наружу - учитываем направление обхода полигона
		var normal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)

		var u1 := accumulated_width * uv_scale_x
		var u2 := (accumulated_width + wall_width) * uv_scale_x
		var v_bottom := 0.0
		var v_top := building_height * uv_scale_y

		var idx := wall_vertices.size()

		wall_vertices.append(v1)
		wall_vertices.append(v2)
		wall_vertices.append(v3)
		wall_vertices.append(v4)

		wall_uvs.append(Vector2(u1, v_bottom))
		wall_uvs.append(Vector2(u2, v_bottom))
		wall_uvs.append(Vector2(u2, v_top))
		wall_uvs.append(Vector2(u1, v_top))

		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)

		wall_indices.append(idx + 0)
		wall_indices.append(idx + 1)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 0)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 3)

		accumulated_width += wall_width

	# === ТРИАНГУЛЯЦИЯ КРЫШИ (плоская поверхность) ===
	var roof_vertices := PackedVector3Array()
	var roof_uvs := PackedVector2Array()
	var roof_normals := PackedVector3Array()
	var roof_indices := PackedInt32Array()

	# === ПАРАПЕТ (бордюр по краю крыши) ===
	var parapet_vertices := PackedVector3Array()
	var parapet_uvs := PackedVector2Array()
	var parapet_normals := PackedVector3Array()
	var parapet_indices := PackedInt32Array()

	# Ограничиваем сложность полигонов (слишком много точек могут вызвать зависание)
	if points.size() <= 100:
		var roof_indices_2d := Geometry2D.triangulate_polygon(points)

		if roof_indices_2d.size() >= 3:
			# Плоская крыша по оригинальным точкам
			for p in points:
				roof_vertices.append(Vector3(p.x, roof_y, p.y))
				roof_uvs.append(Vector2(p.x * 0.1, p.y * 0.1))
				roof_normals.append(Vector3.UP)
			for idx in roof_indices_2d:
				roof_indices.append(idx)

			# Парапет: наружная, нижняя грани + угловые заполнения
			var n_pts := points.size()
			var parapet_top := roof_y + 0.50
			var parapet_bottom := roof_y

			# Предвычисляем offset каждого ребра (normal_sign из signed area — надёжно для любой формы)
			var edge_offsets := PackedVector2Array()
			for ei in n_pts:
				var ei_next := (ei + 1) % n_pts
				var edir := (points[ei_next] - points[ei]).normalized()
				edge_offsets.append(Vector2(-edir.y * normal_sign, edir.x * normal_sign) * 0.20)

			for i in n_pts:
				var i_next := (i + 1) % n_pts
				var p0 := points[i]
				var p1 := points[i_next]
				var off := edge_offsets[i]
				var dir2 := (p1 - p0).normalized()
				var out_normal := Vector3(-dir2.y * normal_sign, 0.0, dir2.x * normal_sign)

				var op0 := p0 + off
				var op1 := p1 + off

				# Наружная грань
				var vi := parapet_vertices.size()
				parapet_vertices.append(Vector3(op0.x, parapet_top, op0.y))
				parapet_vertices.append(Vector3(op1.x, parapet_top, op1.y))
				parapet_vertices.append(Vector3(op1.x, parapet_bottom, op1.y))
				parapet_vertices.append(Vector3(op0.x, parapet_bottom, op0.y))
				parapet_uvs.append(Vector2(0, 0))
				parapet_uvs.append(Vector2(1, 0))
				parapet_uvs.append(Vector2(1, 1))
				parapet_uvs.append(Vector2(0, 1))
				parapet_normals.append(out_normal)
				parapet_normals.append(out_normal)
				parapet_normals.append(out_normal)
				parapet_normals.append(out_normal)
				parapet_indices.append(vi + 0)
				parapet_indices.append(vi + 1)
				parapet_indices.append(vi + 2)
				parapet_indices.append(vi + 0)
				parapet_indices.append(vi + 2)
				parapet_indices.append(vi + 3)

				# Нижняя грань
				vi = parapet_vertices.size()
				parapet_vertices.append(Vector3(op0.x, parapet_bottom, op0.y))
				parapet_vertices.append(Vector3(op1.x, parapet_bottom, op1.y))
				parapet_vertices.append(Vector3(p1.x, parapet_bottom, p1.y))
				parapet_vertices.append(Vector3(p0.x, parapet_bottom, p0.y))
				parapet_uvs.append(Vector2(0, 0))
				parapet_uvs.append(Vector2(1, 0))
				parapet_uvs.append(Vector2(1, 1))
				parapet_uvs.append(Vector2(0, 1))
				parapet_normals.append(Vector3.DOWN)
				parapet_normals.append(Vector3.DOWN)
				parapet_normals.append(Vector3.DOWN)
				parapet_normals.append(Vector3.DOWN)
				parapet_indices.append(vi + 0)
				parapet_indices.append(vi + 1)
				parapet_indices.append(vi + 2)
				parapet_indices.append(vi + 0)
				parapet_indices.append(vi + 2)
				parapet_indices.append(vi + 3)

				# Угловое заполнение
				var next_off := edge_offsets[i_next]
				var corner_a := p1 + off
				var corner_b := p1 + next_off
				if corner_a.distance_squared_to(corner_b) > 0.0001:
					var mid_dir := (off.normalized() + next_off.normalized()).normalized()
					var face_normal := Vector3(mid_dir.x, 0.0, mid_dir.y)
					vi = parapet_vertices.size()
					parapet_vertices.append(Vector3(corner_a.x, parapet_top, corner_a.y))
					parapet_vertices.append(Vector3(corner_b.x, parapet_top, corner_b.y))
					parapet_vertices.append(Vector3(corner_b.x, parapet_bottom, corner_b.y))
					parapet_vertices.append(Vector3(corner_a.x, parapet_bottom, corner_a.y))
					parapet_uvs.append(Vector2(0, 0))
					parapet_uvs.append(Vector2(1, 0))
					parapet_uvs.append(Vector2(1, 1))
					parapet_uvs.append(Vector2(0, 1))
					parapet_normals.append(face_normal)
					parapet_normals.append(face_normal)
					parapet_normals.append(face_normal)
					parapet_normals.append(face_normal)
					parapet_indices.append(vi + 0)
					parapet_indices.append(vi + 1)
					parapet_indices.append(vi + 2)
					parapet_indices.append(vi + 0)
					parapet_indices.append(vi + 2)
					parapet_indices.append(vi + 3)

	# === ФУНДАМЕНТ (0.5м полоса под стенами) ===
	var fnd_vertices := PackedVector3Array()
	var fnd_uvs := PackedVector2Array()
	var fnd_normals := PackedVector3Array()
	var fnd_indices := PackedInt32Array()
	var fnd_top := base_elev + fnd_h
	var fnd_bottom := base_elev
	var fnd_material_idx := int(abs(points[0].x * 73.0 + points[0].y * 137.0)) % 4

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var dir := (p2 - p1).normalized()
		var fnormal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)

		var vi := fnd_vertices.size()
		fnd_vertices.append(Vector3(p1.x, fnd_top, p1.y))
		fnd_vertices.append(Vector3(p2.x, fnd_top, p2.y))
		fnd_vertices.append(Vector3(p2.x, fnd_bottom, p2.y))
		fnd_vertices.append(Vector3(p1.x, fnd_bottom, p1.y))
		fnd_uvs.append(Vector2(0, 0))
		fnd_uvs.append(Vector2(1, 0))
		fnd_uvs.append(Vector2(1, 1))
		fnd_uvs.append(Vector2(0, 1))
		fnd_normals.append(fnormal)
		fnd_normals.append(fnormal)
		fnd_normals.append(fnormal)
		fnd_normals.append(fnormal)
		fnd_indices.append(vi + 0)
		fnd_indices.append(vi + 1)
		fnd_indices.append(vi + 2)
		fnd_indices.append(vi + 0)
		fnd_indices.append(vi + 2)
		fnd_indices.append(vi + 3)

	# Сохраняем результат
	var result := {
		"valid": true,
		"points": points,
		"building_height": building_height,
		"texture_type": task_data.texture_type,
		"parent": task_data.parent,
		"base_elev": base_elev,
		"distance_to_player": task_data.distance_to_player,
		"wall_vertices": wall_vertices,
		"wall_uvs": wall_uvs,
		"wall_normals": wall_normals,
		"wall_indices": wall_indices,
		"roof_vertices": roof_vertices,
		"roof_uvs": roof_uvs,
		"roof_normals": roof_normals,
		"roof_indices": roof_indices,
		"parapet_vertices": parapet_vertices,
		"parapet_uvs": parapet_uvs,
		"parapet_normals": parapet_normals,
		"parapet_indices": parapet_indices,
		"fnd_vertices": fnd_vertices,
		"fnd_uvs": fnd_uvs,
		"fnd_normals": fnd_normals,
		"fnd_indices": fnd_indices,
		"fnd_material_idx": fnd_material_idx
	}

	_building_mutex.lock()
	_building_results.append(result)
	_pending_building_tasks -= 1
	_building_mutex.unlock()


func _make_empty_geo_batch() -> Dictionary:
	return {"vertices": PackedVector3Array(), "uvs": PackedVector2Array(), "normals": PackedVector3Array(), "indices": PackedInt32Array()}


## Накапливает геометрию здания в batch для последующего merge в один ArrayMesh на чанк
func _apply_building_mesh_result(result: Dictionary) -> void:
	if not result.valid:
		return

	if not is_instance_valid(result.get("parent")):
		return
	var parent: Node3D = result.parent

	var texture_type: String = result.texture_type
	var building_height: float = result.building_height
	var base_elev: float = result.base_elev
	var points: PackedVector2Array = result.points

	# Определяем chunk_key из parent node или из координат здания
	var chunk_key := _get_chunk_key_from_node(parent)
	if chunk_key.is_empty():
		# parent не Chunk_ — вычисляем chunk_key из центра здания
		var center := _get_polygon_center(points)
		var cx := int(floor(center.x / chunk_size))
		var cz := int(floor(center.y / chunk_size))
		chunk_key = "%d,%d" % [cx, cz]
		# Используем chunk node если он уже загружен, иначе parent
		if _loaded_chunks.has(chunk_key):
			parent = _loaded_chunks[chunk_key]

	# Инициализируем batch для чанка
	if not _building_geo_batch.has(chunk_key):
		_building_geo_batch[chunk_key] = {
			"parent": parent,
			"panel_walls": _make_empty_geo_batch(),
			"brick_walls": _make_empty_geo_batch(),
			"wall_walls": _make_empty_geo_batch(),
			"roofs": _make_empty_geo_batch(),
			"parapets": _make_empty_geo_batch(),
			"foundation_0": _make_empty_geo_batch(),
			"foundation_1": _make_empty_geo_batch(),
			"foundation_2": _make_empty_geo_batch(),
			"foundation_3": _make_empty_geo_batch(),
			"collisions": [],
			"_building_ranges": [],
		}

	var batch: Dictionary = _building_geo_batch[chunk_key]


	var wall_verts: PackedVector3Array = result.wall_vertices
	var roof_verts: PackedVector3Array = result.roof_vertices
	# === НАКАПЛИВАЕМ СТЕНЫ ===
	var wall_key: String = texture_type + "_walls"
	if not batch.has(wall_key):
		wall_key = "brick_walls"

	var wall_batch: Dictionary = batch[wall_key]
	var wall_start: int = wall_batch["vertices"].size()
	wall_batch["vertices"].append_array(wall_verts)
	wall_batch["uvs"].append_array(result.wall_uvs)
	wall_batch["normals"].append_array(result.wall_normals)
	# Сдвигаем индексы на wall_start
	for i in range(result.wall_indices.size()):
		wall_batch["indices"].append(result.wall_indices[i] + wall_start)

	# === НАКАПЛИВАЕМ КРЫШУ ===
	var roof_start: int = -1
	var roof_count: int = 0
	if result.roof_indices.size() >= 3:
		var roof_batch: Dictionary = batch["roofs"]
		roof_start = roof_batch["vertices"].size()
		roof_batch["vertices"].append_array(roof_verts)
		roof_batch["uvs"].append_array(result.roof_uvs)
		roof_batch["normals"].append_array(result.roof_normals)
		for i in range(result.roof_indices.size()):
			roof_batch["indices"].append(result.roof_indices[i] + roof_start)
		roof_count = roof_verts.size()

	# === НАКАПЛИВАЕМ ПАРАПЕТ ===
	var parapet_verts: PackedVector3Array = result.parapet_vertices
	var parapet_start: int = -1
	var parapet_count: int = 0
	if result.parapet_indices.size() >= 3:
		var parapet_batch: Dictionary = batch["parapets"]
		parapet_start = parapet_batch["vertices"].size()
		parapet_batch["vertices"].append_array(parapet_verts)
		parapet_batch["uvs"].append_array(result.parapet_uvs)
		parapet_batch["normals"].append_array(result.parapet_normals)
		for i in range(result.parapet_indices.size()):
			parapet_batch["indices"].append(result.parapet_indices[i] + parapet_start)
		parapet_count = parapet_verts.size()

	# === НАКАПЛИВАЕМ ФУНДАМЕНТ ===
	var fnd_verts: PackedVector3Array = result.fnd_vertices
	if result.fnd_indices.size() >= 3:
		var fnd_key := "foundation_%d" % result.fnd_material_idx
		var fnd_batch: Dictionary = batch[fnd_key]
		var fnd_start: int = fnd_batch["vertices"].size()
		fnd_batch["vertices"].append_array(fnd_verts)
		fnd_batch["uvs"].append_array(result.fnd_uvs)
		fnd_batch["normals"].append_array(result.fnd_normals)
		for i in range(result.fnd_indices.size()):
			fnd_batch["indices"].append(result.fnd_indices[i] + fnd_start)

	# Сохраняем ranges для deferred elevation
	batch["_building_ranges"].append({
		"wall_key": wall_key,
		"wall_start": wall_start,
		"wall_count": wall_verts.size(),
		"roof_start": roof_start,
		"roof_count": roof_count,
		"parapet_start": parapet_start,
		"parapet_count": parapet_count,
		"points": points,
		"elev_baked": false
	})

	batch["_all_baked"] = false

	# === СОХРАНЯЕМ ДАННЫЕ КОЛЛИЗИЙ ===
	batch["collisions"].append({
		"points": points,
		"base_elev": base_elev,
		"building_height": building_height
	})

	# === ОКНА — вызываем сразу (они сами накапливаются в _window_batch_data) ===
	_add_building_night_decorations.call_deferred(null, points, building_height, parent, base_elev)


## Создаёт merged ArrayMesh для всех зданий чанка — ONE surface per frame (incremental)
## Surface order: panel_walls → brick_walls → wall_walls → roofs → parapets → foundation_0..3 → cleanup
func _finalize_building_geo_batch(chunk_key: String) -> void:
	if not _building_geo_batch.has(chunk_key):
		return

	var batch: Dictionary = _building_geo_batch[chunk_key]
	var parent: Node3D = batch.get("parent")

	if not parent or not is_instance_valid(parent):
		_building_geo_batch.erase(chunk_key)
		return

	# Shadow LOD — начальное значение ON; _update_building_shadows переключает по расстоянию каждые 0.5с
	var shadow_setting: int = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Incremental: track which surface to process next
	var step: int = batch.get("_finalize_step", 0)
	# Steps: 0-2=walls, 3=roofs, 4=parapets, 5-8=foundations, 9=cleanup
	var surface_keys: Array[String] = ["panel_walls", "brick_walls", "wall_walls", "roofs", "parapets", "foundation_0", "foundation_1", "foundation_2", "foundation_3"]

	if step < 9:
		var surface_key: String = surface_keys[step]
		var geo: Dictionary = batch[surface_key]
		if geo["vertices"].size() > 0:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = geo["vertices"]
			arrays[Mesh.ARRAY_TEX_UV] = geo["uvs"]
			arrays[Mesh.ARRAY_NORMAL] = geo["normals"]
			arrays[Mesh.ARRAY_INDEX] = geo["indices"]

			var arr_mesh := ArrayMesh.new()
			arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

			var material: Material
			if step < 3:
				var tex_type: String = surface_key.replace("_walls", "")
				material = _building_wall_materials[tex_type]
			elif step == 3:
				material = _building_roof_material
			elif step == 4:
				material = _building_parapet_material
			else:
				material = _building_foundation_materials[step - 5]

			var rid := _rs_add_mesh(chunk_key, arr_mesh, material,
				shadow_setting, render_distance)
			if not _chunk_building_rs.has(chunk_key):
				_chunk_building_rs[chunk_key] = []
			_chunk_building_rs[chunk_key].append(rid)

			if _draw_call_logging_enabled:
				_draw_call_stats["buildings"] += 1

		# Skip empty surfaces — advance to next non-empty or cleanup
		step += 1
		while step < 9:
			var next_geo: Dictionary = batch[surface_keys[step]]
			if next_geo["vertices"].size() > 0:
				break
			step += 1

		batch["_finalize_step"] = step
		if step < 9:
			if not _building_geo_finalize_queue.has(chunk_key):
				_building_geo_finalize_queue.push_front(chunk_key)
			return

	# === Step 9: Cleanup — collisions, building ranges, erase batch ===
	var all_baked: bool = batch.get("_all_baked", false)

	if not batch["collisions"].is_empty():
		_deferred_building_collisions.append({
			"parent": parent,
			"collisions": batch["collisions"],
			"idx": 0
		})

	if not all_baked:
		parent.set_meta("_building_ranges", batch["_building_ranges"])

	_building_geo_batch.erase(chunk_key)


## Обрабатывает готовые результаты из worker threads (вызывается из _process)
func _process_building_results() -> void:
	var t0 := Time.get_ticks_usec()
	_building_mutex.lock()
	if _building_results.is_empty():
		_building_mutex.unlock()
		return

	var results_to_process := _building_results.duplicate()
	_building_results.clear()
	_building_mutex.unlock()

	# Filter out invalid results to prevent processing empty/invalid buildings
	var valid_results: Array = []
	for result in results_to_process:
		if result.get("valid", false):
			valid_results.append(result)

	if valid_results.is_empty():
		return  # Nothing valid to process

	# Сортируем здания по близости к игроку (если много в очереди)
	if valid_results.size() > 10 and _car:
		var t_sort := Time.get_ticks_usec()
		_sort_building_results_by_distance(valid_results, _car.global_position)
		_record_perf("building_sort", Time.get_ticks_usec() - t_sort)

	# Применяем здания с бюджетом 2ms (было 1 за кадр — слишком медленно для 266 зданий)
	const BUILDING_APPLY_BUDGET_USEC := 2000
	var apply_start := Time.get_ticks_usec()
	var applied := 0
	for i in range(valid_results.size()):
		_apply_building_mesh_result(valid_results[i])
		applied += 1
		if applied > 1 and (Time.get_ticks_usec() - apply_start) > BUILDING_APPLY_BUDGET_USEC:
			break
	_record_perf("building_apply", Time.get_ticks_usec() - apply_start)

	# Возвращаем оставшиеся обратно в очередь
	if applied < valid_results.size():
		_building_mutex.lock()
		for i in range(applied, valid_results.size()):
			_building_results.append(valid_results[i])
		_building_mutex.unlock()


## Создаёт debug label для отображения статистики
func _create_debug_label() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	_debug_label = Label.new()
	_debug_label.position = Vector2(10, 100)
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.add_theme_color_override("font_color", Color.WHITE)
	_debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_debug_label)


## Обновляет debug статистику на экране
func _update_debug_stats(delta: float) -> void:
	if not show_debug_stats or not _debug_label:
		return

	# Собираем FPS samples
	var fps := 1.0 / delta if delta > 0 else 0.0
	_fps_samples.append(fps)
	if _fps_samples.size() > 120:  # Храним 2 секунды при 60 FPS
		_fps_samples.remove_at(0)

	# Обновляем label каждые 0.25 сек
	_fps_update_timer += delta
	if _fps_update_timer < 0.25:
		return
	_fps_update_timer = 0.0

	# Вычисляем статистику
	var sorted_fps := _fps_samples.duplicate()
	sorted_fps.sort()
	var avg_fps := 0.0
	for f in _fps_samples:
		avg_fps += f
	avg_fps /= max(1, _fps_samples.size())

	var min_fps: float = sorted_fps[0] if sorted_fps.size() > 0 else 0.0
	var p1_idx := int(sorted_fps.size() * 0.01)
	var fps_1pct: float = sorted_fps[p1_idx] if p1_idx < sorted_fps.size() else 0.0

	# CPU/GPU render time
	if not _viewport_rid.is_valid():
		_viewport_rid = get_viewport().get_viewport_rid()
	var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
	var render_gpu := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)

	# Godot process + physics
	var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0

	# Render stats
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var vertices := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var vertices_str := "%.1fM" % (vertices / 1_000_000.0) if vertices >= 1_000_000 else "%.0fK" % (vertices / 1000.0)

	# Frame time
	var frame_ms := 1000.0 / fps if fps > 0 else 0.0

	# Physics stats
	var phys_bodies := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var phys_pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

	# Размеры очередей
	var road_q := _road_queue.size()
	var terrain_q := _terrain_objects_queue.size()
	var infra_q := _infrastructure_queue.size()
	var building_q := _building_results.size()
	var curb_q := _curb_queue.size() + _curb_smoothed_queue.size()

	# Определяем bottleneck (GPU timing на macOS/Metal может возвращать 0)
	var bottleneck: String
	if render_gpu < 0.01 and render_cpu < 0.01:
		bottleneck = "N/A"
	elif render_cpu > render_gpu:
		bottleneck = "CPU"
	else:
		bottleneck = "GPU"

	# Собираем per-function breakdown из скользящего окна
	var func_lines := ""
	# Порядок функций для отображения (от самых тяжёлых)
	var func_order: Array[String] = [
		"building_results", "road_queue", "terrain_queue",
		"infra_queue", "vegetation_queue", "veg_results_apply",
		"curb_collisions", "terrain_gen", "chunk_culling", "total_frame"
	]
	var short_names: Dictionary = {
		"building_results": "bld",
		"road_queue": "road",
		"terrain_queue": "ter",
		"infra_queue": "inf",
		"vegetation_queue": "veg",
		"veg_results_apply": "veg_ap",
		"curb_collisions": "curb",
		"terrain_gen": "tgen",
		"chunk_culling": "cull",
		"total_frame": "TOTAL"
	}
	for fn in func_order:
		if not _perf_window.has(fn):
			continue
		var win: Array = _perf_window[fn]
		if win.is_empty():
			continue
		var w_avg := 0.0
		var w_max := 0.0
		for v in win:
			w_avg += v
			if v > w_max:
				w_max = v
		w_avg /= win.size()
		if fn == "total_frame":
			func_lines += "\n  %s: %.1f/%.1f" % [short_names[fn], w_avg, w_max]
		elif w_avg >= 0.05 or w_max >= 0.5:  # Показываем если avg > 0.05ms или max > 0.5ms
			func_lines += " %s:%.1f/%.1f" % [short_names[fn], w_avg, w_max]

	var tgen_q := _pending_terrain_tasks

	# Название текущей камеры
	var cam_name := ""
	var vp := get_viewport()
	if vp:
		var cam := vp.get_camera_3d()
		if cam:
			cam_name = cam.name

	_debug_label.text = "FPS: %.0f (avg:%.0f 1%%:%.0f min:%.0f) | Cam: %s\nFrame: %.1fms [%s] CPU:%.1f GPU:%.1f\nProcess: %.1fms | Physics: %.1fms\nDraw: %d | Verts: %s | VRAM: %.0fMB\nBodies: %d | Pairs: %d | Nodes: %d\nQueues: R:%d T:%d I:%d B:%d C:%d TG:%d | Chunks: %d\n_process avg/max (ms):%s" % [
		fps, avg_fps, fps_1pct, min_fps, cam_name,
		frame_ms, bottleneck, render_cpu, render_gpu,
		process_ms, physics_ms,
		draw_calls, vertices_str, vram,
		phys_bodies, phys_pairs, nodes,
		road_q, terrain_q, infra_q, building_q, curb_q, tgen_q, _loaded_chunks.size(),
		func_lines
	]


## Обрабатывает очередь дорог (3 дороги за кадр)
func _process_road_queue() -> void:
	var queue_start := Time.get_ticks_usec()
	const TOTAL_BUDGET_USEC := 4000  # 4ms total budget for entire function

	# Phase 0: Apply ready road results from worker threads (main thread, time-budgeted)
	_road_mutex.lock()
	var n_ready := _road_results.size()
	_road_mutex.unlock()

	var applied := 0
	while applied < n_ready:
		_road_mutex.lock()
		if _road_results.is_empty():
			_road_mutex.unlock()
			break
		var result: Dictionary = _road_results.pop_front()
		_road_mutex.unlock()
		_apply_road_result(result)
		applied += 1
		if (Time.get_ticks_usec() - queue_start) > 2000:
			break
	_record_perf("road_apply", Time.get_ticks_usec() - queue_start)

	# Process deferred footway splitting incrementally (N points per frame, budget 2.5ms)
	var fw_budget_end := queue_start + 2500
	while not _deferred_footway_queue.is_empty():
		if Time.get_ticks_usec() > fw_budget_end:
			break
		var fw_item: Dictionary = _deferred_footway_queue[0]
		if not is_instance_valid(fw_item.parent):
			_deferred_footway_queue.pop_front()
			continue
		var done := _process_footway_incremental(fw_item, fw_budget_end)
		if done:
			_deferred_footway_queue.pop_front()

	# Process deferred lamp/manhole generation with time budget
	while not _deferred_lamp_queue.is_empty():
		if (Time.get_ticks_usec() - queue_start) > 3000:
			break
		var item: Dictionary = _deferred_lamp_queue[0]
		# Проверяем что parent (чанк) ещё существует — мог быть выгружен
		if not is_instance_valid(item.parent):
			_deferred_lamp_queue.pop_front()
			continue
		# Process incrementally — only process a portion of the road per frame
		var start_idx: int = item.get("_lamp_seg_idx", 0)
		var processed: int = _generate_street_lamps_incremental(item.points, item.width, item.parent, start_idx, queue_start, 3000)
		if processed >= item.points.size() - 1:
			_deferred_lamp_queue.pop_front()  # Fully processed
		else:
			item["_lamp_seg_idx"] = processed  # Resume next frame
	while not _deferred_manhole_queue.is_empty():
		if (Time.get_ticks_usec() - queue_start) > 3000:
			break
		var item: Dictionary = _deferred_manhole_queue[0]
		if not is_instance_valid(item.parent):
			_deferred_manhole_queue.pop_front()
			continue
		_deferred_manhole_queue.pop_front()
		_generate_manholes_fast(item.points, item.width, item.parent)
	while not _deferred_traffic_queue.is_empty():
		if (Time.get_ticks_usec() - queue_start) > 3500:
			break
		var item: Dictionary = _deferred_traffic_queue.pop_front()
		_extract_road_for_traffic_fast(item.points, item.tags, item.elevation_info)

	# Process deferred billboard creation with time budget
	while not _deferred_billboard_queue.is_empty():
		if (Time.get_ticks_usec() - queue_start) > 4000:
			break
		var item: Dictionary = _deferred_billboard_queue.pop_front()
		if not is_instance_valid(item.parent):
			continue
		var billboard_mesh: Node3D = _decoration_layer.create_billboard_mesh(item.billboard, item.elevation)
		_budgeted_add_child(item.parent, billboard_mesh)

	if _road_queue.is_empty() and _pending_road_tasks <= 0:
		# Check if there are still unapplied results or deferred work
		_road_mutex.lock()
		var has_pending := not _road_results.is_empty()
		_road_mutex.unlock()
		if has_pending or not _deferred_lamp_queue.is_empty() or not _deferred_manhole_queue.is_empty() or not _deferred_traffic_queue.is_empty() or not _deferred_footway_queue.is_empty() or not _deferred_billboard_queue.is_empty():
			return  # Wait for results/deferred to be processed first

		# Budget gate: skip finalization if deferred work already consumed >3ms
		if (Time.get_ticks_usec() - queue_start) > 3000:
			return

		# Round-robin: ONE finalization type per frame, ONE chunk per type
		# This prevents Godot scene tree from processing too many new nodes at once
		var did_work := false
		var phases_checked := 0
		while not did_work and phases_checked < 8:
			phases_checked += 1
			match _finalize_phase:
				0:  # Roads (1 chunk)
					_finalize_phase = 1
					if not _pending_batch_chunks.is_empty():
						var t_batch := Time.get_ticks_usec()
						var chunk_key: String = _pending_batch_chunks.pop_front()
						_finalize_road_batches_for_chunk(chunk_key)
						_record_perf("fin_roads", Time.get_ticks_usec() - t_batch)
						did_work = true

				1:  # Curbs
					_finalize_phase = 2
					if not _curb_queue.is_empty() or not _curb_smoothed_queue.is_empty() or not _curb_mesh_state.is_empty() or not _curb_geo_batch.is_empty():
						var t_curb_fin := Time.get_ticks_usec()
						_process_curb_queue()
						_record_perf("fin_curbs", Time.get_ticks_usec() - t_curb_fin)
						did_work = true

				2:  # Lamps (1 chunk)
					_finalize_phase = 3
					if not _lamp_batches_to_finalize.is_empty():
						var t_lamp := Time.get_ticks_usec()
						var chunk_key: String = _lamp_batches_to_finalize[0]
						_lamp_batches_to_finalize.remove_at(0)
						_finalize_lamp_batches_for_chunk(chunk_key)
						_record_perf("fin_lamps", Time.get_ticks_usec() - t_lamp)
						did_work = true

				3:  # Buildings (1 surface per frame, incremental)
					_finalize_phase = 4
					if _pending_building_tasks <= 0 and _building_results.is_empty():
						# Enqueue building geo batches
						if not _building_geo_batch.is_empty():
							for key in _building_geo_batch.keys():
								if not _building_geo_finalize_queue.has(key):
									_building_geo_finalize_queue.append(key)

						if not _building_geo_finalize_queue.is_empty():
							var t_geo := Time.get_ticks_usec()
							var chunk_key: String = _building_geo_finalize_queue[0]
							_building_geo_finalize_queue.remove_at(0)
							_finalize_building_geo_batch(chunk_key)
							_record_perf("fin_buildings", Time.get_ticks_usec() - t_geo)
							# Entrance/windows only after ALL building surfaces done
							if not _building_geo_batch.has(chunk_key):
								_finalize_entrance_batch(chunk_key)
								if _window_batch_data.has(chunk_key):
									_finalize_window_batches_for_chunk(chunk_key)
							did_work = true
						elif not _entrance_batch.is_empty():
							var ent_key: String = _entrance_batch.keys()[0]
							_finalize_entrance_batch(ent_key)
							did_work = true
						else:
							# Enqueue remaining windows (chunks without buildings in queue)
							var window_chunks := _window_batch_data.keys()
							for chunk_key in window_chunks:
								_finalize_window_batches_for_chunk(chunk_key)

				4:  # Windows (progressive fill, time-budgeted)
					_finalize_phase = 5
					if not _window_finalize_queue.is_empty():
						var t_window := Time.get_ticks_usec()
						var budget_end: int = t_window + 2000  # 2ms budget
						_progress_window_finalize(budget_end)
						_record_perf("fin_windows", Time.get_ticks_usec() - t_window)
						did_work = true

				5:  # Trees (1 chunk)
					_finalize_phase = 6
					if not _tree_batches_to_finalize.is_empty():
						var t_tree := Time.get_ticks_usec()
						var chunk_key: String = _tree_batches_to_finalize[0]
						_tree_batches_to_finalize.remove_at(0)
						_finalize_tree_batches_for_chunk(chunk_key)
						_record_perf("fin_trees", Time.get_ticks_usec() - t_tree)
						did_work = true

				6:  # Billboards (1 chunk)
					_finalize_phase = 7
					if not _billboard_batches_to_finalize.is_empty():
						var t_bill := Time.get_ticks_usec()
						var chunk_key: String = _billboard_batches_to_finalize[0]
						_billboard_batches_to_finalize.remove_at(0)
						_finalize_billboard_batch_for_chunk(chunk_key)
						_record_perf("fin_billboards", Time.get_ticks_usec() - t_bill)
						did_work = true

				7:  # Fences (1 chunk)
					_finalize_phase = 0
					if not _fence_batches_to_finalize.is_empty():
						var t_fence := Time.get_ticks_usec()
						var chunk_key: String = _fence_batches_to_finalize[0]
						_fence_batches_to_finalize.remove_at(0)
						_finalize_fence_batches_for_chunk(chunk_key)
						_record_perf("fin_fences", Time.get_ticks_usec() - t_fence)
						did_work = true

		return

	# Dispatch roads to worker threads — no time budget needed on main thread!
	# Limit concurrent tasks to avoid overwhelming thread pool
	const MAX_CONCURRENT_ROAD_TASKS := 8
	var dispatched := 0

	# Ensure lon_scale is initialized
	if _lon_scale == 0.0:
		_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0

	while not _road_queue.is_empty() and _pending_road_tasks < MAX_CONCURRENT_ROAD_TASKS:
		var item: Dictionary = _road_queue.pop_front()
		if not is_instance_valid(item.get("parent")):
			continue

		var parent: Node3D = item.parent
		var chunk_key := ""
		if parent.name.begins_with("Chunk_"):
			chunk_key = parent.name.substr(6)
		else:
			chunk_key = "initial"

		var task_data := {
			"nodes": item.nodes,
			"tags": item.tags,
			"parent": parent,
			"chunk_key": chunk_key,
			"chunk_size": chunk_size,
			"start_lat": start_lat,
			"start_lon": start_lon,
			"lon_scale": _lon_scale,
			"way_id": item.get("way_id", 0)
		}
		_pending_road_tasks += 1
		WorkerThreadPool.add_task(_compute_road_geometry_thread.bind(task_data))
		dispatched += 1


## Обрабатывает очередь бордюров (после того как все перекрёстки определены)
func _process_curb_queue() -> void:
	# Этап 1: Сглаживание точек — time-budgeted 2ms
	const CURB_SMOOTH_BUDGET_USEC := 2000
	var curb_smooth_start := Time.get_ticks_usec()
	var smoothed_count := 0
	while not _curb_queue.is_empty():
		if smoothed_count > 0 and (Time.get_ticks_usec() - curb_smooth_start) > CURB_SMOOTH_BUDGET_USEC:
			break
		var item: Dictionary = _curb_queue.pop_front()
		if is_instance_valid(item.parent) and item.local_points.size() >= 2:
			# Точки уже в локальных координатах — пропускаем latlon конвертацию
			# Сглаживание тоже не нужно: дорога и бордюр используют одни и те же raw points,
			# а сглаживание дороги происходит в _add_road_to_batch_fast
			var points: PackedVector2Array = item.local_points

			# Клиппинг по chunk bbox (OSM данные загружаются с +100м overlap →
			# без клиппинга один бордюр создаётся в нескольких чанках)
			var ck := _get_chunk_key_from_node(item.parent)
			if ck != "":
				var ck_parts: PackedStringArray = ck.split(",")
				var ck_x := int(ck_parts[0])
				var ck_z := int(ck_parts[1])
				var margin: float = item.width + 5.0
				var clip_min_x: float = float(ck_x) * chunk_size - margin
				var clip_max_x: float = float(ck_x + 1) * chunk_size + margin
				var clip_min_z: float = float(ck_z) * chunk_size - margin
				var clip_max_z: float = float(ck_z + 1) * chunk_size + margin
				points = _clip_polyline_to_rect(points, clip_min_x, clip_max_x, clip_min_z, clip_max_z)
				if points.size() < 2:
					continue

			# Добавляем в очередь для генерации меша
			_curb_smoothed_queue.append({
				"points": points,
				"width": item.width,
				"height_offset": item.height_offset,
				"curb_height": item.curb_height,
				"parent": item.parent
			})
			smoothed_count += 1

	# Этап 2: Инкрементальная генерация меша — до 200 сегментов за кадр
	var t0 := Time.get_ticks_usec()
	_process_curb_mesh_incremental(200)
	_record_perf("curb_mesh", Time.get_ticks_usec() - t0)

	# Этап 3: Финализация merged mesh когда все бордюры обработаны
	if _curb_queue.is_empty() and _curb_smoothed_queue.is_empty() and _curb_mesh_state.is_empty():
		if not _curb_geo_batch.is_empty():
			var keys := _curb_geo_batch.keys()
			for key in keys:
				_finalize_curb_geo_batch(key)


## Инкрементальная генерация меша бордюра
func _process_curb_mesh_incremental(max_segments: int) -> void:
	var segments_processed := 0

	while segments_processed < max_segments:
		# Если нет активного состояния, берём следующий бордюр из очереди
		if _curb_mesh_state.is_empty():
			if _curb_smoothed_queue.is_empty():
				return
			var item: Dictionary = _curb_smoothed_queue.pop_front()
			if not is_instance_valid(item.parent):
				continue
			_init_curb_mesh_state(item)

		# Обрабатываем сегменты
		var remaining := max_segments - segments_processed
		var processed := _process_curb_segments(remaining)
		segments_processed += processed

		# Если бордюр завершён, финализируем меш
		if _curb_mesh_state.current_idx >= _curb_mesh_state.points.size() - 1:
			_finalize_curb_mesh()
			_curb_mesh_state.clear()


## Инициализирует состояние для генерации меша бордюра
func _init_curb_mesh_state(item: Dictionary) -> void:
	var points: PackedVector2Array = item.points
	var road_width: float = item.width
	var curb_height: float = item.curb_height

	var curb_width := 0.15
	var hash_val := int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset := hash_val * 0.00003  # Совпадает с z_offset дороги

	# Предварительно вычисляем валидные сегменты (не в контурах перекрёстков)
	var valid_segments: Array[int] = []
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var offset := perp * (road_width * 0.5)
		var left1 := p1 + offset
		var left2 := p2 + offset
		var right1 := p1 - offset
		var right2 := p2 - offset
		if _is_point_in_intersection_shape(left1, true) < 0 and \
		   _is_point_in_intersection_shape(left2, true) < 0 and \
		   _is_point_in_intersection_shape(right1, true) < 0 and \
		   _is_point_in_intersection_shape(right2, true) < 0:
			valid_segments.append(i)

	# Разбиваем на группы непрерывных сегментов
	var groups: Array[Array] = []
	var current_group: Array[int] = []
	for seg_idx in valid_segments:
		if current_group.is_empty() or current_group[current_group.size() - 1] == seg_idx - 1:
			current_group.append(seg_idx)
		else:
			if not current_group.is_empty():
				groups.append(current_group.duplicate())
			current_group = [seg_idx]
	if not current_group.is_empty():
		groups.append(current_group)

	_curb_mesh_state = {
		"points": points,
		"road_width": road_width,
		"road_height": item.height_offset,
		"curb_height": curb_height,
		"curb_width": curb_width,
		"z_offset": z_offset,
		"parent": item.parent,
		"groups": groups,
		"current_group_idx": 0,
		"current_idx_in_group": 0,
		"current_idx": 0,
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"indices": PackedInt32Array()
	}


## Обрабатывает сегменты бордюра
func _process_curb_segments(max_count: int) -> int:
	var state := _curb_mesh_state
	var processed := 0
	var points: PackedVector2Array = state.points
	var groups: Array = state.groups
	var road_width: float = state.road_width
	var road_height: float = state.road_height
	var curb_height: float = state.curb_height
	var curb_width: float = state.curb_width
	var z_offset: float = state.z_offset
	var vertices: PackedVector3Array = state.vertices
	var normals: PackedVector3Array = state.normals
	var indices: PackedInt32Array = state.indices

	while processed < max_count and state.current_group_idx < groups.size():
		var group: Array = groups[state.current_group_idx]
		if state.current_idx_in_group >= group.size():
			state.current_group_idx += 1
			state.current_idx_in_group = 0
			continue

		var g_idx: int = state.current_idx_in_group
		var i: int = group[g_idx]
		var is_first := (g_idx == 0)
		var is_last := (g_idx == group.size() - 1)

		var p1 := points[i]
		var p2 := points[i + 1]
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)

		# Elevation в центре и на краях — как дорога использует maxf(edge, center)
		var h_center1 := 0.0
		var h_center2 := 0.0

		var left_inner1 := p1 + perp * (road_width * 0.5)
		var left_outer1 := p1 + perp * (road_width * 0.5 + curb_width)
		var left_inner2 := p2 + perp * (road_width * 0.5)
		var left_outer2 := p2 + perp * (road_width * 0.5 + curb_width)
		var right_inner1 := p1 - perp * (road_width * 0.5)
		var right_outer1 := p1 - perp * (road_width * 0.5 + curb_width)
		var right_inner2 := p2 - perp * (road_width * 0.5)
		var right_outer2 := p2 - perp * (road_width * 0.5 + curb_width)

		# Высота края дороги = max(elevation_edge, elevation_center) — повторяет логику дороги
		var h_left1 := maxf(0.0, h_center1)
		var h_left2 := maxf(0.0, h_center2)
		var h_right1 := maxf(0.0, h_center1)
		var h_right2 := maxf(0.0, h_center2)

		# Высоты для левого бордюра
		var left_road_y1 := h_left1 + road_height + z_offset
		var left_road_y2 := h_left2 + road_height + z_offset
		var left_curb_y1 := h_left1 + road_height + curb_height + z_offset
		var left_curb_y2 := h_left2 + road_height + curb_height + z_offset
		var left_bottom_y1 := left_curb_y1 - 1.0
		var left_bottom_y2 := left_curb_y2 - 1.0

		# Высоты для правого бордюра
		var right_road_y1 := h_right1 + road_height + z_offset
		var right_road_y2 := h_right2 + road_height + z_offset
		var right_curb_y1 := h_right1 + road_height + curb_height + z_offset
		var right_curb_y2 := h_right2 + road_height + curb_height + z_offset
		var right_bottom_y1 := right_curb_y1 - 1.0
		var right_bottom_y2 := right_curb_y2 - 1.0

		var idx := vertices.size()
		var norm_left_in := Vector3(-perp.x, 0, -perp.y)
		var norm_left_out := Vector3(perp.x, 0, perp.y)
		var norm_right_in := Vector3(perp.x, 0, perp.y)
		var norm_right_out := Vector3(-perp.x, 0, -perp.y)
		var norm_fwd := Vector3(dir.x, 0, dir.y)
		var norm_back := Vector3(-dir.x, 0, -dir.y)

		# === ЛЕВЫЙ БОРДЮР ===

		# Внутренняя стенка (от уровня дороги до верха бордюра)
		vertices.append(Vector3(left_inner1.x, left_road_y1, left_inner1.y))
		vertices.append(Vector3(left_inner2.x, left_road_y2, left_inner2.y))
		vertices.append(Vector3(left_inner2.x, left_curb_y2, left_inner2.y))
		vertices.append(Vector3(left_inner1.x, left_curb_y1, left_inner1.y))
		for _j in 4: normals.append(norm_left_in)
		indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
		idx = vertices.size()

		# Верхняя грань
		vertices.append(Vector3(left_inner1.x, left_curb_y1, left_inner1.y))
		vertices.append(Vector3(left_inner2.x, left_curb_y2, left_inner2.y))
		vertices.append(Vector3(left_outer2.x, left_curb_y2, left_outer2.y))
		vertices.append(Vector3(left_outer1.x, left_curb_y1, left_outer1.y))
		for _j in 4: normals.append(Vector3.UP)
		indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
		idx = vertices.size()

		# Наружная стенка (1м вниз от верха — уходит под землю)
		vertices.append(Vector3(left_outer1.x, left_bottom_y1, left_outer1.y))
		vertices.append(Vector3(left_outer2.x, left_bottom_y2, left_outer2.y))
		vertices.append(Vector3(left_outer2.x, left_curb_y2, left_outer2.y))
		vertices.append(Vector3(left_outer1.x, left_curb_y1, left_outer1.y))
		for _j in 4: normals.append(norm_left_out)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
		indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
		idx = vertices.size()

		# Торцы левого бордюра
		if is_first:
			vertices.append(Vector3(left_inner1.x, left_road_y1, left_inner1.y))
			vertices.append(Vector3(left_outer1.x, left_bottom_y1, left_outer1.y))
			vertices.append(Vector3(left_outer1.x, left_curb_y1, left_outer1.y))
			vertices.append(Vector3(left_inner1.x, left_curb_y1, left_inner1.y))
			for _j in 4: normals.append(norm_back)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
			idx = vertices.size()
		if is_last:
			vertices.append(Vector3(left_inner2.x, left_road_y2, left_inner2.y))
			vertices.append(Vector3(left_outer2.x, left_bottom_y2, left_outer2.y))
			vertices.append(Vector3(left_outer2.x, left_curb_y2, left_outer2.y))
			vertices.append(Vector3(left_inner2.x, left_curb_y2, left_inner2.y))
			for _j in 4: normals.append(norm_fwd)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
			idx = vertices.size()

		# === ПРАВЫЙ БОРДЮР ===

		# Внутренняя стенка (от уровня дороги до верха бордюра)
		vertices.append(Vector3(right_inner1.x, right_road_y1, right_inner1.y))
		vertices.append(Vector3(right_inner2.x, right_road_y2, right_inner2.y))
		vertices.append(Vector3(right_inner2.x, right_curb_y2, right_inner2.y))
		vertices.append(Vector3(right_inner1.x, right_curb_y1, right_inner1.y))
		for _j in 4: normals.append(norm_right_in)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
		indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
		idx = vertices.size()

		# Верхняя грань
		vertices.append(Vector3(right_inner1.x, right_curb_y1, right_inner1.y))
		vertices.append(Vector3(right_inner2.x, right_curb_y2, right_inner2.y))
		vertices.append(Vector3(right_outer2.x, right_curb_y2, right_outer2.y))
		vertices.append(Vector3(right_outer1.x, right_curb_y1, right_outer1.y))
		for _j in 4: normals.append(Vector3.UP)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
		indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
		idx = vertices.size()

		# Наружная стенка (1м вниз от верха — уходит под землю)
		vertices.append(Vector3(right_outer1.x, right_bottom_y1, right_outer1.y))
		vertices.append(Vector3(right_outer2.x, right_bottom_y2, right_outer2.y))
		vertices.append(Vector3(right_outer2.x, right_curb_y2, right_outer2.y))
		vertices.append(Vector3(right_outer1.x, right_curb_y1, right_outer1.y))
		for _j in 4: normals.append(norm_right_out)
		indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
		idx = vertices.size()

		# Торцы правого бордюра
		if is_first:
			vertices.append(Vector3(right_inner1.x, right_road_y1, right_inner1.y))
			vertices.append(Vector3(right_outer1.x, right_bottom_y1, right_outer1.y))
			vertices.append(Vector3(right_outer1.x, right_curb_y1, right_outer1.y))
			vertices.append(Vector3(right_inner1.x, right_curb_y1, right_inner1.y))
			for _j in 4: normals.append(norm_back)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
			idx = vertices.size()
		if is_last:
			vertices.append(Vector3(right_inner2.x, right_road_y2, right_inner2.y))
			vertices.append(Vector3(right_outer2.x, right_bottom_y2, right_outer2.y))
			vertices.append(Vector3(right_outer2.x, right_curb_y2, right_outer2.y))
			vertices.append(Vector3(right_inner2.x, right_curb_y2, right_inner2.y))
			for _j in 4: normals.append(norm_fwd)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)

		state.current_idx_in_group += 1
		state.current_idx = i + 1
		processed += 1

	# Если все группы обработаны, помечаем завершение
	if state.current_group_idx >= groups.size():
		state.current_idx = points.size()

	return processed


## Накапливает геометрию бордюра в batch для merged mesh на чанк
func _finalize_curb_mesh() -> void:
	var state := _curb_mesh_state
	if not state or not is_instance_valid(state.get("parent")):
		return

	var vertices: PackedVector3Array = state.vertices
	var normals: PackedVector3Array = state.normals
	var indices: PackedInt32Array = state.indices
	var parent: Node3D = state.parent

	if vertices.size() == 0:
		return

	# Накапливаем геометрию в batch по chunk_key
	var chunk_key := _get_chunk_key_from_node(parent)
	if chunk_key.is_empty():
		chunk_key = parent.name

	if not _curb_geo_batch.has(chunk_key):
		_curb_geo_batch[chunk_key] = {
			"parent": parent,
			"vertices": PackedVector3Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array()
		}

	var batch: Dictionary = _curb_geo_batch[chunk_key]
	var base_idx: int = batch["vertices"].size()

	batch["vertices"].append_array(vertices)
	batch["normals"].append_array(normals)

	# Сдвигаем индексы на base_idx
	for idx in indices:
		batch["indices"].append(idx + base_idx)

	# Запускаем расчёт коллизий в worker thread
	var collision_task := {
		"points": state.points,
		"groups": state.groups,
		"road_width": state.road_width,
		"road_height": state.road_height,
		"curb_height": state.curb_height,
		"curb_width": state.curb_width,
		"z_offset": state.z_offset,
		"parent": parent
	}
	WorkerThreadPool.add_task(_compute_curb_collisions_thread.bind(collision_task))


## Финализирует merged mesh бордюров для чанка
func _finalize_curb_geo_batch(chunk_key: String) -> void:
	if not _curb_geo_batch.has(chunk_key):
		return
	var batch: Dictionary = _curb_geo_batch[chunk_key]
	var parent: Node3D = batch["parent"]

	if not is_instance_valid(parent) or batch["vertices"].size() == 0:
		_curb_geo_batch.erase(chunk_key)
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = batch["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = batch["normals"]
	arrays[Mesh.ARRAY_INDEX] = batch["indices"]

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	if _draw_call_logging_enabled:
		_draw_call_stats["curbs"] += 1

	_rs_add_mesh(chunk_key, arr_mesh, _curb_material)
	_curb_geo_batch.erase(chunk_key)


## Сортирует очередь по расстоянию до игрока (ближайшие первые)
func _sort_queue_by_distance(queue: Array, player_pos: Vector3) -> void:
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Вычисляем расстояние для каждого элемента
	for item in queue:
		var first_node = item.nodes[0] if item.nodes.size() > 0 else null
		if first_node:
			var pos_2d := _latlon_to_local(first_node.lat, first_node.lon)
			item["_dist"] = pos_2d.distance_squared_to(player_pos_2d)
		else:
			item["_dist"] = 999999.0

	# Сортируем по расстоянию
	queue.sort_custom(func(a, b): return a.get("_dist", 999999.0) < b.get("_dist", 999999.0))


## Сортирует очередь инфраструктуры по расстоянию до игрока
func _sort_infrastructure_by_distance(queue: Array, player_pos: Vector3) -> void:
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Вычисляем расстояние для каждого элемента
	for item in queue:
		var pos = item.get("pos")
		if pos is Vector2:
			item["_dist"] = pos.distance_squared_to(player_pos_2d)
		else:
			item["_dist"] = 999999.0

	# Сортируем по расстоянию
	queue.sort_custom(func(a, b): return a.get("_dist", 999999.0) < b.get("_dist", 999999.0))


## Сортирует результаты зданий по расстоянию до игрока
func _sort_building_results_by_distance(results: Array, player_pos: Vector3) -> void:
	var player_pos_2d := Vector2(player_pos.x, player_pos.z)

	# Вычисляем расстояние для каждого здания
	for result in results:
		if not result.get("valid", false):
			result["_dist"] = 999999.0
			continue

		var points = result.get("points")
		if points is PackedVector2Array and points.size() > 0:
			# Вычисляем центр здания
			var center := Vector2.ZERO
			for p in points:
				center += p
			center /= points.size()
			result["_dist"] = center.distance_squared_to(player_pos_2d)
		else:
			result["_dist"] = 999999.0

	# Сортируем по расстоянию
	results.sort_custom(func(a, b): return a.get("_dist", 999999.0) < b.get("_dist", 999999.0))


## Обрабатывает очередь terrain объектов (с time budget)
func _process_terrain_objects_queue() -> void:
	if _terrain_objects_queue.is_empty():
		return

	# Сортируем по расстоянию до игрока
	if _terrain_objects_queue.size() > 20 and _car:
		var t0 := Time.get_ticks_usec()
		_sort_queue_by_distance(_terrain_objects_queue, _car.global_position)
		_record_perf("terrain_sort", Time.get_ticks_usec() - t0)

	# Time budget: максимум 2ms на terrain объекты, минимум 1 за кадр
	const TERRAIN_TIME_BUDGET_USEC := 2000
	var start_time := Time.get_ticks_usec()
	var processed := 0
	var deferred: Array = []

	while not _terrain_objects_queue.is_empty():
		# Проверяем бюджет ПОСЛЕ первого объекта
		if processed > 0 and (Time.get_ticks_usec() - start_time) > TERRAIN_TIME_BUDGET_USEC:
			break

		var item: Dictionary = _terrain_objects_queue.pop_front()

		# Проверяем что parent ещё существует
		if not is_instance_valid(item.get("parent")):
			continue

		var obj_type: String = item.get("type", "")
		var t0 := Time.get_ticks_usec()

		match obj_type:
			"natural":
				_create_natural_immediate(item.nodes, item.tags, item.parent)
				_record_perf("terrain_natural", Time.get_ticks_usec() - t0)
			"landuse":
				_create_landuse_immediate(item.nodes, item.tags, item.parent, item.get("way_id", 0))
				_record_perf("terrain_landuse", Time.get_ticks_usec() - t0)
			"leisure":
				_create_leisure_immediate(item.nodes, item.tags, item.parent)
				_record_perf("terrain_leisure", Time.get_ticks_usec() - t0)

		processed += 1

	# Возвращаем отложенные элементы обратно в начало очереди
	if not deferred.is_empty():
		for i in range(deferred.size() - 1, -1, -1):
			_terrain_objects_queue.push_front(deferred[i])


## Обрабатывает очередь инфраструктуры (1 объект за кадр)
func _process_infrastructure_queue() -> void:
	if _infrastructure_queue.is_empty():
		return

	# Сортируем по расстоянию до игрока
	if _infrastructure_queue.size() > 20 and _car:
		var t0 := Time.get_ticks_usec()
		_sort_infrastructure_by_distance(_infrastructure_queue, _car.global_position)
		_record_perf("infra_sort", Time.get_ticks_usec() - t0)

	# Time budget: до 2ms на инфраструктуру, минимум 1 за кадр
	const INFRA_TIME_BUDGET_USEC := 2000
	var start_time := Time.get_ticks_usec()
	var processed := 0

	while not _infrastructure_queue.is_empty():
		if processed > 0 and (Time.get_ticks_usec() - start_time) > INFRA_TIME_BUDGET_USEC:
			break

		var item: Dictionary = _infrastructure_queue.pop_front()
		var item_type: String = item.get("type", "")

		# Проверяем что parent ещё существует (мог быть удалён при reset_terrain)
		var parent = item.get("parent")
		if parent == null or not is_instance_valid(parent):
			continue

		var elevation := 0.0
		var t0 := Time.get_ticks_usec()

		match item_type:
			"lamp":
				_create_street_lamp_immediate(item.pos, elevation, item.parent, item.get("direction", Vector2.ZERO))
				_record_perf("infra_lamp", Time.get_ticks_usec() - t0)
			"traffic_light":
				_create_traffic_light_immediate(item.pos, elevation, item.parent)
				_record_perf("infra_traffic_light", Time.get_ticks_usec() - t0)
			"yield_sign":
				_create_yield_sign_immediate(item.pos, elevation, item.parent)
				_record_perf("infra_yield_sign", Time.get_ticks_usec() - t0)
			"parking_sign":
				_create_parking_sign_immediate(item.pos, elevation, item.rotation, item.parent)
				_record_perf("infra_parking_sign", Time.get_ticks_usec() - t0)
			"crossing_sign":
				_create_crossing_sign_immediate(item.pos, elevation, item.get("rotation", 0.0), item.parent)
				_record_perf("infra_crossing_sign", Time.get_ticks_usec() - t0)
		processed += 1


## Диспетчер растительности — отправляет задачи в воркер-треды
func _process_vegetation_queue() -> void:
	if _vegetation_queue.is_empty():
		return

		return

	const MAX_CONCURRENT_VEG_TASKS := 4

	while not _vegetation_queue.is_empty() and _pending_veg_tasks < MAX_CONCURRENT_VEG_TASKS:
		# Ищем первый элемент с финализированным elevation и готовыми дорогами/зданиями
		var item: Dictionary = {}
		var item_idx := -1
		for qi in range(_vegetation_queue.size()):
			var candidate: Dictionary = _vegetation_queue[qi]
			if not is_instance_valid(candidate.get("parent")):
				_vegetation_queue.remove_at(qi)
				break  # Удалили невалидный — попробуем следующий
			var ck: String = _get_chunk_key_from_node(candidate.get("parent"))
			if ck == "":
				ck = candidate.get("chunk_key", "")
			# Проверяем что дороги и здания для этого чанка финализированы
			if ck != "" and _road_batch_data.has(ck):
				continue  # Дороги ещё не финализированы
			if ck != "" and _building_geo_batch.has(ck):
				continue  # Здания ещё не финализированы
			item = candidate
			item_idx = qi
			break

		if item_idx < 0:
			break  # Все элементы ждут зависимостей

		_vegetation_queue.remove_at(item_idx)

		# Получаем chunk_key и elevation data
		var chunk_key: String = _get_chunk_key_from_node(item.get("parent"))
		if chunk_key == "":
			chunk_key = item.get("chunk_key", "")

		var veg_type: String = item.get("type", "")

		match veg_type:
			"trees":
				var task_data := {
					"points": item.points,
					"dense": item.dense,
					"chunk_key": chunk_key,
					"chunk_size": chunk_size,
					"road_spatial_hash": _road_spatial_hash,
					"parent": item.parent
				}
				_pending_veg_tasks += 1
				WorkerThreadPool.add_task(_compute_trees_thread.bind(task_data))
			"chunk_trees":
				var task_data := {
					"chunk_key": chunk_key,
					"chunk_size": chunk_size,
					"road_spatial_hash": _road_spatial_hash,
					"building_spatial_hash": _building_spatial_hash,
					"parking_spatial_hash": _parking_spatial_hash,
					"parking_polygons": _parking_polygons,
					"parent": item.parent
				}
				_pending_veg_tasks += 1
				WorkerThreadPool.add_task(_compute_chunk_trees_thread.bind(task_data))


## Применяет результаты из воркер-тредов деревьев (с бюджетом)
func _apply_veg_thread_results() -> void:
	_veg_mutex.lock()
	if _veg_thread_results.is_empty():
		_veg_mutex.unlock()
		return
	var results := _veg_thread_results.duplicate()
	_veg_thread_results.clear()
	_veg_mutex.unlock()

	const VEG_APPLY_BUDGET_USEC := 2000
	var apply_start := Time.get_ticks_usec()
	var applied := 0

	for result in results:
		var chunk_key: String = result.chunk_key
		var parent: Node3D = result.parent

		# Проверяем что чанк ещё загружен
		if not is_instance_valid(parent) or not _loaded_chunks.has(chunk_key):
			applied += 1
			continue

		# Мёржим в существующую систему батчей
		if not _tree_batch_data.has(chunk_key):
			_tree_batch_data[chunk_key] = {
				"leaf_transforms": [],
				"pine_transforms": [],
				"collisions": [],
				"parent": parent
			}

		var batch: Dictionary = _tree_batch_data[chunk_key]
		batch["leaf_transforms"].append_array(result.leaf_transforms)
		batch["pine_transforms"].append_array(result.pine_transforms)
		batch["collisions"].append_array(result.collisions)

		if not _tree_batches_to_finalize.has(chunk_key):
			_tree_batches_to_finalize.append(chunk_key)

		applied += 1
		if applied > 1 and (Time.get_ticks_usec() - apply_start) > VEG_APPLY_BUDGET_USEC:
			break

	# Возвращаем необработанные результаты обратно
	if applied < results.size():
		_veg_mutex.lock()
		for i in range(applied, results.size()):
			_veg_thread_results.append(results[i])
		_veg_mutex.unlock()


func _create_3d_building_with_texture(points: PackedVector2Array, building_height: float, texture_type: String, parent: Node3D, base_elev: float = 0.0, _debug_name: String = "") -> void:
	# Минимум 4 точки для нормального здания (3 - треугольник, плохо)
	if points.size() < 4:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Проверка на слишком маленькие или вырожденные здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var size_x := max_x - min_x
	var size_z := max_z - min_z

	# Пропускаем слишком маленькие здания (< 3м)
	if size_x < 3.0 or size_z < 3.0:
		return

	# Пропускаем слишком большие здания (возможно ошибка данных > 200м)
	if size_x > 200.0 or size_z > 200.0:
		return

	# Проверка на соотношение сторон (слишком вытянутые - вероятно ошибка)
	var min_size: float = min(size_x, size_z)
	if min_size < 0.1:
		return
	var aspect: float = max(size_x, size_z) / min_size
	if aspect > 20.0:
		return

	# Проверка на площадь (слишком маленькая площадь = плохие данные)
	var area: float = _calculate_polygon_area(points)
	if area < 10.0:  # Меньше 10 м²
		return

	# Высоты с учётом террейна
	var fnd_h := _get_foundation_height(points)
	var floor_y := base_elev + fnd_h
	var foundation_y := base_elev + fnd_h
	var roof_y := base_elev + building_height

	# === СТЕНЫ с ArrayMesh для UV ===
	var wall_arrays := []
	wall_arrays.resize(Mesh.ARRAY_MAX)

	var wall_vertices := PackedVector3Array()
	var wall_uvs := PackedVector2Array()
	var wall_normals := PackedVector3Array()
	var wall_indices := PackedInt32Array()

	var uv_scale_x := 0.1  # Масштаб UV по горизонтали (10м = 1 повтор текстуры)
	var uv_scale_y := 0.1  # Масштаб UV по вертикали

	# Определяем направление полигона для корректных нормалей
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	var accumulated_width := 0.0
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_width := p1.distance_to(p2)

		var v1 := Vector3(p1.x, foundation_y, p1.y)
		var v2 := Vector3(p2.x, foundation_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		# Нормаль стены (наружу) - учитываем направление обхода полигона
		var dir := (p2 - p1).normalized()
		var normal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)

		# UV: фундамент ниже 0 (уходит под землю), видимая часть от 0 до building_height
		var u1 := accumulated_width * uv_scale_x
		var u2 := (accumulated_width + wall_width) * uv_scale_x
		var v_bottom := 0.0
		var v_top := building_height * uv_scale_y

		var idx := wall_vertices.size()

		wall_vertices.append(v1)
		wall_vertices.append(v2)
		wall_vertices.append(v3)
		wall_vertices.append(v4)

		wall_uvs.append(Vector2(u1, v_bottom))
		wall_uvs.append(Vector2(u2, v_bottom))
		wall_uvs.append(Vector2(u2, v_top))
		wall_uvs.append(Vector2(u1, v_top))

		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)

		# Два треугольника для квадрата стены
		wall_indices.append(idx + 0)
		wall_indices.append(idx + 1)
		wall_indices.append(idx + 2)

		wall_indices.append(idx + 0)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 3)

		accumulated_width += wall_width

	wall_arrays[Mesh.ARRAY_VERTEX] = wall_vertices
	wall_arrays[Mesh.ARRAY_TEX_UV] = wall_uvs
	wall_arrays[Mesh.ARRAY_NORMAL] = wall_normals
	wall_arrays[Mesh.ARRAY_INDEX] = wall_indices

	var wall_mesh := ArrayMesh.new()
	wall_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wall_arrays)

	var wall_mesh_instance := MeshInstance3D.new()
	wall_mesh_instance.mesh = wall_mesh

	wall_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Visibility range для автоматического скрытия далёких зданий
	wall_mesh_instance.visibility_range_end = render_distance
	wall_mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	# Материал стен с шейдером для правильного двустороннего освещения
	var wall_material := ShaderMaterial.new()
	wall_material.shader = BuildingWallShader
	if _building_textures.has(texture_type):
		wall_material.set_shader_parameter("albedo_texture", _building_textures[texture_type])
		wall_material.set_shader_parameter("use_texture", true)
	else:
		wall_material.set_shader_parameter("albedo_color", Color(0.7, 0.6, 0.5))
		wall_material.set_shader_parameter("use_texture", false)
	wall_mesh_instance.material_override = wall_material

	# === КРЫША с ArrayMesh для UV ===
	var roof_indices_2d := Geometry2D.triangulate_polygon(points)
	if roof_indices_2d.size() >= 3:
		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)

		var roof_vertices := PackedVector3Array()
		var roof_uvs := PackedVector2Array()
		var roof_normals := PackedVector3Array()
		var roof_indices := PackedInt32Array()

		# Добавляем все вершины крыши
		for p in points:
			roof_vertices.append(Vector3(p.x, roof_y, p.y))
			# UV для крыши - мировые координаты
			roof_uvs.append(Vector2(p.x * 0.1, p.y * 0.1))
			roof_normals.append(Vector3.UP)

		# Индексы из триангуляции
		for idx in roof_indices_2d:
			roof_indices.append(idx)

		roof_arrays[Mesh.ARRAY_VERTEX] = roof_vertices
		roof_arrays[Mesh.ARRAY_TEX_UV] = roof_uvs
		roof_arrays[Mesh.ARRAY_NORMAL] = roof_normals
		roof_arrays[Mesh.ARRAY_INDEX] = roof_indices

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_mesh_instance := MeshInstance3D.new()
		roof_mesh_instance.mesh = roof_mesh

		roof_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

		# Материал крыши с текстурой
		var roof_material := StandardMaterial3D.new()
		roof_material.cull_mode = BaseMaterial3D.CULL_BACK  # Оптимизация: включить backface culling
		if _building_textures.has("roof"):
			roof_material.albedo_texture = _building_textures["roof"]
			roof_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		else:
			roof_material.albedo_color = Color(0.15, 0.15, 0.15)
		roof_mesh_instance.material_override = roof_material

		# Добавляем крышу к стенам
		wall_mesh_instance.add_child(roof_mesh_instance)

		# === ПАРАПЕТ ===
		var par_arrays := []
		par_arrays.resize(Mesh.ARRAY_MAX)
		var par_verts := PackedVector3Array()
		var par_uv := PackedVector2Array()
		var par_norms := PackedVector3Array()
		var par_idx := PackedInt32Array()

		var n_p := points.size()
		var p_top := roof_y + 0.50
		var p_bot := roof_y

		var p_edge_offsets := PackedVector2Array()
		for qi in n_p:
			var qi_next := (qi + 1) % n_p
			var qdir := (points[qi_next] - points[qi]).normalized()
			p_edge_offsets.append(Vector2(-qdir.y * normal_sign, qdir.x * normal_sign) * 0.20)

		for qi in n_p:
			var qi_next := (qi + 1) % n_p
			var qp0 := points[qi]
			var qp1 := points[qi_next]
			var qoff := p_edge_offsets[qi]
			var qdir2 := (qp1 - qp0).normalized()
			var qnorm := Vector3(-qdir2.y * normal_sign, 0.0, qdir2.x * normal_sign)
			var qop0 := qp0 + qoff
			var qop1 := qp1 + qoff

			# Наружная грань
			var vi := par_verts.size()
			par_verts.append(Vector3(qop0.x, p_top, qop0.y))
			par_verts.append(Vector3(qop1.x, p_top, qop1.y))
			par_verts.append(Vector3(qop1.x, p_bot, qop1.y))
			par_verts.append(Vector3(qop0.x, p_bot, qop0.y))
			par_uv.append(Vector2(0, 0))
			par_uv.append(Vector2(1, 0))
			par_uv.append(Vector2(1, 1))
			par_uv.append(Vector2(0, 1))
			par_norms.append(qnorm)
			par_norms.append(qnorm)
			par_norms.append(qnorm)
			par_norms.append(qnorm)
			par_idx.append(vi + 0)
			par_idx.append(vi + 1)
			par_idx.append(vi + 2)
			par_idx.append(vi + 0)
			par_idx.append(vi + 2)
			par_idx.append(vi + 3)

			# Нижняя грань
			vi = par_verts.size()
			par_verts.append(Vector3(qop0.x, p_bot, qop0.y))
			par_verts.append(Vector3(qop1.x, p_bot, qop1.y))
			par_verts.append(Vector3(qp1.x, p_bot, qp1.y))
			par_verts.append(Vector3(qp0.x, p_bot, qp0.y))
			par_uv.append(Vector2(0, 0))
			par_uv.append(Vector2(1, 0))
			par_uv.append(Vector2(1, 1))
			par_uv.append(Vector2(0, 1))
			par_norms.append(Vector3.DOWN)
			par_norms.append(Vector3.DOWN)
			par_norms.append(Vector3.DOWN)
			par_norms.append(Vector3.DOWN)
			par_idx.append(vi + 0)
			par_idx.append(vi + 1)
			par_idx.append(vi + 2)
			par_idx.append(vi + 0)
			par_idx.append(vi + 2)
			par_idx.append(vi + 3)

			# Угловое заполнение
			var qnext_off := p_edge_offsets[qi_next]
			var qca := qp1 + qoff
			var qcb := qp1 + qnext_off
			if qca.distance_squared_to(qcb) > 0.0001:
				var qmid := (qoff.normalized() + qnext_off.normalized()).normalized()
				var qfn := Vector3(qmid.x, 0.0, qmid.y)
				vi = par_verts.size()
				par_verts.append(Vector3(qca.x, p_top, qca.y))
				par_verts.append(Vector3(qcb.x, p_top, qcb.y))
				par_verts.append(Vector3(qcb.x, p_bot, qcb.y))
				par_verts.append(Vector3(qca.x, p_bot, qca.y))
				par_uv.append(Vector2(0, 0))
				par_uv.append(Vector2(1, 0))
				par_uv.append(Vector2(1, 1))
				par_uv.append(Vector2(0, 1))
				par_norms.append(qfn)
				par_norms.append(qfn)
				par_norms.append(qfn)
				par_norms.append(qfn)
				par_idx.append(vi + 0)
				par_idx.append(vi + 1)
				par_idx.append(vi + 2)
				par_idx.append(vi + 0)
				par_idx.append(vi + 2)
				par_idx.append(vi + 3)

		if par_idx.size() >= 3:
			par_arrays[Mesh.ARRAY_VERTEX] = par_verts
			par_arrays[Mesh.ARRAY_TEX_UV] = par_uv
			par_arrays[Mesh.ARRAY_NORMAL] = par_norms
			par_arrays[Mesh.ARRAY_INDEX] = par_idx
			var par_mesh := ArrayMesh.new()
			par_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, par_arrays)
			var par_mi := MeshInstance3D.new()
			par_mi.mesh = par_mesh
			par_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			var par_mat := StandardMaterial3D.new()
			par_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			par_mat.albedo_color = Color(0.5, 0.5, 0.5)
			par_mi.material_override = par_mat
			wall_mesh_instance.add_child(par_mi)

	# === ФУНДАМЕНТ ===
	var fnd_ci := int(abs(points[0].x * 73.0 + points[0].y * 137.0)) % 4
	var fnd_arr := []
	fnd_arr.resize(Mesh.ARRAY_MAX)
	var fv := PackedVector3Array()
	var fu := PackedVector2Array()
	var fn := PackedVector3Array()
	var fi := PackedInt32Array()
	var ft := base_elev + fnd_h
	var fb := base_elev
	for i in range(points.size()):
		var fp1 := points[i]
		var fp2 := points[(i + 1) % points.size()]
		var fdir := (fp2 - fp1).normalized()
		var fnorm := Vector3(-fdir.y * normal_sign, 0.0, fdir.x * normal_sign)
		var fvi := fv.size()
		fv.append(Vector3(fp1.x, ft, fp1.y))
		fv.append(Vector3(fp2.x, ft, fp2.y))
		fv.append(Vector3(fp2.x, fb, fp2.y))
		fv.append(Vector3(fp1.x, fb, fp1.y))
		fu.append(Vector2(0, 0))
		fu.append(Vector2(1, 0))
		fu.append(Vector2(1, 1))
		fu.append(Vector2(0, 1))
		fn.append(fnorm)
		fn.append(fnorm)
		fn.append(fnorm)
		fn.append(fnorm)
		fi.append(fvi + 0)
		fi.append(fvi + 1)
		fi.append(fvi + 2)
		fi.append(fvi + 0)
		fi.append(fvi + 2)
		fi.append(fvi + 3)
	if fi.size() >= 3:
		fnd_arr[Mesh.ARRAY_VERTEX] = fv
		fnd_arr[Mesh.ARRAY_TEX_UV] = fu
		fnd_arr[Mesh.ARRAY_NORMAL] = fn
		fnd_arr[Mesh.ARRAY_INDEX] = fi
		var fnd_m := ArrayMesh.new()
		fnd_m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fnd_arr)
		var fnd_mi := MeshInstance3D.new()
		fnd_mi.mesh = fnd_m
		fnd_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var fnd_mat := StandardMaterial3D.new()
		fnd_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		fnd_mat.albedo_color = _building_foundation_materials[fnd_ci].albedo_color
		var fnd_hash := fmod(abs(points[0].x * 41.0 + points[0].y * 59.0), 1.0)
		fnd_mat.roughness = 0.5 + fnd_hash * 0.4
		fnd_mat.metallic = 0.02 + fnd_hash * 0.08
		fnd_mat.metallic_specular = 0.3
		fnd_mi.material_override = fnd_mat
		wall_mesh_instance.add_child(fnd_mi)

	# Создаём физическое тело
	var body := StaticBody3D.new()
	body.collision_layer = 2  # Слой 2 для зданий
	body.collision_mask = 0   # Статика не проверяет коллизии (машина проверяет со зданиями)
	body.add_child(wall_mesh_instance)

	# Добавляем тело в сцену сразу (визуал появится)
	parent.add_child(body)

	# Создаём коллизии и декорации отложенно (deferred) чтобы не блокировать кадр
	_create_building_collisions_deferred.call_deferred(body, points, base_elev, building_height)
	_add_building_night_decorations.call_deferred(wall_mesh_instance, points, building_height, parent, base_elev)


# Кэш кастомных текстур зданий (загружаются по пути)
var _custom_building_textures: Dictionary = {}
var _custom_building_maps: Dictionary = {}  # Кэш всех дополнительных карт (normal, ao, specular, displacement)


func _load_texture_map(explicit_path: String, auto_path: String) -> Texture2D:
	"""Загружает текстурную карту с кэшированием. Приоритет: explicit_path > auto_path
	Поддерживает как импортированные ресурсы, так и raw PNG/JPG файлы"""
	var path := explicit_path if explicit_path != "" else auto_path
	if path == "":
		return null
	if _custom_building_maps.has(path):
		return _custom_building_maps[path]

	var tex: Texture2D = null

	# Сначала пробуем загрузить как импортированный ресурс
	if ResourceLoader.exists(path):
		tex = load(path)
	else:
		# Пробуем загрузить напрямую как Image (для неимпортированных файлов)
		var img := Image.new()
		var global_path := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(global_path):
			var err := img.load(global_path)
			if err == OK:
				tex = ImageTexture.create_from_image(img)
				print("OSM: Loaded raw image: ", path, " (", img.get_width(), "x", img.get_height(), ")")

	if tex:
		_custom_building_maps[path] = tex
	return tex


func _create_3d_building_with_custom_texture(points: PackedVector2Array, building_height: float, building_override, parent: Node3D, base_elev: float = 0.0, _debug_name: String = "") -> void:
	"""Создаёт здание с кастомной текстурой и normal map из файла"""
	var texture_path: String = building_override.wall_texture_path
	var texture_repeat_y: float = building_override.texture_repeat_y if building_override.texture_repeat_y > 0 else 2.0
	# Минимум 4 точки для нормального здания
	if points.size() < 4:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Проверка на слишком маленькие здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var size_x := max_x - min_x
	var size_z := max_z - min_z

	if size_x < 3.0 or size_z < 3.0:
		return
	if size_x > 200.0 or size_z > 200.0:
		return

	var min_size: float = min(size_x, size_z)
	if min_size < 0.1:
		return
	var aspect: float = max(size_x, size_z) / min_size
	if aspect > 20.0:
		return

	var area: float = _calculate_polygon_area(points)
	if area < 10.0:
		return

	# Загружаем кастомную текстуру (с кэшированием)
	var custom_texture: Texture2D = null
	if _custom_building_textures.has(texture_path):
		custom_texture = _custom_building_textures[texture_path]
	elif ResourceLoader.exists(texture_path):
		custom_texture = load(texture_path)
		_custom_building_textures[texture_path] = custom_texture

	# Загружаем дополнительные карты текстур (с кэшированием)
	var base_path := texture_path.get_basename()  # путь без расширения
	print("OSM: Loading PBR maps for base_path: ", base_path)

	# Normal map
	var normal_path := base_path + "_normal.png"
	var normal_texture: Texture2D = _load_texture_map(building_override.wall_normal_path, normal_path)
	var normal_strength: float = 2.0  # Максимальная сила для видимого эффекта
	print("  Normal map: ", normal_path, " -> ", normal_texture != null)

	# Ambient Occlusion
	var ao_path := base_path + "_ambient.png"
	var ao_texture: Texture2D = _load_texture_map(building_override.wall_ao_path, ao_path)
	var ao_strength: float = 1.0  # Полная сила AO
	print("  AO map: ", ao_path, " -> ", ao_texture != null)

	# Specular (используется как инверсия roughness)
	var specular_path := base_path + "_specular.png"
	var specular_texture: Texture2D = _load_texture_map(building_override.wall_specular_path, specular_path)
	print("  Specular map: ", specular_path, " -> ", specular_texture != null)

	# Displacement/Height (для parallax mapping)
	var displacement_path := base_path + "_displacement.png"
	var displacement_texture: Texture2D = _load_texture_map(building_override.wall_displacement_path, displacement_path)
	var heightmap_scale: float = 0.05  # Увеличенная глубина для видимого эффекта
	print("  Displacement map: ", displacement_path, " -> ", displacement_texture != null)


	# Высоты с учётом террейна
	var fnd_h := _get_foundation_height(points)
	var floor_y := base_elev + fnd_h
	var foundation_y := base_elev + fnd_h
	var roof_y := base_elev + building_height

	# === СТЕНЫ с ArrayMesh для UV ===
	var wall_arrays := []
	wall_arrays.resize(Mesh.ARRAY_MAX)

	var wall_vertices := PackedVector3Array()
	var wall_uvs := PackedVector2Array()
	var wall_normals := PackedVector3Array()
	var wall_indices := PackedInt32Array()

	# Вычисляем длины всех стен
	var wall_widths: Array[float] = []
	var perimeter := 0.0
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var w := p1.distance_to(p2)
		wall_widths.append(w)
		perimeter += w

	# Адаптивное повторение: определяем медиану для разделения коротких/длинных стен
	var use_adaptive: bool = building_override.use_adaptive_repeat
	var median_width := 0.0
	if use_adaptive:
		var sorted_widths := wall_widths.duplicate()
		sorted_widths.sort()
		var mid := sorted_widths.size() / 2
		median_width = sorted_widths[mid]

	# UV масштаб: texture_repeat_x повторов на весь периметр (0 = авто ~10м на повтор)
	var texture_repeat_x: float = building_override.texture_repeat_x if building_override.texture_repeat_x > 0 else 0.0
	var uv_scale_x := texture_repeat_x / perimeter if texture_repeat_x > 0 else 0.1

	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	var accumulated_width := 0.0
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_width: float = wall_widths[i]

		var v1 := Vector3(p1.x, foundation_y, p1.y)
		var v2 := Vector3(p2.x, foundation_y, p2.y)
		var v3 := Vector3(p2.x, roof_y, p2.y)
		var v4 := Vector3(p1.x, roof_y, p1.y)

		var dir := (p2 - p1).normalized()
		var normal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)

		# UV координаты по горизонтали
		var u1: float
		var u2: float
		if use_adaptive:
			# Адаптивный режим: каждая стена начинается с 0, свой масштаб
			var is_short: bool = wall_width < median_width
			var repeats: float = building_override.texture_repeat_short if is_short else building_override.texture_repeat_long
			u1 = 0.0
			u2 = repeats
		else:
			# Стандартный режим: накапливаемый UV по периметру
			u1 = accumulated_width * uv_scale_x
			u2 = (accumulated_width + wall_width) * uv_scale_x

		# Для фото текстуры: N повторов по высоте, UV.y=0 вверху
		# UV масштаб по видимой высоте (floor_y → roof_y), фундамент получает дополнительный UV
		var visible_height := roof_y - floor_y
		var total_height := roof_y - foundation_y
		var v_bottom := texture_repeat_y * total_height / visible_height if visible_height > 0.1 else texture_repeat_y
		var v_top := 0.0

		var idx := wall_vertices.size()

		wall_vertices.append(v1)
		wall_vertices.append(v2)
		wall_vertices.append(v3)
		wall_vertices.append(v4)

		# v1,v2 - низ стены (v_bottom=1.0), v3,v4 - верх стены (v_top=0.0)
		wall_uvs.append(Vector2(u1, v_bottom))
		wall_uvs.append(Vector2(u2, v_bottom))
		wall_uvs.append(Vector2(u2, v_top))
		wall_uvs.append(Vector2(u1, v_top))

		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)
		wall_normals.append(normal)

		wall_indices.append(idx + 0)
		wall_indices.append(idx + 1)
		wall_indices.append(idx + 2)

		wall_indices.append(idx + 0)
		wall_indices.append(idx + 2)
		wall_indices.append(idx + 3)

		accumulated_width += wall_width

	wall_arrays[Mesh.ARRAY_VERTEX] = wall_vertices
	wall_arrays[Mesh.ARRAY_TEX_UV] = wall_uvs
	wall_arrays[Mesh.ARRAY_NORMAL] = wall_normals
	wall_arrays[Mesh.ARRAY_INDEX] = wall_indices

	var wall_mesh := ArrayMesh.new()
	wall_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wall_arrays)

	var wall_mesh_instance := MeshInstance3D.new()
	wall_mesh_instance.mesh = wall_mesh

	wall_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	wall_mesh_instance.visibility_range_end = render_distance
	wall_mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	# Материал стен с кастомной текстурой - используем ShaderMaterial для правильной работы emission
	var wall_material := ShaderMaterial.new()
	wall_material.shader = BuildingWallCustomShader

	# Основные текстуры
	if custom_texture:
		wall_material.set_shader_parameter("albedo_texture", custom_texture)
	if normal_texture:
		wall_material.set_shader_parameter("normal_texture", normal_texture)
		wall_material.set_shader_parameter("normal_strength", normal_strength)
	if ao_texture:
		wall_material.set_shader_parameter("ao_texture", ao_texture)
		wall_material.set_shader_parameter("ao_strength", ao_strength)
	if specular_texture:
		wall_material.set_shader_parameter("roughness_texture", specular_texture)

	wall_mesh_instance.material_override = wall_material

	# === КРЫША (плоская поверхность) ===
	var roof_indices_2d := Geometry2D.triangulate_polygon(points)
	if roof_indices_2d.size() >= 3:
		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)

		var roof_vertices := PackedVector3Array()
		var roof_uvs := PackedVector2Array()
		var roof_normals := PackedVector3Array()

		for p in points:
			roof_vertices.append(Vector3(p.x, roof_y, p.y))
			roof_uvs.append(Vector2(p.x * 0.1, p.y * 0.1))
			roof_normals.append(Vector3.UP)

		roof_arrays[Mesh.ARRAY_VERTEX] = roof_vertices
		roof_arrays[Mesh.ARRAY_TEX_UV] = roof_uvs
		roof_arrays[Mesh.ARRAY_NORMAL] = roof_normals
		roof_arrays[Mesh.ARRAY_INDEX] = roof_indices_2d

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_mesh_instance := MeshInstance3D.new()
		roof_mesh_instance.mesh = roof_mesh
		roof_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

		var roof_material := StandardMaterial3D.new()
		roof_material.cull_mode = BaseMaterial3D.CULL_BACK
		if _building_textures.has("roof"):
			roof_material.albedo_texture = _building_textures["roof"]
			roof_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		else:
			roof_material.albedo_color = Color(0.15, 0.15, 0.15)
		roof_mesh_instance.material_override = roof_material

		wall_mesh_instance.add_child(roof_mesh_instance)

		# === ПАРАПЕТ: наружная, нижняя грани + угловые заполнения ===
		var parapet_arrays := []
		parapet_arrays.resize(Mesh.ARRAY_MAX)
		var par_vertices := PackedVector3Array()
		var par_uvs := PackedVector2Array()
		var par_normals := PackedVector3Array()
		var par_indices := PackedInt32Array()

		var n_pts := points.size()
		var parapet_top := roof_y + 0.50
		var parapet_bottom := roof_y

		# Предвычисляем offset каждого ребра (normal_sign из signed area)
		var edge_offsets := PackedVector2Array()
		for ei in n_pts:
			var ei_next := (ei + 1) % n_pts
			var edir := (points[ei_next] - points[ei]).normalized()
			edge_offsets.append(Vector2(-edir.y * normal_sign, edir.x * normal_sign) * 0.20)

		for i in n_pts:
			var i_next := (i + 1) % n_pts
			var p0 := points[i]
			var p1 := points[i_next]
			var off := edge_offsets[i]
			var dir2 := (p1 - p0).normalized()
			var out_normal := Vector3(-dir2.y * normal_sign, 0.0, dir2.x * normal_sign)

			var op0 := p0 + off
			var op1 := p1 + off

			# Наружная грань
			var vi := par_vertices.size()
			par_vertices.append(Vector3(op0.x, parapet_top, op0.y))
			par_vertices.append(Vector3(op1.x, parapet_top, op1.y))
			par_vertices.append(Vector3(op1.x, parapet_bottom, op1.y))
			par_vertices.append(Vector3(op0.x, parapet_bottom, op0.y))
			par_uvs.append(Vector2(0, 0))
			par_uvs.append(Vector2(1, 0))
			par_uvs.append(Vector2(1, 1))
			par_uvs.append(Vector2(0, 1))
			par_normals.append(out_normal)
			par_normals.append(out_normal)
			par_normals.append(out_normal)
			par_normals.append(out_normal)
			par_indices.append(vi + 0)
			par_indices.append(vi + 1)
			par_indices.append(vi + 2)
			par_indices.append(vi + 0)
			par_indices.append(vi + 2)
			par_indices.append(vi + 3)

			# Нижняя грань
			vi = par_vertices.size()
			par_vertices.append(Vector3(op0.x, parapet_bottom, op0.y))
			par_vertices.append(Vector3(op1.x, parapet_bottom, op1.y))
			par_vertices.append(Vector3(p1.x, parapet_bottom, p1.y))
			par_vertices.append(Vector3(p0.x, parapet_bottom, p0.y))
			par_uvs.append(Vector2(0, 0))
			par_uvs.append(Vector2(1, 0))
			par_uvs.append(Vector2(1, 1))
			par_uvs.append(Vector2(0, 1))
			par_normals.append(Vector3.DOWN)
			par_normals.append(Vector3.DOWN)
			par_normals.append(Vector3.DOWN)
			par_normals.append(Vector3.DOWN)
			par_indices.append(vi + 0)
			par_indices.append(vi + 1)
			par_indices.append(vi + 2)
			par_indices.append(vi + 0)
			par_indices.append(vi + 2)
			par_indices.append(vi + 3)

			# Угловое заполнение
			var next_off := edge_offsets[i_next]
			var corner_a := p1 + off
			var corner_b := p1 + next_off
			if corner_a.distance_squared_to(corner_b) > 0.0001:
				var mid_dir := (off.normalized() + next_off.normalized()).normalized()
				var face_normal := Vector3(mid_dir.x, 0.0, mid_dir.y)
				vi = par_vertices.size()
				par_vertices.append(Vector3(corner_a.x, parapet_top, corner_a.y))
				par_vertices.append(Vector3(corner_b.x, parapet_top, corner_b.y))
				par_vertices.append(Vector3(corner_b.x, parapet_bottom, corner_b.y))
				par_vertices.append(Vector3(corner_a.x, parapet_bottom, corner_a.y))
				par_uvs.append(Vector2(0, 0))
				par_uvs.append(Vector2(1, 0))
				par_uvs.append(Vector2(1, 1))
				par_uvs.append(Vector2(0, 1))
				par_normals.append(face_normal)
				par_normals.append(face_normal)
				par_normals.append(face_normal)
				par_normals.append(face_normal)
				par_indices.append(vi + 0)
				par_indices.append(vi + 1)
				par_indices.append(vi + 2)
				par_indices.append(vi + 0)
				par_indices.append(vi + 2)
				par_indices.append(vi + 3)

		parapet_arrays[Mesh.ARRAY_VERTEX] = par_vertices
		parapet_arrays[Mesh.ARRAY_TEX_UV] = par_uvs
		parapet_arrays[Mesh.ARRAY_NORMAL] = par_normals
		parapet_arrays[Mesh.ARRAY_INDEX] = par_indices

		var parapet_mesh := ArrayMesh.new()
		parapet_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, parapet_arrays)

		var parapet_mesh_instance := MeshInstance3D.new()
		parapet_mesh_instance.mesh = parapet_mesh
		parapet_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

		var parapet_material := StandardMaterial3D.new()
		parapet_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		parapet_material.albedo_color = Color(0.5, 0.5, 0.5)
		parapet_mesh_instance.material_override = parapet_material

		wall_mesh_instance.add_child(parapet_mesh_instance)

	# === ФУНДАМЕНТ ===
	var fnd_ci2 := int(abs(points[0].x * 73.0 + points[0].y * 137.0)) % 4
	var fnd_arr2 := []
	fnd_arr2.resize(Mesh.ARRAY_MAX)
	var fv2 := PackedVector3Array()
	var fu2 := PackedVector2Array()
	var fn2 := PackedVector3Array()
	var fi2 := PackedInt32Array()
	var ft2 := base_elev + fnd_h
	var fb2 := base_elev
	for i in range(points.size()):
		var fp1 := points[i]
		var fp2 := points[(i + 1) % points.size()]
		var fdir := (fp2 - fp1).normalized()
		var fnorm := Vector3(-fdir.y * normal_sign, 0.0, fdir.x * normal_sign)
		var fvi := fv2.size()
		fv2.append(Vector3(fp1.x, ft2, fp1.y))
		fv2.append(Vector3(fp2.x, ft2, fp2.y))
		fv2.append(Vector3(fp2.x, fb2, fp2.y))
		fv2.append(Vector3(fp1.x, fb2, fp1.y))
		fu2.append(Vector2(0, 0))
		fu2.append(Vector2(1, 0))
		fu2.append(Vector2(1, 1))
		fu2.append(Vector2(0, 1))
		fn2.append(fnorm)
		fn2.append(fnorm)
		fn2.append(fnorm)
		fn2.append(fnorm)
		fi2.append(fvi + 0)
		fi2.append(fvi + 1)
		fi2.append(fvi + 2)
		fi2.append(fvi + 0)
		fi2.append(fvi + 2)
		fi2.append(fvi + 3)
	if fi2.size() >= 3:
		fnd_arr2[Mesh.ARRAY_VERTEX] = fv2
		fnd_arr2[Mesh.ARRAY_TEX_UV] = fu2
		fnd_arr2[Mesh.ARRAY_NORMAL] = fn2
		fnd_arr2[Mesh.ARRAY_INDEX] = fi2
		var fnd_m2 := ArrayMesh.new()
		fnd_m2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fnd_arr2)
		var fnd_mi2 := MeshInstance3D.new()
		fnd_mi2.mesh = fnd_m2
		fnd_mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var fnd_mat2 := StandardMaterial3D.new()
		fnd_mat2.cull_mode = BaseMaterial3D.CULL_DISABLED
		fnd_mat2.albedo_color = _building_foundation_materials[fnd_ci2].albedo_color
		var fnd_hash2 := fmod(abs(points[0].x * 41.0 + points[0].y * 59.0), 1.0)
		fnd_mat2.roughness = 0.5 + fnd_hash2 * 0.4
		fnd_mat2.metallic = 0.02 + fnd_hash2 * 0.08
		fnd_mat2.metallic_specular = 0.3
		fnd_mi2.material_override = fnd_mat2
		wall_mesh_instance.add_child(fnd_mi2)

	# Создаём физическое тело
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.add_child(wall_mesh_instance)

	parent.add_child(body)

	# Отложенные коллизии (без окон - у кастомной текстуры свои окна)
	_create_building_collisions_deferred.call_deferred(body, points, base_elev, building_height)
	# Не вызываем _add_building_night_decorations - текстура уже содержит окна


# Отложенное создание коллизий зданий (вызывается через call_deferred)
func _create_building_collisions_deferred(body: StaticBody3D, points: PackedVector2Array, base_elev: float, _building_height: float) -> void:
	if not is_instance_valid(body):
		return

	# Коллизия только на уровне земли (0.5м) — машина не врезается во второй этаж
	var collision_h := 0.5

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var wall_center := Vector3((p1.x + p2.x) / 2, base_elev + collision_h / 2, (p1.y + p2.y) / 2)
		var wall_length := p1.distance_to(p2)

		if wall_length < 0.5:
			continue

		var wall_angle := atan2(p2.y - p1.y, p2.x - p1.x)

		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(wall_length, collision_h, 0.3)
		collision.shape = box
		collision.position = wall_center
		collision.rotation.y = -wall_angle

		body.add_child(collision)

func _create_polygon_mesh(points: PackedVector2Array, color: Color, height_offset: float, parent: Node3D) -> void:
	if points.size() < 3:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	var mesh := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mesh.mesh = im

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = material

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	# Используем триангуляцию для корректной работы с невыпуклыми полигонами
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.size() >= 3:
		im.surface_set_normal(Vector3.UP)  # Нормаль вверх для плоских поверхностей
		for i in range(0, indices.size(), 3):
			var p1 := points[indices[i]]
			var p2 := points[indices[i + 1]]
			var p3 := points[indices[i + 2]]
			var h1 := 0.0 + height_offset
			var h2 := 0.0 + height_offset
			var h3 := 0.0 + height_offset
			im.surface_add_vertex(Vector3(p1.x, h1, p1.y))
			im.surface_add_vertex(Vector3(p2.x, h2, p2.y))
			im.surface_add_vertex(Vector3(p3.x, h3, p3.y))

	im.surface_end()

	parent.add_child(mesh)

func _create_polygon_mesh_with_texture(points: PackedVector2Array, texture_key: String, height_offset: float, parent: Node3D, is_water: bool = false) -> void:
	if points.size() < 3:
		return

	# Убираем дубликат последней точки если она совпадает с первой
	if points.size() > 1 and points[0].distance_to(points[points.size() - 1]) < 0.1:
		points.remove_at(points.size() - 1)

	if points.size() < 3:
		return

	# Триангуляция
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.size() < 3:
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var tri_indices := PackedInt32Array()

	var uv_scale := 0.25  # Масштаб UV для земли (20м = 1 повтор текстуры)

	# Добавляем вершины
	for p in points:
		var h := 0.0 + height_offset
		vertices.append(Vector3(p.x, h, p.y))
		uvs.append(Vector2(p.x * uv_scale, p.y * uv_scale))
		normals.append(Vector3.UP)

	# Фильтруем треугольники, попадающие на дороги
	for ti in range(0, indices.size(), 3):
		var i0: int = indices[ti]
		var i1: int = indices[ti + 1]
		var i2: int = indices[ti + 2]
		var center := (points[i0] + points[i1] + points[i2]) / 3.0
		if _is_point_near_road(center, 0.0):
			continue
		tri_indices.append(i0)
		tri_indices.append(i1)
		tri_indices.append(i2)

	if tri_indices.is_empty():
		return

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = tri_indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh := MeshInstance3D.new()
	mesh.mesh = arr_mesh

	# Материал с текстурой
	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _ground_textures.has(texture_key):
		material.albedo_texture = _ground_textures[texture_key]
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		# Fallback цвета
		match texture_key:
			"grass":
				material.albedo_color = Color(0.3, 0.5, 0.2)
			"forest":
				material.albedo_color = Color(0.2, 0.4, 0.15)
			"water":
				material.albedo_color = Color(0.2, 0.4, 0.6)
			_:
				material.albedo_color = Color(0.4, 0.5, 0.3)

	# Для воды добавляем прозрачность
	if is_water:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.8

	mesh.material_override = material

	# Track draw calls
	if _draw_call_logging_enabled:
		_draw_call_stats["terrain"] += 1

	parent.add_child(mesh)

## Создаёт коллизию для парка с группой "Park" (очень высокое сопротивление качению)
func _create_park_collision(points: PackedVector2Array, parent: Node3D) -> void:
	if points.size() < 3:
		return

	# Триангуляция для создания коллизии
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.size() < 3:
		return

	var vertices := PackedVector3Array()
	for p in points:
		var h := 0.0 + 0.01  # Чуть выше террейна
		vertices.append(Vector3(p.x, h, p.y))

	# Создаём ConcavePolygonShape3D напрямую из vertices/indices (быстрее чем create_trimesh_collision)
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for fi in range(indices.size()):
		faces[fi] = vertices[indices[fi]]

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)

	var body := StaticBody3D.new()
	body.name = "ParkCollision"
	body.collision_layer = 1
	body.collision_mask = 0  # Статика не проверяет коллизии
	body.add_to_group("Park")  # GEVP - парк (очень высокое сопротивление)

	var col_shape := CollisionShape3D.new()
	col_shape.shape = shape
	# Если elevation baked in — помечаем чтобы _update_collision_heights не задвоил
	body.add_child(col_shape)

	parent.add_child(body)

# Конвертация lat/lon в локальные координаты относительно стартовой точки
# Примечание: Z инвертирован, т.к. в Godot +Z направлен "от экрана", а latitude растёт на север
func _latlon_to_local(lat: float, lon: float) -> Vector2:
	if _lon_scale == 0.0:
		_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0
	var dx := (lon - start_lon) * _lon_scale
	var dz := (lat - start_lat) * 111000.0
	return Vector2(dx, -dz)  # Инвертируем Z для корректной ориентации карты


## Предзагрузка чанков вдоль маршрута гонки
## waypoints: Array[Vector2] - массив точек (lat, lon)
func preload_route_chunks(waypoints: Array) -> void:
	if waypoints.is_empty():
		return

	print("OSMTerrain: Preloading chunks for %d waypoints" % waypoints.size())

	var chunks_to_load: Array[String] = []

	for wp in waypoints:
		# wp - это Vector2(lat, lon)
		var local_pos := _latlon_to_local(wp.x, wp.y)
		var chunk_x := int(floor(local_pos.x / chunk_size))
		var chunk_z := int(floor(local_pos.y / chunk_size))

		# Загружаем также соседние чанки для плавности
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var key := "%d,%d" % [chunk_x + dx, chunk_z + dz]
				if key not in chunks_to_load and key not in _loaded_chunks and key not in _loading_chunks:
					chunks_to_load.append(key)

	print("OSMTerrain: Will load %d chunks along route" % chunks_to_load.size())

	# Запускаем загрузку чанков
	for key in chunks_to_load:
		var parts := key.split(",")
		var cx := int(parts[0])
		var cz := int(parts[1])
		_load_chunk(cx, cz)


# Расчёт площади полигона (формула Шолейса)
func _calculate_polygon_area(points: PackedVector2Array) -> float:
	var area := 0.0
	var n := points.size()
	for i in range(n):
		var j := (i + 1) % n
		area += points[i].x * points[j].y
		area -= points[j].x * points[i].y
	return abs(area) / 2.0


# Проверка направления полигона (true = против часовой стрелки = нормали наружу)
## Высота фундамента здания (0.5–1.0м), детерминированная по координатам
static func _get_foundation_height(points: PackedVector2Array) -> float:
	var hash_val: float = absf(points[0].x * 31.0 + points[0].y * 97.0)
	return 0.5 + fmod(hash_val, 1.0) * 0.5  # 0.5 to 1.0


func _is_polygon_ccw(points: PackedVector2Array) -> bool:
	var signed_area := 0.0
	var n := points.size()
	for i in range(n):
		var j := (i + 1) % n
		signed_area += points[i].x * points[j].y
		signed_area -= points[j].x * points[i].y
	return signed_area > 0.0  # Положительная = против часовой (CCW)

# Получение центра полигона
func _get_polygon_center(points: PackedVector2Array) -> Vector2:
	if points.size() == 0:
		return Vector2.ZERO
	var center := Vector2.ZERO
	for p in points:
		center += p
	return center / points.size()

# Получение центра way из массива узлов (в локальных координатах)
func _get_way_center(nodes: Array) -> Vector2:
	if nodes.size() == 0:
		return Vector2.ZERO
	var center := Vector2.ZERO
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		center += local
	return center / nodes.size()

## Get chunk key from parent node name (e.g. "Chunk_1_2" -> "1,2")
func _get_chunk_key_from_node(node: Node3D) -> String:
	if not node:
		return ""
	var node_name: String = node.name
	# Format: "Chunk_x,z" (e.g. "Chunk_1,2")
	if node_name.begins_with("Chunk_"):
		return node_name.substr(6)  # Возвращаем "x,z" часть
	return ""

## Create a StaticBody3D collision for a lamp pole at given transform
func _create_lamp_collision(xform: Transform3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "LampCol"
	body.transform = xform
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.12
	cyl.height = 5.5
	shape.shape = cyl
	shape.position.y = 2.75  # center of 5.5m pole
	body.add_child(shape)
	return body

## Add lamp to batch for chunk with pre-calculated transforms
func _add_lamp_to_batch(chunk_key: String, lamp_pos: Vector3, road_dir: Vector3, parent: Node3D) -> void:
	if not enable_street_lamps:
		return

	# Initialize batch if needed
	if not _lamp_batch_data.has(chunk_key):
		_lamp_batch_data[chunk_key] = {
			"transforms": [],
			"light_data": [],
			"parent": parent
		}

	# Calculate lamp orientation (face toward road)
	var lamp_forward := road_dir.normalized()
	var yaw := atan2(lamp_forward.x, lamp_forward.z) + PI / 2.0
	var lamp_basis := Basis(Vector3.UP, yaw)

	# Model transform: pivot at base (Y=0), rotated by yaw
	var model_transform := Transform3D(lamp_basis, lamp_pos)
	_lamp_batch_data[chunk_key]["transforms"].append(model_transform)

	# Light position: top of model, in world space
	var light_world_pos := lamp_pos + lamp_basis * _lamp_light_offset
	var is_broken := randf() < 0.05
	_lamp_batch_data[chunk_key]["light_data"].append({
		"position": light_world_pos,
		"broken": is_broken
	})

	# Mark for finalization
	if not _lamp_batches_to_finalize.has(chunk_key):
		_lamp_batches_to_finalize.append(chunk_key)

## Finalize lamp batches for chunk - create MultiMesh instances
func _finalize_lamp_batches_for_chunk(chunk_key: String) -> void:
	if not _lamp_batch_data.has(chunk_key):
		return

	var batch: Dictionary = _lamp_batch_data[chunk_key]

	if not batch.has("parent") or not batch.has("transforms"):
		_lamp_batch_data.erase(chunk_key)
		return

	var parent: Node3D = batch.parent
	if not is_instance_valid(parent):
		_lamp_batch_data.erase(chunk_key)
		return

	var lamp_count: int = batch.transforms.size()
	if lamp_count == 0:
		_lamp_batch_data.erase(chunk_key)
		return

	# Create container (build subtree BEFORE adding to scene tree)
	var lamp_container := Node3D.new()
	lamp_container.name = "LampBatches"

	# Single MultiMesh for lamp model
	var mm_inst := MultiMeshInstance3D.new()
	mm_inst.name = "Lamps"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _lamp_model_mesh
	mm.instance_count = lamp_count
	for i in range(lamp_count):
		mm.set_instance_transform(i, batch.transforms[i])
	mm_inst.multimesh = mm
	mm_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	lamp_container.add_child(mm_inst)

	# Collision bodies for each lamp pole
	for i in range(lamp_count):
		var col := _create_lamp_collision(batch.transforms[i])
		lamp_container.add_child(col)

	# LIGHTS container (separate OmniLight3D nodes — deferred)
	var lights_container := Node3D.new()
	lights_container.name = "Lights"
	lamp_container.add_child(lights_container)

	# Add entire subtree to scene tree in one budgeted call
	_budgeted_add_child(parent, lamp_container)

	_lamp_lights_by_chunk[chunk_key] = []

	var is_night: bool = false
	if _night_mode_manager and is_instance_valid(_night_mode_manager):
		is_night = _night_mode_manager.is_night
	else:
		var night_mgr := get_tree().get_first_node_in_group("night_mode_manager")
		if night_mgr:
			_night_mode_manager = night_mgr
			is_night = night_mgr.is_night
		else:
			is_night = _is_night_mode

	# Lights — отложенное создание через очередь
	if batch.light_data.size() > 0:
		_deferred_lamp_lights.append({
			"container": lights_container,
			"lights": batch.light_data,
			"idx": 0,
			"chunk_key": chunk_key,
			"is_night": is_night
		})

	if _draw_call_logging_enabled:
		_draw_call_stats["lamps"] += 1  # Single MultiMesh per chunk

	print("OSM: Finalized lamp batch for chunk %s: %d lamps, 1 draw call" % [chunk_key, lamp_count])

	_lamp_batch_data.erase(chunk_key)

## Update lamp globe colors and light visibility for night mode
func _update_lamp_night_mode(is_night: bool) -> void:
	# Update light visibility for all chunks
	for chunk_key in _lamp_lights_by_chunk.keys():
		var lights: Array = _lamp_lights_by_chunk[chunk_key]
		for light in lights:
			if is_instance_valid(light):
				# Light visibility depends on night mode AND if lamp is not broken
				# Broken lamps have a special metadata flag set during creation
				var is_broken: bool = light.get_meta("broken", false)
				light.visible = is_night and not is_broken

	# Note: Globe colors are baked into MultiMesh instance colors
	# If we need dynamic color changes, would need to:
	# 1. Store MultiMesh references per chunk
	# 2. Iterate and call set_instance_color() for each instance
	# For now, globe colors are static (set at batch creation time)

	print("OSM: Updated lamp night mode (is_night=%s)" % is_night)

## Add tree to batch for MultiMesh rendering
func _add_tree_to_batch(chunk_key: String, pos: Vector2, elevation: float, parent: Node3D, is_pine: bool = false) -> void:
	if not enable_vegetation:
		return

	if not _tree_batch_data.has(chunk_key):
		_tree_batch_data[chunk_key] = {
			"leaf_transforms": [],
			"pine_transforms": [],
			"collisions": [],
			"parent": parent
		}

	var tree_pos := Vector3(pos.x, elevation, pos.y)

	# Случайный масштаб и поворот вокруг Y для разнообразия
	var scale_factor := randf_range(0.8, 1.3)
	var rotation_y := randf() * TAU
	var basis := Basis(Vector3.UP, rotation_y).scaled(Vector3(scale_factor, scale_factor, scale_factor))
	var transform := Transform3D(basis, tree_pos)

	var type_key := "pine_transforms" if is_pine else "leaf_transforms"
	_tree_batch_data[chunk_key][type_key].append(transform)

	# Pivot нормализован — коллизия ставится прямо на позицию дерева
	_tree_batch_data[chunk_key]["collisions"].append({
		"position": tree_pos,
		"radius": 0.4
	})

	if not _tree_batches_to_finalize.has(chunk_key):
		_tree_batches_to_finalize.append(chunk_key)

## Finalize tree batches for chunk - create MultiMesh instances
func _finalize_tree_batches_for_chunk(chunk_key: String) -> void:
	if not _tree_batch_data.has(chunk_key):
		return

	var batch: Dictionary = _tree_batch_data[chunk_key]
	var parent: Node3D = batch["parent"]

	if not is_instance_valid(parent):
		_tree_batch_data.erase(chunk_key)
		return

	var leaf_transforms: Array = batch["leaf_transforms"]
	var pine_transforms: Array = batch["pine_transforms"]
	var total_trees := leaf_transforms.size() + pine_transforms.size()
	if total_trees == 0:
		_tree_batch_data.erase(chunk_key)
		return

	# Создаём LOD0 + LOD1 + LOD2(billboard) MultiMesh для каждого типа дерева
	var draw_calls := 0
	var tree_configs: Array = []
	if leaf_transforms.size() > 0:
		tree_configs.append({
			"name": "Leaf",
			"transforms": leaf_transforms,
			"mesh_lod0": _tree_mesh_leaf,
			"mesh_lod1": _tree_mesh_leaf_lod1,
			"mesh_lod2": _tree_billboard_leaf,
			"shadow_mesh": _tree_shadow_mesh_leaf,
		})
	if pine_transforms.size() > 0:
		tree_configs.append({
			"name": "Pine",
			"transforms": pine_transforms,
			"mesh_lod0": _tree_mesh_pine,
			"mesh_lod1": _tree_mesh_pine_lod1,
			"mesh_lod2": _tree_billboard_pine,
			"shadow_mesh": _tree_shadow_mesh_pine,
		})

	for config in tree_configs:
		var transforms: Array = config["transforms"]
		var name_prefix: String = config["name"]

		# Один MultiMesh на тип дерева, без visibility_range (LOD через MultiMesh не работает per-instance)
		var mm_inst := MultiMeshInstance3D.new()
		mm_inst.name = "Trees%s" % name_prefix
		mm_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = config["mesh_lod0"]
		mm.instance_count = transforms.size()
		for i in range(transforms.size()):
			mm.set_instance_transform(i, transforms[i])
		mm_inst.multimesh = mm
		_budgeted_add_child(parent, mm_inst)

		# Shadow-only MultiMesh (simplified cross mesh for shadow pass)
		var shadow_mesh: ArrayMesh = config["shadow_mesh"]
		if shadow_mesh:
			var shadow_inst := MultiMeshInstance3D.new()
			shadow_inst.name = "TreesShadow%s" % name_prefix
			shadow_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			var shadow_mm := MultiMesh.new()
			shadow_mm.transform_format = MultiMesh.TRANSFORM_3D
			shadow_mm.mesh = shadow_mesh
			shadow_mm.instance_count = transforms.size()
			for i in range(transforms.size()):
				shadow_mm.set_instance_transform(i, transforms[i])
			shadow_inst.multimesh = shadow_mm
			_budgeted_add_child(parent, shadow_inst)
			# Track node for distance-based shadow LOD
			if not _chunk_tree_shadow_nodes.has(chunk_key):
				_chunk_tree_shadow_nodes[chunk_key] = []
			_chunk_tree_shadow_nodes[chunk_key].append(shadow_inst)

		draw_calls += config["mesh_lod0"].get_surface_count()

	if _draw_call_logging_enabled:
		_draw_call_stats["vegetation"] += draw_calls

	# Коллизии деревьев — отложенное создание через очередь
	if not batch["collisions"].is_empty():
		_deferred_tree_collisions.append({
			"parent": parent,
			"collisions": batch["collisions"],
			"idx": 0
		})

	print("OSM: Trees for chunk %s: %d leaf + %d pine (LOD0+LOD1+LOD2)" % [
		chunk_key, leaf_transforms.size(), pine_transforms.size()
	])

	_tree_batch_data.erase(chunk_key)


## Финализирует билборды из DecorationLayer для чанка
func _finalize_billboard_batch_for_chunk(chunk_key: String) -> void:
	if not _decoration_layer:
		return

	# Парсим chunk_key для получения границ чанка
	var parts := chunk_key.split(",")
	if parts.size() != 2:
		return

	var chunk_x := float(parts[0]) * chunk_size
	var chunk_z := float(parts[1]) * chunk_size
	var chunk_min := Vector2(chunk_x, chunk_z)
	var chunk_max := Vector2(chunk_x + chunk_size, chunk_z + chunk_size)

	# Получаем билборды для этого чанка
	var billboards: Array = _decoration_layer.get_billboards_in_chunk(chunk_min, chunk_max)
	if billboards.is_empty():
		return

	# Находим parent node для чанка
	if not _loaded_chunks.has(chunk_key):
		return

	var parent: Node3D = _loaded_chunks[chunk_key]
	if not is_instance_valid(parent):
		return

	# Складываем билборды в deferred очередь — создаём по N за кадр
	for billboard in billboards:
		_deferred_billboard_queue.append({
			"billboard": billboard,
			"elevation": 0.0,
			"parent": parent
		})

	print("OSM: Queued %d billboards for chunk %s" % [billboards.size(), chunk_key])


# Создание дорожного знака - разрушаемый при столкновении
func _set_no_shadow_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_set_no_shadow_recursive(child)


func _create_garbage_container(pos: Vector2, elevation: float, parent: Node3D) -> void:
	var instance: Node3D = GARBAGE_CONTAINER_SCENE.instantiate()
	instance.position = Vector3(pos.x, elevation, pos.y)
	# Отключаем тени на всех MeshInstance3D
	for child in instance.get_children():
		_set_no_shadow_recursive(child)
	parent.add_child(instance)


func _place_custom_models_for_chunk(chunk_key: String, parent: Node3D) -> void:
	if not _decoration_layer:
		return
	for entry in _decoration_layer.get_custom_models():
		var model_path: String = entry.model
		if model_path.is_empty():
			continue
		var lat: float = entry.lat
		var lon: float = entry.lon
		if lat == 0.0 or lon == 0.0:
			continue
		var pos := _latlon_to_local(lat, lon)
		# Check if position belongs to this chunk
		var cx := int(floor(pos.x / chunk_size))
		var cz := int(floor(pos.y / chunk_size))
		var pos_chunk_key := "%d,%d" % [cx, cz]
		if pos_chunk_key != chunk_key:
			continue
		# Load and cache PackedScene
		if not _custom_model_cache.has(model_path):
			if ResourceLoader.exists(model_path):
				_custom_model_cache[model_path] = load(model_path)
			else:
				push_warning("Custom model not found: " + model_path)
				continue
		var scene: PackedScene = _custom_model_cache[model_path]
		if not scene:
			continue
		var inst: Node3D = scene.instantiate()
		var scale_val: float = entry.scale
		var y_offset: float = entry.get("y_offset", 0.0)
		inst.position = Vector3(pos.x, y_offset, pos.y)
		inst.scale = Vector3.ONE * scale_val
		inst.rotation_degrees.y = entry.rotation_y
		# Visibility range 150m (like traffic signs)
		_set_visibility_range_recursive(inst, 150.0)
		_set_no_shadow_recursive(inst)
		parent.add_child(inst)
		print("OSM: Placed custom model '%s' at (%.1f, %.1f) in chunk %s, scale=%.1f" % [
			model_path.get_file(), pos.x, pos.y, chunk_key, scale_val])


func _set_visibility_range_recursive(node: Node, range_end: float) -> void:
	if node is GeometryInstance3D:
		node.visibility_range_end = range_end
	for child in node.get_children():
		_set_visibility_range_recursive(child, range_end)


func _create_traffic_sign(pos: Vector2, elevation: float, tags: Dictionary, parent: Node3D) -> void:
	if not enable_traffic_signs:
		return
	# Смещаем знак с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Проверяем на дубликаты (с учётом новой позиции)
	var pos_key := "ts_%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true

	# RigidBody3D как корневой узел для физики
	var body := RigidBody3D.new()
	body.name = "TrafficSign"
	body.position = Vector3(safe_pos.x, elevation, safe_pos.y)
	body.collision_layer = 4  # Слой 4 - разрушаемые знаки
	body.collision_mask = 7  # Машины(1) + статика(2) + другие знаки(4)
	body.mass = 15.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.body_entered.connect(_on_sign_hit.bind(body))

	# Коллизия для столба
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.5
	collision.shape = shape
	collision.position.y = 1.25
	body.add_child(collision)

	# Столб - серый тонкий цилиндр
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.5
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)  # Серый
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Знак - красный/белый диск
	var sign_plate := MeshInstance3D.new()
	var sign_mesh := CylinderMesh.new()
	sign_mesh.top_radius = 0.3
	sign_mesh.bottom_radius = 0.3
	sign_mesh.height = 0.02
	sign_plate.mesh = sign_mesh

	var sign_mat := StandardMaterial3D.new()
	# Определяем цвет по типу знака
	var sign_type: String = str(tags.get("traffic_sign", ""))
	if "stop" in sign_type.to_lower():
		sign_mat.albedo_color = Color(0.9, 0.1, 0.1)  # Красный
	elif "yield" in sign_type.to_lower() or "give_way" in sign_type.to_lower():
		sign_mat.albedo_color = Color(0.9, 0.9, 0.1)  # Жёлтый
	elif "speed" in sign_type.to_lower():
		sign_mat.albedo_color = Color(0.95, 0.95, 0.95)  # Белый с красной каймой
	else:
		sign_mat.albedo_color = Color(0.2, 0.4, 0.8)  # Синий (информационный)

	sign_plate.material_override = sign_mat
	sign_plate.position.y = 2.3
	sign_plate.rotation.x = PI / 2  # Повернуть горизонтально
	sign_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(sign_plate)

	parent.add_child(body)


# Создание уличного фонаря - PHASE 2: сразу добавляет в batch (без очереди!)
func _create_street_lamp(pos: Vector2, elevation: float, parent: Node3D, direction_to_road: Vector2 = Vector2.ZERO) -> void:
	# Проверяем, не создан ли уже фонарь в этой позиции (округляем до метров)
	var pos_key := "%d_%d" % [int(pos.x), int(pos.y)]
	if _created_lamp_positions.has(pos_key):
		return
	_created_lamp_positions[pos_key] = true

	# PHASE 2: Добавляем в очередь для создания по одному фонарю за кадр
	# Каждый фонарь будет MultiMesh (pole+arm+globe), но БЕЗ батчинга
	_infrastructure_queue.append({
		"type": "lamp",
		"pos": pos,
		"elevation": elevation,
		"parent": parent,
		"direction": direction_to_road
	})


# Немедленное создание фонаря (вызывается из очереди инфраструктуры)
func _create_street_lamp_immediate(pos: Vector2, elevation: float, parent: Node3D, direction_to_road: Vector2 = Vector2.ZERO) -> void:
	if not is_instance_valid(parent) or not _lamp_model_mesh:
		return

	var angle_to_road := 0.0
	if direction_to_road.length() > 0.1:
		angle_to_road = atan2(direction_to_road.x, direction_to_road.y) - PI / 2

	var lamp_pos := Vector3(pos.x, elevation, pos.y)

	var lamp_root := Node3D.new()
	lamp_root.name = "StreetLamp"
	lamp_root.position = lamp_pos
	lamp_root.rotation.y = angle_to_road

	# Single MultiMesh with lamp model (1 instance)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _lamp_model_mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)

	var mm_inst := MultiMeshInstance3D.new()
	mm_inst.multimesh = mm
	mm_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	lamp_root.add_child(mm_inst)

	# Collision for the pole
	var col := _create_lamp_collision(Transform3D.IDENTITY)
	lamp_root.add_child(col)

	# OmniLight3D
	var is_broken := randf() < 0.05
	var is_night := _is_night_mode
	var lamp_light := OmniLight3D.new()
	lamp_light.position = _lamp_light_offset
	lamp_light.omni_range = 12.0
	lamp_light.omni_attenuation = 1.2
	lamp_light.light_energy = 1.5
	lamp_light.light_color = Color(1.0, 0.65, 0.2)
	lamp_light.shadow_enabled = false
	lamp_light.light_bake_mode = Light3D.BAKE_DISABLED
	lamp_light.visible = is_night and not is_broken
	lamp_light.set_meta("is_broken", is_broken)
	lamp_root.add_child(lamp_light)
	_lamp_batch_lights.append(lamp_light)

	parent.add_child(lamp_root)

	if _draw_call_logging_enabled:
		_draw_call_stats["lamps"] += 1


# Создание автобусной остановки
func _create_bus_stop(pos: Vector2, elevation: float, tags: Dictionary, parent: Node3D) -> void:
	# Дедупликация
	var pos_key := "bs_%d_%d" % [int(pos.x), int(pos.y)]
	if _created_bus_stop_positions.has(pos_key):
		return
	_created_bus_stop_positions[pos_key] = true

	# Находим направление к ближайшей дороге
	var road_dir := _get_direction_to_nearest_road(pos)
	var angle := atan2(road_dir.x, road_dir.y) - PI / 2.0  # -90°

	# Создаём контейнер
	var stop_root := Node3D.new()
	stop_root.name = "BusStop"
	stop_root.position = Vector3(pos.x, elevation + 1.1, pos.y)  # +1.1м над землёй
	stop_root.rotation.y = angle

	# Инстанцируем модель
	var model := BUS_STOP_SCENE.instantiate()
	model.scale = Vector3(0.1, 0.1, 0.1)
	stop_root.add_child(model)

	parent.add_child(stop_root)


func _get_direction_to_nearest_road(pos: Vector2) -> Vector2:
	"""Находит направление К ближайшей дороге (перпендикуляр)"""
	if _road_segments.is_empty():
		return Vector2(0, 1)  # По умолчанию - на север

	var min_dist := INF
	var best_dir := Vector2(0, 1)

	for seg in _road_segments:
		var road_p1: Vector2 = seg.p1
		var road_p2: Vector2 = seg.p2
		var road_vec: Vector2 = road_p2 - road_p1
		var road_len: float = road_vec.length()
		if road_len < 0.1:
			continue

		# Проекция точки на отрезок дороги
		var t: float = clamp((pos - road_p1).dot(road_vec) / (road_len * road_len), 0.0, 1.0)
		var closest: Vector2 = road_p1 + road_vec * t
		var dist: float = pos.distance_to(closest)

		if dist < min_dist:
			min_dist = dist
			# Направление ОТ остановки К дороге
			if dist > 0.1:
				best_dir = (closest - pos).normalized()
			else:
				# Если на дороге - перпендикуляр к дороге
				best_dir = Vector2(-road_vec.y, road_vec.x).normalized()

	return best_dir


# Процедурная генерация деревьев в полигоне (парк, лес) - добавляет в очередь
func _generate_trees_in_polygon(points: PackedVector2Array, parent: Node3D, dense: bool = false) -> void:
	if points.size() < 3:
		return

	# Добавляем в очередь растительности для обработки по кадрам
	_vegetation_queue.append({
		"type": "trees",
		"points": points,
		"parent": parent,
		"dense": dense
	})


# === Потокобезопасные функции поиска (для воркер-тредов) ===

func _is_point_near_road_threadsafe(point: Vector2, min_distance: float, road_hash: Dictionary) -> bool:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not road_hash.has(key):
				continue
			for seg in road_hash[key]:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				if point.distance_to(closest) < (seg.width / 2.0) + min_distance:
					return true
	return false


func _is_point_near_building_threadsafe(point: Vector2, min_distance: float, building_hash: Dictionary) -> bool:
	var cell_x := int(floor(point.x / BUILDING_CELL_SIZE))
	var cell_y := int(floor(point.y / BUILDING_CELL_SIZE))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not building_hash.has(key):
				continue
			for seg in building_hash[key]:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				if point.distance_to(closest) < min_distance:
					return true
	return false


func _is_point_in_any_parking_threadsafe(point: Vector2, parking_hash: Dictionary, parking_polys: Array) -> bool:
	const PARKING_BUFFER := 10.0
	var cell_x := int(floor(point.x / PARKING_CELL_SIZE))
	var cell_y := int(floor(point.y / PARKING_CELL_SIZE))
	var checked_polygons: Dictionary = {}
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not parking_hash.has(key):
				continue
			for entry in parking_hash[key]:
				var pidx: int = entry.idx
				var closest := Geometry2D.get_closest_point_to_segment(point, entry.p1, entry.p2)
				if point.distance_to(closest) < PARKING_BUFFER:
					return true
				if not checked_polygons.has(pidx):
					checked_polygons[pidx] = true
					if pidx < parking_polys.size():
						var parking: PackedVector2Array = parking_polys[pidx]
						if parking.size() >= 3 and Geometry2D.is_point_in_polygon(point, parking):
							return true
	return false


func _compute_trees_thread(task_data: Dictionary) -> void:
	var points: PackedVector2Array = task_data.points
	var dense: bool = task_data.dense
	var chunk_key: String = task_data.chunk_key
	var t_chunk_size: float = task_data.chunk_size
	var road_hash: Dictionary = task_data.road_spatial_hash

	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y
	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y
	var area := width * height

	const TREE_DENSITY_FOREST := 0.012
	const TREE_DENSITY_PARK := 0.005
	const MAX_TREES_PER_POLYGON := 600

	var density := TREE_DENSITY_FOREST if dense else TREE_DENSITY_PARK
	var max_trees := mini(int(area * density), MAX_TREES_PER_POLYGON)
	if max_trees < 1:
		max_trees = 1
	var tree_count := 0

	var seed_value := int(abs(min_x * 1000 + min_y * 100 + width * 10 + height)) % 10000
	var avg_spacing := sqrt(1.0 / density)
	var estimated_trees := int(area / (avg_spacing * avg_spacing))
	estimated_trees = mini(estimated_trees, max_trees)
	var max_attempts := estimated_trees * 3

	var leaf_transforms: Array[Transform3D] = []
	var pine_transforms: Array[Transform3D] = []
	var collisions: Array[Dictionary] = []

	for i in range(max_attempts):
		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)
		var hash3 := fmod(hash1 * 17.0 + hash2 * 31.0, 1.0)
		var hash4 := fmod(hash2 * 23.0 + hash1 * 13.0, 1.0)

		var test_x := min_x + (hash1 * 0.7 + hash3 * 0.3) * width
		var test_y := min_y + (hash2 * 0.7 + hash4 * 0.3) * height
		var test_point := Vector2(test_x, test_y)

		if not Geometry2D.is_point_in_polygon(test_point, points):
			continue
		if _is_point_near_road_threadsafe(test_point, 3.0, road_hash):
			continue

		var elevation := 0.0
		var is_pine := dense and fmod(hash1 * 97.0 + hash2 * 53.0, 1.0) < PINE_MIX_RATIO

		# Детерминистичные масштаб/поворот (не randf для потокобезопасности)
		var scale_hash := fmod(float(seed_value + i * 3571) * 0.7236, 1.0)
		var rot_hash := fmod(float(seed_value + i * 6271) * 0.5413, 1.0)
		var scale_factor := 0.8 + scale_hash * 0.5
		var rotation_y := rot_hash * TAU

		var tree_pos := Vector3(test_x, elevation, test_y)
		var basis := Basis(Vector3.UP, rotation_y).scaled(Vector3(scale_factor, scale_factor, scale_factor))
		var transform := Transform3D(basis, tree_pos)

		if is_pine:
			pine_transforms.append(transform)
		else:
			leaf_transforms.append(transform)

		collisions.append({"position": tree_pos, "radius": 0.4})

		tree_count += 1
		if tree_count >= max_trees:
			break

	var result := {
		"chunk_key": chunk_key,
		"parent": task_data.parent,
		"leaf_transforms": leaf_transforms,
		"pine_transforms": pine_transforms,
		"collisions": collisions
	}

	_veg_mutex.lock()
	_veg_thread_results.append(result)
	_pending_veg_tasks -= 1
	_veg_mutex.unlock()


func _compute_chunk_trees_thread(task_data: Dictionary) -> void:
	var chunk_key: String = task_data.chunk_key
	var t_chunk_size: float = task_data.chunk_size
	var road_hash: Dictionary = task_data.road_spatial_hash
	var building_hash: Dictionary = task_data.building_spatial_hash
	var parking_hash: Dictionary = task_data.parking_spatial_hash
	var parking_polys: Array = task_data.parking_polygons

	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var min_x := chunk_x * t_chunk_size
	var min_z := chunk_z * t_chunk_size

	var avg_spacing := 10.0
	var max_trees := 250
	var tree_count := 0

	var seed_value := int(abs(chunk_x * 73856093 + chunk_z * 19349669)) % 100000
	var estimated_trees := int((t_chunk_size * t_chunk_size) / (avg_spacing * avg_spacing))
	estimated_trees = mini(estimated_trees, max_trees)

	var leaf_transforms: Array[Transform3D] = []
	var pine_transforms: Array[Transform3D] = []
	var collisions: Array[Dictionary] = []

	for i in range(estimated_trees):
		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)
		var hash3 := fmod(hash1 * 17.0 + hash2 * 31.0, 1.0)
		var hash4 := fmod(hash2 * 23.0 + hash1 * 13.0, 1.0)

		var test_x := min_x + (hash1 * 0.7 + hash3 * 0.3) * t_chunk_size
		var test_y := min_z + (hash2 * 0.7 + hash4 * 0.3) * t_chunk_size
		var test_point := Vector2(test_x, test_y)

		if _is_point_near_road_threadsafe(test_point, 2.0, road_hash):
			continue
		if _is_point_near_building_threadsafe(test_point, 2.0, building_hash):
			continue
		if _is_point_in_any_parking_threadsafe(test_point, parking_hash, parking_polys):
			continue

		var elevation := 0.0

		# Детерминистичные масштаб/поворот
		var scale_hash := fmod(float(seed_value + i * 3571) * 0.7236, 1.0)
		var rot_hash := fmod(float(seed_value + i * 6271) * 0.5413, 1.0)
		var scale_factor := 0.8 + scale_hash * 0.5
		var rotation_y := rot_hash * TAU

		var tree_pos := Vector3(test_x, elevation, test_y)
		var basis := Basis(Vector3.UP, rotation_y).scaled(Vector3(scale_factor, scale_factor, scale_factor))
		var transform := Transform3D(basis, tree_pos)

		# chunk_trees — всегда лиственные (без pine mix)
		leaf_transforms.append(transform)
		collisions.append({"position": tree_pos, "radius": 0.4})

		tree_count += 1
		if tree_count >= max_trees:
			break

	var result := {
		"chunk_key": chunk_key,
		"parent": task_data.parent,
		"leaf_transforms": leaf_transforms,
		"pine_transforms": pine_transforms,
		"collisions": collisions
	}

	_veg_mutex.lock()
	_veg_thread_results.append(result)
	_pending_veg_tasks -= 1
	_veg_mutex.unlock()


# Немедленное создание деревьев (вызывается из очереди) — LEGACY, заменено тредами
func _create_trees_immediate(points: PackedVector2Array, parent: Node3D, dense: bool = false) -> void:
	if not is_instance_valid(parent):
		return

	# Вычисляем bounding box
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y
	var area := width * height

	# Плотность от площади полигона
	const TREE_DENSITY_FOREST := 0.012  # ~120 деревьев на 100×100м
	const TREE_DENSITY_PARK := 0.005    # ~50 деревьев на 100×100м
	const MAX_TREES_PER_POLYGON := 600

	var density := TREE_DENSITY_FOREST if dense else TREE_DENSITY_PARK
	var max_trees := mini(int(area * density), MAX_TREES_PER_POLYGON)
	if max_trees < 1:
		max_trees = 1
	var tree_count := 0

	# Используем хаотичное размещение на основе хеша координат полигона
	var seed_value := int(abs(min_x * 1000 + min_y * 100 + width * 10 + height)) % 10000
	var avg_spacing := sqrt(1.0 / density)
	var estimated_trees := int(area / (avg_spacing * avg_spacing))
	estimated_trees = mini(estimated_trees, max_trees)
	# Bbox может быть гораздо больше реального полигона — увеличиваем попытки в 3x
	var max_attempts := estimated_trees * 3

	for i in range(max_attempts):
		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)

		var hash3 := fmod(hash1 * 17.0 + hash2 * 31.0, 1.0)
		var hash4 := fmod(hash2 * 23.0 + hash1 * 13.0, 1.0)

		var test_x := min_x + (hash1 * 0.7 + hash3 * 0.3) * width
		var test_y := min_y + (hash2 * 0.7 + hash4 * 0.3) * height
		var test_point := Vector2(test_x, test_y)

		var in_poly := Geometry2D.is_point_in_polygon(test_point, points)
		if not in_poly:
			continue
		if _is_point_near_road(test_point, 3.0):
			continue

		var elevation := 0.0

		# Детерминистичный выбор типа: pine ~15% в лесах
		var is_pine := dense and fmod(hash1 * 97.0 + hash2 * 53.0, 1.0) < PINE_MIX_RATIO

		var chunk_key := _get_chunk_key_from_node(parent)
		if chunk_key != "":
			_add_tree_to_batch(chunk_key, test_point, elevation, parent, is_pine)

		tree_count += 1

		if tree_count >= max_trees:
			break


# Возвращает расстояние от точки до ближайшего края дороги
# Отрицательное = внутри дороги, положительное = снаружи
func _get_distance_to_road_edge(point: Vector2) -> float:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	var min_edge_dist := 999.0

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue
			for seg in _road_spatial_hash[key]:
				var s_p1: Vector2 = seg.p1
				var s_p2: Vector2 = seg.p2
				var s_width: float = seg.width
				var closest := Geometry2D.get_closest_point_to_segment(point, s_p1, s_p2)
				var dist_to_center := point.distance_to(closest)
				var edge_dist: float = dist_to_center - s_width / 2.0
				min_edge_dist = minf(min_edge_dist, edge_dist)

	return min_edge_dist


# Проверка близости к дороге через spatial hash (быстрая версия)
func _is_point_near_road_fast(point: Vector2, min_distance: float) -> bool:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue
			for seg in _road_spatial_hash[key]:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				var dist := point.distance_to(closest)
				if dist < (seg.width / 2.0) + min_distance:
					return true

	return false


# Проверяет, находится ли точка внутри коридора автомобильной дороги (width >= 4.0)
# или внутри контура перекрёстка
# margin: запас за пределами края дороги (0 = точно по краю)
func _is_point_on_vehicle_road(point: Vector2, margin: float = 1.0) -> bool:
	# 0. Парковки: footpath поверх парковки остаётся тротуаром (не crossing)
	for poly in _parking_polygons:
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(point, poly):
			return false
	# 1. Проверка прямых участков дорог через spatial hash
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue
			for seg in _road_spatial_hash[key]:
				var s_width: float = seg.width
				if s_width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				if point.distance_to(closest) < s_width / 2.0 + margin:
					return true
	# 2. Проверка контуров перекрёстков
	for i in range(_intersection_contours.size()):
		var contour: PackedVector2Array = _intersection_contours[i]
		if contour.size() < 3:
			continue
		if i < _intersection_positions.size():
			if point.distance_to(_intersection_positions[i]) > 30.0:
				continue
		if Geometry2D.is_point_in_polygon(point, contour):
			return true
	# Парковки НЕ проверяем — пешеходные дорожки должны оставаться тротуарами поверх парковок
	return false
	return false


# Проверяет, является ли on_road участок footpath полным пересечением дороги:
# before_pt и after_pt лежат по разные стороны от ближайшей дороги.
func _is_full_road_crossing(before_pt: Vector2, after_pt: Vector2) -> bool:
	var mid := (before_pt + after_pt) * 0.5
	var cell_x := int(floor(mid.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(mid.y / ROAD_CELL_SIZE))
	var best_dist := 999.0
	var best_seg_p1 := Vector2.ZERO
	var best_seg_p2 := Vector2.ZERO
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue
			for seg in _road_spatial_hash[key]:
				if seg.width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(mid, seg.p1, seg.p2)
				var dist: float = mid.distance_to(closest)
				if dist < best_dist:
					best_dist = dist
					best_seg_p1 = seg.p1
					best_seg_p2 = seg.p2
	if best_dist > 50.0:
		return false
	var road_dir: Vector2 = (best_seg_p2 - best_seg_p1).normalized()
	var cross_before: float = road_dir.cross(before_pt - best_seg_p1)
	var cross_after: float = road_dir.cross(after_pt - best_seg_p1)
	# Разные знаки → разные стороны дороги → полное пересечение
	return cross_before * cross_after < 0.0


# Находит точку на отрезке [p1, p2], где проходит край дороги (binary search)
func _find_road_edge_point(p1: Vector2, p1_on_road: bool, p2: Vector2) -> Vector2:
	var t_lo := 0.0
	var t_hi := 1.0
	for _iter in 8:
		var t_mid := (t_lo + t_hi) / 2.0
		var p_mid := p1.lerp(p2, t_mid)
		var mid_on := _is_point_on_vehicle_road(p_mid, 0.0)
		if mid_on == p1_on_road:
			t_lo = t_mid
		else:
			t_hi = t_mid
	return p1.lerp(p2, (t_lo + t_hi) / 2.0)


# Генерирует приподнятый террейн (газон/тротуар) по контурам дорог с коллизией
func _create_chunk_ground_terrain(chunk_key: String, parent: Node3D, road_polylines: Array) -> void:
	if not is_instance_valid(parent):
		return

	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var min_x := float(chunk_x) * chunk_size
	var max_x := min_x + chunk_size
	var min_z := float(chunk_z) * chunk_size
	var max_z := min_z + chunk_size
	var sidewalk_height := 0.22  # Уровень тротуара/газона (22см — резкий бордюр)

	# 1. Прямоугольник чанка (CCW для Geometry2D)
	var chunk_rect := PackedVector2Array([
		Vector2(min_x, min_z),
		Vector2(max_x, min_z),
		Vector2(max_x, max_z),
		Vector2(min_x, max_z),
	])

	# 2. Вырезаем коридоры дорог из прямоугольника чанка
	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]

	# road_polylines — массив PackedVector2Array (полигоны-коридоры из вершин дороги)
	for corridor in road_polylines:
		if corridor.size() < 4:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		terrain_polys = new_polys

	# 2b. Вырезаем контуры перекрёстков (заплатки шире коридоров дорог)
	for i in range(_intersection_contours.size()):
		var contour: PackedVector2Array = _intersection_contours[i]
		if contour.size() < 3:
			continue
		# Проверяем что перекрёсток в пределах чанка (с запасом)
		var ipos: Vector2 = _intersection_positions[i]
		if ipos.x < min_x - 30.0 or ipos.x > max_x + 30.0 or ipos.y < min_z - 30.0 or ipos.y > max_z + 30.0:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, contour)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		terrain_polys = new_polys

	# 2c. Вырезаем парковки (на уровне дорог, не должны быть под травой)
	for parking_poly in _parking_polygons:
		if parking_poly.size() < 3:
			continue
		# Быстрая проверка — хотя бы одна точка парковки в пределах чанка
		var in_chunk := false
		for pp in parking_poly:
			if pp.x >= min_x - 5.0 and pp.x <= max_x + 5.0 and pp.y >= min_z - 5.0 and pp.y <= max_z + 5.0:
				in_chunk = true
				break
		if not in_chunk:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, parking_poly)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		terrain_polys = new_polys

	# 2d. Фильтруем мелкие осколки (slivers) от клиппинга — площадь < 2 м²
	var filtered_polys: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		if poly.size() >= 3 and absf(_polygon_area(poly)) >= 2.0:
			filtered_polys.append(poly)
	terrain_polys = filtered_polys

	if terrain_polys.is_empty():
		print("OSM: ChunkTerrain %s: no polygons after clipping" % chunk_key)
		return

	# 2e. Генерируем бордюры по внутренним краям (где террейн граничит с дорогой)
	var curb_verts := PackedVector3Array()
	var curb_norms := PackedVector3Array()
	var curb_idxs := PackedInt32Array()
	var road_level := 0.005
	var boundary_eps := 0.1

	for poly in terrain_polys:
		var pn := poly.size()
		for ei in range(pn):
			var p1: Vector2 = poly[ei]
			var p2: Vector2 = poly[(ei + 1) % pn]
			# Пропускаем края на границе чанка
			var p1_on_boundary := absf(p1.x - min_x) < boundary_eps or absf(p1.x - max_x) < boundary_eps or absf(p1.y - min_z) < boundary_eps or absf(p1.y - max_z) < boundary_eps
			var p2_on_boundary := absf(p2.x - min_x) < boundary_eps or absf(p2.x - max_x) < boundary_eps or absf(p2.y - min_z) < boundary_eps or absf(p2.y - max_z) < boundary_eps
			if p1_on_boundary and p2_on_boundary:
				continue
			# Бордюр 15×15 см в сечении: выступает наружу (к дороге) от края террейна
			var curb_w := 0.15  # ширина (к дороге)
			var curb_h := 0.15  # высота
			var h1 := 0.0
			var h2 := 0.0
			var top1 := h1 + sidewalk_height
			var top2 := h2 + sidewalk_height
			var bot1 := top1 - curb_h
			var bot2 := top2 - curb_h
			var dir := (p2 - p1).normalized()
			var outward := Vector2(dir.y, -dir.x)
			var p1_out := p1 + outward * curb_w
			var p2_out := p2 + outward * curb_w
			var n_front := Vector3(outward.x, 0.0, outward.y)
			var ci := curb_verts.size()
			# Передняя грань (вертикальная, к дороге)
			curb_verts.append(Vector3(p1_out.x, bot1, p1_out.y))  # 0
			curb_verts.append(Vector3(p2_out.x, bot2, p2_out.y))  # 1
			curb_verts.append(Vector3(p2_out.x, top2, p2_out.y))  # 2
			curb_verts.append(Vector3(p1_out.x, top1, p1_out.y))  # 3
			for _j in 4: curb_norms.append(n_front)
			# Верхняя грань (горизонтальная)
			curb_verts.append(Vector3(p1.x, top1, p1.y))          # 4
			curb_verts.append(Vector3(p2.x, top2, p2.y))          # 5
			curb_verts.append(Vector3(p2_out.x, top2, p2_out.y))  # 6
			curb_verts.append(Vector3(p1_out.x, top1, p1_out.y))  # 7
			for _j in 4: curb_norms.append(Vector3.UP)
			# Нижняя грань
			curb_verts.append(Vector3(p1_out.x, bot1, p1_out.y))  # 8
			curb_verts.append(Vector3(p2_out.x, bot2, p2_out.y))  # 9
			curb_verts.append(Vector3(p2.x, bot2, p2.y))          # 10
			curb_verts.append(Vector3(p1.x, bot1, p1.y))          # 11
			for _j in 4: curb_norms.append(Vector3.DOWN)
			# Индексы: 3 грани × 2 треугольника
			for face_off in [0, 4, 8]:
				var f: int = ci + face_off
				curb_idxs.append(f + 0)
				curb_idxs.append(f + 1)
				curb_idxs.append(f + 2)
				curb_idxs.append(f + 0)
				curb_idxs.append(f + 2)
				curb_idxs.append(f + 3)

	if curb_verts.size() > 0:
		var curb_arrays := []
		curb_arrays.resize(Mesh.ARRAY_MAX)
		curb_arrays[Mesh.ARRAY_VERTEX] = curb_verts
		curb_arrays[Mesh.ARRAY_NORMAL] = curb_norms
		curb_arrays[Mesh.ARRAY_INDEX] = curb_idxs
		var curb_mesh := ArrayMesh.new()
		curb_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, curb_arrays)
		var curb_inst := MeshInstance3D.new()
		curb_inst.name = "ChunkCurbs"
		curb_inst.mesh = curb_mesh
		curb_inst.material_override = _curb_material
		curb_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(curb_inst)

	# 3. Триангулируем все оставшиеся полигоны и собираем меш
	var all_vertices := PackedVector3Array()
	var all_uvs := PackedVector2Array()
	var all_normals := PackedVector3Array()
	var all_indices := PackedInt32Array()
	var uv_scale := 0.25
	var total_tris := 0

	for poly in terrain_polys:
		var indices := Geometry2D.triangulate_polygon(poly)
		if indices.size() < 3:
			continue
		var base_idx: int = all_vertices.size()
		for p in poly:
			var h := 0.0 + sidewalk_height
			all_vertices.append(Vector3(p.x, h, p.y))
			all_uvs.append(Vector2(p.x * uv_scale, p.y * uv_scale))
			all_normals.append(Vector3.UP)
		for idx in indices:
			all_indices.append(base_idx + idx)
		total_tris += indices.size() / 3

	if all_indices.is_empty():
		return

	print("OSM: ChunkTerrain %s: %d polys, %d verts, %d tris" % [chunk_key, terrain_polys.size(), all_vertices.size(), total_tris])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_vertices
	arrays[Mesh.ARRAY_TEX_UV] = all_uvs
	arrays[Mesh.ARRAY_NORMAL] = all_normals
	arrays[Mesh.ARRAY_INDEX] = all_indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "ChunkTerrain"
	mesh_inst.mesh = arr_mesh

	# Материал — трава
	if _ground_shader_material:
		mesh_inst.material_override = _ground_shader_material
	else:
		var fallback := StandardMaterial3D.new()
		fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
		if _ground_textures.has("grass"):
			fallback.albedo_texture = _ground_textures["grass"]
			fallback.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		else:
			fallback.albedo_color = Color(0.3, 0.5, 0.2)
		mesh_inst.material_override = fallback
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


	parent.add_child(mesh_inst)

	# 4. Коллизия — ConcavePolygonShape3D из тех же граней
	var faces := PackedVector3Array()
	for ti in range(0, all_indices.size(), 3):
		faces.append(all_vertices[all_indices[ti]])
		faces.append(all_vertices[all_indices[ti + 1]])
		faces.append(all_vertices[all_indices[ti + 2]])

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)

	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.collision_layer = 1
	var col_shape := CollisionShape3D.new()
	col_shape.shape = shape
	body.add_child(col_shape)
	parent.add_child(body)

	if _draw_call_logging_enabled:
		_draw_call_stats["terrain"] += 1


## Worker thread: выполняет тяжёлый полигон-клиппинг террейна вне main thread.
## Geometry2D thread-safe в Godot 4.x (утилитарный класс без state).
func _compute_terrain_clipping_thread(task_data: Dictionary) -> void:
	var chunk_key: String = task_data.chunk_key
	var roads: Array = task_data.road_polylines
	var contours: Array = task_data.contours
	var parking: Array = task_data.parking
	var chunk_rect: PackedVector2Array = task_data.chunk_rect

	var terrain_polys: Array[PackedVector2Array] = [chunk_rect]

	# 1. Вырезаем дорожные коридоры
	for corridor in roads:
		if corridor.size() < 4:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			for cp in clipped:
				if cp.size() >= 3:
					new_polys.append(cp)
		terrain_polys = new_polys
		if terrain_polys.is_empty():
			break

	# 2. Вырезаем контуры перекрёстков
	if not terrain_polys.is_empty():
		for contour in contours:
			if contour.size() < 3:
				continue
			var new_polys: Array[PackedVector2Array] = []
			for poly in terrain_polys:
				var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, contour)
				for cp in clipped:
					if cp.size() >= 3:
						new_polys.append(cp)
			terrain_polys = new_polys
			if terrain_polys.is_empty():
				break

	# 3. Вырезаем парковки
	if not terrain_polys.is_empty():
		for parking_poly in parking:
			if parking_poly.size() < 3:
				continue
			var new_polys: Array[PackedVector2Array] = []
			for poly in terrain_polys:
				var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, parking_poly)
				for cp in clipped:
					if cp.size() >= 3:
						new_polys.append(cp)
			terrain_polys = new_polys
			if terrain_polys.is_empty():
				break

	# 4. Финальная фильтрация мелких осколков
	var filtered_polys: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		if poly.size() >= 3 and absf(_polygon_area(poly)) >= 2.0:
			filtered_polys.append(poly)

	# Отправляем результат в main thread через mutex-protected массив
	var result := {
		"chunk_key": chunk_key,
		"terrain_polys": filtered_polys
	}
	_terrain_thread_mutex.lock()
	_terrain_thread_results.append(result)
	_terrain_thread_mutex.unlock()


## Применяет готовые результаты клиппинга террейна из worker threads (main thread).
func _apply_terrain_thread_results() -> void:
	_terrain_thread_mutex.lock()
	if _terrain_thread_results.is_empty():
		_terrain_thread_mutex.unlock()
		return
	# Забираем один результат за кадр чтобы избежать спайков
	var result: Dictionary = _terrain_thread_results.pop_front()
	_terrain_thread_mutex.unlock()

	_pending_terrain_tasks -= 1
	var chunk_key: String = result.chunk_key
	var terrain_polys: Array[PackedVector2Array] = result.terrain_polys

	var parent: Node3D = _loaded_chunks.get(chunk_key, null)
	if not parent or not is_instance_valid(parent):
		return

	if terrain_polys.is_empty():
		print("OSM: ChunkTerrain %s: no polygons after clipping" % chunk_key)
		return

	_finalize_terrain_mesh(chunk_key, parent, terrain_polys)


## Финализация террейн меша: триангуляция + бордюры + ArrayMesh + коллизия.
## Вызывается из _process_terrain_gen_queue после завершения клиппинга.
func _finalize_terrain_mesh(chunk_key: String, parent: Node3D, terrain_polys: Array[PackedVector2Array]) -> void:
	if not is_instance_valid(parent):
		return

	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var min_x := float(chunk_x) * chunk_size
	var max_x := min_x + chunk_size
	var min_z := float(chunk_z) * chunk_size
	var max_z := min_z + chunk_size
	var sidewalk_height := 0.22

	# Бордюры по внутренним краям (где террейн граничит с дорогой)
	var curb_verts := PackedVector3Array()
	var curb_norms := PackedVector3Array()
	var curb_idxs := PackedInt32Array()
	var boundary_eps := 0.1

	for poly in terrain_polys:
		var pn := poly.size()
		for ei in range(pn):
			var p1: Vector2 = poly[ei]
			var p2: Vector2 = poly[(ei + 1) % pn]
			var p1_on_boundary := absf(p1.x - min_x) < boundary_eps or absf(p1.x - max_x) < boundary_eps or absf(p1.y - min_z) < boundary_eps or absf(p1.y - max_z) < boundary_eps
			var p2_on_boundary := absf(p2.x - min_x) < boundary_eps or absf(p2.x - max_x) < boundary_eps or absf(p2.y - min_z) < boundary_eps or absf(p2.y - max_z) < boundary_eps
			if p1_on_boundary and p2_on_boundary:
				continue
			var curb_w := 0.15
			var curb_h := 0.15
			var h1 := 0.0
			var h2 := 0.0
			var top1 := h1 + sidewalk_height
			var top2 := h2 + sidewalk_height
			var bot1 := top1 - curb_h
			var bot2 := top2 - curb_h
			var dir := (p2 - p1).normalized()
			var outward := Vector2(dir.y, -dir.x)
			var p1_out := p1 + outward * curb_w
			var p2_out := p2 + outward * curb_w
			var n_front := Vector3(outward.x, 0.0, outward.y)
			var ci := curb_verts.size()
			curb_verts.append(Vector3(p1_out.x, bot1, p1_out.y))
			curb_verts.append(Vector3(p2_out.x, bot2, p2_out.y))
			curb_verts.append(Vector3(p2_out.x, top2, p2_out.y))
			curb_verts.append(Vector3(p1_out.x, top1, p1_out.y))
			for _j in 4: curb_norms.append(n_front)
			curb_verts.append(Vector3(p1.x, top1, p1.y))
			curb_verts.append(Vector3(p2.x, top2, p2.y))
			curb_verts.append(Vector3(p2_out.x, top2, p2_out.y))
			curb_verts.append(Vector3(p1_out.x, top1, p1_out.y))
			for _j in 4: curb_norms.append(Vector3.UP)
			curb_verts.append(Vector3(p1_out.x, bot1, p1_out.y))
			curb_verts.append(Vector3(p2_out.x, bot2, p2_out.y))
			curb_verts.append(Vector3(p2.x, bot2, p2.y))
			curb_verts.append(Vector3(p1.x, bot1, p1.y))
			for _j in 4: curb_norms.append(Vector3.DOWN)
			for face_off in [0, 4, 8]:
				var f: int = ci + face_off
				curb_idxs.append(f + 0)
				curb_idxs.append(f + 1)
				curb_idxs.append(f + 2)
				curb_idxs.append(f + 0)
				curb_idxs.append(f + 2)
				curb_idxs.append(f + 3)

	if curb_verts.size() > 0:
		var curb_arrays := []
		curb_arrays.resize(Mesh.ARRAY_MAX)
		curb_arrays[Mesh.ARRAY_VERTEX] = curb_verts
		curb_arrays[Mesh.ARRAY_NORMAL] = curb_norms
		curb_arrays[Mesh.ARRAY_INDEX] = curb_idxs
		var curb_mesh := ArrayMesh.new()
		curb_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, curb_arrays)
		_rs_add_mesh(chunk_key, curb_mesh, _curb_material)

	# Триангулируем полигоны
	var all_vertices := PackedVector3Array()
	var all_uvs := PackedVector2Array()
	var all_normals := PackedVector3Array()
	var all_indices := PackedInt32Array()
	var uv_scale := 0.25
	var total_tris := 0

	for poly in terrain_polys:
		var indices := Geometry2D.triangulate_polygon(poly)
		if indices.size() < 3:
			continue
		var base_idx: int = all_vertices.size()
		for p in poly:
			var h := 0.0 + sidewalk_height
			all_vertices.append(Vector3(p.x, h, p.y))
			all_uvs.append(Vector2(p.x * uv_scale, p.y * uv_scale))
			all_normals.append(Vector3.UP)
		for idx in indices:
			all_indices.append(base_idx + idx)
		total_tris += indices.size() / 3

	if all_indices.is_empty():
		return

	print("OSM: ChunkTerrain %s: %d polys, %d verts, %d tris" % [chunk_key, terrain_polys.size(), all_vertices.size(), total_tris])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_vertices
	arrays[Mesh.ARRAY_TEX_UV] = all_uvs
	arrays[Mesh.ARRAY_NORMAL] = all_normals
	arrays[Mesh.ARRAY_INDEX] = all_indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material: Material = _ground_shader_material
	if not material:
		var fallback := StandardMaterial3D.new()
		fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
		if _ground_textures.has("grass"):
			fallback.albedo_texture = _ground_textures["grass"]
			fallback.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		else:
			fallback.albedo_color = Color(0.3, 0.5, 0.2)
		material = fallback

	_rs_add_mesh(chunk_key, arr_mesh, material)

	# Коллизия — отложенная (ConcavePolygonShape3D из реальной геометрии)
	_deferred_terrain_collisions.append({
		"parent": parent,
		"vertices": all_vertices,
		"indices": all_indices
	})

	if _draw_call_logging_enabled:
		_draw_call_stats["terrain"] += 1

	# Применяем elevation если уже готов


# Генерация деревьев по всему чанку (на обычной земле, вне дорог и зданий)
func _generate_trees_for_chunk(chunk_key: String, parent: Node3D) -> void:
	if not enable_vegetation:
		return

	# Добавляем в очередь растительности для обработки по кадрам
	_vegetation_queue.append({
		"type": "chunk_trees",
		"chunk_key": chunk_key,
		"parent": parent
	})


# Немедленная генерация деревьев по всей площади чанка
func _create_chunk_trees_immediate(chunk_key: String, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var min_x := chunk_x * chunk_size
	var min_z := chunk_z * chunk_size

	var avg_spacing := 10.0  # Среднее расстояние между деревьями (метры)
	var max_trees := 250  # Максимум деревьев на чанк
	var tree_count := 0

	# Псевдорандом на основе координат чанка (используем chunk_x/chunk_z для уникальности)
	var seed_value := int(abs(chunk_x * 73856093 + chunk_z * 19349669)) % 100000

	var estimated_trees := int((chunk_size * chunk_size) / (avg_spacing * avg_spacing))
	estimated_trees = mini(estimated_trees, max_trees)

	for i in range(estimated_trees):
		var hash1 := fmod(float(seed_value + i * 7919) * 0.61803398875, 1.0)
		var hash2 := fmod(float(seed_value + i * 104729) * 0.41421356237, 1.0)

		var hash3 := fmod(hash1 * 17.0 + hash2 * 31.0, 1.0)
		var hash4 := fmod(hash2 * 23.0 + hash1 * 13.0, 1.0)

		var test_x := min_x + (hash1 * 0.7 + hash3 * 0.3) * chunk_size
		var test_y := min_z + (hash2 * 0.7 + hash4 * 0.3) * chunk_size
		var test_point := Vector2(test_x, test_y)

		# Пропускаем если близко к дороге (2м от края дороги)
		if _is_point_near_road(test_point, 2.0):
			continue

		# Пропускаем если близко к зданию (2м от стены)
		if _is_point_near_building(test_point, 2.0):
			continue

		# Пропускаем если на парковке
		if _is_point_in_any_parking(test_point):
			continue

		var elevation := 0.0
		_add_tree_to_batch(chunk_key, test_point, elevation, parent)

		tree_count += 1
		if tree_count >= max_trees:
			break


# Процедурная генерация промышленных зданий внутри территории
func _generate_industrial_buildings(points: PackedVector2Array, parent: Node3D) -> void:
	if points.size() < 4:
		return

	# Вычисляем bounding box
	var min_x := points[0].x
	var max_x := points[0].x
	var min_y := points[0].y
	var max_y := points[0].y

	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	var width := max_x - min_x
	var height := max_y - min_y

	# Пропускаем слишком маленькие территории
	if width < 20.0 or height < 20.0:
		return

	var area := width * height
	if area < 500.0:
		return

	# Генерируем 1-2 здания
	var seed_value := int(abs(min_x * 73 + min_y * 37)) % 10000
	var num_buildings := 1
	if area > 2000:
		num_buildings = 2

	var building_color := Color(0.75, 0.55, 0.4)  # Кирпичный/промышленный цвет

	for i in range(num_buildings):
		# Псевдослучайная позиция (простой хеш)
		var hash1 := fmod(float(seed_value + i * 127) * 0.618, 1.0)
		var hash2 := fmod(float(seed_value + i * 311) * 0.414, 1.0)
		var hash3 := fmod(float(seed_value + i * 541) * 0.314, 1.0)

		# Позиция в центральной части (20-80% от размера)
		var bld_x := min_x + width * (0.2 + hash1 * 0.6)
		var bld_y := min_y + height * (0.2 + hash2 * 0.6)
		var bld_center := Vector2(bld_x, bld_y)

		# Проверяем что центр внутри полигона
		if not Geometry2D.is_point_in_polygon(bld_center, points):
			continue

		# Размер здания (фиксированный, небольшой)
		var bld_width := 10.0 + hash1 * 10.0   # 10-20 м
		var bld_depth := 12.0 + hash2 * 12.0   # 12-24 м
		var bld_height := 6.0 + hash3 * 6.0    # 6-12 м

		# Создаём прямоугольный контур здания
		var half_w := bld_width / 2.0
		var half_d := bld_depth / 2.0
		var bld_points: PackedVector2Array = [
			Vector2(bld_x - half_w, bld_y - half_d),
			Vector2(bld_x + half_w, bld_y - half_d),
			Vector2(bld_x + half_w, bld_y + half_d),
			Vector2(bld_x - half_w, bld_y + half_d)
		]

		# Проверяем что все углы внутри полигона
		var all_inside := true
		for corner in bld_points:
			if not Geometry2D.is_point_in_polygon(corner, points):
				all_inside = false
				break

		if all_inside:
			var base_elev := 0.22
			_create_3d_building(bld_points, building_color, bld_height, parent, base_elev)


# Процедурная генерация фонарей вдоль дороги
func _generate_street_lamps_along_road(nodes: Array, road_width: float, parent: Node3D) -> void:
	if not enable_street_lamps or nodes.size() < 2:
		return

	var lamp_spacing := 25.0  # Расстояние между фонарями (метры)
	var lamp_offset := road_width / 2 + 1.5  # Смещение от края дороги

	var accumulated_distance := 0.0
	var last_lamp_distance := 0.0

	for i in range(nodes.size() - 1):
		var p1 := _latlon_to_local(nodes[i].lat, nodes[i].lon)
		var p2 := _latlon_to_local(nodes[i + 1].lat, nodes[i + 1].lon)

		var segment_length := p1.distance_to(p2)
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)  # Перпендикуляр

		# Проходим по сегменту и ставим фонари
		var pos_along := 0.0
		while pos_along < segment_length:
			var distance_from_last := accumulated_distance + pos_along - last_lamp_distance

			if distance_from_last >= lamp_spacing:
				# Интерполируем позицию
				var t := pos_along / segment_length
				var road_pos := p1.lerp(p2, t)

				# Ставим фонари по обе стороны дороги
				var lamp_pos_left := road_pos + perp * lamp_offset
				var lamp_pos_right := road_pos - perp * lamp_offset

				# Проверяем, не попадают ли фонари на парковку или другую дорогу
				var left_on_parking := _is_point_in_any_parking(lamp_pos_left)
				var right_on_parking := _is_point_in_any_parking(lamp_pos_right)
				var left_on_road := _is_point_near_road(lamp_pos_left, 0.0)
				var right_on_road := _is_point_near_road(lamp_pos_right, 0.0)

				var elev_left := 0.0
				var elev_right := 0.0

				# Направление к дороге (от фонаря к центру дороги)
				var dir_to_road_left := -perp  # Левый фонарь смотрит вправо (к дороге)
				var dir_to_road_right := perp   # Правый фонарь смотрит влево (к дороге)

				# NEW: Add lamps to batch instead of pending queue
				# Left lamp
				if not left_on_parking and not left_on_road:
					var lamp_3d_left := Vector3(lamp_pos_left.x, elev_left, lamp_pos_left.y)
					var chunk_x := int(floor(lamp_pos_left.x / chunk_size))
					var chunk_z := int(floor(lamp_pos_left.y / chunk_size))
					var chunk_key := "%d,%d" % [chunk_x, chunk_z]

					# Only add if chunk is loaded
					if _loaded_chunks.has(chunk_key):
						var chunk_parent: Node3D = _loaded_chunks[chunk_key]
						_add_lamp_to_batch(chunk_key, lamp_3d_left, Vector3(dir_to_road_left.x, 0, dir_to_road_left.y), chunk_parent)

				# Right lamp
				if not right_on_parking and not right_on_road:
					var lamp_3d_right := Vector3(lamp_pos_right.x, elev_right, lamp_pos_right.y)
					var chunk_x := int(floor(lamp_pos_right.x / chunk_size))
					var chunk_z := int(floor(lamp_pos_right.y / chunk_size))
					var chunk_key := "%d,%d" % [chunk_x, chunk_z]

					# Only add if chunk is loaded
					if _loaded_chunks.has(chunk_key):
						var chunk_parent: Node3D = _loaded_chunks[chunk_key]
						_add_lamp_to_batch(chunk_key, lamp_3d_right, Vector3(dir_to_road_right.x, 0, dir_to_road_right.y), chunk_parent)

				last_lamp_distance = accumulated_distance + pos_along

			pos_along += lamp_spacing / 4  # Проверяем чаще для точности

		accumulated_distance += segment_length


## Incremental lamp generation: processes segments from start_seg_idx, returns last processed segment index.
## Respects time budget (budget_usec from budget_start).
func _generate_street_lamps_incremental(local_points: PackedVector2Array, road_width: float, parent: Node3D, start_seg_idx: int, budget_start: int, budget_usec: int) -> int:
	if not enable_street_lamps or local_points.size() < 2:
		return local_points.size()

	var lamp_spacing := 25.0
	var lamp_offset := road_width / 2 + 1.5
	var n_pts: int = local_points.size()

	# Pre-compute cumulative distances (fast, needed for correct spacing)
	var cumulative := PackedFloat64Array()
	cumulative.resize(n_pts)
	cumulative[0] = 0.0
	for i in range(1, n_pts):
		cumulative[i] = cumulative[i - 1] + local_points[i - 1].distance_to(local_points[i])
	var total_length: float = cumulative[n_pts - 1]

	# Calculate starting lamp distance based on start_seg_idx
	var start_dist: float = cumulative[start_seg_idx]
	var next_lamp_dist: float = start_dist
	if next_lamp_dist < lamp_spacing:
		next_lamp_dist = lamp_spacing
	else:
		next_lamp_dist = ceil(start_dist / lamp_spacing) * lamp_spacing

	var seg_idx: int = start_seg_idx
	var last_processed_seg: int = start_seg_idx

	while next_lamp_dist < total_length:
		# Budget check every few lamps
		if (Time.get_ticks_usec() - budget_start) > budget_usec:
			return last_processed_seg

		# Find which segment this distance falls on
		while seg_idx < n_pts - 2 and cumulative[seg_idx + 1] < next_lamp_dist:
			seg_idx += 1

		last_processed_seg = seg_idx
		var seg_start_dist: float = cumulative[seg_idx]
		var seg_end_dist: float = cumulative[seg_idx + 1]
		var seg_length: float = seg_end_dist - seg_start_dist
		if seg_length < 0.001:
			next_lamp_dist += lamp_spacing
			continue

		var t: float = (next_lamp_dist - seg_start_dist) / seg_length
		var p1: Vector2 = local_points[seg_idx]
		var p2: Vector2 = local_points[seg_idx + 1]
		var road_pos: Vector2 = p1.lerp(p2, t)
		var dir: Vector2 = (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)

		var lamp_pos_left := road_pos + perp * lamp_offset
		var lamp_pos_right := road_pos - perp * lamp_offset

		if not _is_point_in_any_parking(lamp_pos_left) and not _is_point_near_road(lamp_pos_left, 0.0):
			var chunk_x := int(floor(lamp_pos_left.x / chunk_size))
			var chunk_z := int(floor(lamp_pos_left.y / chunk_size))
			var chunk_key := "%d,%d" % [chunk_x, chunk_z]
			if _loaded_chunks.has(chunk_key):
				_add_lamp_to_batch(chunk_key, Vector3(lamp_pos_left.x, 0.0, lamp_pos_left.y), Vector3(-perp.x, 0, -perp.y), _loaded_chunks[chunk_key])

		if not _is_point_in_any_parking(lamp_pos_right) and not _is_point_near_road(lamp_pos_right, 0.0):
			var chunk_x := int(floor(lamp_pos_right.x / chunk_size))
			var chunk_z := int(floor(lamp_pos_right.y / chunk_size))
			var chunk_key := "%d,%d" % [chunk_x, chunk_z]
			if _loaded_chunks.has(chunk_key):
				_add_lamp_to_batch(chunk_key, Vector3(lamp_pos_right.x, 0.0, lamp_pos_right.y), Vector3(perp.x, 0, perp.y), _loaded_chunks[chunk_key])

		next_lamp_dist += lamp_spacing

	return n_pts  # Fully processed


# Fast variant: accepts pre-computed local_points
func _generate_street_lamps_fast(local_points: PackedVector2Array, road_width: float, parent: Node3D) -> void:
	if not enable_street_lamps or local_points.size() < 2:
		return

	var lamp_spacing := 25.0
	var lamp_offset := road_width / 2 + 1.5

	# Pre-compute total road length and cumulative distances
	var n_pts: int = local_points.size()
	var cumulative := PackedFloat64Array()
	cumulative.resize(n_pts)
	cumulative[0] = 0.0
	for i in range(1, n_pts):
		cumulative[i] = cumulative[i - 1] + local_points[i - 1].distance_to(local_points[i])
	var total_length: float = cumulative[n_pts - 1]

	# Place lamps at exact spacing intervals along the polyline
	var next_lamp_dist := lamp_spacing  # Skip first point
	var seg_idx := 0

	while next_lamp_dist < total_length:
		# Find which segment this distance falls on
		while seg_idx < n_pts - 2 and cumulative[seg_idx + 1] < next_lamp_dist:
			seg_idx += 1

		var seg_start_dist: float = cumulative[seg_idx]
		var seg_end_dist: float = cumulative[seg_idx + 1]
		var seg_length: float = seg_end_dist - seg_start_dist
		if seg_length < 0.001:
			next_lamp_dist += lamp_spacing
			continue

		var t: float = (next_lamp_dist - seg_start_dist) / seg_length
		var p1: Vector2 = local_points[seg_idx]
		var p2: Vector2 = local_points[seg_idx + 1]
		var road_pos: Vector2 = p1.lerp(p2, t)
		var dir: Vector2 = (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)

		var lamp_pos_left := road_pos + perp * lamp_offset
		var lamp_pos_right := road_pos - perp * lamp_offset

		# Check left side
		if not _is_point_in_any_parking(lamp_pos_left) and not _is_point_near_road(lamp_pos_left, 0.0):
			var chunk_x := int(floor(lamp_pos_left.x / chunk_size))
			var chunk_z := int(floor(lamp_pos_left.y / chunk_size))
			var chunk_key := "%d,%d" % [chunk_x, chunk_z]
			if _loaded_chunks.has(chunk_key):
				_add_lamp_to_batch(chunk_key, Vector3(lamp_pos_left.x, 0.0, lamp_pos_left.y), Vector3(-perp.x, 0, -perp.y), _loaded_chunks[chunk_key])

		# Check right side
		if not _is_point_in_any_parking(lamp_pos_right) and not _is_point_near_road(lamp_pos_right, 0.0):
			var chunk_x := int(floor(lamp_pos_right.x / chunk_size))
			var chunk_z := int(floor(lamp_pos_right.y / chunk_size))
			var chunk_key := "%d,%d" % [chunk_x, chunk_z]
			if _loaded_chunks.has(chunk_key):
				_add_lamp_to_batch(chunk_key, Vector3(lamp_pos_right.x, 0.0, lamp_pos_right.y), Vector3(perp.x, 0, perp.y), _loaded_chunks[chunk_key])

		next_lamp_dist += lamp_spacing


func _generate_manholes_along_road(nodes: Array, road_width: float, parent: Node3D) -> void:
	"""Генерирует люки вдоль дороги каждые manhole_spacing метров"""
	if not enable_manholes or nodes.size() < 2:
		return

	if not _manhole_albedo or not _manhole_normal:
		return

	var accumulated := 0.0
	var last_manhole := 0.0
	var offset := road_width / 2.0 - 0.7  # 0.7м от правого края (за бордюром)

	for i in range(nodes.size() - 1):
		var p1 := _latlon_to_local(nodes[i].lat, nodes[i].lon)
		var p2 := _latlon_to_local(nodes[i + 1].lat, nodes[i + 1].lon)
		var segment_len := p1.distance_to(p2)
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)  # Перпендикуляр (влево)

		var pos_along := 0.0
		while pos_along < segment_len:
			if accumulated + pos_along - last_manhole >= manhole_spacing:
				var t := pos_along / segment_len
				var road_pos := p1.lerp(p2, t)
				var manhole_pos := road_pos - perp * offset  # Вправо от центра

				var elev := 0.0
				_create_manhole_decal(manhole_pos, elev, randf() * TAU, parent)
				last_manhole = accumulated + pos_along

			pos_along += 50.0  # Шаг проверки

		accumulated += segment_len


# Fast variant: accepts pre-computed local_points
func _generate_manholes_fast(local_points: PackedVector2Array, road_width: float, parent: Node3D) -> void:
	if not enable_manholes or local_points.size() < 2:
		return
	if not _manhole_albedo or not _manhole_normal:
		return

	var accumulated := 0.0
	var last_manhole := 0.0
	var offset := road_width / 2.0 - 0.7

	for i in range(local_points.size() - 1):
		var p1: Vector2 = local_points[i]
		var p2: Vector2 = local_points[i + 1]
		var segment_len := p1.distance_to(p2)
		var dir := (p2 - p1).normalized()
		var perp := Vector2(-dir.y, dir.x)

		var pos_along := 0.0
		while pos_along < segment_len:
			if accumulated + pos_along - last_manhole >= manhole_spacing:
				var t := pos_along / segment_len
				var road_pos := p1.lerp(p2, t)
				var manhole_pos := road_pos - perp * offset

				_create_manhole_decal(manhole_pos, 0.0, randf() * TAU, parent)
				last_manhole = accumulated + pos_along

			pos_along += 50.0

		accumulated += segment_len


var _manhole_count := 0  # Debug counter
var _manhole_positions := {}  # Трекинг позиций для дедупликации

func _create_manhole_decal(pos: Vector2, elevation: float, rotation: float, parent: Node3D) -> void:
	"""Создаёт Decal люка в указанной позиции"""
	# Дедупликация: округляем позицию до 1м и проверяем
	var key := "%d_%d" % [int(pos.x), int(pos.y)]
	if _manhole_positions.has(key):
		return
	_manhole_positions[key] = true
	var decal := Decal.new()
	decal.position = Vector3(pos.x, elevation + 0.5, pos.y)
	decal.rotation.y = rotation
	decal.size = Vector3(0.93, 1.0, 0.93)

	decal.texture_albedo = _manhole_albedo
	decal.texture_normal = _manhole_normal

	decal.distance_fade_enabled = true
	decal.distance_fade_begin = 80.0
	decal.distance_fade_length = 20.0

	parent.add_child(decal)
	_manhole_count += 1
	if _manhole_count <= 5 or _manhole_count % 50 == 0:
		print("OSM Manholes: created #%d at (%.1f, %.1f)" % [_manhole_count, pos.x, pos.y])


# === RESIDENTIAL ENTRANCES BATCH SYSTEM ===

func _add_residential_entrances(points: PackedVector2Array, parent: Node3D, base_elev: float, way_id: int) -> void:
	"""Добавляет подъезды для здания если они есть в building_overrides"""
	var override = _decoration_layer.get_building_override_for_way(way_id)
	if not override or override.entrances.is_empty():
		return

	var chunk_key := _get_chunk_key_from_node(parent)
	if chunk_key.is_empty():
		var center := _get_polygon_center(points)
		var cx := int(floor(center.x / chunk_size))
		var cz := int(floor(center.y / chunk_size))
		chunk_key = "%d,%d" % [cx, cz]

	# Инициализируем batch
	if not _entrance_batch.has(chunk_key):
		_entrance_batch[chunk_key] = {"parent": parent, "collisions": [], "lights": []}
		for key in ResidentialEntranceScript.MATERIAL_KEYS:
			_entrance_batch[chunk_key][key] = {
				"vertices": PackedVector3Array(),
				"normals": PackedVector3Array(),
				"indices": PackedInt32Array()
			}

	for entrance_data in override.entrances:
		var lat: float = entrance_data.get("lat", 0.0)
		var lon: float = entrance_data.get("lon", 0.0)
		if lat == 0.0 or lon == 0.0:
			continue

		var entrance_pos := _latlon_to_local(lat, lon)
		var wall := _find_closest_wall_to_point(points, entrance_pos, 3.0)
		if wall.is_empty():
			print("OSM Entrances: no wall found for entrance at (%.6f, %.6f)" % [lat, lon])
			continue

		var elev := 0.0
		var world_pos := Vector3(wall.closest_point.x, elev, wall.closest_point.y)
		var rotation_y: float = atan2(wall.normal.x, wall.normal.z)

		# Генерируем геометрию
		var geo := ResidentialEntranceScript.generate_entrance_geometry(world_pos, rotation_y)

		# Мержим в batch
		var batch: Dictionary = _entrance_batch[chunk_key]
		for key in ResidentialEntranceScript.MATERIAL_KEYS:
			var src: Dictionary = geo[key]
			var dst: Dictionary = batch[key]
			if src["vertices"].size() == 0:
				continue
			var offset: int = dst["vertices"].size()
			dst["vertices"].append_array(src["vertices"])
			dst["normals"].append_array(src["normals"])
			# Смещаем индексы
			for idx in src["indices"]:
				dst["indices"].append(idx + offset)

		# Коллизии
		batch["collisions"].append_array(geo["collisions"])

		# Позиции светильников
		if geo.has("lights"):
			batch["lights"].append_array(geo["lights"])

		print("OSM Entrances: added entrance at (%.1f, %.1f) for way %d, chunk_key=%s" % [wall.closest_point.x, wall.closest_point.y, way_id, chunk_key])


func _finalize_entrance_batch(chunk_key: String) -> void:
	"""Финализирует batch подъездов для чанка — один ArrayMesh с 5 surfaces"""
	if not _entrance_batch.has(chunk_key):
		return

	var batch: Dictionary = _entrance_batch[chunk_key]
	var parent: Node3D = batch.get("parent")

	if not parent or not is_instance_valid(parent):
		_entrance_batch.erase(chunk_key)
		return

	var materials := ResidentialEntranceScript.get_materials()
	var arr_mesh := ArrayMesh.new()
	var has_geometry := false

	for key in ResidentialEntranceScript.MATERIAL_KEYS:
		var geo: Dictionary = batch[key]
		if geo["vertices"].size() == 0:
			continue

		# Генерируем tangent массив из нормалей (нужен для корректного освещения)
		var norms_arr: PackedVector3Array = geo["normals"]
		var tangent_data := PackedFloat32Array()
		tangent_data.resize(norms_arr.size() * 4)
		for i in range(norms_arr.size()):
			var n: Vector3 = norms_arr[i]
			var tangent: Vector3
			if abs(n.y) < 0.9:
				tangent = n.cross(Vector3.UP).normalized()
			else:
				tangent = n.cross(Vector3.RIGHT).normalized()
			tangent_data[i * 4] = tangent.x
			tangent_data[i * 4 + 1] = tangent.y
			tangent_data[i * 4 + 2] = tangent.z
			tangent_data[i * 4 + 3] = 1.0

		# Dummy UV — StandardMaterial3D требует UV для корректного TBN-освещения
		var vert_count: int = geo["vertices"].size()
		var dummy_uv := PackedVector2Array()
		dummy_uv.resize(vert_count)
		for i in range(vert_count):
			dummy_uv[i] = Vector2.ZERO

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = geo["vertices"]
		arrays[Mesh.ARRAY_NORMAL] = geo["normals"]
		arrays[Mesh.ARRAY_INDEX] = geo["indices"]
		arrays[Mesh.ARRAY_TANGENT] = tangent_data
		arrays[Mesh.ARRAY_TEX_UV] = dummy_uv

		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, materials[key])
		has_geometry = true

	if has_geometry:
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = arr_mesh
		mesh_inst.name = "ResidentialEntrances"
		mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_inst.visibility_range_end = 200.0
		mesh_inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		parent.add_child(mesh_inst)

		# Коллизии
		var collisions: Array = batch["collisions"]
		if not collisions.is_empty():
			var body := StaticBody3D.new()
			body.collision_layer = 2
			body.collision_mask = 0
			body.name = "EntranceCollisions"
			parent.add_child(body)

			for coll in collisions:
				var shape := CollisionShape3D.new()
				var box := BoxShape3D.new()
				box.size = coll["size"]
				shape.shape = box
				shape.position = coll["center"]
				shape.rotation.y = -coll["rotation_y"]
				body.add_child(shape)

		# Светильники (OmniLight3D)
		var lights: Array = batch.get("lights", [])
		var is_night: bool = _night_mode_manager.is_night if _night_mode_manager else true
		for light_data in lights:
			var light := OmniLight3D.new()
			light.name = "EntranceLamp"
			light.position = light_data["position"]
			light.light_color = Color(1.0, 0.85, 0.6)
			light.light_energy = 2.0 if is_night else 0.0
			light.omni_range = 5.0
			light.omni_attenuation = 1.2
			light.shadow_enabled = false
			light.distance_fade_enabled = true
			light.distance_fade_begin = 100.0
			light.distance_fade_length = 20.0
			parent.add_child(light)
			_entrance_lights.append(light)

		print("OSM Entrances: finalized batch %s — %d surfaces, %d collisions, %d lights" % [
			chunk_key, arr_mesh.get_surface_count(), collisions.size(), lights.size()])

	_entrance_batch.erase(chunk_key)


func _create_pending_lamps() -> void:
	"""Создаёт отложенные фонари, фильтруя те что на парковках"""
	print("OSM: _create_pending_lamps started, count=%d" % _pending_lamps.size())
	if _pending_lamps.is_empty():
		print("OSM: No pending lamps")
		return

	var created := 0
	var skipped := 0

	for lamp_data in _pending_lamps:
		var pos: Vector2 = lamp_data.pos
		var elev: float = lamp_data.elev
		var dir: Vector2 = lamp_data.dir

		# Находим ПРАВИЛЬНЫЙ чанк для этого фонаря по его позиции
		var chunk_x := int(floor(pos.x / chunk_size))
		var chunk_z := int(floor(pos.y / chunk_size))
		var chunk_key := "%d,%d" % [chunk_x, chunk_z]

		# Проверяем что чанк загружен
		if not _loaded_chunks.has(chunk_key):
			skipped += 1
			continue

		var parent: Node3D = _loaded_chunks[chunk_key]

		# Проверяем что фонарь не на парковке
		if _is_point_in_any_parking(pos):
			skipped += 1
			continue

		# Проверяем что фонарь не на дороге (с небольшим запасом)
		if _is_point_on_road(pos, 0.5):
			skipped += 1
			continue

		_create_street_lamp(pos, elev, parent, dir)
		created += 1

	if created > 0:
		print("OSM: Created %d lamps, skipped %d (added to infrastructure queue)" % [created, skipped])
	_pending_lamps.clear()
	_lamps_created = true  # Флаг только для начальной загрузки

	# PHASE 2: Без батчинга - фонари создаются по одному из infrastructure queue


func _create_pending_parking_signs() -> void:
	"""Создаёт отложенные знаки парковки (теперь все дороги известны)"""
	print("OSM: _create_pending_parking_signs started, count=%d, road_segments=%d" % [_pending_parking_signs.size(), _road_segments.size()])

	var created := 0
	for sign_data in _pending_parking_signs:
		var points: PackedVector2Array = sign_data.points
		var parent: Node3D = sign_data.parent

		var sign_result = _find_parking_sign_position(points)
		if sign_result.is_empty():
			continue

		var sign_pos: Vector2 = sign_result.position
		var sign_rotation: float = sign_result.rotation
		var base_elev = 0.0

		_create_parking_sign(sign_pos, base_elev, sign_rotation, parent)
		created += 1

	print("OSM: Created %d parking signs" % created)
	_pending_parking_signs.clear()


func _is_point_in_any_parking(point: Vector2) -> bool:
	const PARKING_BUFFER := 10.0
	var cell_x := int(floor(point.x / PARKING_CELL_SIZE))
	var cell_y := int(floor(point.y / PARKING_CELL_SIZE))

	# Collect nearby parking polygon indices via spatial hash
	var checked_polygons: Dictionary = {}  # idx → true
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _parking_spatial_hash.has(key):
				continue
			for entry in _parking_spatial_hash[key]:
				var pidx: int = entry.idx
				# Check edge distance
				var closest := Geometry2D.get_closest_point_to_segment(point, entry.p1, entry.p2)
				if point.distance_to(closest) < PARKING_BUFFER:
					return true
				# Also check if point is inside the polygon (only once per polygon)
				if not checked_polygons.has(pidx):
					checked_polygons[pidx] = true
					if pidx < _parking_polygons.size():
						var parking: PackedVector2Array = _parking_polygons[pidx]
						if parking.size() >= 3 and Geometry2D.is_point_in_polygon(point, parking):
							return true
	return false


func _is_point_near_road(point: Vector2, min_distance: float) -> bool:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue
			for seg in _road_spatial_hash[key]:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				var dist := point.distance_to(closest)
				if dist < (seg.width / 2.0) + min_distance:
					return true

	return false


func _is_point_near_any_parking(point: Vector2, max_distance: float) -> bool:
	"""Проверяет, находится ли точка близко к любой парковке"""
	for parking in _parking_polygons:
		if parking.size() < 3:
			continue

		# Вычисляем центр парковки
		var center := Vector2.ZERO
		for p in parking:
			center += p
		center /= parking.size()

		# Максимальное расстояние от центра до угла
		var max_radius := 0.0
		for p in parking:
			max_radius = max(max_radius, center.distance_to(p))

		# Быстрая отсечка
		if point.distance_to(center) > max_radius + max_distance + 5.0:
			continue

		# Проверяем внутри
		if Geometry2D.is_point_in_polygon(point, parking):
			return true

		# Проверяем расстояние до каждого ребра
		for i in range(parking.size()):
			var p1: Vector2 = parking[i]
			var p2: Vector2 = parking[(i + 1) % parking.size()]

			var edge: Vector2 = p2 - p1
			var edge_len_sq: float = edge.length_squared()
			if edge_len_sq < 0.0001:
				continue

			var t: float = clamp((point - p1).dot(edge) / edge_len_sq, 0.0, 1.0)
			var closest: Vector2 = p1 + edge * t

			if point.distance_to(closest) < max_distance:
				return true

	return false


# Создание светофора на перекрёстке
func _create_traffic_light(pos: Vector2, elevation: float, parent: Node3D) -> void:
	if not enable_traffic_lights:
		return
	# Смещаем светофор с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "traffic_light",
		"pos": safe_pos,
		"elevation": elevation,
		"parent": parent
	})


# Немедленное создание светофора (вызывается из очереди)
func _create_traffic_light_immediate(pos: Vector2, elevation: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	var traffic_light := Node3D.new()
	traffic_light.name = "TrafficLight"
	traffic_light.position = Vector3(pos.x, elevation, pos.y)

	# Столб - тёмно-серый
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.1
	pole_mesh.height = 4.5
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.2, 0.2, 0.2)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 2.25
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	traffic_light.add_child(pole)

	# Корпус светофора - чёрный бокс
	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(0.35, 1.0, 0.25)
	box.mesh = box_mesh

	var box_mat := StandardMaterial3D.new()
	box_mat.albedo_color = Color(0.1, 0.1, 0.1)
	box.material_override = box_mat
	box.position.y = 4.2
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	traffic_light.add_child(box)

	# Красный сигнал
	var red_light := MeshInstance3D.new()
	var light_mesh := SphereMesh.new()
	light_mesh.radius = 0.1
	light_mesh.height = 0.2
	red_light.mesh = light_mesh

	var red_mat := StandardMaterial3D.new()
	red_mat.albedo_color = Color(0.9, 0.1, 0.1)
	red_mat.emission_enabled = true
	red_mat.emission = Color(0.9, 0.1, 0.1)
	red_mat.emission_energy_multiplier = 0.3
	red_light.material_override = red_mat
	red_light.position = Vector3(0, 4.5, 0.13)
	traffic_light.add_child(red_light)

	# Жёлтый сигнал
	var yellow_light := MeshInstance3D.new()
	yellow_light.mesh = light_mesh

	var yellow_mat := StandardMaterial3D.new()
	yellow_mat.albedo_color = Color(0.9, 0.7, 0.1)
	yellow_light.material_override = yellow_mat
	yellow_light.position = Vector3(0, 4.2, 0.13)
	traffic_light.add_child(yellow_light)

	# Зелёный сигнал
	var green_light := MeshInstance3D.new()
	green_light.mesh = light_mesh

	var green_mat := StandardMaterial3D.new()
	green_mat.albedo_color = Color(0.1, 0.7, 0.1)
	green_mat.emission_enabled = true
	green_mat.emission = Color(0.1, 0.8, 0.1)
	green_mat.emission_energy_multiplier = 0.5
	green_light.material_override = green_mat
	green_light.position = Vector3(0, 3.9, 0.13)
	traffic_light.add_child(green_light)

	# Коллизия для столба
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0  # Статика не проверяет коллизии
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.12
	shape.height = 4.5
	collision.shape = shape
	collision.position.y = 2.25
	body.add_child(collision)
	traffic_light.add_child(body)

	parent.add_child(traffic_light)

	if _draw_call_logging_enabled:
		_draw_call_stats["traffic_lights"] += 5  # pole + box + red + yellow + green


# Создание знаков на перекрёстке (уступи дорогу)
func _create_intersection_signs(pos: Vector2, elevation: float, parent: Node3D) -> void:
	# Ставим знак немного в стороне от центра перекрёстка
	var offset := 5.0

	# 4 знака по углам перекрёстка
	var offsets: Array[Vector2] = [
		Vector2(offset, offset),
		Vector2(-offset, offset),
		Vector2(offset, -offset),
		Vector2(-offset, -offset)
	]

	for off in offsets:
		var sign_pos: Vector2 = pos + off
		# Создаём знак "Уступи дорогу" (треугольный)
		_create_yield_sign(sign_pos, elevation, parent)


# Создание знака "Уступи дорогу" - разрушаемый при столкновении
func _create_yield_sign(pos: Vector2, elevation: float, parent: Node3D) -> void:
	return  # TEMP: знаки уступи дорогу выключены
	# Смещаем знак с дороги если нужно
	var safe_pos := _move_object_off_road(pos, 0.5, 5)
	if safe_pos == Vector2.ZERO:
		# Не нашли безопасное место, пропускаем
		return

	# Проверяем на дубликаты (с учётом новой позиции)
	var pos_key := "ys_%d_%d" % [int(safe_pos.x), int(safe_pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	_created_sign_positions[pos_key] = true

	# Добавляем в очередь для отложенного создания
	_infrastructure_queue.append({
		"type": "yield_sign",
		"pos": safe_pos,
		"elevation": elevation,
		"parent": parent
	})


# Немедленное создание знака (вызывается из очереди)
func _create_yield_sign_immediate(pos: Vector2, elevation: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return

	# RigidBody3D как корневой узел для физики
	var body := RigidBody3D.new()
	body.name = "YieldSign"
	body.position = Vector3(pos.x, elevation, pos.y)
	body.collision_layer = 4  # Слой 4 - разрушаемые знаки
	body.collision_mask = 7  # Машины(1) + статика(2) + другие знаки(4)
	body.mass = 12.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.body_entered.connect(_on_sign_hit.bind(body))

	# Коллизия
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.05
	shape.height = 2.2
	collision.shape = shape
	collision.position.y = 1.1
	body.add_child(collision)

	# Столб
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.2
	pole.mesh = pole_mesh

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.5, 0.5, 0.5)
	pole_mat.metallic = 0.8
	pole.material_override = pole_mat
	pole.position.y = 1.1
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(pole)

	# Треугольный знак: красный ободок + белый центр + серая спинка
	# 1) Красный треугольник (ободок)
	var border_plate := MeshInstance3D.new()
	var border_mesh := PrismMesh.new()
	border_mesh.size = Vector3(0.5, 0.5, 0.02)
	border_plate.mesh = border_mesh
	var border_mat := StandardMaterial3D.new()
	border_mat.albedo_color = Color(0.85, 0.1, 0.1)
	border_plate.material_override = border_mat
	border_plate.position.y = 2.3
	border_plate.rotation.y = -PI / 2
	border_plate.rotation.z = PI
	border_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(border_plate)

	# 2) Белый треугольник (центр, чуть меньше, чуть впереди)
	var center_plate := MeshInstance3D.new()
	var center_mesh := PrismMesh.new()
	center_mesh.size = Vector3(0.36, 0.36, 0.02)
	center_plate.mesh = center_mesh
	var center_mat := StandardMaterial3D.new()
	center_mat.albedo_color = Color(0.95, 0.95, 0.95)
	center_plate.material_override = center_mat
	center_plate.position.y = 2.3
	center_plate.position.x = -0.02
	center_plate.rotation.y = -PI / 2
	center_plate.rotation.z = PI
	body.add_child(center_plate)

	# 3) Серая металлическая задняя сторона
	var back_plate := MeshInstance3D.new()
	var back_mesh := PrismMesh.new()
	back_mesh.size = Vector3(0.5, 0.5, 0.02)
	back_plate.mesh = back_mesh
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.55, 0.55, 0.55)
	back_mat.metallic = 0.4
	back_mat.roughness = 0.6
	back_plate.material_override = back_mat
	back_plate.position.y = 2.3
	back_plate.position.x = 0.02
	back_plate.rotation.y = -PI / 2
	back_plate.rotation.z = PI
	body.add_child(back_plate)

	parent.add_child(body)

func _extract_road_for_traffic(nodes: Array, tags: Dictionary, bridge_info: Dictionary = {}) -> void:
	"""Извлекает данные дороги в RoadNetwork для навигации NPC"""
	# Проверяем наличие TrafficManager
	if not get_parent().has_node("TrafficManager"):
		return

	var traffic_mgr = get_parent().get_node("TrafficManager")
	if not traffic_mgr.has_method("get_road_network"):
		return

	var road_network = traffic_mgr.get_road_network()
	if road_network == null:
		return

	# Конвертируем nodes в PackedVector2Array
	var local_points := PackedVector2Array()
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		local_points.append(local)

	# Определяем chunk_key по первой точке дороги
	var first_point := local_points[0]
	var chunk_x := int(floor(first_point.x / chunk_size))
	var chunk_z := int(floor(first_point.y / chunk_size))
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]

	# Получаем тип дороги
	var highway_type: String = tags.get("highway", "residential")

	# Добавляем дорожный сегмент в RoadNetwork (с информацией о мосте если есть)
	road_network.add_road_segment(local_points, highway_type, chunk_key, bridge_info)


# Fast variant: accepts pre-computed local_points
func _extract_road_for_traffic_fast(local_points: PackedVector2Array, tags: Dictionary, bridge_info: Dictionary = {}) -> void:
	if not get_parent().has_node("TrafficManager"):
		return
	var traffic_mgr = get_parent().get_node("TrafficManager")
	if not traffic_mgr.has_method("get_road_network"):
		return
	var road_network = traffic_mgr.get_road_network()
	if road_network == null:
		return

	var first_point: Vector2 = local_points[0]
	var chunk_x := int(floor(first_point.x / chunk_size))
	var chunk_z := int(floor(first_point.y / chunk_size))
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]
	var highway_type: String = tags.get("highway", "residential")
	road_network.add_road_segment(local_points, highway_type, chunk_key, bridge_info)


# === NIGHT MODE ===

var _is_wet_mode := false
var _night_mode_connected := false
var _night_mode_manager = null  # Кэш ссылки на NightModeManager (для избежания повторных поисков)
var _building_night_lights: Array[Node3D] = []  # Храним ссылки на созданные источники света

var _is_night_mode := false

func set_wet_mode(enabled: bool, is_night: bool = true) -> void:
	"""Включает/выключает мокрый асфальт для дорог"""
	_is_night_mode = is_night

	if _is_wet_mode == enabled:
		# Даже если состояние не изменилось, нужно обновить материалы если изменился день/ночь
		if enabled:
			for chunk_key in _chunk_road_materials:
				for mat in _chunk_road_materials[chunk_key]:
					_apply_wet_material(mat, enabled, is_night)
		return

	_is_wet_mode = enabled
	print("OSM: Wet mode ", "enabled" if enabled else "disabled")

	# Обновляем материалы всех загруженных дорог (tracked via _chunk_road_materials)
	for chunk_key in _chunk_road_materials:
		for mat in _chunk_road_materials[chunk_key]:
			_apply_wet_material(mat, enabled, is_night)

	# Обновляем shared ground material
	if _ground_shader_material:
		_ground_shader_material.set_shader_parameter("is_wet", enabled)
		_ground_shader_material.set_shader_parameter("is_night", is_night)


func _is_road_material(mat: Material) -> bool:
	"""Проверяет, является ли материал дорожным (не бордюр, не здание)"""
	# ShaderMaterial с нашим road shader - это дорога
	if mat is ShaderMaterial:
		# Проверяем что это наш road shader по наличию параметра is_wet
		if mat.get_shader_parameter("is_wet") != null:
			return true
		return false

	# StandardMaterial3D (fallback) - проверяем по текстуре/цвету
	if mat is StandardMaterial3D:
		# Дороги имеют текстуру или тёмный цвет асфальта
		if mat.albedo_texture:
			return true
		# Проверяем цвет - дороги обычно тёмно-серые
		var color: Color = mat.albedo_color
		if color.r < 0.5 and color.g < 0.5 and color.b < 0.5:
			return true

	return false


func _apply_wet_material(mat: Material, is_wet: bool, is_night: bool = true) -> void:
	"""Применяет свойства мокрого/сухого асфальта к материалу"""
	WetRoadMaterial.apply_wet_properties(mat, is_wet, is_night)


func _connect_to_night_mode() -> void:
	"""Подключается к NightModeManager для получения сигналов"""
	if _night_mode_connected:
		return

	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	if night_manager:
		_night_mode_manager = night_manager  # Кэшируем ссылку
		night_manager.night_mode_changed.connect(_on_night_mode_changed)
		_night_mode_connected = true
		# Если уже ночь - включаем фонари
		if night_manager.is_night:
			_on_night_mode_changed(true)


func _update_building_shadows(player_pos: Vector3) -> void:
	var shadow_dist_sq: float = _building_shadow_lod_distance * _building_shadow_lod_distance
	for chunk_key: String in _chunk_building_rs:
		var parts: PackedStringArray = chunk_key.split(",")
		var cx: float = float(parts[0]) * chunk_size + chunk_size * 0.5
		var cz: float = float(parts[1]) * chunk_size + chunk_size * 0.5
		var dx: float = player_pos.x - cx
		var dz: float = player_pos.z - cz
		var dist_sq: float = dx * dx + dz * dz
		var want_shadow: int
		if dist_sq < shadow_dist_sq:
			want_shadow = RenderingServer.SHADOW_CASTING_SETTING_ON
		else:
			want_shadow = RenderingServer.SHADOW_CASTING_SETTING_OFF
		for rid in _chunk_building_rs[chunk_key]:
			RenderingServer.instance_geometry_set_cast_shadows_setting(rid, want_shadow)


func _update_tree_shadows(player_pos: Vector3) -> void:
	var shadow_dist_sq: float = _tree_shadow_lod_distance * _tree_shadow_lod_distance
	for chunk_key: String in _chunk_tree_shadow_nodes:
		var parts: PackedStringArray = chunk_key.split(",")
		var cx: float = float(parts[0]) * chunk_size + chunk_size * 0.5
		var cz: float = float(parts[1]) * chunk_size + chunk_size * 0.5
		var dx: float = player_pos.x - cx
		var dz: float = player_pos.z - cz
		var dist_sq: float = dx * dx + dz * dz
		var want_shadow: int
		if dist_sq < shadow_dist_sq:
			want_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		else:
			want_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for node: MultiMeshInstance3D in _chunk_tree_shadow_nodes[chunk_key]:
			if is_instance_valid(node):
				node.cast_shadow = want_shadow


func _setup_render_distance() -> void:
	"""Настраивает дальность прорисовки камеры, туман и дистанции чанков"""
	# Настраиваем дистанции загрузки чанков
	# Зазор между load и unload нужен чтобы не флаттерить загрузку/выгрузку
	load_distance = render_distance + 100.0  # Загружаем чуть дальше видимости
	unload_distance = render_distance + chunk_size  # Выгружаем с запасом на chunk_size
	print("OSM: Chunk distances - load: %.0f, unload: %.0f" % [load_distance, unload_distance])

	# Настраиваем камеру
	if _camera:
		_camera.far = render_distance * 1.5  # Немного дальше тумана
		print("OSM: Camera far plane set to %.0f" % _camera.far)

	# Настраиваем тени DirectionalLight — 2 каскада PSSM, max distance = render_distance
	var dir_light := get_tree().current_scene.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	if dir_light:
		dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		dir_light.directional_shadow_max_distance = render_distance
		dir_light.directional_shadow_split_1 = 0.3
		dir_light.shadow_normal_bias = 2.0
		print("OSM: Shadow: 2 cascades, max distance %.0f, bias %.1f" % [render_distance, dir_light.shadow_normal_bias])

	# Настраиваем туман (Godot 4 использует экспоненциальный туман)
	if fog_enabled:
		var world_env := get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
		if world_env and world_env.environment:
			var env := world_env.environment
			env.fog_enabled = true
			# Плотность тумана обратно пропорциональна дальности
			# При 400м density ~= 0.002, при 100м ~= 0.008, при 800м ~= 0.001
			env.fog_density = 0.8 / render_distance
			env.fog_light_color = Color(0.7, 0.75, 0.85)  # Светло-серо-голубой
			env.fog_light_energy = 1.0
			env.fog_aerial_perspective = 0.5  # Эффект дымки на расстоянии
			print("OSM: Fog enabled (density: %.4f for %.0fm)" % [env.fog_density, render_distance])


func _on_night_mode_changed(enabled: bool) -> void:
	"""Обрабатывает переключение ночного режима"""
	print("OSM: Night mode ", "enabled" if enabled else "disabled")
	_is_night_mode = enabled

	# Ground shader night mode
	if _ground_shader_material:
		_ground_shader_material.set_shader_parameter("is_night", enabled)

	# NEW: Update lamp night mode
	_update_lamp_night_mode(enabled)

	# Обновляем все фонари и неоновые вывески
	for chunk_key in _loaded_chunks.keys():
		var chunk: Node3D = _loaded_chunks[chunk_key]
		_update_chunk_night_lights(chunk, enabled)


func _apply_night_mode_to_chunk(chunk: Node3D) -> void:
	"""Применяет текущее состояние ночного режима к чанку"""
	# Проверяем состояние ночного режима из NightModeManager
	var night_manager := get_tree().current_scene.find_child("NightModeManager", true, false)
	var is_night := false
	if night_manager:
		is_night = night_manager.is_night
	elif _is_night_mode:
		is_night = true

	if is_night:
		_update_chunk_night_lights(chunk, true)


func _update_chunk_night_lights(chunk: Node3D, night_enabled: bool) -> void:
	"""Включает/выключает ночное освещение в чанке"""
	_recursive_update_lights(chunk, night_enabled)


func _recursive_update_lights(node: Node, night_enabled: bool) -> void:
	"""Рекурсивно обновляет все источники света"""
	# Проверяем лампы уличных фонарей (SpotLight3D или OmniLight3D для совместимости)
	if node.name == "LampLight" and (node is SpotLight3D or node is OmniLight3D):
		# Проверяем не сломана ли лампа
		var is_broken: bool = node.get_meta("is_broken", false)
		# Сломанные лампы не включаются
		node.visible = night_enabled and not is_broken

	# Проверяем плафоны фонарей (LampGlobe)
	if node.name == "LampGlobe" and node is MeshInstance3D:
		var is_broken: bool = node.get_meta("is_broken", false)
		if node.material_override:
			var mat := node.material_override as StandardMaterial3D
			if mat:
				if night_enabled and not is_broken:
					mat.emission_enabled = true
					mat.emission = Color(1.0, 0.65, 0.2)
					mat.emission_energy_multiplier = 5.0
					mat.albedo_color = Color(1.0, 0.85, 0.5)  # Тёплый жёлтый
				else:
					mat.emission_enabled = false
					mat.albedo_color = Color(0.3, 0.3, 0.3)  # Серый днём

	# Проверяем неоновые вывески
	if node.name.begins_with("NeonSign"):
		node.visible = night_enabled

	# Проверяем окна (MultiMeshInstance3D с шейдером)
	if node.name.begins_with("Windows_") and node is MultiMeshInstance3D:
		var mat := node.material_override as ShaderMaterial
		if mat:
			mat.set_shader_parameter("is_night", night_enabled)

	# Рекурсивно обходим дочерние ноды
	for child in node.get_children():
		_recursive_update_lights(child, night_enabled)


# Цвета для неоновых вывесок (NFS Underground style)
const NEON_COLORS := [
	Color(1.0, 0.0, 0.4),   # Hot pink
	Color(0.0, 1.0, 0.9),   # Cyan
	Color(1.0, 0.3, 0.0),   # Orange
	Color(0.0, 0.5, 1.0),   # Blue
	Color(1.0, 1.0, 0.0),   # Yellow
	Color(0.8, 0.0, 1.0),   # Purple
	Color(0.0, 1.0, 0.3),   # Green
]


var _neon_signs_created := 0

func _add_building_night_decorations(building_mesh: MeshInstance3D, points: PackedVector2Array, building_height: float, parent: Node3D, building_elev: float = 0.0) -> void:
	"""Добавляет неоновые вывески и освещённые окна к зданию"""
	# Проверка на дублирование - ищем уже существующие окна по позиции
	var center := _get_polygon_center(points)
	var window_name := "Windows_%d" % hash(Vector2(center.x, center.y))

	# Проверяем, есть ли уже окна с таким именем в parent
	for child in parent.get_children():
		if child.name.begins_with("Windows_") or child.name.begins_with("NeonSign_"):
			# Проверяем позицию - если совпадает, пропускаем
			if child is Node3D:
				var child_pos := Vector2(child.position.x, child.position.z)
				if child_pos.distance_to(center) < 1.0:
					return  # Уже есть декорации для этого здания

	# Случайный seed на основе позиции здания
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2(center.x, center.y))

	# Размер здания
	var min_x := points[0].x
	var max_x := points[0].x
	var min_z := points[0].y
	var max_z := points[0].y
	for p in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.y)
		max_z = max(max_z, p.y)

	var building_width := max_x - min_x
	var building_depth := max_z - min_z

	# 35% шанс на неоновую вывеску
	if rng.randf() < 0.35 and building_width > 5.0:
		_add_neon_sign(center, building_height, building_width, rng, parent, building_depth, building_elev)
		_neon_signs_created += 1

	# Добавляем светящиеся окна для зданий выше 1 этажа
	if building_height > 3.5:
		_add_building_windows(points, building_height, rng, parent, building_elev)


func _add_neon_sign(center: Vector2, height: float, width: float, rng: RandomNumberGenerator, parent: Node3D, depth: float = 0.0, building_elev: float = 0.0) -> void:
	"""Добавляет неоновую вывеску на здание.
	Оптимизация: QuadMesh вместо BoxMesh, плоская структура без промежуточного Node3D,
	cast_shadow OFF, уменьшенный range OmniLight."""
	var sign_container := Node3D.new()
	sign_container.name = "NeonSign_%d" % rng.randi()

	var color: Color = NEON_COLORS[rng.randi() % NEON_COLORS.size()]

	# Размер вывески
	var sign_width := minf(width * 0.6, 5.0)
	var sign_height := rng.randf_range(1.0, 1.5)
	var sign_y := minf(height * 0.35, 5.0)

	# QuadMesh вместо BoxMesh (12 вершин → 4, не отбрасывает тень)
	var sign_mesh := MeshInstance3D.new()
	sign_mesh.name = "SignMesh"
	var quad := QuadMesh.new()
	quad.size = Vector2(sign_width, sign_height)
	sign_mesh.mesh = quad
	sign_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Материал с emission — unshaded, видимый и ночью и издалека
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 20.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	sign_mesh.material_override = mat

	# Выбираем случайную сторону
	var side := rng.randi() % 4
	var sign_offset: Vector3
	var sign_rotation := 0.0
	var actual_depth := depth if depth > 0 else width

	match side:
		0:  # Z+
			sign_offset = Vector3(0, sign_y, actual_depth / 2 + 0.15)
			sign_rotation = 0.0
		1:  # Z-
			sign_offset = Vector3(0, sign_y, -actual_depth / 2 - 0.15)
			sign_rotation = PI
		2:  # X+
			sign_offset = Vector3(width / 2 + 0.15, sign_y, 0)
			sign_rotation = PI / 2
		3:  # X-
			sign_offset = Vector3(-width / 2 - 0.15, sign_y, 0)
			sign_rotation = -PI / 2

	sign_mesh.position = sign_offset
	sign_mesh.rotation.y = sign_rotation
	sign_container.add_child(sign_mesh)

	# OmniLight с уменьшенным range (10m вместо 25m — достаточно для подсветки фасада)
	var light := OmniLight3D.new()
	light.name = "SignLight"
	var light_offset := Vector3(0, 0, 1.5).rotated(Vector3.UP, sign_rotation)
	light.position = sign_offset + light_offset
	light.omni_range = 10.0
	light.light_energy = 3.0
	light.light_color = color
	light.shadow_enabled = false
	light.light_bake_mode = Light3D.BAKE_DISABLED
	sign_container.add_child(light)

	sign_container.position = Vector3(center.x, building_elev, center.y)
	sign_container.visible = false  # Включается ночью

	parent.add_child(sign_container)

	if _draw_call_logging_enabled:
		_draw_call_stats["neon_signs"] += 1


func _add_building_windows(points: PackedVector2Array, height: float, rng: RandomNumberGenerator, parent: Node3D, building_elev: float = 0.0) -> void:
	"""Добавляет светящиеся окна по периметру здания используя MultiMesh"""
	if points.size() < 3:
		return

	# Параметры окон
	var floor_height := 3.0
	var num_floors := int(height / floor_height)
	if num_floors < 1:
		return

	var window_size := 1.2  # Квадратные окна
	var window_spacing := 2.5  # Расстояние между окнами
	var wall_offset := 0.05  # Отступ окна от стены

	# Цвета окон: тёплые-холодные и фитолампы
	var warm_cold_colors := [
		Color(1.0, 0.85, 0.5),   # Тёплый жёлтый
		Color(1.0, 0.9, 0.6),    # Жёлтый
		Color(1.0, 0.95, 0.75),  # Светло-жёлтый
		Color(0.95, 0.92, 0.85), # Тёплый белый
		Color(0.9, 0.92, 0.95),  # Нейтральный белый
		Color(0.85, 0.9, 1.0),   # Холодный белый
		Color(0.75, 0.85, 1.0),  # Холодный голубоватый
	]
	var phyto_color := Color(0.9, 0.2, 0.9)  # Фиолетовый/маджента
	var off_color := Color(0.0, 0.0, 0.0)  # Чёрный для выключенных окон

	# Случайное распределение для этого здания:
	# Выключено: 30-80%, Включено: 17-65%, Фитолампы: 3-5%
	# NOTE: Цвета генерируются независимо от времени суток
	# Shader сам решит показывать их или нет на основе is_night uniform
	var off_percent := 0.30 + rng.randf() * 0.50  # 30% - 80%
	var phyto_percent := 0.03 + rng.randf() * 0.02  # 3% - 5%
	# Включённые = остаток (17% - 65%)

	# Собираем трансформы и цвета окон
	var window_transforms: Array[Transform3D] = []
	var window_colors: Array[Color] = []

	# Определяем направление полигона для корректных нормалей (как в генерации стен)
	# Инвертируем знак чтобы окна смотрели наружу (в ту же сторону что нормали стен)
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	# Итерируем по рёбрам полигона (стенам здания)
	var num_points := points.size()
	for i in range(num_points):
		var p1 := points[i]
		var p2 := points[(i + 1) % num_points]

		# Направление и длина стены
		var wall_dir := (p2 - p1)
		var wall_length := wall_dir.length()
		if wall_length < window_spacing:
			continue  # Стена слишком короткая для окон

		wall_dir = wall_dir.normalized()

		# Нормаль стены (наружу) - учитываем направление обхода полигона
		var wall_normal := Vector2(-wall_dir.y * normal_sign, wall_dir.x * normal_sign)

		# Угол поворота окна - окно должно быть параллельно стене и смотреть наружу
		# atan2(normal.x, normal.y) даёт угол нормали относительно +Z
		var rot := atan2(wall_normal.x, wall_normal.y)

		# Количество окон на этой стене
		var num_windows := int((wall_length - window_spacing * 0.5) / window_spacing)
		if num_windows < 1:
			num_windows = 1

		# Начальный отступ от края стены
		var start_offset := (wall_length - (num_windows - 1) * window_spacing) / 2.0

		for floor_idx in range(num_floors):
			for win_idx in range(num_windows):
				# Выбор цвета: off_percent выключены, остальные - тёплые-холодные или фитолампы
				var color: Color
				var chance := rng.randf()
				if chance < off_percent:
					# Выключенные окна (остаются тёмными ночью)
					color = off_color
				elif chance < (1.0 - phyto_percent):
					# Тёплые до холодных оттенков (жёлтый -> белый)
					color = warm_cold_colors[rng.randi() % warm_cold_colors.size()]
					# Случайная яркость от 0.15 до 0.5 (храним в альфа-канале)
					color.a = 0.15 + rng.randf() * 0.35
				else:
					# Фитолампы (маджента)
					color = phyto_color
					color.a = 0.25 + rng.randf() * 0.25  # Фитолампы ярче

				# Позиция вдоль стены
				var along_wall := start_offset + win_idx * window_spacing
				var wall_pos := p1 + wall_dir * along_wall

				# Смещение наружу от стены
				var final_pos := wall_pos + wall_normal * wall_offset

				# Высота окна (building_elev + фундамент)
				var y_pos := building_elev + _get_foundation_height(points) + floor_height * 0.5 + floor_idx * floor_height

				var pos := Vector3(final_pos.x, y_pos, final_pos.y)
				var transform := Transform3D(Basis.from_euler(Vector3(0, rot, 0)), pos)
				window_transforms.append(transform)
				window_colors.append(color)

	if window_transforms.is_empty():
		return

	# OPTIMIZATION: Window Batching - накапливаем трансформы вместо создания MultiMesh
	# Один MultiMesh per chunk вместо per building (620 buildings → 1 MultiMesh)

	# Определяем chunk_key из parent
	var chunk_key := ""
	if parent.name.begins_with("Chunk_"):
		chunk_key = parent.name.substr(6)
	else:
		chunk_key = "initial"

	# Инициализируем batch data для этого чанка если ещё нет
	if not _window_batch_data.has(chunk_key):
		_window_batch_data[chunk_key] = {
			"transforms": [],
			"colors": [],
			"parent": parent.get_parent()  # ChunkRoot, а не Building
		}

	# Добавляем трансформы и цвета этого здания в чанк
	var batch: Dictionary = _window_batch_data[chunk_key]
	batch.transforms.append_array(window_transforms)
	batch.colors.append_array(window_colors)

	# MultiMesh будет создан один раз после генерации всех зданий в чанке
	# См. _finalize_window_batches_for_chunk()


## ============================================================================
## BUSINESS SIGNS (вывески для заведений)
## ============================================================================

func _add_business_signs_simple(points: PackedVector2Array, tags: Dictionary, parent: Node3D, building_height: float, base_elev: float = 0.0, loader: Node = null, way_id: int = 0) -> void:
	"""
	Добавление вывесок для заведений
	Приоритет: вход (entrance) > POI node > самая длинная стена

	Также ищет POI nodes (точечные заведения) внутри здания и создаёт для них вывески
	"""
	# BusinessSignGenerator доступен через class_name (статические функции)

	# Список заведений для создания вывесок
	var businesses_to_process: Array = []

	# 1. Если само здание - заведение с названием
	if (tags.has("amenity") or tags.has("shop")) and (tags.has("name") or tags.has("brand")):
		businesses_to_process.append({"tags": tags, "poi_position": null})

	# 2. Ищем POI nodes внутри здания
	if loader != null:
		var pois_inside = _find_pois_inside_building(points, loader)
		var skip_override = null
		if way_id > 0 and _decoration_layer:
			skip_override = _decoration_layer.get_building_override_for_way(way_id)
		for poi in pois_inside:
			var poi_id_val = poi.get("id", 0)
			if skip_override and not skip_override.skip_pois.is_empty():
				if poi_id_val in skip_override.skip_pois:
					print("BusinessSign: Skipping POI %s (suppressed by override for way %d)" % [str(poi_id_val), way_id])
					continue
			businesses_to_process.append({"tags": poi.tags, "poi_position": poi.position, "poi_id": poi_id_val})
	else:
		print("BusinessSign WARNING: loader is null, cannot search for POIs")

	if businesses_to_process.is_empty():
		return

	# Обрабатываем каждое заведение
	for business in businesses_to_process:
		var business_tags: Dictionary = business.tags
		var poi_pos = business.poi_position  # Vector2 или null
		var poi_id: int = business.get("poi_id", 0)

		var sign_text = BusinessSignGenerator.get_sign_text(business_tags)
		if sign_text == "":
			continue

		var sign_width = _calculate_sign_width(sign_text)

		var sign_position_2d: Vector2
		var wall_normal: Vector3
		var placement_method: String

		# Приоритет 1: Ищем вход для этого здания
		var entrance = {}
		if not _entrance_nodes.is_empty() and loader != null:
			entrance = _find_entrance_for_building(points, loader)

		if not entrance.is_empty():
			# Размещаем вывеску над входом
			sign_position_2d = entrance.position
			var wall_dir = (entrance.wall_p2 - entrance.wall_p1).normalized()
			wall_normal = Vector3(wall_dir.y, 0, -wall_dir.x)
			placement_method = "entrance"
		elif poi_pos != null:
			# Приоритет 2: POI node - ищем ближайшую стену к точке
			var closest_wall = _find_closest_wall_to_point(points, poi_pos, sign_width)
			if closest_wall.is_empty():
				continue
			sign_position_2d = closest_wall.closest_point
			wall_normal = closest_wall.normal
			placement_method = "poi_node"
		else:
			# Fallback: самая длинная стена
			var longest_wall = _find_longest_wall_simple(points, sign_width)
			if longest_wall.is_empty():
				continue
			sign_position_2d = (longest_wall.p1 + longest_wall.p2) / 2.0
			wall_normal = longest_wall.normal
			placement_method = "longest_wall"

		# Размещаем вывеску и входную группу
		# Для entrance и poi_node - добавляем входную группу (крыльцо с козырьком)
		var has_entrance_group = placement_method in ["entrance", "poi_node"]

		# Создаём вывеску (ограничиваем ширину для входных групп)
		var max_sign_width = EntranceGroupGenerator.get_canopy_width(2) / 2.0 if has_entrance_group else 5.5
		var sign = BusinessSignGenerator.create_sign(business_tags, max_sign_width)
		if sign.get_child_count() == 0:
			continue

		var sign_height: float
		if has_entrance_group:
			# Входная группа: низ вывески на верхе козырька
			# Высота вывески ~0.45м * scale 3.3 = ~1.5м, половина = ~0.75м
			var half_sign_height := 0.75
			sign_height = base_elev + EntranceGroupGenerator.get_canopy_top_height() + half_sign_height
		elif placement_method == "poi_node":
			# Магазин на первом этаже жилого дома - вывеска на 4м
			sign_height = base_elev + min(4.0, building_height * 0.7)
		else:
			sign_height = base_elev + building_height * 0.7

		sign.position = Vector3(sign_position_2d.x, sign_height, sign_position_2d.y)
		sign.position += wall_normal * 1.5  # Отступ от стены (вывеска масштабирована 3x)

		# Поворачиваем вывеску перпендикулярно стене
		sign.rotation.y = atan2(wall_normal.x, wall_normal.z)

		# Добавляем входную группу (крыльцо + двери + козырёк)
		if has_entrance_group:
			var entrance_group = EntranceGroupGenerator.create_entrance_group(2)
			entrance_group.position = Vector3(sign_position_2d.x, base_elev, sign_position_2d.y)
			entrance_group.rotation.y = atan2(wall_normal.x, wall_normal.z)
			entrance_group.name = "EntranceGroup_%s" % sign_text.substr(0, 10)
			# Антей: непрозрачные двери
			if poi_id == 12155325753:
				var opaque_glass := StandardMaterial3D.new()
				opaque_glass.albedo_color = Color(0.3, 0.4, 0.5, 1.0)
				opaque_glass.metallic = 0.1
				opaque_glass.roughness = 0.1
				opaque_glass.cull_mode = BaseMaterial3D.CULL_DISABLED
				entrance_group.mesh.surface_set_material(1, opaque_glass)
			parent.add_child(entrance_group)

			# Задняя стенка (от козырька до земли)
			var back_wall_colors: Array = [Color(0.85, 0.83, 0.80)]
			if poi_id == 12155325753:  # Антей
				back_wall_colors = [
					Color(0.40, 0.50, 0.78),  # синий (верх)
					Color(0.90, 0.78, 0.20),  # жёлтый
					Color(0.25, 0.72, 0.62),  # бирюзовый
					Color(0.45, 0.60, 0.38),  # зелёный (низ)
				]
			var back_wall := _create_shop_back_wall(
				EntranceGroupGenerator.get_canopy_top_height(),
				EntranceGroupGenerator.get_canopy_width(2),
				back_wall_colors)
			back_wall.position = Vector3(sign_position_2d.x, base_elev, sign_position_2d.y)
			back_wall.rotation.y = atan2(wall_normal.x, wall_normal.z)
			back_wall.name = "BackWall_%s" % sign_text.substr(0, 10)
			parent.add_child(back_wall)

		parent.add_child(sign)


func _add_shop_entrances_from_override(points: PackedVector2Array, parent: Node3D, building_height: float, base_elev: float, way_id: int) -> void:
	"""Добавляет входные группы магазинов из building_overrides (с кастомным логотипом)"""
	if not _decoration_layer or way_id <= 0:
		return
	var override = _decoration_layer.get_building_override_for_way(way_id)
	if not override or override.shop_entrances.is_empty():
		return

	for shop_data in override.shop_entrances:
		var lat: float = shop_data.get("lat", 0.0)
		var lon: float = shop_data.get("lon", 0.0)
		if lat == 0.0 or lon == 0.0:
			continue

		var entrance_pos := _latlon_to_local(lat, lon)
		var wall := _find_closest_wall_to_point(points, entrance_pos, 2.0)
		if wall.is_empty():
			print("ShopEntrance: no wall found for entrance at (%.6f, %.6f)" % [lat, lon])
			continue

		var sign_position_2d: Vector2 = wall.closest_point
		var wall_normal: Vector3 = wall.normal

		# Входная группа (крыльцо + двери + козырёк)
		var entrance_group = EntranceGroupGenerator.create_entrance_group(2)
		entrance_group.position = Vector3(sign_position_2d.x, base_elev, sign_position_2d.y)
		entrance_group.rotation.y = atan2(wall_normal.x, wall_normal.z)
		entrance_group.name = "ShopEntrance_%d" % way_id
		parent.add_child(entrance_group)

		# Вывеска с логотипом
		var sign_logo: String = shop_data.get("sign_logo", "")
		var logo_path := ""
		if sign_logo != "":
			logo_path = BusinessSignGenerator.BRAND_LOGOS_PATH + sign_logo
		var sign_root := Node3D.new()
		sign_root.name = "ShopSign_%d" % way_id
		sign_root.scale = Vector3(1.65, 1.65, 1.65)
		if logo_path != "" and ResourceLoader.exists(logo_path):
			BusinessSignGenerator._create_logo_sign(sign_root, logo_path, Color(0.6, 0.4, 0.2), 4.0)
		else:
			# Fallback: текстовая вывеска
			BusinessSignGenerator._create_text_sign(sign_root, "МАГАЗИН", Color(0.2, 0.5, 0.8), 4.0, "shop")
		# Подсветка
		var light := OmniLight3D.new()
		light.light_energy = 1.5
		light.light_color = Color(0.6, 0.4, 0.2).lightened(0.3)
		light.omni_range = 8.0
		light.position.y = -0.2
		sign_root.add_child(light)

		var half_sign_height := 0.4
		var sign_height: float = base_elev + EntranceGroupGenerator.get_canopy_top_height() + half_sign_height
		sign_root.position = Vector3(sign_position_2d.x, sign_height, sign_position_2d.y)
		sign_root.position += wall_normal * 0.75
		sign_root.rotation.y = atan2(wall_normal.x, wall_normal.z)
		parent.add_child(sign_root)

		# Задняя стенка (от козырька до земли, ShaderMaterial для корректного освещения)
		var canopy_top := EntranceGroupGenerator.get_canopy_top_height()
		var canopy_w := EntranceGroupGenerator.get_canopy_width(2)
		var back_wall_colors: Array = [Color(0.85, 0.83, 0.80)]
		var back_wall_color_arr = shop_data.get("back_wall_color", [])
		if back_wall_color_arr.size() >= 3:
			back_wall_colors = [Color(back_wall_color_arr[0], back_wall_color_arr[1], back_wall_color_arr[2])]
		var back_wall_stripes = shop_data.get("back_wall_stripes", [])
		if not back_wall_stripes.is_empty():
			back_wall_colors = []
			for s in back_wall_stripes:
				back_wall_colors.append(Color(s[0], s[1], s[2]))
		var back_wall := _create_shop_back_wall(canopy_top, canopy_w, back_wall_colors)
		back_wall.position = Vector3(sign_position_2d.x, base_elev, sign_position_2d.y)
		back_wall.rotation.y = atan2(wall_normal.x, wall_normal.z)
		back_wall.name = "ShopBackWall_%d" % way_id
		parent.add_child(back_wall)

		print("ShopEntrance: added at (%.1f, %.1f) for way %d" % [sign_position_2d.x, sign_position_2d.y, way_id])


func _add_custom_entrances_from_override(points: PackedVector2Array, parent: Node3D,
		building_height: float, base_elev: float, way_id: int) -> void:
	if not _decoration_layer or way_id <= 0:
		return
	var override = _decoration_layer.get_building_override_for_way(way_id)
	if not override or override.custom_entrances.is_empty():
		return

	for entrance_data in override.custom_entrances:
		var entrance_type: String = entrance_data.get("type", "")
		var lat: float = entrance_data.get("lat", 0.0)
		var lon: float = entrance_data.get("lon", 0.0)
		if lat == 0.0 or lon == 0.0:
			continue

		var entrance_pos := _latlon_to_local(lat, lon)
		var wall := _find_closest_wall_to_point(points, entrance_pos, 3.0)
		if wall.is_empty():
			print("CustomEntrance: no wall found for %s at (%.6f, %.6f)" % [entrance_type, lat, lon])
			continue

		var elev := 0.0
		var world_pos := Vector3(wall.closest_point.x, elev, wall.closest_point.y)
		var rotation_y: float = atan2(wall.normal.x, wall.normal.z)

		match entrance_type:
			"mars":
				_add_mars_entrance(world_pos, rotation_y, parent, entrance_data)
			_:
				push_warning("CustomEntrance: unknown type '%s'" % entrance_type)


func _add_mars_entrance(world_pos: Vector3, rotation_y: float, parent: Node3D, entrance_data: Dictionary) -> void:
	var geo := MarsEntranceGeneratorScript.generate_entrance_geometry(world_pos, rotation_y)
	var materials := MarsEntranceGeneratorScript.get_materials()

	var arr_mesh := ArrayMesh.new()
	for key in MarsEntranceGeneratorScript.MATERIAL_KEYS:
		var g: Dictionary = geo[key]
		if g["vertices"].size() == 0:
			continue

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g["vertices"]
		arrays[Mesh.ARRAY_NORMAL] = g["normals"]
		arrays[Mesh.ARRAY_INDEX] = g["indices"]
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, materials[key])

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	mesh_inst.name = "MarsEntrance"
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_inst.visibility_range_end = 250.0
	mesh_inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	parent.add_child(mesh_inst)

	# Label3D текст вывески
	if geo.has("sign_data"):
		var sd: Dictionary = geo["sign_data"]
		var sign_text: String = entrance_data.get("sign_text", "МАРС")
		var sign_subtitle: String = entrance_data.get("sign_subtitle", "")
		_add_mars_sign_label(sd["position"], sd["rotation_y"], sign_text, sign_subtitle, parent)

	# Коллизии
	if geo.has("collisions"):
		var body := StaticBody3D.new()
		body.collision_layer = 2
		body.collision_mask = 0
		body.name = "MarsEntranceCollision"
		parent.add_child(body)
		for coll in geo["collisions"]:
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = coll["size"]
			shape.shape = box
			shape.position = coll["center"]
			if coll.has("rotation_y"):
				shape.rotation.y = coll["rotation_y"]
			body.add_child(shape)

	print("MarsEntrance: created at (%.1f, %.1f)" % [world_pos.x, world_pos.z])


func _add_mars_sign_label(pos: Vector3, rot_y: float, text: String, subtitle: String, parent: Node3D) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 400
	label.pixel_size = 0.0025
	label.modulate = Color(0.95, 0.95, 0.95)
	label.outline_size = 8
	label.outline_modulate = Color(0.6, 0.1, 0.1)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = false
	label.position = pos
	label.rotation.y = rot_y
	label.name = "MarsSignText"
	parent.add_child(label)


func _create_shop_back_wall(height: float, width: float, colors: Array) -> MeshInstance3D:
	"""Создаёт заднюю стенку для входной группы магазина (ShaderMaterial).
	colors: Array of Color — одна = сплошной цвет, несколько = горизонтальные полосы (сверху вниз)"""
	if _shop_back_wall_shader == null:
		_shop_back_wall_shader = Shader.new()
		_shop_back_wall_shader.code = """
shader_type spatial;
render_mode cull_disabled;
uniform vec4 albedo_color = vec4(0.85, 0.83, 0.80, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.85;
void fragment() {
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness_value;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
"""

	var hx := width / 2.0
	var wall_z := 0.02
	var stripe_count := colors.size()
	var stripe_height := height / stripe_count

	var arr_mesh := ArrayMesh.new()

	for i in range(stripe_count):
		var color: Color = colors[i]
		# Полосы сверху вниз: i=0 верх, i=last низ
		var y_top := height - i * stripe_height
		var y_bottom := height - (i + 1) * stripe_height

		var mat := ShaderMaterial.new()
		mat.shader = _shop_back_wall_shader
		mat.set_shader_parameter("albedo_color", color)
		mat.set_shader_parameter("roughness_value", 0.85)

		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var idx := PackedInt32Array()

		verts.append(Vector3(-hx, y_bottom, wall_z))
		verts.append(Vector3(hx, y_bottom, wall_z))
		verts.append(Vector3(hx, y_top, wall_z))
		verts.append(Vector3(-hx, y_top, wall_z))
		for _j in range(4):
			norms.append(Vector3(0, 0, 1))
		idx.append_array([0, 1, 2, 0, 2, 3])

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_INDEX] = idx
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		arr_mesh.surface_set_material(arr_mesh.get_surface_count() - 1, mat)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_inst.name = "BackWall"
	return mesh_inst


func _calculate_sign_width(text: String) -> float:
	"""Точно рассчитывает ширину вывески по тексту"""
	var char_count = text.length()
	var avg_char_width = 1.2  # Средняя ширина русского символа для font_size=256 (увеличено с 0.75)
	var text_width = char_count * avg_char_width
	var padding = 2.0  # Отступы (1м с каждой стороны, увеличено с 1.0)
	return text_width + padding


func _find_longest_wall_simple(points: PackedVector2Array, min_width: float) -> Dictionary:
	"""Находит самую длинную стену, достаточную для вывески"""
	if points.size() < 3:
		return {}

	var longest = null
	var max_length = 0.0

	for i in range(points.size()):
		var p1 = points[i]
		var p2 = points[(i + 1) % points.size()]

		var length = p1.distance_to(p2)

		# Проверяем, что стена достаточно длинная для вывески (+ отступы)
		if length < min_width + 1.0:  # 1.0м - запас с обеих сторон
			continue

		if length > max_length:
			max_length = length
			var wall_dir = (p2 - p1).normalized()
			# Нормаль наружу = поворот ВПРАВО (по часовой) от направления стены
			# В 2D: право от (x, y) = (y, -x)
			# В 3D с Y вверх: право от (x, z) = (z, -x)
			var wall_normal = Vector3(wall_dir.y, 0, -wall_dir.x)

			longest = {
				"p1": p1,
				"p2": p2,
				"center": (p1 + p2) / 2.0,
				"length": length,
				"normal": wall_normal
			}

	return longest if longest != null else {}


func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	"""Вычисляет расстояние от точки до отрезка"""
	var seg = seg_end - seg_start
	var seg_length_sq = seg.length_squared()

	if seg_length_sq < 0.0001:
		return point.distance_to(seg_start)

	# Проекция точки на линию отрезка
	var t = clamp((point - seg_start).dot(seg) / seg_length_sq, 0.0, 1.0)
	var projection = seg_start + t * seg

	return point.distance_to(projection)


func _find_entrance_for_building(building_points: PackedVector2Array, _loader: Node) -> Dictionary:
	"""
	Ищет вход, принадлежащий данному зданию.
	Вход считается принадлежащим, если он находится на контуре здания
	или в пределах небольшого расстояния от контура.

	ВАЖНО: Использует _latlon_to_local() (глобальная система координат),
	т.к. building_points уже конвертированы через неё в _create_building()

	Returns: {position: Vector2, wall_p1: Vector2, wall_p2: Vector2, tags: Dictionary} или пустой словарь
	"""
	const MAX_DISTANCE := 2.0  # Максимальное расстояние от контура (2 метра)

	for entrance in _entrance_nodes:
		# Используем _latlon_to_local(), т.к. building_points в той же системе координат
		var entrance_pos: Vector2 = _latlon_to_local(entrance.lat, entrance.lon)

		# Проверяем расстояние до каждой стены здания
		for i in range(building_points.size()):
			var p1 = building_points[i]
			var p2 = building_points[(i + 1) % building_points.size()]

			var distance = _point_to_segment_distance(entrance_pos, p1, p2)

			if distance <= MAX_DISTANCE:
				return {
					"position": entrance_pos,
					"wall_p1": p1,
					"wall_p2": p2,
					"tags": entrance.tags
				}

	return {}


func _find_pois_inside_building(building_points: PackedVector2Array, _loader: Node) -> Array:
	"""
	Ищет POI nodes (точечные заведения) внутри полигона здания.
	Использует алгоритм ray casting для проверки принадлежности точки полигону.

	ВАЖНО: Использует _latlon_to_local() (глобальная система координат),
	т.к. building_points уже конвертированы через неё в _create_building()

	Returns: Array of {position: Vector2, tags: Dictionary}
	"""
	var result: Array = []

	# Вычисляем bbox здания для быстрой фильтрации
	var min_x = INF
	var max_x = -INF
	var min_y = INF
	var max_y = -INF
	for p in building_points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)

	for poi in _poi_nodes:
		# Используем _latlon_to_local(), т.к. building_points в той же системе координат
		var poi_pos: Vector2 = _latlon_to_local(poi.lat, poi.lon)

		# Быстрая проверка bbox
		if poi_pos.x < min_x or poi_pos.x > max_x or poi_pos.y < min_y or poi_pos.y > max_y:
			continue

		# Точная проверка point-in-polygon
		if _point_in_polygon(poi_pos, building_points):
			var name = poi.tags.get("name", "unknown")
			print("POI_DEBUG: Found '%s' (id=%s) inside building at local (%.1f, %.1f)" % [name, str(poi.get("id", 0)), poi_pos.x, poi_pos.y])
			result.append({
				"position": poi_pos,
				"tags": poi.tags,
				"id": poi.get("id", 0)
			})

	return result


func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	"""Проверяет, находится ли точка внутри полигона (ray casting algorithm)"""
	var n = polygon.size()
	if n < 3:
		return false

	var inside = false
	var j = n - 1

	for i in range(n):
		var pi = polygon[i]
		var pj = polygon[j]

		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside

		j = i

	return inside


func _find_closest_wall_to_point(building_points: PackedVector2Array, target_point: Vector2, min_width: float) -> Dictionary:
	"""
	Находит стену здания, ближайшую к указанной точке.
	Возвращает точку на стене, ближайшую к target_point.
	Нормаль всегда направлена НАРУЖУ от центра здания.

	Returns: {closest_point: Vector2, normal: Vector3, p1: Vector2, p2: Vector2} или пустой словарь
	"""
	var closest_wall = {}
	var min_distance = INF

	# Вычисляем центр здания для проверки направления нормали
	var center = Vector2.ZERO
	for p in building_points:
		center += p
	center /= building_points.size()

	for i in range(building_points.size()):
		var p1 = building_points[i]
		var p2 = building_points[(i + 1) % building_points.size()]

		var wall_length = p1.distance_to(p2)

		# Пропускаем слишком короткие стены
		if wall_length < min_width + 1.0:
			continue

		# Находим ближайшую точку на отрезке
		var seg = p2 - p1
		var seg_length_sq = seg.length_squared()

		var t = 0.0
		if seg_length_sq > 0.0001:
			t = clamp((target_point - p1).dot(seg) / seg_length_sq, 0.0, 1.0)

		var closest_on_wall = p1 + t * seg
		var distance = target_point.distance_to(closest_on_wall)

		if distance < min_distance:
			min_distance = distance
			var wall_dir = seg.normalized()
			# Нормаль перпендикулярна стене
			var normal_2d = Vector2(wall_dir.y, -wall_dir.x)

			# Проверяем направление: нормаль должна быть НАРУЖУ от центра
			var wall_center = (p1 + p2) / 2.0
			var to_center = center - wall_center
			if normal_2d.dot(to_center) > 0:
				# Нормаль направлена к центру - инвертируем
				normal_2d = -normal_2d

			var wall_normal = Vector3(normal_2d.x, 0, normal_2d.y)

			closest_wall = {
				"closest_point": closest_on_wall,
				"normal": wall_normal,
				"p1": p1,
				"p2": p2,
				"distance": distance
			}

	return closest_wall


# ============ ROAD SMOOTHING ============

## Catmull-Rom spline interpolation
func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2: float = t * t
	var t3: float = t2 * t
	return (p1 * 2.0 + (-p0 + p2) * t + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2 + (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t3) * 0.5


## Smooths road geometry using Catmull-Rom spline interpolation
## This creates smooth curves through all points
## Клиппинг полилинии по прямоугольнику.
## Обрезает участки, полностью выходящие за rect. Вставляет точки пересечения на границе.
func _clip_polyline_to_rect(points: PackedVector2Array, min_x: float, max_x: float, min_z: float, max_z: float) -> PackedVector2Array:
	if points.size() < 2:
		return points

	var result := PackedVector2Array()
	for i in range(points.size()):
		var p := points[i]
		var inside := p.x >= min_x and p.x <= max_x and p.y >= min_z and p.y <= max_z

		if i > 0:
			var prev := points[i - 1]
			var prev_inside := prev.x >= min_x and prev.x <= max_x and prev.y >= min_z and prev.y <= max_z

			if inside != prev_inside:
				# Одна точка внутри, другая снаружи — добавляем пересечение
				var clipped := _clip_segment_to_rect(prev, p, min_x, max_x, min_z, max_z)
				if clipped != prev and clipped != p:
					result.append(clipped)

		if inside:
			result.append(p)

	return result


## Находит точку пересечения отрезка (a→b) с границей прямоугольника (ближайшую к a).
func _clip_segment_to_rect(a: Vector2, b: Vector2, min_x: float, max_x: float, min_z: float, max_z: float) -> Vector2:
	var best_t := 1.0
	var dx := b.x - a.x
	var dy := b.y - a.y

	# Проверяем вертикальные границы (min_x, max_x)
	if abs(dx) > 0.001:
		var t1: float = (min_x - a.x) / dx
		if t1 > 0.0 and t1 < best_t:
			var hz1: float = a.y + dy * t1
			if hz1 >= min_z and hz1 <= max_z:
				best_t = t1
		var t2: float = (max_x - a.x) / dx
		if t2 > 0.0 and t2 < best_t:
			var hz2: float = a.y + dy * t2
			if hz2 >= min_z and hz2 <= max_z:
				best_t = t2

	# Проверяем горизонтальные границы (min_z, max_z)
	if abs(dy) > 0.001:
		var t3: float = (min_z - a.y) / dy
		if t3 > 0.0 and t3 < best_t:
			var hx3: float = a.x + dx * t3
			if hx3 >= min_x and hx3 <= max_x:
				best_t = t3
		var t4: float = (max_z - a.y) / dy
		if t4 > 0.0 and t4 < best_t:
			var hx4: float = a.x + dx * t4
			if hx4 >= min_x and hx4 <= max_x:
				best_t = t4

	return Vector2(a.x + dx * best_t, a.y + dy * best_t)


func _smooth_road_corners(raw_points: PackedVector2Array) -> PackedVector2Array:
	var smoothed := _smooth_points_adaptive(raw_points, 1.0)
	return _remove_polyline_loops(smoothed)


## Адаптивное сглаживание: мало точек на прямых, много на поворотах
## min_dist — минимальное расстояние между точками (для дорог 1м, для бордюров 2м)
func _smooth_points_adaptive(raw_points: PackedVector2Array, min_dist: float) -> PackedVector2Array:
	if raw_points.size() < 3:
		return raw_points

	var result: PackedVector2Array = PackedVector2Array()

	# Always add first point
	result.append(raw_points[0])

	for i in range(raw_points.size() - 1):
		var p0: Vector2 = raw_points[maxi(0, i - 1)]
		var p1: Vector2 = raw_points[i]
		var p2: Vector2 = raw_points[mini(raw_points.size() - 1, i + 1)]
		var p3: Vector2 = raw_points[mini(raw_points.size() - 1, i + 2)]

		var seg_length: float = p1.distance_to(p2)
		if seg_length < 0.01:
			continue  # Skip degenerate zero-length segments

		# Measure angle sharpness at both ends of the segment
		var sharpness_at_p1: float = 0.0
		if i > 0:
			var d1: Vector2 = (p1 - p0).normalized()
			var d2: Vector2 = (p2 - p1).normalized()
			sharpness_at_p1 = (1.0 - d1.dot(d2)) * 0.5

		var sharpness_at_p2: float = 0.0
		if i + 2 < raw_points.size():
			var d1: Vector2 = (p2 - p1).normalized()
			var d2: Vector2 = (p3 - p2).normalized()
			sharpness_at_p2 = (1.0 - d1.dot(d2)) * 0.5

		var sharpness: float = maxf(sharpness_at_p1, sharpness_at_p2)

		# Also check curvature via Catmull-Rom midpoint deviation from straight line
		# This catches gradual curves where each angle is small but the arc is significant
		var mid_interp: Vector2 = _catmull_rom(p0, p1, p2, p3, 0.5)
		var mid_straight: Vector2 = (p1 + p2) * 0.5
		var deviation: float = mid_interp.distance_to(mid_straight)
		# Normalize deviation by segment length to get relative curvature
		var rel_curvature: float = deviation / maxf(seg_length, 0.1)

		# Combine: use whichever indicates more curvature
		# rel_curvature 0.006 → sharpness 0.05 (gentle), 0.019 → 0.15 (medium)
		if rel_curvature > 0.005:
			sharpness = maxf(sharpness, rel_curvature * 8.0)

		# Adaptive subdivisions based on sharpness:
		# Straight (sharpness < 0.05): 1 subdivision (no intermediate points)
		# Gentle curve (0.05-0.15): 2 subdivisions
		# Medium curve (0.15-0.3): 3-4 subdivisions based on segment length
		# Sharp turn (0.3-0.5): 4-6 subdivisions
		# Very sharp (>0.5): 6-8 subdivisions
		var subdivisions: int
		if sharpness < 0.05:
			subdivisions = 1
		elif sharpness < 0.15:
			subdivisions = 2
		elif sharpness < 0.3:
			subdivisions = maxi(3, mini(4, int(seg_length / 8.0)))
		elif sharpness < 0.5:
			subdivisions = maxi(4, mini(6, int(seg_length / 5.0)))
		else:
			subdivisions = maxi(6, mini(8, int(seg_length / 3.0)))

		# Interpolate from p1 to p2
		for j in range(1, subdivisions):
			var t: float = float(j) / float(subdivisions)
			var interp: Vector2 = _catmull_rom(p0, p1, p2, p3, t)

			if result[result.size() - 1].distance_to(interp) > min_dist:
				result.append(interp)

		# Add the endpoint of this segment (p2) unless it's the last point
		if i < raw_points.size() - 2:
			if result[result.size() - 1].distance_to(p2) > min_dist:
				result.append(p2)

	# Always add last point
	var last_point: Vector2 = raw_points[raw_points.size() - 1]
	if result[result.size() - 1].distance_to(last_point) > 0.1:
		result.append(last_point)

	return result


## Убирает петли (self-intersection) из полилинии.
## Проверяет каждый новый сегмент на пересечение со всеми предыдущими.
## При обнаружении петли — вырезает все точки внутри петли и заменяет на точку пересечения.
func _remove_polyline_loops(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() < 4:
		return points
	var result := PackedVector2Array()
	result.append(points[0])
	var i := 1
	while i < points.size():
		var a: Vector2 = result[result.size() - 1]
		var b: Vector2 = points[i]
		# Проверяем сегмент a→b на пересечение с предыдущими сегментами result
		# Пропускаем последний сегмент result (он смежный — всегда «пересекается» в общей точке)
		var loop_found := false
		if result.size() >= 3:
			var j := 0
			while j < result.size() - 2:
				var c: Vector2 = result[j]
				var d: Vector2 = result[j + 1]
				var ix := _segment_intersect(a, b, c, d)
				if ix != Vector2.INF:
					# Петля: вырезаем точки result[j+1..end], заменяем на точку пересечения
					var new_result := PackedVector2Array()
					for k in range(j + 1):
						new_result.append(result[k])
					new_result.append(ix)
					result = new_result
					loop_found = true
					break
				j += 1
		if not loop_found:
			result.append(b)
		i += 1
	return result


## Пересечение двух отрезков. Возвращает Vector2.INF если не пересекаются.
func _segment_intersect(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var cd: Vector2 = d - c
	var denom: float = ab.x * cd.y - ab.y * cd.x
	if absf(denom) < 1e-10:
		return Vector2.INF  # Параллельные
	var ac: Vector2 = c - a
	var t: float = (ac.x * cd.y - ac.y * cd.x) / denom
	var u: float = (ac.x * ab.y - ac.y * ab.x) / denom
	if t > 0.01 and t < 0.99 and u > 0.01 and u < 0.99:
		return a + ab * t
	return Vector2.INF


## Удаляет zigzag-точки из полилинии: точки слишком близкие к предыдущему сегменту
## или создающие обратный ход. Применяется ДО splitting footway.
func _remove_polyline_zigzag(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var result := PackedVector2Array()
	result.append(points[0])
	result.append(points[1])
	var prev_dir: Vector2 = (points[1] - points[0]).normalized()
	for i in range(2, points.size()):
		var new_dir: Vector2 = (points[i] - result[result.size() - 1]).normalized()
		# Пропускаем точку если она идёт назад (dot < 0) или слишком близко (< 0.5m)
		if prev_dir.dot(new_dir) < 0.0:
			continue
		if points[i].distance_to(result[result.size() - 1]) < 0.5:
			continue
		result.append(points[i])
		prev_dir = new_dir
	return result


## Вычисляет площадь полигона (shoelace formula). Возвращает signed area.
func _polygon_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	var n := poly.size()
	for i in range(n):
		var j := (i + 1) % n
		area += poly[i].x * poly[j].y
		area -= poly[j].x * poly[i].y
	return area * 0.5


## Validates road direction to remove points that create loops/flips
## Removes points where the direction changes by more than 75 degrees
func _validate_road_direction(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() < 3:
		return points

	var result: PackedVector2Array = PackedVector2Array()
	result.append(points[0])  # Always keep first point

	var prev_dir: Vector2 = (points[1] - points[0]).normalized()

	for i in range(1, points.size() - 1):
		var current_dir: Vector2 = (points[i + 1] - points[i]).normalized()
		var dot: float = prev_dir.dot(current_dir)

		# If direction changed by more than 75 degrees, skip this point
		# dot = 0.26 corresponds to ~75 degrees
		# This aggressively removes problematic smoothed points at intersections
		if dot < 0.26:
			# Skip this point as it creates a sharp turn
			continue

		result.append(points[i])
		prev_dir = current_dir

	result.append(points[points.size() - 1])  # Always keep last point
	return result


## Возвращает приоритет дороги (больше = важнее)
func _get_road_priority(highway_type: String) -> int:
	match highway_type:
		"motorway", "trunk":
			return 5
		"primary":
			return 4
		"secondary":
			return 3
		"tertiary":
			return 2
		"residential", "unclassified", "service":
			return 1
		_:
			return 0


## Переключает отображение границ чанков для отладки
func toggle_chunk_boundaries() -> void:
	_show_chunk_boundaries = not _show_chunk_boundaries

	if _show_chunk_boundaries:
		# Создаём визуализацию границ для всех загруженных чанков
		for chunk_key in _loaded_chunks.keys():
			_create_chunk_boundary_mesh(chunk_key)
	else:
		# Удаляем все визуализации
		for mesh_instance in _chunk_boundary_meshes.values():
			if mesh_instance:
				mesh_instance.queue_free()
		_chunk_boundary_meshes.clear()


## Создаёт mesh для визуализации границы чанка
func _create_chunk_boundary_mesh(chunk_key: String) -> void:
	if _chunk_boundary_meshes.has(chunk_key):
		return  # Уже создан

	var coords := chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])

	var x := chunk_x * chunk_size
	var z := chunk_z * chunk_size

	# Создаём линии по периметру чанка
	var immediate_mesh := ImmediateMesh.new()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var height := 50.0  # Высота линий
	var color := Color.YELLOW

	# Нижняя рамка
	immediate_mesh.surface_set_color(color)
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z))

	# Вертикальные линии по углам
	immediate_mesh.surface_add_vertex(Vector3(x, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x, 0, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z + chunk_size))

	# Верхняя рамка
	immediate_mesh.surface_add_vertex(Vector3(x, height, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z))
	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x + chunk_size, height, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z + chunk_size))

	immediate_mesh.surface_add_vertex(Vector3(x, height, z + chunk_size))
	immediate_mesh.surface_add_vertex(Vector3(x, height, z))

	immediate_mesh.surface_end()

	# Создаём MeshInstance3D
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = immediate_mesh

	# Создаём материал
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true  # Всегда видим
	mesh_instance.material_override = material

	# Добавляем в сцену
	add_child(mesh_instance)
	_chunk_boundary_meshes[chunk_key] = mesh_instance


## Проверяет, находится ли точка рядом с перекрёстком
## Возвращает индекс перекрёстка или -1
func _find_nearby_intersection(pos: Vector2, radius: float = 15.0) -> int:
	for i in range(_intersection_positions.size()):
		if pos.distance_to(_intersection_positions[i]) < radius:
			return i
	return -1


## Проверяет, является ли перекрёсток равнозначным
func _is_equal_intersection(intersection_idx: int) -> bool:
	if intersection_idx < 0 or intersection_idx >= _intersection_types.size():
		return false
	return _intersection_types[intersection_idx]


## Ищет ближайший перекрёсток в пределах радиуса
func _find_nearest_intersection(pos: Vector2, max_dist: float) -> int:
	var best_idx := -1
	var best_dist := max_dist
	for i in range(_intersection_positions.size()):
		var dist := pos.distance_to(_intersection_positions[i])
		if dist < best_dist:
			best_dist = dist
			best_idx = i
	return best_idx


## Проверяет, находится ли точка внутри эллипса перекрёстка (с масштабом)
## Добавляет перекрёсток в spatial hash
func _add_intersection_to_spatial_hash(pos: Vector2, radii: Vector2, idx: int) -> void:
	# Определяем bounding box перекрёстка с учётом максимального радиуса
	var max_radius := maxf(radii.x, radii.y) * 1.5  # С запасом для scale
	var min_cell_x := int(floor((pos.x - max_radius) / INTERSECTION_CELL_SIZE))
	var max_cell_x := int(floor((pos.x + max_radius) / INTERSECTION_CELL_SIZE))
	var min_cell_y := int(floor((pos.y - max_radius) / INTERSECTION_CELL_SIZE))
	var max_cell_y := int(floor((pos.y + max_radius) / INTERSECTION_CELL_SIZE))

	# Добавляем индекс во все затронутые ячейки
	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not _intersection_spatial_hash.has(key):
				_intersection_spatial_hash[key] = []
			_intersection_spatial_hash[key].append(idx)


## Получает индексы перекрёстков рядом с точкой через spatial hash
func _get_nearby_intersections(pos: Vector2) -> Array:
	var cell_x := int(floor(pos.x / INTERSECTION_CELL_SIZE))
	var cell_y := int(floor(pos.y / INTERSECTION_CELL_SIZE))
	var key := Vector2i(cell_x, cell_y)
	if _intersection_spatial_hash.has(key):
		return _intersection_spatial_hash[key]
	return []


## Добавляет сегмент дороги в spatial hash для быстрого поиска
func _add_road_segment_to_spatial_hash(seg: Dictionary) -> void:
	var p1: Vector2 = seg.p1
	var p2: Vector2 = seg.p2
	var width: float = seg.width

	# Определяем bounding box сегмента дороги
	var min_x := minf(p1.x, p2.x) - width / 2.0
	var max_x := maxf(p1.x, p2.x) + width / 2.0
	var min_y := minf(p1.y, p2.y) - width / 2.0
	var max_y := maxf(p1.y, p2.y) + width / 2.0

	var min_cell_x := int(floor(min_x / ROAD_CELL_SIZE))
	var max_cell_x := int(floor(max_x / ROAD_CELL_SIZE))
	var min_cell_y := int(floor(min_y / ROAD_CELL_SIZE))
	var max_cell_y := int(floor(max_y / ROAD_CELL_SIZE))

	# Добавляем сегмент во все затронутые ячейки
	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not _road_spatial_hash.has(key):
				_road_spatial_hash[key] = []
			_road_spatial_hash[key].append(seg)


## Получает сегменты дорог рядом с точкой через spatial hash
func _get_nearby_road_segments(pos: Vector2) -> Array:
	var cell_x := int(floor(pos.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(pos.y / ROAD_CELL_SIZE))
	var key := Vector2i(cell_x, cell_y)
	if _road_spatial_hash.has(key):
		return _road_spatial_hash[key]
	return []


## Публичный метод для получения сегментов дорог в радиусе (для миникарты)
## Возвращает Array[{p1: Vector2, p2: Vector2, width: float}]
func get_road_segments_in_radius(center: Vector3, radius: float) -> Array:
	var result: Array = []
	var seen: Dictionary = {}  # Для избежания дубликатов

	var center_2d := Vector2(center.x, center.z)
	var radius_sq := radius * radius

	# Определяем диапазон ячеек для проверки
	var cells_to_check := int(ceil(radius / ROAD_CELL_SIZE)) + 1
	var center_cell_x := int(floor(center.x / ROAD_CELL_SIZE))
	var center_cell_y := int(floor(center.z / ROAD_CELL_SIZE))

	for dx in range(-cells_to_check, cells_to_check + 1):
		for dy in range(-cells_to_check, cells_to_check + 1):
			var key := Vector2i(center_cell_x + dx, center_cell_y + dy)
			if not _road_spatial_hash.has(key):
				continue

			for seg in _road_spatial_hash[key]:
				# Используем id сегмента для избежания дубликатов
				var seg_id := "%s_%s" % [seg.p1, seg.p2]
				if seen.has(seg_id):
					continue
				seen[seg_id] = true

				# Проверяем что хотя бы одна точка в радиусе
				var p1: Vector2 = seg.p1
				var p2: Vector2 = seg.p2
				if center_2d.distance_squared_to(p1) <= radius_sq or center_2d.distance_squared_to(p2) <= radius_sq:
					result.append(seg)
				else:
					# Проверяем центр сегмента
					var mid := (p1 + p2) / 2.0
					if center_2d.distance_squared_to(mid) <= radius_sq:
						result.append(seg)

	return result


## Проверяет, находится ли точка на дороге
func _is_point_on_road(pos: Vector2, margin: float = 0.5) -> bool:
	# Используем spatial hash для быстрого поиска ближайших сегментов
	var nearby_segments := _get_nearby_road_segments(pos)

	for seg in nearby_segments:
		var p1: Vector2 = seg.p1
		var p2: Vector2 = seg.p2
		var width: float = seg.width

		# Вычисляем расстояние от точки до сегмента дороги
		var line_vec := p2 - p1
		var point_vec := pos - p1
		var line_len := line_vec.length()

		if line_len < 0.01:  # Вырожденный сегмент
			continue

		# Проекция точки на линию сегмента
		var t := point_vec.dot(line_vec) / (line_len * line_len)
		t = clampf(t, 0.0, 1.0)

		# Ближайшая точка на сегменте
		var closest := p1 + line_vec * t
		var dist := pos.distance_to(closest)

		# Проверяем, находится ли точка в пределах ширины дороги + margin
		if dist <= (width / 2.0 + margin):
			return true

	return false


## Добавляет сегмент стены здания в spatial hash
func _add_building_segment_to_spatial_hash(seg: Dictionary) -> void:
	var p1: Vector2 = seg.p1
	var p2: Vector2 = seg.p2

	var min_x := minf(p1.x, p2.x)
	var max_x := maxf(p1.x, p2.x)
	var min_y := minf(p1.y, p2.y)
	var max_y := maxf(p1.y, p2.y)

	var min_cell_x := int(floor(min_x / BUILDING_CELL_SIZE))
	var max_cell_x := int(floor(max_x / BUILDING_CELL_SIZE))
	var min_cell_y := int(floor(min_y / BUILDING_CELL_SIZE))
	var max_cell_y := int(floor(max_y / BUILDING_CELL_SIZE))

	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not _building_spatial_hash.has(key):
				_building_spatial_hash[key] = []
			_building_spatial_hash[key].append(seg)


## Проверяет, находится ли точка слишком близко к любому зданию
func _is_point_near_building(point: Vector2, min_distance: float) -> bool:
	var cell_x := int(floor(point.x / BUILDING_CELL_SIZE))
	var cell_y := int(floor(point.y / BUILDING_CELL_SIZE))

	# Проверяем текущую и соседние ячейки (здание может быть в соседней ячейке)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if not _building_spatial_hash.has(key):
				continue
			for seg in _building_spatial_hash[key]:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				if point.distance_to(closest) < min_distance:
					return true

	return false


## Пытается сместить позицию объекта с дороги к её краю
## Возвращает новую позицию или Vector2.ZERO если не удалось найти безопасное место
func _move_object_off_road(pos: Vector2, margin: float = 0.5, max_attempts: int = 5) -> Vector2:
	var current_pos := pos

	for attempt in range(max_attempts):
		# Проверяем текущую позицию
		if not _is_point_on_road(current_pos, margin):
			return current_pos  # Нашли безопасное место

		# Ищем ближайший сегмент дороги
		var nearby_segments := _get_nearby_road_segments(current_pos)
		if nearby_segments.is_empty():
			return current_pos  # Нет дорог рядом, позиция безопасна

		# Находим самый близкий сегмент
		var closest_seg: Dictionary = {}
		var min_dist := INF
		var closest_point := Vector2.ZERO

		for seg in nearby_segments:
			var p1: Vector2 = seg.p1
			var p2: Vector2 = seg.p2
			var line_vec := p2 - p1
			var point_vec := current_pos - p1
			var line_len := line_vec.length()

			if line_len < 0.01:
				continue

			var t := point_vec.dot(line_vec) / (line_len * line_len)
			t = clampf(t, 0.0, 1.0)
			var closest := p1 + line_vec * t
			var dist := current_pos.distance_to(closest)

			if dist < min_dist:
				min_dist = dist
				closest_seg = seg
				closest_point = closest

		if closest_seg.is_empty():
			return current_pos  # Не нашли близкий сегмент

		# Направление от ближайшей точки на дороге к текущей позиции
		var away_dir := (current_pos - closest_point).normalized()
		if away_dir.length() < 0.01:
			# Если находимся точно на линии дороги, используем перпендикуляр
			var p1: Vector2 = closest_seg.p1
			var p2: Vector2 = closest_seg.p2
			var road_dir := (p2 - p1).normalized()
			away_dir = Vector2(-road_dir.y, road_dir.x)  # Перпендикуляр

		# Смещаем к краю дороги + margin
		var width: float = closest_seg.width
		var target_dist := width / 2.0 + margin + 0.5  # Дополнительный запас 0.5м
		current_pos = closest_point + away_dir * target_dist

	# Не удалось найти безопасное место за max_attempts попыток
	return Vector2.ZERO


## Строит контур перекрёстка: "лепестки" вдоль входящих дорог + дуги скругления между ними
## Возвращает PackedVector2Array (мировые координаты). Пустой массив = fallback на эллипс.
func _build_intersection_contour(intersection_idx: int) -> PackedVector2Array:
	var center: Vector2 = _intersection_positions[intersection_idx]
	var roads: Array = _intersection_roads[intersection_idx]

	if roads.size() < 2:
		return PackedVector2Array()  # Тупик — fallback на эллипс

	# Сортируем дороги по углу
	var sorted_roads: Array = []
	for r in roads:
		var dir: Vector2 = r["direction"]
		var angle := atan2(dir.y, dir.x)
		sorted_roads.append({"direction": dir, "width": r["width"], "angle": angle})
	sorted_roads.sort_custom(func(a, b): return a["angle"] < b["angle"])

	var contour := PackedVector2Array()
	var road_count := sorted_roads.size()
	var curve_segments := 6  # Точек в кривой Безье

	# Максимальная полуширина дорог на перекрёстке — для расчёта extend
	var max_half_w := 0.0
	for r in roads:
		max_half_w = maxf(max_half_w, r["width"] * 0.5)

	for i in range(road_count):
		var road: Dictionary = sorted_roads[i]
		var next_road: Dictionary = sorted_roads[(i + 1) % road_count]

		var dir: Vector2 = road["direction"]
		var half_w: float = road["width"] * 0.5
		# Extend должен быть не меньше макс полуширины + запас, чтобы покрыть пересекающие дороги
		var extend: float = maxf(half_w, max_half_w) + 5.0
		var perp := Vector2(-dir.y, dir.x)

		var left_tip: Vector2 = center + dir * extend - perp * half_w
		var right_tip: Vector2 = center + dir * extend + perp * half_w

		contour.append(left_tip)
		contour.append(right_tip)

		# Следующая дорога
		var next_dir: Vector2 = next_road["direction"]
		var next_half_w: float = next_road["width"] * 0.5
		var next_extend: float = maxf(next_half_w, max_half_w) + 5.0
		var next_perp := Vector2(-next_dir.y, next_dir.x)
		var next_left_tip: Vector2 = center + next_dir * next_extend - next_perp * next_half_w

		# Угловой зазор между рукавами
		var delta: float = next_road["angle"] - road["angle"]
		if delta < 0:
			delta += TAU

		if delta > deg_to_rad(150.0):
			# Большой зазор — нет дороги с этой стороны (например, "дно" Т-перекрёстка)
			# Прямая линия от right_tip к next_left_tip (без дуги)
			pass
		elif delta > deg_to_rad(10.0):
			# Угол где дороги реально встречаются — кривая Безье (филе)
			# Находим точку пересечения линий краёв дорог:
			# Линия 1: right_tip + t * dir (край текущей дороги)
			# Линия 2: next_left_tip + s * next_dir (край следующей дороги)
			var d: Vector2 = next_left_tip - right_tip
			var det: float = dir.x * next_dir.y - dir.y * next_dir.x

			if absf(det) > 0.001:
				var t_val: float = (d.x * next_dir.y - d.y * next_dir.x) / det
				var corner_point: Vector2 = right_tip + dir * t_val

				# Проверка: угловая точка не должна быть слишком далеко
				var max_dist: float = maxf(extend, next_extend) * 3.0
				if corner_point.distance_to(center) < max_dist:
					# Квадратичная кривая Безье: P0=right_tip, P1=corner_point, P2=next_left_tip
					for j in range(1, curve_segments + 1):
						var t: float = float(j) / float(curve_segments + 1)
						var p01: Vector2 = right_tip.lerp(corner_point, t)
						var p12: Vector2 = corner_point.lerp(next_left_tip, t)
						contour.append(p01.lerp(p12, t))

	return contour


## Проверяет, находится ли точка внутри контура перекрёстка (ray-casting point-in-polygon)
## Сначала проверяет контуры, для перекрёстков без контура fallback на эллипс
## Возвращает индекс перекрёстка или -1
func _is_point_in_intersection_shape(pos: Vector2, use_curb_contour: bool = false) -> int:
	var nearby := _get_nearby_intersections(pos)
	for i in nearby:
		# Пробуем контур
		var contour: PackedVector2Array
		if use_curb_contour:
			contour = _intersection_curb_contours[i] if i < _intersection_curb_contours.size() else PackedVector2Array()
		else:
			contour = _intersection_contours[i] if i < _intersection_contours.size() else PackedVector2Array()

		if contour.size() >= 3:
			if _point_in_polygon_2d(pos, contour):
				return i
		else:
			# Fallback на эллипс
			var center: Vector2 = _intersection_positions[i]
			var scale := 1.3 if use_curb_contour else 1.0
			var radii: Vector2 = _intersection_radii[i] * scale
			var angle: float = _intersection_angles[i]
			var dx := pos.x - center.x
			var dy := pos.y - center.y
			var cos_a := cos(-angle)
			var sin_a := sin(-angle)
			var rx := dx * cos_a - dy * sin_a
			var ry := dx * sin_a + dy * cos_a
			var normalized := (rx * rx) / (radii.x * radii.x) + (ry * ry) / (radii.y * radii.y)
			if normalized <= 1.0:
				return i
	return -1


## Ray-casting point-in-polygon test (2D)
func _point_in_polygon_2d(point: Vector2, polygon: PackedVector2Array) -> bool:
	var n := polygon.size()
	var inside := false
	var j := n - 1
	for i_idx in range(n):
		var pi: Vector2 = polygon[i_idx]
		var pj: Vector2 = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i_idx
	return inside


## Создаёт скруглённые бордюры на углах перекрёстка
## Для каждой пары смежных дорог — кривая Безье от правого края одной к левому краю следующей
func _create_intersection_curbs(intersection_idx: int, parent: Node3D, height_offset: float) -> void:
	var center: Vector2 = _intersection_positions[intersection_idx]
	var roads: Array = _intersection_roads[intersection_idx]

	if roads.size() < 2:
		return

	# Сортируем дороги по углу (как в _build_intersection_contour)
	var sorted_roads: Array = []
	for r in roads:
		var dir: Vector2 = r["direction"]
		var a := atan2(dir.y, dir.x)
		sorted_roads.append({"direction": dir, "width": r["width"], "angle": a})
	sorted_roads.sort_custom(func(a_r, b_r): return a_r["angle"] < b_r["angle"])

	var road_count := sorted_roads.size()
	var curb_width := 0.15
	var curb_height := 0.22
	var curve_segments := 8

	# Максимальная полуширина для extend
	var max_half_w := 0.0
	for r in roads:
		max_half_w = maxf(max_half_w, r["width"] * 0.5)

	var vertices := PackedVector3Array()
	var normals_arr := PackedVector3Array()
	var indices := PackedInt32Array()

	for i in range(road_count):
		var road: Dictionary = sorted_roads[i]
		var next_road: Dictionary = sorted_roads[(i + 1) % road_count]

		var dir: Vector2 = road["direction"]
		var half_w: float = road["width"] * 0.5
		var extend: float = maxf(half_w, max_half_w) + 5.0
		var perp := Vector2(-dir.y, dir.x)

		var next_dir: Vector2 = next_road["direction"]
		var next_half_w: float = next_road["width"] * 0.5
		var next_extend: float = maxf(next_half_w, max_half_w) + 5.0
		var next_perp := Vector2(-next_dir.y, next_dir.x)

		# Точки на краю дорог (правый край текущей, левый край следующей)
		var right_tip: Vector2 = center + dir * extend + perp * half_w
		var next_left_tip: Vector2 = center + next_dir * next_extend - next_perp * next_half_w

		# Угловой зазор между рукавами
		var delta: float = next_road["angle"] - road["angle"]
		if delta < 0:
			delta += TAU

		if delta < deg_to_rad(10.0):
			continue  # Слишком маленький угол — дороги почти параллельны

		# Собираем точки кривой
		var curve_points: PackedVector2Array = PackedVector2Array()
		curve_points.append(right_tip)

		if delta <= deg_to_rad(150.0):
			# Кривая Безье через угловую точку (пересечение линий краёв)
			var d: Vector2 = next_left_tip - right_tip
			var det: float = dir.x * next_dir.y - dir.y * next_dir.x
			if absf(det) > 0.001:
				var t_val: float = (d.x * next_dir.y - d.y * next_dir.x) / det
				var corner_point: Vector2 = right_tip + dir * t_val
				var max_dist: float = maxf(extend, next_extend) * 3.0
				if corner_point.distance_to(center) < max_dist:
					for j in range(1, curve_segments + 1):
						var t: float = float(j) / float(curve_segments + 1)
						var p01: Vector2 = right_tip.lerp(corner_point, t)
						var p12: Vector2 = corner_point.lerp(next_left_tip, t)
						curve_points.append(p01.lerp(p12, t))

		curve_points.append(next_left_tip)

		if curve_points.size() < 2:
			continue

		# Генерируем бордюр вдоль кривой
		for seg_i in range(curve_points.size() - 1):
			var p1: Vector2 = curve_points[seg_i]
			var p2: Vector2 = curve_points[seg_i + 1]

			# Направление "наружу" от центра перекрёстка
			var out1 := (p1 - center).normalized()
			var out2 := (p2 - center).normalized()

			# Внутренний край (на контуре = край дороги)
			var inner1 := p1
			var inner2 := p2
			# Внешний край
			var outer1 := p1 + out1 * curb_width
			var outer2 := p2 + out2 * curb_width

			# Высоты
			var h1 := 0.0
			var h2 := 0.0
			var road_y1 := h1 + height_offset
			var road_y2 := h2 + height_offset
			var curb_y1 := road_y1 + curb_height
			var curb_y2 := road_y2 + curb_height
			var bottom_y1 := curb_y1 - 1.0
			var bottom_y2 := curb_y2 - 1.0

			# Нормали
			var seg_dir := (p2 - p1).normalized()
			var norm_in := Vector3(-out1.x, 0, -out1.y)  # Внутрь (к дороге)
			var norm_out := Vector3(out1.x, 0, out1.y)   # Наружу

			var idx := vertices.size()

			# Внутренняя стенка (от уровня дороги до верха бордюра)
			vertices.append(Vector3(inner1.x, road_y1, inner1.y))
			vertices.append(Vector3(inner2.x, road_y2, inner2.y))
			vertices.append(Vector3(inner2.x, curb_y2, inner2.y))
			vertices.append(Vector3(inner1.x, curb_y1, inner1.y))
			for _j in 4: normals_arr.append(norm_in)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
			idx = vertices.size()

			# Верхняя грань
			vertices.append(Vector3(inner1.x, curb_y1, inner1.y))
			vertices.append(Vector3(inner2.x, curb_y2, inner2.y))
			vertices.append(Vector3(outer2.x, curb_y2, outer2.y))
			vertices.append(Vector3(outer1.x, curb_y1, outer1.y))
			for _j in 4: normals_arr.append(Vector3.UP)
			indices.append(idx + 0); indices.append(idx + 1); indices.append(idx + 2)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 3)
			idx = vertices.size()

			# Наружная стенка (от земли до верха бордюра)
			vertices.append(Vector3(outer1.x, bottom_y1, outer1.y))
			vertices.append(Vector3(outer2.x, bottom_y2, outer2.y))
			vertices.append(Vector3(outer2.x, curb_y2, outer2.y))
			vertices.append(Vector3(outer1.x, curb_y1, outer1.y))
			for _j in 4: normals_arr.append(norm_out)
			indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
			indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)

	if vertices.size() == 0:
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals_arr
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = arr_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.material_override = _curb_material
	parent.add_child(mesh_instance)


## Создаёт заплатку на перекрёстке (чистый асфальт без разметки)
## Использует контур перекрёстка если доступен, иначе fallback на эллипс
## Каждая вершина следует за elevation terrain + наклон дороги
func _create_intersection_patch(pos: Vector2, parent: Node3D, intersection_idx: int = -1, height_offset: float = 0.096, chunk_key: String = "") -> void:
	if not _road_textures.has("intersection"):
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Z-offset: дороги имеют hash-based z_offset до 0.03, заплатка должна быть выше всех
	var z_off := 0.005

	# Elevation в центре перекрёстка
	var h_center := 0.0
	var center_y := h_center + height_offset + z_off

	# Центральная вершина (индекс 0)
	st.set_uv(Vector2(0.5, 0.5))
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(pos.x, center_y, pos.y))

	# Получаем контур перекрёстка или fallback на эллипс
	var contour := PackedVector2Array()
	if intersection_idx >= 0 and intersection_idx < _intersection_contours.size():
		contour = _intersection_contours[intersection_idx]

	if contour.size() >= 3:
		# Контурный патч — вершины по контуру
		# Находим bounding box для UV-маппинга
		var min_x := contour[0].x
		var max_x := contour[0].x
		var min_y := contour[0].y
		var max_y := contour[0].y
		for cp in contour:
			min_x = minf(min_x, cp.x)
			max_x = maxf(max_x, cp.x)
			min_y = minf(min_y, cp.y)
			max_y = maxf(max_y, cp.y)
		var range_x := maxf(max_x - min_x, 0.001)
		var range_y := maxf(max_y - min_y, 0.001)

		for cp in contour:
			var h_edge := 0.0
			var vertex_y := h_edge + height_offset + z_off
			var u := (cp.x - min_x) / range_x
			var v := (cp.y - min_y) / range_y
			st.set_uv(Vector2(u, v))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(cp.x, vertex_y, cp.y))

		# Fan-триангуляция от центра
		var n := contour.size()
		for i in range(n):
			var next_i := (i + 1) % n
			st.add_index(0)       # Центр
			st.add_index(i + 1)   # Текущая вершина
			st.add_index(next_i + 1)  # Следующая
	else:
		# Fallback: эллипс (старое поведение)
		var radius_a := 6.0
		var radius_b := 6.0
		var rotation_angle := 0.0
		if intersection_idx >= 0 and intersection_idx < _intersection_radii.size():
			radius_a = _intersection_radii[intersection_idx].x
			radius_b = _intersection_radii[intersection_idx].y
			rotation_angle = _intersection_angles[intersection_idx]

		var segments := 16
		var cos_rot := cos(rotation_angle)
		var sin_rot := sin(rotation_angle)
		for i in range(segments):
			var angle := float(i) / segments * TAU
			var ex := cos(angle) * radius_a
			var ey := sin(angle) * radius_b
			var rx := ex * cos_rot - ey * sin_rot
			var ry := ex * sin_rot + ey * cos_rot
			var x := pos.x + rx
			var z_coord := pos.y + ry
			var edge_pos := Vector2(x, z_coord)
			var h_edge := 0.0
			var vertex_y := h_edge + height_offset + z_off
			var u := 0.5 + cos(angle) * 0.5
			var v := 0.5 + sin(angle) * 0.5
			st.set_uv(Vector2(u, v))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(x, vertex_y, z_coord))

		for i in range(segments):
			var next_i := (i + 1) % segments
			st.add_index(0)
			st.add_index(i + 1)
			st.add_index(next_i + 1)

	var mesh := st.commit()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh

	var albedo_tex: Texture2D = _road_textures.get("intersection", null)
	var normal_tex: Texture2D = _normal_textures.get("asphalt", null)
	var material: Material = WetRoadMaterial.create_road_shader_material(
		albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null)
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, "intersection")
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Регистрируем материал для wet mode
	if chunk_key != "" and material is ShaderMaterial:
		if not _chunk_road_materials.has(chunk_key):
			_chunk_road_materials[chunk_key] = []
		_chunk_road_materials[chunk_key].append(material)

	parent.add_child(mesh_instance)


## RenderingServer mesh instance — bypasses scene tree entirely.
## Returns the instance RID. Mesh ref stored to prevent GC.
func _rs_add_mesh(chunk_key: String, mesh: Mesh, material: Material = null,
		shadow: int = RenderingServer.SHADOW_CASTING_SETTING_OFF,
		vis_max: float = 0.0, vis_min: float = 0.0) -> RID:
	var inst := RenderingServer.instance_create2(mesh.get_rid(), get_world_3d().scenario)
	RenderingServer.instance_set_transform(inst, Transform3D.IDENTITY)
	RenderingServer.instance_geometry_set_cast_shadows_setting(inst, shadow)
	if material:
		RenderingServer.instance_geometry_set_material_override(inst, material.get_rid())
	if vis_max > 0.0 or vis_min > 0.0:
		RenderingServer.instance_geometry_set_visibility_range(inst, vis_min, vis_max, 0.0, 0.0,
			RenderingServer.VISIBILITY_RANGE_FADE_DISABLED)
	# Lazy activation: создаём невидимыми, активируем через N кадров пакетно
	if _chunk_activation_pending.has(chunk_key):
		RenderingServer.instance_set_visible(inst, false)
	if not _chunk_rs_instances.has(chunk_key):
		_chunk_rs_instances[chunk_key] = []
		_chunk_rs_meshes[chunk_key] = []
	_chunk_rs_instances[chunk_key].append(inst)
	_chunk_rs_meshes[chunk_key].append(mesh)
	if material:
		_chunk_rs_meshes[chunk_key].append(material)  # prevent GC for dynamic materials
	return inst


## Записывает метрику времени
## Lazy chunk activation — даёт Vulkan время подготовить GPU ресурсы перед показом
func _process_chunk_activation() -> void:
	if _chunk_activation_pending.is_empty():
		return

	# Состояния в _chunk_activation_pending:
	# -1 = ждём финализации
	# >= 0 = индекс следующего RS instance для активации
	const RS_PER_FRAME := 4  # RS instances за кадр (размазываем Vulkan upload)

	for chunk_key in _chunk_activation_pending.keys():
		var state: int = _chunk_activation_pending[chunk_key]

		if state == -1:
			# Проверяем есть ли ещё finalize очереди для этого чанка
			var still_pending := _pending_batch_chunks.has(chunk_key) or _lamp_batches_to_finalize.has(chunk_key) or _tree_batches_to_finalize.has(chunk_key) or _billboard_batches_to_finalize.has(chunk_key) or _building_geo_finalize_queue.has(chunk_key) or _fence_batches_to_finalize.has(chunk_key)
			if not still_pending:
				_chunk_activation_pending[chunk_key] = 0  # начинаем пакетную активацию
		else:
			# Пакетная активация RS instances по N за кадр
			if not _chunk_rs_instances.has(chunk_key):
				# Нет RS instances — сразу включаем scene tree node
				if _loaded_chunks.has(chunk_key):
					var cn: Node3D = _loaded_chunks[chunk_key]
					if is_instance_valid(cn):
						cn.visible = true
				_chunk_activation_pending.erase(chunk_key)
				print("OSM: Activated chunk %s (lazy, no RS)" % chunk_key)
				continue

			var instances: Array = _chunk_rs_instances[chunk_key]
			var end_idx: int = mini(state + RS_PER_FRAME, instances.size())
			var i := state
			while i < end_idx:
				RenderingServer.instance_set_visible(instances[i], true)
				i += 1

			if end_idx >= instances.size():
				# Все RS instances активированы — включаем scene tree node
				if _loaded_chunks.has(chunk_key):
					var cn: Node3D = _loaded_chunks[chunk_key]
					if is_instance_valid(cn):
						cn.visible = true
				_chunk_activation_pending.erase(chunk_key)
				print("OSM: Activated chunk %s (lazy, %d RS)" % [chunk_key, instances.size()])
			else:
				_chunk_activation_pending[chunk_key] = end_idx


## Budgeted add_child — limits scene tree insertions per frame.
## Returns true if added immediately, false if deferred.
func _budgeted_add_child(parent_node: Node, child_node: Node) -> bool:
	if _add_child_count < ADD_CHILD_BUDGET_PER_FRAME:
		parent_node.add_child(child_node)
		_add_child_count += 1
		return true
	else:
		_deferred_add_child_queue.append({"parent": parent_node, "child": child_node})
		return false


func _record_perf(name: String, time_usec: int) -> void:
	var time_ms := time_usec / 1000.0
	# Данные текущего кадра для slow-frame лога
	_current_frame_perf[name] = time_ms

	# Скользящее окно для on-screen display
	if not _perf_window.has(name):
		_perf_window[name] = [] as Array[float]
	var win: Array = _perf_window[name]
	win.append(time_ms)
	if win.size() > PERF_WINDOW_SIZE:
		win.pop_front()

	if not _perf_enabled:
		return
	if not _perf_metrics.has(name):
		_perf_metrics[name] = {"total": 0, "count": 0, "max": 0, "samples": []}
	var m: Dictionary = _perf_metrics[name]
	m.total += time_usec
	m.count += 1
	if time_usec > m.max:
		m.max = time_usec
	# Храним последние 100 сэмплов для расчёта медианы
	if m.samples.size() < 100:
		m.samples.append(time_usec)
	else:
		m.samples[m.count % 100] = time_usec


## Выводит метрики в консоль
func _print_perf_metrics() -> void:
	print("\n========== PERFORMANCE METRICS ==========")
	print("Frames: %d" % _perf_frame_count)

	var sorted_keys := _perf_metrics.keys()
	sorted_keys.sort_custom(func(a, b):
		return _perf_metrics[a].total > _perf_metrics[b].total
	)

	for name in sorted_keys:
		var m: Dictionary = _perf_metrics[name]
		if m.count == 0:
			continue
		var avg: float = float(m.total) / float(m.count)
		var samples: Array = m.samples.duplicate()
		samples.sort()
		var median: float = float(samples[samples.size() / 2]) if samples.size() > 0 else 0.0
		print("  %s: avg=%.2f ms, median=%.2f ms, max=%.2f ms, calls=%d, total=%.1f ms" % [
			name,
			avg / 1000.0,
			median / 1000.0,
			float(m.max) / 1000.0,
			m.count,
			float(m.total) / 1000.0
		])

	print("==========================================\n")
	# Сбрасываем метрики
	_perf_metrics.clear()
	_perf_frame_count = 0

func _print_draw_call_stats() -> void:
	"""
	Выводит статистику draw calls по категориям для диагностики
	"""
	if not _draw_call_logging_enabled:
		return

	# Подсчитываем NPC draw calls динамически (~7 meshes per car)
	var traffic_mgr_node = get_parent().get_node_or_null("TrafficManager")
	if traffic_mgr_node:
		_draw_call_stats["npc_cars"] = traffic_mgr_node.active_npcs.size() * 7

	var total_draw_calls = 0
	for category in _draw_call_stats:
		total_draw_calls += _draw_call_stats[category]

	if total_draw_calls == 0:
		return

	print("\n========== DRAW CALL BREAKDOWN ==========")
	print("Total tracked draw calls: %d" % total_draw_calls)
	print()

	# Сортируем по количеству (descending)
	var sorted_categories = []
	for category in _draw_call_stats:
		sorted_categories.append({
			"name": category,
			"count": _draw_call_stats[category]
		})
	sorted_categories.sort_custom(func(a, b): return a.count > b.count)

	# Выводим с процентами
	for item in sorted_categories:
		if item.count == 0:
			continue
		var percentage = 100.0 * item.count / total_draw_calls
		# Создаем визуальную полоску (до 20 символов)
		var bar_length = int(percentage / 5.0)
		var bar = ""
		for i in range(bar_length):
			bar += "█"
		print("  %-12s: %5d (%5.1f%%) %s" % [
			item.name.capitalize(),
			item.count,
			percentage,
			bar
		])

	print("\n💡 RECOMMENDATIONS:")

	# Анализируем что нужно оптимизировать
	var buildings_pct = 100.0 * _draw_call_stats["buildings"] / total_draw_calls if total_draw_calls > 0 else 0
	var windows_pct = 100.0 * _draw_call_stats["windows"] / total_draw_calls if total_draw_calls > 0 else 0
	var roads_pct = 100.0 * _draw_call_stats["roads"] / total_draw_calls if total_draw_calls > 0 else 0
	var infrastructure_pct = (_draw_call_stats["curbs"] + _draw_call_stats["lamps"] + _draw_call_stats["signs"]) * 100.0 / total_draw_calls if total_draw_calls > 0 else 0

	if buildings_pct > 30:
		print("  🔴 Buildings: %.1f%% of draw calls" % buildings_pct)
		print("     → Implement MultiMeshInstance3D for building base meshes")

	if windows_pct > 20:
		print("  🔴 Windows: %.1f%% of draw calls" % windows_pct)
		print("     → Batch all windows into single MultiMesh per chunk")

	if roads_pct > 20:
		print("  🔴 Roads: %.1f%% of draw calls" % roads_pct)
		print("     → Merge road segments, use global batches by material")

	if infrastructure_pct > 15:
		print("  🟠 Infrastructure: %.1f%% of draw calls" % infrastructure_pct)
		print("     → Use MultiMesh for curbs, lamps, signs")

	print("=========================================\n")


## Camera-based frustum culling для чанков
## Использует реальные frustum planes камеры + dot product для чанков позади
func _update_chunk_culling() -> void:
	if not enable_frustum_culling:
		for chunk_node in _loaded_chunks.values():
			if is_instance_valid(chunk_node):
				chunk_node.visible = true
		return

	# Всегда получаем актуальную камеру (может смениться через CameraManager)
	_culling_camera = get_viewport().get_camera_3d()
	if not _culling_camera:
		return

	if not _car:
		return

	var car_pos := _car.global_position

	# Получаем frustum planes камеры (left, right, top, bottom, near, far)
	var frustum: Array[Plane] = _culling_camera.get_frustum()

	# Направление камеры для дополнительного culling позади машины
	var cam_forward := -_culling_camera.global_transform.basis.z
	cam_forward.y = 0
	if cam_forward.length_squared() > 0.001:
		cam_forward = cam_forward.normalized()
	else:
		cam_forward = -_car.global_transform.basis.z
		cam_forward.y = 0
		cam_forward = cam_forward.normalized()

	var culled_count := 0
	var visible_count := 0

	# Высота зданий для AABB (макс ~50м)
	var chunk_height := 60.0

	var cam_pos := _culling_camera.global_position

	for chunk_key in _loaded_chunks.keys():
		# Пропускаем чанки в процессе lazy activation
		if _chunk_activation_pending.has(chunk_key):
			continue

		var chunk_node: Node3D = _loaded_chunks[chunk_key]
		if not is_instance_valid(chunk_node):
			continue

		var coords: PackedStringArray = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])

		# AABB чанка с учётом высоты
		var aabb_min := Vector3(chunk_x * chunk_size, -5.0, chunk_z * chunk_size)
		var aabb_max := Vector3(aabb_min.x + chunk_size, chunk_height, aabb_min.z + chunk_size)
		var aabb_center := (aabb_min + aabb_max) * 0.5
		var aabb_half := (aabb_max - aabb_min) * 0.5

		# Расстояние до ближнего ребра чанка
		var nearest_x := clampf(car_pos.x, aabb_min.x, aabb_max.x)
		var nearest_z := clampf(car_pos.z, aabb_min.z, aabb_max.z)
		var dist_to_edge := car_pos.distance_to(Vector3(nearest_x, car_pos.y, nearest_z))

		# Ближние чанки (< 200м до ребра) — всегда видимы
		if dist_to_edge < 200.0:
			chunk_node.visible = true
			visible_count += 1
			continue

		# Тест AABB vs frustum planes
		var inside_frustum := true
		for plane in frustum:
			var d := aabb_center.dot(plane.normal) + plane.d
			var r := absf(aabb_half.x * plane.normal.x) + absf(aabb_half.y * plane.normal.y) + absf(aabb_half.z * plane.normal.z)
			if d + r < 0.0:
				inside_frustum = false
				break

		var should_hide := not inside_frustum

		# Дополнительно: скрываем далёкие чанки строго позади камеры
		if not should_hide:
			var to_chunk := aabb_center - car_pos
			to_chunk.y = 0
			var dist := to_chunk.length()
			if dist > chunk_size * 0.5:  # Не текущий чанк
				var dot := cam_forward.dot(to_chunk.normalized())
				# Чанк далеко позади - скрываем
				if dot < -0.4 and dist > chunk_size * 1.5:
					should_hide = true

		if should_hide:
			culled_count += 1
		else:
			visible_count += 1

		chunk_node.visible = not should_hide

	# DEBUG: раз в 5 секунд (~25 вызовов culling при 200ms интервале)
	_culling_debug_counter += 1
	if _culling_debug_counter >= 25:
		_culling_debug_counter = 0
		print("Culling: %d visible, %d culled (frustum), loaded: %d" % [
			visible_count, culled_count, _loaded_chunks.size()
		])
