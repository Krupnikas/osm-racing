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
const TRAM_STOP_SIGN_TEXTURE = preload("res://textures/signs/tram_stop.png")
const DecorationLayerScript = preload("res://osm/decoration_layer.gd")
const WheelDirtScript = preload("res://effects/wheel_dirt.gd")

# Текстуры для деревянных одноэтажных домов (Россия)
const FOUNDATION_DEPTH := 3.0  # How far below terrain each foundation vertex extends
const FOUNDATION_CAP_DEPTH := 5.0  # Bottom cap Y offset below base_elev

const WOODEN_TEXTURES := [
	"res://textures/buildings/wooden-house-1.png",
	"res://textures/buildings/wooden-house-2.png",
	"res://textures/buildings/wooden-house-3.png",
	"res://textures/buildings/wooden-house-4.png",
]


# Decoration Layer для добавления атмосферы поверх OSM данных
var _decoration_layer: Node = null  # DecorationLayer

# Кэш текстур (создаются один раз)
var _road_textures: Dictionary = {}
var _cached_road_albedo: Texture2D = null  # Shared asphalt albedo for lane-aware keys
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
@export var chunk_size := 210.0  # Размер чанка в метрах (270м сетка - 2×30м паддинг)
@export var load_distance := 500.0  # Дистанция подгрузки чанков
@export var unload_distance := 700.0  # Дистанция выгрузки чанков
@export var render_distance := 400.0  # Дальность прорисовки (и начало тумана)
@export var fog_enabled := true  # Включить туман для скрытия края мира
@export var car_path: NodePath
@export var camera_path: NodePath
@export var debug_print := false  # Выключить debug output для производительности
@export var debug_chunk_lifecycle := false  # Лёгкая диагностика стадий чанков
@export var debug_log_to_file := true  # Пишет runtime-диагностику в user://osm_runtime_debug.log
@export var debug_log_roads := true  # Добавляет road/culling события в runtime-лог
@export var debug_log_path := "user://osm_runtime_debug.log"

## Feature Flags для A/B тестирования производительности
@export_group("Features", "enable_")
@export var enable_buildings := true  # Включить здания
@export var enable_windows := true  # Включить окна в зданиях

# Shared window layout constants (used by thread + main thread)
const WINDOW_SIZE := 1.2          # Window quad width/height (meters)
const WINDOW_SPACING := 2.5       # Center-to-center distance (meters)
const WINDOW_RECESS_DEPTH := 0.15 # How far window sits behind wall surface (meters)
const WINDOW_CUT_MARGIN := 0.02   # Wall cutout is this much larger than window on each side
const WINDOW_FLOOR_HEIGHT := 3.0  # Floor-to-floor height (meters)
const WATER_Y := -1.0             # Water surface level (1m below ground)
const SHORE_WIDTH := 3.0          # Horizontal slope distance (~22° gentle slope from 0.22 to -1.0)
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
@export var enable_fences := true  # Включить заборы (промзоны, территории)
@export var enable_elevation := false  # Включить elevation из SRTM30m
@export var enable_ground_plane := false  # Grey fallback plane at raw elevation under terrain
@export var enable_water := true  # Включить водные объекты (реки, озера)
@export var manhole_spacing := 100.0  # Расстояние между люками (метры)

## Фильтр чанков: Callable(cx: int, cz: int) -> bool. Если задан, чанки загружаются только если фильтр вернёт true.
var chunk_filter: Callable = Callable()

## Тестовый режим: провайдер данных вместо HTTP (Callable(lat, lon, size) -> Dictionary)
var test_data_provider: Callable = Callable()
## Тестовый режим: провайдер высот (Callable(chunk_key, lat, lon) -> Dictionary)

# Elevation system
const ElevationLoaderScript = preload("res://osm/elevation_loader.gd")
var _chunk_elevation_data: Dictionary = {}  # chunk_key -> grid dict
var _elevation_in_flight: Dictionary = {}  # chunk_key -> true (request in progress)
var _base_elevation := 0.0  # No offset — 1:1 ASL elevation

var osm_loader: Node
var _car: Node3D
var _camera: Camera3D
var _debug_log_file: FileAccess = null
var _debug_log_absolute_path := ""
var _profiler: PerformanceProfiler  # Для измерения производительности
var _loaded_chunks: Dictionary = {}  # key: "x,z" -> value: Node3D (chunk node)
var _loading_chunks: Dictionary = {}  # key: "x,z" -> value: timestamp (start time in msec)
var _chunk_data_received: Dictionary = {}  # key: "x,z" -> true — dedup for duplicate HTTP callbacks
var _chunk_state: Dictionary = {}  # key: "x,z" -> lifecycle/debug state
var _loading_placeholders: Dictionary = {}  # key: "x,z" -> MeshInstance3D placeholder
const CHUNK_LOAD_TIMEOUT := 30.0  # Таймаут загрузки чанка (секунд) — must be > HTTP timeout × retries
const CHUNK_STALL_WARN_MS := 10000
const CHUNK_STALL_FAIL_MS := 30000
var _last_check_pos := Vector3.ZERO
var _last_player_pos := Vector3.ZERO
var _check_interval := 0.5  # Проверка каждые 0.5 сек
var _check_timer := 0.0
var _chunks_to_unload: Array[String] = []  # Очередь на выгрузку (1 чанк за кадр)
var _initial_loading := false  # Флаг начальной загрузки
var _initial_chunks_needed: Array[String] = []  # Чанки нужные для старта
var _initial_chunks_loaded: int = 0  # Количество загруженных начальных чанков
var _initial_chunks_completed: Dictionary = {}  # Чанки завершившие phase3 (для отслеживания прогресса даже после unload)
var _loading_paused := false  # Загрузка НЕ на паузе - автоматический старт
var _load_generation := 0  # Инкрементируется при reset для игнорирования старых callback'ов
var _initial_load_debug_timer := 0.0
# _entrance_nodes/_poi_nodes removed — now passed as local params to avoid data race during frame budgeting
var _parking_polygons: Array[PackedVector2Array] = []  # Полигоны парковок для исключения фонарей
var _parking_bounds: Array = []  # Cached {center: Vector2, radius: float} per parking polygon
var _parking_spatial_hash: Dictionary = {}  # Spatial hash: Vector2i → Array of {polygon_idx: int, p1: Vector2, p2: Vector2}
const PARKING_CELL_SIZE := 30.0
var _road_segments: Array = []  # Сегменты дорог для позиционирования знаков парковки
var _road_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска дорог
const ROAD_CELL_SIZE := 20.0  # Размер ячейки spatial hash для дорог
var _building_segments: Array = []  # Сегменты стен зданий {p1: Vector2, p2: Vector2}
var _building_spatial_hash: Dictionary = {}  # Spatial hash для быстрого поиска зданий (сегменты)
var _building_poly_hash: Dictionary = {}  # Spatial hash полигонов зданий для is_point_in_polygon
const BUILDING_CELL_SIZE := 20.0  # Размер ячейки spatial hash для зданий
var _water_polygons: Array[PackedVector2Array] = []  # Все водные полигоны (для is_point_in_polygon)
var _water_spatial_hash: Dictionary = {}  # Spatial hash: Vector2i → Array of {idx: int, p1: Vector2, p2: Vector2}
const WATER_CELL_SIZE := 30.0
# Per-chunk tracking of spatial hash cells for cleanup on unload
# chunk_key -> {"road": [Vector2i], "building": [Vector2i], "building_poly": [Vector2i], "parking": [Vector2i], "intersection": [Vector2i]}
var _chunk_hash_cells: Dictionary = {}
# Per-chunk spatial hashes (independent, include overlap data — used by vegetation threads)
var _chunk_road_hashes: Dictionary = {}  # chunk_key → Dictionary (Vector2i → Array of seg)
var _chunk_tram_hashes: Dictionary = {}  # chunk_key → Dictionary (Vector2i → Array of tram seg)
var _chunk_building_hashes: Dictionary = {}  # chunk_key → Dictionary
var _chunk_building_poly_hashes: Dictionary = {}  # chunk_key → Dictionary
var _chunk_parking_hashes: Dictionary = {}  # chunk_key → Dictionary
var _chunk_water_hashes: Dictionary = {}  # chunk_key → {hash: Dictionary, polys: Array}
var _chunk_intersection_hashes: Dictionary = {}  # chunk_key → Dictionary (Vector2i → Array of idx)
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
var _pending_parking_signs: Array = []  # Отложенные знаки парковки
var _crossing_sign_front_mat: StandardMaterial3D
var _crossing_sign_back_mat: StandardMaterial3D
var _parking_sign_front_mat: StandardMaterial3D
var _tram_stop_sign_front_mat: StandardMaterial3D
var _deferred_lamp_queue: Dictionary = {}  # chunk_key → Array[{points, width, parent}]
var _deferred_manhole_queue: Dictionary = {}  # chunk_key → Array[{points, width, parent}]
var _deferred_traffic_queue: Array = []  # Deferred traffic network extraction
var _deferred_tram_queue: Array = []  # Deferred tram track network extraction
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
var _culling_visible_count := 0  # Количество видимых чанков (для HUD)
var _culling_culled_count := 0   # Количество скрытых чанков (для HUD)

# Отложенная генерация дорог и других тяжёлых объектов
var _road_queue: Dictionary = {}  # Per-chunk road queue: chunk_key -> Array of {nodes, tags, parent, way_id}
var _curb_queue: Array = []  # Очередь бордюров (создаются после детекции перекрёстков)

# Threaded road processing — smoothing + geometry in worker threads
var _road_mutex: Mutex
var _road_results: Array = []  # Готовые результаты из worker threads
var _pending_road_tasks: int = 0  # Счётчик активных задач
var _pending_road_tasks_by_chunk: Dictionary = {}  # chunk_key -> int active worker tasks

# Road batching system - накопление geometry данных для mesh merging
var _road_batch_data: Dictionary = {}  # key: chunk_key -> { "highway": {vertices, uvs, normals, indices}, "primary": {...}, ...}
var _dispatched_tram_ways: Dictionary = {}  # way_id+chunk → true — dedup tram rendering dispatches
var _dispatched_tram_network: Dictionary = {}  # way_id → true — dedup tram NETWORK extraction (once per way globally)
var _pending_batch_chunks: Array[String] = []  # Чанки с pending road batches (нужно финализировать)
var _chunk_terrain_roads: Dictionary = {}  # chunk_key → Array[{points: PackedVector2Array, width: float}] — для отложенного выреза террейна
var _deferred_path_polys: Dictionary = {}  # chunk_key → Array[{polys, raw_points, width, height_offset, parent}] — footpath polygons waiting for road clipping at finalization
var _chunk_water_polygons: Dictionary = {}  # chunk_key → Array[PackedVector2Array] — водоёмы для выреза террейна + берег
# Global, dedup'd water polygons (full, un-clipped). Per-chunk water entries
# only see their own slice; chunks deep inside a huge reservoir (Рыбинское,
# 11×16 km) have no polygon nodes in their bbox and never register one
# locally. Iterating this list with an AABB pre-filter lets every chunk's
# terrain cutout / point-in-water lookup see the full polygon. Keyed by
# polygon hash so a relation joined in one chunk's data is stored once.
var _global_water_polygons: Array[PackedVector2Array] = []
var _global_water_polygon_bboxes: Array[Rect2] = []
var _global_water_polygon_hashes: Dictionary = {}  # hash → idx
var _deferred_terrain_chunks: Array[String] = []  # Чанки ожидающие terrain clipping (ждут соседей)

var _chunk_pending_deferred: Dictionary = {}  # chunk_key → int — счётчик pending deferred items (lamps, footway, manholes, billboard, traffic)

# Window batching system - ONE MultiMesh per chunk instead of per-building
var _window_batch_data: Dictionary = {}  # key: chunk_key -> {transforms: Array[Transform3D], colors: Array[Color], parent: Node3D}
var _window_batch_materials: Array[ShaderMaterial] = []  # Материалы всех window batches для обновления is_night параметра

# BUILDING GEOMETRY MERGE: объединяем все стены/крыши чанка в один ArrayMesh для снижения draw calls
var _building_geo_batch: Dictionary = {}  # chunk_key -> {parent, panel_walls: {verts,uvs,normals,indices}, brick_walls, wall_walls, roofs, collisions, decorations}
var _building_geo_finalize_queue: Array[String] = []  # Очередь chunk_key для финализации
var _window_finalize_queue: Array[String] = []  # Progressive window finalization queue
var _window_finalize_progress: Dictionary = {}  # chunk_key -> {buf, offset, mm, transforms, colors, parent, mat, mm_instance}
var _building_wall_materials: Dictionary = {}  # texture_type -> ShaderMaterial (shared)
var _building_recess_materials: Dictionary = {}  # texture_type -> ShaderMaterial (with vertex emission)
var _building_roof_material: StandardMaterial3D = null  # shared
var _gabled_roof_material: StandardMaterial3D = null  # shared, для двускатных крыш
var _building_parapet_material: ShaderMaterial = null  # shared (uses wall shader for FRONT_FACING fix)
var _building_foundation_materials: Array[StandardMaterial3D] = []  # 4 random colors

# ENTRANCE GEOMETRY MERGE: объединяем все подъезды чанка в один ArrayMesh
var _entrance_batch: Dictionary = {}  # chunk_key -> {parent, concrete: {vertices,normals,indices}, red_metal, ...}
var _entrance_lights: Array[OmniLight3D] = []  # Светильники подъездов (для ночного режима)
const ResidentialEntranceScript = preload("res://osm/residential_entrance_generator.gd")

# Lamp lights - для управления ночным режимом
var _lamp_batch_lights: Array[Light3D] = []  # Все SpotLight3D фонарей (immediate path)

var _curb_smoothed_queue: Array = []  # Очередь сглаженных бордюров для генерации меша
var _curb_mesh_state: Dictionary = {}  # Текущее состояние генерации меша бордюра (для разбивки по кадрам)
var _curb_geo_batch: Dictionary = {}  # chunk_key -> {parent, vertices, normals, indices}
var _curb_material: Material = null  # Shared material для всех бордюров (ShaderMaterial с PBR текстурой)

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
var _lamp_light_offset := Vector3(0, 6.7, 0)  # Позиция SpotLight3D относительно основания
var _lamp_debug_visible := false  # Видимость debug шариков и конусов (L)

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

# Bridge / deck registry (restored from 7102d8c).
#   _bridge_node_ways[coord_key] = { way_id: true, ... } — every node touched
#     by a highway+bridge=yes way. Used to detect shared endpoints between
#     adjacent bridge segments.
#   _bridge_deck_polygons — local-coord outlines from man_made=bridge
#     relations; the flat deck mesh is built on top of these.
#   _deck_entry_edges_cache — memoised long-axis frame for each deck polygon
#     (avoid recomputing the ramp axis per vertex).
var _bridge_node_ways: Dictionary = {}
var _bridge_deck_polygons: Array[PackedVector2Array] = []
var _deck_entry_edges_cache: Dictionary = {}
# Per-polygon "reference elevation" — single constant Y the whole deck sits
# on (= max elevation of polygon vertices in loaded chunks, i.e. abutment /
# bank level). This is the design-doc principle: a real bridge has one deck
# elevation for the whole span, not per-vertex terrain noise. Indexed by
# poly index in _bridge_deck_polygons.
var _deck_polygon_ref_elev: Dictionary = {}
# Bridge deck mesh + collision + railing nodes per polygon index. They live
# directly under `self` (not under the spawning chunk), so the camera-
# direction culler can't hide them when the player is still on the bridge.
# Cleared in reset_terrain to free per-location decks.
var _bridge_deck_nodes: Dictionary = {}  # poly_idx -> Array[Node3D]
# Lateral exit points where _link bridge roads depart the deck polygon.
# Deck mesh ramps down at these points so the standalone bridge road's
# ramp is visible. Each: {pos, inward_dir, half_width, base_elev}.
var _deck_lateral_exits: Array = []

# Ramp junction points — where on-deck bridge ways meet the polygon boundary.
# Detected in _apply_road_result. Each: {pos: Vector2, dir: Vector2, width: float}
# where dir points outward (away from polygon center).
var _deck_ramp_junctions: Array = []

# Stage 1 bridge approach ramp detection (read-only, debug overlay).
# Detector is instantiated lazily on first chunk load; never modifies
# bridge rendering. See docs/bridge_ramp_design.md and
# osm/bridge_ramp_detector.gd.
var _ramp_detector: Node = null

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

# Per-chunk profiling: chunk_key → {start_ms, phase12_thread_ms, phase12_apply_ms, phase3_ms, finalize_ms, activate_ms, total_ms, ways, buildings, roads}
var _chunk_profile: Dictionary = {}

# Terrain clipping via WorkerThreadPool — результаты из worker потоков
var _terrain_thread_results: Array = []  # Results from terrain worker threads
var _terrain_thread_mutex: Mutex
var _pending_terrain_tasks: int = 0

# Threaded terrain generation — Phase 1+2 (spatial hash + intersections) run on worker thread
var _terrain_gen_results: Array = []  # Results from terrain gen worker threads
var _pending_terrain_gen_tasks: int = 0

# Phase 3 incremental queue — process ways/objects across frames with time budget
var _phase3_queue: Array = []  # [{result, parent, chunk_key, way_idx, phase}]

# Очереди отложенного создания нод (бюджет: N нод за кадр)
var _deferred_building_collisions: Dictionary = {}  # chunk_key → Array[{parent, collisions, idx}]
var _deferred_lamp_lights: Dictionary = {}  # chunk_key → Array[{container, lights, idx, chunk_key, is_night}]
var _deferred_tree_collisions: Dictionary = {}  # chunk_key → Array[{parent, collisions, idx}]
var _deferred_road_collisions: Dictionary = {}  # chunk_key → Array[{body, vertices, indices}]
var _deferred_terrain_collisions: Dictionary = {}  # chunk_key → Array[{parent, vertices, indices}]
var _deferred_footway_queue: Dictionary = {}  # chunk_key → Array[{smoothed_points, width, tags, parent}]
var _deferred_billboard_queue: Dictionary = {}  # chunk_key → Array[{billboard, elevation, parent}]
var _finalize_phase: int = 0  # Round-robin: 0=roads, 1=curbs, 2=lamps, 3=buildings, 4=windows, 5=trees, 6=billboards
var _chunk_activation_pending: Dictionary = {}  # chunk_key -> state (-1=waiting, >=0=RS activation index)
var _chunk_culling_cooldown: Dictionary = {}  # chunk_key -> timestamp (ms) — don't cull recently activated chunks

# Global add_child budget — limits scene tree insertions per frame
const ADD_CHILD_BUDGET_NORMAL := 2
var _add_child_budget: int = 2  # Текущий бюджет (увеличен при начальной загрузке)
var _add_child_count: int = 0
var _deferred_add_child_queue: Array = []  # [{parent: Node, child: Node}]
var _deferred_fence_edges: Dictionary = {}  # chunk_key → Array[{chunk_key, p1, p2, edge_idx}]

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
	"track": 3.5,
	"tram": 2.2,
	"tram_rails": 2.2
}

const LANE_WIDTH := 3.5  # Стандартная ширина полосы (метры)

## Ширина дороги с учётом lanes (фолбэк на ROAD_WIDTHS)
static func _get_road_width(tags: Dictionary) -> float:
	var highway_type: String = tags.get("highway", "residential")
	var lanes_str: String = str(tags.get("lanes", ""))
	if lanes_str.is_valid_int():
		var lanes: int = int(lanes_str)
		if lanes >= 1 and lanes <= 8:
			return lanes * LANE_WIDTH
	return ROAD_WIDTHS.get(highway_type, 5.0)

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
# Bridge deck (man_made=bridge relation) — flat platform constants.
# Restored from 7102d8c (Oktyabrsky deck rendering, lost in sk merge).
const BRIDGE_DECK_HEIGHT := 5.0         # Константная высота деки моста над землёй
const BRIDGE_RAMP_LENGTH := 35.0        # Длина рампы на СВОБОДНОМ конце

## Snap start_lat/start_lon to global grid so chunk boundaries are identical
## regardless of the exact start position. Nearby starts (same city) snap to the
## same origin, giving full cache reuse between free-roam and race sessions.
func _snap_origin_to_grid() -> void:
	var lat_step := chunk_size / 111000.0
	# Snap so that chunk centers fall on n * lat_step (matching precache script).
	# Chunk center = start_lat - lat_step/2, so start_lat must be (n+0.5)*lat_step.
	var lat_n := roundi(start_lat / lat_step - 0.5)
	var new_lat: float = snapped(float(lat_n) * lat_step + lat_step * 0.5, 0.0001)

	# Recompute _lon_scale with snapped lat (must match precache: cos of snapped lat)
	_lon_scale = cos(deg_to_rad(new_lat)) * 111000.0
	var lon_step := chunk_size / _lon_scale
	var lon_n := roundi(start_lon / lon_step - 0.5)
	var new_lon: float = snapped(float(lon_n) * lon_step + lon_step * 0.5, 0.0001)

	if absf(new_lat - start_lat) > 0.00001 or absf(new_lon - start_lon) > 0.00001:
		print("OSM: Grid-snapped origin: lat %.6f→%.6f  lon %.6f→%.6f (Δ%.1fm, %.1fm)" % [
			start_lat, new_lat, start_lon, new_lon,
			absf(new_lat - start_lat) * 111000.0,
			absf(new_lon - start_lon) * _lon_scale])
	start_lat = new_lat
	start_lon = new_lon


func _ready() -> void:
	# Cache cosine for _latlon_to_local (avoids cos() every call)
	_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0
	_snap_origin_to_grid()
	_open_runtime_debug_log()

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

	_tram_stop_sign_front_mat = StandardMaterial3D.new()
	_tram_stop_sign_front_mat.albedo_texture = TRAM_STOP_SIGN_TEXTURE
	_tram_stop_sign_front_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_tram_stop_sign_front_mat.alpha_scissor_threshold = 0.5
	_tram_stop_sign_front_mat.metallic = 0.3
	_tram_stop_sign_front_mat.roughness = 0.5

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


func _exit_tree() -> void:
	_close_runtime_debug_log()

func _init_textures() -> void:
	if _textures_initialized:
		return

	print("OSM: Initializing textures...")
	var start_time := Time.get_ticks_msec()

	# Текстуры дорог — PBR текстуры из ambientCG (CC0)
	# Asphalt026B — дороги, Asphalt022 — тротуары
	var road_albedo_tex: Texture2D = load("res://textures/road/Asphalt026B_1K-JPG_Color.jpg")
	var sidewalk_albedo_tex: Texture2D = load("res://textures/road/Asphalt022_1K-JPG_Color.jpg")

	# Albedo — единая PBR текстура асфальта для всех типов дорог
	# Ключи с числом полос: "ow2", "ow3", "bi2", "bi4" и т.д.
	_cached_road_albedo = road_albedo_tex
	for key in ["crossing", "intersection", "residential"]:
		_road_textures[key] = road_albedo_tex
	_road_textures["path"] = sidewalk_albedo_tex
	# Lane-aware keys are registered lazily in _ensure_lane_textures()

	# Tram track textures
	_road_textures["tram_bed"] = TextureGeneratorScript.create_tram_bed(256)
	_road_textures["tram_rails"] = TextureGeneratorScript.create_tram_rails(256)

	# Разметка — общие (без полосовой разметки)
	_road_textures["marking_residential"] = TextureGeneratorScript.create_residential_markings(256)
	_road_textures["marking_crossing"] = TextureGeneratorScript.create_crossing_markings(256)

	# Текстуры люков
	_manhole_albedo = load("res://textures/road/manhole/color_alpha.png")
	_manhole_normal = load("res://textures/road/manhole/normal.png")
	print("OSM Manholes: textures loaded - albedo=%s, normal=%s" % [_manhole_albedo != null, _manhole_normal != null])

	# Текстуры зданий — PBR текстуры из ambientCG (CC0)
	# Bricks053 — светлые здания (panel), Bricks026 — кирпичные (brick)
	var panel_albedo_tex: Texture2D = load("res://textures/walls/Bricks053_1K-JPG_Color.jpg")
	var panel_normal_tex: Texture2D = load("res://textures/walls/Bricks053_1K-JPG_NormalGL.jpg")
	var panel_rough_tex: Texture2D = load("res://textures/walls/Bricks053_1K-JPG_Roughness.jpg")
	var brick_albedo_tex: Texture2D = load("res://textures/walls/Bricks026_1K-JPG_Color.jpg")
	var brick_normal_tex: Texture2D = load("res://textures/walls/Bricks026_1K-JPG_NormalGL.jpg")
	var brick_rough_tex: Texture2D = load("res://textures/walls/Bricks026_1K-JPG_Roughness.jpg")

	_building_textures["panel"] = panel_albedo_tex if panel_albedo_tex else TextureGeneratorScript.create_panel_building_no_windows(256, 5)
	_building_textures["brick"] = brick_albedo_tex if brick_albedo_tex else TextureGeneratorScript.create_brick_building_no_windows(256)
	_building_textures["wall"] = panel_albedo_tex if panel_albedo_tex else TextureGeneratorScript.create_wall_texture(256)
	_building_textures["roof"] = TextureGeneratorScript.create_roof_texture(256)

	# Normal/Roughness maps для стен
	var _wall_normal_textures := {}
	var _wall_roughness_textures := {}
	_wall_normal_textures["panel"] = panel_normal_tex
	_wall_normal_textures["brick"] = brick_normal_tex
	_wall_normal_textures["wall"] = _wall_normal_textures["panel"]
	_wall_roughness_textures["panel"] = panel_rough_tex
	_wall_roughness_textures["brick"] = brick_rough_tex
	_wall_roughness_textures["wall"] = _wall_roughness_textures["panel"]

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
		if _wall_normal_textures.get(tex_type):
			mat.set_shader_parameter("normal_texture", _wall_normal_textures[tex_type])
			mat.set_shader_parameter("use_normal", true)
			mat.set_shader_parameter("normal_strength", 1.0)
		if _wall_roughness_textures.get(tex_type):
			mat.set_shader_parameter("roughness_texture", _wall_roughness_textures[tex_type])
			mat.set_shader_parameter("use_roughness_texture", true)
		_building_wall_materials[tex_type] = mat
		# Recess material — same textures but with vertex color emission for window glow
		var recess_mat := ShaderMaterial.new()
		recess_mat.shader = BuildingWallShader
		if _building_textures.has(tex_type):
			recess_mat.set_shader_parameter("albedo_texture", _building_textures[tex_type])
			recess_mat.set_shader_parameter("use_texture", true)
		else:
			recess_mat.set_shader_parameter("albedo_color", Color(0.7, 0.6, 0.5))
			recess_mat.set_shader_parameter("use_texture", false)
		if _wall_normal_textures.get(tex_type):
			recess_mat.set_shader_parameter("normal_texture", _wall_normal_textures[tex_type])
			recess_mat.set_shader_parameter("use_normal", true)
			recess_mat.set_shader_parameter("normal_strength", 1.0)
		if _wall_roughness_textures.get(tex_type):
			recess_mat.set_shader_parameter("roughness_texture", _wall_roughness_textures[tex_type])
			recess_mat.set_shader_parameter("use_roughness_texture", true)
		recess_mat.set_shader_parameter("use_vertex_emission", true)
		_building_recess_materials[tex_type] = recess_mat

	_building_roof_material = StandardMaterial3D.new()
	_building_roof_material.cull_mode = BaseMaterial3D.CULL_BACK
	if _building_textures.has("roof"):
		_building_roof_material.albedo_texture = _building_textures["roof"]
		_building_roof_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		_building_roof_material.albedo_color = Color(0.15, 0.15, 0.15)

	# Двускатная крыша (шифер/металл) для деревянных домов
	_gabled_roof_material = StandardMaterial3D.new()
	_gabled_roof_material.albedo_color = Color(0.35, 0.38, 0.36)  # Серо-зелёный шифер
	_gabled_roof_material.metallic = 0.3
	_gabled_roof_material.roughness = 0.6
	_gabled_roof_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Парапет использует wall shader для корректной обработки FRONT_FACING
	_building_parapet_material = ShaderMaterial.new()
	_building_parapet_material.shader = BuildingWallShader
	_building_parapet_material.set_shader_parameter("use_texture", false)
	_building_parapet_material.set_shader_parameter("albedo_color", Color(0.5, 0.5, 0.5))
	_building_parapet_material.set_shader_parameter("roughness_base", 0.7)

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

	# Shared material бордюров — ShaderMaterial для FRONT_FACING fix
	# Бордюры не имеют UV, поэтому используем albedo_color вместо текстуры
	_curb_material = ShaderMaterial.new()
	_curb_material.shader = BuildingWallShader  # cull_disabled + FRONT_FACING flip
	_curb_material.set_shader_parameter("use_texture", false)
	_curb_material.set_shader_parameter("albedo_color", Color(0.72, 0.70, 0.66))
	_curb_material.set_shader_parameter("roughness_base", 0.75)

	# Shared material for iron bar fences
	_fence_material = StandardMaterial3D.new()
	_fence_material.albedo_color = Color(0.25, 0.25, 0.28)
	_fence_material.metallic = 0.35
	_fence_material.roughness = 0.85
	_fence_material.cull_mode = BaseMaterial3D.CULL_BACK

	# Текстуры земли - загружаем PBR текстуру травы (Ground037 — дикая трава с проплешинами)
	var grass_tex: Texture2D = load("res://textures/Ground037_1K-JPG_Color.jpg")
	_ground_textures["grass"] = grass_tex if grass_tex else TextureGeneratorScript.create_forest_texture(256)
	var grass_normal_tex: Texture2D = load("res://textures/Ground037_1K-JPG_NormalGL.jpg")
	if grass_normal_tex:
		_ground_textures["grass_normal"] = grass_normal_tex
	var grass_rough_tex: Texture2D = load("res://textures/Ground037_1K-JPG_Roughness.jpg")
	if grass_rough_tex:
		_ground_textures["grass_roughness"] = grass_rough_tex
	_ground_textures["forest"] = TextureGeneratorScript.create_forest_texture(256)
	_ground_textures["water"] = TextureGeneratorScript.create_water_texture(256)

	# Normal maps — PBR normal из ambientCG
	var road_normal_tex: Texture2D = load("res://textures/road/Asphalt026B_1K-JPG_NormalGL.jpg")
	_normal_textures["asphalt"] = road_normal_tex if road_normal_tex else TextureGeneratorScript.create_asphalt_normal(256)
	var sidewalk_normal_tex: Texture2D = load("res://textures/road/Asphalt022_1K-JPG_NormalGL.jpg")
	_normal_textures["sidewalk"] = sidewalk_normal_tex if sidewalk_normal_tex else _normal_textures["asphalt"]

	# Roughness maps — PBR roughness из ambientCG
	var road_rough_tex: Texture2D = load("res://textures/road/Asphalt026B_1K-JPG_Roughness.jpg")
	_road_textures["road_roughness"] = road_rough_tex
	var sidewalk_rough_tex: Texture2D = load("res://textures/road/Asphalt022_1K-JPG_Roughness.jpg")
	_road_textures["sidewalk_roughness"] = sidewalk_rough_tex
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

	# Прогрев кэша кастомных текстур зданий — загружаем все текстуры из textures/buildings/
	# чтобы при генерации чанков не было фризов от файловых проверок
	_preload_custom_building_textures()

	_textures_initialized = true
	var elapsed := Time.get_ticks_msec() - start_time
	print("OSM: Textures initialized in %d ms" % elapsed)

func _preload_custom_building_textures() -> void:
	"""Предзагружает все текстуры зданий и PBR-карты из textures/buildings/ в кэш"""
	var dir := DirAccess.open("res://textures/buildings/")
	if not dir:
		return
	var preloaded := 0
	var pbr_cached := 0
	var suffix_normal := "_normal.png"
	var suffix_ao := "_ambient.png"
	var suffix_spec := "_specular.png"
	var suffix_disp := "_displacement.png"
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and not fname.ends_with(".import"):
			var path := "res://textures/buildings/" + fname
			# Предзагружаем основную текстуру
			if not _custom_building_textures.has(path) and ResourceLoader.exists(path):
				_custom_building_textures[path] = load(path)
				preloaded += 1
			# Кэшируем PBR-карты для основных текстур (не для самих PBR-суффиксов)
			var is_pbr := fname.ends_with(suffix_normal) or fname.ends_with(suffix_ao) or fname.ends_with(suffix_spec) or fname.ends_with(suffix_disp)
			if not is_pbr:
				var base_path := path.get_basename()
				var p_normal := base_path + suffix_normal
				var p_ao := base_path + suffix_ao
				var p_spec := base_path + suffix_spec
				var p_disp := base_path + suffix_disp
				if not _custom_building_maps.has(p_normal):
					_load_texture_map("", p_normal)
					pbr_cached += 1
				if not _custom_building_maps.has(p_ao):
					_load_texture_map("", p_ao)
					pbr_cached += 1
				if not _custom_building_maps.has(p_spec):
					_load_texture_map("", p_spec)
					pbr_cached += 1
				if not _custom_building_maps.has(p_disp):
					_load_texture_map("", p_disp)
					pbr_cached += 1
		fname = dir.get_next()
	dir.list_dir_end()
	print("OSM: Preloaded %d custom building textures, cached %d PBR map lookups" % [preloaded, pbr_cached])


func _init_window_shader() -> void:
	if _window_shader:
		return

	print("OSM: Initializing window shader (compile once, reuse for all batches)...")
	_window_shader = Shader.new()
	_window_shader.code = """
shader_type spatial;
render_mode specular_schlick_ggx;

uniform bool is_night = false;
uniform float emission_energy : hint_range(0.0, 8.0) = 2.5;

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
		vec3 window_color = COLOR.rgb * brightness;
		ALBEDO = window_color;
		EMISSION = window_color * emission_energy;
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
	crown_mat.vertex_color_use_as_albedo = true
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
			# Включаем vertex_color для кроны (зелёный материал) — для per-instance вариативности
			if mat is StandardMaterial3D:
				var smat: StandardMaterial3D = mat.duplicate()
				if smat.albedo_color.g > smat.albedo_color.r and smat.albedo_color.g > smat.albedo_color.b:
					smat.vertex_color_use_as_albedo = true
				mat = smat
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
	_lamp_light_offset = Vector3(-0.6, aabb.end.y - 0.17, 0)

	var total_tris := 0
	for s in range(_lamp_model_mesh.get_surface_count()):
		var idx = _lamp_model_mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
		if idx:
			total_tris += idx.size() / 3
	print("OSM: Street lamp model loaded: %d surfaces, %d tris, light at Y=%.1f" % [
		_lamp_model_mesh.get_surface_count(), total_tris, _lamp_light_offset.y
	])



func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L:
			_lamp_debug_visible = not _lamp_debug_visible
			get_tree().call_group("lamp_debug_vis", "set_visible", _lamp_debug_visible)
			print("OSM: Lamp debug vis = %s" % _lamp_debug_visible)

func _process(delta: float) -> void:
	var _frame_start := Time.get_ticks_usec()
	_current_frame_perf.clear()
	_slow_frame_cooldown -= delta
	# Кешируем позицию и направление камеры для приоритизации чанков
	var _vp := get_viewport()
	if _vp:
		var _cam := _vp.get_camera_3d()
		if _cam:
			_cached_cam_pos = _cam.global_position
			var fwd := -_cam.global_transform.basis.z
			fwd.y = 0.0
			_cached_cam_fwd = fwd.normalized() if fwd.length_squared() > 0.001 else Vector3.FORWARD

	# Reset add_child budget and drain deferred queue (with time budget)
	_add_child_budget = 9999 if _initial_loading else ADD_CHILD_BUDGET_NORMAL
	_add_child_count = 0
	var _ac_t0 := Time.get_ticks_usec()
	var AC_TIME_BUDGET_USEC := 500000 if _initial_loading else 2000  # 2ms normal, unlimited initial
	while not _deferred_add_child_queue.is_empty() and _add_child_count < _add_child_budget:
		if _add_child_count > 0 and (Time.get_ticks_usec() - _ac_t0) > AC_TIME_BUDGET_USEC:
			break
		var ac_item: Dictionary = _deferred_add_child_queue[0]
		if is_instance_valid(ac_item["parent"]) and is_instance_valid(ac_item["child"]):
			ac_item["parent"].add_child(ac_item["child"])
			_add_child_count += 1
		_deferred_add_child_queue.pop_front()
	_record_perf("add_child_drain", Time.get_ticks_usec() - _ac_t0)

	# Clean up stuck chunk loads in real-time
	_clean_timed_out_chunks()

	# Обрабатываем готовые здания из worker threads (даже на паузе)
	# Each queue below manages its own time budget independently
	var t0 := Time.get_ticks_usec()
	_process_building_results()
	var t_building := Time.get_ticks_usec() - t0
	_record_perf("building_results", t_building)

	# Обрабатываем очередь дорог (has own 4ms/6ms budget)
	var t_road := 0
	t0 = Time.get_ticks_usec()
	_process_road_queue()
	t_road = Time.get_ticks_usec() - t0
	_record_perf("road_queue", t_road)

	# Apply threaded terrain generation results FIRST (Phase 1+2: road/building spatial hash)
	# Must run before vegetation/infrastructure so trees & lamps can check road hash
	if not _terrain_gen_results.is_empty():
		t0 = Time.get_ticks_usec()
		_apply_terrain_gen_result()
		_record_perf("terrain_gen_apply", Time.get_ticks_usec() - t0)

	# Process Phase 3 queue (ways, intersections, points, finalize)
	# Must run before vegetation so procedural trees see all roads from this chunk
	# Critical pipeline step — always runs (has own internal 4ms budget)
	if not _phase3_queue.is_empty():
		t0 = Time.get_ticks_usec()
		# During initial loading, drain multiple chunks per frame within 500ms budget.
		# During gameplay, process one chunk's phase per frame to avoid stutter.
		var phase3_budget_us: int = 500000 if _initial_loading else 4000
		var phase3_iterations := 0
		var phase3_max_iterations: int = 32 if _initial_loading else 1
		while phase3_iterations < phase3_max_iterations:
			phase3_iterations += 1
			if (Time.get_ticks_usec() - t0) > phase3_budget_us:
				break
			if _phase3_queue.is_empty():
				break
			if not _process_phase3_queue():
				break
		_record_perf("phase3_queue", Time.get_ticks_usec() - t0)

	# Обрабатываем очередь terrain объектов (has own 2ms budget)
	var t_terrain := 0
	t0 = Time.get_ticks_usec()
	_process_terrain_objects_queue()
	t_terrain = Time.get_ticks_usec() - t0
	_record_perf("terrain_queue", t_terrain)

	# Обрабатываем очередь инфраструктуры (has own 2ms budget)
	var t_infra := 0
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

	# Создаём отложенные ноды с бюджетом (buildings, trees, roads collision)
	# Each sub-queue has own budget — always runs
	t0 = Time.get_ticks_usec()
	_process_deferred_nodes()
	_record_perf("deferred_nodes", Time.get_ticks_usec() - t0)

	# Лампы — отдельно
	t0 = Time.get_ticks_usec()
	_process_deferred_lamp_lights()
	_record_perf("lamp_lights", Time.get_ticks_usec() - t0)

	# Применяем готовые результаты клиппинга террейна из worker threads
	# Critical pipeline step — terrain mesh finalization (has own 3ms budget)
	var t_terrain_gen := 0
	t0 = Time.get_ticks_usec()
	_apply_terrain_thread_results()
	t_terrain_gen = Time.get_ticks_usec() - t0
	_record_perf("terrain_gen", t_terrain_gen)

	# Process deferred fence edges incrementally (own 2ms budget)
	if not _deferred_fence_edges.is_empty():
		t0 = Time.get_ticks_usec()
		_process_deferred_fence_edges(t0, 2000)
		_record_perf("fence_gen", Time.get_ticks_usec() - t0)

	# Lazy chunk activation — включаем видимость через N кадров после финализации
	t0 = Time.get_ticks_usec()
	_process_chunk_activation()
	_record_perf("chunk_activation", Time.get_ticks_usec() - t0)

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

	# Детальное логирование при реальном delta > 16ms (< 60fps), не чаще раза в секунду
	var _real_frame_ms := delta * 1000.0
	if _real_frame_ms > 16.0 and _slow_frame_cooldown <= 0.0:
		_slow_frame_cooldown = 1.0
		if not _viewport_rid.is_valid() and get_viewport():
			_viewport_rid = get_viewport().get_viewport_rid()
		var sf_render_cpu := 0.0
		var sf_render_gpu := 0.0
		if _viewport_rid.is_valid():
			sf_render_cpu = RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
			sf_render_gpu = RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var sf_draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var sf_vertices := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		var sf_objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		var sf_phys_bodies := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
		var sf_phys_pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		var sf_nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var sf_resources := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		var sf_vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
		# Определяем bottleneck
		var sf_bottleneck: String
		if sf_render_gpu < 0.01 and sf_render_cpu < 0.01:
			sf_bottleneck = "GPU timing N/A"
		elif sf_render_cpu > sf_render_gpu:
			sf_bottleneck = "CPU-bound"
		else:
			sf_bottleneck = "GPU-bound"
		print("")
		print("===== SLOW FRAME #%d (delta=%.1fms, %.0f FPS) [%s] =====" % [
			Engine.get_process_frames(), _real_frame_ms, Engine.get_frames_per_second(), sf_bottleneck])
		print("  Render: CPU=%.1fms GPU=%.1fms" % [sf_render_cpu, sf_render_gpu])
		# Our _process breakdown — print ALL subsystems from _current_frame_perf
		print("  OSM _process: %.1fms breakdown:" % _frame_time)
		# Sort by time descending so biggest contributors are first
		var perf_items: Array = []
		var accounted_ms := 0.0
		for pk in _current_frame_perf:
			if pk == "total_frame":
				continue
			var pv: float = _current_frame_perf[pk]
			if pv >= 0.01:
				perf_items.append({"name": pk, "ms": pv})
				accounted_ms += pv
		perf_items.sort_custom(func(a, b): return a.ms > b.ms)
		var perf_parts: PackedStringArray = []
		for pi in perf_items:
			perf_parts.append("%s=%.2fms" % [pi.name, pi.ms])
		if perf_parts.size() > 0:
			print("    %s" % " | ".join(perf_parts))
		print("    unaccounted=%.2fms" % maxf(0.0, _frame_time - accounted_ms))
		# Scene stats
		print("  Scene: draws=%d verts=%.1fM objects=%d nodes=%d resources=%d" % [
			sf_draw_calls, sf_vertices / 1_000_000.0, sf_objects, sf_nodes, sf_resources])
		print("  Physics: bodies=%d pairs=%d | VRAM=%.0fMB" % [
			sf_phys_bodies, sf_phys_pairs, sf_vram])
		# Queues
		print("  Queues: roads=%d terrain=%d infra=%d buildings=%d curbs=%d" % [
			_road_queue_total_size(), _terrain_objects_queue.size(), _infrastructure_queue.size(),
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

	# Выгружаем до 3 чанков за кадр (из очереди) — spread across frames
	var _unload_t0 := Time.get_ticks_usec()
	var unloaded := 0
	while not _chunks_to_unload.is_empty() and unloaded < 3:
		var unload_key: String = _chunks_to_unload.pop_front()
		if _loaded_chunks.has(unload_key):
			_unload_chunk(unload_key)
		unloaded += 1
	_record_perf("chunk_unload", Time.get_ticks_usec() - _unload_t0)

	_check_timer += delta
	if _check_timer < _check_interval:
		return
	_check_timer = 0.0

	# Определяем позицию для загрузки чанков
	# Всегда используем позицию машины — камера может быть далеко (fly mode, cinematic)
	var player_pos := Vector3.ZERO
	if _car and is_instance_valid(_car):
		player_pos = _car.global_position
	else:
		var viewport := get_viewport()
		if viewport:
			var current_cam := viewport.get_camera_3d()
			if current_cam:
				player_pos = current_cam.global_position

	# Проверяем нужны ли новые чанки (с предиктивной загрузкой по направлению)
	var _uc_t0 := Time.get_ticks_usec()
	var velocity := Vector3.ZERO
	if _car and is_instance_valid(_car) and _car is RigidBody3D:
		velocity = _car.linear_velocity
	elif delta > 0.001:
		velocity = (player_pos - _last_player_pos) / delta
	_last_player_pos = player_pos
	_update_chunks_simple_predictive(player_pos, velocity)
	_record_perf("update_chunks", Time.get_ticks_usec() - _uc_t0)

	# Обновляем тени зданий и деревьев по расстоянию до игрока
	_update_building_shadows(player_pos)
	_update_tree_shadows(player_pos)

# Начать загрузку карты
func start_loading() -> void:
	# Re-snap origin in case start_lat/start_lon were changed after _ready().
	_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0
	_snap_origin_to_grid()
	print("OSM: Starting initial loading... (generation %d)" % _load_generation)
	print("OSM: State before start: _loaded_chunks=%d, _loading_chunks=%d" % [_loaded_chunks.size(), _loading_chunks.size()])

	# ПРИНУДИТЕЛЬНАЯ очистка на случай если reset_terrain не очистил
	if _loaded_chunks.size() > 0:
		print("OSM: WARNING - _loaded_chunks not empty, clearing...")
		_loaded_chunks.clear()
	if _loading_chunks.size() > 0:
		print("OSM: WARNING - _loading_chunks not empty, clearing...")
		_loading_chunks.clear()
	_chunk_data_received.clear()
	_chunk_state.clear()
	_elevation_in_flight.clear()

	_loading_paused = false
	_initial_loading = true
	_initial_chunks_loaded = 0
	_initial_chunks_completed.clear()
	_chunk_profile.clear()
	_parking_polygons.clear()  # Очищаем парковки при новой загрузке
	_parking_bounds.clear()
	_parking_spatial_hash.clear()
	_water_polygons.clear()
	_water_spatial_hash.clear()
	_chunk_hash_cells.clear()
	_chunk_road_hashes.clear()
	_chunk_building_hashes.clear()
	_chunk_building_poly_hashes.clear()
	_chunk_parking_hashes.clear()
	_chunk_water_hashes.clear()
	_chunk_intersection_hashes.clear()
	_created_lamp_positions.clear()  # Очищаем позиции фонарей
	_created_bus_stop_positions.clear()  # Очищаем позиции остановок
	_pending_parking_signs.clear()  # Очищаем отложенные знаки парковки
	_deferred_lamp_queue.clear()
	_deferred_manhole_queue.clear()
	_deferred_traffic_queue.clear()
	_deferred_tram_queue.clear()
	_dispatched_tram_network.clear()
	_deferred_billboard_queue.clear()
	_deferred_footway_queue.clear()
	_deferred_building_collisions.clear()
	_deferred_tree_collisions.clear()
	_deferred_lamp_lights.clear()
	_deferred_road_collisions.clear()
	_deferred_terrain_collisions.clear()
	_deferred_fence_edges.clear()
	_chunk_activation_pending.clear()
	_chunk_culling_cooldown.clear()
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
	_chunk_water_polygons.clear()
	_global_water_polygons.clear()
	_global_water_polygon_bboxes.clear()
	_global_water_polygon_hashes.clear()
	_deferred_terrain_chunks.clear()
	# Clear threaded terrain gen results
	_terrain_thread_mutex.lock()
	_terrain_gen_results.clear()
	_terrain_thread_mutex.unlock()
	_pending_terrain_gen_tasks = 0
	_phase3_queue.clear()

	# Reconnect night mode after reset
	_connect_to_night_mode()

	# Определяем какие чанки нужны для старта
	# Используем позицию машины если она есть, иначе Vector3.ZERO
	var spawn_pos := Vector3.ZERO
	if _car and is_instance_valid(_car):
		spawn_pos = _car.global_position
		print("OSM: Loading chunks around car position (%.1f, %.1f, %.1f)" % [spawn_pos.x, spawn_pos.y, spawn_pos.z])
	else:
		print("OSM: Loading chunks around spawn point (0, 0, 0) [_car is null or freed]")

	_initial_chunks_needed = _get_initial_chunks(spawn_pos)
	# Сортируем начальные чанки: ближайшие к камере первыми
	if _initial_chunks_needed.size() > 1:
		_initial_chunks_needed.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	print("OSM: Need to load %d chunks for initial area" % _initial_chunks_needed.size())

	print("OSM: Emitting initial_load_started signal...")
	initial_load_started.emit()
	print("OSM: initial_load_started signal emitted")

	# Загружаем начальные чанки (уже отсортированы по приоритету)
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

	# Считаем сколько начальных чанков завершили phase3 (не зависит от unload)
	var loaded_count := 0
	for chunk_key in _initial_chunks_needed:
		if _initial_chunks_completed.has(chunk_key):
			loaded_count += 1

	_initial_chunks_loaded = loaded_count

	# Считаем общий прогресс: 50% на чанки, 50% на очереди
	var total_chunks: int = _initial_chunks_needed.size()
	var chunk_progress: float = float(loaded_count) / float(max(1, total_chunks))  # 0.0-1.0

	# Считаем размер всех очередей (включая финализацию визуала и deferred лампы)
	# Read _pending_road_tasks under mutex (modified by worker threads)
	_road_mutex.lock()
	var pending_road_snapshot: int = _pending_road_tasks
	var road_results_pending: int = _road_results.size()
	_road_mutex.unlock()
	var total_queued: int = _building_results.size() + _road_queue_total_size() + road_results_pending + _terrain_objects_queue.size() + _infrastructure_queue.size() + _pending_building_tasks + pending_road_snapshot + _pending_veg_tasks + _pending_terrain_tasks + _deferred_total_size(_deferred_lamp_queue) + _deferred_total_size(_deferred_manhole_queue) + _deferred_traffic_queue.size() + _pending_batch_chunks.size() + _building_geo_finalize_queue.size() + _curb_geo_batch.size() + _lamp_batches_to_finalize.size() + _tree_batches_to_finalize.size() + _billboard_batches_to_finalize.size() + _window_finalize_queue.size() + _deferred_total_size(_deferred_footway_queue) + _deferred_total_size(_deferred_billboard_queue) + _chunk_activation_pending.size() + _deferred_total_size(_deferred_lamp_lights) + _phase3_queue.size()

	# DEBUG: Детальное логирование очередей
	if loaded_count >= total_chunks and total_queued > 0:
		print("OSM DEBUG: Chunks loaded %d/%d, queues=%d:" % [loaded_count, total_chunks, total_queued])
		print("  data: bld=%d road=%d(thr:%d,res:%d) terr=%d infra=%d pBld=%d pRoad=%d pVeg=%d pTerr=%d lamp=%d manhole=%d traffic=%d" % [_building_results.size(), _road_queue_total_size(), pending_road_snapshot, road_results_pending, _terrain_objects_queue.size(), _infrastructure_queue.size(), _pending_building_tasks, pending_road_snapshot, _pending_veg_tasks, _pending_terrain_tasks, _deferred_total_size(_deferred_lamp_queue), _deferred_total_size(_deferred_manhole_queue), _deferred_traffic_queue.size()])
		print("  finalize: roadBatch=%d bldGeo=%d curb=%d lamp=%d tree=%d billboard=%d window=%d" % [_pending_batch_chunks.size(), _building_geo_finalize_queue.size(), _curb_geo_batch.size(), _lamp_batches_to_finalize.size(), _tree_batches_to_finalize.size(), _billboard_batches_to_finalize.size(), _window_finalize_queue.size()])

	# DEBUG: Проверяем зависшие чанки в _loading_chunks
	if loaded_count < total_chunks:
		var missing_chunks: Array[String] = []
		for chunk_key in _initial_chunks_needed:
			if not _initial_chunks_completed.has(chunk_key):
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
				# Keep placeholder — don't remove on retry (prevents blinking)
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

	_initial_load_debug_timer += get_process_delta_time()
	if _initial_load_debug_timer >= 2.0:
		_initial_load_debug_timer = 0.0
		print("OSM LOAD DEBUG: %d/%d chunks, queued=%d, progress=%.1f%% phase3=%d loading=%s" % [
			loaded_count, total_chunks, total_queued, total_progress * 100.0,
			_phase3_queue.size(), str(_loading_chunks.keys())])
	initial_load_progress.emit(total_progress, status)

	# Все начальные чанки загружены?
	if loaded_count >= total_chunks:
		# Ждём только очереди для НАЧАЛЬНЫХ 16 чанков, остальные достроятся на фоне
		var initial_set: Dictionary = {}
		for ck in _initial_chunks_needed:
			initial_set[ck] = true
		var initial_queued := false
		# phase3 — есть ли наши чанки
		for p3 in _phase3_queue:
			if initial_set.has(p3.chunk_key):
				initial_queued = true
				break
		# Finalization arrays — содержат ли начальные чанки
		if not initial_queued:
			for ck in _pending_batch_chunks:
				if initial_set.has(ck):
					initial_queued = true
					break
		if not initial_queued:
			for ck in _building_geo_finalize_queue:
				if initial_set.has(ck):
					initial_queued = true
					break
		if not initial_queued:
			for ck in _lamp_batches_to_finalize:
				if initial_set.has(ck):
					initial_queued = true
					break
		if not initial_queued:
			for ck in _tree_batches_to_finalize:
				if initial_set.has(ck):
					initial_queued = true
					break
		if not initial_queued:
			for ck in _billboard_batches_to_finalize:
				if initial_set.has(ck):
					initial_queued = true
					break
		# Activation pending для начальных
		if not initial_queued:
			for ck in _chunk_activation_pending:
				if initial_set.has(ck):
					initial_queued = true
					break
		var queues_empty := not initial_queued
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
			initial_load_progress.emit(0.95, "Финализация: создание света фонарей...")
			# Создаём все отложенные SpotLight3D сразу (без бюджета)
			var lamp_light_count := 0
			for ll_ck2 in _deferred_lamp_lights.keys():
				var ll_arr2: Array = _deferred_lamp_lights[ll_ck2]
				while not ll_arr2.is_empty():
					var item: Dictionary = ll_arr2[0]
					var container: Node3D = item["container"]
					if not is_instance_valid(container):
						ll_arr2.pop_front()
						continue
					var lights: Array = item["lights"]
					var chunk_key: String = item["chunk_key"]
					var idx: int = item.get("idx", 0)
					while idx < lights.size():
						var light_data: Dictionary = lights[idx]
						var light := SpotLight3D.new()
						light.position = light_data.position
						light.rotation_degrees.y = rad_to_deg(light_data.get("yaw", 0.0) - PI / 2.0 + PI)
						light.rotation_degrees.x = -75
						light.spot_range = 15.0
						light.spot_angle = 70.0
						light.spot_attenuation = 1.0
						light.light_energy = 2.6
						light.light_color = Color(1.0, 0.65, 0.2)
						light.light_volumetric_fog_energy = 16.0
						light.shadow_enabled = false
						light.light_bake_mode = Light3D.BAKE_DISABLED
						light.distance_fade_enabled = true
						light.distance_fade_begin = 120.0
						light.distance_fade_shadow = 30.0
						light.distance_fade_length = 30.0
						light.visible = _is_night_mode and not light_data.broken
						light.set_meta("broken", light_data.broken)
						light.add_child(_create_lamp_bulb())
						light.add_child(_create_debug_light_cone(light.spot_range, light.spot_angle))
						container.add_child(light)
						if _lamp_lights_by_chunk.has(chunk_key):
							_lamp_lights_by_chunk[chunk_key].append(light)
						lamp_light_count += 1
						idx += 1
					ll_arr2.pop_front()
			_deferred_lamp_lights.clear()
			print("OSM: Created %d lamp lights during finalization" % lamp_light_count)
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

	# Загружаем недостающие — ближайшие к камере первыми
	var chunks_to_load: Array[String] = []
	for chunk_key in needed_chunks:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			chunks_to_load.append(chunk_key)
	if chunks_to_load.size() > 1:
		chunks_to_load.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	for chunk_key in chunks_to_load:
		_enqueue_chunk_load_request(chunk_key, -_chunk_priority_score(chunk_key))
	_process_chunk_load_queue()

	# Выгружаем далёкие чанки
	for chunk_key in _loaded_chunks:
		if _chunks_to_unload.has(chunk_key):
			continue
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector2(chunk_x * chunk_size + chunk_size / 2, chunk_z * chunk_size + chunk_size / 2)
		if Vector2(player_pos.x, player_pos.z).distance_to(chunk_center) > unload_distance:
			_chunks_to_unload.append(chunk_key)

## Фиксированные 16 чанков для начальной загрузки (4×4, по 2 в каждую сторону)
func _get_initial_chunks(player_pos: Vector3) -> Array[String]:
	var result: Array[String] = []
	var player_chunk_x := int(floor(player_pos.x / chunk_size))
	var player_chunk_z := int(floor(player_pos.z / chunk_size))
	for dx in range(-2, 2):
		for dz in range(-2, 2):
			var cx := player_chunk_x + dx
			var cz := player_chunk_z + dz
			if chunk_filter.is_valid() and not chunk_filter.call(cx, cz):
				continue
			result.append("%d,%d" % [cx, cz])
	return result


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
			var chunk_center := Vector2(cx * chunk_size + chunk_size / 2, cz * chunk_size + chunk_size / 2)
			if Vector2(player_pos.x, player_pos.z).distance_to(chunk_center) <= load_distance:
				if chunk_filter.is_valid() and not chunk_filter.call(cx, cz):
					continue
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

	# Загружаем недостающие — ближайшие к камере первыми
	var chunks_to_load: Array[String] = []
	for chunk_key in needed_chunks:
		if not _loaded_chunks.has(chunk_key) and not _loading_chunks.has(chunk_key):
			chunks_to_load.append(chunk_key)
	if chunks_to_load.size() > 1:
		chunks_to_load.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	for chunk_key in chunks_to_load:
		_enqueue_chunk_load_request(chunk_key, -_chunk_priority_score(chunk_key))
	_process_chunk_load_queue()

	# Выгружаем далёкие чанки — сзади быстрее (300м), спереди дальше (unload_distance)
	var move_dir := velocity.normalized() if speed > min_speed_for_prediction else Vector3.ZERO
	for chunk_key in _loaded_chunks:
		if _chunks_to_unload.has(chunk_key):
			continue
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector2(chunk_x * chunk_size + chunk_size / 2, chunk_z * chunk_size + chunk_size / 2)
		var dist := Vector2(player_pos.x, player_pos.z).distance_to(chunk_center)
		var max_dist := unload_distance
		if move_dir.length_squared() > 0.5:
			var player_xz := Vector2(player_pos.x, player_pos.z)
			var to_chunk := (chunk_center - player_xz).normalized()
			var move_xz := Vector2(move_dir.x, move_dir.z)
			if to_chunk.dot(move_xz) < -0.3:  # Чанк сзади
				max_dist = 300.0
		if dist > max_dist:
			_chunks_to_unload.append(chunk_key)

	# Отменяем загрузку далёких чанков (ещё не загрузились — только HTTP в процессе)
	var cancel_keys: Array[String] = []
	for chunk_key in _loading_chunks:
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		var chunk_center := Vector2(chunk_x * chunk_size + chunk_size / 2, chunk_z * chunk_size + chunk_size / 2)
		var dist := Vector2(player_pos.x, player_pos.z).distance_to(chunk_center)
		var max_dist := unload_distance
		if move_dir.length_squared() > 0.5:
			var player_xz := Vector2(player_pos.x, player_pos.z)
			var to_chunk := (chunk_center - player_xz).normalized()
			var move_xz := Vector2(move_dir.x, move_dir.z)
			if to_chunk.dot(move_xz) < -0.3:
				max_dist = 300.0
		if dist > max_dist:
			cancel_keys.append(chunk_key)
	for chunk_key in cancel_keys:
		print("OSM: Cancelling loading chunk %s (too far)" % chunk_key)
		_loading_chunks.erase(chunk_key)
		_chunk_load_queue = _chunk_load_queue.filter(func(c): return c["key"] != chunk_key)
		_remove_loading_placeholder(chunk_key)
		_current_load_count = maxi(0, _current_load_count - 1)


## Старая сложная предиктивная загрузка (отключена)
func _update_chunks_predictive(player_pos: Vector3, velocity: Vector3) -> void:
	# Получаем приоритизированный список чанков
	var predicted_chunks := _get_predicted_chunks(player_pos, velocity)

	# Добавляем новые чанки в очередь
	for chunk_data in predicted_chunks:
		_enqueue_chunk_load_request(chunk_data["key"], chunk_data["priority"])
	_process_chunk_load_queue()

	# Направленная выгрузка
	_unload_distant_chunks(player_pos, velocity)


## Загрузка чанка с отслеживанием количества
func _load_chunk_tracked(chunk_x: int, chunk_z: int) -> void:
	_current_load_count += 1
	_load_chunk(chunk_x, chunk_z)


func _enqueue_chunk_load_request(chunk_key: String, priority: float) -> void:
	if chunk_key == "":
		return
	if _loaded_chunks.has(chunk_key) or _loading_chunks.has(chunk_key):
		return
	for idx in range(_chunk_load_queue.size()):
		var queued: Dictionary = _chunk_load_queue[idx]
		if queued["key"] == chunk_key:
			if priority > queued["priority"]:
				queued["priority"] = priority
				_chunk_load_queue[idx] = queued
				_chunk_load_queue.sort_custom(func(a, b): return a["priority"] > b["priority"])
			return
	_chunk_load_queue.append({
		"key": chunk_key,
		"priority": priority,
	})
	_chunk_load_queue.sort_custom(func(a, b): return a["priority"] > b["priority"])


func _process_chunk_load_queue() -> void:
	while _current_load_count < MAX_CONCURRENT_LOADS and _chunk_load_queue.size() > 0:
		var next_chunk: Dictionary = _chunk_load_queue.pop_front()
		var chunk_key: String = next_chunk["key"]
		if _loaded_chunks.has(chunk_key) or _loading_chunks.has(chunk_key):
			continue
		var coords: Array = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])
		_load_chunk_tracked(chunk_x, chunk_z)


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
		var chunk_center := Vector2(
			chunk_x * chunk_size + chunk_size / 2,
			chunk_z * chunk_size + chunk_size / 2
		)

		var dist := Vector2(player_pos.x, player_pos.z).distance_to(chunk_center)

		# При низкой скорости - стандартная радиальная выгрузка
		if speed < min_speed_for_prediction:
			if dist > unload_distance:
				chunks_to_unload.append(chunk_key)
			continue

		# Направленная выгрузка
		var player_xz := Vector2(player_pos.x, player_pos.z)
		var to_chunk := chunk_center - player_xz
		var dir_to_chunk := to_chunk.normalized() if to_chunk.length() > 0.01 else Vector2.ZERO
		var move_xz := Vector2(move_dir.x, move_dir.z)
		var alignment := move_xz.dot(dir_to_chunk)

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
	var chunk_center := Vector2(
		chunk_x * chunk_size + chunk_size / 2,
		chunk_z * chunk_size + chunk_size / 2
	)
	return Vector2(pos.x, pos.z).distance_to(chunk_center)


func _create_loading_placeholder(chunk_key: String, chunk_x: int, chunk_z: int) -> void:
	if _loading_placeholders.has(chunk_key):
		return
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "LoadingPlaceholder_" + chunk_key
	var box := BoxMesh.new()
	box.size = Vector3(chunk_size - 2.0, 0.3, chunk_size - 2.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.35, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = mat
	mesh_inst.mesh = box
	mesh_inst.position = Vector3(
		chunk_x * chunk_size + chunk_size * 0.5,
		0.05,
		chunk_z * chunk_size + chunk_size * 0.5
	)
	add_child(mesh_inst)
	_loading_placeholders[chunk_key] = mesh_inst


func _set_placeholder_processing(chunk_key: String) -> void:
	if _loading_placeholders.has(chunk_key):
		var ph: MeshInstance3D = _loading_placeholders[chunk_key]
		if is_instance_valid(ph):
			var mat: StandardMaterial3D = (ph.mesh as BoxMesh).material
			mat.albedo_color = Color(0.3, 0.45, 0.7, 0.6)  # Blue = processing


func _remove_loading_placeholder(chunk_key: String) -> void:
	if _loading_placeholders.has(chunk_key):
		var ph: MeshInstance3D = _loading_placeholders[chunk_key]
		if is_instance_valid(ph):
			ph.queue_free()
		_loading_placeholders.erase(chunk_key)


func _load_chunk(chunk_x: int, chunk_z: int) -> void:
	var chunk_key := "%d,%d" % [chunk_x, chunk_z]
	var request_started_ms := Time.get_ticks_msec()
	_loading_chunks[chunk_key] = request_started_ms  # Сохраняем время начала загрузки
	var state: Dictionary = _ensure_chunk_state(chunk_key)
	var existing_node: Node3D = state.get("node", null)
	if existing_node and not is_instance_valid(existing_node):
		state["node"] = null
	state["generation"] = _load_generation
	state["request_started_ms"] = request_started_ms
	state["data_loaded_ms"] = 0
	state["tgen_applied_ms"] = 0
	state["phase3_done_ms"] = 0
	state["finalize_done_ms"] = 0
	state["activated_ms"] = 0
	state["last_error"] = ""
	state["cancelled"] = false
	_chunk_state[chunk_key] = state
	_set_chunk_stage(chunk_key, "requested")
	_emit_chunk_debug("CHUNK_REQUEST key=%s gen=%d request_started_ms=%d" % [
		chunk_key,
		_load_generation,
		request_started_ms
	])

	# Create visible placeholder box while chunk loads
	_create_loading_placeholder(chunk_key, chunk_x, chunk_z)

	# Вычисляем центр чанка в координатах lat/lon
	var center_x := chunk_x * chunk_size + chunk_size / 2
	var center_z := chunk_z * chunk_size + chunk_size / 2

	# Конвертируем локальные координаты обратно в lat/lon
	# Z инвертирован в системе координат, поэтому вычитаем
	var chunk_lat := start_lat - center_z / 111000.0
	var chunk_lon := start_lon + center_x / (111000.0 * cos(deg_to_rad(start_lat)))

	# Привязка к глобальной сетке — кеш переиспользуется независимо от точки спавна
	# Snap lat first, then use snapped lat for lon_step (must match Python precache script)
	var lat_step := chunk_size / 111000.0
	var lat_idx := int(roundf(chunk_lat / lat_step))
	chunk_lat = snapped(float(lat_idx) * lat_step, 0.0001)
	var lon_step := chunk_size / (111000.0 * cos(deg_to_rad(chunk_lat)))
	var lon_idx := int(roundf(chunk_lon / lon_step))
	chunk_lon = snapped(float(lon_idx) * lon_step, 0.0001)

	print("OSM: Loading chunk %s at lat=%.4f, lon=%.4f" % [chunk_key, chunk_lat, chunk_lon])

	# Тестовый режим — данные без HTTP, но тот же async flow что и в игре
	if test_data_provider.is_valid():
		var osm_data: Dictionary = test_data_provider.call(chunk_lat, chunk_lon, chunk_size)
		osm_data["center_lat"] = chunk_lat
		osm_data["center_lon"] = chunk_lon
		var fake_loader := Node.new()
		fake_loader.name = "FakeLoader_" + chunk_key
		add_child(fake_loader)
		# Test mode: store empty elevation so phase3 won't wait
		if enable_elevation and not _chunk_elevation_data.has(chunk_key):
			_chunk_elevation_data[chunk_key] = {}
		_on_chunk_data_loaded(osm_data, chunk_key, fake_loader, _load_generation)
		return

	# Создаём отдельный загрузчик для этого чанка
	var loader := OSMLoaderScript.new()
	add_child(loader)
	var gen := _load_generation  # Захватываем текущую генерацию
	loader.data_loaded.connect(_on_chunk_data_loaded.bind(chunk_key, loader, gen))
	loader.load_failed.connect(_on_chunk_load_failed.bind(chunk_key, loader, gen))
	loader.load_area(chunk_lat, chunk_lon, maxf(chunk_size, 150.0) + chunk_size / 2)  # overlap не менее 150м с каждой стороны

	# Elevation — independent parallel request
	if enable_elevation:
		_request_elevation(chunk_key, chunk_x, chunk_z)

func _load_chunk_at_position(pos: Vector3) -> void:
	var chunk_x := int(floor(pos.x / chunk_size))
	var chunk_z := int(floor(pos.z / chunk_size))
	_load_chunk(chunk_x, chunk_z)

func _request_elevation(chunk_key: String, cx: int, cz: int) -> void:
	if _chunk_elevation_data.has(chunk_key):
		return  # Already loaded (in-memory)
	if _elevation_in_flight.has(chunk_key):
		return  # Request already in progress
	_elevation_in_flight[chunk_key] = true
	var loader := ElevationLoaderScript.new()
	add_child(loader)
	var gen := _load_generation
	loader.elevation_loaded.connect(_on_elevation_loaded.bind(gen, loader))
	loader.elevation_failed.connect(_on_elevation_failed.bind(gen, loader))
	loader.load_elevation(chunk_key, cx, cz, chunk_size, start_lat, start_lon)


func _on_elevation_loaded(chunk_key: String, grid_data: Dictionary, gen: int, loader: Node) -> void:
	if is_instance_valid(loader):
		loader.queue_free()
	_elevation_in_flight.erase(chunk_key)
	if gen != _load_generation:
		return  # Stale
	_chunk_elevation_data[chunk_key] = grid_data


var _elevation_retries: Dictionary = {}  # chunk_key -> retry count
const MAX_ELEVATION_RETRIES := 3

func _on_elevation_failed(chunk_key: String, error: String, gen: int, loader: Node) -> void:
	if is_instance_valid(loader):
		loader.queue_free()
	_elevation_in_flight.erase(chunk_key)
	if gen != _load_generation:
		return
	var retries: int = _elevation_retries.get(chunk_key, 0)
	if retries < MAX_ELEVATION_RETRIES:
		_elevation_retries[chunk_key] = retries + 1
		push_warning("ELEV: Failed %s: %s — retry %d/%d" % [chunk_key, error, retries + 1, MAX_ELEVATION_RETRIES])
		var coords: Array = chunk_key.split(",")
		_request_elevation(chunk_key, int(coords[0]), int(coords[1]))
	else:
		push_warning("ELEV: Failed %s after %d retries: %s — chunk will render flat" % [chunk_key, MAX_ELEVATION_RETRIES, error])
		# Store empty dict so phase3 won't wait forever
		_chunk_elevation_data[chunk_key] = {}


func _clean_timed_out_chunks() -> void:
	if _loading_chunks.is_empty():
		return
	# During initial loading, timeouts are handled by _check_initial_load_progress
	if _initial_loading:
		return
	var current_time := Time.get_ticks_msec()
	var timed_out: Array[String] = []
	for chunk_key in _loading_chunks.keys():
		var load_start_time: int = _loading_chunks[chunk_key]
		var elapsed_sec := float(current_time - load_start_time) / 1000.0
		if elapsed_sec > CHUNK_LOAD_TIMEOUT:
			timed_out.append(chunk_key)
	for chunk_key in timed_out:
		_current_load_count = max(0, _current_load_count - 1)
		print("OSM: Chunk %s timed out after %.0fs, retrying..." % [chunk_key, CHUNK_LOAD_TIMEOUT])
		_emit_chunk_debug("CHUNK_TIMEOUT key=%s timeout_s=%.0f" % [chunk_key, CHUNK_LOAD_TIMEOUT])
		_retry_chunk_load(chunk_key, "timeout")


func _unload_chunk(chunk_key: String) -> void:
	if not _loaded_chunks.has(chunk_key):
		var state_node := _get_chunk_node(chunk_key)
		if state_node and is_instance_valid(state_node):
			_set_chunk_stage(chunk_key, "unloaded", {"last_error": "manual_unload"})
			_emit_chunk_debug("CHUNK_UNLOAD key=%s had_loaded_entry=false" % chunk_key)
			_drop_chunk_runtime_state(chunk_key)
		return
	if _loaded_chunks.has(chunk_key):
		_set_chunk_stage(chunk_key, "unloaded", {"last_error": "manual_unload"})
		_emit_chunk_debug("CHUNK_UNLOAD key=%s had_loaded_entry=true" % chunk_key)
		_chunk_culling_cooldown.erase(chunk_key)
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

		# Keep elevation data in memory — it's tiny (49 floats per chunk)
		# and avoids re-reading from disk cache on chunk reload.
		# Cleared only on reset_terrain() (location change).

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

		# Clean up fence geo batch and deferred fence edges
		if _fence_geo_batch.has(chunk_key):
			_fence_geo_batch.erase(chunk_key)
		var fence_finalize_idx := _fence_batches_to_finalize.find(chunk_key)
		if fence_finalize_idx >= 0:
			_fence_batches_to_finalize.remove_at(fence_finalize_idx)
		_deferred_fence_edges.erase(chunk_key)

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

		# Clean up road batch data & entrance batch
		_road_batch_data.erase(chunk_key)
		_entrance_batch.erase(chunk_key)

		# Purge flat queues: remove items belonging to this chunk's node
		# (parent will be freed → items would be skipped anyway, but this frees queue slots)
		var chunk_node_ref: Node3D = _loaded_chunks[chunk_key] if _loaded_chunks.has(chunk_key) else null
		if chunk_node_ref:
			_road_queue.erase(chunk_key)
			_terrain_objects_queue = _terrain_objects_queue.filter(func(item): return item.get("parent") != chunk_node_ref)
			_infrastructure_queue = _infrastructure_queue.filter(func(item): return item.get("parent") != chunk_node_ref)
			_curb_queue = _curb_queue.filter(func(item): return item.get("parent") != chunk_node_ref)
			_curb_smoothed_queue = _curb_smoothed_queue.filter(func(item): return item.get("parent") != chunk_node_ref)

		# Purge road thread results for this chunk (under mutex)
		# Note: _pending_road_tasks already decremented by worker thread when result was added
		_road_mutex.lock()
		var _filtered_rr: Array = []
		for rr in _road_results:
			if rr.get("chunk_key", "") != chunk_key:
				_filtered_rr.append(rr)
		_road_results = _filtered_rr
		_pending_road_tasks_by_chunk.erase(chunk_key)
		_road_mutex.unlock()

		# Clean up terrain roads data for this chunk
		_chunk_terrain_roads.erase(chunk_key)
		_chunk_water_polygons.erase(chunk_key)

		# Clean up pending terrain thread results for this chunk
		_terrain_thread_mutex.lock()
		var filtered_terrain: Array = []
		for tr in _terrain_thread_results:
			if tr.chunk_key != chunk_key:
				filtered_terrain.append(tr)
			else:
				_pending_terrain_tasks -= 1
		_terrain_thread_results = filtered_terrain
		# Clean up pending terrain gen results for this chunk
		var filtered_gen: Array = []
		for gr in _terrain_gen_results:
			if gr.chunk_key != chunk_key:
				filtered_gen.append(gr)
			else:
				_pending_terrain_gen_tasks -= 1
		_terrain_gen_results = filtered_gen
		_terrain_thread_mutex.unlock()
		# Clean up pending Phase 3 queue for this chunk
		var filtered_p3: Array = []
		for p3 in _phase3_queue:
			if p3.chunk_key != chunk_key:
				filtered_p3.append(p3)
		_phase3_queue = filtered_p3

		# Clean up deferred node queues for this chunk (O(1) per-chunk erase)
		_deferred_building_collisions.erase(chunk_key)
		_deferred_tree_collisions.erase(chunk_key)
		_deferred_lamp_lights.erase(chunk_key)
		_deferred_road_collisions.erase(chunk_key)
		_deferred_terrain_collisions.erase(chunk_key)
		_deferred_footway_queue.erase(chunk_key)
		_deferred_billboard_queue.erase(chunk_key)
		_deferred_lamp_queue.erase(chunk_key)
		_deferred_manhole_queue.erase(chunk_key)
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
		_remove_loading_placeholder(chunk_key)

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
		_chunk_data_received.erase(chunk_key)
		if _chunk_state.has(chunk_key):
			var state: Dictionary = _chunk_state[chunk_key]
			state["node"] = null
			_chunk_state[chunk_key] = state

		# Очищаем позиции фонарей и знаков в выгруженном чанке
		_clear_chunk_objects_positions(chunk_key)

		# Clean up spatial hash cells contributed by this chunk
		_cleanup_chunk_hash_cells(chunk_key)

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
	_emit_chunk_debug("TERRAIN_RESET begin generation=%d loaded=%d loading=%d" % [
		_load_generation,
		_loaded_chunks.size(),
		_loading_chunks.size()
	])
	# Recalculate cached cosine (start_lat may have changed)
	_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0
	_snap_origin_to_grid()
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
	_chunk_data_received.clear()
	_chunk_state.clear()
	for ph_key in _loading_placeholders.keys():
		_remove_loading_placeholder(ph_key)
	_initial_loading = false
	_initial_chunks_needed.clear()
	_initial_chunks_loaded = 0
	_initial_chunks_completed.clear()
	_chunk_profile.clear()
	_chunk_elevation_data.clear()
	_elevation_in_flight.clear()
	_elevation_retries.clear()
	_base_elevation = 0.0
	_loading_paused = true
	_finalization_state = 0  # Сбрасываем состояние финализации
	# Предиктивная загрузка
	_chunk_load_queue.clear()
	_current_load_count = 0
	_smoothed_velocity = Vector3.ZERO
	# Сбрасываем таймеры зависания
	_queue_stuck_time = 0.0
	_last_queue_size = 0

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
	_pending_road_tasks_by_chunk.clear()
	_road_mutex.unlock()
	_veg_mutex.lock()
	_veg_thread_results.clear()
	_pending_veg_tasks = 0
	_veg_mutex.unlock()
	_terrain_objects_queue.clear()
	_infrastructure_queue.clear()
	_vegetation_queue.clear()
	_pending_parking_signs.clear()
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
	_building_poly_hash.clear()
	_parking_polygons.clear()
	_parking_bounds.clear()
	_parking_spatial_hash.clear()
	_water_polygons.clear()
	_water_spatial_hash.clear()
	_chunk_hash_cells.clear()
	_chunk_road_hashes.clear()
	_chunk_building_hashes.clear()
	_chunk_building_poly_hashes.clear()
	_chunk_parking_hashes.clear()
	_chunk_water_hashes.clear()
	_chunk_intersection_hashes.clear()
	_deferred_lamp_queue.clear()
	_deferred_manhole_queue.clear()
	_deferred_traffic_queue.clear()
	_deferred_tram_queue.clear()
	_dispatched_tram_network.clear()
	_deferred_billboard_queue.clear()
	_chunk_activation_pending.clear()
	_chunk_culling_cooldown.clear()

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
	_deferred_fence_edges.clear()
	_deferred_building_collisions.clear()
	_deferred_tree_collisions.clear()
	_deferred_lamp_lights.clear()
	_deferred_road_collisions.clear()
	_deferred_terrain_collisions.clear()
	_deferred_footway_queue.clear()
	_window_batch_data.clear()
	_window_batch_materials.clear()
	_pending_batch_chunks.clear()
	_road_batch_data.clear()
	_chunk_terrain_roads.clear()
	_chunk_water_polygons.clear()
	_global_water_polygons.clear()
	_global_water_polygon_bboxes.clear()
	_global_water_polygon_hashes.clear()
	_deferred_path_polys.clear()
	_bridge_node_ways.clear()
	_bridge_deck_polygons.clear()
	_deck_entry_edges_cache.clear()
	_deck_polygon_ref_elev.clear()
	_deck_lateral_exits.clear()
	_deck_ramp_junctions.clear()
	_deck_exit_way_ids.clear()
	# Free deck nodes parented to `self` (they're not under any chunk so the
	# chunk-unload pass won't sweep them up).
	for poly_idx in _bridge_deck_nodes:
		for n in _bridge_deck_nodes[poly_idx]:
			if is_instance_valid(n):
				n.queue_free()
	_bridge_deck_nodes.clear()
	_deferred_terrain_chunks.clear()

	# Reset draw call stats (prevent stale stats across location changes)
	for key in _draw_call_stats:
		_draw_call_stats[key] = 0

	# Disconnect night mode signal to prevent stale callbacks
	if _night_mode_connected and _night_mode_manager and is_instance_valid(_night_mode_manager):
		if _night_mode_manager.night_mode_changed.is_connected(_on_night_mode_changed):
			_night_mode_manager.night_mode_changed.disconnect(_on_night_mode_changed)
		_night_mode_connected = false

	print("OSM: Terrain reset complete (all batch data cleared)")
	_emit_chunk_debug("TERRAIN_RESET complete generation=%d" % _load_generation)

func _on_osm_load_failed(error: String) -> void:
	push_error("OSM load failed: " + error)

func _on_chunk_load_failed(error: String, chunk_key: String, loader: Node, gen: int) -> void:
	# Игнорируем callback если это от старой загрузки
	if gen != _load_generation:
		print("OSM: Ignoring stale failed chunk %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		loader.queue_free()
		return

	# Если чанк уже был отменён — просто освобождаем loader
	if not _loading_chunks.has(chunk_key):
		print("OSM: Ignoring failed cancelled chunk %s" % chunk_key)
		loader.queue_free()
		return

	push_error("OSM chunk %s load failed: %s" % [chunk_key, error])
	_emit_chunk_debug("CHUNK_HTTP_FAIL key=%s gen=%d error=%s" % [chunk_key, gen, error])
	_current_load_count = max(0, _current_load_count - 1)
	loader.queue_free()
	print("OSM: Retrying failed chunk %s..." % chunk_key)
	_retry_chunk_load(chunk_key, error)

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

	# Если чанк был отменён (убрали из _loading_chunks, потому что уехали далеко) — игнорируем
	if not _loading_chunks.has(chunk_key):
		print("OSM: Ignoring cancelled chunk %s (no longer in _loading_chunks)" % chunk_key)
		loader.queue_free()
		return

	# Дедупликация: если данные для этого чанка уже получены — игнорируем повторный callback (от failover retry)
	if _chunk_data_received.has(chunk_key):
		print("OSM: Ignoring duplicate data for chunk %s" % chunk_key)
		loader.queue_free()
		return
	_chunk_data_received[chunk_key] = true

	print("OSM: Chunk %s data loaded" % chunk_key)
	_emit_chunk_debug("CHUNK_HTTP_OK key=%s gen=%d ways=%d nodes=%d" % [
		chunk_key,
		gen,
		int(osm_data.get("ways", []).size()),
		int(osm_data.get("nodes", {}).size())
	])
	_current_load_count = max(0, _current_load_count - 1)  # Декремент счётчика

	# Change placeholder color to "processing" (data loaded, finalizing)
	_set_placeholder_processing(chunk_key)

	# Per-chunk profiling
	_chunk_profile[chunk_key] = {
		"start_ms": Time.get_ticks_msec(),
		"phase12_thread_ms": 0.0,
		"phase12_apply_ms": 0.0,
		"phase3_ms": 0.0,
		"finalize_ms": 0.0,
		"activate_ms": 0.0,
		"ways": 0, "buildings": 0, "roads": 0, "amenities": 0,
	}

	# Создаём контейнер для чанка (невидимый — активируется после финализации)
	var chunk_node := Node3D.new()
	chunk_node.name = "Chunk_" + chunk_key
	chunk_node.visible = false
	add_child(chunk_node)
	_ensure_chunk_state(chunk_key, chunk_node)
	_set_chunk_stage(chunk_key, "http_loaded", {
		"generation": gen,
		"node": chunk_node,
	})
	_chunk_activation_pending[chunk_key] = -1  # -1 = ждём финализации

	# Генерируем объекты асинхронно (с frame budgeting)
	_generate_chunk_async(osm_data, chunk_node, chunk_key, loader, gen)

# Генерация чанка: dispatch computation to worker thread, finalize on main thread
func _generate_chunk_async(osm_data: Dictionary, chunk_node: Node3D, chunk_key: String, loader: Node, gen: int) -> void:
	loader.queue_free()
	# Dispatch Phase 1+2 to worker thread (spatial hash + intersections)
	_generate_terrain(osm_data, chunk_node, chunk_key, gen)

## Dispatch terrain generation: Phase 1+2 run on worker thread, Phase 3 on main thread.
## For non-chunk (initial load), runs synchronously on main thread.
func _generate_terrain(osm_data: Dictionary, parent: Node3D, chunk_key: String = "", gen: int = -1) -> void:
	# Pre-scan: register every node touched by a highway+bridge=yes way so
	# road meshes downstream can detect shared bridge endpoints. Main thread,
	# safe to write the global dict.
	_bridge_prescan_ways(osm_data.get("ways", []))

	# Collect man_made=bridge relation outlines into the global polygon list.
	# Each polygon becomes one flat asphalt deck mesh + railing in
	# _process_terrain_objects_queue (type "bridge_deck"). Dedup by start
	# vertex so a polygon shared across chunks is only built once.
	for deck in osm_data.get("bridge_decks", []):
		var deck_nodes: Array = deck.get("nodes", [])
		if deck_nodes.size() < 3:
			continue
		var poly := PackedVector2Array()
		for n in deck_nodes:
			poly.append(_latlon_to_local(n["lat"], n["lon"]))
		var dominated := false
		for existing in _bridge_deck_polygons:
			if existing.size() > 0 and poly.size() > 0 and existing[0].distance_to(poly[0]) < 1.0:
				dominated = true
				break
		if dominated:
			continue
		_bridge_deck_polygons.append(poly)
		_terrain_objects_queue.append({
			"type": "bridge_deck",
			"polygon": poly,
			"tags": deck.get("tags", {}),
			"parent": parent,
		})
		# Grass cutout at ramp junctions is handled per-junction in
		# _register_ramp_junction (small corridors, not full-axis strips).
		# A man_made=bridge polygon can span chunks the player hasn't
		# triggered yet (Oktyabrsky deck = ~600 m, while load_distance is
		# tighter). Eagerly request elevation for every chunk the polygon
		# touches so the deck mesh isn't blocked forever waiting for
		# remote chunks the player hasn't driven into.
		if enable_elevation:
			var deck_chunks := {}
			for v in poly:
				var cx := int(floor(v.x / chunk_size))
				var cz := int(floor(v.y / chunk_size))
				deck_chunks["%d,%d" % [cx, cz]] = Vector2i(cx, cz)
			for ck in deck_chunks:
				var cxz: Vector2i = deck_chunks[ck]
				_request_elevation(ck, cxz.x, cxz.y)

	# Detect lateral exit points where _link bridge roads depart the deck.
	# Must run after prescan (shared endpoints) and polygon collection,
	# but before the deck mesh is built.
	_detect_deck_lateral_exits(osm_data.get("ways", []))

	# Stage 1+2 bridge ramp detection: notify the detector on every chunk
	# load so it can accumulate the road-graph view across chunks and
	# rebuild the ramp spatial index BEFORE this chunk's Phase 3 road
	# meshing samples vertex Y. Synchronous (not call_deferred) so the
	# index is current when sample_road_y is called.
	_ensure_ramp_detector()
	if _ramp_detector != null:
		_ramp_detector.notify_chunk_loaded(osm_data, self)

	if chunk_key == "":
		# Initial load (no chunk key) — run synchronously on main thread
		_generate_terrain_sync(osm_data, parent, chunk_key)
		return

	# Chunk load — dispatch Phase 1+2 to worker thread
	# Ensure _lon_scale is initialized before threading
	if _lon_scale == 0.0:
		_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0

	var task_data := {
		"osm_data": osm_data,
		"chunk_key": chunk_key,
		"gen": gen,
		"start_lat": start_lat,
		"start_lon": start_lon,
		"lon_scale": _lon_scale,
		"chunk_size": chunk_size,
	}

	_pending_terrain_gen_tasks += 1
	WorkerThreadPool.add_task(
		_compute_terrain_phases_thread.bind(task_data),
		false,  # high_priority
		"TerrainGen_" + chunk_key
	)


## Worker thread: Phase 1 (spatial hash) + Phase 2 (intersections).
## Pure computation — no scene tree access!
func _compute_terrain_phases_thread(task_data: Dictionary) -> void:
	var _thread_t0 := Time.get_ticks_usec()
	var osm_data: Dictionary = task_data.osm_data
	var chunk_key: String = task_data.chunk_key
	var gen: int = task_data.gen
	var t_start_lat: float = task_data.start_lat
	var t_start_lon: float = task_data.start_lon
	var t_lon_scale: float = task_data.lon_scale
	var t_chunk_size: float = task_data.chunk_size

	var ways: Array = osm_data.get("ways", [])

	# Thread-local latlon conversion (no instance var access)
	var _ll := func(lat: float, lon: float) -> Vector2:
		var dx: float = (lon - t_start_lon) * t_lon_scale
		var dz: float = (lat - t_start_lat) * 111000.0
		return Vector2(dx, -dz)

	# Chunk bounds
	var coords: Array = chunk_key.split(",")
	var chunk_x := int(coords[0])
	var chunk_z := int(coords[1])
	var chunk_min_x: float = chunk_x * t_chunk_size
	var chunk_max_x: float = chunk_min_x + t_chunk_size
	var chunk_min_z: float = chunk_z * t_chunk_size
	var chunk_max_z: float = chunk_min_z + t_chunk_size

	# ========== PHASE 1: Build spatial hash data ==========
	var parking_polygons: Array = []
	var parking_bounds: Array = []
	var parking_hash_entries: Array = []
	var road_hash_entries: Array = []
	var building_hash_entries: Array = []
	var building_poly_entries: Array = []

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])

		# Parking polygons
		if tags.get("amenity") == "parking" and nodes.size() >= 3:
			var points := PackedVector2Array()
			for node in nodes:
				points.append(_ll.call(node.lat, node.lon))
			var pidx: int = parking_polygons.size()
			parking_polygons.append(points)
			var center := Vector2.ZERO
			for p in points:
				center += p
			center /= points.size()
			var max_r := 0.0
			for p in points:
				var d: float = center.distance_to(p)
				if d > max_r:
					max_r = d
			parking_bounds.append({"center": center, "radius": max_r})
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
						parking_hash_entries.append({"cell": Vector2i(cx, cy), "idx": pidx, "p1": ep1, "p2": ep2})

		# Road segments -> spatial hash
		if tags.has("highway") and nodes.size() >= 2:
			var highway_type: String = tags.get("highway", "residential")
			var road_w: float = _get_road_width(tags)
			var raw_pts := PackedVector2Array()
			raw_pts.resize(nodes.size())
			for j in range(nodes.size()):
				raw_pts[j] = _ll.call(nodes[j].lat, nodes[j].lon)
			var smoothed_pts := _smooth_road_corners(raw_pts)
			# Tag every road seg with way_id + bridge flag so the bridge
			# helpers can find neighbour bridge tangents and skip non-bridge
			# segments. Without these the corridor / shared-endpoint logic
			# from 7102d8c can't function.
			var rseg_way_id: int = int(way.get("id", 0))
			var rseg_is_bridge: bool = tags.get("bridge", "") == "yes"
			for j in range(smoothed_pts.size() - 1):
				var rseg := {
					"p1": smoothed_pts[j],
					"p2": smoothed_pts[j + 1],
					"width": road_w,
					"way_id": rseg_way_id,
					"bridge": rseg_is_bridge,
				}
				var p1: Vector2 = rseg.p1
				var p2: Vector2 = rseg.p2
				var min_x: float = minf(p1.x, p2.x) - road_w / 2.0
				var max_x: float = maxf(p1.x, p2.x) + road_w / 2.0
				var min_y: float = minf(p1.y, p2.y) - road_w / 2.0
				var max_y: float = maxf(p1.y, p2.y) + road_w / 2.0
				var cells: Array = []
				for rcx in range(int(floor(min_x / ROAD_CELL_SIZE)), int(floor(max_x / ROAD_CELL_SIZE)) + 1):
					for rcy in range(int(floor(min_y / ROAD_CELL_SIZE)), int(floor(max_y / ROAD_CELL_SIZE)) + 1):
						cells.append(Vector2i(rcx, rcy))
				road_hash_entries.append({"seg": rseg, "cells": cells})

		# Building segments -> spatial hash
		if (tags.has("building") or (tags.has("amenity") and not tags.has("highway"))) and nodes.size() >= 3:
			var bpoints := PackedVector2Array()
			for node in nodes:
				bpoints.append(_ll.call(node.lat, node.lon))
			for j in range(bpoints.size()):
				var bp1 := bpoints[j]
				var bp2 := bpoints[(j + 1) % bpoints.size()]
				var bseg := {"p1": bp1, "p2": bp2}
				var bmin_x := minf(bp1.x, bp2.x)
				var bmax_x := maxf(bp1.x, bp2.x)
				var bmin_y := minf(bp1.y, bp2.y)
				var bmax_y := maxf(bp1.y, bp2.y)
				var bcells: Array = []
				for bcx in range(int(floor(bmin_x / BUILDING_CELL_SIZE)), int(floor(bmax_x / BUILDING_CELL_SIZE)) + 1):
					for bcy in range(int(floor(bmin_y / BUILDING_CELL_SIZE)), int(floor(bmax_y / BUILDING_CELL_SIZE)) + 1):
						bcells.append(Vector2i(bcx, bcy))
				building_hash_entries.append({"seg": bseg, "cells": bcells})
			# Building polygon hash
			var pmin_x: float = bpoints[0].x
			var pmax_x: float = bpoints[0].x
			var pmin_y: float = bpoints[0].y
			var pmax_y: float = bpoints[0].y
			for p in bpoints:
				pmin_x = minf(pmin_x, p.x)
				pmax_x = maxf(pmax_x, p.x)
				pmin_y = minf(pmin_y, p.y)
				pmax_y = maxf(pmax_y, p.y)
			var pcells: Array = []
			for pcx in range(int(floor(pmin_x / BUILDING_CELL_SIZE)), int(floor(pmax_x / BUILDING_CELL_SIZE)) + 1):
				for pcy in range(int(floor(pmin_y / BUILDING_CELL_SIZE)), int(floor(pmax_y / BUILDING_CELL_SIZE)) + 1):
					pcells.append(Vector2i(pcx, pcy))
			building_poly_entries.append({"poly": bpoints, "cells": pcells})

	# Pedestrian areas — register in building poly hash to block trees
	var ped_areas: Array = osm_data.get("pedestrian_areas", [])
	for ped_nodes in ped_areas:
		if ped_nodes.size() < 3:
			continue
		var ped_pts := PackedVector2Array()
		for node in ped_nodes:
			var dx: float = (node["lon"] - t_start_lon) * t_lon_scale
			var dz: float = (node["lat"] - t_start_lat) * 111000.0
			ped_pts.append(Vector2(dx, -dz))
		var pp_min_x: float = ped_pts[0].x
		var pp_max_x: float = ped_pts[0].x
		var pp_min_y: float = ped_pts[0].y
		var pp_max_y: float = ped_pts[0].y
		for p in ped_pts:
			pp_min_x = minf(pp_min_x, p.x)
			pp_max_x = maxf(pp_max_x, p.x)
			pp_min_y = minf(pp_min_y, p.y)
			pp_max_y = maxf(pp_max_y, p.y)
		var pp_cells: Array = []
		for pcx in range(int(floor(pp_min_x / BUILDING_CELL_SIZE)), int(floor(pp_max_x / BUILDING_CELL_SIZE)) + 1):
			for pcy in range(int(floor(pp_min_y / BUILDING_CELL_SIZE)), int(floor(pp_max_y / BUILDING_CELL_SIZE)) + 1):
				pp_cells.append(Vector2i(pcx, pcy))
		building_poly_entries.append({"poly": ped_pts, "cells": pp_cells})

	# ========== PHASE 2: Intersection detection ==========
	var node_usage: Dictionary = {}
	var node_arms: Dictionary = {}
	var roundabout_nodes: Dictionary = {}

	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])
		if not tags.has("highway") or way_nodes.size() < 2:
			continue
		var is_roundabout_way: bool = tags.get("junction", "") in ["roundabout", "circular"] or tags.get("highway", "") == "mini_roundabout"
		if is_roundabout_way:
			for node in way_nodes:
				var roundabout_key := "%.6f,%.6f" % [node.lat, node.lon]
				roundabout_nodes[roundabout_key] = true
		var highway_type: String = tags.get("highway", "")
		if highway_type in ["footway", "path", "cycleway", "track", "steps"]:
			continue
		var road_width: float = _get_road_width(tags)

		# Конвертируем в local и сглаживаем — directions перекрёстков должны
		# совпадать с фактическими сглаженными дорогами, а не с сырыми OSM-узлами.
		var raw_pts := PackedVector2Array()
		raw_pts.resize(way_nodes.size())
		for wi in range(way_nodes.size()):
			raw_pts[wi] = _ll.call(way_nodes[wi].lat, way_nodes[wi].lon)
		var smoothed_pts: PackedVector2Array = _smooth_road_corners(raw_pts)

		# Для каждого исходного OSM-узла находим ближайшую точку на сглаженной полилинии
		# и берём direction из сглаженных сегментов
		for i in range(way_nodes.size()):
			var node = way_nodes[i]
			var node_key := "%.6f,%.6f" % [node.lat, node.lon]
			var local: Vector2 = raw_pts[i]

			# Находим ближайшую точку в smoothed_pts
			var best_si := 0
			var best_dist := local.distance_squared_to(smoothed_pts[0])
			for si in range(1, smoothed_pts.size()):
				var dd := local.distance_squared_to(smoothed_pts[si])
				if dd < best_dist:
					best_dist = dd
					best_si = si

			# Direction из сглаженной полилинии
			var direction := Vector2.ZERO
			if best_si > 0:
				direction = (local - smoothed_pts[best_si - 1]).normalized()
			elif best_si < smoothed_pts.size() - 1:
				direction = (smoothed_pts[best_si + 1] - local).normalized()

			if not node_usage.has(node_key):
				node_usage[node_key] = {"pos": local, "types": [], "widths": [], "directions": []}
			if highway_type not in node_usage[node_key]["types"]:
				node_usage[node_key]["types"].append(highway_type)
				node_usage[node_key]["widths"].append(road_width)
				node_usage[node_key]["directions"].append(direction)

			if not node_arms.has(node_key):
				node_arms[node_key] = []
			# Arms: направления от перекрёстка к соседним сглаженным точкам
			if best_si > 0:
				var outward_prev := (smoothed_pts[best_si - 1] - local).normalized()
				node_arms[node_key].append({"direction": outward_prev, "width": road_width})
			if best_si < smoothed_pts.size() - 1:
				var outward_next := (smoothed_pts[best_si + 1] - local).normalized()
				node_arms[node_key].append({"direction": outward_next, "width": road_width})

	# Detect intersections
	var new_positions: Array = []
	var new_radii: Array = []
	var new_angles: Array = []
	var new_types: Array = []
	var new_roads: Array = []
	var new_contours: Array = []
	var new_curb_contours: Array = []
	var new_hash_entries: Array = []

	for node_key in node_usage:
		if roundabout_nodes.has(node_key):
			continue
		var info: Dictionary = node_usage[node_key]
		var types: Array = info["types"]
		var arms: Array = node_arms.get(node_key, [])
		var filtered_arms: Array = []
		for arm in arms:
			var dominated := false
			for existing in filtered_arms:
				if absf(arm["direction"].angle_to(existing["direction"])) < deg_to_rad(10.0):
					dominated = true
					if arm["width"] > existing["width"]:
						existing["direction"] = arm["direction"]
						existing["width"] = arm["width"]
					break
			if not dominated:
				filtered_arms.append(arm.duplicate())
		if types.size() < 2 and filtered_arms.size() < 3:
			continue
		var is_duplicate := false
		for existing_pos in new_positions:
			if existing_pos.distance_to(info["pos"]) < 2.0:
				is_duplicate = true
				break
		if is_duplicate:
			continue

		new_positions.append(info["pos"])
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
		new_radii.append(Vector2(max_width * 0.5, second_width * 0.5))
		new_angles.append(atan2(max_dir.y, max_dir.x) + PI * 0.5)
		var min_priority := 999
		var max_priority := 0
		for t in types:
			var p := _get_road_priority(t)
			min_priority = mini(min_priority, p)
			max_priority = maxi(max_priority, p)
		new_types.append((max_priority - min_priority) <= 1)
		new_roads.append(filtered_arms)
		var contour := _build_intersection_contour_from_data(info["pos"], filtered_arms)
		new_contours.append(contour)
		if contour.size() > 0:
			var curb_contour := PackedVector2Array()
			for cp in contour:
				curb_contour.append(cp + (cp - info["pos"]).normalized() * 0.3)
			new_curb_contours.append(curb_contour)
		else:
			new_curb_contours.append(PackedVector2Array())
		var hash_radius := maxf(max_width * 0.5, second_width * 0.5)
		if contour.size() > 0:
			for cp in contour:
				hash_radius = maxf(hash_radius, cp.distance_to(info["pos"]))
		new_hash_entries.append({"pos": info["pos"], "radii": Vector2(hash_radius + 1.0, hash_radius + 1.0)})

	# Phase 2b: node_road_count for intersection objects
	# Use small margin to catch intersections right on chunk boundaries
	var nrc_margin := 2.0
	var node_road_count: Dictionary = {}
	var node_positions: Dictionary = {}
	var node_road_types: Dictionary = {}
	for way in ways:
		var way_tags: Dictionary = way.get("tags", {})
		var way_nodes: Array = way.get("nodes", [])
		if not way_tags.has("highway"):
			continue
		var highway_type: String = way_tags.get("highway", "")
		if highway_type in ["footway", "path", "cycleway", "steps", "pedestrian"]:
			continue
		if way_nodes.size() < 2:
			continue
		for node in way_nodes:
			var node_key := "%.5f,%.5f" % [node.lat, node.lon]
			var roundabout_key := "%.6f,%.6f" % [node.lat, node.lon]
			if roundabout_nodes.has(roundabout_key):
				continue
			var local: Vector2 = _ll.call(node.lat, node.lon)
			if local.x < chunk_min_x - nrc_margin or local.x >= chunk_max_x + nrc_margin or local.y < chunk_min_z - nrc_margin or local.y >= chunk_max_z + nrc_margin:
				continue
			if not node_road_count.has(node_key):
				node_road_count[node_key] = 0
				node_positions[node_key] = local
				node_road_types[node_key] = []
			node_road_count[node_key] += 1
			if highway_type not in node_road_types[node_key]:
				node_road_types[node_key].append(highway_type)

	# Store result via mutex
	var result := {
		"chunk_key": chunk_key, "gen": gen, "osm_data": osm_data,
		"parking_polygons": parking_polygons, "parking_bounds": parking_bounds,
		"parking_hash_entries": parking_hash_entries,
		"road_hash_entries": road_hash_entries,
		"building_hash_entries": building_hash_entries,
		"building_poly_entries": building_poly_entries,
		"new_positions": new_positions, "new_radii": new_radii,
		"new_angles": new_angles, "new_types": new_types,
		"new_roads": new_roads, "new_contours": new_contours,
		"new_curb_contours": new_curb_contours,
		"new_hash_entries": new_hash_entries,
		"node_road_count": node_road_count,
		"node_positions": node_positions,
		"node_road_types": node_road_types,
		"roundabout_nodes": roundabout_nodes,
	}
	result["thread_time_ms"] = (Time.get_ticks_usec() - _thread_t0) / 1000.0
	_terrain_thread_mutex.lock()
	_terrain_gen_results.append(result)
	_terrain_thread_mutex.unlock()


## Thread-safe intersection contour builder (no instance vars)
## Uses edge-line intersection for Bezier control point — same algorithm as main branch
func _build_intersection_contour_from_data(center: Vector2, roads: Array) -> PackedVector2Array:
	if roads.size() < 2:
		return PackedVector2Array()
	var sorted_roads: Array = []
	for r in roads:
		var dir: Vector2 = r["direction"]
		sorted_roads.append({"direction": dir, "width": r["width"], "angle": atan2(dir.y, dir.x)})
	sorted_roads.sort_custom(func(a, b): return a["angle"] < b["angle"])
	var contour := PackedVector2Array()
	var road_count := sorted_roads.size()
	var curve_segments := 6
	var max_half_w := 0.0
	for r in roads:
		max_half_w = maxf(max_half_w, r["width"] * 0.5)
	for i in range(road_count):
		var road: Dictionary = sorted_roads[i]
		var next_road: Dictionary = sorted_roads[(i + 1) % road_count]
		var dir: Vector2 = road["direction"]
		var half_w: float = road["width"] * 0.5
		var extend: float = maxf(half_w, max_half_w) + 5.0
		var perp := Vector2(-dir.y, dir.x)
		var left_tip: Vector2 = center + dir * extend - perp * half_w
		var right_tip: Vector2 = center + dir * extend + perp * half_w
		contour.append(left_tip)
		contour.append(right_tip)
		var next_dir: Vector2 = next_road["direction"]
		var next_half_w: float = next_road["width"] * 0.5
		var next_extend: float = maxf(next_half_w, max_half_w) + 5.0
		var next_perp := Vector2(-next_dir.y, next_dir.x)
		var next_left_tip: Vector2 = center + next_dir * next_extend - next_perp * next_half_w
		var delta: float = next_road["angle"] - road["angle"]
		if delta < 0:
			delta += TAU
		if delta > deg_to_rad(150.0):
			pass
		elif delta > deg_to_rad(10.0):
			# Find intersection of road edge lines for Bezier control point
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
						contour.append(p01.lerp(p12, t))
	return contour


## Apply terrain gen thread results on main thread. Called from _process().
func _apply_terrain_gen_result() -> void:
	# Drain ALL ready results — this is cheap work (spatial hash copy)
	_terrain_thread_mutex.lock()
	if _terrain_gen_results.is_empty():
		_terrain_thread_mutex.unlock()
		return
	var batch: Array = _terrain_gen_results.duplicate()
	_terrain_gen_results.clear()
	_terrain_thread_mutex.unlock()

	# Apply with 4ms budget (spatial hash + intersection dedup)
	var TGEN_APPLY_BUDGET_USEC := 500000 if _initial_loading else 4000
	var tg_start := Time.get_ticks_usec()
	var tg_applied := 0
	for result in batch:
		_pending_terrain_gen_tasks -= 1
		_apply_single_terrain_gen_result(result)
		tg_applied += 1
		if tg_applied > 1 and (Time.get_ticks_usec() - tg_start) > TGEN_APPLY_BUDGET_USEC:
			break

	# Return unprocessed back to queue
	if tg_applied < batch.size():
		_terrain_thread_mutex.lock()
		var remaining: Array = batch.slice(tg_applied)
		remaining.append_array(_terrain_gen_results)
		_terrain_gen_results = remaining
		_terrain_thread_mutex.unlock()


func _apply_single_terrain_gen_result(result: Dictionary) -> void:
	var chunk_key: String = result.chunk_key
	var gen: int = result.gen
	if gen >= 0 and gen != _load_generation:
		print("OSM: Ignoring stale terrain gen %s (gen %d != %d)" % [chunk_key, gen, _load_generation])
		return

	var parent: Node3D = _get_chunk_node(chunk_key)
	if not parent or not is_instance_valid(parent):
		_set_chunk_stage(chunk_key, "cancelled", {"last_error": "missing_chunk_node"})
		_emit_chunk_debug("CHUNK_DROP key=%s reason=missing_node stage=terrain_gen_ready" % chunk_key)
		if _chunk_debug_enabled():
			dump_chunk_pipeline(chunk_key)
		return

	# Apply Phase 1: per-chunk spatial hashes
	var chunk_parking_hash: Dictionary = {}
	var chunk_parking_polys: Array = []
	for pp in result.parking_polygons:
		chunk_parking_polys.append(pp)
	for entry in result.parking_hash_entries:
		var cell: Vector2i = entry.cell
		if not chunk_parking_hash.has(cell):
			chunk_parking_hash[cell] = []
		chunk_parking_hash[cell].append({"idx": entry.idx, "p1": entry.p1, "p2": entry.p2})
	_chunk_parking_hashes[chunk_key] = {"hash": chunk_parking_hash, "polys": chunk_parking_polys}
	var chunk_road_hash: Dictionary = {}
	var chunk_building_hash: Dictionary = {}
	var chunk_building_poly_hash: Dictionary = {}
	for rhe in result.road_hash_entries:
		var seg: Dictionary = rhe.seg
		for cell in rhe.cells:
			if not chunk_road_hash.has(cell):
				chunk_road_hash[cell] = []
			chunk_road_hash[cell].append(seg)
	for bhe in result.building_hash_entries:
		var seg: Dictionary = bhe.seg
		for cell in bhe.cells:
			if not chunk_building_hash.has(cell):
				chunk_building_hash[cell] = []
			chunk_building_hash[cell].append(seg)
	for bpe in result.building_poly_entries:
		for cell in bpe.cells:
			if not chunk_building_poly_hash.has(cell):
				chunk_building_poly_hash[cell] = []
			chunk_building_poly_hash[cell].append(bpe.poly)
	_chunk_road_hashes[chunk_key] = chunk_road_hash
	_chunk_building_hashes[chunk_key] = chunk_building_hash
	_chunk_building_poly_hashes[chunk_key] = chunk_building_poly_hash

	# Apply Phase 2: intersections (with global dedup)
	for li in range(result.new_positions.size()):
		var pos: Vector2 = result.new_positions[li]
		var is_dup := false
		for existing_pos in _intersection_positions:
			if existing_pos.distance_to(pos) < 2.0:
				is_dup = true
				break
		if is_dup:
			continue
		_intersection_positions.append(pos)
		_intersection_radii.append(result.new_radii[li])
		_intersection_angles.append(result.new_angles[li])
		_intersection_types.append(result.new_types[li])
		_intersection_roads.append(result.new_roads[li])
		_intersection_contours.append(result.new_contours[li])
		_intersection_curb_contours.append(result.new_curb_contours[li])
		var he: Dictionary = result.new_hash_entries[li]
		_add_intersection_to_spatial_hash(pos, he.radii, _intersection_positions.size() - 1, chunk_key)

	# Record profiling: thread time and apply time
	if _chunk_profile.has(chunk_key):
		_chunk_profile[chunk_key]["phase12_thread_ms"] = result.get("thread_time_ms", 0.0)
	_set_chunk_stage(chunk_key, "terrain_gen_ready", {
		"generation": gen,
		"node": parent,
	})

	# Queue Phase 3 for incremental processing across frames
	_phase3_queue.append({
		"result": result, "parent": parent, "chunk_key": chunk_key, "gen": gen,
		"way_idx": 0, "phase": "ways",  # phases: ways, intersections, points, bus_stops, finalize
		"phase3_work_us": 0,  # Cumulative work time (excludes queue waiting)
	})


## Process Phase 3 queue incrementally — time-budgeted across frames.
## Returns true if work was done this frame.
func _process_phase3_queue() -> bool:
	if _phase3_queue.is_empty():
		return false

	# Own budget: unlimited during initial loading, 4ms during gameplay
	var budget_us: int = 500000 if _initial_loading else 4000
	var t0 := Time.get_ticks_usec()

	# Приоритизируем: ближайший processable чанк перед камерой первый
	var best_idx := -1
	var best_score := INF
	for pi in _phase3_queue.size():
		var ck: String = _phase3_queue[pi].chunk_key
		if not _should_process_chunk(ck):
			continue
		# Wait for elevation data before placing any objects
		if enable_elevation and not _chunk_elevation_data.has(ck):
			continue
		var ps := _chunk_priority_score(ck)
		if ps < best_score:
			best_score = ps
			best_idx = pi
	if best_idx < 0:
		return false  # Все чанки culled — ничего не делаем
	if best_idx != 0:
		var tmp: Dictionary = _phase3_queue[0]
		_phase3_queue[0] = _phase3_queue[best_idx]
		_phase3_queue[best_idx] = tmp

	var entry: Dictionary = _phase3_queue[0]
	var result: Dictionary = entry.result
	var parent: Node3D = entry.parent
	var chunk_key: String = entry.chunk_key
	var gen: int = entry.gen
	var phase: String = entry.phase

	# Check parent still valid
	if not is_instance_valid(parent):
		_set_chunk_stage(chunk_key, "cancelled", {"last_error": "invalid_phase3_parent"})
		_phase3_queue.pop_front()
		return true
	if chunk_key != "" and _chunk_state.has(chunk_key):
		var state: Dictionary = _chunk_state[chunk_key]
		if state.get("stage", "") != "phase3":
			_set_chunk_stage(chunk_key, "phase3", {"node": parent})

	var osm_data: Dictionary = result.osm_data
	var target: Node3D = parent if parent else self
	var ways: Array = osm_data.get("ways", [])
	var filter_by_chunk := chunk_key != ""
	var chunk_min_x := 0.0
	var chunk_max_x := 0.0
	var chunk_min_z := 0.0
	var chunk_max_z := 0.0
	if filter_by_chunk:
		var coords: Array = chunk_key.split(",")
		chunk_min_x = int(coords[0]) * chunk_size
		chunk_max_x = chunk_min_x + chunk_size
		chunk_min_z = int(coords[1]) * chunk_size
		chunk_max_z = chunk_min_z + chunk_size

	if phase == "ways":
		var chunk_entrance_nodes: Array = osm_data.get("entrance_nodes", [])
		var chunk_poi_nodes: Array = osm_data.get("poi_nodes", [])
		var way_idx: int = entry.way_idx
		while way_idx < ways.size():
			if (Time.get_ticks_usec() - t0) > budget_us:
				entry.way_idx = way_idx
				return true
			var way: Dictionary = ways[way_idx]
			way_idx += 1
			var tags: Dictionary = way.get("tags", {})
			var nodes: Array = way.get("nodes", [])
			if nodes.size() < 2:
				continue
			if filter_by_chunk:
				# highway и waterway — рисуем ВСЕ из overlap данных, клиппинг к bbox внутри _create_road/_create_waterway
				if tags.has("highway") or tags.has("waterway") or tags.get("railway", "") == "tram":
					pass  # Не фильтруем — каждый чанк рисует свой клипнутый кусок
				elif tags.get("amenity") == "parking":
					pass  # Не фильтруем — _create_parking клипает через intersect_polygons
				elif tags.get("natural") == "water" or tags.get("landuse") in ["reservoir", "basin"]:
					# Huge water polygons (rivers, reservoirs) cannot be center-
					# filtered — the centre is far from any single chunk. Use
					# bbox-overlap instead: any chunk whose bbox the polygon
					# touches gets to process it (and clips per-chunk inside
					# _create_natural_immediate). Restored from 53b0537.
					var w_bbox := _get_way_local_bbox(nodes)
					if w_bbox.position.x > chunk_max_x or w_bbox.end.x < chunk_min_x or w_bbox.position.y > chunk_max_z or w_bbox.end.y < chunk_min_z:
						continue
				elif tags.has("building") or tags.has("amenity"):
					var center := _get_way_center(nodes)
					if not (center.x >= chunk_min_x and center.x < chunk_max_x and center.y >= chunk_min_z and center.y < chunk_max_z):
						continue
				else:
					var center := _get_way_center(nodes)
					if not (center.x >= chunk_min_x and center.x < chunk_max_x and center.y >= chunk_min_z and center.y < chunk_max_z):
						continue
			var way_id_raw: int = int(way.get("id", 0))
			if way_id_raw in [75621890]:
				continue
			if tags.has("highway"):
				_create_road(nodes, tags, target, null, way_id_raw, true)  # skip_spatial_hash: already built by Phase 1+2
			elif tags.get("railway", "") == "tram":
				var tram_dedup_key := "%d_%s" % [way_id_raw, chunk_key]
				if _dispatched_tram_ways.has(tram_dedup_key):
					continue
				_dispatched_tram_ways[tram_dedup_key] = true
				print("[TRAM] Dispatching tram way %d to _create_road, chunk=%s nodes=%d" % [way_id_raw, chunk_key, nodes.size()])
				# Store tram segments in separate hash for sign placement
				var tram_pts := PackedVector2Array()
				tram_pts.resize(nodes.size())
				for j_t in range(nodes.size()):
					tram_pts[j_t] = _latlon_to_local(nodes[j_t].lat, nodes[j_t].lon)
				if not _chunk_tram_hashes.has(chunk_key):
					_chunk_tram_hashes[chunk_key] = {}
				var th: Dictionary = _chunk_tram_hashes[chunk_key]
				for j_t in range(tram_pts.size() - 1):
					var seg_dict := {"p1": tram_pts[j_t], "p2": tram_pts[j_t + 1], "width": 2.2}
					var min_cx := int(floor(minf(tram_pts[j_t].x, tram_pts[j_t + 1].x) / ROAD_CELL_SIZE))
					var max_cx := int(floor(maxf(tram_pts[j_t].x, tram_pts[j_t + 1].x) / ROAD_CELL_SIZE))
					var min_cy := int(floor(minf(tram_pts[j_t].y, tram_pts[j_t + 1].y) / ROAD_CELL_SIZE))
					var max_cy := int(floor(maxf(tram_pts[j_t].y, tram_pts[j_t + 1].y) / ROAD_CELL_SIZE))
					for tcx in range(min_cx, max_cx + 1):
						for tcy in range(min_cy, max_cy + 1):
							var tkey := Vector2i(tcx, tcy)
							if not th.has(tkey):
								th[tkey] = []
							th[tkey].append(seg_dict)
				var tram_tags: Dictionary = tags.duplicate()
				tram_tags["highway"] = "tram"
				_create_road(nodes, tram_tags, target, null, way_id_raw, true)
				# Rails overlay — renders above roads at crossings
				var rails_tags: Dictionary = tags.duplicate()
				rails_tags["highway"] = "tram_rails"
				_create_road(nodes, rails_tags, target, null, way_id_raw, true)
			elif tags.has("building"):
				_create_building(nodes, tags, target, null, way_id_raw, chunk_entrance_nodes, chunk_poi_nodes, true)  # skip_spatial_hash
			elif tags.has("amenity") and not tags.has("building"):
				_create_amenity_building(nodes, tags, target, null, true)  # skip_spatial_hash
			elif tags.has("natural"):
				# Pre-register water polygons synchronously so the tree /
				# lamp / lookup checks in the upcoming "points" phase see
				# them. The mesh + shore are still built lazily from the
				# terrain queue.
				if tags.get("natural") == "water" and enable_water and nodes.size() >= 3:
					var wpts := PackedVector2Array()
					for n in nodes:
						wpts.append(_latlon_to_local(n.lat, n.lon))
					_register_global_water_polygon(wpts)
					for clipped in _clip_polygon_to_chunk(wpts, chunk_key):
						_register_water_polygon(clipped, target)
				# Large water polygons (reservoirs, lakes) must be processed
				# first so that narrower water strips contained inside them
				# can skip redundant shore edges facing open water (53b0537).
				if tags.get("natural", "") == "water" and nodes.size() > 200:
					_terrain_objects_queue.push_front({"type": "natural", "nodes": nodes, "tags": tags, "parent": target})
				else:
					_terrain_objects_queue.append({"type": "natural", "nodes": nodes, "tags": tags, "parent": target})
			elif tags.has("landuse"):
				if tags.get("landuse") in ["reservoir", "basin"] and enable_water and nodes.size() >= 3:
					var lpts := PackedVector2Array()
					for n in nodes:
						lpts.append(_latlon_to_local(n.lat, n.lon))
					_register_global_water_polygon(lpts)
					for clipped in _clip_polygon_to_chunk(lpts, chunk_key):
						_register_water_polygon(clipped, target)
				_terrain_objects_queue.append({"type": "landuse", "nodes": nodes, "tags": tags, "parent": target, "way_id": way_id_raw})
			elif tags.has("leisure"):
				_terrain_objects_queue.append({"type": "leisure", "nodes": nodes, "tags": tags, "parent": target, "way_id": way_id_raw})
			elif tags.has("waterway") and enable_water:
				_create_waterway(nodes, tags, target, null)
		# Done with ways — move to intersections
		entry.phase = "intersections"
		entry.way_idx = 0
		# Pre-build intersection keys list for iteration
		var ikeys: Array = []
		var node_road_count: Dictionary = result.node_road_count
		for nk in node_road_count:
			if node_road_count[nk] >= 2:
				ikeys.append(nk)
		entry["ikeys"] = ikeys
		return true

	if phase == "intersections":
		var node_road_count: Dictionary = result.node_road_count
		var node_positions: Dictionary = result.node_positions
		var node_road_types: Dictionary = result.node_road_types
		var roundabout_nodes: Dictionary = result.get("roundabout_nodes", {})
		var ikeys: Array = entry.get("ikeys", [])
		var idx: int = entry.way_idx
		while idx < ikeys.size():
			if (Time.get_ticks_usec() - t0) > budget_us:
				entry.way_idx = idx
				return true
			var node_key: String = ikeys[idx]
			idx += 1
			if roundabout_nodes.has(node_key):
				continue
			var pos: Vector2 = node_positions[node_key]
			var inside_chunk := true
			if filter_by_chunk:
				inside_chunk = pos.x >= chunk_min_x and pos.x < chunk_max_x and pos.y >= chunk_min_z and pos.y < chunk_max_z
				# Patches can extend beyond center — use margin for patch check
				var patch_margin := 20.0
				var near_chunk := pos.x >= chunk_min_x - patch_margin and pos.x < chunk_max_x + patch_margin and pos.y >= chunk_min_z - patch_margin and pos.y < chunk_max_z + patch_margin
				if not near_chunk:
					continue
			var road_types: Array = node_road_types[node_key]
			var major_road_count := 0
			var max_width := 0.0
			var max_height_offset := 0.006
			for t in road_types:
				if t in ["motorway", "trunk", "primary", "secondary", "tertiary", "residential", "service"]:
					major_road_count += 1
				max_width = maxf(max_width, ROAD_WIDTHS.get(t, 6.0))
				var ho := 0.006
				match t:
					"motorway", "trunk": ho = 0.012
					"primary": ho = 0.010
					"secondary": ho = 0.008
					"tertiary": ho = 0.007
					"residential", "unclassified": ho = 0.006
					"service": ho = 0.004
				max_height_offset = maxf(max_height_offset, ho)
			# Search ALL chunks — intersection may be registered under a different chunk due to overlap
			var intersection_idx := _find_nearest_intersection(pos, 2.0)
			# Signs only in the chunk that contains the center (avoid duplicates)
			if inside_chunk:
				var sign_offset := Vector2(5, 5)
				if intersection_idx >= 0:
					var angle: float = _intersection_angles[intersection_idx]
					sign_offset = Vector2(cos(angle), sin(angle)) * (max_width * 0.5 + 0.5)
				var sign_elev := _sample_elevation(pos.x, pos.y)
				var has_primary := "primary" in road_types or "secondary" in road_types
				if has_primary and node_road_count[node_key] >= 3:
					_create_traffic_light(pos + sign_offset, sign_elev, target)
				else:
					_create_yield_sign(pos + sign_offset, sign_elev, target)
			# Patches in all nearby chunks (clipped to chunk bounds inside)
			if major_road_count >= 1:
				_create_intersection_patch(pos, target, intersection_idx, max_height_offset, chunk_key)
		# Done with intersections — move to points
		entry.phase = "points"
		entry.way_idx = 0
		return true

	if phase == "points":
		var point_objects: Array = osm_data.get("point_objects", [])
		var idx: int = entry.way_idx
		while idx < point_objects.size():
			if (Time.get_ticks_usec() - t0) > budget_us:
				entry.way_idx = idx
				return true
			var obj: Dictionary = point_objects[idx]
			idx += 1
			var tags: Dictionary = obj.get("tags", {})
			var local: Vector2 = _latlon_to_local(obj.get("lat", 0.0), obj.get("lon", 0.0))
			if filter_by_chunk:
				if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
					continue
			var pt_ck := chunk_key if not chunk_key.is_empty() else "%d,%d" % [int(floor(local.x / chunk_size)), int(floor(local.y / chunk_size))]
			var pt_elev := _sample_elevation(local.x, local.y)
			if tags.get("natural") == "tree":
				if not _is_point_near_road(local, 3.0, pt_ck) and not _is_point_in_water(local, pt_ck):
					_add_tree_to_batch(pt_ck, local, pt_elev, target)
			elif tags.get("amenity") == "waste_disposal":
				_create_garbage_container(local, pt_elev, target)
			elif tags.has("traffic_sign"):
				_create_traffic_sign(local, pt_elev, tags, target)
			elif tags.get("highway") == "street_lamp":
				if not _is_point_in_any_parking(local, pt_ck) and not _is_point_near_road(local, 0.1, pt_ck) and not _is_point_in_water(local, pt_ck):
					if chunk_key != "":
						_add_lamp_to_batch(chunk_key, Vector3(local.x, pt_elev, local.y), Vector3.FORWARD, target)
					else:
						_create_street_lamp(local, pt_elev, target)
		# Done with points — move to bus stops
		entry.phase = "bus_stops"
		entry.way_idx = 0
		return true

	if phase == "bus_stops":
		var bus_stops: Array = osm_data.get("bus_stops", [])
		var excluded_stops := ["Улица Партизана Окинина"]
		var idx: int = entry.way_idx
		while idx < bus_stops.size():
			var stop: Dictionary = bus_stops[idx]
			idx += 1
			var tags: Dictionary = stop.get("tags", {})
			if tags.get("name", "") in excluded_stops:
				continue
			var local: Vector2 = _latlon_to_local(stop.get("lat", 0.0), stop.get("lon", 0.0))
			if filter_by_chunk:
				if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
					continue
			_create_bus_stop(local, 0.0, tags, target)
		# Done with bus stops — move to tram stops
		entry.phase = "tram_stops"
		entry.way_idx = 0
		return true

	if phase == "tram_stops":
		var tram_stops: Array = osm_data.get("tram_stops", [])
		var idx: int = entry.way_idx
		while idx < tram_stops.size():
			var stop: Dictionary = tram_stops[idx]
			idx += 1
			var local: Vector2 = _latlon_to_local(stop.get("lat", 0.0), stop.get("lon", 0.0))
			if filter_by_chunk:
				if local.x < chunk_min_x or local.x >= chunk_max_x or local.y < chunk_min_z or local.y >= chunk_max_z:
					continue
			_enqueue_tram_stop_sign(local, target, chunk_key)
			# Register stop position for tram stopping behavior
			var traffic_mgr = get_parent().get_node_or_null("TrafficManager")
			if traffic_mgr and traffic_mgr.has_method("get_road_network"):
				var rn = traffic_mgr.get_road_network()
				if rn:
					rn.tram_stop_positions.append(Vector3(local.x, _sample_elevation(local.x, local.y), local.y))
		# Done with tram stops — move to pedestrian areas
		entry.phase = "pedestrian_areas"
		entry.way_idx = 0
		return true

	if phase == "pedestrian_areas":
		var ped_areas: Array = osm_data.get("pedestrian_areas", [])
		var idx: int = entry.way_idx
		while idx < ped_areas.size():
			var ped_nodes: Array = ped_areas[idx]
			idx += 1
			if ped_nodes.size() < 3:
				continue
			var ped_points := PackedVector2Array()
			for node in ped_nodes:
				ped_points.append(_latlon_to_local(node["lat"], node["lon"]))
			# Only create in the chunk where center falls (avoid duplicates across chunks)
			if filter_by_chunk:
				var cx := 0.0
				var cy := 0.0
				for p in ped_points:
					cx += p.x
					cy += p.y
				cx /= ped_points.size()
				cy /= ped_points.size()
				if not (cx >= chunk_min_x and cx < chunk_max_x and cy >= chunk_min_z and cy < chunk_max_z):
					continue
			_create_pedestrian_area(ped_points, target, chunk_key)
			print("OSM: Created pedestrian area with %d points in chunk %s" % [ped_points.size(), chunk_key])
		# Done — finalize
		entry.phase = "finalize"
		return true

	if phase == "finalize":
		if chunk_key != "":
			_place_custom_models_for_chunk(chunk_key, target)
			_generate_trees_for_chunk(chunk_key, target)
		var batch_chunk_key := chunk_key if chunk_key != "" else "initial"
		if not _pending_batch_chunks.has(batch_chunk_key):
			_pending_batch_chunks.append(batch_chunk_key)
		# Finalize chunk state
		_set_chunk_stage(chunk_key, "finalizing", {"node": parent})
		_loading_chunks.erase(chunk_key)
		_loaded_chunks[chunk_key] = parent
		_initial_chunks_completed[chunk_key] = true
		# Per-chunk profiling: record phase3 total time
		if _chunk_profile.has(chunk_key):
			var cp: Dictionary = _chunk_profile[chunk_key]
			var ways_data: Array = result.get("osm_data", {}).get("ways", [])
			cp["ways"] = ways_data.size()
			var total_ms: int = Time.get_ticks_msec() - cp.get("start_ms", 0)
			print("CHUNK_PROFILE %s: total=%dms (thread=%.0fms, phase3=%dms) ways=%d" % [
				chunk_key, total_ms, cp.get("phase12_thread_ms", 0.0), total_ms - int(cp.get("phase12_thread_ms", 0.0)), cp.get("ways", 0)])
		if gen >= 0 and gen != _load_generation:
			_phase3_queue.pop_front()
			return true
		if _decoration_layer and not _billboard_batches_to_finalize.has(chunk_key):
			_billboard_batches_to_finalize.append(chunk_key)
		_apply_night_mode_to_chunk(parent)
		_check_initial_load_complete()
		_phase3_queue.pop_front()
		return true

	# Unknown phase — drop entry
	_phase3_queue.pop_front()
	return true


## Synchronous terrain generation (for initial load / non-chunk mode).
func _generate_terrain_sync(osm_data: Dictionary, parent: Node3D, chunk_key: String = "") -> void:
	var target: Node3D = parent if parent else self
	var ways: Array = osm_data.get("ways", [])
	var chunk_entrance_nodes: Array = osm_data.get("entrance_nodes", [])
	var chunk_poi_nodes: Array = osm_data.get("poi_nodes", [])
	# Phase 1: Spatial hash
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])
		if tags.get("amenity") == "parking" and nodes.size() >= 3:
			var points := PackedVector2Array()
			for node in nodes:
				points.append(_latlon_to_local(node.lat, node.lon))
			if not _chunk_parking_hashes.has(chunk_key):
				_chunk_parking_hashes[chunk_key] = {"hash": {}, "polys": []}
			var cp_data: Dictionary = _chunk_parking_hashes[chunk_key]
			var cp_hash: Dictionary = cp_data["hash"]
			var cp_polys: Array = cp_data["polys"]
			var pidx: int = cp_polys.size()
			cp_polys.append(points)
			for ei in range(points.size()):
				var ep1: Vector2 = points[ei]
				var ep2: Vector2 = points[(ei + 1) % points.size()]
				for cx in range(int(floor(minf(ep1.x, ep2.x) / PARKING_CELL_SIZE)), int(floor(maxf(ep1.x, ep2.x) / PARKING_CELL_SIZE)) + 1):
					for cy in range(int(floor(minf(ep1.y, ep2.y) / PARKING_CELL_SIZE)), int(floor(maxf(ep1.y, ep2.y) / PARKING_CELL_SIZE)) + 1):
						var cell_key := Vector2i(cx, cy)
						if not cp_hash.has(cell_key):
							cp_hash[cell_key] = []
						cp_hash[cell_key].append({"idx": pidx, "p1": ep1, "p2": ep2})
		if tags.has("highway") and nodes.size() >= 2:
			var road_w: float = _get_road_width(tags)
			var raw_pts := PackedVector2Array()
			raw_pts.resize(nodes.size())
			for j in range(nodes.size()):
				raw_pts[j] = _latlon_to_local(nodes[j].lat, nodes[j].lon)
			var smoothed_pts := _smooth_road_corners(raw_pts)
			var sync_way_id: int = int(way.get("id", 0))
			var sync_is_bridge: bool = tags.get("bridge", "") == "yes"
			for j in range(smoothed_pts.size() - 1):
				_add_road_segment_to_spatial_hash({
					"p1": smoothed_pts[j],
					"p2": smoothed_pts[j + 1],
					"width": road_w,
					"way_id": sync_way_id,
					"bridge": sync_is_bridge,
				}, chunk_key)
		if (tags.has("building") or (tags.has("amenity") and not tags.has("highway"))) and nodes.size() >= 3:
			var bpoints := PackedVector2Array()
			for node in nodes:
				bpoints.append(_latlon_to_local(node.lat, node.lon))
			for j in range(bpoints.size()):
				_add_building_segment_to_spatial_hash({"p1": bpoints[j], "p2": bpoints[(j + 1) % bpoints.size()]}, chunk_key)
			_add_building_poly_to_hash(bpoints, chunk_key)
	# Phase 3: Create objects
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		var nodes: Array = way.get("nodes", [])
		if nodes.size() < 2:
			continue
		var way_id_raw: int = int(way.get("id", 0))
		if way_id_raw in [75621890]:
			continue
		if tags.has("highway"):
			_create_road(nodes, tags, target, null, way_id_raw)
		elif tags.get("railway", "") == "tram":
			var tram_tags: Dictionary = tags.duplicate()
			tram_tags["highway"] = "tram"
			_create_road(nodes, tram_tags, target, null, way_id_raw)
		elif tags.has("building"):
			_create_building(nodes, tags, target, null, way_id_raw, chunk_entrance_nodes, chunk_poi_nodes)
		elif tags.has("amenity") and not tags.has("building"):
			_create_amenity_building(nodes, tags, target, null)
		elif tags.has("natural"):
			# Pre-register water polygons synchronously (see threaded path).
			if tags.get("natural") == "water" and enable_water and nodes.size() >= 3:
				var wpts := PackedVector2Array()
				for n in nodes:
					wpts.append(_latlon_to_local(n.lat, n.lon))
				_register_global_water_polygon(wpts)
				for clipped in _clip_polygon_to_chunk(wpts, chunk_key):
					_register_water_polygon(clipped, target)
			if tags.get("natural", "") == "water" and nodes.size() > 200:
				_terrain_objects_queue.push_front({"type": "natural", "nodes": nodes, "tags": tags, "parent": target})
			else:
				_terrain_objects_queue.append({"type": "natural", "nodes": nodes, "tags": tags, "parent": target})
		elif tags.has("landuse"):
			if tags.get("landuse") in ["reservoir", "basin"] and enable_water and nodes.size() >= 3:
				var lpts := PackedVector2Array()
				for n in nodes:
					lpts.append(_latlon_to_local(n.lat, n.lon))
				_register_global_water_polygon(lpts)
				for clipped in _clip_polygon_to_chunk(lpts, chunk_key):
					_register_water_polygon(clipped, target)
			_terrain_objects_queue.append({"type": "landuse", "nodes": nodes, "tags": tags, "parent": target, "way_id": way_id_raw})
		elif tags.has("leisure"):
			_terrain_objects_queue.append({"type": "leisure", "nodes": nodes, "tags": tags, "parent": target, "way_id": way_id_raw})
		elif tags.has("waterway") and enable_water:
			_create_waterway(nodes, tags, target, null)
	# Pedestrian areas (from relations, separate from highway ways)
	var ped_areas: Array = osm_data.get("pedestrian_areas", [])
	if ped_areas.size() > 0:
		print("OSM: Processing %d pedestrian areas for chunk %s" % [ped_areas.size(), chunk_key])
	for ped_nodes in ped_areas:
		if ped_nodes.size() < 3:
			continue
		var ped_points := PackedVector2Array()
		for node in ped_nodes:
			ped_points.append(_latlon_to_local(node["lat"], node["lon"]))
		_create_pedestrian_area(ped_points, target, chunk_key)
		# Block trees
		_add_building_poly_to_hash(ped_points, chunk_key)

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


func _create_road(nodes: Array, tags: Dictionary, parent: Node3D, _loader: Node, way_id: int = 0, skip_spatial_hash: bool = false) -> void:
	if not enable_roads:
		return
	# Steps are not rendered as road surfaces.
	if tags.get("highway", "") == "steps":
		return
	# Добавляем в очередь для отложенного создания (per-chunk)
	var rq_ck := ""
	if parent.name.begins_with("Chunk_"):
		rq_ck = parent.name.substr(6)
	if not _road_queue.has(rq_ck):
		_road_queue[rq_ck] = []
	_road_queue[rq_ck].append({
		"nodes": nodes,
		"tags": tags,
		"parent": parent,
		"way_id": way_id
	})

	# Сегменты дорог сохраняем сразу (нужны для знаков парковки и проверки фонарей)
	# Skip if spatial hash was already built by Phase 1+2 worker thread
	if skip_spatial_hash:
		return
	var highway_type: String = tags.get("highway", "residential")
	if highway_type in ["tram", "tram_rails"]:
		return  # Tram tracks must NOT be in road spatial hash
	var width: float = _get_road_width(tags)
	var raw_pts := PackedVector2Array()
	raw_pts.resize(nodes.size())
	for i in range(nodes.size()):
		raw_pts[i] = _latlon_to_local(nodes[i].lat, nodes[i].lon)
	var smoothed_pts := _smooth_road_corners(raw_pts)
	var seg_is_bridge: bool = tags.get("bridge", "") == "yes"
	for i in range(smoothed_pts.size() - 1):
		var seg := {
			"p1": smoothed_pts[i],
			"p2": smoothed_pts[i + 1],
			"width": width,
			"way_id": way_id,
			"bridge": seg_is_bridge,
		}
		_add_road_segment_to_spatial_hash(seg, rq_ck)


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
	var width: float = _get_road_width(tags)

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
	# Oneway + lanes → texture_key
	var oneway: String = tags.get("oneway", "")
	var is_oneway: bool = oneway == "yes" or oneway == "-1" or oneway == "true" or oneway == "1"
	var lanes_str: String = str(tags.get("lanes", ""))
	var texture_key: String
	var height_offset: float
	var curb_height: float
	match highway_type:
		"motorway", "trunk":
			var lanes: int = int(lanes_str) if lanes_str.is_valid_int() else (3 if is_oneway else 4)
			texture_key = ("ow%d" if is_oneway else "bi%d") % lanes
			height_offset = 0.012
			curb_height = 0.0
		"motorway_link", "trunk_link":
			texture_key = "residential"
			height_offset = 0.012
			curb_height = 0.0
		"primary":
			var lanes: int = int(lanes_str) if lanes_str.is_valid_int() else (2 if is_oneway else 4)
			texture_key = ("ow%d" if is_oneway else "bi%d") % lanes
			height_offset = 0.010
			curb_height = 0.0
		"primary_link":
			texture_key = "residential"
			height_offset = 0.010
			curb_height = 0.0
		"secondary":
			var lanes: int = int(lanes_str) if lanes_str.is_valid_int() else (2 if is_oneway else 4)
			texture_key = ("ow%d" if is_oneway else "bi%d") % lanes
			height_offset = 0.008
			curb_height = 0.0
		"secondary_link":
			texture_key = "residential"
			height_offset = 0.008
			curb_height = 0.0
		"tertiary", "tertiary_link":
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
		"tram":
			texture_key = "tram_bed"
			height_offset = 0.003  # Below all roads so ties hidden at crossings
			curb_height = 0.0
		"tram_rails":
			texture_key = "tram_rails"
			height_offset = 0.05  # 5cm above road — visually raised, car bounces
			curb_height = 0.0
		"footway", "path", "cycleway", "track":
			texture_key = "path"
			height_offset = 0.23
			curb_height = 0.0
		_:
			texture_key = "residential"
			height_offset = 0.006
			curb_height = 0.0

	# Debug: log specific ways
	var _debug_way_id: int = task_data.get("way_id", 0)
	var _debug_way: bool = _debug_way_id in [60119987, 84060676]

	# For _link roads: shift first/last raw point from parent road center to parent road edge.
	# Link roads start at a shared junction node (center of parent road). Their mesh overlaps
	# the parent road mesh, causing z-fighting when textures differ.
	# By moving raw[0] along the link direction by parent_half_width, the link starts at the
	# parent edge, and smoothing creates a curve from there — preserving roundings, no overlap.
	#
	# EXCEPTION (Stage 2A.3 root-cause fix, verified by visual debug overlay):
	# when the parent at the junction is a bridge=yes way, there is NO parent road mesh —
	# on-deck bridge=yes ways render as deck-painted markings, not road meshes. The shift
	# is unnecessary and creates the visible 2.7 m gap between road approach and bridge
	# polygon outline. The polygon outline IS a vertex of the road's node[0] in OSM data.
	if highway_type.ends_with("_link") and local_points.size() >= 2:
		var parent_hw: float = 6.0
		if highway_type in ["motorway_link", "trunk_link"]:
			parent_hw = 7.0
		elif highway_type in ["primary_link"]:
			parent_hw = 6.0
		elif highway_type in ["secondary_link"]:
			parent_hw = 5.0
		else:
			parent_hw = 4.0
		var first_node: Dictionary = nodes[0]
		var last_node: Dictionary = nodes[nodes.size() - 1]
		# Shift start unless the start junction is shared with a bridge=yes way.
		if not _bridge_endpoint_touches_any(first_node.lat, first_node.lon):
			var dir_start: Vector2 = (local_points[1] - local_points[0]).normalized()
			var shift_dist_start: float = minf(parent_hw, local_points[0].distance_to(local_points[1]) * 0.5)
			local_points[0] = local_points[0] + dir_start * shift_dist_start
		# Shift end unless the end junction is shared with a bridge=yes way.
		if not _bridge_endpoint_touches_any(last_node.lat, last_node.lon):
			var last_idx: int = local_points.size() - 1
			var dir_end: Vector2 = (local_points[last_idx - 1] - local_points[last_idx]).normalized()
			var shift_dist_end: float = minf(parent_hw, local_points[last_idx].distance_to(local_points[last_idx - 1]) * 0.5)
			local_points[last_idx] = local_points[last_idx] + dir_end * shift_dist_end

	# Smoothing (thread-safe: pure math) — skip for tram (straight tracks, smoothing creates wobble)
	var smoothed_points: PackedVector2Array
	if highway_type in ["tram", "tram_rails"]:
		smoothed_points = _subdivide_for_elevation(local_points)
	else:
		smoothed_points = _smooth_road_corners(local_points)

	# Save full smoothed points BEFORE clip — needed for corridor polygon
	var full_smoothed_points: PackedVector2Array = smoothed_points

	if _debug_way:
		print("ROAD_DEBUG way=%d type=%s width=%.1f chunk=%s raw=%d smoothed=%d" % [_debug_way_id, highway_type, width, chunk_key, local_points.size(), smoothed_points.size()])
		# Show raw points with angles
		for i in range(local_points.size()):
			var angle_info := ""
			if i > 0 and i < local_points.size() - 1:
				var d1: Vector2 = (local_points[i] - local_points[i-1]).normalized()
				var d2: Vector2 = (local_points[i+1] - local_points[i]).normalized()
				var dot_val: float = d1.dot(d2)
				var angle_deg: float = rad_to_deg(acos(clampf(dot_val, -1.0, 1.0)))
				angle_info = " angle=%.1f°" % angle_deg
			print("  raw[%d] = (%.3f, %.3f)%s" % [i, local_points[i].x, local_points[i].y, angle_info])
		# Show smoothed with distance from junction
		var junction_pt: Vector2 = local_points[0]
		for i in range(mini(smoothed_points.size(), 10)):
			var dist_from_junc: float = smoothed_points[i].distance_to(junction_pt)
			print("  smoothed[%d] = (%.3f, %.3f) dist_from_start=%.2fm" % [i, smoothed_points[i].x, smoothed_points[i].y, dist_from_junc])
	# Клипаем smoothed_points к bbox чанка (используется для curbs, lamps)
	var chunk_min_x := -INF
	var chunk_max_x := INF
	var chunk_min_z := -INF
	var chunk_max_z := INF
	if chunk_key != "initial" and chunk_key != "":
		var ck_parts_sm: PackedStringArray = chunk_key.split(",")
		var ck_x_sm := int(ck_parts_sm[0])
		var ck_z_sm := int(ck_parts_sm[1])
		chunk_min_x = float(ck_x_sm) * t_chunk_size
		chunk_max_x = float(ck_x_sm + 1) * t_chunk_size
		chunk_min_z = float(ck_z_sm) * t_chunk_size
		chunk_max_z = float(ck_z_sm + 1) * t_chunk_size
		var clip_margin: float = width * 0.5
		smoothed_points = _clip_polyline_to_rect(smoothed_points,
			chunk_min_x - clip_margin, chunk_max_x + clip_margin, chunk_min_z - clip_margin, chunk_max_z + clip_margin)
		if smoothed_points.size() < 2:
			# Дорога полностью вне чанка — уменьшаем счётчик и выходим
			_road_mutex.lock()
			_pending_road_tasks -= 1
			_decrement_pending_road_task(chunk_key)
			_road_mutex.unlock()
			return

	# Build geometry if not bridge
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var terrain_corridors: Array[PackedVector2Array] = []

	if not is_bridge and highway_type not in ["footway", "path"]:
		# Validate + clip (thread-safe: pure math)
		# Skip vertex gen for footway/path — they get re-split on main thread anyway
		var validated: PackedVector2Array = _validate_road_direction(smoothed_points)
		var half_w: float = width * 0.5

		# Corridor: use offset_polyline for proper non-self-intersecting polygon.
		# Manual perp-based construction self-intersects at sharp turns, causing
		# Geometry2D.clip_polygons to produce unpredictable terrain artifacts.
		var full_validated: PackedVector2Array = _validate_road_direction(full_smoothed_points)
		if full_validated.size() >= 2 and highway_type not in ["cycleway", "track", "steps", "tram_rails"]:
			var corridor_delta: float = half_w + 0.1  # 10cm buffer over mesh width
			# Subdivide centerline at grid crossings so corridor shape matches road mesh on slopes
			var full_subdivided: PackedVector2Array = _subdivide_for_elevation(full_validated)
			var clip_rect := PackedVector2Array()
			if chunk_key != "initial" and chunk_key != "":
				var ck_parts_c: PackedStringArray = chunk_key.split(",")
				var c_x := int(ck_parts_c[0])
				var c_z := int(ck_parts_c[1])
				var ch_x0 := float(c_x) * t_chunk_size
				var ch_x1 := float(c_x + 1) * t_chunk_size
				var ch_z0 := float(c_z) * t_chunk_size
				var ch_z1 := float(c_z + 1) * t_chunk_size
				clip_rect = PackedVector2Array([
					Vector2(ch_x0, ch_z0), Vector2(ch_x1, ch_z0),
					Vector2(ch_x1, ch_z1), Vector2(ch_x0, ch_z1),
				])
			terrain_corridors.append_array(_build_terrain_corridors_for_polyline(full_subdivided, corridor_delta, clip_rect))

		var points: PackedVector2Array = validated

		# Clip polyline to chunk with margin (for mesh vertices)
		if chunk_key != "initial" and chunk_key != "":
			var ck_parts: PackedStringArray = chunk_key.split(",")
			var ck_x := int(ck_parts[0])
			var ck_z := int(ck_parts[1])
			points = _clip_polyline_to_rect(points,
				float(ck_x) * t_chunk_size - half_w,
				float(ck_x + 1) * t_chunk_size + half_w,
				float(ck_z) * t_chunk_size - half_w,
				float(ck_z + 1) * t_chunk_size + half_w)

		# Insert centerline points where road edges cross chunk boundary
		points = _insert_chunk_edge_points(points, half_w, chunk_min_x, chunk_max_x, chunk_min_z, chunk_max_z)

		# Subdivide at grid crossings so road mesh follows bilinear elevation accurately.
		# Without this, long straight segments have only 2 vertices and the flat quad
		# diverges from the terrain surface on slopes.
		points = _subdivide_for_elevation(points)

		# Diagnostic: for ramp-owning ways, log + record the FIRST/LAST
		# vertex after ALL processing so the detector overlay can draw
		# them as 3D markers (visualise the gap to the bridge polygon).
		if _ramp_detector != null \
				and _ramp_detector.way_owns_ramp(_debug_way_id) \
				and points.size() >= 2:
			# Send to detector for overlay (deferred = main-thread safe).
			_ramp_detector.call_deferred("record_road_endpoints",
					_debug_way_id, chunk_key,
					points[0], points[points.size() - 1])
			if OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG"):
				var pidx_log: Array = _ramp_detector.get_polygon_indices_for_way(_debug_way_id)
				for pi in pidx_log:
					if int(pi) < 0 or int(pi) >= _bridge_deck_polygons.size(): continue
					var poly_log: PackedVector2Array = _bridge_deck_polygons[int(pi)]
					var d_first: float = _min_dist_to_polygon_outline(points[0], poly_log)
					var d_last: float = _min_dist_to_polygon_outline(points[points.size() - 1], poly_log)
					print("[BridgeRamp] FINAL way=%d chunk=%s n=%d first=(%.2f,%.2f) d=%.2f last=(%.2f,%.2f) d=%.2f"
							% [_debug_way_id, chunk_key, points.size(),
								points[0].x, points[0].y, d_first,
								points[points.size() - 1].x, points[points.size() - 1].y, d_last])



		if _debug_way:
			print("ROAD_DEBUG way=%d validated=%d clipped=%d chunk=%s margin=%.1f" % [_debug_way_id, validated.size(), points.size(), chunk_key, half_w + 1.0])
			for i in range(points.size()):
				print("  final[%d] = (%.3f, %.3f)" % [i, points[i].x, points[i].y])
			# Show chunk boundaries and overlap zone
			if chunk_key != "initial" and chunk_key != "":
				var _ck_p: PackedStringArray = chunk_key.split(",")
				var _cx := int(_ck_p[0])
				var _cz := int(_ck_p[1])
				var _cs := t_chunk_size
				print("  chunk_bounds: x=[%.1f, %.1f] z=[%.1f, %.1f]" % [float(_cx) * _cs, float(_cx + 1) * _cs, float(_cz) * _cs, float(_cz + 1) * _cs])
				print("  clip_bounds: x=[%.1f, %.1f] z=[%.1f, %.1f]" % [float(_cx) * _cs - half_w - 1.0, float(_cx + 1) * _cs + half_w + 1.0, float(_cz) * _cs - half_w - 1.0, float(_cz + 1) * _cs + half_w + 1.0])

		if points.size() >= 2:
			# Hash from ORIGINAL first point (before clip) so all chunks get same height for same road
			var hash_val: int = int(abs(local_points[0].x * 1000 + local_points[0].y * 7919)) % 100
			var z_offset: float = hash_val * 0.000005
			if _debug_way:
				print("ROAD_DEBUG way=%d height_offset=%.4f z_offset=%.5f hash=%d" % [_debug_way_id, height_offset, z_offset, hash_val])
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

			if _debug_way:
				for i in range(n_points):
					print("  perp[%d] = (%.4f, %.4f) at (%.3f, %.3f)" % [i, perpendiculars[i].x, perpendiculars[i].y, points[i].x, points[i].y])

			# Pre-compute raw left/right edges and accumulated lengths
			var uv_scale: float = 0.1
			var left_pts := PackedVector2Array()
			var right_pts := PackedVector2Array()
			var accum_lens := PackedFloat64Array()
			var accum_len: float = 0.0
			for i in range(n_points):
				var p: Vector2 = points[i]
				var perp: Vector2 = perpendiculars[i]
				if i > 0:
					accum_len += points[i - 1].distance_to(p)
				left_pts.append(Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w))
				right_pts.append(Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w))
				accum_lens.append(accum_len)

			# Bridge-endpoint perp override (Attempt #12, see docs/bridge_debug.md):
			# At a ramp-owning way's first/last vertex coinciding with a polygon
			# vertex, override perpendiculars[0]/[n-1] with the polygon outline
			# tangent at that vertex (averaged direction prev→next). This makes
			# l[0]/r[0] (computed as p[0] ± perp * half_w) lie ON the polygon
			# outline by construction — no Z-offset, no angular mismatch at the
			# abutment seam. Road keeps its standard 7 m carriageway width;
			# polygon mesh covers the deck-only lateral wedge between road edge
			# and polygon outline corner (v15 east, v18 west). Width override
			# (Attempt #13) was tried and reverted: snapping l[0]/r[0] directly
			# to v15/v18 (12 m wide) deformed lane-marking textures (UV stretch
			# across trapezoidal quad) and caused l[0] to extend beyond the
			# chunk boundary, overlapping the neighbouring chunk's road mesh.
			# Sign of the polygon tangent is flipped if it would invert the
			# perpendicular relative to the road's natural left/right side
			# (otherwise the first quad twists into an X and the mesh
			# degenerates).
			if _ramp_detector != null and _ramp_detector.way_owns_ramp(_debug_way_id) and n_points >= 2:
				var first_n: Dictionary = nodes[0]
				if _bridge_endpoint_touches_any(first_n.lat, first_n.lon):
					var first_local := Vector2(
							(first_n.lon - t_start_lon) * t_lon_scale,
							-(first_n.lat - t_start_lat) * 111000.0)
					if points[0].distance_to(first_local) < 0.5:
						var d_first := _polygon_abutment_dir_at_local(first_local)
						if d_first != Vector2.ZERO:
							if d_first.dot(perpendiculars[0]) < 0.0:
								d_first = -d_first
							var p0: Vector2 = points[0]
							left_pts[0] = Vector2(p0.x - d_first.x * half_w, p0.y - d_first.y * half_w)
							right_pts[0] = Vector2(p0.x + d_first.x * half_w, p0.y + d_first.y * half_w)
				var last_n: Dictionary = nodes[nodes.size() - 1]
				if _bridge_endpoint_touches_any(last_n.lat, last_n.lon):
					var last_local := Vector2(
							(last_n.lon - t_start_lon) * t_lon_scale,
							-(last_n.lat - t_start_lat) * 111000.0)
					var li: int = n_points - 1
					if points[li].distance_to(last_local) < 0.5:
						var d_last := _polygon_abutment_dir_at_local(last_local)
						if d_last != Vector2.ZERO:
							if d_last.dot(perpendiculars[li]) < 0.0:
								d_last = -d_last
							var pn: Vector2 = points[li]
							left_pts[li] = Vector2(pn.x - d_last.x * half_w, pn.y - d_last.y * half_w)
							right_pts[li] = Vector2(pn.x + d_last.x * half_w, pn.y + d_last.y * half_w)

			# Chunk rect for 2D intersection
			var mesh_clip_rect := PackedVector2Array()
			if chunk_min_x != -INF:
				mesh_clip_rect = PackedVector2Array([
					Vector2(chunk_min_x, chunk_min_z), Vector2(chunk_max_x, chunk_min_z),
					Vector2(chunk_max_x, chunk_max_z), Vector2(chunk_min_x, chunk_max_z),
				])

			# Per-segment: build quad, clip against chunk rect, triangulate
			for seg in range(n_points - 1):
				var l0 := left_pts[seg]
				var l1 := left_pts[seg + 1]
				var r0 := right_pts[seg]
				var r1 := right_pts[seg + 1]

				var seg_dir := points[seg + 1] - points[seg]
				var seg_len := seg_dir.length()
				if seg_len < 0.001:
					continue
				seg_dir /= seg_len
				var seg_perp := Vector2(-seg_dir.y, seg_dir.x)

				# Check if any vertex is outside chunk
				var need_clip := false
				if mesh_clip_rect.size() > 0:
					for v in [l0, l1, r0, r1]:
						if v.x < chunk_min_x or v.x > chunk_max_x or v.y < chunk_min_z or v.y > chunk_max_z:
							need_clip = true
							break

				if not need_clip:
					# Fast path: quad fully inside chunk — two triangles.
					# Stage 2A: edge vertices share the centerline distance
					# of the seg index that produced them, so all four call
					# sites pass accum_lens[seg] or accum_lens[seg+1].
					var base_idx := vertices.size()
					var uv_y0: float = accum_lens[seg] * uv_scale
					var uv_y1: float = accum_lens[seg + 1] * uv_scale
					var cl_d_seg: float = accum_lens[seg]
					var cl_d_next: float = accum_lens[seg + 1]
					var h_l0: float = _road_sample_y_for_way(_debug_way_id, l0, cl_d_seg, height_offset + z_offset)
					var h_r0: float = _road_sample_y_for_way(_debug_way_id, r0, cl_d_seg, height_offset + z_offset)
					var h_l1: float = _road_sample_y_for_way(_debug_way_id, l1, cl_d_next, height_offset + z_offset)
					var h_r1: float = _road_sample_y_for_way(_debug_way_id, r1, cl_d_next, height_offset + z_offset)
					vertices.append(Vector3(l0.x, h_l0, l0.y))
					uvs.append(Vector2(0.0, uv_y0))
					normals.append(Vector3.UP)
					vertices.append(Vector3(r0.x, h_r0, r0.y))
					uvs.append(Vector2(1.0, uv_y0))
					normals.append(Vector3.UP)
					vertices.append(Vector3(l1.x, h_l1, l1.y))
					uvs.append(Vector2(0.0, uv_y1))
					normals.append(Vector3.UP)
					vertices.append(Vector3(r1.x, h_r1, r1.y))
					uvs.append(Vector2(1.0, uv_y1))
					normals.append(Vector3.UP)
					indices.append(base_idx)
					indices.append(base_idx + 3)
					indices.append(base_idx + 1)
					indices.append(base_idx)
					indices.append(base_idx + 2)
					indices.append(base_idx + 3)
				else:
					# 2D intersection: clip road quad against chunk boundary
					# CCW winding: left-forward then right-backward
					var quad := PackedVector2Array([l0, l1, r1, r0])
					if _polygon_area(quad) < 0:
						quad.reverse()
					var clipped_list: Array[PackedVector2Array] = Geometry2D.intersect_polygons(quad, mesh_clip_rect)
					for clip_poly in clipped_list:
						if clip_poly.size() < 3:
							continue
						var tri_idx := Geometry2D.triangulate_polygon(clip_poly)
						if tri_idx.is_empty():
							continue
						var base_idx := vertices.size()
						# Stage 2A clipped path: kept as terrain fallback —
						# applying way-aware ramp here projects v2 onto the
						# centerline and creates a vertical "patch" at chunk
						# seams where part of the quad is on-ramp and part is
						# off-ramp. Documented as known limitation; revisit
						# in Stage 2B with proper polygon-edge stitching.
						for v2 in clip_poly:
							var h: float = _sample_elevation(v2.x, v2.y) + height_offset + z_offset
							vertices.append(Vector3(v2.x, h, v2.y))
							# UV from projection onto segment axes
							var rel := v2 - points[seg]
							var along := rel.dot(seg_dir)
							var cross_d := rel.dot(seg_perp)
							var uv_x := clampf(cross_d / width + 0.5, 0.0, 1.0)
							var uv_y := (accum_lens[seg] + along) * uv_scale
							uvs.append(Vector2(uv_x, uv_y))
							normals.append(Vector3.UP)
						for ti in tri_idx:
							indices.append(base_idx + ti)

	# Store result via mutex
	var result := {
		"smoothed_points": smoothed_points,
		"full_smoothed_points": full_smoothed_points,
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
		"way_id": task_data.get("way_id", 0),
		"terrain_corridors": terrain_corridors
	}
	_road_mutex.lock()
	_road_results.append(result)
	_pending_road_tasks -= 1
	_decrement_pending_road_task(chunk_key)
	_road_mutex.unlock()


## Применяет результат road geometry из worker thread (main thread only)
func _apply_road_result(result: Dictionary) -> void:
	var parent: Node3D = result.parent
	var chunk_key: String = result.chunk_key
	if not is_instance_valid(parent):
		_emit_road_debug("ROAD_DROP key=%s reason=invalid_parent highway=%s way_id=%s" % [
			chunk_key,
			str(result.get("highway_type", "")),
			str(result.get("way_id", 0))
		])
		return

	var texture_key: String = result.texture_key
	var smoothed_points: PackedVector2Array = result.smoothed_points
	var width: float = result.width
	var height_offset: float = result.height_offset
	var curb_height: float = result.curb_height
	var highway_type: String = result.highway_type
	var is_bridge: bool = result.is_bridge
	var elevation_info: Dictionary = result.elevation_info

	# A bridge=yes way INSIDE a man_made=bridge polygon doesn't get its own
	# road mesh / ramps / barriers — the deck polygon IS the road surface.
	# Vehicle roads on the deck only paint lane markings; footways become a
	# slightly raised sidewalk strip with a curb on the inner edge. This is
	# the asaxenov bridge handling restored from 7102d8c after the sk merge
	# wiped it. The on-deck branch still falls through to the regular
	# corridor / lamp / traffic-network registration below so the bridge
	# road is part of the navigation graph.
	var on_deck: bool = is_bridge and _is_way_on_bridge_deck(result.nodes)
	# All bridge=yes roads inside polygon stay on-deck — the lateral exit
	# system in _deck_surface_y_at ramps the deck surface down at arm tips.

	var _way_id_disp: int = int(result.get("way_id", 0))
	if is_bridge:
		print("[BridgeDispatch] way=%d type=%s on_deck=%s pts=%d" % [
			_way_id_disp, highway_type, on_deck, smoothed_points.size()])

	if is_bridge and on_deck:
		# Detect ramp junction: endpoint near polygon boundary → apron needed
		if highway_type not in ["footway", "path", "steps"] and smoothed_points.size() >= 2:
			_detect_ramp_junction(result.nodes, smoothed_points, width)
		var is_footway_on_deck: bool = highway_type in ["footway", "path"]
		if not is_footway_on_deck:
			_create_on_deck_lane_markings(smoothed_points, width, result.get("tags", {}), parent)
		else:
			_create_on_deck_footway(smoothed_points, width, result.get("tags", {}), parent, chunk_key, result.nodes)
	elif is_bridge:
		_create_bridge_road(result.nodes, width, texture_key, height_offset, elevation_info, parent, int(result.get("way_id", 0)), result.get("tags", {}))
	elif highway_type in ["footway", "path"] and smoothed_points.size() >= 2:
		# Defer footway splitting + vertex gen to avoid 10-15ms spikes from
		# _is_point_on_vehicle_road (spatial hash + intersection contours per point)
		var cleaned: PackedVector2Array = _remove_polyline_zigzag(smoothed_points)
		if cleaned.size() >= 2:
			var fw_ck := _get_chunk_key_from_node(parent)
			_deferred_append(_deferred_footway_queue, fw_ck, {
				"smoothed_points": cleaned,
				"width": width,
				"tags": result.get("tags", {}),
				"parent": parent,
				"way_id": result.get("way_id", 0),
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

	# Регистрируем коридоры для выреза террейна (посчитаны и клипнуты к чанку в worker thread)
	var corridors: Array = result.get("terrain_corridors", [])
	var ck := _get_chunk_key_from_node(parent)
	if not corridors.is_empty():
		if not _chunk_terrain_roads.has(ck):
			_chunk_terrain_roads[ck] = []
		for corridor in corridors:
			if corridor.size() >= 3:
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
			"bridge_info": elevation_info,
			"way_id": int(result.get("way_id", 0)),  # Stage 2B: thread through to curb sampler
		})

	# Lamps (major roads only) - clip to chunk rect, deferred
	if highway_type in ["motorway", "trunk", "primary", "secondary", "tertiary"]:
		var lamp_ck := _get_chunk_key_from_node(parent)
		var lamp_rect := _get_chunk_rect_from_key(lamp_ck)
		var lamp_pts := _clip_polyline_to_rect(smoothed_points, lamp_rect.position.x, lamp_rect.end.x, lamp_rect.position.y, lamp_rect.end.y)
		if lamp_pts.size() >= 2:
			_deferred_append(_deferred_lamp_queue, lamp_ck, {"points": lamp_pts, "width": width, "parent": parent})

	# Manholes - clip to chunk rect, deferred
	if highway_type in ["primary", "secondary", "tertiary", "residential", "unclassified"]:
		var mh_ck := _get_chunk_key_from_node(parent)
		var mh_rect := _get_chunk_rect_from_key(mh_ck)
		var mh_pts := _clip_polyline_to_rect(smoothed_points, mh_rect.position.x, mh_rect.end.x, mh_rect.position.y, mh_rect.end.y)
		if mh_pts.size() >= 2:
			_deferred_append(_deferred_manhole_queue, mh_ck, {"points": mh_pts, "width": width, "parent": parent})

	# Road/tram network - deferred (use FULL unclipped points for complete waypoint chain)
	if highway_type == "tram":
		var tram_way_id: int = result.get("way_id", 0)
		if not _dispatched_tram_network.has(tram_way_id):
			_dispatched_tram_network[tram_way_id] = true
			var full_pts: PackedVector2Array = result.get("full_smoothed_points", smoothed_points)
			_deferred_tram_queue.append({"points": full_pts, "tags": result.tags})
	elif highway_type == "tram_rails":
		# Create collision for raised rails — thin boxes along each rail line
		_create_rail_collision(smoothed_points, parent)
	else:
		_deferred_traffic_queue.append({"points": smoothed_points, "tags": result.tags, "elevation_info": elevation_info})



## Creates collision shapes along tram rail lines (two rails per track, gauge 1520mm)
func _create_rail_collision(points: PackedVector2Array, parent: Node3D) -> void:
	if points.size() < 2 or not is_instance_valid(parent):
		return
	var rail_h := 0.05  # 5cm rail height
	var rail_w := 0.07  # 7cm rail width
	var gauge_half := 0.76  # Half gauge (1520mm / 2)
	var body := StaticBody3D.new()
	body.name = "TramRailCollision"
	for i in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var seg := p1 - p0
		var seg_len := seg.length()
		if seg_len < 0.5:
			continue
		var dir := seg / seg_len
		var perp := Vector2(-dir.y, dir.x)
		var mid_2d := (p0 + p1) * 0.5
		var angle := atan2(dir.x, dir.y)
		var elev_mid := _sample_elevation(mid_2d.x, mid_2d.y)
		# Two rails offset by gauge
		for rail_offset in [-gauge_half, gauge_half]:
			var ro: float = rail_offset
			var rail_mid: Vector2 = mid_2d + perp * ro
			var shape := BoxShape3D.new()
			shape.size = Vector3(rail_w, rail_h, seg_len)
			var col := CollisionShape3D.new()
			col.shape = shape
			col.position = Vector3(rail_mid.x, elev_mid + rail_h * 0.5, rail_mid.y)
			col.rotation.y = -angle
			body.add_child(col)
	parent.add_child(body)


## Standalone bridge road (bridge=yes way that is NOT inside a man_made=
## bridge deck polygon). Restored verbatim from 7102d8c — same shared/free
## endpoint detection, same ramp profile via `_bridge_height_at`, same
## pillars+barriers wiring. Only the per-vertex Y is shifted up by
## `_sample_elevation()` so the bridge sits on the elevation-aware terrain
## instead of at world Y=0.
func _create_bridge_road(nodes: Array, width: float, texture_key: String, height_offset: float, _bridge_info: Dictionary, parent: Node3D, way_id: int = 0, tags: Dictionary = {}) -> void:
	if nodes.size() < 2:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	var total_length := 0.0
	for i in range(points.size() - 1):
		total_length += points[i].distance_to(points[i + 1])
	if total_length < 1.0:
		return

	# Shared/free endpoints — by OSM lat/lon (NOT local coords, which can
	# diverge between adjacent ways due to clipping/smoothing).
	var first_n: Dictionary = nodes[0]
	var last_n: Dictionary = nodes[nodes.size() - 1]
	var start_shared: bool = _bridge_endpoint_is_shared(first_n.lat, first_n.lon)
	var end_shared: bool = _bridge_endpoint_is_shared(last_n.lat, last_n.lon)

	# Ramp lengths on both ends. Shared end → 0 (no ramp, the way meets its
	# neighbour at full deck height). Free end → cover up to BRIDGE_RAMP_LENGTH
	# so even short ways reach deck height before transitioning down.
	var ramp_from_start: float = 0.0
	var ramp_from_end: float = 0.0
	if not start_shared:
		ramp_from_start = minf(BRIDGE_RAMP_LENGTH, total_length)
	if not end_shared:
		ramp_from_end = minf(BRIDGE_RAMP_LENGTH, total_length)
	# Both ends free + shorter than 2× ramp — split evenly so they don't
	# overlap and zero out the centre.
	if not start_shared and not end_shared and total_length < BRIDGE_RAMP_LENGTH * 2.0:
		ramp_from_start = total_length * 0.5
		ramp_from_end = total_length * 0.5

	# Subdivide long segments so the smooth-step ramp stays smooth.
	# 5m gives ~7 vertices in the 35m ramp zone for a smooth S-curve.
	const BRIDGE_SEGMENT_LENGTH := 5.0
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

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	var half_w := width * 0.5
	var accumulated_length := 0.0
	var point_heights := PackedFloat64Array()
	var perpendiculars: Array[Vector2] = _compute_averaged_perpendiculars(points)
	if way_id != 0 and not _bridge_node_ways.is_empty():
		_fix_shared_endpoint_perps(points, perpendiculars, nodes, way_id)

	# Reference elevation for the standalone bridge — max of the way's
	# endpoint elevations (one constant per bridge, like for relation decks).
	# When an endpoint is shared AND sits on a deck polygon, use the polygon's
	# surface Y so the standalone road aligns with the deck (terrain under the
	# bridge may be at river level, much lower than the abutment).
	var p_first: Vector2 = points[0]
	var p_last: Vector2 = points[points.size() - 1]
	var elev_a: float
	var elev_b: float
	if start_shared and _is_point_on_bridge_deck(p_first):
		elev_a = _deck_surface_y_at_cached(p_first) - BRIDGE_DECK_HEIGHT
	else:
		elev_a = _sample_elevation(p_first.x, p_first.y)
	if end_shared and _is_point_on_bridge_deck(p_last):
		elev_b = _deck_surface_y_at_cached(p_last) - BRIDGE_DECK_HEIGHT
	else:
		elev_b = _sample_elevation(p_last.x, p_last.y)
	var ref_elev: float = maxf(elev_a, elev_b)
	var deck_top: float = ref_elev + BRIDGE_DECK_HEIGHT + height_offset

	for i in range(points.size()):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]
		# Bridge Y = lerp(local_terrain, deck_top, smooth_step(t)) so the
		# deck stays flat on its middle section and ties down to local
		# ground at the abutments.
		var ramp_t: float = 1.0
		if ramp_from_start > 0.0 and accumulated_length < ramp_from_start:
			ramp_t = accumulated_length / ramp_from_start
		elif ramp_from_end > 0.0 and accumulated_length > total_length - ramp_from_end:
			ramp_t = (total_length - accumulated_length) / ramp_from_end
		var point_height: float
		if ramp_t >= 1.0:
			point_height = deck_top
		else:
			var local := _sample_elevation(p.x, p.y)
			if local == 0.0:
				local = ref_elev
			point_height = lerpf(local + height_offset, deck_top, _smooth_step(ramp_t))

		point_heights.append(point_height)
		var left := Vector3(p.x - perp.x * half_w, point_height, p.y - perp.y * half_w)
		var right := Vector3(p.x + perp.x * half_w, point_height, p.y + perp.y * half_w)
		vertices.append(left)
		vertices.append(right)

		uvs.append(Vector2(0.0, accumulated_length * 0.1))
		uvs.append(Vector2(1.0, accumulated_length * 0.1))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)

		if i < points.size() - 1:
			accumulated_length += points[i].distance_to(points[i + 1])

	for i in range(points.size() - 1):
		var base_idx := i * 2
		indices.append(base_idx); indices.append(base_idx + 2); indices.append(base_idx + 1)
		indices.append(base_idx + 1); indices.append(base_idx + 2); indices.append(base_idx + 3)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	if way_id in [43844912, 128566919]:
		print("[BridgeRoadDump] way=%d ref_elev=%.1f deck_top=%.1f start_shared=%s end_shared=%s ramp_start=%.1f ramp_end=%.1f" % [
			way_id, ref_elev, deck_top, start_shared, end_shared, ramp_from_start, ramp_from_end])
		print("[BridgeRoadDump] verts=%d (left/right pairs):" % vertices.size())
		for vi in range(0, vertices.size(), 2):
			var vl: Vector3 = vertices[vi]
			var vr: Vector3 = vertices[vi + 1] if vi + 1 < vertices.size() else vl
			print("[BridgeRoadVert] %d: left=(%.1f, %.1f, %.1f) right=(%.1f, %.1f, %.1f)" % [
				vi / 2, vl.x, vl.y, vl.z, vr.x, vr.y, vr.z])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material: Material = WetRoadMaterial.create_road_shader_material(
		_road_textures.get(texture_key, null),
		_normal_textures.get("asphalt", null),
		_is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null)
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, texture_key)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BridgeRoad"
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh_instance)

	_create_bridge_collision(vertices, indices, parent)
	_create_bridge_pillars(points, ramp_from_start, ramp_from_end, total_length, parent, ref_elev)
	_create_bridge_barriers(nodes, points, width, ramp_from_start, ramp_from_end, total_length, height_offset, parent, way_id, ref_elev)
	_create_bridge_road_lane_markings(points, perpendiculars, point_heights, width, tags, parent)



## Lane markings for standalone bridge roads. Uses pre-computed per-vertex
## heights from _create_bridge_road so markings follow the smoothstep ramp.
func _create_bridge_road_lane_markings(pts: PackedVector2Array, perps: Array[Vector2],
		heights: PackedFloat64Array, road_width: float, tags: Dictionary, parent: Node3D) -> void:
	if pts.size() < 2:
		return
	var lanes_str: String = str(tags.get("lanes", "2"))
	var lane_count: int = int(lanes_str) if lanes_str.is_valid_int() else 2
	lane_count = clampi(lane_count, 1, 6)
	if lane_count <= 1:
		return
	var half_w: float = road_width * 0.5

	const LINE_WIDTH := 0.15
	const DASH_LENGTH := 3.0
	const DASH_GAP := 3.0
	const MARKING_Y_OFFSET := 0.003

	var marking_mat := StandardMaterial3D.new()
	marking_mat.albedo_color = Color(1.0, 1.0, 1.0)
	marking_mat.roughness = 0.6
	marking_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(marking_mat)

	var acc_lengths := PackedFloat64Array()
	acc_lengths.resize(pts.size())
	acc_lengths[0] = 0.0
	for i in range(1, pts.size()):
		acc_lengths[i] = acc_lengths[i - 1] + pts[i - 1].distance_to(pts[i])

	var lane_w: float = road_width / float(lane_count)
	for lane_i in range(1, lane_count):
		var offset: float = -half_w + lane_w * float(lane_i)
		for seg_i in range(pts.size() - 1):
			var sp1 := pts[seg_i]
			var sp2 := pts[seg_i + 1]
			var seg_len := sp1.distance_to(sp2)
			var seg_acc := acc_lengths[seg_i]
			var h1: float = heights[seg_i] + MARKING_Y_OFFSET
			var h2: float = heights[seg_i + 1] + MARKING_Y_OFFSET
			var cycle := DASH_LENGTH + DASH_GAP
			var pos := 0.0
			while pos < seg_len:
				var abs_pos := seg_acc + pos
				var in_cycle := fmod(abs_pos, cycle)
				if in_cycle < DASH_LENGTH:
					var dash_remaining := DASH_LENGTH - in_cycle
					var draw_len := minf(dash_remaining, seg_len - pos)
					var t1 := pos / seg_len
					var t2 := (pos + draw_len) / seg_len
					var dp1 := sp1.lerp(sp2, t1)
					var dp2 := sp1.lerp(sp2, t2)
					var dperp1 := perps[seg_i].lerp(perps[seg_i + 1], t1)
					var dperp2 := perps[seg_i].lerp(perps[seg_i + 1], t2)
					var dy1: float = lerpf(h1, h2, t1)
					var dy2: float = lerpf(h1, h2, t2)
					var o1 := dp1 + dperp1 * offset
					var o2 := dp2 + dperp2 * offset
					var hw := LINE_WIDTH * 0.5
					var v1 := Vector3(o1.x - dperp1.x * hw, dy1, o1.y - dperp1.y * hw)
					var v2 := Vector3(o1.x + dperp1.x * hw, dy1, o1.y + dperp1.y * hw)
					var v3 := Vector3(o2.x + dperp2.x * hw, dy2, o2.y + dperp2.y * hw)
					var v4 := Vector3(o2.x - dperp2.x * hw, dy2, o2.y - dperp2.y * hw)
					st.set_normal(Vector3.UP)
					st.add_vertex(v1); st.set_normal(Vector3.UP)
					st.add_vertex(v2); st.set_normal(Vector3.UP)
					st.add_vertex(v3)
					st.set_normal(Vector3.UP)
					st.add_vertex(v1); st.set_normal(Vector3.UP)
					st.add_vertex(v3); st.set_normal(Vector3.UP)
					st.add_vertex(v4)
					pos += draw_len
				else:
					var gap_remaining := cycle - in_cycle
					pos += gap_remaining

	var committed := st.commit()
	if committed and committed.get_surface_count() > 0:
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "BridgeRoadLaneMarkings"
		mesh_inst.mesh = committed
		mesh_inst.material_override = marking_mat
		mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mesh_inst)


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
## Pillars on the flat section of the bridge (between the two ramp regions).
## Restored verbatim from 7102d8c — same signature with ramp_from_start /
## ramp_from_end so shared-endpoint segments don't get an unwanted ramp.
## Each pillar drops from the deck (`ref_elev + BRIDGE_DECK_HEIGHT`) to the
## actual ground at its base.
func _create_bridge_pillars(points: PackedVector2Array, ramp_from_start: float, ramp_from_end: float, total_length: float, parent: Node3D, ref_elev: float) -> void:
	if total_length < BRIDGE_MIN_LENGTH_FOR_PILLARS:
		return

	var flat_start: float = ramp_from_start
	var flat_end: float = total_length - ramp_from_end
	if flat_end <= flat_start:
		return  # bridge is all ramp — no pillars

	var deck_top: float = ref_elev + BRIDGE_DECK_HEIGHT
	var accumulated := 0.0
	var last_pillar_pos: float = -BRIDGE_PILLAR_SPACING
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var segment_length := p1.distance_to(p2)
		var seg_start := accumulated
		var seg_end := accumulated + segment_length

		var check_start := maxf(seg_start, flat_start)
		var check_end := minf(seg_end, flat_end)
		if check_start < check_end:
			var pos := check_start
			while pos <= check_end:
				if pos - last_pillar_pos >= BRIDGE_PILLAR_SPACING:
					var t: float = (pos - seg_start) / segment_length if segment_length > 0 else 0.0
					t = clampf(t, 0.0, 1.0)
					var pillar_pos_2d := p1.lerp(p2, t)
					var ground_elev := _sample_elevation(pillar_pos_2d.x, pillar_pos_2d.y)
					if ground_elev == 0.0:
						# Over water / unloaded chunk — make the pillar reach
						# down a sensible amount from the deck instead of
						# floating at world Y=0.
						ground_elev = deck_top - BRIDGE_DECK_HEIGHT * 2.0
					var pillar_height: float = deck_top - ground_elev
					if pillar_height < 0.5:
						pos += BRIDGE_PILLAR_SPACING * 0.5
						continue
					_create_single_pillar(pillar_pos_2d, ground_elev, pillar_height, parent)
					last_pillar_pos = pos
				pos += BRIDGE_PILLAR_SPACING * 0.5
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


## Bridge edge barriers. Heights match the road mesh's lerp(local, deck_top)
## profile so the barrier stays coplanar. Skips quads whose endpoints fall
## into another bridge way's corridor (ramp merges open).
func _create_bridge_barriers(_nodes: Array, points: PackedVector2Array, road_width: float, ramp_from_start: float, ramp_from_end: float, total_length: float, height_offset: float, parent: Node3D, self_way_id: int = 0, ref_elev: float = 0.0) -> void:
	if points.size() < 2:
		return

	const BARRIER_HEIGHT := 0.8
	const BARRIER_WIDTH := 0.15
	const BARRIER_COLOR := Color(0.6, 0.6, 0.6)

	var half_road := road_width * 0.5
	var perpendiculars: Array[Vector2] = _compute_averaged_perpendiculars(points)
	var barrier_ck := _get_chunk_key_from_node(parent)
	var deck_top: float = ref_elev + BRIDGE_DECK_HEIGHT + height_offset

	for side in [-1, 1]:
		var vertices := PackedVector3Array()
		var indices := PackedInt32Array()
		var normals := PackedVector3Array()
		var skip_point: Array[bool] = []
		skip_point.resize(points.size())

		var accumulated := 0.0

		for i in range(points.size()):
			var p: Vector2 = points[i]
			var perp: Vector2 = perpendiculars[i]
			var barrier_pt := Vector2(p.x + perp.x * half_road * side, p.y + perp.y * half_road * side)
			skip_point[i] = _point_in_other_bridge_corridor(barrier_pt, barrier_ck, self_way_id)

			# Match the road mesh's lerp(local, deck_top, smooth_step(t)).
			var ramp_t: float = 1.0
			if ramp_from_start > 0.0 and accumulated < ramp_from_start:
				ramp_t = accumulated / ramp_from_start
			elif ramp_from_end > 0.0 and accumulated > total_length - ramp_from_end:
				ramp_t = (total_length - accumulated) / ramp_from_end
			var road_y: float
			if ramp_t >= 1.0:
				road_y = deck_top
			else:
				var local := _sample_elevation(p.x, p.y)
				if local == 0.0:
					local = ref_elev
				road_y = lerpf(local + height_offset, deck_top, _smooth_step(ramp_t))

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
			# Drop this barrier quad if either endpoint lies inside another
			# bridge way's corridor (ramp merge gap).
			if skip_point[i] or skip_point[i + 1]:
				continue
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

		# Skip empty: every quad got dropped via skip_point (all points landed
		# inside another bridge way's corridor) → indices is empty → Godot
		# throws "index_array_len==NO_INDEX_ARRAY" and corrupts the side.
		# That exception was bubbling up and silently killing the whole
		# road/deck/pillar pipeline for this bridge.
		if vertices.size() < 8 or indices.is_empty():
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


# === Bridge deck + endpoint registry (restored from 7102d8c) =================
# Тут реставрирована система отрисовки деки моста (man_made=bridge relation)
# и реестра общих концов между bridge=yes way'ями. Потеряны при мёрже sk→main
# 0463f00 — sk-сторона переписала эту секцию под elevation, не сохранив
# моих наработок по Октябрьскому мосту.

func _bridge_coord_key(lat: float, lon: float) -> String:
	return "%.7f,%.7f" % [lat, lon]


func _register_bridge_node(lat: float, lon: float, way_id: int) -> void:
	var k := _bridge_coord_key(lat, lon)
	if not _bridge_node_ways.has(k):
		_bridge_node_ways[k] = {}
	(_bridge_node_ways[k] as Dictionary)[way_id] = true


func _bridge_endpoint_is_shared(lat: float, lon: float) -> bool:
	var k := _bridge_coord_key(lat, lon)
	var entries: Dictionary = _bridge_node_ways.get(k, {})
	return entries.size() >= 2


func _bridge_endpoint_touches_any(lat: float, lon: float) -> bool:
	var k := _bridge_coord_key(lat, lon)
	return _bridge_node_ways.has(k)


# Returns the polygon outline direction at a vertex coinciding with `local_pos`.
# When a road approach (e.g. cutting=yes ramp) ends at a man_made=bridge polygon
# vertex, the road's transverse leading edge must lie ON the polygon abutment
# line — not perpendicular to the road tangent (which generally differs by a
# few degrees and produces a sub-meter lateral seam). The abutment direction
# is `(poly[i+1] - poly[i-1]).normalized()`: average of the two edges meeting
# at the vertex, which is exactly the tangent of the polygon outline there.
# Returns Vector2.ZERO if no polygon vertex is found within 0.5 m of local_pos.
# See docs/bridge_debug.md (Attempt #12) for the geometry derivation.
func _polygon_abutment_dir_at_local(local_pos: Vector2) -> Vector2:
	for poly in _bridge_deck_polygons:
		var n: int = poly.size()
		if n < 3:
			continue
		for i in range(n):
			if poly[i].distance_to(local_pos) < 0.5:
				var prev_v: Vector2 = poly[(i - 1 + n) % n]
				var next_v: Vector2 = poly[(i + 1) % n]
				var d: Vector2 = next_v - prev_v
				if d.length_squared() > 0.0001:
					return d.normalized()
	return Vector2.ZERO


# Returns [prev_v, next_v] — the two polygon vertices adjacent to a vertex
# coinciding with `local_pos`. These ARE the corners of the polygon's
# abutment edge through the matching vertex; using them directly as a
# road approach's leading-edge endpoints (`left_pts[0]`, `right_pts[0]`)
# makes the road mesh's transverse edge coincident with the polygon
# outline polyline — same length, same angle, same shared corner points.
# The road quad widens from its normal half-width at the next vertex up
# to the polygon abutment width at the bridge endpoint.
# Returns empty array if no polygon vertex is within 0.5 m.
func _polygon_vertex_neighbors_at_local(local_pos: Vector2) -> Array:
	for poly in _bridge_deck_polygons:
		var n: int = poly.size()
		if n < 3:
			continue
		for i in range(n):
			if poly[i].distance_to(local_pos) < 0.5:
				var prev_v: Vector2 = poly[(i - 1 + n) % n]
				var next_v: Vector2 = poly[(i + 1) % n]
				return [prev_v, next_v]
	return []


func _bridge_prescan_ways(ways: Array) -> void:
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		if not tags.has("highway"):
			continue
		if tags.get("bridge", "") != "yes":
			continue
		var nodes: Array = way.get("nodes", [])
		if nodes.size() < 2:
			continue
		var way_id: int = int(way.get("id", 0))
		if way_id == 75621890:
			continue
		for n in nodes:
			_register_bridge_node(n.lat, n.lon, way_id)


## Detect lateral exit points where _link bridge roads depart the deck polygon.
## Must run after _bridge_prescan_ways (shared endpoint data) and after polygon
## collection. Registers exit data so _deck_surface_y_at ramps the deck down
## and _subdivide_ramp_tris creates fine mesh in the exit zone.
var _deck_exit_way_ids: Dictionary = {}  # dedup across chunks
func _detect_deck_lateral_exits(ways: Array) -> void:
	if _bridge_deck_polygons.is_empty():
		return
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		if tags.get("bridge", "") != "yes":
			continue
		var highway: String = str(tags.get("highway", ""))
		if not highway.ends_with("_link"):
			continue
		var nodes: Array = way.get("nodes", [])
		if nodes.size() < 2:
			continue
		var way_id: int = int(way.get("id", 0))
		if _deck_exit_way_ids.has(way_id):
			continue
		var mid_idx: int = nodes.size() / 2
		var mid_local: Vector2 = _latlon_to_local(nodes[mid_idx].lat, nodes[mid_idx].lon)
		print("[LateralExitScan] way=%d hw=%s mid=(%.1f,%.1f) polys=%d on_deck=%s" % [
			way_id, highway, mid_local.x, mid_local.y,
			_bridge_deck_polygons.size(), _is_point_on_bridge_deck(mid_local)])
		if not _is_point_on_bridge_deck(mid_local):
			continue
		_deck_exit_way_ids[way_id] = true
		var first_n: Dictionary = nodes[0]
		var last_n: Dictionary = nodes[nodes.size() - 1]
		var p0: Vector2 = _latlon_to_local(first_n.lat, first_n.lon)
		var pN: Vector2 = _latlon_to_local(last_n.lat, last_n.lon)
		var s0: bool = _bridge_endpoint_is_shared(first_n.lat, first_n.lon)
		var sN: bool = _bridge_endpoint_is_shared(last_n.lat, last_n.lon)
		var road_w: float = 7.0
		if tags.has("width"):
			var w_str: String = str(tags.width)
			if w_str.is_valid_float():
				road_w = float(w_str)
		elif highway in ["primary_link", "trunk_link"]:
			road_w = 9.0
		# Free start endpoint inside polygon → lateral exit
		if not s0 and _is_point_on_bridge_deck(p0):
			var p1: Vector2 = _latlon_to_local(nodes[1].lat, nodes[1].lon)
			var base_e: float = _sample_elevation(p0.x, p0.y)
			_deck_lateral_exits.append({
				"pos": p0,
				"inward_dir": (p1 - p0).normalized(),
				"half_width": road_w * 0.5,
				"base_elev": base_e,
			})
			print("[LateralExit] way=%d start pos=(%.1f,%.1f) base_elev=%.1f" % [way_id, p0.x, p0.y, base_e])
		# Free end endpoint inside polygon → lateral exit
		if not sN and _is_point_on_bridge_deck(pN):
			var p_prev: Vector2 = _latlon_to_local(nodes[nodes.size() - 2].lat, nodes[nodes.size() - 2].lon)
			var base_e: float = _sample_elevation(pN.x, pN.y)
			_deck_lateral_exits.append({
				"pos": pN,
				"inward_dir": (p_prev - pN).normalized(),
				"half_width": road_w * 0.5,
				"base_elev": base_e,
			})
			print("[LateralExit] way=%d end pos=(%.1f,%.1f) base_elev=%.1f" % [way_id, pN.x, pN.y, base_e])
	# Second pass: bridge=yes non-_link ways with endpoint on polygon
	# boundary. These are on-deck roads entering through polygon arm tips
	# (e.g. secondary road entering from northwest arm). The main ramp
	# axis only covers the two most distant polygon ends, so these arms
	# need lateral exit treatment to ramp the deck surface down.
	const BOUNDARY_SNAP := 3.0
	for way in ways:
		var tags: Dictionary = way.get("tags", {})
		if tags.get("bridge", "") != "yes":
			continue
		var highway: String = str(tags.get("highway", ""))
		if highway.ends_with("_link") or highway.is_empty():
			continue
		var nodes: Array = way.get("nodes", [])
		if nodes.size() < 2:
			continue
		var way_id: int = int(way.get("id", 0))
		if _deck_exit_way_ids.has(way_id):
			continue
		var first_n: Dictionary = nodes[0]
		var last_n: Dictionary = nodes[nodes.size() - 1]
		var p0: Vector2 = _latlon_to_local(first_n.lat, first_n.lon)
		var pN: Vector2 = _latlon_to_local(last_n.lat, last_n.lon)
		# Check if either endpoint is on/near a polygon boundary vertex,
		# but NOT in the main ramp zone (those are already handled by the
		# primary ramp axis in _deck_surface_y_at).
		for poly in _bridge_deck_polygons:
			if poly.size() < 3:
				continue
			var d0: float = _min_dist_to_polygon_outline(p0, poly)
			var dN: float = _min_dist_to_polygon_outline(pN, poly)
			if d0 > BOUNDARY_SNAP and dN > BOUNDARY_SNAP:
				continue
			# Must be inside the polygon (on-deck way, not outside).
			if not Geometry2D.is_point_in_polygon(p0, poly) \
					and not Geometry2D.is_point_in_polygon(pN, poly):
				continue
			# Skip endpoints in the main ramp zone — already covered.
			var ramp_info: Dictionary = _get_deck_ramp_axis(poly)
			if d0 <= BOUNDARY_SNAP:
				var proj0: float = (p0 - ramp_info.origin).dot(ramp_info.axis)
				var end_dist0: float = minf(proj0 - float(ramp_info.min_proj), float(ramp_info.max_proj) - proj0)
				if end_dist0 < BRIDGE_RAMP_LENGTH:
					d0 = INF  # mask out — already handled by main ramp
			if dN <= BOUNDARY_SNAP:
				var projN: float = (pN - ramp_info.origin).dot(ramp_info.axis)
				var end_distN: float = minf(projN - float(ramp_info.min_proj), float(ramp_info.max_proj) - projN)
				if end_distN < BRIDGE_RAMP_LENGTH:
					dN = INF  # mask out
			if d0 > BOUNDARY_SNAP and dN > BOUNDARY_SNAP:
				continue
			_deck_exit_way_ids[way_id] = true
			var road_w: float = 7.0
			if tags.has("width"):
				var w_str: String = str(tags.width)
				if w_str.is_valid_float():
					road_w = float(w_str)
			elif highway in ["primary", "trunk"]:
				road_w = 9.0
			if d0 <= BOUNDARY_SNAP and Geometry2D.is_point_in_polygon(p0, poly):
				var p1: Vector2 = _latlon_to_local(nodes[1].lat, nodes[1].lon)
				var base_e: float = _sample_elevation(p0.x, p0.y)
				_deck_lateral_exits.append({
					"pos": p0,
					"inward_dir": (p1 - p0).normalized(),
					"half_width": road_w * 0.5,
					"base_elev": base_e,
				})
				print("[LateralExit] way=%d boundary start pos=(%.1f,%.1f) base_elev=%.1f" % [way_id, p0.x, p0.y, base_e])
			if dN <= BOUNDARY_SNAP and Geometry2D.is_point_in_polygon(pN, poly):
				var p_prev: Vector2 = _latlon_to_local(nodes[nodes.size() - 2].lat, nodes[nodes.size() - 2].lon)
				var base_e: float = _sample_elevation(pN.x, pN.y)
				_deck_lateral_exits.append({
					"pos": pN,
					"inward_dir": (p_prev - pN).normalized(),
					"half_width": road_w * 0.5,
					"base_elev": base_e,
				})
				print("[LateralExit] way=%d boundary end pos=(%.1f,%.1f) base_elev=%.1f" % [way_id, pN.x, pN.y, base_e])
			break


# Stage 1 bridge ramp detection — instantiate the detector lazily, parented
# to self so it lives next to the deck nodes. Detection runs once after the
# initial OSM load; later, debug toggle is F9. Never touches mesh code.
func _ensure_ramp_detector() -> void:
	if _ramp_detector != null:
		return
	var script: GDScript = load("res://osm/bridge_ramp_detector.gd")
	if script == null:
		push_warning("BridgeRampDetector script not found")
		return
	_ramp_detector = script.new()
	_ramp_detector.name = "BridgeRampDetector"
	add_child(_ramp_detector)


# Stage 2A wrapper: way-aware road vertex Y.
#
# Used ONLY by primary drivable road meshes built in
# _compute_road_geometry_thread. Curbs, sidewalks, lane markings, lamps,
# tram beds and footways still sample terrain directly — Stage 2A is
# scoped to primary road surface only.
#
# When the ramp flag is OFF (default), behaves byte-identical to the
# legacy direct call. When ON, the detector filters candidate ramps by
# `way_id` first, then projects the point onto each candidate's polyline
# with strict perpendicular tolerance. A nearby perpendicular or parallel
# road CANNOT be affected unless its way_id is explicitly registered for
# that ramp.
#
# Thread-safe: the detector takes its mutex internally on the read path.
func _road_sample_y_for_way(way_id: int, point: Vector2,
		centerline_distance: float, height_offset: float) -> float:
	var terrain_y: float = _sample_elevation(point.x, point.y)
	if _ramp_detector == null:
		return terrain_y + height_offset
	return _ramp_detector.sample_road_y_for_way(
			way_id, point, centerline_distance, terrain_y, height_offset)


# Stage 2A.3 — SNAP polyline endpoints to polygon outline.
# For each endpoint OUTSIDE polygon and within SNAP_DIST of polygon
# outline, MOVE it to the closest polygon outline point. This ensures
# the road mesh's edge is EXACTLY on the polygon outline → bridge mesh
# meets road mesh flush. Skip if endpoint already inside polygon
# (polyline crosses naturally).
func _smart_extend_polyline_to_polygon(points: PackedVector2Array,
		polygon: PackedVector2Array, way_id: int, chunk_key: String) -> PackedVector2Array:
	const SNAP_DIST := 5.0
	if points.size() < 2 or polygon.size() < 3:
		return points
	var result: PackedVector2Array = points.duplicate()
	var first_inside: bool = Geometry2D.is_point_in_polygon(result[0], polygon)
	var last_inside: bool = Geometry2D.is_point_in_polygon(result[result.size() - 1], polygon)
	# Snap FIRST endpoint if needed.
	if not first_inside:
		var first: Vector2 = result[0]
		var snap_first: Vector2 = _closest_point_on_polygon_outline(first, polygon)
		var d_first: float = first.distance_to(snap_first)
		if d_first <= SNAP_DIST and d_first > 0.01:
			result[0] = snap_first
			if OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG"):
				print("[BridgeRamp] SNAP way=%d chunk=%s first %.2f m to polygon"
						% [way_id, chunk_key, d_first])
	# Snap LAST endpoint if needed.
	if not last_inside:
		var last_idx: int = result.size() - 1
		var last: Vector2 = result[last_idx]
		var snap_last: Vector2 = _closest_point_on_polygon_outline(last, polygon)
		var d_last: float = last.distance_to(snap_last)
		if d_last <= SNAP_DIST and d_last > 0.01:
			result[last_idx] = snap_last
			if OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG"):
				print("[BridgeRamp] SNAP way=%d chunk=%s last %.2f m to polygon"
						% [way_id, chunk_key, d_last])
	return result


# Returns the closest point on polygon's outline (any edge) to `point`.
func _closest_point_on_polygon_outline(point: Vector2, polygon: PackedVector2Array) -> Vector2:
	var best_pt: Vector2 = polygon[0]
	var best_dist: float = INF
	for j in range(polygon.size()):
		var p1: Vector2 = polygon[j]
		var p2: Vector2 = polygon[(j + 1) % polygon.size()]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, p1, p2)
		var d: float = closest.distance_to(point)
		if d < best_dist:
			best_dist = d
			best_pt = closest
	return best_pt


func _min_dist_to_polygon_outline(point: Vector2, polygon: PackedVector2Array) -> float:
	var best: float = INF
	for j in range(polygon.size()):
		var p1: Vector2 = polygon[j]
		var p2: Vector2 = polygon[(j + 1) % polygon.size()]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, p1, p2)
		var d: float = closest.distance_to(point)
		if d < best:
			best = d
	return best


# Old extension helper (replaced by _smart_extend_polyline_to_polygon).
# Kept for reference if simpler logic ever needed.
func _extend_polyline_to_polygon_edge(points: PackedVector2Array,
		polygon: PackedVector2Array, way_id: int, chunk_key: String) -> PackedVector2Array:
	const MAX_EXT := 10.0
	if points.size() < 2 or polygon.size() < 3:
		return points
	var result: PackedVector2Array = points.duplicate()
	# Try extending FIRST endpoint (backward direction).
	var first: Vector2 = result[0]
	if not Geometry2D.is_point_in_polygon(first, polygon):
		var tangent: Vector2 = first - result[1]
		var t_len: float = tangent.length()
		if t_len > 0.001:
			tangent = tangent / t_len
			var ray_end: Vector2 = first + tangent * MAX_EXT
			var best_inter: Vector2 = Vector2.INF
			var best_dist: float = MAX_EXT + 1.0
			for j in range(polygon.size()):
				var p1: Vector2 = polygon[j]
				var p2: Vector2 = polygon[(j + 1) % polygon.size()]
				var inter = Geometry2D.segment_intersects_segment(first, ray_end, p1, p2)
				if inter == null:
					continue
				var d: float = (inter as Vector2).distance_to(first)
				if d < best_dist:
					best_dist = d
					best_inter = inter
			if best_inter != Vector2.INF:
				result.insert(0, best_inter)
				if OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG"):
					print("[BridgeRamp] EXTEND way=%d chunk=%s first endpoint by %.2f m" \
							% [way_id, chunk_key, best_dist])
	# Try extending LAST endpoint (forward direction).
	var last_idx: int = result.size() - 1
	var last: Vector2 = result[last_idx]
	if not Geometry2D.is_point_in_polygon(last, polygon):
		var tangent: Vector2 = last - result[last_idx - 1]
		var t_len: float = tangent.length()
		if t_len > 0.001:
			tangent = tangent / t_len
			var ray_end: Vector2 = last + tangent * MAX_EXT
			var best_inter: Vector2 = Vector2.INF
			var best_dist: float = MAX_EXT + 1.0
			for j in range(polygon.size()):
				var p1: Vector2 = polygon[j]
				var p2: Vector2 = polygon[(j + 1) % polygon.size()]
				var inter = Geometry2D.segment_intersects_segment(last, ray_end, p1, p2)
				if inter == null:
					continue
				var d: float = (inter as Vector2).distance_to(last)
				if d < best_dist:
					best_dist = d
					best_inter = inter
			if best_inter != Vector2.INF:
				result.append(best_inter)
				if OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG"):
					print("[BridgeRamp] EXTEND way=%d chunk=%s last endpoint by %.2f m" \
							% [way_id, chunk_key, best_dist])
	return result


# Stage 2A.2 helper: clips the polyline so it does NOT enter any bridge
# polygon. Uses Geometry2D.clip_polyline_with_polygon, which returns
# disjoint outside-polygon segments. We pick the longest piece — the
# main approach road — and discard interior pieces (which would be on
# the deck and rendered by the bridge mesh anyway). Only called for
# ramp-owning ways.
func _clip_polyline_outside_bridge_polygons(points: PackedVector2Array, way_id: int,
		chunk_key: String) -> PackedVector2Array:
	if points.size() < 2 or _bridge_deck_polygons.is_empty():
		return points
	var debug := OS.has_environment("BRIDGE_RAMP_APPLY_DEBUG")
	if debug:
		var inside_first := false
		var inside_last := false
		for poly in _bridge_deck_polygons:
			if poly.size() >= 3 and Geometry2D.is_point_in_polygon(points[0], poly):
				inside_first = true
			if poly.size() >= 3 and Geometry2D.is_point_in_polygon(points[points.size() - 1], poly):
				inside_last = true
		print("[BridgeRamp] CLIP way=%d chunk=%s n=%d first_inside=%s last_inside=%s"
				% [way_id, chunk_key, points.size(), inside_first, inside_last])
	var current: PackedVector2Array = points
	for poly in _bridge_deck_polygons:
		if poly.size() < 3:
			continue
		var pieces: Array = Geometry2D.clip_polyline_with_polygon(current, poly)
		if debug:
			var sizes: Array = []
			for p in pieces:
				sizes.append((p as PackedVector2Array).size())
			print("[BridgeRamp]   pieces=%d sizes=%s" % [pieces.size(), str(sizes)])
		if pieces.is_empty():
			return PackedVector2Array()
		var best := PackedVector2Array()
		for p in pieces:
			var pp: PackedVector2Array = p
			if pp.size() > best.size():
				best = pp
		current = best
	return current


## Returns the two long-axis endpoints (abutments) of a deck polygon —
## those are the points where the bridge ties down to the surrounding
## terrain. Reuses the long-axis frame already computed in
## `_get_deck_ramp_axis`.
func _polygon_axis_ends(poly: PackedVector2Array) -> Array:
	var ramp := _get_deck_ramp_axis(poly)
	var origin: Vector2 = ramp.origin
	var axis: Vector2 = ramp.axis
	var axis_a: Vector2 = origin + axis * float(ramp.min_proj)
	var axis_b: Vector2 = origin + axis * float(ramp.max_proj)
	return [axis_a, axis_b]


## True iff the chunks holding both abutment points have their elevation
## grids loaded. We only need these two points (not every polygon vertex)
## to compute `ref_elev` correctly — bridge polygons can be longer than the
## streaming radius, so blocking on full coverage would never resolve.
func _are_axis_end_chunks_loaded(axis_a: Vector2, axis_b: Vector2) -> bool:
	if not enable_elevation:
		return true
	for p in [axis_a, axis_b]:
		var cx := int(floor(p.x / chunk_size))
		var cz := int(floor(p.y / chunk_size))
		var grid: Dictionary = _chunk_elevation_data.get("%d,%d" % [cx, cz], {})
		if grid.is_empty():
			return false
	return true


## Reference elevation for a deck polygon = max elevation of its two
## abutments. The deck sits at `ref_elev + BRIDGE_DECK_HEIGHT` everywhere
## (single constant Y for the whole bridge — not per-vertex terrain noise).
## Returns NAN if the abutment chunks haven't loaded yet; caller should
## defer building the deck.
func _compute_and_cache_deck_ref_elev(poly_idx: int) -> float:
	if poly_idx < 0 or poly_idx >= _bridge_deck_polygons.size():
		return NAN
	if _deck_polygon_ref_elev.has(poly_idx):
		return _deck_polygon_ref_elev[poly_idx]
	var poly: PackedVector2Array = _bridge_deck_polygons[poly_idx]
	if poly.size() < 3:
		return NAN
	var ends := _polygon_axis_ends(poly)
	var axis_a: Vector2 = ends[0]
	var axis_b: Vector2 = ends[1]
	if not _are_axis_end_chunks_loaded(axis_a, axis_b):
		return NAN
	var elev_a := _sample_elevation(axis_a.x, axis_a.y)
	var elev_b := _sample_elevation(axis_b.x, axis_b.y)
	var ref_elev: float = maxf(elev_a, elev_b)
	_deck_polygon_ref_elev[poly_idx] = ref_elev
	return ref_elev


## Y of the deck surface at a local-coords point.
##
## The deck sits at `ref_elev + BRIDGE_DECK_HEIGHT` over its flat middle
## section; near the long-axis endpoints (within `BRIDGE_RAMP_LENGTH`)
## the deck ramps down to whatever local terrain is there so it can tie
## into the road on the bank. Layer > 1 stacks `LAYER_HEIGHT` per layer.
func _deck_surface_y_at(point: Vector2, full_polygon: PackedVector2Array, layer: int, ref_elev: float) -> float:
	var max_h: float = BRIDGE_DECK_HEIGHT + maxf(0, layer - 1) * LAYER_HEIGHT
	var deck_top: float = ref_elev + max_h
	if full_polygon.size() < 3:
		return deck_top
	var ramp_info: Dictionary = _get_deck_ramp_axis(full_polygon)
	var proj: float = (point - ramp_info.origin).dot(ramp_info.axis)
	var min_end_dist: float = minf(proj - float(ramp_info.min_proj), float(ramp_info.max_proj) - proj)
	var t := clampf(min_end_dist / BRIDGE_RAMP_LENGTH, 0.0, 1.0)
	var y: float = deck_top
	if t < 1.0:
		# Inside the ramp zone (within BRIDGE_RAMP_LENGTH of an axis end).
		var local := _sample_elevation(point.x, point.y)
		if local == 0.0:
			local = ref_elev
		# Ramp base 10cm below terrain so it dips underground and
		# guarantees intersection with ground road — no gap possible.
		y = lerpf(local - 0.1, deck_top, _smooth_step(t))
	# Lateral exit ramps — where _link bridge roads depart the polygon,
	# the deck ramps down to meet the standalone bridge road's surface.
	for exit_data in _deck_lateral_exits:
		var to_pt: Vector2 = point - exit_data.pos
		var along: float = to_pt.dot(exit_data.inward_dir)
		# Allow negative along — polygon tip vertices are behind exit pos.
		# They should be at ground level (nt clamped to 0).
		if along < -30.0 or along > BRIDGE_RAMP_LENGTH:
			continue
		var perp_dir := Vector2(-exit_data.inward_dir.y, exit_data.inward_dir.x)
		var across: float = absf(to_pt.dot(perp_dir))
		var hw: float = float(exit_data.half_width)
		# Wide corridor covers the full polygon width at the exit so
		# sidewalks alongside the arm also ramp down correctly.
		var corridor_w: float = hw + 15.0
		if across > corridor_w:
			continue
		var nt: float = clampf(along / BRIDGE_RAMP_LENGTH, 0.0, 1.0)
		# Sample ground elevation at the exit point live (elevation data
		# may not have been available at detection time).
		var base_e: float = _sample_elevation(exit_data.pos.x, exit_data.pos.y)
		if base_e == 0.0:
			base_e = ref_elev
		var exit_y: float = lerpf(base_e - 0.1, deck_top, _smooth_step(nt))
		# Perpendicular fade: linear blend to deck_top outside arm road width
		if across > hw:
			var fade_t: float = (across - hw) / 15.0
			exit_y = lerpf(exit_y, deck_top, fade_t)
		y = minf(y, exit_y)
	return y


## Convenience wrapper for callers that only know a point (not which
## polygon owns it). Looks up the containing polygon and uses its cached
## ref_elev. For points outside any deck polygon (off-bridge), returns
## terrain ground so consumers don't crater into Y=0.
func _deck_surface_y_at_cached(point: Vector2) -> float:
	for i in _bridge_deck_polygons.size():
		var poly: PackedVector2Array = _bridge_deck_polygons[i]
		if poly.size() < 3:
			continue
		if not Geometry2D.is_point_in_polygon(point, poly):
			continue
		var ref_elev: float = _deck_polygon_ref_elev.get(i, NAN)
		if is_nan(ref_elev):
			# Polygon known but its ref_elev isn't computed yet — try once.
			ref_elev = _compute_and_cache_deck_ref_elev(i)
		if is_nan(ref_elev):
			continue
		return _deck_surface_y_at(point, poly, 1, ref_elev)
	return _sample_elevation(point.x, point.y)


# Computes the long-axis frame (origin + axis + min/max projection) for a
# deck polygon. Cached per polygon — 100m+ Oktyabrsky deck calls this many
# times during meshing and railing, recomputing every time was wasted work.
func _get_deck_ramp_axis(poly: PackedVector2Array) -> Dictionary:
	var poly_idx := -1
	for i in range(_bridge_deck_polygons.size()):
		if _bridge_deck_polygons[i] == poly:
			poly_idx = i
			break
	if poly_idx >= 0 and _deck_entry_edges_cache.has(poly_idx):
		return _deck_entry_edges_cache[poly_idx]
	var max_dist_sq := 0.0
	var end_a := poly[0]
	var end_b := poly[1] if poly.size() > 1 else poly[0]
	for i in range(poly.size()):
		for j in range(i + 1, poly.size()):
			var d: float = poly[i].distance_squared_to(poly[j])
			if d > max_dist_sq:
				max_dist_sq = d
				end_a = poly[i]
				end_b = poly[j]
	var axis: Vector2 = (end_b - end_a).normalized()
	var min_proj := INF
	var max_proj := -INF
	for p in poly:
		var proj: float = (p - end_a).dot(axis)
		min_proj = minf(min_proj, proj)
		max_proj = maxf(max_proj, proj)
	var result := {"origin": end_a, "axis": axis, "min_proj": min_proj, "max_proj": max_proj}
	if poly_idx >= 0:
		_deck_entry_edges_cache[poly_idx] = result
	return result


func _is_point_on_bridge_deck(point: Vector2) -> bool:
	for poly in _bridge_deck_polygons:
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(point, poly):
			return true
	return false


# Detects ramp junction points where an on-deck bridge way's endpoint
# sits near the polygon boundary. Creates apron mesh immediately if
# the deck is already built (roads typically load after deck).
func _detect_ramp_junction(nodes: Array, pts: PackedVector2Array, width: float) -> void:
	if nodes.size() < 2 or pts.size() < 2:
		return
	const SNAP := 5.0
	var first_local := _latlon_to_local(nodes[0].lat, nodes[0].lon)
	var last_local := _latlon_to_local(nodes[nodes.size() - 1].lat, nodes[nodes.size() - 1].lon)
	for pi in _bridge_deck_polygons.size():
		var poly: PackedVector2Array = _bridge_deck_polygons[pi]
		if poly.size() < 3:
			continue
		# Check first node
		var d0: float = _min_dist_to_polygon_outline(first_local, poly)
		if d0 < SNAP:
			var dir: Vector2 = (pts[0] - pts[1]).normalized()
			_register_ramp_junction(first_local, dir, width, pi)
		# Check last node
		var dN: float = _min_dist_to_polygon_outline(last_local, poly)
		if dN < SNAP:
			var last_idx: int = pts.size() - 1
			var dir: Vector2 = (pts[last_idx] - pts[last_idx - 1]).normalized()
			_register_ramp_junction(last_local, dir, width, pi)


func _register_ramp_junction(pos: Vector2, dir: Vector2, width: float, poly_idx: int) -> void:
	const SNAP := 5.0
	for j in _deck_ramp_junctions:
		if j.pos.distance_to(pos) < SNAP:
			return  # duplicate
	var junc := {"pos": pos, "dir": dir, "width": width, "poly_idx": poly_idx}
	_deck_ramp_junctions.append(junc)
	print("[RampJunction] #%d at (%.1f,%.1f) dir=(%.2f,%.2f) w=%.1f poly=%d" % [
		_deck_ramp_junctions.size() - 1, pos.x, pos.y, dir.x, dir.y, width, poly_idx])
	# If the deck mesh is already built, create the apron immediately.
	if _bridge_deck_nodes.has(poly_idx):
		var ref_elev: float = _deck_polygon_ref_elev.get(poly_idx, NAN)
		if not is_nan(ref_elev):
			_create_single_ramp_apron(junc, ref_elev)
	else:
		print("[RampJunction]   deck not built yet for poly %d — apron deferred" % poly_idx)


func _is_way_on_bridge_deck(nodes: Array) -> bool:
	if _bridge_deck_polygons.is_empty() or nodes.size() < 2:
		return false
	var mid_idx: int = nodes.size() / 2
	var mid_local := _latlon_to_local(nodes[mid_idx].lat, nodes[mid_idx].lon)
	return _is_point_on_bridge_deck(mid_local)


# Direction of the nearest OTHER bridge way at the given local point — used
# to average perpendiculars at shared bridge endpoints so adjacent way
# meshes meet seamlessly.
func _find_neighbor_bridge_tangent(point: Vector2, self_way_id: int) -> Vector2:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	var best_dist := INF
	var best_dir := Vector2.ZERO
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, "")
			for seg in segs:
				if not seg.get("bridge", false):
					continue
				if seg.get("way_id", 0) == self_way_id:
					continue
				if seg.width < 4.0:
					continue
				var d1: float = point.distance_to(seg.p1)
				var d2: float = point.distance_to(seg.p2)
				var min_d: float = minf(d1, d2)
				if min_d < 2.0 and min_d < best_dist:
					best_dist = min_d
					if d1 < d2:
						best_dir = (seg.p2 - seg.p1).normalized()
					else:
						best_dir = (seg.p1 - seg.p2).normalized()
	return best_dir


# Half the distance to the nearest other bridge centreline in `direction`,
# so two roads each shrinking by that amount meet flush. Returns 0 when
# there is no other bridge ahead.
func _find_midpoint_to_other_bridge_road(origin: Vector2, direction: Vector2, self_way_id: int) -> float:
	var cell_x := int(floor(origin.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(origin.y / ROAD_CELL_SIZE))
	var best_dist := INF
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, "")
			for seg in segs:
				if not seg.get("bridge", false):
					continue
				if seg.get("way_id", 0) == self_way_id:
					continue
				if seg.width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(origin, seg.p1, seg.p2)
				var to_other := closest - origin
				if to_other.dot(direction) <= 0:
					continue
				var dist := origin.distance_to(closest)
				if dist < best_dist:
					best_dist = dist
	if best_dist < INF:
		return best_dist * 0.5
	return 0.0


# `point` lies inside another bridge way's road corridor. Used by barriers
# to open gaps where ramps merge into a main bridge.
func _point_in_other_bridge_corridor(point: Vector2, ck: String = "", self_way_id: int = 0) -> bool:
	const MARGIN := -0.5
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
				if not seg.get("bridge", false):
					continue
				if self_way_id != 0 and seg.get("way_id", 0) == self_way_id:
					continue
				var s_width: float = seg.width
				if s_width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				if point.distance_to(closest) < s_width / 2.0 + MARGIN:
					return true
	return false


# Height of a bridge way at accumulated distance along its centreline.
# `ramp_from_*` sides ramp up over the given length; sides == 0 stay at full
# deck height (used at shared bridge endpoints). Shared by road mesh,
# pillars, and barriers so they stay coplanar.
func _bridge_height_at(accumulated: float, ramp_from_start: float, ramp_from_end: float, total_length: float, height_offset: float) -> float:
	var h := BRIDGE_DECK_HEIGHT
	if ramp_from_start > 0.0 and accumulated < ramp_from_start:
		h = _smooth_step(accumulated / ramp_from_start) * BRIDGE_DECK_HEIGHT
	elif ramp_from_end > 0.0 and accumulated > total_length - ramp_from_end:
		var rem: float = total_length - accumulated
		h = _smooth_step(rem / ramp_from_end) * BRIDGE_DECK_HEIGHT
	return height_offset + h


# Averages perpendiculars at shared bridge endpoints so adjacent way meshes
# meet seamlessly. Pass the smoothed local-coord polyline + node OSM list.
func _fix_shared_endpoint_perps(pts: PackedVector2Array, perps: Array[Vector2], nodes: Array, self_way_id: int) -> void:
	if pts.size() < 2 or nodes.size() < 2:
		return
	var first_node: Dictionary = nodes[0]
	if _bridge_endpoint_is_shared(first_node.lat, first_node.lon):
		var neighbor_dir := _find_neighbor_bridge_tangent(pts[0], self_way_id)
		if neighbor_dir != Vector2.ZERO:
			var my_dir: Vector2 = (pts[1] - pts[0]).normalized()
			var avg_dir: Vector2 = (my_dir + neighbor_dir).normalized()
			if avg_dir.length_squared() > 0.01:
				perps[0] = Vector2(-avg_dir.y, avg_dir.x)
	var last_node: Dictionary = nodes[nodes.size() - 1]
	if _bridge_endpoint_is_shared(last_node.lat, last_node.lon):
		var last_idx: int = pts.size() - 1
		var neighbor_dir2 := _find_neighbor_bridge_tangent(pts[last_idx], self_way_id)
		if neighbor_dir2 != Vector2.ZERO:
			var my_dir2: Vector2 = (pts[last_idx] - pts[last_idx - 1]).normalized()
			var avg_dir2: Vector2 = (my_dir2 + neighbor_dir2).normalized()
			if avg_dir2.length_squared() > 0.01:
				perps[last_idx] = Vector2(-avg_dir2.y, avg_dir2.x)


# Recursively splits triangles whose edges exceed MAX_EDGE so the ramp
# transitions stay smooth. Returns reshaped {vertices, indices, uvs, normals}.
# `ref_elev` is the polygon's reference elevation — same constant the deck
# top sits on (`ref_elev + BRIDGE_DECK_HEIGHT`). The ramp test uses it.
func _subdivide_ramp_tris(verts: PackedVector3Array, idxs: PackedInt32Array,
		full_polygon: PackedVector2Array, layer: int, uv_scale: float, ref_elev: float) -> Dictionary:
	const MAX_EDGE := 3.0
	# 10 iterations handles 700m polygon edges (adaptive: only ramp-zone
	# triangles split, +3 tris/iter → ~30 extra tris total).
	const MAX_ITER := 10
	var v := Array()
	for vi in range(verts.size()):
		v.append(verts[vi])
	var tris := Array()
	for ii in range(idxs.size()):
		tris.append(idxs[ii])
	# A vertex sits in the ramp zone if its Y is below the deck top.
	var max_h: float = BRIDGE_DECK_HEIGHT + maxf(0, layer - 1) * LAYER_HEIGHT
	var deck_top: float = ref_elev + max_h
	for _iter in range(MAX_ITER):
		var new_tris := PackedInt32Array()
		var changed := false
		var mid_cache := {}
		for ti in range(0, tris.size(), 3):
			var i0: int = tris[ti]
			var i1: int = tris[ti + 1]
			var i2: int = tris[ti + 2]
			var v0: Vector3 = v[i0]
			var v1: Vector3 = v[i1]
			var v2: Vector3 = v[i2]
			var in_ramp: bool = v0.y < deck_top - 0.01 or v1.y < deck_top - 0.01 or v2.y < deck_top - 0.01
			# Also subdivide triangles near lateral exit points — these
			# start at deck_top but the midpoints will get ramp Y from
			# _deck_surface_y_at, seeding further subdivision.
			if not in_ramp and not _deck_lateral_exits.is_empty():
				var r_sq: float = (BRIDGE_RAMP_LENGTH + MAX_EDGE * 2) * (BRIDGE_RAMP_LENGTH + MAX_EDGE * 2)
				for exit_data in _deck_lateral_exits:
					var ep: Vector2 = exit_data.pos
					for vi3 in [v0, v1, v2]:
						if Vector2(vi3.x, vi3.z).distance_squared_to(ep) < r_sq:
							in_ramp = true
							break
					if in_ramp:
						break
			if not in_ramp:
				new_tris.append(i0); new_tris.append(i1); new_tris.append(i2)
				continue
			var d01: float = v0.distance_to(v1)
			var d12: float = v1.distance_to(v2)
			var d20: float = v2.distance_to(v0)
			if d01 <= MAX_EDGE and d12 <= MAX_EDGE and d20 <= MAX_EDGE:
				new_tris.append(i0); new_tris.append(i1); new_tris.append(i2)
				continue
			changed = true
			var m01: int = _get_or_create_midpoint(v, mid_cache, i0, i1, full_polygon, layer, ref_elev)
			var m12: int = _get_or_create_midpoint(v, mid_cache, i1, i2, full_polygon, layer, ref_elev)
			var m20: int = _get_or_create_midpoint(v, mid_cache, i2, i0, full_polygon, layer, ref_elev)
			new_tris.append(i0); new_tris.append(m01); new_tris.append(m20)
			new_tris.append(m01); new_tris.append(i1); new_tris.append(m12)
			new_tris.append(m20); new_tris.append(m12); new_tris.append(i2)
			new_tris.append(m01); new_tris.append(m12); new_tris.append(m20)
		tris = Array(new_tris)
		if not changed:
			break
	var out_v := PackedVector3Array()
	var out_uv := PackedVector2Array()
	var out_n := PackedVector3Array()
	for vi2 in range(v.size()):
		out_v.append(v[vi2])
		out_uv.append(Vector2(v[vi2].x * uv_scale, v[vi2].z * uv_scale))
		out_n.append(Vector3.UP)
	return {"vertices": out_v, "indices": PackedInt32Array(tris), "uvs": out_uv, "normals": out_n}


func _get_or_create_midpoint(v: Array, cache: Dictionary, i_a: int, i_b: int,
		full_polygon: PackedVector2Array, layer: int, ref_elev: float) -> int:
	var key: int = mini(i_a, i_b) * 100000 + maxi(i_a, i_b)
	if cache.has(key):
		return cache[key]
	var va: Vector3 = v[i_a]
	var vb: Vector3 = v[i_b]
	var mid_2d := Vector2((va.x + vb.x) * 0.5, (va.z + vb.z) * 0.5)
	var mid_y: float = _deck_surface_y_at(mid_2d, full_polygon, layer, ref_elev)
	var idx: int = v.size()
	v.append(Vector3(mid_2d.x, mid_y, mid_2d.y))
	cache[key] = idx
	return idx


# Builds the flat asphalt deck mesh + railing for one man_made=bridge
# polygon. Caller MUST have ensured the polygon's ref_elev is cached
# (axis-end chunks loaded) — the queue handler in
# `_process_terrain_objects_queue` defers items until that's true.
func _create_bridge_deck_mesh(points: PackedVector2Array, tags: Dictionary, parent: Node3D, full_polygon: PackedVector2Array = PackedVector2Array()) -> void:
	if points.size() < 3:
		return

	var indices := Geometry2D.triangulate_polygon(points)
	if indices.is_empty():
		return

	var poly_idx: int = _bridge_deck_polygons.find(full_polygon)
	var ref_elev: float = _compute_and_cache_deck_ref_elev(poly_idx)
	if is_nan(ref_elev):
		# Caller should never let us reach here; bail rather than build
		# at Y=0 (= 120 m underground here).
		return

	var layer: int = int(str(tags.get("layer", "1"))) if str(tags.get("layer", "1")).is_valid_int() else 1

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var tri_indices := PackedInt32Array()
	var uv_scale := 0.1  # 10m per UV repeat

	var use_ramp: bool = full_polygon.size() >= 3
	for i in points.size():
		var p := points[i]
		var y_here: float = _deck_surface_y_at(p, full_polygon, layer, ref_elev)
		vertices.append(Vector3(p.x, y_here, p.y))
		uvs.append(Vector2(p.x * uv_scale, p.y * uv_scale))
		normals.append(Vector3.UP)
	tri_indices = indices
	if use_ramp:
		var sub_result: Dictionary = _subdivide_ramp_tris(vertices, tri_indices, full_polygon, layer, uv_scale, ref_elev)
		vertices = sub_result.vertices
		tri_indices = sub_result.indices
		uvs = sub_result.uvs
		normals = sub_result.normals

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = tri_indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.7, 0.7, 0.7)
	material.roughness = 0.9
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _cached_road_albedo:
		material.albedo_texture = _cached_road_albedo
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "BridgeDeck"
	mesh_inst.mesh = arr_mesh
	mesh_inst.material_override = material
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.name = "BridgeDeckCollision"
	body.collision_layer = 1
	body.add_to_group("Road")
	var shape := CollisionShape3D.new()
	var coll_shape := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array()
	for i in range(0, tri_indices.size(), 3):
		faces.append(vertices[tri_indices[i]])
		faces.append(vertices[tri_indices[i + 1]])
		faces.append(vertices[tri_indices[i + 2]])
	coll_shape.set_faces(faces)
	shape.shape = coll_shape
	body.add_child(shape)
	parent.add_child(body)

	var railing_nodes: Array = _create_deck_railing(points, ref_elev, parent)
	var all_nodes: Array = [mesh_inst, body]
	all_nodes.append_array(railing_nodes)
	_bridge_deck_nodes[poly_idx] = all_nodes

	# Create aprons for any ramp junctions already detected before deck build.
	# Most junctions arrive after deck (roads load later), but handle both orders.
	for junc in _deck_ramp_junctions:
		if junc.get("poly_idx", -1) == poly_idx:
			_create_single_ramp_apron(junc, ref_elev)


# Renders thin white lane-divider strips on top of the deck for an on-deck
# vehicle road. Edges already come from the curb / centre-divider geometry,
# so this only paints the dashed dividers between lanes.
func _create_on_deck_lane_markings(pts: PackedVector2Array, road_width: float, tags: Dictionary, parent: Node3D) -> void:
	if pts.size() < 2:
		return
	# Subdivide at 5 m grid crossings so per-vertex Y from
	# _deck_surface_y_at_cached tracks the smoothstep ramp curve
	# (same idea as _subdivide_for_elevation on terrain roads).
	pts = _subdivide_for_elevation(pts, 5.0)

	var lanes_str: String = str(tags.get("lanes", "2"))
	var lane_count: int = int(lanes_str) if lanes_str.is_valid_int() else 2
	lane_count = clampi(lane_count, 1, 6)
	var half_w: float = road_width * 0.5
	var perps: Array[Vector2] = _compute_averaged_perpendiculars(pts)

	const LINE_WIDTH := 0.15
	const DASH_LENGTH := 3.0
	const DASH_GAP := 3.0
	const MARKING_Y_OFFSET := 0.003

	var marking_mat := StandardMaterial3D.new()
	marking_mat.albedo_color = Color(1.0, 1.0, 1.0)
	marking_mat.roughness = 0.6
	marking_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	marking_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(marking_mat)

	var acc_lengths := PackedFloat64Array()
	acc_lengths.resize(pts.size())
	acc_lengths[0] = 0.0
	for i in range(1, pts.size()):
		acc_lengths[i] = acc_lengths[i - 1] + pts[i - 1].distance_to(pts[i])

	var add_line_segment := func(p1: Vector2, p2: Vector2, perp1: Vector2, perp2: Vector2,
			offset: float, lw: float) -> void:
		var o1 := p1 + perp1 * offset
		var o2 := p2 + perp2 * offset
		var y1: float = _deck_surface_y_at_cached(p1) + MARKING_Y_OFFSET
		var y2: float = _deck_surface_y_at_cached(p2) + MARKING_Y_OFFSET
		var hw := lw * 0.5
		var v1 := Vector3(o1.x - perp1.x * hw, y1, o1.y - perp1.y * hw)
		var v2 := Vector3(o1.x + perp1.x * hw, y1, o1.y + perp1.y * hw)
		var v3 := Vector3(o2.x + perp2.x * hw, y2, o2.y + perp2.y * hw)
		var v4 := Vector3(o2.x - perp2.x * hw, y2, o2.y - perp2.y * hw)
		st.set_normal(Vector3.UP)
		st.add_vertex(v1); st.set_normal(Vector3.UP)
		st.add_vertex(v2); st.set_normal(Vector3.UP)
		st.add_vertex(v3)
		st.set_normal(Vector3.UP)
		st.add_vertex(v1); st.set_normal(Vector3.UP)
		st.add_vertex(v3); st.set_normal(Vector3.UP)
		st.add_vertex(v4)

	if lane_count > 1:
		var lane_w: float = road_width / float(lane_count)
		for lane_i in range(1, lane_count):
			var offset: float = -half_w + lane_w * float(lane_i)
			for seg_i in range(pts.size() - 1):
				var sp1 := pts[seg_i]
				var sp2 := pts[seg_i + 1]
				var seg_len := sp1.distance_to(sp2)
				var seg_acc := acc_lengths[seg_i]
				var cycle := DASH_LENGTH + DASH_GAP
				var pos := 0.0
				while pos < seg_len:
					var abs_pos := seg_acc + pos
					var in_cycle := fmod(abs_pos, cycle)
					if in_cycle < DASH_LENGTH:
						var dash_remaining := DASH_LENGTH - in_cycle
						var draw_len := minf(dash_remaining, seg_len - pos)
						var t1 := pos / seg_len
						var t2 := (pos + draw_len) / seg_len
						var dp1 := sp1.lerp(sp2, t1)
						var dp2 := sp1.lerp(sp2, t2)
						var dperp1 := perps[seg_i].lerp(perps[seg_i + 1], t1)
						var dperp2 := perps[seg_i].lerp(perps[seg_i + 1], t2)
						add_line_segment.call(dp1, dp2, dperp1, dperp2, offset, LINE_WIDTH)
						pos += draw_len
					else:
						var gap_remaining := cycle - in_cycle
						pos += gap_remaining

	var committed := st.commit()
	if committed and committed.get_surface_count() > 0:
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "BridgeLaneMarkings"
		mesh_inst.mesh = committed
		mesh_inst.material_override = marking_mat
		mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mesh_inst)


# Renders a footway/path that runs ON a man_made=bridge deck as a slightly
# raised sidewalk strip with an inner curb butting up against the carriage-
# way. Edges expand TOWARD the deck edge (so two parallel pieces — ПЧ and
# тротуар — meet flush). Restored from 7102d8c. Without this, footways
# inside the deck polygon either disappeared or rendered as separate sad
# little bridges.
func _create_on_deck_footway(smoothed_points: PackedVector2Array, width: float, tags: Dictionary, parent: Node3D, chunk_key: String, full_nodes: Array = []) -> void:
	var pts: PackedVector2Array = _remove_polyline_zigzag(smoothed_points)
	if pts.size() < 2:
		return
	# Subdivide at 5 m grid crossings so the footway mesh follows the
	# deck ramp smoothstep curve instead of linearly interpolating Y
	# between sparse OSM nodes.
	pts = _subdivide_for_elevation(pts, 5.0)
	var half_w: float = width * 0.5
	var perps: Array[Vector2] = _compute_averaged_perpendiculars(pts)
	var hw_lefts := PackedFloat64Array()
	var hw_rights := PackedFloat64Array()
	hw_lefts.resize(pts.size())
	hw_rights.resize(pts.size())
	var max_expand: float = half_w + 3.0

	# Determine which side is "toward deck edge". Sparse ways clipped to a
	# chunk can leave only 2 points whose midpoint lands at a polygon corner,
	# making the local probe fail (both sides exit the deck within 0.5m).
	# Use the FULL way's middle node when available so the probe sees a
	# representative interior point. Fall back to the chunked midpoint.
	var mid_p: Vector2
	var mid_perp: Vector2
	if full_nodes.size() >= 2:
		var fmid_idx: int = full_nodes.size() / 2
		mid_p = _latlon_to_local(full_nodes[fmid_idx].lat, full_nodes[fmid_idx].lon)
		var prev_n: Dictionary = full_nodes[maxi(0, fmid_idx - 1)]
		var next_n: Dictionary = full_nodes[mini(full_nodes.size() - 1, fmid_idx + 1)]
		var prev_p: Vector2 = _latlon_to_local(prev_n.lat, prev_n.lon)
		var next_p: Vector2 = _latlon_to_local(next_n.lat, next_n.lon)
		var dir: Vector2 = (next_p - prev_p)
		if dir.length_squared() < 0.01:
			dir = Vector2(1, 0)
		dir = dir.normalized()
		mid_perp = Vector2(-dir.y, dir.x)
	else:
		var mid_k: int = clampi(pts.size() / 2, 0, pts.size() - 1)
		mid_p = pts[mid_k]
		mid_perp = perps[mid_k]
	var left_deck_dist: float = 0.0
	var right_deck_dist: float = 0.0
	for ds in range(1, 30):
		var d: float = float(ds) * 0.5
		if left_deck_dist == 0.0 and not _is_point_on_bridge_deck(mid_p - mid_perp * d):
			left_deck_dist = d
		if right_deck_dist == 0.0 and not _is_point_on_bridge_deck(mid_p + mid_perp * d):
			right_deck_dist = d
		if left_deck_dist > 0 and right_deck_dist > 0:
			break
	var expand_left: bool = left_deck_dist > 0 and (right_deck_dist == 0 or left_deck_dist < right_deck_dist)
	var expand_right: bool = right_deck_dist > 0 and (left_deck_dist == 0 or right_deck_dist < left_deck_dist)

	for k in range(pts.size()):
		var p: Vector2 = pts[k]
		var perp: Vector2 = perps[k]
		var hwl: float = half_w
		var hwr: float = half_w
		if expand_left:
			for dist_step in range(1, 16):
				var dist: float = half_w + float(dist_step) * 0.2
				if dist > max_expand:
					break
				if not _is_point_on_bridge_deck(p - perp * dist):
					hwl = dist + 0.3
					break
				hwl = dist
		else:
			# Non-expanding side: clamp so the footway doesn't ride onto the
			# adjacent vehicle road.
			if _is_point_on_vehicle_road(p - perp * hwl, 0.0, chunk_key):
				for clamp_s in range(1, int(hwl / 0.1) + 1):
					var td: float = hwl - float(clamp_s) * 0.1
					if td < 0.2:
						hwl = 0.2
						break
					if not _is_point_on_vehicle_road(p - perp * td, 0.0, chunk_key):
						hwl = td
						break
		if expand_right:
			for dist_step in range(1, 16):
				var dist: float = half_w + float(dist_step) * 0.2
				if dist > max_expand:
					break
				if not _is_point_on_bridge_deck(p + perp * dist):
					hwr = dist + 0.3
					break
				hwr = dist
		else:
			if _is_point_on_vehicle_road(p + perp * hwr, 0.0, chunk_key):
				for clamp_s in range(1, int(hwr / 0.1) + 1):
					var td: float = hwr - float(clamp_s) * 0.1
					if td < 0.2:
						hwr = 0.2
						break
					if not _is_point_on_vehicle_road(p + perp * td, 0.0, chunk_key):
						hwr = td
						break
		hw_lefts[k] = hwl
		hw_rights[k] = hwr

	# Smooth (3-point moving average) to remove sub-1m notches between
	# consecutive vertices.
	if pts.size() >= 3:
		var sl := hw_lefts.duplicate()
		var sr := hw_rights.duplicate()
		for k in range(1, pts.size() - 1):
			hw_lefts[k] = (sl[k - 1] + sl[k] + sl[k + 1]) / 3.0
			hw_rights[k] = (sr[k - 1] + sr[k] + sr[k + 1]) / 3.0

	# Build sidewalk surface — sits 23 cm above the deck.
	var verts := PackedVector3Array()
	var uv_arr := PackedVector2Array()
	var norm_arr := PackedVector3Array()
	var idx_arr := PackedInt32Array()
	var acc := 0.0
	for k in range(pts.size()):
		var p: Vector2 = pts[k]
		var perp: Vector2 = perps[k]
		var deck_y_here: float = _deck_surface_y_at_cached(p) + 0.23
		verts.append(Vector3(p.x - perp.x * hw_lefts[k], deck_y_here, p.y - perp.y * hw_lefts[k]))
		verts.append(Vector3(p.x + perp.x * hw_rights[k], deck_y_here, p.y + perp.y * hw_rights[k]))
		uv_arr.append(Vector2(0.0, acc * 0.1))
		uv_arr.append(Vector2(1.0, acc * 0.1))
		norm_arr.append(Vector3.UP)
		norm_arr.append(Vector3.UP)
		if k < pts.size() - 1:
			acc += pts[k].distance_to(pts[k + 1])
	for k in range(pts.size() - 1):
		var bi: int = k * 2
		idx_arr.append(bi); idx_arr.append(bi + 2); idx_arr.append(bi + 1)
		idx_arr.append(bi + 1); idx_arr.append(bi + 2); idx_arr.append(bi + 3)

	if verts.size() >= 4:
		if not _road_batch_data.has(chunk_key):
			_road_batch_data[chunk_key] = {}
		var fw_tex := "path"
		if not _road_batch_data[chunk_key].has(fw_tex):
			_road_batch_data[chunk_key][fw_tex] = {
				"vertices": PackedVector3Array(),
				"uvs": PackedVector2Array(),
				"normals": PackedVector3Array(),
				"indices": PackedInt32Array(),
				"parent": parent,
			}
		var batch: Dictionary = _road_batch_data[chunk_key][fw_tex]
		var vertex_offset: int = batch["vertices"].size()
		batch["vertices"].append_array(verts)
		batch["uvs"].append_array(uv_arr)
		batch["normals"].append_array(norm_arr)
		if vertex_offset > 0:
			var offset_indices := PackedInt32Array()
			offset_indices.resize(idx_arr.size())
			for oi in range(idx_arr.size()):
				offset_indices[oi] = idx_arr[oi] + vertex_offset
			batch["indices"].append_array(offset_indices)
		else:
			batch["indices"].append_array(idx_arr)

	# Curb: 22 cm tall strip on both edges of the sidewalk so it reads as a
	# raised pavement against the carriageway.
	if pts.size() >= 2:
		var curb_h: float = 0.22
		var curb_st := SurfaceTool.new()
		curb_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var curb_mat := StandardMaterial3D.new()
		curb_mat.albedo_color = Color(0.65, 0.63, 0.60)
		curb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		curb_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		curb_st.set_material(curb_mat)
		for side in [-1, 1]:
			for k in range(pts.size() - 1):
				var cp1: Vector2 = pts[k]
				var cp2: Vector2 = pts[k + 1]
				var cdir: Vector2 = (cp2 - cp1).normalized()
				var cperp: Vector2 = Vector2(-cdir.y, cdir.x)
				var chw1: float = hw_lefts[k] if side == -1 else hw_rights[k]
				var chw2: float = hw_lefts[k + 1] if side == -1 else hw_rights[k + 1]
				var e1: Vector2 = cp1 + cperp * chw1 * side
				var e2: Vector2 = cp2 + cperp * chw2 * side
				var dy1: float = _deck_surface_y_at_cached(cp1) + 0.01
				var dy2: float = _deck_surface_y_at_cached(cp2) + 0.01
				var cv1 := Vector3(e1.x, dy1, e1.y)
				var cv2 := Vector3(e2.x, dy2, e2.y)
				var cv3 := Vector3(e2.x, dy2 + curb_h, e2.y)
				var cv4 := Vector3(e1.x, dy1 + curb_h, e1.y)
				var face_n := (cv2 - cv1).cross(cv4 - cv1).normalized()
				var edge_center := (cv1 + cv2) * 0.5
				var center_3d := Vector3(cp1.x, edge_center.y, cp1.y)
				if face_n.dot(edge_center - center_3d) < 0:
					face_n = -face_n
				curb_st.set_normal(face_n); curb_st.add_vertex(cv1)
				curb_st.set_normal(face_n); curb_st.add_vertex(cv2)
				curb_st.set_normal(face_n); curb_st.add_vertex(cv3)
				curb_st.set_normal(face_n); curb_st.add_vertex(cv1)
				curb_st.set_normal(face_n); curb_st.add_vertex(cv3)
				curb_st.set_normal(face_n); curb_st.add_vertex(cv4)
		var curb_committed := curb_st.commit()
		if curb_committed and curb_committed.get_surface_count() > 0:
			var curb_mi := MeshInstance3D.new()
			curb_mi.name = "BridgeSidewalkCurb"
			curb_mi.mesh = curb_committed
			curb_mi.material_override = curb_mat
			curb_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(curb_mi)


# Creates a single asphalt apron mesh at one ramp junction. Called from
# _register_ramp_junction when the deck is already built, or from
# _create_bridge_deck_mesh for any junctions detected before deck build.
func _create_single_ramp_apron(junc: Dictionary, ref_elev: float) -> void:
	const APRON_LEN := 5.0
	var center: Vector2 = junc.pos
	var outward: Vector2 = junc.dir
	var hw: float = float(junc.width) * 0.5 + 1.0
	var ap_perp := Vector2(-outward.y, outward.x)

	# Inner edge at polygon boundary, outer edge APRON_LEN outside (over the gap)
	var inner_l: Vector2 = center - ap_perp * hw
	var inner_r: Vector2 = center + ap_perp * hw
	var outer_l: Vector2 = center - ap_perp * hw + outward * APRON_LEN
	var outer_r: Vector2 = center + ap_perp * hw + outward * APRON_LEN

	# 5cm above terrain — enough to clear grass without visible floating
	const Y_OFF := 0.05
	var y_il: float = _sample_elevation(inner_l.x, inner_l.y) + Y_OFF
	var y_ir: float = _sample_elevation(inner_r.x, inner_r.y) + Y_OFF
	var y_ol: float = _sample_elevation(outer_l.x, outer_l.y) + Y_OFF
	var y_or: float = _sample_elevation(outer_r.x, outer_r.y) + Y_OFF

	var verts := PackedVector3Array([
		Vector3(inner_l.x, y_il, inner_l.y),
		Vector3(inner_r.x, y_ir, inner_r.y),
		Vector3(outer_l.x, y_ol, outer_l.y),
		Vector3(outer_r.x, y_or, outer_r.y),
	])
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0),
		Vector2(0, APRON_LEN * 0.1), Vector2(1, APRON_LEN * 0.1),
	])
	var norms := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var idxs := PackedInt32Array([0, 2, 1, 1, 2, 3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idxs

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# DEBUG: bright red so we can see apron positions
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 0.0)
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.name = "RampApron"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Parent to self (same as deck mesh) so it survives chunk unloading
	add_child(mi)

	# Track with deck nodes for cleanup
	var poly_idx: int = junc.get("poly_idx", 0)
	if _bridge_deck_nodes.has(poly_idx):
		_bridge_deck_nodes[poly_idx].append(mi)

	# Register terrain corridor to cut grass under the apron
	var corridor := PackedVector2Array([outer_l, outer_r, inner_r, inner_l])
	var cx := int(floor(center.x / chunk_size))
	var cz := int(floor(center.y / chunk_size))
	var ck := "%d,%d" % [cx, cz]
	if not _chunk_terrain_roads.has(ck):
		_chunk_terrain_roads[ck] = []
	_chunk_terrain_roads[ck].append(corridor)

	print("[RampApron] created at (%.1f,%.1f) outward=(%.2f,%.2f) Y=%.2f..%.2f" % [
		center.x, center.y, outward.x, outward.y,
		_sample_elevation(center.x, center.y) + Y_OFF,
		_sample_elevation(center.x + outward.x * APRON_LEN, center.y + outward.y * APRON_LEN) + Y_OFF])


# 110 cm vertical-bar railing along the deck perimeter. Skips edges that
# coincide with a vehicle road entry (so cars can drive on/off the deck) and
# edges that lie on a chunk boundary (the neighbouring chunk paints its half).
# `ref_elev` is the polygon's reference elevation — the railing Y is queried
# via the same `_deck_surface_y_at(p, poly, 1, ref_elev)` so it matches the
# deck mesh exactly, no per-vertex elevation noise.
func _create_deck_railing(poly: PackedVector2Array, ref_elev: float, parent: Node3D) -> Array:
	var created: Array = []
	if poly.size() < 3:
		return created

	const RAILING_HEIGHT := 1.1
	const BAR_SPACING := 0.12
	const BAR_RADIUS := 0.015
	const RAIL_COLOR := Color(0.3, 0.3, 0.33)
	const TOP_RAIL_THICKNESS := 0.04

	var ck := _get_chunk_key_from_node(parent)
	var has_chunk_rect := false
	var chunk_rect := Rect2()
	if not ck.is_empty():
		chunk_rect = _get_chunk_rect_from_key(ck)
		has_chunk_rect = true
	var edge_tol := 0.5

	var material := StandardMaterial3D.new()
	material.albedo_color = RAIL_COLOR
	material.metallic = 0.6
	material.roughness = 0.5
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)

	var pn := poly.size()
	for i in range(pn):
		var p1 := poly[i]
		var p2 := poly[(i + 1) % pn]

		if has_chunk_rect:
			var rx := chunk_rect.position.x
			var rz := chunk_rect.position.y
			var rx2 := rx + chunk_rect.size.x
			var rz2 := rz + chunk_rect.size.y
			if absf(p1.x - rx) < edge_tol and absf(p2.x - rx) < edge_tol:
				continue
			if absf(p1.x - rx2) < edge_tol and absf(p2.x - rx2) < edge_tol:
				continue
			if absf(p1.y - rz) < edge_tol and absf(p2.y - rz) < edge_tol:
				continue
			if absf(p1.y - rz2) < edge_tol and absf(p2.y - rz2) < edge_tol:
				continue

		var seg_len := p1.distance_to(p2)
		if seg_len < 0.3:
			continue

		var edge_mid := (p1 + p2) * 0.5
		if _is_point_on_vehicle_road(edge_mid, 0.0, ""):
			continue

		# Skip edges near lateral exits (arm ramp openings)
		var near_exit := false
		for exit_data in _deck_lateral_exits:
			var ep: Vector2 = exit_data.pos
			var skip_r: float = float(exit_data.half_width) + 15.0
			if p1.distance_to(ep) < skip_r or p2.distance_to(ep) < skip_r or edge_mid.distance_to(ep) < skip_r:
				near_exit = true
				break
		if near_exit:
			continue

		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x)
		var perp3 := Vector3(outward.x, 0, outward.y)
		var along3 := Vector3(dir.x, 0, dir.y)

		var num_bars := int(seg_len / BAR_SPACING)
		for bi in range(num_bars + 1):
			var t: float = float(bi) / float(maxi(num_bars, 1))
			var bp := p1.lerp(p2, t)
			var cx := bp.x + outward.x * 0.05
			var cz := bp.y + outward.y * 0.05
			var base := Vector3(cx, _deck_surface_y_at(bp, poly, 1, ref_elev), cz)
			var hw := BAR_RADIUS
			for face in range(4):
				var n: Vector3
				var off1: Vector3
				var off2: Vector3
				match face:
					0: n = perp3; off1 = along3 * hw; off2 = -along3 * hw
					1: n = -perp3; off1 = -along3 * hw; off2 = along3 * hw
					2: n = along3; off1 = perp3 * hw; off2 = -perp3 * hw
					3: n = -along3; off1 = -perp3 * hw; off2 = perp3 * hw
				var v1 := base + off1 + n * hw
				var v2 := base + off2 + n * hw
				var v3 := v2 + Vector3(0, RAILING_HEIGHT, 0)
				var v4 := v1 + Vector3(0, RAILING_HEIGHT, 0)
				st.set_normal(n)
				st.add_vertex(v1)
				st.set_normal(n)
				st.add_vertex(v2)
				st.set_normal(n)
				st.add_vertex(v3)
				st.set_normal(n)
				st.add_vertex(v1)
				st.set_normal(n)
				st.add_vertex(v3)
				st.set_normal(n)
				st.add_vertex(v4)

		var rail_y1: float = _deck_surface_y_at(p1, poly, 1, ref_elev) + RAILING_HEIGHT
		var rail_y2: float = _deck_surface_y_at(p2, poly, 1, ref_elev) + RAILING_HEIGHT
		var tp1 := Vector3(p1.x + outward.x * 0.05, rail_y1, p1.y + outward.y * 0.05)
		var tp2 := Vector3(p2.x + outward.x * 0.05, rail_y2, p2.y + outward.y * 0.05)
		var th := TOP_RAIL_THICKNESS
		st.set_normal(Vector3.UP)
		st.add_vertex(tp1 + perp3 * th)
		st.set_normal(Vector3.UP)
		st.add_vertex(tp2 + perp3 * th)
		st.set_normal(Vector3.UP)
		st.add_vertex(tp2 - perp3 * th)
		st.set_normal(Vector3.UP)
		st.add_vertex(tp1 + perp3 * th)
		st.set_normal(Vector3.UP)
		st.add_vertex(tp2 - perp3 * th)
		st.set_normal(Vector3.UP)
		st.add_vertex(tp1 - perp3 * th)
		st.set_normal(perp3)
		st.add_vertex(tp1 + perp3 * th)
		st.set_normal(perp3)
		st.add_vertex(tp2 + perp3 * th)
		st.set_normal(perp3)
		st.add_vertex(tp2 + perp3 * th - Vector3(0, th, 0))
		st.set_normal(perp3)
		st.add_vertex(tp1 + perp3 * th)
		st.set_normal(perp3)
		st.add_vertex(tp2 + perp3 * th - Vector3(0, th, 0))
		st.set_normal(perp3)
		st.add_vertex(tp1 + perp3 * th - Vector3(0, th, 0))

	var committed := st.commit()
	if committed == null or committed.get_surface_count() == 0:
		return created

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "BridgeDeckRailing"
	mesh_inst.mesh = committed
	mesh_inst.material_override = material
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh_inst)
	created.append(mesh_inst)

	var coll_body := StaticBody3D.new()
	coll_body.name = "DeckRailingCollision"
	coll_body.collision_layer = 2
	for i in range(pn):
		var p1 := poly[i]
		var p2 := poly[(i + 1) % pn]
		var seg_len := p1.distance_to(p2)
		if seg_len < 1.0:
			continue
		if has_chunk_rect:
			var rx := chunk_rect.position.x
			var rz := chunk_rect.position.y
			var rx2 := rx + chunk_rect.size.x
			var rz2 := rz + chunk_rect.size.y
			if absf(p1.x - rx) < edge_tol and absf(p2.x - rx) < edge_tol:
				continue
			if absf(p1.x - rx2) < edge_tol and absf(p2.x - rx2) < edge_tol:
				continue
			if absf(p1.y - rz) < edge_tol and absf(p2.y - rz) < edge_tol:
				continue
			if absf(p1.y - rz2) < edge_tol and absf(p2.y - rz2) < edge_tol:
				continue
		var mid_pt := (p1 + p2) * 0.5
		if _is_point_on_vehicle_road(mid_pt, 1.0, ""):
			continue
		var coll_deck_y: float = _deck_surface_y_at(mid_pt, poly, 1, ref_elev)
		var coll_shape_node := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(seg_len, RAILING_HEIGHT, 0.1)
		coll_shape_node.shape = box
		var angle := atan2(p2.y - p1.y, p2.x - p1.x)
		coll_shape_node.position = Vector3(mid_pt.x, coll_deck_y + RAILING_HEIGHT * 0.5, mid_pt.y)
		coll_shape_node.rotation.y = -angle
		coll_body.add_child(coll_shape_node)
	parent.add_child(coll_body)
	created.append(coll_body)
	return created

# === End restored bridge deck section =======================================


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
	var z_offset: float = hash_val * 0.000005

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

		var left_pos := Vector2(p.x - perp.x * half_w, p.y - perp.y * half_w)
		var right_pos := Vector2(p.x + perp.x * half_w, p.y + perp.y * half_w)
		var h: float = _sample_elevation(p.x, p.y) + height_offset + z_offset

		# Left vertex
		vertices.append(Vector3(left_pos.x, h, left_pos.y))
		uvs.append(Vector2(0.0, uv_y))
		normals.append(Vector3.UP)

		# Right vertex
		vertices.append(Vector3(right_pos.x, h, right_pos.y))
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

## Subdivide road segments at elevation grid line crossings (every grid_step meters).
## Inserts vertices where the polyline crosses X or Z lines of the fixed grid,
## so roads follow the bilinear elevation surface accurately regardless of angle.
func _subdivide_for_elevation(points: PackedVector2Array, grid_step: float = 10.0) -> PackedVector2Array:
	if not enable_elevation or points.size() < 2:
		return points
	var result := PackedVector2Array()
	result.append(points[0])
	for i in range(1, points.size()):
		var p0 := points[i - 1]
		var p1 := points[i]
		var dx := p1.x - p0.x
		var dy := p1.y - p0.y  # y in Vector2 = world Z
		# Collect t-values where segment crosses grid lines
		var t_vals: Array[float] = []
		# X-axis grid crossings
		if absf(dx) > 0.001:
			var x_min := minf(p0.x, p1.x)
			var x_max := maxf(p0.x, p1.x)
			var x := ceilf(x_min / grid_step) * grid_step
			while x < x_max:
				var t := (x - p0.x) / dx
				if t > 0.001 and t < 0.999:
					t_vals.append(t)
				x += grid_step
		# Z-axis grid crossings
		if absf(dy) > 0.001:
			var z_min := minf(p0.y, p1.y)
			var z_max := maxf(p0.y, p1.y)
			var z := ceilf(z_min / grid_step) * grid_step
			while z < z_max:
				var t := (z - p0.y) / dy
				if t > 0.001 and t < 0.999:
					t_vals.append(t)
				z += grid_step
		# Sort and insert vertices at crossings
		t_vals.sort()
		var prev_t := -1.0
		for t in t_vals:
			if t - prev_t > 0.001:
				result.append(p0.lerp(p1, t))
				prev_t = t
		result.append(p1)
	return result


## Insert centerline points where road edges (offset by half_w) cross chunk boundaries.
## At inserted points the perpendicular offset lands exactly on the chunk edge,
## so clampf barely changes the vertex position — no sideways shift.
static func _insert_chunk_edge_points(points: PackedVector2Array, half_w: float,
		min_x: float, max_x: float, min_z: float, max_z: float) -> PackedVector2Array:
	if points.size() < 2 or min_x == -INF:
		return points
	var result := PackedVector2Array()
	result.append(points[0])
	for i in range(1, points.size()):
		var p0 := points[i - 1]
		var p1 := points[i]
		var seg_vec := p1 - p0
		var seg_len := seg_vec.length()
		if seg_len < 0.001:
			result.append(p1)
			continue
		var dir := seg_vec / seg_len
		var perp := Vector2(-dir.y, dir.x)

		# Left and right edge endpoints
		var l0 := p0 - perp * half_w
		var l1 := p1 - perp * half_w
		var r0 := p0 + perp * half_w
		var r1 := p1 + perp * half_w

		# Find t values where left or right edge crosses chunk boundary
		var t_list: Array = []
		var e0: Vector2
		var e1: Vector2
		for edge_idx in 2:
			e0 = l0 if edge_idx == 0 else r0
			e1 = l1 if edge_idx == 0 else r1
			var dx := e1.x - e0.x
			var dz := e1.y - e0.y
			var t: float
			if absf(dx) > 0.001:
				t = (min_x - e0.x) / dx
				if t > 0.01 and t < 0.99:
					t_list.append(t)
				t = (max_x - e0.x) / dx
				if t > 0.01 and t < 0.99:
					t_list.append(t)
			if absf(dz) > 0.001:
				t = (min_z - e0.y) / dz
				if t > 0.01 and t < 0.99:
					t_list.append(t)
				t = (max_z - e0.y) / dz
				if t > 0.01 and t < 0.99:
					t_list.append(t)

		if t_list.is_empty():
			result.append(p1)
			continue

		# Sort and insert unique centerline points
		t_list.sort()
		var prev_t := 0.0
		for t in t_list:
			if t - prev_t < 0.01:
				continue
			result.append(p0.lerp(p1, t))
			prev_t = t
		result.append(p1)
	return result

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

	# Clip road centerline to chunk boundary
	var chunk_min_x := -INF
	var chunk_max_x := INF
	var chunk_min_z := -INF
	var chunk_max_z := INF
	if chunk_key != "initial":
		var ck_parts: PackedStringArray = chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		chunk_min_x = float(ck_x) * chunk_size
		chunk_max_x = float(ck_x + 1) * chunk_size
		chunk_min_z = float(ck_z) * chunk_size
		chunk_max_z = float(ck_z + 1) * chunk_size
		var clip_margin: float = width * 0.5
		points = _clip_polyline_to_rect(points, chunk_min_x - clip_margin, chunk_max_x + clip_margin, chunk_min_z - clip_margin, chunk_max_z + clip_margin)
		if points.size() < 2:
			return

	# Subdivide long segments so road follows terrain elevation
	points = _subdivide_for_elevation(points)

	var half_w: float = width * 0.5

	# Insert points where road edges cross chunk boundary for proper edge clipping
	points = _insert_chunk_edge_points(points, half_w, chunk_min_x, chunk_max_x, chunk_min_z, chunk_max_z)

	# Z-fighting offset
	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.000005

	# Генерируем geometry для этого road segment
	var batch: Dictionary = _road_batch_data[chunk_key][texture_key]
	var vertex_offset: int = batch["vertices"].size()  # Offset для индексов

	var uv_scale: float = 0.1
	var accumulated_length: float = 0.0

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

		var left_pos := Vector2(clampf(p.x - perp.x * half_w, chunk_min_x, chunk_max_x), clampf(p.y - perp.y * half_w, chunk_min_z, chunk_max_z))
		var right_pos := Vector2(clampf(p.x + perp.x * half_w, chunk_min_x, chunk_max_x), clampf(p.y + perp.y * half_w, chunk_min_z, chunk_max_z))
		var h_center: float = _sample_elevation(p.x, p.y) + height_offset + z_offset
		var h_left: float = _sample_elevation(left_pos.x, left_pos.y) + height_offset + z_offset
		var h_right: float = _sample_elevation(right_pos.x, right_pos.y) + height_offset + z_offset

		# Clamp cross-slope: max 15% grade
		var max_tilt: float = width * 0.15
		h_left = clampf(h_left, h_center - max_tilt, h_center + max_tilt)
		h_right = clampf(h_right, h_center - max_tilt, h_center + max_tilt)

		# Left vertex
		batch["vertices"].append(Vector3(left_pos.x, h_left, left_pos.y))
		batch["uvs"].append(Vector2(0.0, uv_y))

		# Right vertex
		batch["vertices"].append(Vector3(right_pos.x, h_right, right_pos.y))
		batch["uvs"].append(Vector2(1.0, uv_y))

		# Normal from cross-section tilt
		var cross := Vector3(right_pos.x - left_pos.x, h_right - h_left, right_pos.y - left_pos.y)
		var fwd := Vector3(perp.y, 0.0, -perp.x)  # road forward direction
		var n := cross.cross(fwd).normalized()
		if n.y < 0.0:
			n = -n
		batch["normals"].append(n)
		batch["normals"].append(n)

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
func _process_footway_incremental(item: Dictionary, budget_end: int, ck: String = "") -> bool:
	var smoothed_points: PackedVector2Array = item.smoothed_points
	var width: float = item.width * 2.0  # Визуальная ширина x2 (ROAD_WIDTHS хранит логическую)
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
		on_road.append(_is_point_on_vehicle_road_neighborhood(p, 1.0, ck))
		in_parking.append(_is_point_in_any_parking(p, ck))
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
	# Path base is needed even for tagged crossings so curb returns and sidewalk ramps
	# are filled; the on-road portion is still removed by road-corridor clipping.
	_add_path_clipped_to_batch(smoothed_points, width, 0.23, parent)

	# Crossing: splitting по on_road для определения on-road portions (зебра)
	var current_pts := PackedVector2Array()
	current_pts.append(smoothed_points[0])
	var current_on: bool = on_road[0]
	var last_off_road_pt := smoothed_points[0]
	var has_before_off: bool = not on_road[0]
	for i in range(1, smoothed_points.size()):
		if on_road[i] != current_on:
			var edge_pt := _find_road_edge_point(smoothed_points[i - 1], current_on, smoothed_points[i], ck)
			current_pts.append(edge_pt)
			if current_pts.size() >= 2:
				if current_on:
					var road_info: Dictionary = {}
					if not is_tagged_crossing and has_before_off:
						var on_start: Vector2 = current_pts[0]
						var on_end: Vector2 = current_pts[current_pts.size() - 1]
						# Try edge points first (mid lands on the road → correct segment found)
						road_info = _detect_road_crossing(on_start, on_end, ck)
						if road_info.is_empty():
							# Edge points on same side (short on-road segment).
							# Find nearest road at on-road midpoint directly.
							var on_mid: Vector2 = (on_start + on_end) * 0.5
							road_info = _find_nearest_road_at_point(on_mid, ck)
					var is_full: bool = is_tagged_crossing or not road_info.is_empty()
					if is_full:
						var cross_pts := PackedVector2Array([current_pts[0], current_pts[current_pts.size() - 1]])
						var edge_span: float = cross_pts[0].distance_to(cross_pts[1])
						var road_w: float = road_info.get("road_width", 0.0)
						if edge_span >= 4.0:
							# Edge points span enough — use them directly (accurate angle)
							if not road_info.is_empty() and edge_span < road_w * 0.7:
								cross_pts = _build_crossing_strip(road_info, width)
						else:
							# Short on-road segment — use footway direction instead of spatial hash
							# Center on midpoint of off-road points (opposite sides of road),
							# not edge_pts (which cluster near one road edge)
							var fw_dir: Vector2 = (smoothed_points[i] - last_off_road_pt).normalized()
							var road_center: Vector2 = (last_off_road_pt + smoothed_points[i]) * 0.5
							var half_span := 5.0
							if road_w > 0.0:
								half_span = road_w * 0.5 + 2.0
							cross_pts = PackedVector2Array([road_center - fw_dir * half_span, road_center + fw_dir * half_span])
						var cross_w := width
						_add_road_to_batch_fast(cross_pts, cross_w, "intersection", 0.016, parent)
						_add_road_to_batch_fast(cross_pts, cross_w, "crossing", 0.017, parent)
						# Re-enqueue chunk for finalization (crossing added after initial batch build)
						if not _pending_batch_chunks.has(ck):
							_pending_batch_chunks.append(ck)
						if enable_crossing_signs:
							_enqueue_crossing_signs(cross_pts, parent, ck)
				else:
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
			var road_info_end: Dictionary = {}
			if not is_tagged_crossing and has_before_off:
				var on_start_end: Vector2 = current_pts[0]
				var on_end_end: Vector2 = current_pts[current_pts.size() - 1]
				road_info_end = _detect_road_crossing(on_start_end, on_end_end, ck)
				if road_info_end.is_empty():
					var on_mid_end: Vector2 = (on_start_end + on_end_end) * 0.5
					road_info_end = _find_nearest_road_at_point(on_mid_end, ck)
			var is_full_end: bool = is_tagged_crossing or not road_info_end.is_empty()
			if is_full_end:
				var cross_pts_end := PackedVector2Array([current_pts[0], current_pts[current_pts.size() - 1]])
				var edge_span_end: float = cross_pts_end[0].distance_to(cross_pts_end[1])
				var road_w_end: float = road_info_end.get("road_width", 0.0)
				if edge_span_end >= 4.0:
					if not road_info_end.is_empty() and edge_span_end < road_w_end * 0.7:
						cross_pts_end = _build_crossing_strip(road_info_end, width)
				else:
					var fw_dir_end: Vector2 = (last_pt - last_off_road_pt).normalized()
					var road_center_e: Vector2 = (last_off_road_pt + last_pt) * 0.5
					var half_span_e := 5.0
					if road_w_end > 0.0:
						half_span_e = road_w_end * 0.5 + 2.0
					cross_pts_end = PackedVector2Array([road_center_e - fw_dir_end * half_span_e, road_center_e + fw_dir_end * half_span_e])
				var cross_w_end := width
				_add_road_to_batch_fast(cross_pts_end, cross_w_end, "intersection", 0.016, parent)
				_add_road_to_batch_fast(cross_pts_end, cross_w_end, "crossing", 0.017, parent)
				if not _pending_batch_chunks.has(ck):
					_pending_batch_chunks.append(ck)
				if enable_crossing_signs:
					_enqueue_crossing_signs(current_pts, parent, ck)
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

	var chunk_min_x := -INF
	var chunk_max_x := INF
	var chunk_min_z := -INF
	var chunk_max_z := INF
	if chunk_key != "initial":
		var ck_parts: PackedStringArray = chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		chunk_min_x = float(ck_x) * chunk_size
		chunk_max_x = float(ck_x + 1) * chunk_size
		chunk_min_z = float(ck_z) * chunk_size
		chunk_max_z = float(ck_z + 1) * chunk_size
		var clip_margin: float = width * 0.5
		points = _clip_polyline_to_rect(points, chunk_min_x - clip_margin, chunk_max_x + clip_margin, chunk_min_z - clip_margin, chunk_max_z + clip_margin)
		if points.size() < 2:
			return

	# Subdivide long segments so road follows terrain elevation
	points = _subdivide_for_elevation(points)

	var half_w: float = width * 0.5

	# Insert points where road edges cross chunk boundary for proper edge clipping
	points = _insert_chunk_edge_points(points, half_w, chunk_min_x, chunk_max_x, chunk_min_z, chunk_max_z)

	var hash_val: int = int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.000005

	var batch: Dictionary = _road_batch_data[chunk_key][texture_key]
	var vertex_offset: int = batch["vertices"].size()
	# UV scale: 1 UV unit вдоль = width метров, чтобы текстура тайлилась 1:1
	var uv_scale: float = 1.0 / width
	var accumulated_length: float = 0.0
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

	for i in range(n_points):
		var p: Vector2 = points[i]
		var perp: Vector2 = perpendiculars[i]

		if i > 0:
			accumulated_length += points[i - 1].distance_to(p)
		var uv_y: float = accumulated_length * uv_scale

		var left_pos := Vector2(clampf(p.x - perp.x * half_w, chunk_min_x, chunk_max_x), clampf(p.y - perp.y * half_w, chunk_min_z, chunk_max_z))
		var right_pos := Vector2(clampf(p.x + perp.x * half_w, chunk_min_x, chunk_max_x), clampf(p.y + perp.y * half_w, chunk_min_z, chunk_max_z))
		var h_center: float = _sample_elevation(p.x, p.y) + height_offset + z_offset
		var h_left: float = _sample_elevation(left_pos.x, left_pos.y) + height_offset + z_offset
		var h_right: float = _sample_elevation(right_pos.x, right_pos.y) + height_offset + z_offset

		# Clamp cross-slope: max 15% grade
		var max_tilt: float = width * 0.15
		h_left = clampf(h_left, h_center - max_tilt, h_center + max_tilt)
		h_right = clampf(h_right, h_center - max_tilt, h_center + max_tilt)

		batch["vertices"].append(Vector3(left_pos.x, h_left, left_pos.y))
		batch["uvs"].append(Vector2(0.0, uv_y))

		batch["vertices"].append(Vector3(right_pos.x, h_right, right_pos.y))
		batch["uvs"].append(Vector2(1.0, uv_y))

		var cross := Vector3(right_pos.x - left_pos.x, h_right - h_left, right_pos.y - left_pos.y)
		var fwd := Vector3(perp.y, 0.0, -perp.x)
		var n := cross.cross(fwd).normalized()
		if n.y < 0.0:
			n = -n
		batch["normals"].append(n)
		batch["normals"].append(n)

	# Generate indices
	for i in range(n_points - 1):
		var idx: int = vertex_offset + i * 2
		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 3)
		batch["indices"].append(idx + 1)
		batch["indices"].append(idx + 0)
		batch["indices"].append(idx + 2)
		batch["indices"].append(idx + 3)


## Добавляет тротуар (path) как polygon, обрезанный road corridors + intersections.
## Результат обрезается точно по бордюру, как terrain.
func _add_path_clipped_to_batch(raw_points: PackedVector2Array, width: float, height_offset: float, parent: Node3D) -> void:
	if raw_points.size() < 2:
		return

	var chunk_key := ""
	if parent.name.begins_with("Chunk_"):
		chunk_key = parent.name.substr(6)
	else:
		chunk_key = "initial"

	# 1. Строим corridor polygon из points + width
	var validated: PackedVector2Array = _validate_road_direction(raw_points)
	if validated.size() < 2:
		return
	var half_w: float = width * 0.5
	var corridor_polys: Array[PackedVector2Array] = Geometry2D.offset_polyline(
		validated, half_w,
		Geometry2D.JOIN_MITER, Geometry2D.END_SQUARE)
	if corridor_polys.is_empty():
		return

	# 2. Обрезка по bbox чанка + начальная инициализация polys
	var polys: Array[PackedVector2Array] = []
	var ck_x := 0
	var ck_z := 0
	if chunk_key != "initial":
		var ck_parts: PackedStringArray = chunk_key.split(",")
		ck_x = int(ck_parts[0])
		ck_z = int(ck_parts[1])
		var chunk_rect := PackedVector2Array([
			Vector2(float(ck_x) * chunk_size, float(ck_z) * chunk_size),
			Vector2(float(ck_x + 1) * chunk_size, float(ck_z) * chunk_size),
			Vector2(float(ck_x + 1) * chunk_size, float(ck_z + 1) * chunk_size),
			Vector2(float(ck_x) * chunk_size, float(ck_z + 1) * chunk_size),
		])
		for raw_corridor in corridor_polys:
			if raw_corridor.size() < 3:
				continue
			if _polygon_area(raw_corridor) < 0:
				raw_corridor.reverse()
			var clipped_corridors: Array[PackedVector2Array] = Geometry2D.intersect_polygons(raw_corridor, chunk_rect)
			for cp in clipped_corridors:
				if cp.size() >= 3 and absf(_polygon_area(cp)) >= 0.5:
					polys.append(cp)
	else:
		for raw_corridor in corridor_polys:
			if raw_corridor.size() < 3:
				continue
			if _polygon_area(raw_corridor) < 0:
				raw_corridor.reverse()
			polys.append(raw_corridor)
	if polys.is_empty():
		return

	# 3. Defer road/intersection/parking clipping to finalization time,
	#    when _chunk_terrain_roads from all neighbours are populated.
	#    For "initial" mode (no chunks), clip immediately as before.
	if chunk_key != "initial":
		if not _deferred_path_polys.has(chunk_key):
			_deferred_path_polys[chunk_key] = []
		_deferred_path_polys[chunk_key].append({
			"polys": polys,
			"validated": validated,
			"width": width,
			"height_offset": height_offset,
			"parent": parent,
			"ck_x": ck_x,
			"ck_z": ck_z,
		})
		return

	# --- "initial" mode: clip and add immediately (legacy path) ---
	polys = _clip_path_polys_by_roads_and_intersections(polys, ck_x, ck_z, "initial")

	# Фильтрация мелких осколков
	var filtered: Array[PackedVector2Array] = []
	for poly in polys:
		if poly.size() >= 3 and absf(_polygon_area(poly)) >= 0.5:
			filtered.append(poly)
	if filtered.is_empty():
		return

	# Добавляем в road batch (триангулированные полигоны)
	_add_path_polys_to_batch(filtered, validated, width, height_offset, "initial", parent)


## Clips path polygons by road corridors, intersection contours, and parking polygons.
## Extracted so it can be called both inline ("initial") and deferred (chunk finalization).
func _clip_path_polys_by_roads_and_intersections(polys: Array[PackedVector2Array], ck_x: int, ck_z: int, chunk_key: String) -> Array[PackedVector2Array]:
	# Road corridors
	if chunk_key != "initial":
		var terrain_roads: Array = []
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var nk := "%d,%d" % [ck_x + dx, ck_z + dz]
				if _chunk_terrain_roads.has(nk):
					terrain_roads.append_array(_chunk_terrain_roads[nk])
		for road_corridor in terrain_roads:
			if road_corridor.size() < 4:
				continue
			var new_polys: Array[PackedVector2Array] = []
			for poly in polys:
				var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, road_corridor)
				for cp in clipped:
					if cp.size() >= 3:
						new_polys.append(cp)
			polys = new_polys
			if polys.is_empty():
				return polys

	# Intersection contours
	if not polys.is_empty():
		var ch_min_x := float(ck_x) * chunk_size
		var ch_max_x := ch_min_x + chunk_size
		var ch_min_z := float(ck_z) * chunk_size
		var ch_max_z := ch_min_z + chunk_size
		for i in range(_intersection_contours.size()):
			var contour: PackedVector2Array = _intersection_contours[i]
			if contour.size() < 3:
				continue
			if chunk_key != "initial" and i < _intersection_positions.size():
				var ipos: Vector2 = _intersection_positions[i]
				if ipos.x < ch_min_x - 30.0 or ipos.x > ch_max_x + 30.0 or ipos.y < ch_min_z - 30.0 or ipos.y > ch_max_z + 30.0:
					continue
			var new_polys: Array[PackedVector2Array] = []
			for poly in polys:
				var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, contour)
				for cp in clipped:
					if cp.size() >= 3:
						new_polys.append(cp)
			polys = new_polys
			if polys.is_empty():
				return polys

	# Parking polygons
	if not polys.is_empty():
		for ck_p in _chunk_parking_hashes:
			var pk_data: Dictionary = _chunk_parking_hashes[ck_p]
			var pk_polys: Array = pk_data.get("polys", [])
			for parking_poly in pk_polys:
				if parking_poly.size() < 3:
					continue
				var new_polys: Array[PackedVector2Array] = []
				for poly in polys:
					var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, parking_poly)
					for cp in clipped:
						if cp.size() >= 3:
							new_polys.append(cp)
				polys = new_polys
				if polys.is_empty():
					return polys

	return polys


## Adds pre-clipped path polygons to road batch data for triangulation.
func _add_path_polys_to_batch(filtered: Array[PackedVector2Array], validated: PackedVector2Array, width: float, height_offset: float, chunk_key: String, parent: Node3D) -> void:
	if not _road_batch_data.has(chunk_key):
		_road_batch_data[chunk_key] = {}
	var texture_key := "path"
	if not _road_batch_data[chunk_key].has(texture_key):
		_road_batch_data[chunk_key][texture_key] = {
			"vertices": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"normals": PackedVector3Array(),
			"indices": PackedInt32Array(),
			"parent": parent
		}
	var batch: Dictionary = _road_batch_data[chunk_key][texture_key]

	var hash_val: int = int(abs(validated[0].x * 1000 + validated[0].y * 7919)) % 100
	var z_offset: float = hash_val * 0.000005
	var uv_scale: float = 1.0 / width

	# Split polygons into grid cells so flat triangles track bilinear elevation
	var grid_polys: Array[PackedVector2Array] = []
	for poly in filtered:
		grid_polys.append_array(_split_polygon_by_grid(poly, 10.0))

	for poly in grid_polys:
		var indices := Geometry2D.triangulate_polygon(poly)
		if indices.size() < 3:
			continue
		var base_idx: int = batch["vertices"].size()
		for p in poly:
			var h: float = _sample_elevation(p.x, p.y) + height_offset + z_offset
			batch["vertices"].append(Vector3(p.x, h, p.y))
			batch["uvs"].append(Vector2(p.x * uv_scale, p.y * uv_scale))
			batch["normals"].append(Vector3.UP)
		for idx in indices:
			batch["indices"].append(base_idx + idx)


## Ensures albedo + marking textures exist for a lane-aware texture_key like "ow2", "bi4".
## Called lazily — generates and caches on first use.
func _ensure_lane_textures(texture_key: String) -> void:
	if _road_textures.has(texture_key):
		return
	# Albedo — always the same asphalt
	_road_textures[texture_key] = _cached_road_albedo
	# Parse key: "ow{N}" = oneway N lanes, "bi{N}" = bidirectional N lanes
	var marking_key := "marking_" + texture_key
	if _road_textures.has(marking_key):
		return
	var is_oneway: bool = texture_key.begins_with("ow")
	var lanes: int = int(texture_key.substr(2))
	if lanes < 1:
		lanes = 2
	if is_oneway:
		_road_textures[marking_key] = TextureGeneratorScript.create_oneway_markings(512, lanes)
	else:
		# Bidirectional: center line + dashed lane dividers
		_road_textures[marking_key] = TextureGeneratorScript.create_primary_markings(512, lanes)


# Финализирует road batches для чанка - создаёт merged meshes
func _finalize_road_batches_for_chunk(chunk_key: String) -> void:
	var prof_start_total = 0
	if _profiler:
		prof_start_total = _profiler.start_measure("road_batch_finalize_total_" + chunk_key)

	# Flush deferred path polygons — clip against now-populated road corridors
	var _had_deferred_paths := false
	if _deferred_path_polys.has(chunk_key):
		var deferred_items: Array = _deferred_path_polys[chunk_key]
		_deferred_path_polys.erase(chunk_key)
		for item in deferred_items:
			var polys: Array[PackedVector2Array] = item.polys
			polys = _clip_path_polys_by_roads_and_intersections(polys, item.ck_x, item.ck_z, chunk_key)
			var filtered: Array[PackedVector2Array] = []
			for poly in polys:
				if poly.size() >= 3 and absf(_polygon_area(poly)) >= 0.5:
					filtered.append(poly)
			if not filtered.is_empty():
				_add_path_polys_to_batch(filtered, item.validated, item.width, item.height_offset, chunk_key, item.parent)
				_had_deferred_paths = true

	if not _road_batch_data.has(chunk_key):
		# Нет дорог — но террейн всё равно создаём
		_emit_road_debug("ROAD_FINALIZE key=%s status=no_batches" % chunk_key)
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

	# Lazy-register lane-aware textures (e.g., "ow2", "bi4")
	_ensure_lane_textures(texture_key)

	# Создаём материал с шейдером (noise вариация roughness + лужи + разметка)
	var albedo_tex: Texture2D = _road_textures.get(texture_key, null)
	var is_sidewalk := texture_key == "path"
	var material: Material
	if texture_key == "tram_bed":
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = albedo_tex
		mat.roughness = 0.7
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		material = mat
	elif texture_key == "tram_rails":
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = albedo_tex
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
		mat.metallic = 0.7
		mat.roughness = 0.3
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		material = mat
	else:
		var normal_tex: Texture2D = _normal_textures.get("sidewalk" if is_sidewalk else "asphalt", null)
		var roughness_tex: Texture2D = _road_textures.get("sidewalk_roughness" if is_sidewalk else "road_roughness", null)
		var marking_tex: Texture2D = _road_textures.get("marking_" + texture_key, null)
		material = WetRoadMaterial.create_road_shader_material(
			albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
			_noise_textures.get("micro", null),
			_noise_textures.get("macro", null),
			roughness_tex,
			marking_tex
		)
		if material is ShaderMaterial:
			WetRoadMaterial.apply_road_type_params(material, texture_key)

	# Добавляем в parent (chunk node)
	var parent: Node3D = batch["parent"]

	# SAFETY: Проверяем что parent ещё существует (чанк не был выгружен)
	if not is_instance_valid(parent):
		print("OSM: ⚠️ Skipped road batch %s/%s - chunk was unloaded" % [chunk_key, texture_key])
		_emit_road_debug("ROAD_DROP key=%s reason=finalize_invalid_parent texture=%s verts=%d indices=%d" % [
			chunk_key,
			texture_key,
			int(batch["vertices"].size()),
			int(batch["indices"].size())
		])
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

	_emit_road_debug("ROAD_FINALIZE key=%s texture=%s verts=%d tris=%d rs_instances=%d remaining_batches=%d" % [
		chunk_key,
		texture_key,
		int(batch["vertices"].size()),
		int(batch["indices"].size() / 3),
		int(_chunk_rs_instances.get(chunk_key, []).size()),
		int(_road_batch_data.get(chunk_key, {}).size())
	])

	# Road collision — StaticBody3D (deferred shape creation)
	var road_body := StaticBody3D.new()
	road_body.name = "RoadBatchCollision_" + texture_key
	road_body.collision_layer = 1
	road_body.collision_mask = 1
	road_body.add_to_group("Road")  # GEVP - дорога

	_budgeted_add_child(parent, road_body)

	# Collision shape — отложенное создание (ConcavePolygonShape3D ~5-26ms)
	_deferred_append(_deferred_road_collisions, chunk_key, {
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
	# Проверяем что все соседние чанки завершили Phase 3 (дороги готовы)
	# Если сосед ещё загружается — откладываем terrain clipping
	var ck_parts: PackedStringArray = chunk_key.split(",")
	var ck_x := int(ck_parts[0])
	var ck_z := int(ck_parts[1])
	# Собираем коридоры дорог — уже клипнуты к rect чанка в worker thread
	var terrain_roads: Array = []
	if _chunk_terrain_roads.has(chunk_key):
		terrain_roads = _chunk_terrain_roads[chunk_key].duplicate()
	var ch_min_x := float(ck_x) * chunk_size
	var ch_max_x := ch_min_x + chunk_size
	var ch_min_z := float(ck_z) * chunk_size
	var ch_max_z := ch_min_z + chunk_size

	# Собираем перекрёстки и парковки, относящиеся к этому чанку (предфильтрация)
	# Skip intersection clipping when roads are disabled — nothing fills the holes
	var relevant_contours: Array[PackedVector2Array] = []
	var relevant_contour_positions: Array[Vector2] = []
	if enable_roads:
		for i in range(_intersection_contours.size()):
			var ipos: Vector2 = _intersection_positions[i]
			if ipos.x >= ch_min_x - 30.0 and ipos.x <= ch_max_x + 30.0 and ipos.y >= ch_min_z - 30.0 and ipos.y <= ch_max_z + 30.0:
				var contour: PackedVector2Array = _intersection_contours[i]
				if contour.size() >= 3:
					relevant_contours.append(contour)
					relevant_contour_positions.append(ipos)

	var relevant_parking: Array[PackedVector2Array] = []
	if enable_roads:
		for ck_p in _chunk_parking_hashes:
			var pk_data: Dictionary = _chunk_parking_hashes[ck_p]
			var pk_polys: Array = pk_data.get("polys", [])
			for parking_poly in pk_polys:
				if parking_poly.size() < 3:
					continue
				var in_chunk := false
				for pp in parking_poly:
					if pp.x >= ch_min_x - 5.0 and pp.x <= ch_max_x + 5.0 and pp.y >= ch_min_z - 5.0 and pp.y <= ch_max_z + 5.0:
						in_chunk = true
						break
				if in_chunk:
					relevant_parking.append(parking_poly)

	# Собираем водные полигоны из глобального реестра — каждый full polygon
	# зарегистрирован один раз, чанки находят его по AABB пересечению. Это
	# покрывает чанки внутри огромных полигонов (Рыбинское вдхр), которые
	# не получили way в своих OSM-данных.
	var relevant_water_shore: Array[PackedVector2Array] = []
	# Per-chunk water polygons we'll render mesh + shore for.
	var per_chunk_water: Array[PackedVector2Array] = []
	if enable_water:
		var inflated := Rect2(
			ch_min_x - SHORE_WIDTH - 5.0,
			ch_min_z - SHORE_WIDTH - 5.0,
			(ch_max_x - ch_min_x) + 2 * (SHORE_WIDTH + 5.0),
			(ch_max_z - ch_min_z) + 2 * (SHORE_WIDTH + 5.0)
		)
		var chunk_rect_clip := PackedVector2Array([
			Vector2(ch_min_x, ch_min_z),
			Vector2(ch_max_x, ch_min_z),
			Vector2(ch_max_x, ch_max_z),
			Vector2(ch_min_x, ch_max_z),
		])
		for i in _global_water_polygons.size():
			var bbox: Rect2 = _global_water_polygon_bboxes[i]
			if not bbox.intersects(inflated):
				continue
			var water_poly: PackedVector2Array = _global_water_polygons[i]
			if water_poly.size() < 3:
				continue
			# Clip polygon to chunk rect for water mesh + per-chunk
			# polygon list (used by shore "facing open water" check).
			for clipped_w in Geometry2D.intersect_polygons(water_poly, chunk_rect_clip):
				if clipped_w.size() >= 3:
					per_chunk_water.append(clipped_w)
			# Расширяем полигон на SHORE_WIDTH для выреза из террейна
			var delta := SHORE_WIDTH
			if not _is_polygon_ccw(water_poly):
				delta = -delta
			var expanded := Geometry2D.offset_polygon(water_poly, delta)
			for ep in expanded:
				if ep.size() >= 3:
					relevant_water_shore.append(ep)
	# Render water mesh + shore for this chunk's slices of global polygons.
	# Without this the terrain hole has no water filling it (chunk falls
	# into empty void below the road / bridge).
	if not per_chunk_water.is_empty():
		# Update per-chunk water hash so other queries (point-in-water,
		# tree placement) see this chunk's water — even though the way
		# wasn't in this chunk's OSM data.
		if not _chunk_water_polygons.has(chunk_key):
			_chunk_water_polygons[chunk_key] = []
		for cw in per_chunk_water:
			_chunk_water_polygons[chunk_key].append(cw)
			_create_polygon_mesh_with_texture(cw, "water", WATER_Y, parent_node, true)
			call_deferred("_create_shore_mesh", cw, parent_node)

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
		"water_shore": relevant_water_shore,
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
	quad.size = Vector2(WINDOW_SIZE, WINDOW_SIZE)
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
			light.light_energy = 2.6 if is_night else 0.0
			light_count += 1

	var icon := "🌙" if is_night else "☀️"
	print("OSM: %s Updated %d window batch materials, %d entrance lights: is_night=%s (pruned %d stale)" % [
		icon, updated_count, light_count, is_night, before_size - _window_batch_materials.size()
	])


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

			var h_center1 := _sample_elevation(p1.x, p1.y)
			var h_center2 := _sample_elevation(p2.x, p2.y)
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
	var CURB_COLLISION_BUDGET_USEC := 500000 if _initial_loading else 1000
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
	var BUDGET_USEC := 500000 if _initial_loading else 2000
	var start := Time.get_ticks_usec()

	# 1. Road/terrain collisions (тяжёлые — 1 за кадр в gameplay, drain в initial loading)
	# ConcavePolygonShape3D.set_faces is ~5-15ms, but during initial loading the user is on the
	# loading screen, so we can drain everything within the 500ms budget.
	while not _deferred_road_collisions.is_empty():
		if _add_child_count >= _add_child_budget:
			return
		if (Time.get_ticks_usec() - start) > BUDGET_USEC:
			return
		var _rc_keys := _get_prioritized_keys(_deferred_road_collisions)
		if _rc_keys.is_empty():
			break
		var rc_ck: String = _rc_keys[0]
		var rc_arr: Array = _deferred_road_collisions[rc_ck]
		var item: Dictionary = rc_arr.pop_front()
		if rc_arr.is_empty():
			_deferred_road_collisions.erase(rc_ck)
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
		if not _initial_loading:
			return  # Gameplay: one heavy collision per frame to avoid stutter

	while not _deferred_terrain_collisions.is_empty():
		if _add_child_count >= _add_child_budget:
			return
		if (Time.get_ticks_usec() - start) > BUDGET_USEC:
			return
		var _tc_keys := _get_prioritized_keys(_deferred_terrain_collisions)
		if _tc_keys.is_empty():
			break
		var tc_ck: String = _tc_keys[0]
		var tc_arr: Array = _deferred_terrain_collisions[tc_ck]
		var item: Dictionary = tc_arr.pop_front()
		if tc_arr.is_empty():
			_deferred_terrain_collisions.erase(tc_ck)
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
		if not _initial_loading:
			return  # Gameplay: one heavy collision per frame

	# 2. Building collisions (budgeted)
	var bc_done_keys: Array[String] = []
	for bc_ck in _get_prioritized_keys(_deferred_building_collisions):
		if _add_child_count >= _add_child_budget or (Time.get_ticks_usec() - start) > BUDGET_USEC:
			break
		var bc_arr: Array = _deferred_building_collisions[bc_ck]
		while not bc_arr.is_empty():
			if _add_child_count >= _add_child_budget or (Time.get_ticks_usec() - start) > BUDGET_USEC:
				return
			var item: Dictionary = bc_arr[0]
			var parent: Node3D = item["parent"]
			if not is_instance_valid(parent):
				bc_arr.pop_front()
				continue
			var collisions: Array = item["collisions"]
			var idx: int = item["idx"]
			while idx < collisions.size() and _add_child_count < _add_child_budget:
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
				bc_arr.pop_front()
			else:
				item["idx"] = idx
				return
		if bc_arr.is_empty():
			bc_done_keys.append(bc_ck)
	for bc_ck in bc_done_keys:
		_deferred_building_collisions.erase(bc_ck)

	# 3. Tree collisions (budgeted)
	var tree_done_keys: Array[String] = []
	for tree_ck in _get_prioritized_keys(_deferred_tree_collisions):
		if _add_child_count >= _add_child_budget or (Time.get_ticks_usec() - start) > BUDGET_USEC:
			break
		var tree_arr: Array = _deferred_tree_collisions[tree_ck]
		while not tree_arr.is_empty():
			if _add_child_count >= _add_child_budget or (Time.get_ticks_usec() - start) > BUDGET_USEC:
				return
			var item: Dictionary = tree_arr[0]
			var parent_node: Node3D = item["parent"]
			if not is_instance_valid(parent_node):
				tree_arr.pop_front()
				continue
			var collisions: Array = item["collisions"]
			var idx: int = item["idx"]
			while idx < collisions.size() and _add_child_count < _add_child_budget:
				var collision_data: Dictionary = collisions[idx]
				var coll_pos: Vector3 = collision_data["position"]
				if _is_point_near_road(Vector2(coll_pos.x, coll_pos.z), 60.0, tree_ck):
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
				tree_arr.pop_front()
			else:
				item["idx"] = idx
				return
		if tree_arr.is_empty():
			tree_done_keys.append(tree_ck)
	for tree_ck in tree_done_keys:
		_deferred_tree_collisions.erase(tree_ck)


## Создаёт все отложенные SpotLight3D фонарей за один проход (без бюджета).
## Вызывается из _process() отдельно от _process_deferred_nodes.
func _process_deferred_lamp_lights() -> void:
	var t0 := Time.get_ticks_usec()
	var ll_done_keys: Array[String] = []
	for ll_ck in _get_prioritized_keys(_deferred_lamp_lights):
		var ll_arr: Array = _deferred_lamp_lights[ll_ck]
		while not ll_arr.is_empty():
			var item: Dictionary = ll_arr[0]
			var container: Node3D = item["container"]
			if not is_instance_valid(container):
				ll_arr.pop_front()
				continue
			var lights: Array = item["lights"]
			var chunk_key: String = item["chunk_key"]
			for light_data: Dictionary in lights:
				var light := SpotLight3D.new()
				light.position = light_data.position
				light.rotation_degrees.y = rad_to_deg(light_data.get("yaw", 0.0) - PI / 2.0 + PI)
				light.rotation_degrees.x = -75
				light.spot_range = 15.0
				light.spot_angle = 70.0
				light.spot_attenuation = 1.0
				light.light_energy = 2.6
				light.light_color = Color(1.0, 0.65, 0.2)
				light.light_volumetric_fog_energy = 16.0
				light.shadow_enabled = false
				light.light_bake_mode = Light3D.BAKE_DISABLED
				light.distance_fade_enabled = true
				light.distance_fade_begin = 120.0
				light.distance_fade_shadow = 30.0
				light.distance_fade_length = 30.0
				light.visible = _is_night_mode and not light_data.broken
				light.set_meta("broken", light_data.broken)
				light.add_child(_create_lamp_bulb())
				light.add_child(_create_debug_light_cone(light.spot_range, light.spot_angle))
				container.add_child(light)
				if _lamp_lights_by_chunk.has(chunk_key):
					_lamp_lights_by_chunk[chunk_key].append(light)
			ll_arr.pop_front()
			# 2ms budget — remaining lamps processed next frame (unlimited during initial load)
			if not _initial_loading and (Time.get_ticks_usec() - t0) > 2000:
				break
		if ll_arr.is_empty():
			ll_done_keys.append(ll_ck)
		if not _initial_loading and (Time.get_ticks_usec() - t0) > 2000:
			break
	for ll_ck in ll_done_keys:
		_deferred_lamp_lights.erase(ll_ck)


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

func _create_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, way_id: int = 0, entrance_nodes: Array = [], poi_nodes: Array = [], skip_spatial_hash: bool = false) -> void:
	if not enable_buildings or nodes.size() < 3:
		return

		var ck: String = _get_chunk_key_from_node(parent)

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Сохраняем рёбра здания для проверки расстояния при генерации деревьев
	# Skip if spatial hash was already built by Phase 1+2 worker thread
	if not skip_spatial_hash:
		var bld_ck := _get_chunk_key_from_node(parent)
		for i in range(points.size()):
			var p1 := points[i]
			var p2 := points[(i + 1) % points.size()]
			var seg := {"p1": p1, "p2": p2}
			_add_building_segment_to_spatial_hash(seg, bld_ck)
		_add_building_poly_to_hash(points, bld_ck)

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
	var max_elev := _sample_elevation(center.x, center.y)
	for p in points:
		max_elev = maxf(max_elev, _sample_elevation(p.x, p.y))
	var base_elev := 0.22 + max_elev

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

	# Custom 3D model — полностью заменяет геометрию здания
	if building_override and building_override.custom_model_path != "":
		_place_custom_building_model(building_override, center, parent, base_elev)
	elif building_override and building_override.wall_texture_path != "":
		# Кастомная текстура с опциональным normal map
		_create_3d_building_with_custom_texture(points, building_height, building_override, parent, base_elev, debug_name)
		print("OSM: Building override applied for way %d with texture %s" % [way_id, building_override.wall_texture_path])
	elif building_override and building_override.use_color_tint:
		var override_color: Color = building_override.color_tint
		_create_3d_building(points, override_color, building_height, parent, base_elev, debug_name)
		print("OSM: Building override applied for way %d with color %s" % [way_id, override_color])
	else:
		# Деревянные одноэтажные дома (Россия) — из override или OSM тегов
		var is_wooden := false
		var building_material_tag := str(tags.get("building:material", ""))
		if building_override and building_override.building_material == "wood":
			is_wooden = true
		elif building_material_tag == "wood" or building_material_tag == "timber":
			is_wooden = true

		if is_wooden and building_height <= 7.0 and _is_russia_location():
			var wood_idx := way_id % WOODEN_TEXTURES.size()
			var wood_override = BuildingOverride.new()
			wood_override.wall_texture_path = WOODEN_TEXTURES[wood_idx]
			wood_override.texture_repeat_y = 1.0
			wood_override.building_material = "wood"
			_create_3d_building_with_custom_texture(points, building_height, wood_override, parent, base_elev, debug_name)
		else:
			# Проверяем, подходит ли здание для случайной советской текстуры
			var use_soviet_texture := false
			var soviet_texture_path := ""

			# Критерий 1: Нет override (уже подтверждено, т.к. мы в else)
			# Критерий 2: Только Череповец
			# Критерий 3: 5 этажей
			if _is_cherepovets_location() and _is_5_story_building(building_height, tags):
				use_soviet_texture = true
				soviet_texture_path = _get_random_soviet_texture(way_id, tags)

			if use_soviet_texture:
				# Создаём динамический BuildingOverride со случайной текстурой
				# ТОЛЬКО текстура + вертикальное повторение (1×). Без масштабов, без адаптивности.
				var temp_override = BuildingOverride.new()
				temp_override.wall_texture_path = soviet_texture_path
				temp_override.texture_repeat_y = 1.0

				_create_3d_building_with_custom_texture(points, building_height, temp_override, parent, base_elev, debug_name)
			else:
				# Оригинальная логика текстур по умолчанию
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
	_add_business_signs_simple(points, tags, parent, building_height, base_elev, loader, way_id, entrance_nodes, poi_nodes)

	# Добавляем подъезды жилых домов (из building_overrides JSON)
	if way_id > 0 and _decoration_layer:
		_add_residential_entrances(points, parent, base_elev, way_id)

	# Добавляем входные группы магазинов (из building_overrides JSON)
	if way_id > 0 and _decoration_layer:
		_add_shop_entrances_from_override(points, parent, building_height, base_elev, way_id)

	# Добавляем кастомные входные группы (МАРС и т.д.)
	if way_id > 0 and _decoration_layer:
		_add_custom_entrances_from_override(points, parent, building_height, base_elev, way_id)

	# Вывески на крыше
	if way_id > 0 and _decoration_layer:
		_add_roof_signs_from_override(points, parent, building_height, base_elev, way_id)
		_add_wall_signs_from_override(points, parent, building_height, base_elev, way_id)
		_add_pediments_from_override(points, parent, building_height, base_elev, way_id)


func _create_parking(points: PackedVector2Array, parent: Node3D, chunk_key: String = "") -> void:
	"""Создаёт парковку: асфальтовую поверхность + знак P (знак отложен) + припаркованные машины"""
	if points.size() < 3:
		return
	if not enable_roads:
		return

	# Clip parking polygon to chunk bounds
	if chunk_key != "" and chunk_key != "initial":
		var ck_parts := chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		var chunk_rect := PackedVector2Array([
			Vector2(float(ck_x) * chunk_size, float(ck_z) * chunk_size),
			Vector2(float(ck_x + 1) * chunk_size, float(ck_z) * chunk_size),
			Vector2(float(ck_x + 1) * chunk_size, float(ck_z + 1) * chunk_size),
			Vector2(float(ck_x) * chunk_size, float(ck_z + 1) * chunk_size),
		])
		var clipped := Geometry2D.intersect_polygons(points, chunk_rect)
		if clipped.is_empty():
			return
		points = clipped[0]
		if points.size() < 3:
			return

	# Примечание: полигон уже добавлен в _chunk_parking_hashes в первом проходе

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
	if parking_points.size() < 3:
		return {}

	# Сначала находим ближайшую дорогу к парковке (по центру)
	var parking_center := Vector2.ZERO
	for pt in parking_points:
		parking_center += pt
	parking_center /= parking_points.size()

	var nearby_segs := _get_nearby_road_segments(parking_center)
	if nearby_segs.is_empty():
		return {}

	var nearest_road_point := Vector2.ZERO
	var min_center_dist := INF

	for seg in nearby_segs:
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
	# Split into grid cells so parking follows terrain slope accurately
	var grid_polys := _split_polygon_by_grid(points, 10.0)

	var mesh := MeshInstance3D.new()
	mesh.name = "ParkingSurface"

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Создаём материал — тот же шейдер что и дороги (PBR текстура + roughness + wet mode)
	var albedo_tex: Texture2D = _road_textures.get("intersection", null)
	var normal_tex: Texture2D = _normal_textures.get("asphalt", null)
	var roughness_tex: Texture2D = _road_textures.get("road_roughness", null)
	var material: Material = WetRoadMaterial.create_road_shader_material(
		albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null),
		roughness_tex
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, "intersection")

	st.set_material(material)

	# Высота парковки вровень с дорогами (service = 0.004)
	var height_offset := 0.005

	# Добавляем вершины треугольников
	var uv_ws := 1.0 / 6.0  # World-space UV (совпадает с дорогами и перекрёстками)
	for cell_poly in grid_polys:
		var indices := Geometry2D.triangulate_polygon(cell_poly)
		if indices.size() < 3:
			continue
		for i in range(0, indices.size(), 3):
			for j in range(3):
				var idx = indices[i + j]
				var p = cell_poly[idx]
				var h = _sample_elevation(p.x, p.y) + height_offset
				st.set_uv(Vector2(p.x * uv_ws, p.y * uv_ws))
				st.set_normal(Vector3.UP)
				st.add_vertex(Vector3(p.x, h, p.y))

	mesh.mesh = st.commit()

	# Collision — StaticBody3D with trimesh collision
	var body := StaticBody3D.new()
	body.name = "ParkingCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	body.add_to_group("Road")
	body.add_child(mesh)
	mesh.create_trimesh_collision()
	for child in mesh.get_children():
		if child is StaticBody3D:
			var col_shape := child.get_child(0)
			if col_shape is CollisionShape3D:
				child.remove_child(col_shape)
				body.add_child(col_shape)
			child.queue_free()
	parent.add_child(body)

	# Track material for wet mode toggle
	if material is ShaderMaterial:
		var chunk_key := ""
		if parent.name.begins_with("Chunk_"):
			chunk_key = parent.name.substr(6)
		if chunk_key != "":
			if not _chunk_road_materials.has(chunk_key):
				_chunk_road_materials[chunk_key] = []
			_chunk_road_materials[chunk_key].append(material)


func _create_pedestrian_area(points: PackedVector2Array, parent: Node3D, chunk_key: String = "") -> void:
	"""Создаёт пешеходную площадь с материалом тротуара"""
	if not enable_roads:
		return
	# Split into grid cells so area follows terrain slope accurately
	var grid_polys := _split_polygon_by_grid(points, 10.0)

	var mesh := MeshInstance3D.new()
	mesh.name = "PedestrianArea"

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var albedo_tex: Texture2D = _road_textures.get("path", null)
	var normal_tex: Texture2D = _normal_textures.get("sidewalk", null)
	var roughness_tex: Texture2D = _road_textures.get("sidewalk_roughness", null)
	var material: Material = WetRoadMaterial.create_road_shader_material(
		albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null),
		roughness_tex
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, "path")

	st.set_material(material)

	var height_offset := 0.23  # Same as footway (1cm above grass terrain at 0.22)
	var uv_ws := 1.0 / 4.0

	for cell_poly in grid_polys:
		var indices := Geometry2D.triangulate_polygon(cell_poly)
		if indices.size() < 3:
			continue
		for i in range(0, indices.size(), 3):
			for j in range(3):
				var idx = indices[i + j]
				var p = cell_poly[idx]
				st.set_uv(Vector2(p.x * uv_ws, p.y * uv_ws))
				st.set_normal(Vector3.UP)
				st.add_vertex(Vector3(p.x, _sample_elevation(p.x, p.y) + height_offset, p.y))

	mesh.mesh = st.commit()
	parent.add_child(mesh)

	if material is ShaderMaterial:
		var ck := chunk_key
		if ck.is_empty() and parent.name.begins_with("Chunk_"):
			ck = parent.name.substr(6)
		if ck != "":
			if not _chunk_road_materials.has(ck):
				_chunk_road_materials[ck] = []
			_chunk_road_materials[ck].append(material)


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
		var elevation: float = _sample_elevation(pos.x, pos.y)

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
	var nearby_segs := _get_nearby_road_segments(center)
	if nearby_segs.is_empty():
		return _get_longest_edge_direction(parking_points)

	# Находим ближайший сегмент дороги
	var min_dist := INF
	var best_road_dir := Vector2(1, 0)

	for seg in nearby_segs:
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
func _enqueue_crossing_signs(crossing_pts: PackedVector2Array, parent: Node3D, ck: String = "") -> void:
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
			var segs := _query_road_hash(key, ck)
			for seg in segs:
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


func _enqueue_tram_stop_sign(pos: Vector2, parent: Node3D, chunk_key: String) -> void:
	# Dedup
	var pos_key := "ts_%d_%d" % [int(pos.x), int(pos.y)]
	if _created_sign_positions.has(pos_key):
		return
	# Find nearest tram segment from SEPARATE tram hash (not road hash!)
	var cell_x := int(floor(pos.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(pos.y / ROAD_CELL_SIZE))
	var best_seg: Dictionary = {}
	var best_dist := 999.0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			# Search all chunk tram hashes
			for ck in _chunk_tram_hashes:
				var th: Dictionary = _chunk_tram_hashes[ck]
				if not th.has(key):
					continue
				for seg in th[key]:
					var closest := Geometry2D.get_closest_point_to_segment(pos, seg.p1, seg.p2)
					var dist: float = pos.distance_to(closest)
					if dist < best_dist:
						best_dist = dist
						best_seg = seg
	if best_seg.is_empty() or best_dist > 30.0:
		return
	_created_sign_positions[pos_key] = true
	var road_dir: Vector2 = (best_seg.p2 - best_seg.p1).normalized()
	var half_w: float = best_seg.width / 2.0
	# Project tram_stop onto track center, offset OUTWARD (left perp = always away from corridor center)
	var closest := Geometry2D.get_closest_point_to_segment(pos, best_seg.p1, best_seg.p2)
	var left_perp := Vector2(-road_dir.y, road_dir.x)
	var sign_pos: Vector2 = closest + left_perp * (half_w + 0.2)
	# Face oncoming tram (opposite of travel direction)
	var rotation_y: float = atan2(-road_dir.x, -road_dir.y)
	_infrastructure_queue.append({
		"type": "tram_stop_sign",
		"pos": sign_pos,
		"elevation": 0.0,
		"parent": parent,
		"rotation": rotation_y,
		"chunk_key": chunk_key
	})


func _create_tram_stop_sign_immediate(pos: Vector2, elevation: float, rotation_y: float, parent: Node3D) -> void:
	if not is_instance_valid(parent):
		return
	var body := RigidBody3D.new()
	body.name = "TramStopSign"
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

	# Лицевая сторона знака (текстура трамвайной остановки)
	var sign_front := MeshInstance3D.new()
	var front_mesh := QuadMesh.new()
	front_mesh.size = Vector2(0.6, 0.6)
	sign_front.mesh = front_mesh
	sign_front.material_override = _tram_stop_sign_front_mat
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
	if texture_key == "grass" and natural_type not in ["wood", "tree_row"]:
		return

	# Клипаем полигон по границам чанка
	var chunk_key := _get_chunk_key_from_node(parent)
	var clipped_polys := _clip_polygon_to_chunk(points, chunk_key)
	for clipped in clipped_polys:
		if is_water and enable_water:
			# Water mesh + shore are now rendered globally per chunk in
			# _create_deferred_terrain — that handles chunks deep inside a
			# huge polygon (whose data didn't return the way at all) the
			# same as chunks holding boundary nodes. Just register it.
			pass
		elif texture_key != "grass" and not is_water and enable_vegetation:
			# Skip land polygons (forest, etc.) whose centroid sits inside a
			# registered water polygon — OSM occasionally has natural=wood
			# overlapping rivers/reservoirs, and the green forest mesh at
			# Y=elev-0.02 would otherwise hide the water at Y=elev+WATER_Y.
			var clipped_center := _get_polygon_center(clipped)
			if not _is_point_in_water(clipped_center, chunk_key):
				_create_polygon_mesh_with_texture(clipped, texture_key, -0.02, parent, false)
		# Генерируем густые деревья внутри лесных полигонов
		if natural_type in ["wood", "tree_row"]:
			_generate_trees_in_polygon(clipped, parent, true)


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

	# Клипаем полигон по границам чанка
	var chunk_key := _get_chunk_key_from_node(parent)

	# Индустриальные и коммерческие зоны - рисуем забор и генерируем здания внутри
	if landuse_type in ["industrial", "commercial"]:
		var clipped_ind := _clip_polygon_to_chunk(points, chunk_key)
		for clipped in clipped_ind:
			_add_fence_to_batch(clipped, parent)
			_generate_industrial_buildings(clipped, parent)
		return

	var texture_key := "grass"
	var is_water := false
	match landuse_type:
		"residential":
			texture_key = "grass"
		"farmland", "farm":
			texture_key = "grass"
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
	var has_tree_override := false
	var dense_override := false
	if _decoration_layer and way_id > 0:
		var tree_override = _decoration_layer.get_landuse_tree_override(way_id)
		if tree_override:
			has_tree_override = true
			dense_override = tree_override.get("dense", false)

	# Трава уже покрыта per-chunk terrain, пропускаем чтобы не было z-fighting
	if texture_key == "grass" and not has_tree_override and landuse_type != "forest":
		return

	var clipped_polys := _clip_polygon_to_chunk(points, chunk_key)
	for clipped in clipped_polys:
		if has_tree_override:
			_generate_trees_in_polygon(clipped, parent, dense_override)
		if is_water and enable_water:
			# See _create_natural_immediate: water mesh + shore is rendered
			# globally in _create_deferred_terrain, not per-immediate-poly.
			pass
		elif texture_key != "grass" and not is_water and enable_vegetation:
			var clipped_center := _get_polygon_center(clipped)
			if not _is_point_in_water(clipped_center, chunk_key):
				_create_polygon_mesh_with_texture(clipped, texture_key, -0.02, parent, false)
		if landuse_type == "forest":
			_generate_trees_in_polygon(clipped, parent, true)


## Немедленное создание объекта отдыха (вызывается из очереди)
func _create_leisure_immediate(nodes: Array, tags: Dictionary, parent: Node3D, way_id: int = 0) -> void:
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

	# Клипаем полигон по границам чанка
	var chunk_key := _get_chunk_key_from_node(parent)
	var clipped_polys := _clip_polygon_to_chunk(points, chunk_key)

	# Забор для конкретных парков по way_id
	var fenced_parks := [307915405, 45550044]  # Парк Серпантин, Парк 200-летия Череповца

	for clipped in clipped_polys:
		# Добавляем коллизию с группой Park для высокого сопротивления качению
		if leisure_type in ["park", "garden", "pitch"]:
			_create_park_collision(clipped, parent)
		# Генерируем деревья в парках и садах
		if leisure_type in ["park", "garden"]:
			_generate_trees_in_polygon(clipped, parent, false)
		# Забор для указанных парков
		if way_id in fenced_parks:
			_add_fence_to_batch(clipped, parent)

	# Трава уже покрыта per-chunk terrain, пропускаем чтобы не было z-fighting
	if texture_key == "grass":
		return

	for clipped in clipped_polys:
		if is_water and enable_water:
			_register_water_polygon(clipped, parent)
			_create_polygon_mesh_with_texture(clipped, "water", WATER_Y, parent, true)
			_create_shore_mesh(clipped, parent)
		elif not is_water and enable_vegetation:
			_create_polygon_mesh_with_texture(clipped, texture_key, -0.02, parent, false)

func _create_amenity_building(nodes: Array, tags: Dictionary, parent: Node3D, loader: Node, skip_spatial_hash: bool = false) -> void:
	if nodes.size() < 3:
		return

	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	# Сохраняем рёбра для проверки расстояния при генерации деревьев
	if not skip_spatial_hash:
		var am_ck := _get_chunk_key_from_node(parent)
		for i in range(points.size()):
			var p1 := points[i]
			var p2 := points[(i + 1) % points.size()]
			var seg := {"p1": p1, "p2": p2}
			_add_building_segment_to_spatial_hash(seg, am_ck)
		_add_building_poly_to_hash(points, am_ck)

	var amenity_type: String = str(tags.get("amenity", ""))

	# Территории (школы, детсады, университеты, пожарные станции, полиция) - рисуем забор, а не здание
	# Здание внутри рисуется отдельно если есть building тег
	if amenity_type in ["school", "kindergarten", "college", "university", "fire_station", "police"]:
		_add_fence_to_batch(points, parent)
		return

	# Заправки не создаём как здания
	if amenity_type == "fuel":
		return

	# Парковки обрабатываем отдельно
	if amenity_type == "parking":
		var pk_ck := _get_chunk_key_from_node(parent)
		_create_parking(points, parent, pk_ck)
		return

	# Остальные amenity - создаём как маленькие здания (через thread pool)
	var building_height: float = 8.0
	match amenity_type:
		"hospital":
			building_height = 18.0
		"clinic":
			building_height = 12.0
		"police", "fire_station":
			building_height = 10.0
		"place_of_worship", "church":
			building_height = 20.0
		"bank":
			building_height = 12.0
		"post_office":
			building_height = 8.0
		"restaurant", "cafe", "fast_food", "bar", "pub":
			building_height = 5.0
		"theatre", "cinema":
			building_height = 15.0
		"library":
			building_height = 10.0

	# Use threaded building generation (same as regular buildings) to avoid main thread stalls
	_queue_building_for_thread(points, building_height, "brick", parent, 0.0)


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

	# Elevation at endpoints
	var elev1 := _sample_elevation(p1.x, p1.y)
	var elev2 := _sample_elevation(p2.x, p2.y)

	# Posts at both ends — into both LODs
	var p1_c := Vector3(p1.x, center_y + elev1, p1.y)
	var p2_c := Vector3(p2.x, center_y + elev2, p2.y)
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
			var elev_t := lerpf(elev1, elev2, t)
			var bc := Vector3(bp.x, center_y + elev_t, bp.y)
			_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, bc, bar_hs, fwd, right)
			if i % 2 == 0:
				_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, bc, bar_hs, fwd, right)

	# Horizontal rails (both LODs)
	var mid := p1.lerp(p2, 0.5)
	var elev_mid := (elev1 + elev2) * 0.5
	var rail_hs := Vector3(RAIL_HS_Z, RAIL_HS_Y, seg_len * 0.5)
	# Bottom rail
	var rc_bot := Vector3(mid.x, BASE_Y + BOTTOM_RAIL_Y + elev_mid, mid.y)
	_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, rc_bot, rail_hs, fwd, right)
	_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, rc_bot, rail_hs, fwd, right)
	# Top rail
	var rc_top := Vector3(mid.x, BASE_Y + TOP_RAIL_Y + elev_mid, mid.y)
	_append_fence_box(lod0.vertices, lod0.normals, lod0.indices, rc_top, rail_hs, fwd, right)
	_append_fence_box(lod1.vertices, lod1.normals, lod1.indices, rc_top, rail_hs, fwd, right)


## Add iron bar fence along polyline to chunk batch (deferred — queues edges for incremental processing)
func _add_fence_to_batch(points: PackedVector2Array, parent: Node3D) -> void:
	if not enable_fences:
		return
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

	# Queue all edges for deferred incremental processing
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]

		var dir := (p2 - p1).normalized()
		var outward := Vector2(-dir.y, dir.x) * fence_offset
		p1 = p1 + outward
		p2 = p2 + outward

		var seg_len := p1.distance_to(p2)
		if seg_len < 0.5:
			continue

		batch.edges.append({"p1": p1, "p2": p2})
		_deferred_append(_deferred_fence_edges, chunk_key, {"chunk_key": chunk_key, "p1": p1, "p2": p2, "edge_idx": i})

	if not _fence_batches_to_finalize.has(chunk_key):
		_fence_batches_to_finalize.append(chunk_key)


## Process deferred fence edges incrementally (time-budgeted)
## Each edge is subdivided into ~2.25m sections with _generate_fence_segment calls
## Supports mid-edge resume via _fence_edge_cursor (section index within current edge)
var _fence_edge_cursor: int = 0  # section index within current edge (for mid-edge resume)

func _process_deferred_fence_edges(start_usec: int, budget_usec: int) -> void:
	var fe_done_keys: Array[String] = []
	for fe_ck in _get_prioritized_keys(_deferred_fence_edges):
		var fe_arr: Array = _deferred_fence_edges[fe_ck]
		while not fe_arr.is_empty():
			var item: Dictionary = fe_arr[0]
			var chunk_key: String = item.chunk_key

			# Skip if chunk was unloaded
			if not _fence_geo_batch.has(chunk_key):
				fe_arr.pop_front()
				_fence_edge_cursor = 0
				continue

			var batch: Dictionary = _fence_geo_batch[chunk_key]
			var p1: Vector2 = item.p1
			var p2: Vector2 = item.p2
			var edge_idx: int = item.edge_idx
			var seg_len := p1.distance_to(p2)
			var num_sections := maxi(1, int(round(seg_len / 2.25)))

			# Process sections starting from cursor (supports mid-edge resume)
			while _fence_edge_cursor < num_sections:
				if (Time.get_ticks_usec() - start_usec) > budget_usec:
					return  # Budget exhausted, resume next frame from _fence_edge_cursor
				var j := _fence_edge_cursor
				var t1 := float(j) / float(num_sections)
				var t2 := float(j + 1) / float(num_sections)
				var sp1 := p1.lerp(p2, t1)
				var sp2 := p1.lerp(p2, t2)
				var seed_val := int(sp1.x * 1000.0) ^ int(sp1.y * 1000.0) ^ (edge_idx * 997 + j)
				_generate_fence_segment(sp1, sp2, batch.lod0, batch.lod1, seed_val)
				_fence_edge_cursor += 1

			# Edge fully processed
			fe_arr.pop_front()
			_fence_edge_cursor = 0
		if fe_arr.is_empty():
			fe_done_keys.append(fe_ck)
	for fe_ck in fe_done_keys:
		_deferred_fence_edges.erase(fe_ck)


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
		# LOD1: no vis_max (always visible while chunk loaded). Godot computes
		# visibility_range distance from camera to AABB center — per-chunk fence
		# batches produce large AABBs whose center can be 100m+ from any actual
		# fence, causing vis_max=150 to cull the mesh even when standing next to it.
		# Chunk unload at 700m provides natural distance culling instead.
		_rs_add_mesh(chunk_key, mesh, _fence_material,
			RenderingServer.SHADOW_CASTING_SETTING_OFF, 0.0, 50.0)

	# Collision: build StaticBody3D with shapes off-tree, then add once
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
			box.size = Vector3(elen, 2.2, 0.08)
			collision.shape = box
			var col_elev := _sample_elevation(mid.x, mid.y)
			collision.position = Vector3(mid.x, col_elev + 0.12 + 1.1, mid.y)
			collision.rotation.y = -angle
			body.add_child(collision)
		# Defer adding body to scene tree to spread cost
		_deferred_add_child_queue.append({"parent": batch.parent, "child": body})

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

		var h1 := _sample_elevation(p1.x, p1.y) + 0.12
		var h2 := _sample_elevation(p2.x, p2.y) + 0.12

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

		var h1 := _sample_elevation(p1.x, p1.y) + 0.12
		var h2 := _sample_elevation(p2.x, p2.y) + 0.12
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

## Конвертирует линию водотока + ширину в замкнутый полигон (для рендера и клиппинга)
func _waterway_to_polygon(points: PackedVector2Array, width: float) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var half_w := width * 0.5
	var left_side: PackedVector2Array = []
	var right_side: PackedVector2Array = []
	for i in range(points.size()):
		var dir: Vector2
		if i == 0:
			dir = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			dir = (points[i] - points[i - 1]).normalized()
		else:
			dir = (points[i + 1] - points[i - 1]).normalized()
		var perp := Vector2(-dir.y, dir.x) * half_w
		left_side.append(points[i] + perp)
		right_side.append(points[i] - perp)
	# Замыкаем: left forward + right backward
	var result: PackedVector2Array = []
	for p in left_side:
		result.append(p)
	for i in range(right_side.size() - 1, -1, -1):
		result.append(right_side[i])
	return result


## Registers a water polygon globally (deduped by hash) so every chunk's
## terrain cutout / lookup can see it, even if its OSM data didn't return
## the way (huge polygons appear only in chunks holding a boundary node).
func _register_global_water_polygon(full_points: PackedVector2Array) -> void:
	if full_points.size() < 3:
		return
	# Cheap hash: first 3 points (32-bit fixed-point) — stable across chunks
	# that all derive coords from the same start_lat/start_lon.
	var h: int = 0
	for i in range(mini(3, full_points.size())):
		h = (h * 1000003) ^ int(full_points[i].x * 1000.0)
		h = (h * 1000003) ^ int(full_points[i].y * 1000.0)
	if _global_water_polygon_hashes.has(h):
		return
	_global_water_polygon_hashes[h] = _global_water_polygons.size()
	_global_water_polygons.append(full_points)
	# Compute AABB for fast polygon-skip in lookups.
	var min_x := full_points[0].x
	var max_x := min_x
	var min_y := full_points[0].y
	var max_y := min_y
	for p in full_points:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	_global_water_polygon_bboxes.append(Rect2(min_x, min_y, max_x - min_x, max_y - min_y))


## Регистрирует водный полигон в _chunk_water_polygons для terrain clipping и per-chunk spatial hash
func _register_water_polygon(points: PackedVector2Array, parent: Node3D) -> void:
	var ck := _get_chunk_key_from_node(parent)
	if ck.is_empty():
		return
	if not _chunk_water_polygons.has(ck):
		_chunk_water_polygons[ck] = []
	_chunk_water_polygons[ck].append(points)

	# Per-chunk water hash
	if not _chunk_water_hashes.has(ck):
		_chunk_water_hashes[ck] = {"hash": {}, "polys": []}
	var cw_data: Dictionary = _chunk_water_hashes[ck]
	var cw_hash: Dictionary = cw_data["hash"]
	var cw_polys: Array = cw_data["polys"]
	var local_water_idx: int = cw_polys.size()
	cw_polys.append(points)
	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var seg_min_x := minf(p1.x, p2.x)
		var seg_max_x := maxf(p1.x, p2.x)
		var seg_min_y := minf(p1.y, p2.y)
		var seg_max_y := maxf(p1.y, p2.y)
		var cell_min_x := int(floor(seg_min_x / WATER_CELL_SIZE))
		var cell_max_x := int(floor(seg_max_x / WATER_CELL_SIZE))
		var cell_min_y := int(floor(seg_min_y / WATER_CELL_SIZE))
		var cell_max_y := int(floor(seg_max_y / WATER_CELL_SIZE))
		for cx in range(cell_min_x, cell_max_x + 1):
			for cy in range(cell_min_y, cell_max_y + 1):
				var cell := Vector2i(cx, cy)
				if not cw_hash.has(cell):
					cw_hash[cell] = []
				cw_hash[cell].append({"idx": local_water_idx, "p1": p1, "p2": p2})


## Генерирует наклонный берег вокруг водного полигона (от Y=0.22 до Y=-1.0)
func _create_shore_mesh(water_poly: PackedVector2Array, parent: Node3D) -> void:
	if water_poly.size() < 3:
		return
	# Убираем дубликат последней точки
	var poly := PackedVector2Array(water_poly)
	if poly.size() > 1 and poly[0].distance_to(poly[poly.size() - 1]) < 0.1:
		poly.remove_at(poly.size() - 1)
	if poly.size() < 3:
		return

	# Get chunk rect to skip shore on chunk boundary edges
	var shore_ck := _get_chunk_key_from_node(parent)
	var chunk_rect := Rect2()
	var has_chunk_rect := false
	if not shore_ck.is_empty():
		chunk_rect = _get_chunk_rect_from_key(shore_ck)
		has_chunk_rect = true

	var pn := poly.size()
	var sidewalk_h := 0.22  # Верхний край берега (уровень тротуара/террейна)
	var water_h := WATER_Y  # Нижний край берега (уровень воды)

	# Определяем направление полигона для правильной ориентации наружных нормалей
	var ccw := _is_polygon_ccw(poly)
	var out_sign := 1.0 if ccw else -1.0

	# Вычисляем miter-точки для внешнего контура (расширение на SHORE_WIDTH)
	var outer: PackedVector2Array = PackedVector2Array()
	outer.resize(pn)
	for vi in range(pn):
		var d_prev := (poly[vi] - poly[(vi - 1 + pn) % pn]).normalized()
		var d_next := (poly[(vi + 1) % pn] - poly[vi]).normalized()
		var out_prev := Vector2(d_prev.y, -d_prev.x) * out_sign
		var out_next := Vector2(d_next.y, -d_next.x) * out_sign
		var avg := out_prev + out_next
		if avg.length_squared() > 0.001:
			var n := avg.normalized()
			var dot := n.dot(out_next)
			if dot > 0.2:
				outer[vi] = poly[vi] + n * (SHORE_WIDTH / dot)
			else:
				outer[vi] = poly[vi] + out_next * SHORE_WIDTH
		else:
			outer[vi] = poly[vi] + Vector2(d_next.y, -d_next.x) * out_sign * SHORE_WIDTH
		# Ограничиваем miter чтобы не было слишком длинных шипов
		if outer[vi].distance_to(poly[vi]) > SHORE_WIDTH * 3.0:
			var dir_out := (outer[vi] - poly[vi]).normalized()
			outer[vi] = poly[vi] + dir_out * SHORE_WIDTH * 3.0

	# Генерируем slope mesh: для каждого ребра — quad (2 треугольника)
	# Outer edge на Y=sidewalk_h, inner edge (water_poly) на Y=water_h
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idxs := PackedInt32Array()

	# Chunk boundary tolerance for edge detection
	var edge_tol := 0.5  # meters

	# Other water polygons in this chunk — used to skip shore edges that face
	# open water (e.g. narrow river strip embedded inside the reservoir).
	# Restored from 53b0537 — depends on call_deferred so larger polygon was
	# registered earlier this frame.
	var other_water_polys: Array = []
	if not shore_ck.is_empty():
		for ex: PackedVector2Array in _chunk_water_polygons.get(shore_ck, []):
			if ex.size() >= 3 and ex != poly:
				other_water_polys.append(ex)

	for ei in range(pn):
		var i0 := ei
		var i1 := (ei + 1) % pn

		# Skip edges that lie on chunk boundary (both vertices on same boundary edge)
		if has_chunk_rect:
			var p0 := poly[i0]
			var p1 := poly[i1]
			var rx := chunk_rect.position.x
			var rz := chunk_rect.position.y
			var rx2 := rx + chunk_rect.size.x
			var rz2 := rz + chunk_rect.size.y
			# Both on left edge
			if absf(p0.x - rx) < edge_tol and absf(p1.x - rx) < edge_tol:
				continue
			# Both on right edge
			if absf(p0.x - rx2) < edge_tol and absf(p1.x - rx2) < edge_tol:
				continue
			# Both on top edge
			if absf(p0.y - rz) < edge_tol and absf(p1.y - rz) < edge_tol:
				continue
			# Both on bottom edge
			if absf(p0.y - rz2) < edge_tol and absf(p1.y - rz2) < edge_tol:
				continue
		# Inner = water edge, outer = shore top edge
		var in0 := poly[i0]
		var in1 := poly[i1]
		var out0 := outer[i0]
		var out1 := outer[i1]

		# Skip shore edge if its outer-top midpoint is inside another water
		# polygon (this edge is not a real shoreline — it's facing open water).
		if not other_water_polys.is_empty():
			var mid := (out0 + out1) * 0.5
			var in_other := false
			for ow: PackedVector2Array in other_water_polys:
				if Geometry2D.is_point_in_polygon(mid, ow):
					in_other = true
					break
			if in_other:
				continue
		# Нормаль наклонной поверхности (примерно 45° наружу-вверх)
		var edge_dir := (in1 - in0).normalized()
		var outward_2d := Vector2(edge_dir.y, -edge_dir.x) * out_sign
		# Slope normal: outward + up, normalized
		var slope_normal := Vector3(outward_2d.x, 1.0, outward_2d.y).normalized()

		var ci := verts.size()
		# 4 вершины: out0_top, out1_top, in1_bottom, in0_bottom
		var elev_out0 := _sample_elevation(out0.x, out0.y)
		var elev_out1 := _sample_elevation(out1.x, out1.y)
		var elev_in0 := _sample_elevation(in0.x, in0.y)
		var elev_in1 := _sample_elevation(in1.x, in1.y)
		verts.append(Vector3(out0.x, elev_out0 + sidewalk_h, out0.y))
		verts.append(Vector3(out1.x, elev_out1 + sidewalk_h, out1.y))
		verts.append(Vector3(in1.x, elev_in1 + water_h, in1.y))
		verts.append(Vector3(in0.x, elev_in0 + water_h, in0.y))
		for _j in 4:
			norms.append(slope_normal)
		# UV: горизонтальная длина и вертикальная от 0 (верх) до 1 (низ)
		var seg_len := out0.distance_to(out1)
		uvs.append(Vector2(0.0, 0.0))
		uvs.append(Vector2(seg_len * 0.25, 0.0))
		uvs.append(Vector2(seg_len * 0.25, 1.0))
		uvs.append(Vector2(0.0, 1.0))
		# Два треугольника: 0,2,1 и 0,3,2
		idxs.append(ci + 0); idxs.append(ci + 2); idxs.append(ci + 1)
		idxs.append(ci + 0); idxs.append(ci + 3); idxs.append(ci + 2)

	if verts.is_empty():
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idxs

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Материал: земля/песок
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.35, 0.25)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var ck := _get_chunk_key_from_node(parent)
	if not ck.is_empty():
		_rs_add_mesh(ck, arr_mesh, material)
	else:
		var mesh := MeshInstance3D.new()
		mesh.mesh = arr_mesh
		mesh.material_override = material
		parent.add_child(mesh)

	# Коллизия для берега (чтобы машина могла ехать по склону)
	var shore_body := StaticBody3D.new()
	shore_body.name = "ShoreCollision"
	shore_body.collision_layer = 1
	shore_body.collision_mask = 0
	shore_body.add_to_group("Grass")
	var faces := PackedVector3Array()
	for i in range(0, idxs.size(), 3):
		faces.append(verts[idxs[i]])
		faces.append(verts[idxs[i + 1]])
		faces.append(verts[idxs[i + 2]])
	var col_shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	col_shape.shape = concave
	shore_body.add_child(col_shape)
	parent.add_child(shore_body)


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

	# Конвертируем центральную линию в полигон
	var points: PackedVector2Array = []
	for node in nodes:
		var local: Vector2 = _latlon_to_local(node.lat, node.lon)
		points.append(local)

	var poly := _waterway_to_polygon(points, width)
	if poly.size() < 3:
		return

	# Клипаем полигон по границам чанка
	var chunk_key := _get_chunk_key_from_node(parent)
	var clipped_polys := _clip_polygon_to_chunk(poly, chunk_key)
	for clipped in clipped_polys:
		_register_water_polygon(clipped, parent)
		_create_polygon_mesh_with_texture(clipped, "water", WATER_Y, parent, true)
		# No shore for waterway=* lines: rivers/canals/streams are typically
		# inside a larger natural=water polygon (which has its own shore), or
		# they are too narrow to want banks of their own. Drawing shore here
		# put two brown stripes through the middle of every big river.

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
	fnd_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(points.size()):
		var fp1 := points[i]
		var fp2 := points[(i + 1) % points.size()]
		var fdir := Vector2(fp2.x - fp1.x, fp2.y - fp1.y).normalized()
		var fnorm := Vector3(-fdir.y * normal_sign, 0, fdir.x * normal_sign)
		fnd_im.surface_set_normal(fnorm)
		var fb1 := _sample_elevation(fp1.x, fp1.y) - FOUNDATION_DEPTH
		var fb2 := _sample_elevation(fp2.x, fp2.y) - FOUNDATION_DEPTH
		var fv1 := Vector3(fp1.x, fnd_top, fp1.y)
		var fv2 := Vector3(fp2.x, fnd_top, fp2.y)
		var fv3 := Vector3(fp2.x, fb2, fp2.y)
		var fv4 := Vector3(fp1.x, fb1, fp1.y)
		fnd_im.surface_add_vertex(fv1)
		fnd_im.surface_add_vertex(fv2)
		fnd_im.surface_add_vertex(fv3)
		fnd_im.surface_add_vertex(fv1)
		fnd_im.surface_add_vertex(fv3)
		fnd_im.surface_add_vertex(fv4)
	# Bottom cap — seal foundation from below
	var bottom_indices := Geometry2D.triangulate_polygon(points)
	if bottom_indices.size() >= 3:
		fnd_im.surface_set_normal(Vector3.DOWN)
		var cap_y := base_elev - FOUNDATION_CAP_DEPTH
		for i in range(0, bottom_indices.size(), 3):
			var bp1 := points[bottom_indices[i]]
			var bp2 := points[bottom_indices[i + 1]]
			var bp3 := points[bottom_indices[i + 2]]
			fnd_im.surface_add_vertex(Vector3(bp1.x, cap_y, bp1.y))
			fnd_im.surface_add_vertex(Vector3(bp3.x, cap_y, bp3.y))
			fnd_im.surface_add_vertex(Vector3(bp2.x, cap_y, bp2.y))
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
	# Pre-compute per-vertex foundation bottoms (main thread has elevation access)
	var fnd_bottoms := PackedFloat32Array()
	fnd_bottoms.resize(points.size())
	for i in range(points.size()):
		fnd_bottoms[i] = _sample_elevation(points[i].x, points[i].y) - FOUNDATION_DEPTH
	var task_data := {
		"points": points,
		"building_height": building_height,
		"texture_type": texture_type,
		"parent": parent,
		"base_elev": base_elev,
		"distance_to_player": distance_to_player,  # For shadow LOD
		"fnd_bottoms": fnd_bottoms,
	}

	# Добавляем задачу в пул потоков
	_pending_building_tasks += 1
	WorkerThreadPool.add_task(_compute_building_mesh_thread.bind(task_data))


## Вычисляет геометрию здания в worker thread (без создания Node)
func _compute_building_mesh_thread(task_data: Dictionary) -> void:
	var points: PackedVector2Array = task_data.points
	var building_height: float = task_data.building_height
	var base_elev: float = task_data.base_elev
	var fnd_bottoms: PackedFloat32Array = task_data.get("fnd_bottoms", PackedFloat32Array())

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

	var uv_scale_x := 0.4  # 1 UV unit = 2.5m (PBR кирпичные текстуры ~1м на тайл)
	var uv_scale_y := 0.4
	var accumulated_width := 0.0

	# Определяем направление полигона для корректных нормалей
	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	var wnd_num_floors := int(building_height / WINDOW_FLOOR_HEIGHT)
	var wnd_half := WINDOW_SIZE * 0.5

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var wall_width := p1.distance_to(p2)

		var dir := (p2 - p1).normalized()
		var normal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)
		var dir3 := Vector3(dir.x, 0.0, dir.y)

		var u_left := accumulated_width * uv_scale_x
		var v_bottom_uv := 0.0

		# Compute window positions for this wall segment
		var win_positions: Array[float] = []  # along-wall center offsets
		if wall_width >= WINDOW_SPACING and wnd_num_floors >= 1:
			var wnd_count := int((wall_width - WINDOW_SPACING * 0.5) / WINDOW_SPACING)
			if wnd_count < 1:
				wnd_count = 1
			var wnd_start := (wall_width - (wnd_count - 1) * WINDOW_SPACING) / 2.0
			for wi in range(wnd_count):
				win_positions.append(wnd_start + wi * WINDOW_SPACING)

		if win_positions.is_empty() or wnd_num_floors < 1:
			# No windows — single quad as before
			var v1 := Vector3(p1.x, foundation_y, p1.y)
			var v2 := Vector3(p2.x, foundation_y, p2.y)
			var v3 := Vector3(p2.x, roof_y, p2.y)
			var v4 := Vector3(p1.x, roof_y, p1.y)
			var u_right := (accumulated_width + wall_width) * uv_scale_x
			var v_top_uv := building_height * uv_scale_y
			var idx := wall_vertices.size()
			wall_vertices.append(v1)
			wall_vertices.append(v2)
			wall_vertices.append(v3)
			wall_vertices.append(v4)
			wall_uvs.append(Vector2(u_left, v_bottom_uv))
			wall_uvs.append(Vector2(u_right, v_bottom_uv))
			wall_uvs.append(Vector2(u_right, v_top_uv))
			wall_uvs.append(Vector2(u_left, v_top_uv))
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
		else:
			# Build horizontal cut lines (Y values relative to foundation_y)
			# Cutout is WINDOW_CUT_MARGIN larger than window on each side
			var cut_half := wnd_half + WINDOW_CUT_MARGIN
			var y_cuts: Array[float] = [0.0]  # start at foundation
			for fl in range(wnd_num_floors):
				var win_center_y := WINDOW_FLOOR_HEIGHT * 0.5 + fl * WINDOW_FLOOR_HEIGHT
				y_cuts.append(win_center_y - cut_half)
				y_cuts.append(win_center_y + cut_half)
			y_cuts.append(building_height - (foundation_y - base_elev))  # roof relative
			y_cuts.sort()

			# Build vertical cut lines (along-wall offsets)
			var x_cuts: Array[float] = [0.0]
			for wp in win_positions:
				x_cuts.append(wp - cut_half)
				x_cuts.append(wp + cut_half)
			x_cuts.append(wall_width)
			x_cuts.sort()

			# For each grid cell, check if it's a window hole or wall
			var p1_3d := Vector3(p1.x, 0.0, p1.y)
			for yi in range(y_cuts.size() - 1):
				var y0 := y_cuts[yi]
				var y1 := y_cuts[yi + 1]
				if y1 - y0 < 0.001:
					continue
				for xi in range(x_cuts.size() - 1):
					var x0 := x_cuts[xi]
					var x1 := x_cuts[xi + 1]
					if x1 - x0 < 0.001:
						continue

					# Check if this cell is a window hole (using cut_half for larger cutout)
					var is_window := false
					var cell_cx := (x0 + x1) * 0.5
					var cell_cy := (y0 + y1) * 0.5
					for wp in win_positions:
						if absf(cell_cx - wp) < cut_half - 0.01:
							for fl in range(wnd_num_floors):
								var wy := WINDOW_FLOOR_HEIGHT * 0.5 + fl * WINDOW_FLOOR_HEIGHT
								if absf(cell_cy - wy) < cut_half - 0.01:
									is_window = true
									break
						if is_window:
							break

					if is_window:
						continue  # Skip — this is a hole

					# Emit wall quad for this cell
					var va := p1_3d + dir3 * x0 + Vector3.UP * (foundation_y + y0)
					var vb := p1_3d + dir3 * x1 + Vector3.UP * (foundation_y + y0)
					var vc := p1_3d + dir3 * x1 + Vector3.UP * (foundation_y + y1)
					var vd := p1_3d + dir3 * x0 + Vector3.UP * (foundation_y + y1)

					var ua := (accumulated_width + x0) * uv_scale_x
					var ub := (accumulated_width + x1) * uv_scale_x
					var va_v := y0 * uv_scale_y
					var vb_v := y1 * uv_scale_y

					var idx := wall_vertices.size()
					wall_vertices.append(va)
					wall_vertices.append(vb)
					wall_vertices.append(vc)
					wall_vertices.append(vd)
					wall_uvs.append(Vector2(ua, va_v))
					wall_uvs.append(Vector2(ub, va_v))
					wall_uvs.append(Vector2(ub, vb_v))
					wall_uvs.append(Vector2(ua, vb_v))
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

	# === WINDOW RECESS GEOMETRY (углубления вокруг окон) ===
	var recess_vertices := PackedVector3Array()
	var recess_uvs := PackedVector2Array()
	var recess_normals := PackedVector3Array()
	var recess_indices := PackedInt32Array()
	var recess_colors := PackedColorArray()

	if wnd_num_floors >= 1:
		# RNG для цветов окон — seed должен совпадать с _add_building_windows
		var center := Vector2.ZERO
		for p in points:
			center += p
		center /= float(points.size())
		var wnd_rng := RandomNumberGenerator.new()
		wnd_rng.seed = hash(Vector2(center.x, center.y)) ^ 0x57494E44  # WIND
		var off_percent := 0.30 + wnd_rng.randf() * 0.50
		var phyto_percent := 0.03 + wnd_rng.randf() * 0.02
		var warm_cold_colors: Array[Color] = [
			Color(1.0, 0.85, 0.5), Color(1.0, 0.9, 0.6), Color(1.0, 0.95, 0.75),
			Color(0.95, 0.92, 0.85), Color(0.9, 0.92, 0.95), Color(0.85, 0.9, 1.0),
			Color(0.75, 0.85, 1.0),
		]
		var phyto_color := Color(0.9, 0.2, 0.9)

		for i in range(points.size()):
			var rp1 := points[i]
			var rp2 := points[(i + 1) % points.size()]
			var rwall_length := rp1.distance_to(rp2)
			if rwall_length < WINDOW_SPACING:
				continue

			var rwall_dir_2d := (rp2 - rp1).normalized()
			var rwall_normal_2d := Vector2(-rwall_dir_2d.y * normal_sign, rwall_dir_2d.x * normal_sign)
			var rwall_dir_3d := Vector3(rwall_dir_2d.x, 0.0, rwall_dir_2d.y)
			var rwall_normal_3d := Vector3(rwall_normal_2d.x, 0.0, rwall_normal_2d.y)
			var inward := -rwall_normal_3d * WINDOW_RECESS_DEPTH

			var rnum_windows := int((rwall_length - WINDOW_SPACING * 0.5) / WINDOW_SPACING)
			if rnum_windows < 1:
				rnum_windows = 1
			var rstart_offset := (rwall_length - (rnum_windows - 1) * WINDOW_SPACING) / 2.0

			for floor_idx in range(wnd_num_floors):
				var y_center := foundation_y + WINDOW_FLOOR_HEIGHT * 0.5 + floor_idx * WINDOW_FLOOR_HEIGHT
				for win_idx in range(rnum_windows):
					var along_wall := rstart_offset + win_idx * WINDOW_SPACING
					var wall_pos := rp1 + rwall_dir_2d * along_wall
					var center_3d := Vector3(wall_pos.x, y_center, wall_pos.y)

					# Window color (same algorithm as _add_building_windows)
					var wnd_color := Color.BLACK
					var chance := wnd_rng.randf()
					if chance < off_percent:
						wnd_color = Color.BLACK  # off
					elif chance < (1.0 - phyto_percent):
						wnd_color = warm_cold_colors[wnd_rng.randi() % warm_cold_colors.size()]
						wnd_color.a = 0.15 + wnd_rng.randf() * 0.35
					else:
						wnd_color = phyto_color
						wnd_color.a = 0.25 + wnd_rng.randf() * 0.25
					# Premultiply brightness into RGB for vertex color
					var emit_color := Color(wnd_color.r * wnd_color.a, wnd_color.g * wnd_color.a, wnd_color.b * wnd_color.a, 1.0)

					# Outer corners (on wall surface) — larger by WINDOW_CUT_MARGIN
					var cut_h := wnd_half + WINDOW_CUT_MARGIN
					var outer_tl := center_3d - rwall_dir_3d * cut_h + Vector3.UP * cut_h
					var outer_tr := center_3d + rwall_dir_3d * cut_h + Vector3.UP * cut_h
					var outer_bl := center_3d - rwall_dir_3d * cut_h - Vector3.UP * cut_h
					var outer_br := center_3d + rwall_dir_3d * cut_h - Vector3.UP * cut_h

					# Inner corners (at recess depth) — exact window size
					var inner_tl := center_3d - rwall_dir_3d * wnd_half + Vector3.UP * wnd_half + inward
					var inner_tr := center_3d + rwall_dir_3d * wnd_half + Vector3.UP * wnd_half + inward
					var inner_bl := center_3d - rwall_dir_3d * wnd_half - Vector3.UP * wnd_half + inward
					var inner_br := center_3d + rwall_dir_3d * wnd_half - Vector3.UP * wnd_half + inward

					# Left side — trapezoid (normal ~right into cavity)
					_add_recess_quad(recess_vertices, recess_uvs, recess_normals, recess_indices,
						outer_tl, outer_bl, inner_bl, inner_tl, rwall_dir_3d, recess_colors, emit_color)
					# Right side — trapezoid (normal ~left into cavity)
					_add_recess_quad(recess_vertices, recess_uvs, recess_normals, recess_indices,
						inner_tr, inner_br, outer_br, outer_tr, -rwall_dir_3d, recess_colors, emit_color)
					# Top side — trapezoid (normal ~down into cavity)
					_add_recess_quad(recess_vertices, recess_uvs, recess_normals, recess_indices,
						inner_tl, inner_tr, outer_tr, outer_tl, -Vector3.UP, recess_colors, emit_color)
					# Bottom side — trapezoid (normal ~up into cavity)
					_add_recess_quad(recess_vertices, recess_uvs, recess_normals, recess_indices,
						outer_bl, outer_br, inner_br, inner_bl, Vector3.UP, recess_colors, emit_color)

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
	var fnd_material_idx := int(abs(points[0].x * 73.0 + points[0].y * 137.0)) % 4

	for i in range(points.size()):
		var p1 := points[i]
		var p2 := points[(i + 1) % points.size()]
		var dir := (p2 - p1).normalized()
		var fnormal := Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)
		var fb1 := fnd_bottoms[i] if i < fnd_bottoms.size() else base_elev - FOUNDATION_DEPTH
		var fb2 := fnd_bottoms[(i + 1) % points.size()] if (i + 1) % points.size() < fnd_bottoms.size() else base_elev - FOUNDATION_DEPTH

		var vi := fnd_vertices.size()
		fnd_vertices.append(Vector3(p1.x, fnd_top, p1.y))
		fnd_vertices.append(Vector3(p2.x, fnd_top, p2.y))
		fnd_vertices.append(Vector3(p2.x, fb2, p2.y))
		fnd_vertices.append(Vector3(p1.x, fb1, p1.y))
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

	# Bottom cap — seal foundation from below
	var cap_y := base_elev - FOUNDATION_CAP_DEPTH
	var bottom_tri := Geometry2D.triangulate_polygon(points)
	if bottom_tri.size() >= 3:
		for i in range(0, bottom_tri.size(), 3):
			var bp1 := points[bottom_tri[i]]
			var bp2 := points[bottom_tri[i + 1]]
			var bp3 := points[bottom_tri[i + 2]]
			var vi := fnd_vertices.size()
			fnd_vertices.append(Vector3(bp1.x, cap_y, bp1.y))
			fnd_vertices.append(Vector3(bp3.x, cap_y, bp3.y))
			fnd_vertices.append(Vector3(bp2.x, cap_y, bp2.y))
			fnd_uvs.append(Vector2(0, 0))
			fnd_uvs.append(Vector2(0, 0))
			fnd_uvs.append(Vector2(0, 0))
			fnd_normals.append(Vector3.DOWN)
			fnd_normals.append(Vector3.DOWN)
			fnd_normals.append(Vector3.DOWN)
			fnd_indices.append(vi + 0)
			fnd_indices.append(vi + 1)
			fnd_indices.append(vi + 2)

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
		"fnd_material_idx": fnd_material_idx,
		"recess_vertices": recess_vertices,
		"recess_uvs": recess_uvs,
		"recess_normals": recess_normals,
		"recess_indices": recess_indices,
		"recess_colors": recess_colors,
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
			"panel_recess": _make_empty_geo_batch(),
			"brick_recess": _make_empty_geo_batch(),
			"wall_recess": _make_empty_geo_batch(),
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

	# === НАКАПЛИВАЕМ RECESS (углубления окон) ===
	var recess_verts: PackedVector3Array = result.get("recess_vertices", PackedVector3Array())
	if recess_verts.size() > 0:
		var recess_key: String = texture_type + "_recess"
		if not batch.has(recess_key):
			recess_key = "brick_recess"
		var recess_batch: Dictionary = batch[recess_key]
		if not recess_batch.has("colors"):
			recess_batch["colors"] = PackedColorArray()
		var recess_start: int = recess_batch["vertices"].size()
		recess_batch["vertices"].append_array(recess_verts)
		recess_batch["uvs"].append_array(result.recess_uvs)
		recess_batch["normals"].append_array(result.recess_normals)
		recess_batch["colors"].append_array(result.get("recess_colors", PackedColorArray()))
		for ri in range(result.recess_indices.size()):
			recess_batch["indices"].append(result.recess_indices[ri] + recess_start)

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
	# Steps: 0-2=walls, 3=roofs, 4=parapets, 5-8=foundations, 9-11=recesses, 12=cleanup
	var surface_keys: Array[String] = ["panel_walls", "brick_walls", "wall_walls", "roofs", "parapets", "foundation_0", "foundation_1", "foundation_2", "foundation_3", "panel_recess", "brick_recess", "wall_recess"]

	if step < 12:
		var surface_key: String = surface_keys[step]
		var geo: Dictionary = batch[surface_key]
		if geo["vertices"].size() > 0:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = geo["vertices"]
			arrays[Mesh.ARRAY_TEX_UV] = geo["uvs"]
			arrays[Mesh.ARRAY_NORMAL] = geo["normals"]
			arrays[Mesh.ARRAY_INDEX] = geo["indices"]
			# Recess surfaces (steps 9-11) have vertex colors for window emission
			if step >= 9 and geo.has("colors") and geo["colors"].size() == geo["vertices"].size():
				arrays[Mesh.ARRAY_COLOR] = geo["colors"]

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
			elif step < 9:
				material = _building_foundation_materials[step - 5]
			else:
				# Recesses (9-11) — recess material with vertex emission
				var tex_type: String = surface_key.replace("_recess", "")
				material = _building_recess_materials.get(tex_type, _building_wall_materials[tex_type])

			var rid := _rs_add_mesh(chunk_key, arr_mesh, material,
				shadow_setting, render_distance)
			if not _chunk_building_rs.has(chunk_key):
				_chunk_building_rs[chunk_key] = []
			_chunk_building_rs[chunk_key].append(rid)

			if _draw_call_logging_enabled:
				_draw_call_stats["buildings"] += 1

		# Skip empty surfaces — advance to next non-empty or cleanup
		step += 1
		while step < 12:
			var next_geo: Dictionary = batch[surface_keys[step]]
			if next_geo["vertices"].size() > 0:
				break
			step += 1

		batch["_finalize_step"] = step
		if step < 12:
			if not _building_geo_finalize_queue.has(chunk_key):
				_building_geo_finalize_queue.push_front(chunk_key)
			return

	# === Step 12: Cleanup — collisions, building ranges, erase batch ===
	var all_baked: bool = batch.get("_all_baked", false)

	if not batch["collisions"].is_empty():
		_deferred_append(_deferred_building_collisions, chunk_key, {
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

	# Take only up to N results at a time to avoid expensive duplicate of large arrays
	var MAX_BATCH := 9999 if _initial_loading else 20
	var batch_size := mini(_building_results.size(), MAX_BATCH)
	var results_to_process: Array = []
	for i in range(batch_size):
		results_to_process.append(_building_results[i])
	# Remove taken items
	for i in range(batch_size):
		_building_results.pop_front()
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

	# Применяем здания с бюджетом 2ms (без ограничений при начальной загрузке)
	var BUILDING_APPLY_BUDGET_USEC := 500000 if _initial_loading else 2000
	var apply_start := Time.get_ticks_usec()
	var applied := 0
	for i in range(valid_results.size()):
		_apply_building_mesh_result(valid_results[i])
		applied += 1
		if applied > 1 and (Time.get_ticks_usec() - apply_start) > BUILDING_APPLY_BUDGET_USEC:
			break
	_record_perf("building_apply", Time.get_ticks_usec() - apply_start)

	# Возвращаем оставшиеся обратно в начало очереди (сохраняя порядок)
	if applied < valid_results.size():
		_building_mutex.lock()
		var remaining: Array = valid_results.slice(applied)
		remaining.append_array(_building_results)
		_building_results = remaining
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
	if not _viewport_rid.is_valid() and get_viewport():
		_viewport_rid = get_viewport().get_viewport_rid()
	var render_cpu := 0.0
	var render_gpu := 0.0
	if _viewport_rid.is_valid():
		render_cpu = RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		render_gpu = RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)

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
	var road_q := _road_queue_total_size()
	var terrain_q := _terrain_objects_queue.size()
	var infra_q := _infrastructure_queue.size()
	var building_q := _building_results.size() + _building_geo_finalize_queue.size()
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

	var chunks_loaded := _loaded_chunks.size()
	var chunks_loading := _loading_chunks.size()
	var chunks_activating := _chunk_activation_pending.size()
	var chunks_visible := _culling_visible_count
	var chunks_culled := _culling_culled_count
	# Считаем чанки с незавершённой финализацией (видимые но неполные)
	var chunks_incomplete := 0
	for ck in _loaded_chunks:
		if _pending_batch_chunks.has(ck) or _lamp_batches_to_finalize.has(ck) or _tree_batches_to_finalize.has(ck) or _billboard_batches_to_finalize.has(ck) or _building_geo_finalize_queue.has(ck) or _fence_batches_to_finalize.has(ck) or _deferred_footway_queue.has(ck) or _deferred_lamp_queue.has(ck) or _deferred_manhole_queue.has(ck) or _deferred_billboard_queue.has(ck) or _deferred_building_collisions.has(ck) or _deferred_tree_collisions.has(ck) or _deferred_road_collisions.has(ck) or _deferred_terrain_collisions.has(ck) or _deferred_lamp_lights.has(ck) or _deferred_fence_edges.has(ck):
			chunks_incomplete += 1

	_debug_label.text = "FPS: %.0f (avg:%.0f 1%%:%.0f min:%.0f) | Cam: %s\nFrame: %.1fms [%s] CPU:%.1f GPU:%.1f\nProcess: %.1fms | Physics: %.1fms\nDraw: %d | Verts: %s | VRAM: %.0fMB\nBodies: %d | Pairs: %d | Nodes: %d\nQueues: R:%d T:%d I:%d B:%d C:%d TG:%d\nChunks: %d loaded (%d incomplete) | %d loading | %d activating | %d visible | %d culled\n_process avg/max (ms):%s" % [
		fps, avg_fps, fps_1pct, min_fps, cam_name,
		frame_ms, bottleneck, render_cpu, render_gpu,
		process_ms, physics_ms,
		draw_calls, vertices_str, vram,
		phys_bodies, phys_pairs, nodes,
		road_q, terrain_q, infra_q, building_q, curb_q, tgen_q,
		chunks_loaded, chunks_incomplete, chunks_loading, chunks_activating, chunks_visible, chunks_culled,
		func_lines
	]


func _road_queue_total_size() -> int:
	var total := 0
	for ck in _road_queue:
		total += (_road_queue[ck] as Array).size()
	return total

## Обрабатывает очередь дорог (3 дороги за кадр)
func _process_road_queue() -> void:
	var queue_start := Time.get_ticks_usec()
	var TOTAL_BUDGET_USEC := 500000 if _initial_loading else 4000  # unlimited during initial load, 4ms during gameplay

	# Phase 0: Apply ready road results from worker threads (main thread, time-budgeted)
	_road_mutex.lock()
	var n_ready := _road_results.size()
	_road_mutex.unlock()

	var road_apply_budget: int = 100000 if _initial_loading else 2000  # 100ms initial (drain everything), 2ms gameplay
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
		if (Time.get_ticks_usec() - queue_start) > road_apply_budget:
			break
	_record_perf("road_apply", Time.get_ticks_usec() - queue_start)

	# Overall budget gate — bail if already over budget
	if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
		return

	# Process deferred footway splitting incrementally (budget: remaining time up to 2.5ms from start)
	# During initial loading, drain everything within the broader 500ms budget.
	var fw_budget_end := queue_start + (200000 if _initial_loading else 2500)
	var fw_done_keys: Array[String] = []
	for fw_ck in _get_prioritized_keys(_deferred_footway_queue):
		if Time.get_ticks_usec() > fw_budget_end:
			break
		var fw_arr: Array = _deferred_footway_queue[fw_ck]
		while not fw_arr.is_empty():
			if Time.get_ticks_usec() > fw_budget_end:
				break
			var fw_item: Dictionary = fw_arr[0]
			if not is_instance_valid(fw_item.parent):
				fw_arr.pop_front()
				continue
			var done := _process_footway_incremental(fw_item, fw_budget_end, fw_ck)
			if done:
				fw_arr.pop_front()
		if fw_arr.is_empty():
			fw_done_keys.append(fw_ck)
	for fw_ck in fw_done_keys:
		_deferred_footway_queue.erase(fw_ck)

	if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
		return

	# Process deferred lamp/manhole generation with time budget
	# During initial loading, drain everything within the broader 500ms budget.
	var lamp_budget_us: int = 200000 if _initial_loading else 3000
	var lamp_done_keys: Array[String] = []
	for lamp_ck in _get_prioritized_keys(_deferred_lamp_queue):
		if (Time.get_ticks_usec() - queue_start) > lamp_budget_us:
			break
		var lamp_arr: Array = _deferred_lamp_queue[lamp_ck]
		while not lamp_arr.is_empty():
			if (Time.get_ticks_usec() - queue_start) > lamp_budget_us:
				break
			var item: Dictionary = lamp_arr[0]
			if not is_instance_valid(item.parent):
				lamp_arr.pop_front()
				continue
			var start_idx: int = item.get("_lamp_seg_idx", 0)
			var processed: int = _generate_street_lamps_incremental(item.points, item.width, item.parent, start_idx, queue_start, lamp_budget_us)
			if processed >= item.points.size() - 1:
				lamp_arr.pop_front()
			else:
				item["_lamp_seg_idx"] = processed
				break  # Resume next frame
		if lamp_arr.is_empty():
			lamp_done_keys.append(lamp_ck)
	for lamp_ck in lamp_done_keys:
		_deferred_lamp_queue.erase(lamp_ck)

	if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
		return

	var mh_done_keys: Array[String] = []
	for mh_ck in _get_prioritized_keys(_deferred_manhole_queue):
		if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
			break
		var mh_arr: Array = _deferred_manhole_queue[mh_ck]
		while not mh_arr.is_empty():
			if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
				break
			var item: Dictionary = mh_arr[0]
			if not is_instance_valid(item.parent):
				mh_arr.pop_front()
				continue
			mh_arr.pop_front()
			_generate_manholes_fast(item.points, item.width, item.parent)
		if mh_arr.is_empty():
			mh_done_keys.append(mh_ck)
	for mh_ck in mh_done_keys:
		_deferred_manhole_queue.erase(mh_ck)
	while not _deferred_traffic_queue.is_empty():
		if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
			break
		var item: Dictionary = _deferred_traffic_queue.pop_front()
		_extract_road_for_traffic_fast(item.points, item.tags, item.elevation_info)

	# Tram network extraction
	while not _deferred_tram_queue.is_empty():
		if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
			break
		var tram_item: Dictionary = _deferred_tram_queue.pop_front()
		_extract_tram_for_network(tram_item.points, tram_item.tags)

	if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
		return

	# Process deferred billboard creation with time budget
	var bb_done_keys: Array[String] = []
	for bb_ck in _get_prioritized_keys(_deferred_billboard_queue):
		if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
			break
		var bb_arr: Array = _deferred_billboard_queue[bb_ck]
		while not bb_arr.is_empty():
			if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
				break
			var item: Dictionary = bb_arr.pop_front()
			if not is_instance_valid(item.parent):
				continue
			var billboard_mesh: Node3D = _decoration_layer.create_billboard_mesh(item.billboard, item.elevation)
			_budgeted_add_child(item.parent, billboard_mesh)
		if bb_arr.is_empty():
			bb_done_keys.append(bb_ck)
	for bb_ck in bb_done_keys:
		_deferred_billboard_queue.erase(bb_ck)

	# Dispatch roads to worker threads — no time budget needed on main thread!
	# Limit concurrent tasks to avoid overwhelming thread pool
	# During initial loading: unlimited dispatch so all roads run in parallel.
	var MAX_CONCURRENT_ROAD_TASKS: int = 64 if _initial_loading else 8

	# Ensure lon_scale is initialized
	if _lon_scale == 0.0:
		_lon_scale = cos(deg_to_rad(start_lat)) * 111000.0

	# Dispatch in fair round-robin order so finalizing chunks do not starve behind new road work.
	if not _road_queue.is_empty() and _pending_road_tasks < MAX_CONCURRENT_ROAD_TASKS:
		var dispatch_capacity := MAX_CONCURRENT_ROAD_TASKS - _pending_road_tasks
		for chunk_key in _get_road_dispatch_order(dispatch_capacity):
			if _pending_road_tasks >= MAX_CONCURRENT_ROAD_TASKS:
				break
			if not _road_queue.has(chunk_key):
				continue
			var rq_arr: Array = _road_queue[chunk_key]
			if rq_arr.is_empty():
				_road_queue.erase(chunk_key)
				continue
			var item: Dictionary = rq_arr.pop_front()
			if rq_arr.is_empty():
				_road_queue.erase(chunk_key)
			if not is_instance_valid(item.get("parent")):
				continue
			_emit_road_debug("ROAD_DISPATCH key=%s queued=%d pending_tasks=%d activation_state=%s" % [
				chunk_key,
				rq_arr.size(),
				_pending_road_task_count_for_chunk(chunk_key),
				str(_chunk_activation_pending.get(chunk_key, null))
			])
			var parent: Node3D = item.parent
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
			_road_mutex.lock()
			_pending_road_tasks += 1
			_increment_pending_road_task(chunk_key)
			_road_mutex.unlock()
			WorkerThreadPool.add_task(_compute_road_geometry_thread.bind(task_data))

	# Check if roads pipeline has active work before finalization
	_road_mutex.lock()
	var has_road_results := not _road_results.is_empty()
	var pending_tasks := _pending_road_tasks
	_road_mutex.unlock()
	if has_road_results or pending_tasks > 0:
		return  # Still computing or applying road geometry

	# Budget gate: skip finalization if deferred work already consumed most budget
	if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
		return

	# Round-robin finalization. Normally one phase per frame to avoid scene-tree stutter,
	# but during initial loading we have a 500ms budget — drain queues until budget exhausted.
	var max_iterations: int = 64 if _initial_loading else 8
	var phases_checked := 0
	while phases_checked < max_iterations:
		phases_checked += 1
		if (Time.get_ticks_usec() - queue_start) > TOTAL_BUDGET_USEC:
			break
		var did_work := false
		match _finalize_phase:
			0:  # Roads (1 chunk — visible first)
				_finalize_phase = 1
				if not _pending_batch_chunks.is_empty():
					var _pbc_idx := -1
					for candidate_idx in range(_pending_batch_chunks.size()):
						var candidate_key: String = _pending_batch_chunks[candidate_idx]
						if _chunk_has_pending_road_inputs(candidate_key):
							continue
						_pbc_idx = candidate_idx
						break
					if _pbc_idx < 0:
						var fallback_idx := _pick_closest_chunk_idx(_pending_batch_chunks)
						if fallback_idx >= 0:
							var blocked_chunk: String = _pending_batch_chunks[fallback_idx]
							_emit_road_debug("ROAD_FINALIZE_WAIT key=%s queue=%s pending_tasks=%d ready_results=%s" % [
								blocked_chunk,
								str(_road_queue.get(blocked_chunk, []).size()),
								_pending_road_task_count_for_chunk(blocked_chunk),
								str(_chunk_has_key_in_array(_road_results, blocked_chunk))
							])
					else:
						var t_batch := Time.get_ticks_usec()
						var chunk_key2: String = _pending_batch_chunks[_pbc_idx]
						_pending_batch_chunks.remove_at(_pbc_idx)
						_finalize_road_batches_for_chunk(chunk_key2)
						_record_perf("fin_roads", Time.get_ticks_usec() - t_batch)
						did_work = true

			1:  # Curbs
				_finalize_phase = 2
				if not _curb_queue.is_empty() or not _curb_smoothed_queue.is_empty() or not _curb_mesh_state.is_empty() or not _curb_geo_batch.is_empty():
					var t_curb_fin := Time.get_ticks_usec()
					_process_curb_queue()
					_record_perf("fin_curbs", Time.get_ticks_usec() - t_curb_fin)
					did_work = true

			2:  # Lamps (1 chunk — visible first)
				_finalize_phase = 3
				if not _lamp_batches_to_finalize.is_empty():
					var _lb_idx := _pick_closest_chunk_idx(_lamp_batches_to_finalize)
					if _lb_idx >= 0:
						var t_lamp := Time.get_ticks_usec()
						var lamp_ck: String = _lamp_batches_to_finalize[_lb_idx]
						_lamp_batches_to_finalize.remove_at(_lb_idx)
						_finalize_lamp_batches_for_chunk(lamp_ck)
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
						var _bg_idx := _pick_closest_chunk_idx(_building_geo_finalize_queue)
						if _bg_idx >= 0:
							var t_geo := Time.get_ticks_usec()
							var geo_ck: String = _building_geo_finalize_queue[_bg_idx]
							_building_geo_finalize_queue.remove_at(_bg_idx)
							_finalize_building_geo_batch(geo_ck)
							_record_perf("fin_buildings", Time.get_ticks_usec() - t_geo)
							# Entrance/windows only after ALL building surfaces done
							if not _building_geo_batch.has(geo_ck):
								_finalize_entrance_batch(geo_ck)
								if _window_batch_data.has(geo_ck):
									_finalize_window_batches_for_chunk(geo_ck)
							did_work = true
					elif not _entrance_batch.is_empty():
						var ent_key: String = _entrance_batch.keys()[0]
						_finalize_entrance_batch(ent_key)
						did_work = true
					else:
						# Enqueue remaining windows (chunks without buildings in queue)
						var window_chunks := _window_batch_data.keys()
						for wck in window_chunks:
							_finalize_window_batches_for_chunk(wck)

			4:  # Windows (progressive fill, time-budgeted)
				_finalize_phase = 5
				if not _window_finalize_queue.is_empty():
					var t_window := Time.get_ticks_usec()
					var budget_end: int = t_window + 2000  # 2ms budget
					_progress_window_finalize(budget_end)
					_record_perf("fin_windows", Time.get_ticks_usec() - t_window)
					did_work = true

			5:  # Trees (1 chunk — visible first)
				_finalize_phase = 6
				if not _tree_batches_to_finalize.is_empty():
					var _tb_idx := _pick_closest_chunk_idx(_tree_batches_to_finalize)
					if _tb_idx >= 0:
						var t_tree := Time.get_ticks_usec()
						var tree_ck: String = _tree_batches_to_finalize[_tb_idx]
						_tree_batches_to_finalize.remove_at(_tb_idx)
						_finalize_tree_batches_for_chunk(tree_ck)
						_record_perf("fin_trees", Time.get_ticks_usec() - t_tree)
						did_work = true

			6:  # Billboards (1 chunk — visible first)
				_finalize_phase = 7
				if not _billboard_batches_to_finalize.is_empty():
					var _bb_idx := _pick_closest_chunk_idx(_billboard_batches_to_finalize)
					if _bb_idx >= 0:
						var t_bill := Time.get_ticks_usec()
						var bill_ck: String = _billboard_batches_to_finalize[_bb_idx]
						_billboard_batches_to_finalize.remove_at(_bb_idx)
						_finalize_billboard_batch_for_chunk(bill_ck)
						_record_perf("fin_billboards", Time.get_ticks_usec() - t_bill)
						did_work = true

			7:  # Fences (1 chunk — visible first)
				_finalize_phase = 0
				if not _fence_batches_to_finalize.is_empty():
					var _fc_idx := _pick_closest_chunk_idx(_fence_batches_to_finalize)
					if _fc_idx >= 0:
						var fence_ck: String = _fence_batches_to_finalize[_fc_idx]
						# Don't finalize if deferred edges still pending for this chunk
						var has_pending_edges: bool = _deferred_fence_edges.has(fence_ck) and not (_deferred_fence_edges[fence_ck] as Array).is_empty()
						if has_pending_edges:
							did_work = true  # keep cycling
						else:
							var t_fence := Time.get_ticks_usec()
							_fence_batches_to_finalize.remove_at(_fc_idx)
							_finalize_fence_batches_for_chunk(fence_ck)
							_record_perf("fin_fences", Time.get_ticks_usec() - t_fence)
							did_work = true


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
				var clip_min_x: float = float(ck_x) * chunk_size
				var clip_max_x: float = float(ck_x + 1) * chunk_size
				var clip_min_z: float = float(ck_z) * chunk_size
				var clip_max_z: float = float(ck_z + 1) * chunk_size
				points = _clip_polyline_to_rect(points, clip_min_x, clip_max_x, clip_min_z, clip_max_z)
				if points.size() < 2:
					continue

			# Добавляем в очередь для генерации меша
			_curb_smoothed_queue.append({
				"points": points,
				"width": item.width,
				"height_offset": item.height_offset,
				"curb_height": item.curb_height,
				"parent": item.parent,
				"way_id": item.get("way_id", 0),  # Stage 2B: keep way_id for ramp sampler
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
	var curb_ck := _get_chunk_key_from_node(item.parent) if item.has("parent") else ""

	var curb_width := 0.15
	var hash_val := int(abs(points[0].x * 1000 + points[0].y * 7919)) % 100
	var z_offset := hash_val * 0.000005  # Совпадает с z_offset дороги

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
		if _is_point_in_intersection_shape(left1, true, curb_ck) < 0 and \
		   _is_point_in_intersection_shape(left2, true, curb_ck) < 0 and \
		   _is_point_in_intersection_shape(right1, true, curb_ck) < 0 and \
		   _is_point_in_intersection_shape(right2, true, curb_ck) < 0:
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

	# Stage 2B: cumulative centerline distance for ramp sampler. Starts at 0
	# at the chunk-clipped first point. Distances are informational only —
	# the way-aware sampler uses point projection, not absolute distance.
	var cum_dist: PackedFloat32Array = PackedFloat32Array()
	cum_dist.resize(points.size())
	if points.size() > 0:
		cum_dist[0] = 0.0
		var acc: float = 0.0
		for i in range(1, points.size()):
			acc += points[i - 1].distance_to(points[i])
			cum_dist[i] = acc

	_curb_mesh_state = {
		"points": points,
		"cum_dist": cum_dist,
		"way_id": int(item.get("way_id", 0)),
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

		# Усреднение perp на стыках для устранения щелей между сегментами
		var perp1 := perp
		var perp2 := perp
		if not is_first:
			var prev_i: int = group[g_idx - 1]
			var prev_dir := (points[prev_i + 1] - points[prev_i]).normalized()
			var prev_perp := Vector2(-prev_dir.y, prev_dir.x)
			var avg := prev_perp + perp
			if avg.length_squared() > 0.001:
				perp1 = avg.normalized()
		if not is_last:
			var next_i: int = group[g_idx + 1]
			var next_dir := (points[next_i + 1] - points[next_i]).normalized()
			var next_perp := Vector2(-next_dir.y, next_dir.x)
			var avg := perp + next_perp
			if avg.length_squared() > 0.001:
				perp2 = avg.normalized()

		# Stage 2B: elevation through the way-aware ramp sampler so curbs
		# follow the same Y the road centerline used. Pass road_y_offset=0
		# because the curb code adds its own offsets below.
		var curb_way_id: int = int(state.get("way_id", 0))
		var cum_dist_arr: PackedFloat32Array = state.get("cum_dist", PackedFloat32Array())
		var cl_d1: float = cum_dist_arr[i] if i < cum_dist_arr.size() else 0.0
		var cl_d2: float = cum_dist_arr[i + 1] if (i + 1) < cum_dist_arr.size() else cl_d1
		var h_center1 := _road_sample_y_for_way(curb_way_id, p1, cl_d1, 0.0)
		var h_center2 := _road_sample_y_for_way(curb_way_id, p2, cl_d2, 0.0)

		var left_inner1 := p1 + perp1 * (road_width * 0.5)
		var left_outer1 := p1 + perp1 * (road_width * 0.5 + curb_width)
		var left_inner2 := p2 + perp2 * (road_width * 0.5)
		var left_outer2 := p2 + perp2 * (road_width * 0.5 + curb_width)
		var right_inner1 := p1 - perp1 * (road_width * 0.5)
		var right_outer1 := p1 - perp1 * (road_width * 0.5 + curb_width)
		var right_inner2 := p2 - perp2 * (road_width * 0.5)
		var right_outer2 := p2 - perp2 * (road_width * 0.5 + curb_width)

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
		indices.append(idx + 0); indices.append(idx + 2); indices.append(idx + 1)
		indices.append(idx + 0); indices.append(idx + 3); indices.append(idx + 2)
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
		# bridge_deck items use a "polygon" (local-coord) instead of "nodes".
		var poly = item.get("polygon", null)
		if poly is PackedVector2Array and poly.size() > 0:
			item["_dist"] = poly[0].distance_squared_to(player_pos_2d)
			continue
		var nodes_arr = item.get("nodes", [])
		var first_node = nodes_arr[0] if (nodes_arr is Array and nodes_arr.size() > 0) else null
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

	# Time budget: unlimited during initial loading, 2ms during gameplay
	var TERRAIN_TIME_BUDGET_USEC := 500000 if _initial_loading else 2000
	var start_time := Time.get_ticks_usec()
	var processed := 0
	var deferred: Array = []

	while not _terrain_objects_queue.is_empty():
		# Проверяем бюджет ПОСЛЕ первого объекта
		if processed > 0 and (Time.get_ticks_usec() - start_time) > TERRAIN_TIME_BUDGET_USEC:
			break

		var item: Dictionary = _terrain_objects_queue.pop_front()

		var obj_type: String = item.get("type", "")
		# Bridge decks parent themselves to `self`, not to chunks; the
		# chunk that originally queued them may already have unloaded but
		# the deck must still build (it's per-relation, not per-chunk).
		# Other types still require their owning chunk to be alive.
		if obj_type != "bridge_deck" and not is_instance_valid(item.get("parent")):
			continue
		var t0 := Time.get_ticks_usec()

		match obj_type:
			"natural":
				_create_natural_immediate(item.nodes, item.tags, item.parent)
				_record_perf("terrain_natural", Time.get_ticks_usec() - t0)
			"landuse":
				_create_landuse_immediate(item.nodes, item.tags, item.parent, item.get("way_id", 0))
				_record_perf("terrain_landuse", Time.get_ticks_usec() - t0)
			"leisure":
				_create_leisure_immediate(item.nodes, item.tags, item.parent, item.get("way_id", 0))
				_record_perf("terrain_leisure", Time.get_ticks_usec() - t0)
			"bridge_deck":
				var poly: PackedVector2Array = item.get("polygon", PackedVector2Array())
				var poly_idx: int = _bridge_deck_polygons.find(poly)
				# Defer until both abutment (long-axis) chunks have
				# elevation. That's all we need for ref_elev — the rest of
				# the polygon uses the constant ref_elev as its baseline.
				# Long bridges (Oktyabrsky 1 km) span more chunks than the
				# streaming radius ever covers, so requiring full coverage
				# would never resolve.
				var ref_elev: float = _compute_and_cache_deck_ref_elev(poly_idx)
				if is_nan(ref_elev):
					deferred.append(item)
					continue
				# Parent the deck to self, not to the chunk that happened to
				# spawn it: a 1 km bridge mesh otherwise gets hidden the
				# moment its owner chunk falls behind the camera-direction
				# culler (~315 m behind), even though the player is still
				# driving on top of it. reset_terrain() frees orphan deck
				# nodes via _bridge_deck_nodes.
				var deck_parent: Node3D = self
				_create_bridge_deck_mesh(poly, item.get("tags", {}), deck_parent, poly)
				_record_perf("terrain_bridge_deck", Time.get_ticks_usec() - t0)

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

	# Time budget: unlimited during initial loading, 2ms during gameplay
	var INFRA_TIME_BUDGET_USEC := 500000 if _initial_loading else 2000
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

		var elevation := _sample_elevation(item.pos.x, item.pos.y)
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
			"tram_stop_sign":
				_create_tram_stop_sign_immediate(item.pos, elevation, item.get("rotation", 0.0), item.parent)
				_record_perf("infra_tram_stop_sign", Time.get_ticks_usec() - t0)
		processed += 1


## Диспетчер растительности — отправляет задачи в воркер-треды
func _process_vegetation_queue() -> void:
	if _vegetation_queue.is_empty():
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
			if ck != "" and _road_queue.has(ck):
				continue  # Дороги ещё в очереди на dispatching в worker threads
			if ck != "" and _road_batch_data.has(ck):
				continue  # Дороги ещё не финализированы в mesh
			if ck != "" and _pending_batch_chunks.has(ck):
				continue  # Batch ещё не финализирован (road workers могут быть в полёте)
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

		# Per-chunk hashes (each chunk has its own, includes overlap data)
		var ck_road_hash: Dictionary = _chunk_road_hashes.get(chunk_key, {})
		var ck_building_hash: Dictionary = _chunk_building_hashes.get(chunk_key, {})
		var ck_building_poly_hash: Dictionary = _chunk_building_poly_hashes.get(chunk_key, {})
		var ck_parking_data: Dictionary = _chunk_parking_hashes.get(chunk_key, {})
		var ck_parking_hash: Dictionary = ck_parking_data.get("hash", {})
		var ck_parking_polys: Array = ck_parking_data.get("polys", [])
		var ck_water_data: Dictionary = _chunk_water_hashes.get(chunk_key, {})
		var ck_water_hash: Dictionary = ck_water_data.get("hash", {})
		# Pass GLOBAL water polygons to the vegetation worker so trees scattered
		# inside a forest polygon that overlaps a huge water polygon (whose
		# nodes aren't in this chunk's OSM data) still detect "in water".
		var ck_water_polys: Array = _global_water_polygons.duplicate()

		var elev_grid: Dictionary = _chunk_elevation_data.get(chunk_key, {})
		var base_elev: float = 0.0

		match veg_type:
			"trees":
				var task_data := {
					"points": item.points,
					"dense": item.dense,
					"chunk_key": chunk_key,
					"chunk_size": chunk_size,
					"road_spatial_hash": ck_road_hash,
					"building_spatial_hash": ck_building_hash,
					"building_poly_hash": ck_building_poly_hash,
					"water_spatial_hash": ck_water_hash,
					"water_polygons": ck_water_polys,
					"parent": item.parent,
					"elev_grid": elev_grid,
					"base_elevation": base_elev,
				}
				_pending_veg_tasks += 1
				WorkerThreadPool.add_task(_compute_trees_thread.bind(task_data))
			"chunk_trees":
				var task_data := {
					"chunk_key": chunk_key,
					"chunk_size": chunk_size,
					"road_spatial_hash": ck_road_hash,
					"building_spatial_hash": ck_building_hash,
					"building_poly_hash": ck_building_poly_hash,
					"parking_spatial_hash": ck_parking_hash,
					"parking_polygons": ck_parking_polys,
					"water_spatial_hash": ck_water_hash,
					"water_polygons": ck_water_polys,
					"parent": item.parent,
					"elev_grid": elev_grid,
					"base_elevation": base_elev,
				}
				_pending_veg_tasks += 1
				WorkerThreadPool.add_task(_compute_chunk_trees_thread.bind(task_data))


func _is_chunk_alive_for_async_work(chunk_key: String) -> bool:
	if chunk_key.is_empty():
		return true
	return _is_chunk_alive(chunk_key)


## Применяет результаты из воркер-тредов деревьев (с бюджетом)
func _apply_veg_thread_results() -> void:
	_veg_mutex.lock()
	if _veg_thread_results.is_empty():
		_veg_mutex.unlock()
		return
	var results := _veg_thread_results.duplicate()
	_veg_thread_results.clear()
	_veg_mutex.unlock()

	var VEG_APPLY_BUDGET_USEC := 500000 if _initial_loading else 2000
	var apply_start := Time.get_ticks_usec()
	var applied := 0

	for result in results:
		var chunk_key: String = result.chunk_key
		var parent: Node3D = result.parent

		# Не дропаем результаты, если чанк ещё в стадии loading/finalization.
		if not is_instance_valid(parent) or not _is_chunk_alive_for_async_work(chunk_key):
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

	var uv_scale_x := 0.4  # 1 UV unit = 2.5m (PBR кирпичные текстуры ~1м на тайл)
	var uv_scale_y := 0.4

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

	# Используем shared материал стен (уже с PBR текстурами)
	wall_mesh_instance.material_override = _building_wall_materials.get(texture_type)

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
			var par_mat := ShaderMaterial.new()
			par_mat.shader = BuildingWallShader
			par_mat.set_shader_parameter("use_texture", false)
			par_mat.set_shader_parameter("albedo_color", Color(0.5, 0.5, 0.5))
			par_mat.set_shader_parameter("roughness_base", 0.7)
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
	for i in range(points.size()):
		var fp1 := points[i]
		var fp2 := points[(i + 1) % points.size()]
		var fdir := (fp2 - fp1).normalized()
		var fnorm := Vector3(-fdir.y * normal_sign, 0.0, fdir.x * normal_sign)
		var fvi := fv.size()
		var fb1 := _sample_elevation(fp1.x, fp1.y) - FOUNDATION_DEPTH
		var fb2 := _sample_elevation(fp2.x, fp2.y) - FOUNDATION_DEPTH
		fv.append(Vector3(fp1.x, ft, fp1.y))
		fv.append(Vector3(fp2.x, ft, fp2.y))
		fv.append(Vector3(fp2.x, fb2, fp2.y))
		fv.append(Vector3(fp1.x, fb1, fp1.y))
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
	# Bottom cap — seal foundation from below
	var bottom_tri := Geometry2D.triangulate_polygon(points)
	if bottom_tri.size() >= 3:
		var cap_y := base_elev - FOUNDATION_CAP_DEPTH
		for i in range(0, bottom_tri.size(), 3):
			var bvi := fv.size()
			var bp1 := points[bottom_tri[i]]
			var bp2 := points[bottom_tri[i + 1]]
			var bp3 := points[bottom_tri[i + 2]]
			fv.append(Vector3(bp1.x, cap_y, bp1.y))
			fv.append(Vector3(bp3.x, cap_y, bp3.y))
			fv.append(Vector3(bp2.x, cap_y, bp2.y))
			fu.append(Vector2.ZERO)
			fu.append(Vector2.ZERO)
			fu.append(Vector2.ZERO)
			fn.append(Vector3.DOWN)
			fn.append(Vector3.DOWN)
			fn.append(Vector3.DOWN)
			fi.append(bvi)
			fi.append(bvi + 1)
			fi.append(bvi + 2)
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

	# Кэшируем и null чтобы не проверять файлы повторно
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
	# Normal map
	var normal_path := base_path + "_normal.png"
	var normal_texture: Texture2D = _load_texture_map(building_override.wall_normal_path, normal_path)
	var normal_strength: float = 2.0

	# Ambient Occlusion
	var ao_path := base_path + "_ambient.png"
	var ao_texture: Texture2D = _load_texture_map(building_override.wall_ao_path, ao_path)
	var ao_strength: float = 1.0

	# Specular (используется как инверсия roughness)
	var specular_path := base_path + "_specular.png"
	var specular_texture: Texture2D = _load_texture_map(building_override.wall_specular_path, specular_path)

	# Displacement/Height (для parallax mapping)
	var displacement_path := base_path + "_displacement.png"
	var displacement_texture: Texture2D = _load_texture_map(building_override.wall_displacement_path, displacement_path)
	var heightmap_scale: float = 0.05


	# Высоты с учётом террейна
	var fnd_h := 0.0 if building_override.no_foundation else _get_foundation_height(points)
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

	# UV масштаб: texture_repeat_x повторов на весь периметр (0 = авто)
	var texture_repeat_x: float = building_override.texture_repeat_x if building_override.texture_repeat_x > 0 else 0.0
	var uv_scale_x := 0.0
	if texture_repeat_x > 0:
		uv_scale_x = texture_repeat_x / perimeter
	elif custom_texture and building_height > 0.1:
		# Авто: сохраняем пропорции текстуры. Один тайл по высоте = building_height / repeat_y.
		# Ширина тайла в метрах = tile_h * (tex_w / tex_h). uv_scale_x = 1 / tile_w_meters.
		var tex_aspect: float = float(custom_texture.get_width()) / float(custom_texture.get_height())
		var tile_h: float = building_height / texture_repeat_y
		var tile_w: float = tile_h * tex_aspect
		uv_scale_x = 1.0 / tile_w if tile_w > 0.1 else 0.1
	else:
		uv_scale_x = 0.1  # Дефолт для текстур без авто-расчёта
	var uv_offset_x: float = building_override.texture_offset_x

	var is_ccw := _is_polygon_ccw(points)
	var normal_sign := -1.0 if is_ccw else 1.0

	# === Per-vertex extra heights from pediments ===
	var extra_height: Array[float] = []
	extra_height.resize(points.size())
	for _ei in points.size():
		extra_height[_ei] = 0.0

	# Extension walls (above roof_y) — separate mesh with light color
	var ext_vertices := PackedVector3Array()
	var ext_uvs := PackedVector2Array()
	var ext_normals := PackedVector3Array()
	var ext_indices := PackedInt32Array()
	var has_extensions := false
	var ext_color := Color(0.92, 0.92, 0.94)
	var ext_texture: Texture2D = null

	if building_override and not building_override.pediments.is_empty():
		for ped_data in building_override.pediments:
			if not ped_data.has("p1") or not ped_data.has("p2"):
				continue
			var ped_p1_ll: Array = ped_data["p1"]
			var ped_p2_ll: Array = ped_data["p2"]
			if ped_p1_ll.size() < 2 or ped_p2_ll.size() < 2:
				continue

			var ped_p1_local := _latlon_to_local(ped_p1_ll[0], ped_p1_ll[1])
			var ped_p2_local := _latlon_to_local(ped_p2_ll[0], ped_p2_ll[1])
			var rect_h: float = ped_data.get("rect_height", 2.0)
			var tri_h: float = ped_data.get("tri_height", 2.0)

			if ped_data.has("color"):
				var ca: Array = ped_data["color"]
				if ca.size() >= 3:
					ext_color = Color(ca[0], ca[1], ca[2])

			if ped_data.has("texture"):
				var tex_path: String = "res://textures/" + ped_data["texture"]
				ext_texture = load(tex_path) as Texture2D

			# Find closest polygon vertices to p1 and p2
			var idx1 := -1
			var idx2 := -1
			var best_d1 := 999999.0
			var best_d2 := 999999.0
			for vi in points.size():
				var d1 := points[vi].distance_squared_to(ped_p1_local)
				var d2 := points[vi].distance_squared_to(ped_p2_local)
				if d1 < best_d1:
					best_d1 = d1
					idx1 = vi
				if d2 < best_d2:
					best_d2 = d2
					idx2 = vi

			if idx1 < 0 or idx2 < 0 or idx1 == idx2:
				continue

			# Walk from idx1 to idx2 (both directions), use shorter path
			var walk := []
			var vi_cur := idx1
			while vi_cur != idx2:
				walk.append(vi_cur)
				vi_cur = (vi_cur + 1) % points.size()
			walk.append(idx2)

			var walk_rev := []
			vi_cur = idx1
			while vi_cur != idx2:
				walk_rev.append(vi_cur)
				vi_cur = (vi_cur - 1 + points.size()) % points.size()
			walk_rev.append(idx2)

			if walk_rev.size() < walk.size():
				walk = walk_rev

			# Assign heights: corners = rect_h, middle = rect_h + tri_h
			for wi in walk.size():
				var vidx: int = walk[wi]
				if wi == 0 or wi == walk.size() - 1:
					extra_height[vidx] = maxf(extra_height[vidx], rect_h)
				else:
					var t: float = float(wi) / float(walk.size() - 1)
					var tri_contrib: float = tri_h * (1.0 - abs(t - 0.5) / 0.5)
					extra_height[vidx] = maxf(extra_height[vidx], rect_h + tri_contrib)

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
			u1 = accumulated_width * uv_scale_x + uv_offset_x
			u2 = (accumulated_width + wall_width) * uv_scale_x + uv_offset_x

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

		# Extension walls above roof_y for pediment vertices
		var i_next := (i + 1) % points.size()
		var ext_left: float = extra_height[i]
		var ext_right: float = extra_height[i_next]
		if ext_left > 0.0 or ext_right > 0.0:
			has_extensions = true
			var eidx := ext_vertices.size()
			ext_vertices.append(Vector3(p1.x, roof_y, p1.y))
			ext_vertices.append(Vector3(p2.x, roof_y, p2.y))
			ext_vertices.append(Vector3(p2.x, roof_y + ext_right, p2.y))
			ext_vertices.append(Vector3(p1.x, roof_y + ext_left, p1.y))
			var ext_u_right := wall_width / 3.0  # тайлинг ~3м на повтор
			var ext_v_left := ext_left / 3.0
			var ext_v_right := ext_right / 3.0
			ext_uvs.append(Vector2(0, ext_v_left))           # bottom-left
			ext_uvs.append(Vector2(ext_u_right, ext_v_right)) # bottom-right
			ext_uvs.append(Vector2(ext_u_right, 0))           # top-right
			ext_uvs.append(Vector2(0, 0))                     # top-left
			ext_normals.append(normal)
			ext_normals.append(normal)
			ext_normals.append(normal)
			ext_normals.append(normal)
			ext_indices.append(eidx + 0)
			ext_indices.append(eidx + 1)
			ext_indices.append(eidx + 2)
			ext_indices.append(eidx + 0)
			ext_indices.append(eidx + 2)
			ext_indices.append(eidx + 3)

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

	# === Extension walls (pediment upper section, light color) ===
	if has_extensions and ext_vertices.size() >= 3:
		var ext_arrays := []
		ext_arrays.resize(Mesh.ARRAY_MAX)
		ext_arrays[Mesh.ARRAY_VERTEX] = ext_vertices
		ext_arrays[Mesh.ARRAY_TEX_UV] = ext_uvs
		ext_arrays[Mesh.ARRAY_NORMAL] = ext_normals
		ext_arrays[Mesh.ARRAY_INDEX] = ext_indices

		var ext_mesh := ArrayMesh.new()
		ext_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ext_arrays)

		var ext_mat := ShaderMaterial.new()
		ext_mat.shader = BuildingWallShader
		if ext_texture:
			ext_mat.set_shader_parameter("use_texture", true)
			ext_mat.set_shader_parameter("albedo_texture", ext_texture)
		else:
			ext_mat.set_shader_parameter("use_texture", false)
		ext_mat.set_shader_parameter("albedo_color", ext_color)
		ext_mat.set_shader_parameter("roughness_base", 0.6)

		var ext_inst := MeshInstance3D.new()
		ext_inst.mesh = ext_mesh
		ext_inst.material_override = ext_mat
		ext_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		wall_mesh_instance.add_child(ext_inst)
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

	# === КРЫША ===
	# Определяем тип крыши: explicit roof_type > building_material fallback
	var effective_roof_type: String = building_override.roof_type
	if effective_roof_type == "" and building_override.building_material == "wood":
		effective_roof_type = "hip"

	if effective_roof_type == "hip":
		# === ВАЛЬМОВАЯ КРЫША — ребро вдоль длинной стороны, скаты со всех сторон ===
		var bb_min_x := INF
		var bb_max_x := -INF
		var bb_min_z := INF
		var bb_max_z := -INF
		for p in points:
			bb_min_x = min(bb_min_x, p.x)
			bb_max_x = max(bb_max_x, p.x)
			bb_min_z = min(bb_min_z, p.y)
			bb_max_z = max(bb_max_z, p.y)

		var roof_sx := bb_max_x - bb_min_x
		var roof_sz := bb_max_z - bb_min_z
		var ridge_h: float = building_override.ridge_height if building_override.ridge_height > 0 else 2.5
		var ridge_top := roof_y + ridge_h
		var ridge_along_x := roof_sx >= roof_sz

		# Ребро конька вдоль длинной стороны, отступ от краёв = половина короткой стороны
		var rv := PackedVector3Array()
		var ru := PackedVector2Array()
		var rn := PackedVector3Array()
		var ri := PackedInt32Array()

		var c0 := Vector3(bb_min_x, roof_y, bb_min_z)
		var c1 := Vector3(bb_max_x, roof_y, bb_min_z)
		var c2 := Vector3(bb_max_x, roof_y, bb_max_z)
		var c3 := Vector3(bb_min_x, roof_y, bb_max_z)

		if ridge_along_x:
			var mid_z := (bb_min_z + bb_max_z) / 2.0
			var inset: float = min(roof_sz / 2.0, roof_sx / 4.0)
			var r0 := Vector3(bb_min_x + inset, ridge_top, mid_z)
			var r1 := Vector3(bb_max_x - inset, ridge_top, mid_z)
			var half_w := roof_sz / 2.0
			var slope_l := sqrt(half_w * half_w + ridge_h * ridge_h)
			var n_front := Vector3(0, half_w / slope_l, -ridge_h / slope_l)
			var n_back := Vector3(0, half_w / slope_l, ridge_h / slope_l)

			# Скат front (трапеция): c0, c1, r1, r0
			var vi: int = 0
			rv.append(c0); rv.append(c1); rv.append(r1); rv.append(r0)
			ru.append(Vector2(0, 1)); ru.append(Vector2(roof_sx * 0.2, 1))
			ru.append(Vector2(roof_sx * 0.2, 0)); ru.append(Vector2(0, 0))
			for _i in 4: rn.append(n_front)
			ri.append_array([0, 1, 2, 0, 2, 3])

			# Скат back (трапеция): c3, r0, r1, c2
			vi = rv.size()
			rv.append(c3); rv.append(r0); rv.append(r1); rv.append(c2)
			ru.append(Vector2(0, 1)); ru.append(Vector2(0, 0))
			ru.append(Vector2(roof_sx * 0.2, 0)); ru.append(Vector2(roof_sx * 0.2, 1))
			for _i in 4: rn.append(n_back)
			ri.append_array([vi, vi + 1, vi + 2, vi, vi + 2, vi + 3])

			# Вальма left (треугольник): c0, c3, r0
			var n_left := Vector3(-1, 0.5, 0).normalized()
			vi = rv.size()
			rv.append(c0); rv.append(c3); rv.append(r0)
			ru.append(Vector2(0, 1)); ru.append(Vector2(1, 1)); ru.append(Vector2(0.5, 0))
			for _i in 3: rn.append(n_left)
			ri.append_array([vi, vi + 1, vi + 2])

			# Вальма right (треугольник): c1, c2, r1
			var n_right := Vector3(1, 0.5, 0).normalized()
			vi = rv.size()
			rv.append(c1); rv.append(c2); rv.append(r1)
			ru.append(Vector2(0, 1)); ru.append(Vector2(1, 1)); ru.append(Vector2(0.5, 0))
			for _i in 3: rn.append(n_right)
			ri.append_array([vi, vi + 1, vi + 2])
		else:
			var mid_x := (bb_min_x + bb_max_x) / 2.0
			var inset: float = min(roof_sx / 2.0, roof_sz / 4.0)
			var r0 := Vector3(mid_x, ridge_top, bb_min_z + inset)
			var r1 := Vector3(mid_x, ridge_top, bb_max_z - inset)
			var half_w := roof_sx / 2.0
			var slope_l := sqrt(half_w * half_w + ridge_h * ridge_h)
			var n_left := Vector3(-ridge_h / slope_l, half_w / slope_l, 0)
			var n_right := Vector3(ridge_h / slope_l, half_w / slope_l, 0)

			# Скат left (трапеция): c0, r0, r1, c3
			var vi: int = 0
			rv.append(c0); rv.append(r0); rv.append(r1); rv.append(c3)
			ru.append(Vector2(0, 1)); ru.append(Vector2(0, 0))
			ru.append(Vector2(roof_sz * 0.2, 0)); ru.append(Vector2(roof_sz * 0.2, 1))
			for _i in 4: rn.append(n_left)
			ri.append_array([0, 1, 2, 0, 2, 3])

			# Скат right (трапеция): c1, c2, r1, r0
			vi = rv.size()
			rv.append(c1); rv.append(c2); rv.append(r1); rv.append(r0)
			ru.append(Vector2(0, 1)); ru.append(Vector2(roof_sz * 0.2, 1))
			ru.append(Vector2(roof_sz * 0.2, 0)); ru.append(Vector2(0, 0))
			for _i in 4: rn.append(n_right)
			ri.append_array([vi, vi + 1, vi + 2, vi, vi + 2, vi + 3])

			# Вальма front (треугольник): c0, c1, r0
			var n_front := Vector3(0, 0.5, -1).normalized()
			vi = rv.size()
			rv.append(c0); rv.append(c1); rv.append(r0)
			ru.append(Vector2(0, 1)); ru.append(Vector2(1, 1)); ru.append(Vector2(0.5, 0))
			for _i in 3: rn.append(n_front)
			ri.append_array([vi, vi + 1, vi + 2])

			# Вальма back (треугольник): c3, c2, r1
			var n_back := Vector3(0, 0.5, 1).normalized()
			vi = rv.size()
			rv.append(c3); rv.append(c2); rv.append(r1)
			ru.append(Vector2(0, 1)); ru.append(Vector2(1, 1)); ru.append(Vector2(0.5, 0))
			for _i in 3: rn.append(n_back)
			ri.append_array([vi, vi + 1, vi + 2])

		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)
		roof_arrays[Mesh.ARRAY_VERTEX] = rv
		roof_arrays[Mesh.ARRAY_TEX_UV] = ru
		roof_arrays[Mesh.ARRAY_NORMAL] = rn
		roof_arrays[Mesh.ARRAY_INDEX] = ri

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_mesh_instance := MeshInstance3D.new()
		roof_mesh_instance.mesh = roof_mesh
		roof_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		roof_mesh_instance.material_override = _gabled_roof_material
		wall_mesh_instance.add_child(roof_mesh_instance)

	elif effective_roof_type == "gable":
		# === ДВУСКАТНАЯ КРЫША (gable) — конёк на полную длину, вертикальные фронтоны ===
		var bb_min_x := INF
		var bb_max_x := -INF
		var bb_min_z := INF
		var bb_max_z := -INF
		for p in points:
			bb_min_x = min(bb_min_x, p.x)
			bb_max_x = max(bb_max_x, p.x)
			bb_min_z = min(bb_min_z, p.y)
			bb_max_z = max(bb_max_z, p.y)

		var roof_sx := bb_max_x - bb_min_x
		var roof_sz := bb_max_z - bb_min_z
		var ridge_h: float = building_override.ridge_height if building_override.ridge_height > 0 else 3.5
		var ridge_top := roof_y + ridge_h
		var ridge_along_x := roof_sx >= roof_sz

		var rv := PackedVector3Array()
		var ru := PackedVector2Array()
		var rn := PackedVector3Array()
		var ri := PackedInt32Array()

		var c0 := Vector3(bb_min_x, roof_y, bb_min_z)
		var c1 := Vector3(bb_max_x, roof_y, bb_min_z)
		var c2 := Vector3(bb_max_x, roof_y, bb_max_z)
		var c3 := Vector3(bb_min_x, roof_y, bb_max_z)

		# Фронтоны (вертикальные треугольники) — отдельный меш
		var fv := PackedVector3Array()
		var fu := PackedVector2Array()
		var fn := PackedVector3Array()
		var fi := PackedInt32Array()

		if ridge_along_x:
			var mid_z := (bb_min_z + bb_max_z) / 2.0
			# Конёк на полную длину (без inset)
			var r0 := Vector3(bb_min_x, ridge_top, mid_z)
			var r1 := Vector3(bb_max_x, ridge_top, mid_z)
			var half_w := roof_sz / 2.0
			var slope_l := sqrt(half_w * half_w + ridge_h * ridge_h)
			var n_front := Vector3(0, half_w / slope_l, -ridge_h / slope_l)
			var n_back := Vector3(0, half_w / slope_l, ridge_h / slope_l)

			# Скат front (прямоугольник): c0, c1, r1, r0
			var vi: int = 0
			rv.append(c0); rv.append(c1); rv.append(r1); rv.append(r0)
			ru.append(Vector2(0, 1)); ru.append(Vector2(roof_sx * 0.2, 1))
			ru.append(Vector2(roof_sx * 0.2, 0)); ru.append(Vector2(0, 0))
			for _i in 4: rn.append(n_front)
			ri.append_array([0, 1, 2, 0, 2, 3])

			# Скат back (прямоугольник): c3, r0, r1, c2
			vi = rv.size()
			rv.append(c3); rv.append(r0); rv.append(r1); rv.append(c2)
			ru.append(Vector2(0, 1)); ru.append(Vector2(0, 0))
			ru.append(Vector2(roof_sx * 0.2, 0)); ru.append(Vector2(roof_sx * 0.2, 1))
			for _i in 4: rn.append(n_back)
			ri.append_array([vi, vi + 1, vi + 2, vi, vi + 2, vi + 3])

			# Фронтон left (вертикальный треугольник): c0, c3, r0
			var n_left := Vector3(-1, 0, 0)
			vi = 0
			fv.append(c0); fv.append(c3); fv.append(r0)
			fu.append(Vector2(0, 0)); fu.append(Vector2(1, 0)); fu.append(Vector2(0.5, 1))
			for _i in 3: fn.append(n_left)
			fi.append_array([0, 1, 2])

			# Фронтон right (вертикальный треугольник): c1, r1, c2
			var n_right := Vector3(1, 0, 0)
			vi = fv.size()
			fv.append(c1); fv.append(r1); fv.append(c2)
			fu.append(Vector2(0, 0)); fu.append(Vector2(0.5, 1)); fu.append(Vector2(1, 0))
			for _i in 3: fn.append(n_right)
			fi.append_array([vi, vi + 1, vi + 2])
		else:
			var mid_x := (bb_min_x + bb_max_x) / 2.0
			var r0 := Vector3(mid_x, ridge_top, bb_min_z)
			var r1 := Vector3(mid_x, ridge_top, bb_max_z)
			var half_w := roof_sx / 2.0
			var slope_l := sqrt(half_w * half_w + ridge_h * ridge_h)
			var n_left := Vector3(-ridge_h / slope_l, half_w / slope_l, 0)
			var n_right := Vector3(ridge_h / slope_l, half_w / slope_l, 0)

			# Скат left: c0, r0, r1, c3
			var vi: int = 0
			rv.append(c0); rv.append(r0); rv.append(r1); rv.append(c3)
			ru.append(Vector2(0, 1)); ru.append(Vector2(0, 0))
			ru.append(Vector2(roof_sz * 0.2, 0)); ru.append(Vector2(roof_sz * 0.2, 1))
			for _i in 4: rn.append(n_left)
			ri.append_array([0, 1, 2, 0, 2, 3])

			# Скат right: c1, c2, r1, r0
			vi = rv.size()
			rv.append(c1); rv.append(c2); rv.append(r1); rv.append(r0)
			ru.append(Vector2(0, 1)); ru.append(Vector2(roof_sz * 0.2, 1))
			ru.append(Vector2(roof_sz * 0.2, 0)); ru.append(Vector2(0, 0))
			for _i in 4: rn.append(n_right)
			ri.append_array([vi, vi + 1, vi + 2, vi, vi + 2, vi + 3])

			# Фронтон front: c0, c1, r0
			var n_front := Vector3(0, 0, -1)
			vi = 0
			fv.append(c0); fv.append(c1); fv.append(r0)
			fu.append(Vector2(0, 0)); fu.append(Vector2(1, 0)); fu.append(Vector2(0.5, 1))
			for _i in 3: fn.append(n_front)
			fi.append_array([0, 1, 2])

			# Фронтон back: c3, r1, c2
			var n_back := Vector3(0, 0, 1)
			vi = fv.size()
			fv.append(c3); fv.append(r1); fv.append(c2)
			fu.append(Vector2(0, 0)); fu.append(Vector2(0.5, 1)); fu.append(Vector2(1, 0))
			for _i in 3: fn.append(n_back)
			fi.append_array([vi, vi + 1, vi + 2])

		# Скаты крыши
		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)
		roof_arrays[Mesh.ARRAY_VERTEX] = rv
		roof_arrays[Mesh.ARRAY_TEX_UV] = ru
		roof_arrays[Mesh.ARRAY_NORMAL] = rn
		roof_arrays[Mesh.ARRAY_INDEX] = ri

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_mesh_instance := MeshInstance3D.new()
		roof_mesh_instance.mesh = roof_mesh
		roof_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		roof_mesh_instance.material_override = _gabled_roof_material
		wall_mesh_instance.add_child(roof_mesh_instance)

		# Фронтоны — отдельный меш с цветным материалом
		if fi.size() > 0:
			var gable_arrays := []
			gable_arrays.resize(Mesh.ARRAY_MAX)
			gable_arrays[Mesh.ARRAY_VERTEX] = fv
			gable_arrays[Mesh.ARRAY_TEX_UV] = fu
			gable_arrays[Mesh.ARRAY_NORMAL] = fn
			gable_arrays[Mesh.ARRAY_INDEX] = fi

			var gable_mesh := ArrayMesh.new()
			gable_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, gable_arrays)

			var gable_material := StandardMaterial3D.new()
			gable_material.albedo_color = building_override.gable_color
			gable_material.cull_mode = BaseMaterial3D.CULL_DISABLED

			var gable_instance := MeshInstance3D.new()
			gable_instance.mesh = gable_mesh
			gable_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			gable_instance.material_override = gable_material
			wall_mesh_instance.add_child(gable_instance)

	else:
		# === ПЛОСКАЯ КРЫША (с per-vertex heights для педиментов) ===
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
		if effective_roof_type != "eaved":
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
				# Skip parapet for edges with raised pediment walls
				if extra_height[i] > 0.0 or extra_height[i_next] > 0.0:
					continue
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

			var parapet_material := ShaderMaterial.new()
			parapet_material.shader = BuildingWallShader
			parapet_material.set_shader_parameter("use_texture", false)
			parapet_material.set_shader_parameter("albedo_color", Color(0.5, 0.5, 0.5))
			parapet_material.set_shader_parameter("roughness_base", 0.7)
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
	for i in range(points.size()):
		var fp1 := points[i]
		var fp2 := points[(i + 1) % points.size()]
		var fdir := (fp2 - fp1).normalized()
		var fnorm := Vector3(-fdir.y * normal_sign, 0.0, fdir.x * normal_sign)
		var fvi := fv2.size()
		var fb2_1 := _sample_elevation(fp1.x, fp1.y) - FOUNDATION_DEPTH
		var fb2_2 := _sample_elevation(fp2.x, fp2.y) - FOUNDATION_DEPTH
		fv2.append(Vector3(fp1.x, ft2, fp1.y))
		fv2.append(Vector3(fp2.x, ft2, fp2.y))
		fv2.append(Vector3(fp2.x, fb2_2, fp2.y))
		fv2.append(Vector3(fp1.x, fb2_1, fp1.y))
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
	# Bottom cap — seal foundation from below
	var bottom_tri2 := Geometry2D.triangulate_polygon(points)
	if bottom_tri2.size() >= 3:
		var cap_y2 := base_elev - FOUNDATION_CAP_DEPTH
		for i in range(0, bottom_tri2.size(), 3):
			var bvi := fv2.size()
			var bp1 := points[bottom_tri2[i]]
			var bp2 := points[bottom_tri2[i + 1]]
			var bp3 := points[bottom_tri2[i + 2]]
			fv2.append(Vector3(bp1.x, cap_y2, bp1.y))
			fv2.append(Vector3(bp3.x, cap_y2, bp3.y))
			fv2.append(Vector3(bp2.x, cap_y2, bp2.y))
			fu2.append(Vector2.ZERO)
			fu2.append(Vector2.ZERO)
			fu2.append(Vector2.ZERO)
			fn2.append(Vector3.DOWN)
			fn2.append(Vector3.DOWN)
			fn2.append(Vector3.DOWN)
			fi2.append(bvi)
			fi2.append(bvi + 1)
			fi2.append(bvi + 2)
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

	# Split into grid cells for accurate elevation following on slopes
	var grid_polys := _split_polygon_by_grid(points, 10.0)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var tri_indices := PackedInt32Array()

	var uv_scale := 0.25  # Масштаб UV для земли (20м = 1 повтор текстуры)

	for cell_poly in grid_polys:
		var indices := Geometry2D.triangulate_polygon(cell_poly)
		if indices.size() < 3:
			continue
		var base_idx: int = vertices.size()
		for p in cell_poly:
			var h := _sample_elevation(p.x, p.y) + height_offset
			vertices.append(Vector3(p.x, h, p.y))
			uvs.append(Vector2(p.x * uv_scale, p.y * uv_scale))
			normals.append(Vector3.UP)
		for idx in indices:
			tri_indices.append(base_idx + idx)

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

	# Для воды добавляем коллизию с группой Water
	if is_water and vertices.size() >= 3 and tri_indices.size() >= 3:
		_create_water_collision(vertices, tri_indices, parent)


## Создаёт коллизию для водной поверхности с группой "Water"
func _create_water_collision(vertices: PackedVector3Array, indices: PackedInt32Array, parent: Node3D) -> void:
	var faces := PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(vertices[indices[i]])
		faces.append(vertices[indices[i + 1]])
		faces.append(vertices[indices[i + 2]])
	if faces.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "WaterCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("Water")
	var col_shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	col_shape.shape = concave
	body.add_child(col_shape)
	parent.add_child(body)


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
		var h := _sample_elevation(p.x, p.y) + 0.01
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


## Get spawn elevation by reading the elevation cache for chunk 0,0.
## Returns ASL elevation at spawn point, or 0.0 if no cache.
func get_spawn_elevation() -> float:
	if not enable_elevation:
		return 0.0
	# Cache key includes lat/lon to be location-aware
	# Try current version first, then fall back to in-memory data
	var cache_key := "elev_v%d_%.4f_%.4f_0,0.json" % [ElevationLoader.CACHE_VERSION, start_lat, start_lon]
	var cache_path := ProjectSettings.globalize_path("user://osm_cache/" + cache_key)
	var file := FileAccess.open(cache_path, FileAccess.READ)
	if not file:
		cache_key = "elev_v%d_%.4f_%.4f_-1,-1.json" % [ElevationLoader.CACHE_VERSION, start_lat, start_lon]
		cache_path = ProjectSettings.globalize_path("user://osm_cache/" + cache_key)
		file = FileAccess.open(cache_path, FileAccess.READ)
		if not file:
			# Try in-memory elevation data
			var grid_data: Dictionary = _chunk_elevation_data.get("0,0", _chunk_elevation_data.get("-1,-1", {}))
			if not grid_data.is_empty():
				var grid: Array = grid_data.get("grid", [])
				var res: int = grid_data.get("grid_res", 5)
				var center := res / 2
				if grid.size() > center and grid[center].size() > center:
					return float(grid[center][center])
			return 0.0
	var json_string := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(json_string) != OK:
		return 0.0
	var data: Dictionary = json.data
	var grid: Array = data.get("grid", [])
	var res: int = data.get("grid_res", 5)
	var center := res / 2
	if grid.size() > center and grid[center].size() > center:
		return float(grid[center][center])
	return 0.0


## Sample terrain elevation at world position using bilinear interpolation.
## Returns ASL elevation. Returns 0.0 if no data.
func _sample_elevation(world_x: float, world_z: float) -> float:
	if not enable_elevation:
		return 0.0
	# Find which chunk contains this position
	var cx := int(floor(world_x / chunk_size))
	var cz := int(floor(world_z / chunk_size))
	var ck := "%d,%d" % [cx, cz]
	var grid_data: Dictionary = _chunk_elevation_data.get(ck, {})
	if grid_data.is_empty():
		# Position at chunk boundary or slightly past edge — floor() rounded to
		# unloaded adjacent chunk. Try previous chunk in each dimension (covers
		# right/bottom edge boundaries and road vertices extending past edge).
		for try_key in ["%d,%d" % [cx - 1, cz], "%d,%d" % [cx, cz - 1], "%d,%d" % [cx - 1, cz - 1]]:
			grid_data = _chunk_elevation_data.get(try_key, {})
			if not grid_data.is_empty():
				break
		if grid_data.is_empty():
			return 0.0
	var grid: Array = grid_data.get("grid", [])
	var grid_res: int = grid_data.get("grid_res", 5)
	var base_x: float = grid_data.get("base_x", 0.0)
	var base_z: float = grid_data.get("base_z", 0.0)
	var step: float = grid_data.get("grid_step", 50.0)
	if grid.size() < grid_res:
		return 0.0
	# Normalized position within grid
	var fx: float = clampf((world_x - base_x) / step, 0.0, float(grid_res - 1))
	var fz: float = clampf((world_z - base_z) / step, 0.0, float(grid_res - 1))
	var ix: int = mini(int(fx), grid_res - 2)
	var iz: int = mini(int(fz), grid_res - 2)
	var tx: float = fx - float(ix)
	var tz: float = fz - float(iz)
	# Bilinear interpolation
	var h00: float = grid[iz][ix]
	var h10: float = grid[iz][ix + 1]
	var h01: float = grid[iz + 1][ix]
	var h11: float = grid[iz + 1][ix + 1]
	var h0: float = h00 * (1.0 - tx) + h10 * tx
	var h1: float = h01 * (1.0 - tx) + h11 * tx
	var raw: float = h0 * (1.0 - tz) + h1 * tz
	return raw


## Thread-safe elevation sampling from pre-fetched grid data (no instance vars).
## Used by worker threads that receive elevation data via task_data.
static func _sample_elevation_static(world_x: float, world_z: float,
		elev_grid: Dictionary, base_elev: float) -> float:
	if elev_grid.is_empty():
		return 0.0
	var grid: Array = elev_grid.get("grid", [])
	var grid_res: int = elev_grid.get("grid_res", 5)
	var base_x: float = elev_grid.get("base_x", 0.0)
	var base_z: float = elev_grid.get("base_z", 0.0)
	var step: float = elev_grid.get("grid_step", 50.0)
	if grid.size() < grid_res:
		return 0.0
	var fx: float = clampf((world_x - base_x) / step, 0.0, float(grid_res - 1))
	var fz: float = clampf((world_z - base_z) / step, 0.0, float(grid_res - 1))
	var ix: int = mini(int(fx), grid_res - 2)
	var iz: int = mini(int(fz), grid_res - 2)
	var tx: float = fx - float(ix)
	var tz: float = fz - float(iz)
	var h00: float = grid[iz][ix]
	var h10: float = grid[iz][ix + 1]
	var h01: float = grid[iz + 1][ix]
	var h11: float = grid[iz + 1][ix + 1]
	var h0: float = h00 * (1.0 - tx) + h10 * tx
	var h1: float = h01 * (1.0 - tx) + h11 * tx
	var raw: float = h0 * (1.0 - tz) + h1 * tz
	return raw


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
		_enqueue_chunk_load_request(key, 0.5)
	_process_chunk_load_queue()


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
	return 0.1 + fmod(hash_val, 1.0) * 0.1  # 0.1 to 0.2


static func _add_recess_quad(
	vertices: PackedVector3Array, uvs: PackedVector2Array,
	normals: PackedVector3Array, indices: PackedInt32Array,
	v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
	normal: Vector3, colors: PackedColorArray = PackedColorArray(),
	color: Color = Color.BLACK
) -> void:
	var idx := vertices.size()
	vertices.append(v0)
	vertices.append(v1)
	vertices.append(v2)
	vertices.append(v3)
	uvs.append(Vector2(0.0, 0.0))
	uvs.append(Vector2(0.0, WINDOW_RECESS_DEPTH))
	uvs.append(Vector2(WINDOW_SIZE * 0.1, WINDOW_RECESS_DEPTH))
	uvs.append(Vector2(WINDOW_SIZE * 0.1, 0.0))
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colors.append(color)
	colors.append(color)
	colors.append(color)
	colors.append(color)
	indices.append(idx + 0)
	indices.append(idx + 1)
	indices.append(idx + 2)
	indices.append(idx + 0)
	indices.append(idx + 2)
	indices.append(idx + 3)


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


## Returns axis-aligned bounding box of a way's nodes in local coordinates.
## Used to filter huge water polygons by bbox-overlap instead of centroid
## (centroid of a 11-km-long reservoir lies nowhere near any single chunk).
func _get_way_local_bbox(nodes: Array) -> Rect2:
	if nodes.size() == 0:
		return Rect2()
	var first: Vector2 = _latlon_to_local(nodes[0].lat, nodes[0].lon)
	var min_pt := first
	var max_pt := first
	for i in range(1, nodes.size()):
		var p: Vector2 = _latlon_to_local(nodes[i].lat, nodes[i].lon)
		min_pt.x = minf(min_pt.x, p.x)
		min_pt.y = minf(min_pt.y, p.y)
		max_pt.x = maxf(max_pt.x, p.x)
		max_pt.y = maxf(max_pt.y, p.y)
	return Rect2(min_pt, max_pt - min_pt)


## Get chunk key from parent node name (e.g. "Chunk_1_2" -> "1,2")
func _get_chunk_key_from_node(node: Node3D) -> String:
	if not node:
		return ""
	var node_name: String = node.name
	# Format: "Chunk_x,z" (e.g. "Chunk_1,2")
	if node_name.begins_with("Chunk_"):
		return node_name.substr(6)  # Возвращаем "x,z" часть
	return ""

## Per-chunk deferred dict helpers
func _deferred_append(dict: Dictionary, chunk_key: String, item: Dictionary) -> void:
	if not dict.has(chunk_key):
		dict[chunk_key] = []
	dict[chunk_key].append(item)

func _deferred_total_size(dict: Dictionary) -> int:
	var total := 0
	for arr in dict.values():
		total += arr.size()
	return total


func get_runtime_debug_log_path() -> String:
	if _debug_log_absolute_path == "":
		_debug_log_absolute_path = ProjectSettings.globalize_path(debug_log_path)
	return _debug_log_absolute_path


func _open_runtime_debug_log() -> void:
	if not debug_log_to_file:
		return
	_debug_log_absolute_path = ProjectSettings.globalize_path(debug_log_path)
	var log_dir := _debug_log_absolute_path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(log_dir)
	if dir_err != OK and not DirAccess.dir_exists_absolute(log_dir):
		push_warning("OSM runtime debug log directory could not be created: %s" % _debug_log_absolute_path)
		return
	_debug_log_file = FileAccess.open(debug_log_path, FileAccess.WRITE)
	if _debug_log_file == null:
		push_warning("OSM runtime debug log could not be opened: %s" % _debug_log_absolute_path)
		return
	print("OSM: Runtime debug log -> %s" % _debug_log_absolute_path)
	_write_runtime_debug_log("SESSION_START")
	_write_runtime_debug_log("SESSION_CONFIG chunk_debug=%s road_debug=%s start_lat=%.6f start_lon=%.6f chunk_size=%.1f load_distance=%.1f unload_distance=%.1f" % [
		str(debug_chunk_lifecycle),
		str(debug_log_roads),
		start_lat,
		start_lon,
		chunk_size,
		load_distance,
		unload_distance,
	])


func _close_runtime_debug_log() -> void:
	if _debug_log_file:
		_write_runtime_debug_log("SESSION_END")
		_debug_log_file.flush()
		_debug_log_file.close()
		_debug_log_file = null


func _write_runtime_debug_log(message: String) -> void:
	if _debug_log_file == null:
		return
	var timestamp := Time.get_datetime_string_from_system()
	_debug_log_file.store_line("%s uptime_ms=%d %s" % [timestamp, Time.get_ticks_msec(), message])
	_debug_log_file.flush()


func _emit_chunk_debug(message: String) -> void:
	if _chunk_debug_enabled():
		print(message)
	if debug_log_to_file:
		_write_runtime_debug_log(message)


func _emit_road_debug(message: String) -> void:
	if debug_print:
		print(message)
	if debug_log_to_file and debug_log_roads:
		_write_runtime_debug_log(message)


func _chunk_debug_enabled() -> bool:
	return debug_print or debug_chunk_lifecycle


func _ensure_chunk_state(chunk_key: String, node: Node3D = null) -> Dictionary:
	var state: Dictionary = _chunk_state.get(chunk_key, {})
	if state.is_empty():
		state = {
			"node": null,
			"stage": "requested",
			"generation": _load_generation,
			"request_started_ms": 0,
			"data_loaded_ms": 0,
			"tgen_applied_ms": 0,
			"phase3_done_ms": 0,
			"finalize_done_ms": 0,
			"activated_ms": 0,
			"last_error": "",
			"retry_count": 0,
			"cancelled": false,
			"last_stage_change_ms": 0,
			"last_stall_report_ms": 0,
		}
	if node != null:
		state["node"] = node
	_chunk_state[chunk_key] = state
	return state


func _set_chunk_stage(chunk_key: String, stage: String, extra: Dictionary = {}) -> void:
	var now := Time.get_ticks_msec()
	var state: Dictionary = _ensure_chunk_state(chunk_key)
	state["stage"] = stage
	state["last_stage_change_ms"] = now
	match stage:
		"http_loaded":
			state["data_loaded_ms"] = now
		"terrain_gen_ready":
			state["tgen_applied_ms"] = now
		"finalizing":
			state["phase3_done_ms"] = now
			state["finalize_done_ms"] = now
		"ready":
			state["activated_ms"] = now
		"cancelled":
			state["cancelled"] = true
		"failed", "unloaded":
			state["cancelled"] = false
	if stage not in ["cancelled", "failed", "unloaded"] and not extra.has("cancelled"):
		state["cancelled"] = false
	for key in extra:
		state[key] = extra[key]
	_chunk_state[chunk_key] = state
	_emit_chunk_debug("CHUNK_STAGE key=%s stage=%s gen=%s retry=%s" % [
		chunk_key,
		stage,
		str(state.get("generation", -1)),
		str(state.get("retry_count", 0))
	])


func _get_chunk_node(chunk_key: String) -> Node3D:
	if not _chunk_state.has(chunk_key):
		return null
	var node: Node3D = _chunk_state[chunk_key].get("node", null)
	if node and is_instance_valid(node):
		return node
	return null


func _is_chunk_alive(chunk_key: String) -> bool:
	if not _chunk_state.has(chunk_key):
		return false
	var state: Dictionary = _chunk_state[chunk_key]
	var stage: String = state.get("stage", "")
	if stage in ["cancelled", "failed", "unloaded"]:
		return false
	var node: Node3D = state.get("node", null)
	return node != null and is_instance_valid(node)


func _chunk_has_key_in_array(queue: Array, chunk_key: String) -> bool:
	for item in queue:
		if item is Dictionary and item.get("chunk_key", "") == chunk_key:
			return true
	return false


func _pending_road_task_count_for_chunk(chunk_key: String) -> int:
	return int(_pending_road_tasks_by_chunk.get(chunk_key, 0))


func _increment_pending_road_task(chunk_key: String) -> void:
	if chunk_key == "":
		return
	_pending_road_tasks_by_chunk[chunk_key] = _pending_road_task_count_for_chunk(chunk_key) + 1


func _decrement_pending_road_task(chunk_key: String) -> void:
	if chunk_key == "":
		return
	var remaining: int = maxi(0, _pending_road_task_count_for_chunk(chunk_key) - 1)
	if remaining == 0:
		_pending_road_tasks_by_chunk.erase(chunk_key)
	else:
		_pending_road_tasks_by_chunk[chunk_key] = remaining


func _chunk_has_pending_road_inputs(chunk_key: String) -> bool:
	if chunk_key == "":
		return false
	if _road_queue.has(chunk_key):
		return true
	if _chunk_has_key_in_array(_road_results, chunk_key):
		return true
	return _pending_road_task_count_for_chunk(chunk_key) > 0





func _get_prioritized_road_queue_keys() -> Array:
	var finalizing: Array = []
	var activating: Array = []
	var normal: Array = []
	for chunk_key in _road_queue.keys():
		if not _should_process_chunk(chunk_key):
			continue
		if _pending_batch_chunks.has(chunk_key):
			finalizing.append(chunk_key)
		elif _chunk_activation_pending.has(chunk_key):
			activating.append(chunk_key)
		else:
			normal.append(chunk_key)
	if finalizing.size() > 1:
		finalizing.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	if activating.size() > 1:
		activating.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	if normal.size() > 1:
		normal.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	finalizing.append_array(activating)
	finalizing.append_array(normal)
	return finalizing


func _get_road_dispatch_order(max_tasks: int) -> Array[String]:
	var dispatch_order: Array[String] = []
	if max_tasks <= 0:
		return dispatch_order
	var prioritized_keys: Array = _get_prioritized_road_queue_keys()
	if prioritized_keys.is_empty():
		return dispatch_order
	var remaining_per_chunk: Dictionary = {}
	for chunk_key in prioritized_keys:
		var queued_items: Array = _road_queue.get(chunk_key, [])
		if not queued_items.is_empty():
			remaining_per_chunk[chunk_key] = queued_items.size()
	while dispatch_order.size() < max_tasks and not remaining_per_chunk.is_empty():
		var dispatched_in_round := false
		for chunk_key in prioritized_keys:
			if dispatch_order.size() >= max_tasks:
				break
			var remaining: int = int(remaining_per_chunk.get(chunk_key, 0))
			if remaining <= 0:
				continue
			dispatch_order.append(chunk_key)
			dispatched_in_round = true
			remaining -= 1
			if remaining <= 0:
				remaining_per_chunk.erase(chunk_key)
			else:
				remaining_per_chunk[chunk_key] = remaining
		if not dispatched_in_round:
			break
	return dispatch_order


func _collect_chunk_blockers(chunk_key: String) -> Array[String]:
	var blockers: Array[String] = []
	var state: Dictionary = _chunk_state.get(chunk_key, {})
	var stage: String = state.get("stage", "")
	if stage in ["requested", "http_loaded", "terrain_gen_ready", "phase3"]:
		blockers.append("stage:" + stage)
	if _road_queue.has(chunk_key):
		blockers.append("road_queue")
	if _pending_road_task_count_for_chunk(chunk_key) > 0:
		blockers.append("road_tasks_pending")
	if _chunk_has_key_in_array(_road_results, chunk_key):
		blockers.append("road_results_pending")
	if _pending_batch_chunks.has(chunk_key):
		blockers.append("pending_batch")
	if _road_batch_data.has(chunk_key):
		blockers.append("road_batch_data")
	if _building_geo_finalize_queue.has(chunk_key):
		blockers.append("building_geo_finalize")
	if _building_geo_batch.has(chunk_key):
		blockers.append("building_geo_batch")
	if _window_finalize_queue.has(chunk_key):
		blockers.append("window_finalize")
	if _window_finalize_progress.has(chunk_key):
		blockers.append("window_finalize_progress")
	if _curb_geo_batch.has(chunk_key):
		blockers.append("curb_geo_batch")
	if _lamp_batches_to_finalize.has(chunk_key):
		blockers.append("lamp_finalize")
	if _tree_batches_to_finalize.has(chunk_key):
		blockers.append("tree_finalize")
	if _tree_batch_data.has(chunk_key):
		blockers.append("tree_batch_data")
	if _billboard_batches_to_finalize.has(chunk_key):
		blockers.append("billboard_finalize")
	if _fence_batches_to_finalize.has(chunk_key):
		blockers.append("fence_finalize")
	if _deferred_footway_queue.has(chunk_key):
		blockers.append("deferred_footway")
	if _deferred_lamp_queue.has(chunk_key):
		blockers.append("deferred_lamps")
	if _deferred_manhole_queue.has(chunk_key):
		blockers.append("deferred_manholes")
	if _deferred_billboard_queue.has(chunk_key):
		blockers.append("deferred_billboards")
	if _deferred_building_collisions.has(chunk_key):
		blockers.append("deferred_building_collisions")
	if _deferred_tree_collisions.has(chunk_key):
		blockers.append("deferred_tree_collisions")
	if _deferred_road_collisions.has(chunk_key):
		blockers.append("deferred_road_collisions")
	if _deferred_terrain_collisions.has(chunk_key):
		blockers.append("deferred_terrain_collisions")
	if _deferred_lamp_lights.has(chunk_key):
		blockers.append("deferred_lamp_lights")
	if _deferred_fence_edges.has(chunk_key):
		blockers.append("deferred_fence_edges")
	if _chunk_has_key_in_array(_phase3_queue, chunk_key):
		blockers.append("phase3_queue")
	if _chunk_has_key_in_array(_terrain_gen_results, chunk_key):
		blockers.append("terrain_gen_results")
	if _chunk_has_key_in_array(_terrain_thread_results, chunk_key):
		blockers.append("terrain_thread_results")
	return blockers


func _collect_chunk_activation_blockers(chunk_key: String) -> Array[String]:
	var blockers: Array[String] = []
	var state: Dictionary = _chunk_state.get(chunk_key, {})
	var stage: String = state.get("stage", "")
	if stage in ["requested", "http_loaded", "terrain_gen_ready", "phase3"]:
		blockers.append("stage:" + stage)
	if _chunk_has_key_in_array(_phase3_queue, chunk_key):
		blockers.append("phase3_queue")
	if _pending_batch_chunks.has(chunk_key):
		blockers.append("pending_batch")
	if _building_geo_finalize_queue.has(chunk_key):
		blockers.append("building_geo_finalize")
	if _lamp_batches_to_finalize.has(chunk_key):
		blockers.append("lamp_finalize")
	if _tree_batches_to_finalize.has(chunk_key):
		blockers.append("tree_finalize")
	if _billboard_batches_to_finalize.has(chunk_key):
		blockers.append("billboard_finalize")
	if _fence_batches_to_finalize.has(chunk_key):
		blockers.append("fence_finalize")
	if _deferred_footway_queue.has(chunk_key):
		blockers.append("deferred_footway")
	if _deferred_lamp_queue.has(chunk_key):
		blockers.append("deferred_lamps")
	if _deferred_manhole_queue.has(chunk_key):
		blockers.append("deferred_manholes")
	if _deferred_billboard_queue.has(chunk_key):
		blockers.append("deferred_billboards")
	if _deferred_building_collisions.has(chunk_key):
		blockers.append("deferred_building_collisions")
	if _deferred_tree_collisions.has(chunk_key):
		blockers.append("deferred_tree_collisions")
	if _deferred_road_collisions.has(chunk_key):
		blockers.append("deferred_road_collisions")
	if _deferred_terrain_collisions.has(chunk_key):
		blockers.append("deferred_terrain_collisions")
	if _deferred_lamp_lights.has(chunk_key):
		blockers.append("deferred_lamp_lights")
	if _deferred_fence_edges.has(chunk_key):
		blockers.append("deferred_fence_edges")
	return blockers


func _chunk_has_pending_work(chunk_key: String) -> bool:
	return not _collect_chunk_activation_blockers(chunk_key).is_empty()


func _can_purge_chunk_on_cull(chunk_key: String) -> bool:
	if _initial_loading and not _initial_chunks_completed.has(chunk_key):
		return false
	if _chunk_activation_pending.has(chunk_key):
		return false
	if not _chunk_state.has(chunk_key):
		return true
	var state: Dictionary = _chunk_state[chunk_key]
	if state.get("stage", "") != "ready":
		return false
	return _collect_chunk_blockers(chunk_key).is_empty()


func get_chunk_debug_state(chunk_key: String) -> Dictionary:
	if not _chunk_state.has(chunk_key):
		return {}
	var state: Dictionary = _chunk_state[chunk_key].duplicate(true)
	state["has_loaded_entry"] = _loaded_chunks.has(chunk_key)
	state["has_loading_entry"] = _loading_chunks.has(chunk_key)
	state["activation_state"] = _chunk_activation_pending.get(chunk_key, null)
	state["blockers"] = _collect_chunk_blockers(chunk_key)
	state["activation_blockers"] = _collect_chunk_activation_blockers(chunk_key)
	state["can_purge_on_cull"] = _can_purge_chunk_on_cull(chunk_key)
	return state


func get_all_chunk_debug_states() -> Dictionary:
	var result: Dictionary = {}
	for chunk_key in _chunk_state.keys():
		result[chunk_key] = get_chunk_debug_state(chunk_key)
	return result


func dump_chunk_pipeline(chunk_key: String = "") -> void:
	if chunk_key == "":
		var keys: Array = _chunk_state.keys()
		keys.sort()
		for key in keys:
			_emit_chunk_debug("CHUNK_PIPELINE %s %s" % [key, str(get_chunk_debug_state(key))])
		return
	_emit_chunk_debug("CHUNK_PIPELINE %s %s" % [chunk_key, str(get_chunk_debug_state(chunk_key))])


func _drop_chunk_runtime_state(chunk_key: String, free_node: bool = true) -> void:
	var parent: Node3D = _get_chunk_node(chunk_key)
	_loading_chunks.erase(chunk_key)
	_chunk_activation_pending.erase(chunk_key)
	_chunk_culling_cooldown.erase(chunk_key)
	_purge_chunk_queues(chunk_key)
	_chunk_terrain_roads.erase(chunk_key)
	_chunk_water_polygons.erase(chunk_key)
	_deferred_path_polys.erase(chunk_key)
	_remove_loading_placeholder(chunk_key)
	if parent and is_instance_valid(parent):
		_terrain_objects_queue = _terrain_objects_queue.filter(func(item): return item.get("parent") != parent)
		_infrastructure_queue = _infrastructure_queue.filter(func(item): return item.get("parent") != parent)
		_curb_queue = _curb_queue.filter(func(item): return item.get("parent") != parent)
		_curb_smoothed_queue = _curb_smoothed_queue.filter(func(item): return item.get("parent") != parent)
	_deferred_add_child_queue = _deferred_add_child_queue.filter(
		func(item): return item.get("chunk_key", "") != chunk_key and is_instance_valid(item.get("parent")) and is_instance_valid(item.get("child")))
	_road_mutex.lock()
	_road_results = _road_results.filter(func(item): return item.get("chunk_key", "") != chunk_key)
	_pending_road_tasks_by_chunk.erase(chunk_key)
	_road_mutex.unlock()
	_veg_mutex.lock()
	_veg_thread_results = _veg_thread_results.filter(func(item): return item.get("chunk_key", "") != chunk_key)
	_veg_mutex.unlock()
	_terrain_thread_mutex.lock()
	var old_tgen_size := _terrain_gen_results.size()
	_terrain_gen_results = _terrain_gen_results.filter(func(item): return item.get("chunk_key", "") != chunk_key)
	_pending_terrain_gen_tasks = maxi(0, _pending_terrain_gen_tasks - (old_tgen_size - _terrain_gen_results.size()))
	var old_terrain_size := _terrain_thread_results.size()
	_terrain_thread_results = _terrain_thread_results.filter(func(item): return item.get("chunk_key", "") != chunk_key)
	_pending_terrain_tasks = maxi(0, _pending_terrain_tasks - (old_terrain_size - _terrain_thread_results.size()))
	_terrain_thread_mutex.unlock()
	if _loaded_chunks.has(chunk_key):
		_loaded_chunks.erase(chunk_key)
	_chunk_data_received.erase(chunk_key)
	if free_node and parent and is_instance_valid(parent):
		parent.queue_free()
	_cleanup_chunk_hash_cells(chunk_key)
	if _chunk_state.has(chunk_key):
		var state: Dictionary = _chunk_state[chunk_key]
		state["node"] = null
		_chunk_state[chunk_key] = state


func _retry_chunk_load(chunk_key: String, reason: String) -> void:
	var state: Dictionary = _ensure_chunk_state(chunk_key)
	var retries := int(state.get("retry_count", 0)) + 1
	_set_chunk_stage(chunk_key, "failed", {
		"last_error": reason,
		"retry_count": retries,
	})
	_emit_chunk_debug("CHUNK_DROP key=%s reason=%s stage=%s" % [chunk_key, reason, str(_chunk_state.get(chunk_key, {}).get("stage", ""))])
	if _chunk_debug_enabled():
		dump_chunk_pipeline(chunk_key)
	_drop_chunk_runtime_state(chunk_key)
	var coords: PackedStringArray = chunk_key.split(",")
	if coords.size() == 2:
		_load_chunk(int(coords[0]), int(coords[1]))

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

	# Deduplication: same road loaded by overlapping chunks → same lamp positions
	var pos_key := "%d_%d" % [int(lamp_pos.x), int(lamp_pos.z)]
	if _created_lamp_positions.has(pos_key):
		return
	_created_lamp_positions[pos_key] = true

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
		"broken": is_broken,
		"yaw": yaw
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

	# Free any existing lights for this chunk (safety: prevents duplicates if finalized twice)
	if _lamp_lights_by_chunk.has(chunk_key):
		for old_light in _lamp_lights_by_chunk[chunk_key]:
			if is_instance_valid(old_light):
				old_light.queue_free()
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
		_deferred_append(_deferred_lamp_lights, chunk_key, {
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
	# Update light visibility for batched lamps (deferred path)
	for chunk_key in _lamp_lights_by_chunk.keys():
		var lights: Array = _lamp_lights_by_chunk[chunk_key]
		for light in lights:
			if is_instance_valid(light):
				var is_broken: bool = light.get_meta("broken", false)
				light.visible = is_night and not is_broken

	# Update light visibility for immediate lamps
	for light in _lamp_batch_lights:
		if is_instance_valid(light):
			var is_broken: bool = light.get_meta("is_broken", false)
			light.visible = is_night and not is_broken

	var total_by_chunk := 0
	for chunk_key2 in _lamp_lights_by_chunk.keys():
		total_by_chunk += _lamp_lights_by_chunk[chunk_key2].size()
	print("OSM: Updated lamp night mode (is_night=%s) by_chunk=%d immediate=%d deferred_pending=%d" % [is_night, total_by_chunk, _lamp_batch_lights.size(), _deferred_total_size(_deferred_lamp_lights)])

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
		mm.use_colors = true
		mm.mesh = config["mesh_lod0"]
		mm.instance_count = transforms.size()
		for i in range(transforms.size()):
			mm.set_instance_transform(i, transforms[i])
			# Вариативность цвета кроны: от тёмно-зелёного до жёлто-зелёного
			var pos: Vector3 = (transforms[i] as Transform3D).origin
			var h1 := fmod(absf(pos.x * 73.1 + pos.z * 137.9), 1.0)
			var h2 := fmod(absf(pos.x * 41.3 + pos.z * 97.7), 1.0)
			var r := 0.12 + h1 * 0.3
			var g := 0.3 + h2 * 0.4
			var b := 0.03 + h1 * 0.12
			mm.set_instance_color(i, Color(r, g, b))
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
		_deferred_append(_deferred_tree_collisions, chunk_key, {
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
		_deferred_append(_deferred_billboard_queue, chunk_key, {
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
	if not enable_vegetation:
		return
	var instance: Node3D = GARBAGE_CONTAINER_SCENE.instantiate()
	instance.position = Vector3(pos.x, elevation, pos.y)
	# Отключаем тени на всех MeshInstance3D
	for child in instance.get_children():
		_set_no_shadow_recursive(child)
	parent.add_child(instance)


func _place_custom_building_model(override, center: Vector2, parent: Node3D, base_elev: float) -> void:
	var model_path: String = override.custom_model_path
	if not _custom_model_cache.has(model_path):
		if ResourceLoader.exists(model_path):
			_custom_model_cache[model_path] = load(model_path)
		else:
			push_warning("Custom building model not found: " + model_path)
			return
	var scene: PackedScene = _custom_model_cache[model_path]
	if not scene:
		return
	var inst: Node3D = scene.instantiate()
	var scale_val: float = override.custom_model_scale
	inst.position = Vector3(center.x, base_elev + override.custom_model_y_offset, center.y)
	inst.scale = Vector3.ONE * scale_val
	inst.rotation_degrees.y = override.custom_model_rotation_y
	var vis_range: float = override.custom_model_visibility_range
	_set_visibility_range_recursive(inst, vis_range)
	parent.add_child(inst)
	print("OSM: Placed custom building model '%s' at (%.1f, %.1f), scale=%.2f, vis=%.0fm" % [
		model_path.get_file(), center.x, center.y, scale_val, vis_range])


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

	# SpotLight3D направленный вниз
	var is_broken := randf() < 0.05
	var is_night := _is_night_mode
	var lamp_light := SpotLight3D.new()
	lamp_light.position = _lamp_light_offset
	# lamp_root уже повёрнут по Y (модель боком), компенсируем +90° чтобы -Z смотрела к дороге
	lamp_light.rotation_degrees.y = 90.0 + 180.0
	lamp_light.rotation_degrees.x = -75  # 15° наклон к дороге от вертикали
	lamp_light.spot_range = 15.0
	lamp_light.spot_angle = 70.0
	lamp_light.spot_attenuation = 1.0
	lamp_light.light_energy = 2.6
	lamp_light.light_color = Color(1.0, 0.65, 0.2)
	lamp_light.light_volumetric_fog_energy = 16.0
	lamp_light.shadow_enabled = false
	lamp_light.light_bake_mode = Light3D.BAKE_DISABLED
	lamp_light.distance_fade_enabled = true
	lamp_light.distance_fade_begin = 120.0
	lamp_light.distance_fade_shadow = 30.0
	lamp_light.distance_fade_length = 30.0
	lamp_light.visible = is_night and not is_broken
	lamp_light.set_meta("is_broken", is_broken)
	lamp_light.add_child(_create_lamp_bulb())
	lamp_light.add_child(_create_debug_light_cone(lamp_light.spot_range, lamp_light.spot_angle))
	lamp_root.add_child(lamp_light)
	_lamp_batch_lights.append(lamp_light)

	parent.add_child(lamp_root)

	if _draw_call_logging_enabled:
		_draw_call_stats["lamps"] += 1


## Создаёт светящийся шарик-лампочку (emission) для фонаря
func _create_lamp_bulb() -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.3)
	mat.emission_energy_multiplier = 15.0
	var mi := MeshInstance3D.new()
	mi.name = "LampBulb"
	mi.mesh = sphere
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 300.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	return mi


## Создаёт полупрозрачный конус для визуализации SpotLight (debug)
## + красный шарик в точке источника света
func _create_debug_light_cone(spot_range: float, spot_angle: float) -> Node3D:
	var root := Node3D.new()
	root.name = "DebugLightVis"
	root.add_to_group("lamp_debug_vis")
	root.visible = _lamp_debug_visible

	# --- Красный шарик (0.5м диаметр) в центре источника ---
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.25
	sphere_mesh.height = 0.5
	var sphere_mat := StandardMaterial3D.new()
	sphere_mat.albedo_color = Color(1.0, 0.0, 0.0)
	sphere_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var sphere_mi := MeshInstance3D.new()
	sphere_mi.mesh = sphere_mesh
	sphere_mi.material_override = sphere_mat
	sphere_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(sphere_mi)

	# --- Конус вдоль -Z (направление SpotLight3D) ---
	# CylinderMesh ориентирован по Y: top (+Y/2) = top_radius, bottom (-Y/2) = bottom_radius
	# top_radius=0 → вершина конуса, bottom_radius=R → основание конуса
	# Нужно: вершина в начале координат (0,0,0), основание на расстоянии spot_range по -Z
	#
	# Поворот rotation_degrees.x = +90: Y→Z, поэтому:
	#   top  (+Y/2) → (+Z/2)  — вершина смещается в +Z (ближе к источнику)
	#   bottom (-Y/2) → (-Z/2) — основание смещается в -Z (вдоль луча)
	# Центр цилиндра (0,0,0), после поворота: top в (0,0,+h/2), bottom в (0,0,-h/2)
	# Сдвиг position.z = -h/2 переносит top в (0,0,0), bottom в (0,0,-h) — ровно по лучу
	var cone_mesh := CylinderMesh.new()
	var radius := spot_range * tan(deg_to_rad(spot_angle))
	cone_mesh.top_radius = 0.0
	cone_mesh.bottom_radius = radius
	cone_mesh.height = spot_range
	cone_mesh.radial_segments = 12
	cone_mesh.rings = 1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.2, 0.15)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mi := MeshInstance3D.new()
	mi.mesh = cone_mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.rotation_degrees.x = 90  # Y→Z: top(+Y)→+Z(ближе), bottom(-Y)→-Z(дальше)
	mi.position.z = -spot_range * 0.5  # top(вершина) в (0,0,0), bottom(основание) в (0,0,-range)
	root.add_child(mi)

	return root


# Создание автобусной остановки
func _create_bus_stop(pos: Vector2, elevation: float, tags: Dictionary, parent: Node3D) -> void:
	# Дедупликация
	var pos_key := "bs_%d_%d" % [int(pos.x), int(pos.y)]
	if _created_bus_stop_positions.has(pos_key):
		return
	_created_bus_stop_positions[pos_key] = true

	# Находим ближайшую дорогу и смещаем остановку с проезжей части на обочину
	var nearby_segs := _get_nearby_road_segments(pos)
	var road_dir := Vector2(0, 1)
	var min_dist := INF
	var best_road_half_w := 3.0
	for seg in nearby_segs:
		var road_p1: Vector2 = seg.p1
		var road_p2: Vector2 = seg.p2
		var road_vec: Vector2 = road_p2 - road_p1
		var road_len: float = road_vec.length()
		if road_len < 0.1:
			continue
		var t: float = clamp((pos - road_p1).dot(road_vec) / (road_len * road_len), 0.0, 1.0)
		var closest: Vector2 = road_p1 + road_vec * t
		var dist: float = pos.distance_to(closest)
		if dist < min_dist:
			min_dist = dist
			best_road_half_w = seg.width * 0.5
			if dist > 0.1:
				road_dir = (closest - pos).normalized()
			else:
				road_dir = Vector2(-road_vec.y, road_vec.x).normalized()

	# Если остановка на дороге или слишком близко — сдвигаем за край дороги
	var shelter_offset := 2.5  # Метры от края дороги до центра навеса
	if min_dist < best_road_half_w + shelter_offset:
		var move_dist: float = best_road_half_w + shelter_offset - min_dist
		pos = pos - road_dir * move_dist  # Отодвигаем ОТ дороги

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

	# Коллизия павильона
	var body := StaticBody3D.new()
	body.name = "BusStopCol"
	body.collision_layer = 2  # Buildings layer
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 2.5, 1.2)
	shape.shape = box
	shape.position.y = 1.25
	body.add_child(shape)
	stop_root.add_child(body)

	parent.add_child(stop_root)


func _get_direction_to_nearest_road(pos: Vector2) -> Vector2:
	"""Находит направление К ближайшей дороге (перпендикуляр)"""
	var nearby_segs := _get_nearby_road_segments(pos)
	if nearby_segs.is_empty():
		return Vector2(0, 1)  # По умолчанию - на север

	var min_dist := INF
	var best_dir := Vector2(0, 1)

	for seg in nearby_segs:
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
	if not enable_vegetation:
		return
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


func _is_point_near_building_threadsafe(point: Vector2, min_distance: float, building_hash: Dictionary, poly_hash: Dictionary = {}) -> bool:
	var cell_x := int(floor(point.x / BUILDING_CELL_SIZE))
	var cell_y := int(floor(point.y / BUILDING_CELL_SIZE))
	# Проверяем расстояние до стен
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			if building_hash.has(key):
				for seg in building_hash[key]:
					var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
					if point.distance_to(closest) < min_distance:
						return true
	# Проверяем, не внутри ли полигона здания
	if not poly_hash.is_empty():
		var key := Vector2i(cell_x, cell_y)
		if poly_hash.has(key):
			for poly: PackedVector2Array in poly_hash[key]:
				if Geometry2D.is_point_in_polygon(point, poly):
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
	var building_hash: Dictionary = task_data.building_spatial_hash
	var poly_hash: Dictionary = task_data.building_poly_hash
	var water_hash: Dictionary = task_data.get("water_spatial_hash", {})
	var water_polys: Array = task_data.get("water_polygons", [])
	var t_elev_grid: Dictionary = task_data.get("elev_grid", {})
	var t_base_elev: float = task_data.get("base_elevation", 0.0)

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
		if _is_point_near_road_threadsafe(test_point, 5.0, road_hash):
			continue
		if _is_point_near_building_threadsafe(test_point, 2.0, building_hash, poly_hash):
			continue
		if _is_point_in_water_threadsafe(test_point, water_hash, water_polys):
			continue

		var elevation := _sample_elevation_static(test_point.x, test_point.y, t_elev_grid, t_base_elev)
		var is_pine := dense and fmod(hash1 * 97.0 + hash2 * 53.0, 1.0) < PINE_MIX_RATIO

		# Детерминистичные масштаб/поворот (не randf для потокобезопасности)
		var scale_hash := fmod(float(seed_value + i * 3571) * 0.7236, 1.0)
		var scale_hash_y := fmod(float(seed_value + i * 4919) * 0.8317, 1.0)
		var rot_hash := fmod(float(seed_value + i * 6271) * 0.5413, 1.0)
		var scale_xz := 0.5 + scale_hash * 1.0
		var scale_y := 0.5 + scale_hash_y * 1.0
		var rotation_y := rot_hash * TAU

		var tree_pos := Vector3(test_x, elevation, test_y)
		var basis := Basis(Vector3.UP, rotation_y).scaled(Vector3(scale_xz, scale_y, scale_xz))
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
	var poly_hash: Dictionary = task_data.building_poly_hash
	var parking_hash: Dictionary = task_data.parking_spatial_hash
	var parking_polys: Array = task_data.parking_polygons
	var water_hash: Dictionary = task_data.get("water_spatial_hash", {})
	var water_polys: Array = task_data.get("water_polygons", [])
	var t_elev_grid: Dictionary = task_data.get("elev_grid", {})
	var t_base_elev: float = task_data.get("base_elevation", 0.0)

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

		if _is_point_near_road_threadsafe(test_point, 4.0, road_hash):
			continue
		if _is_point_near_building_threadsafe(test_point, 2.0, building_hash, poly_hash):
			continue
		if _is_point_in_any_parking_threadsafe(test_point, parking_hash, parking_polys):
			continue
		if _is_point_in_water_threadsafe(test_point, water_hash, water_polys):
			continue

		var elevation := _sample_elevation_static(test_point.x, test_point.y, t_elev_grid, t_base_elev)

		# Детерминистичные масштаб/поворот
		var scale_hash := fmod(float(seed_value + i * 3571) * 0.7236, 1.0)
		var scale_hash_y := fmod(float(seed_value + i * 4919) * 0.8317, 1.0)
		var rot_hash := fmod(float(seed_value + i * 6271) * 0.5413, 1.0)
		var scale_xz := 0.5 + scale_hash * 1.0
		var scale_y := 0.5 + scale_hash_y * 1.0
		var rotation_y := rot_hash * TAU

		var tree_pos := Vector3(test_x, elevation, test_y)
		var basis := Basis(Vector3.UP, rotation_y).scaled(Vector3(scale_xz, scale_y, scale_xz))
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
	var tree_ck := _get_chunk_key_from_node(parent)

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
		if _is_point_near_road(test_point, 3.0, tree_ck):
			continue

		var elevation := _sample_elevation(test_point.x, test_point.y)

		# Детерминистичный выбор типа: pine ~15% в лесах
		var is_pine := dense and fmod(hash1 * 97.0 + hash2 * 53.0, 1.0) < PINE_MIX_RATIO

		if tree_ck != "":
			_add_tree_to_batch(tree_ck, test_point, elevation, parent, is_pine)

		tree_count += 1

		if tree_count >= max_trees:
			break


# Возвращает расстояние от точки до ближайшего края дороги
# Отрицательное = внутри дороги, положительное = снаружи
func _get_distance_to_road_edge(point: Vector2, ck: String = "") -> float:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	var min_edge_dist := 999.0

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
				var s_p1: Vector2 = seg.p1
				var s_p2: Vector2 = seg.p2
				var s_width: float = seg.width
				var closest := Geometry2D.get_closest_point_to_segment(point, s_p1, s_p2)
				var dist_to_center := point.distance_to(closest)
				var edge_dist: float = dist_to_center - s_width / 2.0
				min_edge_dist = minf(min_edge_dist, edge_dist)

	return min_edge_dist


# Проверка близости к дороге через spatial hash (быстрая версия)
func _is_point_near_road_fast(point: Vector2, min_distance: float, ck: String = "") -> bool:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				var dist := point.distance_to(closest)
				if dist < (seg.width / 2.0) + min_distance:
					return true

	return false


# Проверяет, находится ли точка внутри коридора автомобильной дороги (width >= 4.0)
# или внутри контура перекрёстка
# margin: запас за пределами края дороги (0 = точно по краю)
## Like _is_point_on_vehicle_road but queries road hash from 3x3 chunk neighbourhood.
## Used for footway on_road classification — footway in chunk A may cross a road
## whose segments are stored in chunk B's road hash.
func _is_point_on_vehicle_road_neighborhood(point: Vector2, margin: float, ck: String) -> bool:
	if ck == "":
		return _is_point_on_vehicle_road(point, margin)
	var parts := ck.split(",")
	var cx := int(parts[0])
	var cz := int(parts[1])
	# Check parking in own chunk only (fast path)
	if _is_point_in_any_parking(point, ck):
		return false
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			# Query road hash from 3x3 chunk neighbourhood
			for cdx in range(-1, 2):
				for cdz in range(-1, 2):
					var nk := "%d,%d" % [cx + cdx, cz + cdz]
					var segs := _query_road_hash(key, nk)
					for seg in segs:
						if seg.width < 4.0:
							continue
						var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
						if point.distance_to(closest) < seg.width / 2.0 + margin:
							return true
	for i in range(_intersection_contours.size()):
		var contour: PackedVector2Array = _intersection_contours[i]
		if contour.size() < 3:
			continue
		if i < _intersection_positions.size():
			if point.distance_to(_intersection_positions[i]) > 30.0:
				continue
		if Geometry2D.is_point_in_polygon(point, contour):
			return true
	return false


func _is_point_on_vehicle_road(point: Vector2, margin: float = 1.0, ck: String = "") -> bool:
	# 0. Парковки: footpath поверх парковки остаётся тротуаром (не crossing)
	if _is_point_in_any_parking(point, ck):
		return false
	# 1. Проверка прямых участков дорог через spatial hash
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
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
	return false


# Finds the closest vehicle road (width >= 4m) near midpoint of before_pt/after_pt.
# Returns Dictionary with road info if full crossing, or empty dict if not.
func _detect_road_crossing(before_pt: Vector2, after_pt: Vector2, ck: String = "") -> Dictionary:
	var mid := (before_pt + after_pt) * 0.5
	var cell_x := int(floor(mid.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(mid.y / ROAD_CELL_SIZE))
	var best_dist := 999.0
	var best_seg_p1 := Vector2.ZERO
	var best_seg_p2 := Vector2.ZERO
	var best_width := 0.0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
				if seg.width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(mid, seg.p1, seg.p2)
				var dist: float = mid.distance_to(closest)
				if dist < best_dist:
					best_dist = dist
					best_seg_p1 = seg.p1
					best_seg_p2 = seg.p2
					best_width = seg.width
	if best_dist > 50.0:
		return {}
	var road_dir: Vector2 = (best_seg_p2 - best_seg_p1).normalized()
	var cross_before: float = road_dir.cross(before_pt - best_seg_p1)
	var cross_after: float = road_dir.cross(after_pt - best_seg_p1)
	# cross_b * cross_a <= 0 → opposite sides (or one exactly on road line)
	if cross_before * cross_after <= 0.0 and (absf(cross_before) > 0.01 or absf(cross_after) > 0.01):
		return {
			"mid": mid,
			"road_dir": road_dir,
			"road_width": best_width,
			"road_p1": best_seg_p1,
			"road_p2": best_seg_p2,
		}
	return {}


# Finds nearest road segment at a point (no crossing validation).
# Used when we already know a point is on-road and just need geometry.
func _find_nearest_road_at_point(point: Vector2, ck: String = "") -> Dictionary:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
	var best_dist := 999.0
	var best_seg_p1 := Vector2.ZERO
	var best_seg_p2 := Vector2.ZERO
	var best_width := 0.0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
				if seg.width < 4.0:
					continue
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				var dist: float = point.distance_to(closest)
				if dist < best_dist:
					best_dist = dist
					best_seg_p1 = seg.p1
					best_seg_p2 = seg.p2
					best_width = seg.width
	if best_dist > 20.0:
		return {}
	var road_dir: Vector2 = (best_seg_p2 - best_seg_p1).normalized()
	return {
		"mid": point,
		"road_dir": road_dir,
		"road_width": best_width,
		"road_p1": best_seg_p1,
		"road_p2": best_seg_p2,
	}


# Legacy wrapper — returns bool only.
func _is_full_road_crossing(before_pt: Vector2, after_pt: Vector2, ck: String = "") -> bool:
	return not _detect_road_crossing(before_pt, after_pt, ck).is_empty()


## Builds a 2-point crossing strip perpendicular to the road, spanning its full width.
## The strip is centered at the projection of the footway midpoint onto the road centerline.
## `road_info` comes from _detect_road_crossing(). `fw_width` is the footway visual width
## (used as the "depth" of the crossing strip along the road direction).
func _build_crossing_strip(road_info: Dictionary, _fw_width: float) -> PackedVector2Array:
	var road_dir: Vector2 = road_info.road_dir
	var road_width: float = road_info.road_width
	var mid: Vector2 = road_info.mid
	var road_p1: Vector2 = road_info.road_p1
	var road_p2: Vector2 = road_info.road_p2
	# Project footway midpoint onto road centerline
	var center := Geometry2D.get_closest_point_to_segment(mid, road_p1, road_p2)
	# Perpendicular to road direction
	var perp := Vector2(-road_dir.y, road_dir.x)
	var half_w := road_width * 0.5
	return PackedVector2Array([center - perp * half_w, center + perp * half_w])


# Находит точку на отрезке [p1, p2], где проходит край дороги (binary search)
func _find_road_edge_point(p1: Vector2, p1_on_road: bool, p2: Vector2, ck: String = "") -> Vector2:
	var t_lo := 0.0
	var t_hi := 1.0
	for _iter in 8:
		var t_mid := (t_lo + t_hi) / 2.0
		var p_mid := p1.lerp(p2, t_mid)
		var mid_on := _is_point_on_vehicle_road(p_mid, 0.0, ck)
		if mid_on == p1_on_road:
			t_lo = t_mid
		else:
			t_hi = t_mid
	return p1.lerp(p2, (t_lo + t_hi) / 2.0)


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
	# clip_polygons can't cut holes inside polygons — it returns CW "hole" polygons
	# that we can't use. When this happens, we pre-split the terrain polygon with
	# a cutting line through the corridor center, then clip each half.
	for corridor in roads:
		if corridor.size() < 4:
			continue
		var new_polys: Array[PackedVector2Array] = []
		for poly in terrain_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, corridor)
			# Check for CW holes (area < 0) — means corridor fully inside poly
			var has_cw_hole := false
			for cp in clipped:
				if cp.size() >= 3 and _polygon_area(cp) < -1.0:
					has_cw_hole = true
					break
			if not has_cw_hole:
				# Normal case: corridor crosses poly boundary
				for cp in clipped:
					if cp.size() >= 3 and _polygon_area(cp) >= 1.0:
						new_polys.append(cp)
			else:
				# Corridor fully inside poly — pre-split poly with a cutting line
				# through corridor center, perpendicular to corridor's main axis
				var c0: Vector2 = corridor[0]
				var c_min_x: float = c0.x
				var c_max_x: float = c0.x
				var c_min_y: float = c0.y
				var c_max_y: float = c0.y
				for ci in range(1, corridor.size()):
					var cv: Vector2 = corridor[ci]
					c_min_x = minf(c_min_x, cv.x)
					c_max_x = maxf(c_max_x, cv.x)
					c_min_y = minf(c_min_y, cv.y)
					c_max_y = maxf(c_max_y, cv.y)
				var c_center_x: float = (c_min_x + c_max_x) * 0.5
				var c_center_y: float = (c_min_y + c_max_y) * 0.5
				# Find poly bounding box
				var pv0: Vector2 = poly[0]
				var p_min_x: float = pv0.x
				var p_max_x: float = pv0.x
				var p_min_y: float = pv0.y
				var p_max_y: float = pv0.y
				for pi2 in range(1, poly.size()):
					var pv: Vector2 = poly[pi2]
					p_min_x = minf(p_min_x, pv.x)
					p_max_x = maxf(p_max_x, pv.x)
					p_min_y = minf(p_min_y, pv.y)
					p_max_y = maxf(p_max_y, pv.y)
				# Cut terrain perpendicular to corridor's main axis through its center.
				# This ensures the corridor crosses the cut line and won't be fully
				# inside either half → no CW holes from clip_polygons.
				var halves: Array[PackedVector2Array] = []
				if (c_max_x - c_min_x) >= (c_max_y - c_min_y):
					# Corridor runs horizontally — cut VERTICALLY at center_x
					var left_half := PackedVector2Array([
						Vector2(p_min_x - 1.0, p_min_y - 1.0),
						Vector2(c_center_x, p_min_y - 1.0),
						Vector2(c_center_x, p_max_y + 1.0),
						Vector2(p_min_x - 1.0, p_max_y + 1.0),
					])
					var right_half := PackedVector2Array([
						Vector2(c_center_x, p_min_y - 1.0),
						Vector2(p_max_x + 1.0, p_min_y - 1.0),
						Vector2(p_max_x + 1.0, p_max_y + 1.0),
						Vector2(c_center_x, p_max_y + 1.0),
					])
					var left_parts := Geometry2D.intersect_polygons(poly, left_half)
					var right_parts := Geometry2D.intersect_polygons(poly, right_half)
					for lp in left_parts:
						if lp.size() >= 3 and _polygon_area(lp) >= 1.0:
							halves.append(lp)
					for rp in right_parts:
						if rp.size() >= 3 and _polygon_area(rp) >= 1.0:
							halves.append(rp)
				else:
					# Corridor runs vertically — cut HORIZONTALLY at center_y
					var top_half := PackedVector2Array([
						Vector2(p_min_x - 1.0, p_min_y - 1.0),
						Vector2(p_max_x + 1.0, p_min_y - 1.0),
						Vector2(p_max_x + 1.0, c_center_y),
						Vector2(p_min_x - 1.0, c_center_y),
					])
					var bot_half := PackedVector2Array([
						Vector2(p_min_x - 1.0, c_center_y),
						Vector2(p_max_x + 1.0, c_center_y),
						Vector2(p_max_x + 1.0, p_max_y + 1.0),
						Vector2(p_min_x - 1.0, p_max_y + 1.0),
					])
					var top_parts := Geometry2D.intersect_polygons(poly, top_half)
					var bot_parts := Geometry2D.intersect_polygons(poly, bot_half)
					for tp in top_parts:
						if tp.size() >= 3 and _polygon_area(tp) >= 1.0:
							halves.append(tp)
					for bp in bot_parts:
						if bp.size() >= 3 and _polygon_area(bp) >= 1.0:
							halves.append(bp)
				# Now clip each half with the corridor — corridor crosses the cut edge
				for half in halves:
					var half_clipped := Geometry2D.clip_polygons(half, corridor)
					for hc in half_clipped:
						if hc.size() >= 3 and _polygon_area(hc) >= 1.0:
							new_polys.append(hc)
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

	# 4. Вырезаем водоёмы + берег (расширенные полигоны)
	var water_shore: Array = task_data.get("water_shore", [])
	if not terrain_polys.is_empty():
		for water_shore_poly in water_shore:
			if water_shore_poly.size() < 3:
				continue
			var new_polys: Array[PackedVector2Array] = []
			for poly in terrain_polys:
				var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, water_shore_poly)
				for cp in clipped:
					if cp.size() >= 3:
						new_polys.append(cp)
			terrain_polys = new_polys
			if terrain_polys.is_empty():
				break

	# 5. Финальная фильтрация: убираем CW (holes) и мелкие осколки
	# Geometry2D.clip_polygons может вернуть [outer_CCW, hole_CW] пару.
	# Нужно вырезать CW-дырки из CCW-полигонов, т.к. триангуляция не учитывает дырки.
	var ccw_polys: Array[PackedVector2Array] = []
	var cw_holes: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		if poly.size() < 3:
			continue
		var area := _polygon_area(poly)
		if area >= 2.0:
			ccw_polys.append(poly)
		elif area <= -2.0:
			# CW hole — reverse to make CCW for use as clipping polygon
			var reversed_poly := PackedVector2Array(poly)
			reversed_poly.reverse()
			cw_holes.append(reversed_poly)
	# Clip holes from outer polygons
	for hole in cw_holes:
		var new_ccw: Array[PackedVector2Array] = []
		for poly in ccw_polys:
			var clipped: Array[PackedVector2Array] = Geometry2D.clip_polygons(poly, hole)
			for cp in clipped:
				if cp.size() >= 3 and _polygon_area(cp) >= 2.0:
					new_ccw.append(cp)
		ccw_polys = new_ccw
	var filtered_polys: Array[PackedVector2Array] = ccw_polys

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
	var batch: Array = _terrain_thread_results.duplicate()
	_terrain_thread_results.clear()
	_terrain_thread_mutex.unlock()

	# Apply with 3ms budget (terrain finalization includes triangulation + curbs)
	var TERRAIN_APPLY_BUDGET_USEC := 500000 if _initial_loading else 3000
	var t0 := Time.get_ticks_usec()
	var applied := 0

	for result in batch:
		_pending_terrain_tasks -= 1
		var chunk_key: String = result.chunk_key
		var terrain_polys: Array[PackedVector2Array] = result.terrain_polys

		var parent: Node3D = _get_chunk_node(chunk_key)
		if not parent or not _is_chunk_alive(chunk_key):
			applied += 1
			continue

		if terrain_polys.is_empty():
			print("OSM: ChunkTerrain %s: no polygons after clipping" % chunk_key)
			applied += 1
			continue

		_finalize_terrain_mesh(chunk_key, parent, terrain_polys)
		applied += 1
		if applied > 1 and (Time.get_ticks_usec() - t0) > TERRAIN_APPLY_BUDGET_USEC:
			break

	# Return unprocessed back to front of queue (preserve order)
	if applied < batch.size():
		_terrain_thread_mutex.lock()
		var remaining: Array = batch.slice(applied)
		remaining.append_array(_terrain_thread_results)
		_terrain_thread_results = remaining
		_terrain_thread_mutex.unlock()


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
		var curb_w := 0.15
		var top := sidewalk_height
		var bot := -3.0  # Extend below terrain to cover elevation differences

		# Miter outer-точка для каждой вершины — внешняя сторона встык
		var miter_out: PackedVector2Array = PackedVector2Array()
		miter_out.resize(pn)
		for vi in range(pn):
			var d_prev := (poly[vi] - poly[(vi - 1 + pn) % pn]).normalized()
			var d_next := (poly[(vi + 1) % pn] - poly[vi]).normalized()
			var out_prev := Vector2(d_prev.y, -d_prev.x)
			var out_next := Vector2(d_next.y, -d_next.x)
			var avg := out_prev + out_next
			if avg.length_squared() > 0.001:
				var n := avg.normalized()
				var dot := n.dot(out_next)
				if dot > 0.3:
					miter_out[vi] = poly[vi] + n * (curb_w / dot)
				else:
					miter_out[vi] = poly[vi] + out_next * curb_w
			else:
				miter_out[vi] = poly[vi] + Vector2(d_next.y, -d_next.x) * curb_w

		for ei in range(pn):
			var p1: Vector2 = poly[ei]
			var p2: Vector2 = poly[(ei + 1) % pn]
			var p1_on_boundary := absf(p1.x - min_x) < boundary_eps or absf(p1.x - max_x) < boundary_eps or absf(p1.y - min_z) < boundary_eps or absf(p1.y - max_z) < boundary_eps
			var p2_on_boundary := absf(p2.x - min_x) < boundary_eps or absf(p2.x - max_x) < boundary_eps or absf(p2.y - min_z) < boundary_eps or absf(p2.y - max_z) < boundary_eps
			if p1_on_boundary and p2_on_boundary:
				continue
			var dir := (p2 - p1).normalized()
			var outward := Vector2(dir.y, -dir.x)
			# Outer: miter (встык), на границе чанка — простое смещение по outward
			var p1_out: Vector2
			var p2_out: Vector2
			if p1_on_boundary:
				p1_out = p1 + outward * curb_w
			else:
				p1_out = miter_out[ei]
			if p2_on_boundary:
				p2_out = p2 + outward * curb_w
			else:
				p2_out = miter_out[(ei + 1) % pn]
			# Inner: overlap (пересекаются), на границе — без overlap
			if not p1_on_boundary:
				p1 -= dir * curb_w
			if not p2_on_boundary:
				p2 += dir * curb_w
			var e1 := _sample_elevation(p1.x, p1.y)
			var e2 := _sample_elevation(p2.x, p2.y)
			var top1 := top + e1
			var top2 := top + e2
			var bot1 := bot + e1
			var bot2 := bot + e2
			var n_front := Vector3(outward.x, 0.0, outward.y)
			var ci := curb_verts.size()
			# Передняя грань
			curb_verts.append(Vector3(p1_out.x, bot1, p1_out.y))
			curb_verts.append(Vector3(p2_out.x, bot2, p2_out.y))
			curb_verts.append(Vector3(p2_out.x, top2, p2_out.y))
			curb_verts.append(Vector3(p1_out.x, top1, p1_out.y))
			for _j in 4: curb_norms.append(n_front)
			# Верхняя грань
			curb_verts.append(Vector3(p1.x, top1, p1.y))
			curb_verts.append(Vector3(p2.x, top2, p2.y))
			curb_verts.append(Vector3(p2_out.x, top2, p2_out.y))
			curb_verts.append(Vector3(p1_out.x, top1, p1_out.y))
			for _j in 4: curb_norms.append(Vector3.UP)
			# Нижняя грань
			curb_verts.append(Vector3(p1_out.x, bot1, p1_out.y))
			curb_verts.append(Vector3(p2_out.x, bot2, p2_out.y))
			curb_verts.append(Vector3(p2.x, bot2, p2.y))
			curb_verts.append(Vector3(p1.x, bot1, p1.y))
			for _j in 4: curb_norms.append(Vector3.DOWN)
			# Передняя грань (offset 0) — 0,1,2 / 0,2,3
			curb_idxs.append(ci + 0); curb_idxs.append(ci + 1); curb_idxs.append(ci + 2)
			curb_idxs.append(ci + 0); curb_idxs.append(ci + 2); curb_idxs.append(ci + 3)
			# Верхняя грань (offset 4) — 0,2,1 / 0,3,2
			curb_idxs.append(ci + 4); curb_idxs.append(ci + 6); curb_idxs.append(ci + 5)
			curb_idxs.append(ci + 4); curb_idxs.append(ci + 7); curb_idxs.append(ci + 6)
			# Нижняя грань (offset 8) — 0,1,2 / 0,2,3
			curb_idxs.append(ci + 8); curb_idxs.append(ci + 9); curb_idxs.append(ci + 10)
			curb_idxs.append(ci + 8); curb_idxs.append(ci + 10); curb_idxs.append(ci + 11)

	if curb_verts.size() > 0:
		var curb_arrays := []
		curb_arrays.resize(Mesh.ARRAY_MAX)
		curb_arrays[Mesh.ARRAY_VERTEX] = curb_verts
		curb_arrays[Mesh.ARRAY_NORMAL] = curb_norms
		curb_arrays[Mesh.ARRAY_INDEX] = curb_idxs
		var curb_mesh := ArrayMesh.new()
		curb_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, curb_arrays)
		_rs_add_mesh(chunk_key, curb_mesh, _curb_material)

	# Split terrain polygons into grid cells for accurate elevation following.
	# Without this, large flat triangles interpolate linearly and diverge from the
	# bilinear elevation surface that roads/trams follow, causing terrain to poke
	# through roads or sidewalks to sink under grass.
	var grid_polys: Array[PackedVector2Array] = []
	for poly in terrain_polys:
		grid_polys.append_array(_split_polygon_by_grid(poly, 10.0))

	# Триангулируем полигоны
	var all_vertices := PackedVector3Array()
	var all_uvs := PackedVector2Array()
	var all_normals := PackedVector3Array()
	var all_indices := PackedInt32Array()
	var uv_scale := 0.25
	var total_tris := 0

	for poly in grid_polys:
		var indices := Geometry2D.triangulate_polygon(poly)
		if indices.size() < 3:
			continue
		var base_idx: int = all_vertices.size()
		for p in poly:
			var h := sidewalk_height + _sample_elevation(p.x, p.y)
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

	# Ground plane: same polygons, 0.5m below raw elevation (fills holes)
	if enable_ground_plane and enable_elevation:
		var gp_verts := PackedVector3Array()
		gp_verts.resize(all_vertices.size())
		for vi in all_vertices.size():
			var v := all_vertices[vi]
			gp_verts[vi] = Vector3(v.x, v.y - sidewalk_height, v.z)
		var gp_arrays := []
		gp_arrays.resize(Mesh.ARRAY_MAX)
		gp_arrays[Mesh.ARRAY_VERTEX] = gp_verts
		gp_arrays[Mesh.ARRAY_TEX_UV] = all_uvs
		gp_arrays[Mesh.ARRAY_NORMAL] = all_normals
		gp_arrays[Mesh.ARRAY_INDEX] = all_indices
		var gp_mesh := ArrayMesh.new()
		gp_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, gp_arrays)
		var gp_mat := StandardMaterial3D.new()
		gp_mat.albedo_color = Color(0.35, 0.35, 0.32)
		gp_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_rs_add_mesh(chunk_key, gp_mesh, gp_mat)

	# Коллизия — отложенная (ConcavePolygonShape3D из реальной геометрии)
	_deferred_append(_deferred_terrain_collisions, chunk_key, {
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
		if _is_point_near_road(test_point, 2.0, chunk_key):
			continue

		# Пропускаем если близко к зданию (2м от стены)
		if _is_point_near_building(test_point, 2.0, chunk_key):
			continue

		# Пропускаем если на парковке
		if _is_point_in_any_parking(test_point, chunk_key):
			continue

		# Пропускаем если в водоёме
		if _is_point_in_water(test_point, chunk_key):
			continue

		var elevation := _sample_elevation(test_point.x, test_point.y)
		_add_tree_to_batch(chunk_key, test_point, elevation, parent)

		tree_count += 1
		if tree_count >= max_trees:
			break


# Процедурная генерация промышленных зданий внутри территории
func _generate_industrial_buildings(points: PackedVector2Array, parent: Node3D) -> void:
	if not enable_buildings:
		return
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
			var bld_ctr := _get_polygon_center(bld_points)
			var bld_max_elev := _sample_elevation(bld_ctr.x, bld_ctr.y)
			for bp in bld_points:
				bld_max_elev = maxf(bld_max_elev, _sample_elevation(bp.x, bp.y))
			var base_elev := 0.22 + bld_max_elev
			_create_3d_building(bld_points, building_color, bld_height, parent, base_elev)


## Incremental lamp generation: processes segments from start_seg_idx, returns last processed segment index.
## Respects time budget (budget_usec from budget_start).
func _generate_street_lamps_incremental(local_points: PackedVector2Array, road_width: float, parent: Node3D, start_seg_idx: int, budget_start: int, budget_usec: int) -> int:
	if not enable_street_lamps or local_points.size() < 2:
		return local_points.size()

	var lamp_spacing := 17.0
	var lamp_offset := road_width / 2 + 0.5
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
		var both_sides := road_width >= 12.0  # primary and wider — both sides

		# Compute chunk_key once, pass to all spatial checks (single-chunk O(1) lookup)
		var left_ck := "%d,%d" % [int(floor(lamp_pos_left.x / chunk_size)), int(floor(lamp_pos_left.y / chunk_size))]

		# Skip lamps inside intersection contours (where bezier curbs are)
		var left_in_intersection := _is_point_in_intersection_shape(lamp_pos_left, false, left_ck) >= 0
		if not left_in_intersection and not _is_point_in_any_parking(lamp_pos_left, left_ck) and not _is_point_near_road(lamp_pos_left, 0.1, left_ck) and not _is_point_in_water(lamp_pos_left, left_ck):
			if _loaded_chunks.has(left_ck):
				_add_lamp_to_batch(left_ck, Vector3(lamp_pos_left.x, _sample_elevation(lamp_pos_left.x, lamp_pos_left.y), lamp_pos_left.y), Vector3(-perp.x, 0, -perp.y), _loaded_chunks[left_ck])

		if both_sides:
			var right_ck := "%d,%d" % [int(floor(lamp_pos_right.x / chunk_size)), int(floor(lamp_pos_right.y / chunk_size))]
			if _is_point_in_intersection_shape(lamp_pos_right, false, right_ck) < 0 and not _is_point_in_any_parking(lamp_pos_right, right_ck) and not _is_point_near_road(lamp_pos_right, 0.1, right_ck) and not _is_point_in_water(lamp_pos_right, right_ck):
				if _loaded_chunks.has(right_ck):
					_add_lamp_to_batch(right_ck, Vector3(lamp_pos_right.x, _sample_elevation(lamp_pos_right.x, lamp_pos_right.y), lamp_pos_right.y), Vector3(perp.x, 0, perp.y), _loaded_chunks[right_ck])

		next_lamp_dist += lamp_spacing

	return n_pts  # Fully processed


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

				var elev := _sample_elevation(manhole_pos.x, manhole_pos.y)
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

				_create_manhole_decal(manhole_pos, _sample_elevation(manhole_pos.x, manhole_pos.y), randf() * TAU, parent)
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

		var elev := _sample_elevation(wall.closest_point.x, wall.closest_point.y)
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
			light.light_energy = 2.6 if is_night else 0.0
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


func _create_pending_parking_signs() -> void:
	"""Создаёт отложенные знаки парковки (теперь все дороги известны)"""
	print("OSM: _create_pending_parking_signs started, count=%d" % _pending_parking_signs.size())

	var created := 0
	for sign_data in _pending_parking_signs:
		var points: PackedVector2Array = sign_data.points
		var parent: Node3D = sign_data.parent

		var sign_result = _find_parking_sign_position(points)
		if sign_result.is_empty():
			continue

		var sign_pos: Vector2 = sign_result.position
		var sign_rotation: float = sign_result.rotation
		var base_elev = _sample_elevation(sign_pos.x, sign_pos.y)

		_create_parking_sign(sign_pos, base_elev, sign_rotation, parent)
		created += 1

	print("OSM: Created %d parking signs" % created)
	_pending_parking_signs.clear()


func _is_point_in_any_parking(point: Vector2, ck: String = "") -> bool:
	const PARKING_BUFFER := 10.0
	var cell_x := int(floor(point.x / PARKING_CELL_SIZE))
	var cell_y := int(floor(point.y / PARKING_CELL_SIZE))

	var chunks_to_check: Array = [ck] if ck != "" else _chunk_parking_hashes.keys()
	for c in chunks_to_check:
		if not _chunk_parking_hashes.has(c):
			continue
		var data: Dictionary = _chunk_parking_hashes[c]
		var h: Dictionary = data.get("hash", {})
		var polys: Array = data.get("polys", [])
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var key := Vector2i(cell_x + dx, cell_y + dy)
				if not h.has(key):
					continue
				for entry in h[key]:
					var pidx: int = entry.idx
					var closest := Geometry2D.get_closest_point_to_segment(point, entry.p1, entry.p2)
					if point.distance_to(closest) < PARKING_BUFFER:
						return true
					if pidx < polys.size():
						var parking: PackedVector2Array = polys[pidx]
						if parking.size() >= 3 and Geometry2D.is_point_in_polygon(point, parking):
							return true
	return false


## Проверяет, находится ли точка внутри водного полигона (main thread)
func _is_point_in_water(point: Vector2, _ck: String = "") -> bool:
	# Use the global polygon list — it contains every water polygon
	# registered by ANY chunk (deduped by hash) and so works for chunks
	# whose own OSM data didn't return the relation. AABB pre-check
	# skips polygons not near the point in O(1).
	for i in _global_water_polygons.size():
		var bbox: Rect2 = _global_water_polygon_bboxes[i]
		if not bbox.has_point(point):
			continue
		var wp: PackedVector2Array = _global_water_polygons[i]
		if wp.size() >= 3 and Geometry2D.is_point_in_polygon(point, wp):
			return true
	return false


## Проверяет, находится ли точка внутри водного полигона (thread-safe)
## water_polys here is the GLOBAL list (full polygons), passed by snapshot
## to worker threads via task_data. AABB pre-check is folded into the
## main-thread version; here we just iterate (workers tolerate latency).
static func _is_point_in_water_threadsafe(point: Vector2, _water_hash: Dictionary, water_polys: Array) -> bool:
	for wp in water_polys:
		if wp.size() >= 3 and Geometry2D.is_point_in_polygon(point, wp):
			return true
	return false


func _is_point_near_road(point: Vector2, min_distance: float, ck: String = "") -> bool:
	var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(point.y / ROAD_CELL_SIZE))

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_road_hash(key, ck)
			for seg in segs:
				var closest := Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
				var dist := point.distance_to(closest)
				if dist < (seg.width / 2.0) + min_distance:
					return true

	return false


func _is_point_near_any_parking(point: Vector2, max_distance: float) -> bool:
	"""Проверяет, находится ли точка близко к любой парковке"""
	for ck_p in _chunk_parking_hashes:
		var pk_data: Dictionary = _chunk_parking_hashes[ck_p]
		var pk_polys: Array = pk_data.get("polys", [])
		for parking in pk_polys:
			if parking.size() < 3:
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
	var oneway: String = tags.get("oneway", "")
	road_network.add_road_segment(local_points, highway_type, chunk_key, bridge_info, oneway, tags)


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
	var oneway: String = tags.get("oneway", "")
	road_network.add_road_segment(local_points, highway_type, chunk_key, bridge_info, oneway, tags)


func _extract_tram_for_network(local_points: PackedVector2Array, tags: Dictionary) -> void:
	print("[TRAM] _extract_tram_for_network: %d points, range X=[%.1f..%.1f] Z=[%.1f..%.1f]" % [
		local_points.size(),
		local_points[0].x if local_points.size() > 0 else 0,
		local_points[local_points.size()-1].x if local_points.size() > 0 else 0,
		local_points[0].y if local_points.size() > 0 else 0,
		local_points[local_points.size()-1].y if local_points.size() > 0 else 0
	])
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
	road_network.add_tram_segment(local_points, chunk_key)


# === NIGHT MODE ===

var _is_wet_mode := false
var _wetness_value := 0.0
var _wetness_tween: Tween
var _night_mode_connected := false
var _night_mode_manager = null  # Кэш ссылки на NightModeManager (для избежания повторных поисков)
var _building_night_lights: Array[Node3D] = []  # Храним ссылки на созданные источники света

var _is_night_mode := false

func set_wet_mode(enabled: bool, is_night: bool = true) -> void:
	"""Включает/выключает мокрый асфальт для дорог (плавно за 5 секунд)"""
	_is_night_mode = is_night
	_is_wet_mode = enabled

	# Обновляем is_night сразу на всех материалах
	for chunk_key in _chunk_road_materials:
		for mat in _chunk_road_materials[chunk_key]:
			if mat is ShaderMaterial:
				mat.set_shader_parameter("is_night", is_night)
	if _ground_shader_material:
		_ground_shader_material.set_shader_parameter("is_night", is_night)

	# Плавный переход wetness_global за 5 секунд (один вызов RenderingServer на кадр)
	var target := 1.0 if enabled else 0.0
	if _wetness_tween:
		_wetness_tween.kill()
	_wetness_tween = create_tween()
	_wetness_tween.tween_method(_apply_wetness_global, _wetness_value, target, 5.0)
	print("OSM: Wet mode %s (tweening %.1f → %.1f)" % ["enabled" if enabled else "disabled", _wetness_value, target])


func _apply_wetness_global(value: float) -> void:
	"""Устанавливает глобальный шейдерный параметр wetness_global (один вызов на кадр)"""
	_wetness_value = value
	RenderingServer.global_shader_parameter_set("wetness_global", value)
	WheelDirtScript.current_wetness = value


func _is_road_material(mat: Material) -> bool:
	"""Проверяет, является ли материал дорожным (не бордюр, не здание)"""
	# ShaderMaterial с нашим road shader - это дорога
	if mat is ShaderMaterial:
		# Проверяем что это наш road shader по наличию параметра is_night
		if mat.get_shader_parameter("is_night") != null:
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


func _update_tree_shadows(_player_pos: Vector3) -> void:
	# Tree shadows always ON — shadow mesh is a simplified cross (8 verts per tree in MultiMesh),
	# the cost is negligible. Disabling shadow LOD prevents the visible "pop" when all tree shadows
	# in a chunk switch on/off at once.
	pass


func _setup_render_distance() -> void:
	"""Настраивает дальность прорисовки камеры, туман и дистанции чанков"""
	# Настраиваем дистанции загрузки чанков
	# Зазор между load и unload нужен чтобы не флаттерить загрузку/выгрузку
	load_distance = render_distance + 100.0  # Загружаем чуть дальше видимости
	unload_distance = render_distance + chunk_size  # Выгружаем с запасом на chunk_size
	print("OSM: Chunk size: %.0f, distances - load: %.0f, unload: %.0f" % [chunk_size, load_distance, unload_distance])

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

	# Добавляем светящиеся окна для зданий с хотя бы 1 этажом окон
	# Условие должно совпадать с wall cutout логикой в _compute_building_mesh_thread
	if int(building_height / WINDOW_FLOOR_HEIGHT) >= 1:
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

	# Параметры окон (используем shared constants)
	var floor_height := WINDOW_FLOOR_HEIGHT
	var num_floors := int(height / floor_height)
	if num_floors < 1:
		return

	var window_size := WINDOW_SIZE
	var window_spacing := WINDOW_SPACING
	var wall_offset := -WINDOW_RECESS_DEPTH  # Окно утоплено внутрь стены

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

	# Отдельный RNG для цветов окон — seed совпадает с _compute_building_mesh_thread
	# чтобы recess-бортики светились тем же цветом что и окна
	var center := _get_polygon_center(points)
	var wnd_rng := RandomNumberGenerator.new()
	wnd_rng.seed = hash(Vector2(center.x, center.y)) ^ 0x57494E44  # WIND

	# Случайное распределение для этого здания:
	# Выключено: 30-80%, Включено: 17-65%, Фитолампы: 3-5%
	# NOTE: Цвета генерируются независимо от времени суток
	# Shader сам решит показывать их или нет на основе is_night uniform
	var off_percent := 0.30 + wnd_rng.randf() * 0.50  # 30% - 80%
	var phyto_percent := 0.03 + wnd_rng.randf() * 0.02  # 3% - 5%
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
				var chance := wnd_rng.randf()
				if chance < off_percent:
					# Выключенные окна (остаются тёмными ночью)
					color = off_color
				elif chance < (1.0 - phyto_percent):
					# Тёплые до холодных оттенков (жёлтый -> белый)
					color = warm_cold_colors[wnd_rng.randi() % warm_cold_colors.size()]
					# Случайная яркость от 0.15 до 0.5 (храним в альфа-канале)
					color.a = 0.15 + wnd_rng.randf() * 0.35
				else:
					# Фитолампы (маджента)
					color = phyto_color
					color.a = 0.25 + wnd_rng.randf() * 0.25  # Фитолампы ярче

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

func _add_business_signs_simple(points: PackedVector2Array, tags: Dictionary, parent: Node3D, building_height: float, base_elev: float = 0.0, loader: Node = null, way_id: int = 0, entrance_nodes: Array = [], poi_nodes: Array = []) -> void:
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
	var pois_inside = _find_pois_inside_building(points, loader, poi_nodes)
	var skip_override = null
	if way_id > 0 and _decoration_layer:
		skip_override = _decoration_layer.get_building_override_for_way(way_id)
	if skip_override and skip_override.skip_all_pois:
		return
	for poi in pois_inside:
		var poi_id_val = poi.get("id", 0)
		if skip_override and not skip_override.skip_pois.is_empty():
			if poi_id_val in skip_override.skip_pois:
				print("BusinessSign: Skipping POI %s (suppressed by override for way %d)" % [str(poi_id_val), way_id])
				continue
		businesses_to_process.append({"tags": poi.tags, "poi_position": poi.position, "poi_id": poi_id_val})

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
		if not entrance_nodes.is_empty() and loader != null:
			entrance = _find_entrance_for_building(points, loader, entrance_nodes)

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
			var sign_text: String = shop_data.get("sign_text", "МАГАЗИН")
			BusinessSignGenerator._create_text_sign(sign_root, sign_text, Color(0.2, 0.5, 0.8), 4.0, "shop")
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

		var elev := _sample_elevation(wall.closest_point.x, wall.closest_point.y)
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


func _add_roof_signs_from_override(points: PackedVector2Array, parent: Node3D, building_height: float, base_elev: float, way_id: int) -> void:
	if not _decoration_layer or way_id <= 0:
		return
	var override = _decoration_layer.get_building_override_for_way(way_id)
	if not override or override.roof_signs.is_empty():
		return

	var roof_y := base_elev + building_height

	for sign_data in override.roof_signs:
		var lat: float = sign_data.get("lat", 0.0)
		var lon: float = sign_data.get("lon", 0.0)
		var logo_name: String = sign_data.get("logo", "")
		if lat == 0.0 or lon == 0.0 or logo_name == "":
			continue

		var logo_path := BusinessSignGenerator.BRAND_LOGOS_PATH + logo_name
		if not ResourceLoader.exists(logo_path):
			push_warning("RoofSign: logo not found: " + logo_path)
			continue

		var texture: Texture2D = load(logo_path)
		if not texture:
			continue

		var sign_pos := _latlon_to_local(lat, lon)
		var wall := _find_closest_wall_to_point(points, sign_pos, 5.0)
		if wall.is_empty():
			print("RoofSign: no wall found for sign at (%.6f, %.6f)" % [lat, lon])
			continue

		var wall_normal: Vector3 = wall.normal
		var snap_point: Vector2 = wall.closest_point

		# Размер логотипа на крыше (крупный)
		var tex_size := texture.get_size()
		var aspect := tex_size.x / tex_size.y
		var logo_h := 5.0  # Высота логотипа в метрах
		var logo_w := logo_h * aspect

		# Sprite3D с логотипом
		var sprite := Sprite3D.new()
		sprite.texture = texture
		sprite.pixel_size = logo_h / tex_size.y
		sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		sprite.no_depth_test = false
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		sprite.name = "RoofSign_%d" % way_id

		# Позиция: на крыше, чуть выше + смещение наружу
		sprite.position = Vector3(snap_point.x, roof_y + logo_h / 2.0 + 0.3, snap_point.y)
		sprite.position += wall_normal * 0.1
		sprite.rotation.y = atan2(wall_normal.x, wall_normal.z)

		parent.add_child(sprite)

		# Подсветка ночью (неоновый эффект)
		var sign_light := OmniLight3D.new()
		sign_light.light_energy = 2.0
		sign_light.light_color = Color(1.0, 0.9, 0.3)  # Тёплый жёлтый
		sign_light.omni_range = 12.0
		sign_light.name = "RoofSignLight_%d" % way_id
		sign_light.position = Vector3(snap_point.x, roof_y + logo_h / 2.0, snap_point.y)
		sign_light.position += wall_normal * 1.5
		parent.add_child(sign_light)

		print("RoofSign: added at roof for way %d" % way_id)


func _add_wall_signs_from_override(points: PackedVector2Array, parent: Node3D, building_height: float, base_elev: float, way_id: int) -> void:
	"""Places logo signs on building walls with white background."""
	if not _decoration_layer or way_id <= 0:
		return
	var override = _decoration_layer.get_building_override_for_way(way_id)
	if not override or override.wall_signs.is_empty():
		return

	for sign_data in override.wall_signs:
		var lat: float = sign_data.get("lat", 0.0)
		var lon: float = sign_data.get("lon", 0.0)
		var logo_name: String = sign_data.get("logo", "")
		var height_ratio: float = sign_data.get("height_ratio", 0.75)  # 0=ground, 1=roof
		var sign_width: float = sign_data.get("width", 5.0)
		var padding: float = sign_data.get("padding", 0.3)
		if lat == 0.0 or lon == 0.0 or logo_name == "":
			continue

		var logo_path := "res://textures/" + logo_name
		var logo_tex: Texture2D = load(logo_path) as Texture2D
		if not logo_tex:
			push_warning("WallSign: logo not found: " + logo_path)
			continue

		var sign_pos := _latlon_to_local(lat, lon)
		var wall := _find_closest_wall_to_point(points, sign_pos, 3.0)
		if wall.is_empty():
			continue

		var snap_point: Vector2 = wall["closest_point"]
		var wall_normal: Vector3 = wall["normal"]
		var normal_2d := Vector2(wall_normal.x, wall_normal.z)

		var roof_y := base_elev + building_height
		# height_ratio: 0.0 = ground level, 1.0 = roof line
		var sign_center_y := base_elev + building_height * height_ratio

		# Logo dimensions from texture aspect ratio
		var logo_aspect: float = float(logo_tex.get_width()) / float(logo_tex.get_height())
		var sign_h := sign_width / logo_aspect
		var bg_w := sign_width + padding * 2
		var bg_h := sign_h + padding * 2

		# Wall tangent — derived from outward normal via cross product
		# This guarantees "right" is correct for the viewer regardless of polygon winding
		var tangent := Vector3.UP.cross(wall_normal).normalized()
		var outward := wall_normal * 0.06

		var center := Vector3(snap_point.x, sign_center_y, snap_point.y) + outward

		# White background quad — vertex order: BL, BR, TR, TL (same as Новый Век logo)
		var bv := PackedVector3Array()
		bv.append(center - tangent * bg_w * 0.5 - Vector3(0, bg_h * 0.5, 0))  # 0: bottom-left
		bv.append(center + tangent * bg_w * 0.5 - Vector3(0, bg_h * 0.5, 0))  # 1: bottom-right
		bv.append(center + tangent * bg_w * 0.5 + Vector3(0, bg_h * 0.5, 0))  # 2: top-right
		bv.append(center - tangent * bg_w * 0.5 + Vector3(0, bg_h * 0.5, 0))  # 3: top-left
		var bu := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		var n3d := wall_normal.normalized()
		var bn := PackedVector3Array([n3d, n3d, n3d, n3d])
		var bi := PackedInt32Array([0, 1, 2, 0, 2, 3])

		var bg_arrays := []
		bg_arrays.resize(Mesh.ARRAY_MAX)
		bg_arrays[Mesh.ARRAY_VERTEX] = bv
		bg_arrays[Mesh.ARRAY_TEX_UV] = bu
		bg_arrays[Mesh.ARRAY_NORMAL] = bn
		bg_arrays[Mesh.ARRAY_INDEX] = bi

		var bg_mesh := ArrayMesh.new()
		bg_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bg_arrays)
		var bg_mat := ShaderMaterial.new()
		bg_mat.shader = BuildingWallShader
		bg_mat.set_shader_parameter("use_texture", false)
		bg_mat.set_shader_parameter("albedo_color", Color(0.97, 0.97, 0.97))
		bg_mat.set_shader_parameter("roughness_base", 0.5)

		var bg_inst := MeshInstance3D.new()
		bg_inst.mesh = bg_mesh
		bg_inst.material_override = bg_mat
		bg_inst.name = "WallSignBg_%d" % way_id
		parent.add_child(bg_inst)

		# Logo quad — vertex order: BL, BR, TR, TL (same as Новый Век logo)
		var logo_center := center + outward
		var lv := PackedVector3Array()
		lv.append(logo_center - tangent * sign_width * 0.5 - Vector3(0, sign_h * 0.5, 0))  # 0: bottom-left
		lv.append(logo_center + tangent * sign_width * 0.5 - Vector3(0, sign_h * 0.5, 0))  # 1: bottom-right
		lv.append(logo_center + tangent * sign_width * 0.5 + Vector3(0, sign_h * 0.5, 0))  # 2: top-right
		lv.append(logo_center - tangent * sign_width * 0.5 + Vector3(0, sign_h * 0.5, 0))  # 3: top-left
		var lu := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		var ln := PackedVector3Array([n3d, n3d, n3d, n3d])
		var li := PackedInt32Array([0, 1, 2, 0, 2, 3])

		var logo_arrays := []
		logo_arrays.resize(Mesh.ARRAY_MAX)
		logo_arrays[Mesh.ARRAY_VERTEX] = lv
		logo_arrays[Mesh.ARRAY_TEX_UV] = lu
		logo_arrays[Mesh.ARRAY_NORMAL] = ln
		logo_arrays[Mesh.ARRAY_INDEX] = li

		var logo_mesh := ArrayMesh.new()
		logo_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, logo_arrays)

		var logo_shader := Shader.new()
		logo_shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;
uniform sampler2D logo_texture : source_color, filter_linear_mipmap;
uniform float emission_energy : hint_range(0.0, 8.0) = 2.0;
global uniform bool is_night_global;
void fragment() {
	vec4 tex = texture(logo_texture, UV);
	if (tex.a < 0.5) discard;
	ALBEDO = tex.rgb;
	ROUGHNESS = 0.3;
	METALLIC = 0.0;
	if (!FRONT_FACING) NORMAL = -NORMAL;
	if (is_night_global) {
		EMISSION = tex.rgb * emission_energy;
	}
}
"""
		var logo_mat := ShaderMaterial.new()
		logo_mat.shader = logo_shader
		logo_mat.set_shader_parameter("logo_texture", logo_tex)
		logo_mat.set_shader_parameter("emission_energy", 1.5)

		var logo_inst := MeshInstance3D.new()
		logo_inst.mesh = logo_mesh
		logo_inst.material_override = logo_mat
		logo_inst.name = "WallSignLogo_%d" % way_id
		parent.add_child(logo_inst)

		print("WallSign: added for way %d at (%.6f, %.6f)" % [way_id, lat, lon])


func _add_pediments_from_override(points: PackedVector2Array, parent: Node3D, building_height: float, base_elev: float, way_id: int) -> void:
	"""Generates gable roof cap over raised pediment sections using actual polygon vertices."""
	if not _decoration_layer or way_id <= 0:
		return
	var override = _decoration_layer.get_building_override_for_way(way_id)
	if not override or override.pediments.is_empty():
		return

	var roof_y := base_elev + building_height

	# Центр здания для вычисления inward
	var center := Vector2.ZERO
	for p in points:
		center += p
	center /= points.size()

	for ped_data in override.pediments:
		var rect_h: float = ped_data.get("rect_height", 2.0)
		var tri_h: float = ped_data.get("tri_height", 2.0)
		var depth: float = ped_data.get("depth", 6.0)

		if not ped_data.has("p1") or not ped_data.has("p2"):
			continue
		var p1_ll: Array = ped_data["p1"]
		var p2_ll: Array = ped_data["p2"]
		if p1_ll.size() < 2 or p2_ll.size() < 2:
			continue

		var p1 := _latlon_to_local(p1_ll[0], p1_ll[1])
		var p2 := _latlon_to_local(p2_ll[0], p2_ll[1])

		# Find polygon vertex indices for p1 and p2
		var idx1 := -1
		var idx2 := -1
		var best_d1 := 1e18
		var best_d2 := 1e18
		for vi in points.size():
			var d1 := points[vi].distance_squared_to(p1)
			var d2 := points[vi].distance_squared_to(p2)
			if d1 < best_d1:
				best_d1 = d1
				idx1 = vi
			if d2 < best_d2:
				best_d2 = d2
				idx2 = vi
		if idx1 < 0 or idx2 < 0 or idx1 == idx2:
			continue

		# Walk from idx1 to idx2, pick shorter path
		var walk := []
		var vi_cur := idx1
		while vi_cur != idx2:
			walk.append(vi_cur)
			vi_cur = (vi_cur + 1) % points.size()
		walk.append(idx2)
		var walk_rev := []
		vi_cur = idx1
		while vi_cur != idx2:
			walk_rev.append(vi_cur)
			vi_cur = (vi_cur - 1 + points.size()) % points.size()
		walk_rev.append(idx2)
		if walk_rev.size() < walk.size():
			walk = walk_rev

		# Compute extra_height per walk vertex (same logic as wall extension)
		var walk_extra := []
		for wi in walk.size():
			if wi == 0 or wi == walk.size() - 1:
				walk_extra.append(rect_h)
			else:
				var t: float = float(wi) / float(walk.size() - 1)
				var tri_contrib: float = tri_h * (1.0 - abs(t - 0.5) / 0.5)
				walk_extra.append(rect_h + tri_contrib)

		# Inward direction (from front wall toward building center)
		var wall_dir := (p2 - p1).normalized()
		var normal_2d := Vector2(wall_dir.y, -wall_dir.x)
		var wall_center_2d := (p1 + p2) / 2.0
		if normal_2d.dot(wall_center_2d - center) < 0:
			normal_2d = -normal_2d
		var inward_dir := Vector3(-normal_2d.x, 0, -normal_2d.y)
		var inward := inward_dir * depth
		# Свес крыши: выступ наружу от стен
		var overhang := 0.5
		var outward := -inward_dir * overhang

		# Build roof slopes per edge in walk — each slope quad goes from
		# front edge (at actual polygon vertex heights + overhang) to back edge (at roof_y + inward)
		var rv := PackedVector3Array()
		var ru := PackedVector2Array()
		var rn := PackedVector3Array()
		var ri := PackedInt32Array()

		for wi in range(walk.size() - 1):
			var left_idx: int = walk[wi]
			var right_idx: int = walk[wi + 1]
			var left_pt: Vector2 = points[left_idx]
			var right_pt: Vector2 = points[right_idx]
			var left_y: float = roof_y + float(walk_extra[wi])
			var right_y: float = roof_y + float(walk_extra[wi + 1])

			# Front edge: polygon vertices + outward overhang, slightly lower
			var f_left := Vector3(left_pt.x, left_y - 0.1, left_pt.y) + outward
			var f_right := Vector3(right_pt.x, right_y - 0.1, right_pt.y) + outward
			# Back edge: same XZ offset by inward, at roof_y (flat at back)
			var b_left := Vector3(left_pt.x, roof_y, left_pt.y) + inward
			var b_right := Vector3(right_pt.x, roof_y, right_pt.y) + inward

			var vi_base: int = rv.size()
			rv.append(f_left)   # 0
			rv.append(f_right)  # 1
			rv.append(b_right)  # 2
			rv.append(b_left)   # 3

			var slope_n := (f_right - f_left).cross(b_left - f_left).normalized()
			if slope_n.y < 0:
				slope_n = -slope_n
			for _i in 4:
				rn.append(slope_n)

			ru.append(Vector2(0, 0))
			ru.append(Vector2(1, 0))
			ru.append(Vector2(1, 1))
			ru.append(Vector2(0, 1))

			ri.append_array([vi_base, vi_base + 1, vi_base + 2, vi_base, vi_base + 2, vi_base + 3])

		if rv.size() < 3:
			continue

		var roof_arrays := []
		roof_arrays.resize(Mesh.ARRAY_MAX)
		roof_arrays[Mesh.ARRAY_VERTEX] = rv
		roof_arrays[Mesh.ARRAY_TEX_UV] = ru
		roof_arrays[Mesh.ARRAY_NORMAL] = rn
		roof_arrays[Mesh.ARRAY_INDEX] = ri

		var roof_mesh := ArrayMesh.new()
		roof_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_arrays)

		var roof_inst := MeshInstance3D.new()
		roof_inst.mesh = roof_mesh
		roof_inst.material_override = _gabled_roof_material
		roof_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		roof_inst.name = "PedimentRoof_%d" % way_id
		parent.add_child(roof_inst)

		print("PedimentRoof: gable cap for way %d, walk=%s, extras=%s" % [way_id, str(walk), str(walk_extra)])

		# === Logo on front face ===
		if ped_data.has("logo"):
			var logo_path: String = "res://textures/" + ped_data["logo"]
			var logo_tex: Texture2D = load(logo_path) as Texture2D
			if logo_tex:
				# Center of front wall: midpoint between p1 and p2
				var mid_2d := (p1 + p2) / 2.0
				# Find peak extra height for vertical centering
				var max_extra := 0.0
				for we in walk_extra:
					if float(we) > max_extra:
						max_extra = float(we)
				# Logo center Y: middle of the rect_height section, raised 0.3m
				var logo_center_y := roof_y + rect_h * 0.5 + 0.3
				# Logo size: aspect ratio from texture
				var logo_aspect: float = float(logo_tex.get_width()) / float(logo_tex.get_height())
				var logo_h := rect_h * 1.2
				var logo_w := logo_h * logo_aspect
				# Wall tangent and outward normal
				var logo_wall_dir := (p2 - p1).normalized()
				var logo_tangent := Vector3(logo_wall_dir.x, 0, logo_wall_dir.y)
				var logo_outward := Vector3(normal_2d.x, 0, normal_2d.y) * 0.05
				var logo_center := Vector3(mid_2d.x, logo_center_y, mid_2d.y) + logo_outward

				var lv := PackedVector3Array()
				lv.append(logo_center - logo_tangent * logo_w * 0.5 - Vector3(0, logo_h * 0.5, 0))
				lv.append(logo_center + logo_tangent * logo_w * 0.5 - Vector3(0, logo_h * 0.5, 0))
				lv.append(logo_center + logo_tangent * logo_w * 0.5 + Vector3(0, logo_h * 0.5, 0))
				lv.append(logo_center - logo_tangent * logo_w * 0.5 + Vector3(0, logo_h * 0.5, 0))
				var lu := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
				var ln_vec := Vector3(normal_2d.x, 0, normal_2d.y).normalized()
				var ln := PackedVector3Array([ln_vec, ln_vec, ln_vec, ln_vec])
				var li := PackedInt32Array([0, 1, 2, 0, 2, 3])

				var logo_arrays := []
				logo_arrays.resize(Mesh.ARRAY_MAX)
				logo_arrays[Mesh.ARRAY_VERTEX] = lv
				logo_arrays[Mesh.ARRAY_TEX_UV] = lu
				logo_arrays[Mesh.ARRAY_NORMAL] = ln
				logo_arrays[Mesh.ARRAY_INDEX] = li

				var logo_mesh := ArrayMesh.new()
				logo_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, logo_arrays)

				var logo_shader := Shader.new()
				logo_shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;
uniform sampler2D logo_texture : source_color, filter_linear_mipmap;
uniform float emission_energy : hint_range(0.0, 8.0) = 2.0;
global uniform bool is_night_global;
void fragment() {
	vec4 tex = texture(logo_texture, UV);
	if (tex.a < 0.5) discard;
	ALBEDO = tex.rgb;
	ROUGHNESS = 0.4;
	METALLIC = 0.0;
	if (!FRONT_FACING) NORMAL = -NORMAL;
	if (is_night_global) {
		EMISSION = tex.rgb * emission_energy;
	}
}
"""
				var logo_mat := ShaderMaterial.new()
				logo_mat.shader = logo_shader
				logo_mat.set_shader_parameter("logo_texture", logo_tex)
				logo_mat.set_shader_parameter("emission_energy", 2.0)

				var logo_inst := MeshInstance3D.new()
				logo_inst.mesh = logo_mesh
				logo_inst.material_override = logo_mat
				logo_inst.name = "PedimentLogo_%d" % way_id
				parent.add_child(logo_inst)

		# === Entrance group along pediment front wall ===
		var entrance_text: String = ped_data.get("entrance_text", "")
		if entrance_text != "":
			var ground_y := base_elev
			var entrance_h := 3.5  # one story
			var wall_width_full := p1.distance_to(p2)
			var outward_3d := Vector3(normal_2d.x, 0, normal_2d.y)
			var tangent_3d := Vector3(wall_dir.x, 0, wall_dir.y)
			var canopy_depth := 1.5
			var canopy_thick := 0.1
			var frame_width := 0.08
			var panel_count := int(wall_width_full / 2.0)
			if panel_count < 3:
				panel_count = 3
			var panel_width := wall_width_full / panel_count

			# Glass panels + frames
			var gv := PackedVector3Array()
			var gu := PackedVector2Array()
			var gn := PackedVector3Array()
			var gi := PackedInt32Array()
			var fv := PackedVector3Array()  # frames
			var fu := PackedVector2Array()
			var fn := PackedVector3Array()
			var fi := PackedInt32Array()

			var n3d := outward_3d.normalized()
			var wall_offset := outward_3d * 0.15  # in front of wall to avoid z-fighting

			for pi in panel_count:
				var t_left := float(pi) / panel_count
				var t_right := float(pi + 1) / panel_count
				var left_2d := p1.lerp(p2, t_left)
				var right_2d := p1.lerp(p2, t_right)

				# Glass panel (inset by frame_width)
				var gl := left_2d + wall_dir * frame_width
				var gr := right_2d - wall_dir * frame_width
				var gidx := gv.size()
				gv.append(Vector3(gl.x, ground_y + frame_width, gl.y) + wall_offset)
				gv.append(Vector3(gr.x, ground_y + frame_width, gr.y) + wall_offset)
				gv.append(Vector3(gr.x, ground_y + entrance_h - frame_width, gr.y) + wall_offset)
				gv.append(Vector3(gl.x, ground_y + entrance_h - frame_width, gl.y) + wall_offset)
				gu.append(Vector2(0, 1)); gu.append(Vector2(1, 1))
				gu.append(Vector2(1, 0)); gu.append(Vector2(0, 0))
				for _i in 4: gn.append(n3d)
				gi.append_array([gidx, gidx+1, gidx+2, gidx, gidx+2, gidx+3])

				# Vertical frame left
				var fidx := fv.size()
				fv.append(Vector3(left_2d.x, ground_y, left_2d.y) + wall_offset)
				fv.append(Vector3(gl.x, ground_y, gl.y) + wall_offset)
				fv.append(Vector3(gl.x, ground_y + entrance_h, gl.y) + wall_offset)
				fv.append(Vector3(left_2d.x, ground_y + entrance_h, left_2d.y) + wall_offset)
				fu.append(Vector2(0, 1)); fu.append(Vector2(1, 1))
				fu.append(Vector2(1, 0)); fu.append(Vector2(0, 0))
				for _i in 4: fn.append(n3d)
				fi.append_array([fidx, fidx+1, fidx+2, fidx, fidx+2, fidx+3])

			# Right-most frame
			var fidx2 := fv.size()
			fv.append(Vector3(p2.x, ground_y, p2.y) + wall_offset - tangent_3d * frame_width)
			fv.append(Vector3(p2.x, ground_y, p2.y) + wall_offset)
			fv.append(Vector3(p2.x, ground_y + entrance_h, p2.y) + wall_offset)
			fv.append(Vector3(p2.x, ground_y + entrance_h, p2.y) + wall_offset - tangent_3d * frame_width)
			fu.append(Vector2(0, 1)); fu.append(Vector2(1, 1))
			fu.append(Vector2(1, 0)); fu.append(Vector2(0, 0))
			for _i in 4: fn.append(n3d)
			fi.append_array([fidx2, fidx2+1, fidx2+2, fidx2, fidx2+2, fidx2+3])

			# Top frame bar
			fidx2 = fv.size()
			fv.append(Vector3(p1.x, ground_y + entrance_h - frame_width, p1.y) + wall_offset)
			fv.append(Vector3(p2.x, ground_y + entrance_h - frame_width, p2.y) + wall_offset)
			fv.append(Vector3(p2.x, ground_y + entrance_h, p2.y) + wall_offset)
			fv.append(Vector3(p1.x, ground_y + entrance_h, p1.y) + wall_offset)
			fu.append(Vector2(0, 1)); fu.append(Vector2(1, 1))
			fu.append(Vector2(1, 0)); fu.append(Vector2(0, 0))
			for _i in 4: fn.append(n3d)
			fi.append_array([fidx2, fidx2+1, fidx2+2, fidx2, fidx2+2, fidx2+3])

			# Bottom frame bar
			fidx2 = fv.size()
			fv.append(Vector3(p1.x, ground_y, p1.y) + wall_offset)
			fv.append(Vector3(p2.x, ground_y, p2.y) + wall_offset)
			fv.append(Vector3(p2.x, ground_y + frame_width, p2.y) + wall_offset)
			fv.append(Vector3(p1.x, ground_y + frame_width, p1.y) + wall_offset)
			fu.append(Vector2(0, 1)); fu.append(Vector2(1, 1))
			fu.append(Vector2(1, 0)); fu.append(Vector2(0, 0))
			for _i in 4: fn.append(n3d)
			fi.append_array([fidx2, fidx2+1, fidx2+2, fidx2, fidx2+2, fidx2+3])

			# Create glass mesh
			var glass_arrays := []
			glass_arrays.resize(Mesh.ARRAY_MAX)
			glass_arrays[Mesh.ARRAY_VERTEX] = gv
			glass_arrays[Mesh.ARRAY_TEX_UV] = gu
			glass_arrays[Mesh.ARRAY_NORMAL] = gn
			glass_arrays[Mesh.ARRAY_INDEX] = gi
			var frame_arrays := []
			frame_arrays.resize(Mesh.ARRAY_MAX)
			frame_arrays[Mesh.ARRAY_VERTEX] = fv
			frame_arrays[Mesh.ARRAY_TEX_UV] = fu
			frame_arrays[Mesh.ARRAY_NORMAL] = fn
			frame_arrays[Mesh.ARRAY_INDEX] = fi

			var entrance_mesh := ArrayMesh.new()
			entrance_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, glass_arrays)
			entrance_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, frame_arrays)

			# Glass material
			var glass_shader := Shader.new()
			glass_shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;
global uniform bool is_night_global;
global uniform float wetness_global;
void fragment() {
	ALBEDO = vec3(0.25, 0.35, 0.5);
	ALPHA = 0.95;
	ROUGHNESS = 0.05;
	METALLIC = 0.15;
	SPECULAR = 0.8;
	if (!FRONT_FACING) NORMAL = -NORMAL;
	if (is_night_global) {
		EMISSION = vec3(0.15, 0.12, 0.08) * 0.5;
	}
}
"""
			var glass_mat := ShaderMaterial.new()
			glass_mat.shader = glass_shader

			# Frame material
			var frame_mat := ShaderMaterial.new()
			frame_mat.shader = BuildingWallShader
			frame_mat.set_shader_parameter("use_texture", false)
			frame_mat.set_shader_parameter("albedo_color", Color(0.15, 0.15, 0.18))
			frame_mat.set_shader_parameter("roughness_base", 0.3)

			var entrance_inst := MeshInstance3D.new()
			entrance_inst.mesh = entrance_mesh
			entrance_inst.set_surface_override_material(0, glass_mat)
			entrance_inst.set_surface_override_material(1, frame_mat)
			entrance_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			entrance_inst.name = "PedimentEntrance_%d" % way_id
			parent.add_child(entrance_inst)

			# Collision wall for entrance — trimesh at exact vertex positions
			var col_body := StaticBody3D.new()
			col_body.name = "PedimentEntranceCol_%d" % way_id
			var col_off := outward_3d * 0.15
			var c1 := Vector3(p1.x, ground_y, p1.y) + col_off
			var c2 := Vector3(p2.x, ground_y, p2.y) + col_off
			var c3 := Vector3(p2.x, ground_y + entrance_h, p2.y) + col_off
			var c4 := Vector3(p1.x, ground_y + entrance_h, p1.y) + col_off
			var col_faces := PackedVector3Array([c1, c2, c3, c1, c3, c4])
			var col_shape := CollisionShape3D.new()
			var concave := ConcavePolygonShape3D.new()
			concave.set_faces(col_faces)
			col_shape.shape = concave
			col_body.add_child(col_shape)
			parent.add_child(col_body)

			# Canopy above entrance
			var canopy_y := ground_y + entrance_h
			var cv := PackedVector3Array()
			var cu := PackedVector2Array()
			var cn := PackedVector3Array()
			var ci := PackedInt32Array()
			# Top face
			cv.append(Vector3(p1.x, canopy_y + canopy_thick, p1.y) + wall_offset)
			cv.append(Vector3(p2.x, canopy_y + canopy_thick, p2.y) + wall_offset)
			cv.append(Vector3(p2.x, canopy_y + canopy_thick, p2.y) + wall_offset + outward_3d * canopy_depth)
			cv.append(Vector3(p1.x, canopy_y + canopy_thick, p1.y) + wall_offset + outward_3d * canopy_depth)
			cu.append(Vector2(0, 0)); cu.append(Vector2(1, 0))
			cu.append(Vector2(1, 1)); cu.append(Vector2(0, 1))
			for _i in 4: cn.append(Vector3.UP)
			ci.append_array([0, 1, 2, 0, 2, 3])
			# Bottom face
			var cidx := cv.size()
			cv.append(Vector3(p1.x, canopy_y, p1.y) + wall_offset + outward_3d * canopy_depth)
			cv.append(Vector3(p2.x, canopy_y, p2.y) + wall_offset + outward_3d * canopy_depth)
			cv.append(Vector3(p2.x, canopy_y, p2.y) + wall_offset)
			cv.append(Vector3(p1.x, canopy_y, p1.y) + wall_offset)
			cu.append(Vector2(0, 0)); cu.append(Vector2(1, 0))
			cu.append(Vector2(1, 1)); cu.append(Vector2(0, 1))
			for _i in 4: cn.append(Vector3.DOWN)
			ci.append_array([cidx, cidx+1, cidx+2, cidx, cidx+2, cidx+3])
			# Front edge
			cidx = cv.size()
			cv.append(Vector3(p1.x, canopy_y, p1.y) + wall_offset + outward_3d * canopy_depth)
			cv.append(Vector3(p2.x, canopy_y, p2.y) + wall_offset + outward_3d * canopy_depth)
			cv.append(Vector3(p2.x, canopy_y + canopy_thick, p2.y) + wall_offset + outward_3d * canopy_depth)
			cv.append(Vector3(p1.x, canopy_y + canopy_thick, p1.y) + wall_offset + outward_3d * canopy_depth)
			cu.append(Vector2(0, 1)); cu.append(Vector2(1, 1))
			cu.append(Vector2(1, 0)); cu.append(Vector2(0, 0))
			for _i in 4: cn.append(n3d)
			ci.append_array([cidx, cidx+1, cidx+2, cidx, cidx+2, cidx+3])

			var canopy_arrays := []
			canopy_arrays.resize(Mesh.ARRAY_MAX)
			canopy_arrays[Mesh.ARRAY_VERTEX] = cv
			canopy_arrays[Mesh.ARRAY_TEX_UV] = cu
			canopy_arrays[Mesh.ARRAY_NORMAL] = cn
			canopy_arrays[Mesh.ARRAY_INDEX] = ci

			var canopy_mesh := ArrayMesh.new()
			canopy_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, canopy_arrays)
			var canopy_mat := ShaderMaterial.new()
			canopy_mat.shader = BuildingWallShader
			canopy_mat.set_shader_parameter("use_texture", false)
			canopy_mat.set_shader_parameter("albedo_color", Color(0.3, 0.3, 0.32))
			canopy_mat.set_shader_parameter("roughness_base", 0.4)

			var canopy_inst := MeshInstance3D.new()
			canopy_inst.mesh = canopy_mesh
			canopy_inst.material_override = canopy_mat
			canopy_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			canopy_inst.name = "PedimentCanopy_%d" % way_id
			parent.add_child(canopy_inst)

			# Text label directly on building wall (no background)
			var sign_mid := (p1 + p2) / 2.0
			var label_y := canopy_y + canopy_thick + 0.5
			var label := Label3D.new()
			label.text = entrance_text
			label.font = load("res://ui/fonts/arial_bold.ttf") as Font
			if not label.font:
				label.font = ThemeDB.fallback_font
			label.font_size = 128
			label.pixel_size = 0.005
			label.modulate = Color(0.1, 0.1, 0.5)
			label.outline_modulate = Color(0.05, 0.05, 0.3)
			label.outline_size = 8
			label.no_depth_test = false
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			label.position = Vector3(sign_mid.x, label_y, sign_mid.y) + outward_3d * 0.06
			label.rotation.y = atan2(normal_2d.x, normal_2d.y)
			label.name = "PedimentSignText_%d" % way_id
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


func _find_entrance_for_building(building_points: PackedVector2Array, _loader: Node, entrance_nodes: Array = []) -> Dictionary:
	"""
	Ищет вход, принадлежащий данному зданию.
	Вход считается принадлежащим, если он находится на контуре здания
	или в пределах небольшого расстояния от контура.

	ВАЖНО: Использует _latlon_to_local() (глобальная система координат),
	т.к. building_points уже конвертированы через неё в _create_building()

	Returns: {position: Vector2, wall_p1: Vector2, wall_p2: Vector2, tags: Dictionary} или пустой словарь
	"""
	const MAX_DISTANCE := 2.0  # Максимальное расстояние от контура (2 метра)

	for entrance in entrance_nodes:
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


func _find_pois_inside_building(building_points: PackedVector2Array, _loader: Node, poi_nodes: Array = []) -> Array:
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

	for poi in poi_nodes:
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


## Проверяет, стоит ли обрабатывать чанк (не culled). Culled чанки пропускаются.
## Всегда обрабатываем: initial loading, activation pending, visible чанки.
func _should_process_chunk(chunk_key: String) -> bool:
	# Во время initial loading — обрабатываем всё
	if _initial_loading:
		return true
	# Если нет в loaded — обрабатываем (ещё не можем culling)
	if not _loaded_chunks.has(chunk_key):
		return true
	var node: Node3D = _loaded_chunks[chunk_key]
	if not is_instance_valid(node):
		return true
	# Нефинализированные road batches должны дренироваться даже если чанк временно скрыт.
	if _pending_batch_chunks.has(chunk_key):
		return true
	# Activation pending — обрабатываем (ещё не visible, но нужно)
	if _chunk_activation_pending.has(chunk_key):
		return true
	# Visible чанки — обрабатываем
	if node.visible:
		return true
	# Culled (node.visible=false, не pending) — пропускаем
	return false

## Приоритет чанка: чем меньше значение, тем выше приоритет.
## Чанки перед камерой получают бонус (score уменьшается), сзади — штраф.
var _cached_cam_pos := Vector3.ZERO
var _cached_cam_fwd := Vector3.FORWARD
func _chunk_priority_score(chunk_key: String) -> float:
	var parts := chunk_key.split(",")
	var cx := float(int(parts[0])) * chunk_size + chunk_size * 0.5
	var cz := float(int(parts[1])) * chunk_size + chunk_size * 0.5
	var dx := cx - _cached_cam_pos.x
	var dz := cz - _cached_cam_pos.z
	var dist_sq := dx * dx + dz * dz
	# Направление к чанку относительно камеры: dot > 0 = впереди, < 0 = сзади
	var dist := sqrt(dist_sq) + 0.001
	var dot := (dx * _cached_cam_fwd.x + dz * _cached_cam_fwd.z) / dist
	# Чанки сзади камеры (dot < 0) получают штраф ×3
	if dot < 0.0:
		return dist_sq * 3.0
	return dist_sq

## Находит индекс processable чанка с наивысшим приоритетом. Возвращает -1 если все culled.
func _pick_closest_chunk_idx(queue: Array) -> int:
	var best_idx := -1
	var best_score := INF
	for i in queue.size():
		if not _should_process_chunk(queue[i]):
			continue
		var s := _chunk_priority_score(queue[i])
		if s < best_score:
			best_score = s
			best_idx = i
	return best_idx

## Возвращает ключи Dictionary отсортированные по приоритету (ближние перед камерой первые)
func _get_prioritized_keys(dict: Dictionary) -> Array:
	var keys: Array = dict.keys()
	# Filter out culled chunks — don't waste budget on invisible chunks
	var filtered: Array = []
	for k in keys:
		if _should_process_chunk(k):
			filtered.append(k)
	if filtered.size() > 1:
		filtered.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))
	return filtered

## Возвращает Rect2 для чанка по его ключу "cx,cz"
func _get_chunk_rect_from_key(chunk_key: String) -> Rect2:
	var parts := chunk_key.split(",")
	var cx := int(parts[0])
	var cz := int(parts[1])
	return Rect2(float(cx) * chunk_size, float(cz) * chunk_size, chunk_size, chunk_size)

## Клиппинг полигона по границам чанка. Возвращает массив клипнутых полигонов.
func _clip_polygon_to_chunk(poly: PackedVector2Array, chunk_key: String) -> Array[PackedVector2Array]:
	var rect := _get_chunk_rect_from_key(chunk_key)
	var rect_poly := PackedVector2Array([
		Vector2(rect.position.x, rect.position.y),
		Vector2(rect.end.x, rect.position.y),
		Vector2(rect.end.x, rect.end.y),
		Vector2(rect.position.x, rect.end.y),
	])
	var result: Array[PackedVector2Array] = []
	var clipped := Geometry2D.intersect_polygons(poly, rect_poly)
	for p in clipped:
		if p.size() >= 3:
			result.append(p)
	return result

## Smooths road geometry using Catmull-Rom spline interpolation
## This creates smooth curves through all points
## Клиппинг полилинии по прямоугольнику.
## Обрезает участки, полностью выходящие за rect. Вставляет точки пересечения на границе.
func _clip_polyline_to_rect(points: PackedVector2Array, min_x: float, max_x: float, min_z: float, max_z: float) -> PackedVector2Array:
	if points.size() < 2:
		return points

	var result := PackedVector2Array()
	for i in range(points.size() - 1):
		var segment: PackedVector2Array = _clip_segment_to_rect_segment(points[i], points[i + 1], min_x, max_x, min_z, max_z)
		if segment.size() < 2:
			continue
		for pt in segment:
			if result.is_empty() or result[result.size() - 1].distance_to(pt) > 0.01:
				result.append(pt)

	return result


func _clip_segment_to_rect_segment(a: Vector2, b: Vector2, min_x: float, max_x: float, min_z: float, max_z: float) -> PackedVector2Array:
	# Liang-Barsky line clipping. Inlined (no lambda) because GDScript
	# lambdas capture floats by value, breaking t0/t1 mutation across calls.
	var dx := b.x - a.x
	var dy := b.y - a.y
	var t0 := 0.0
	var t1 := 1.0
	var ps: Array[float] = [-dx, dx, -dy, dy]
	var qs: Array[float] = [a.x - min_x, max_x - a.x, a.y - min_z, max_z - a.y]
	for i in range(4):
		var p: float = ps[i]
		var q: float = qs[i]
		if absf(p) < 0.000001:
			if q < 0.0:
				return PackedVector2Array()
			continue
		var r: float = q / p
		if p < 0.0:
			if r > t1:
				return PackedVector2Array()
			if r > t0:
				t0 = r
		else:
			if r < t0:
				return PackedVector2Array()
			if r < t1:
				t1 = r
	if t1 < t0:
		return PackedVector2Array()

	return PackedVector2Array([
		Vector2(a.x + dx * t0, a.y + dy * t0),
		Vector2(a.x + dx * t1, a.y + dy * t1),
	])


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


func _is_closed_polyline(points: PackedVector2Array, tolerance: float = 0.5) -> bool:
	if points.size() < 3:
		return false
	return points[0].distance_to(points[points.size() - 1]) <= tolerance


func _build_segment_corridor_quad(a: Vector2, b: Vector2, delta: float) -> PackedVector2Array:
	var dir := b - a
	var len := dir.length()
	if len < 0.001:
		return PackedVector2Array()
	dir /= len
	var perp := Vector2(-dir.y, dir.x) * delta
	var cap := dir * delta
	return PackedVector2Array([
		a - perp - cap,
		a + perp - cap,
		b + perp + cap,
		b - perp + cap,
	])


func _build_terrain_corridors_for_polyline(points: PackedVector2Array, delta: float, clip_rect: PackedVector2Array = PackedVector2Array()) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if points.size() < 2:
		return result

	var is_closed := _is_closed_polyline(points)
	if not is_closed:
		var corridor_polys: Array[PackedVector2Array] = Geometry2D.offset_polyline(
			points, delta,
			Geometry2D.JOIN_MITER, Geometry2D.END_BUTT)
		for raw_corridor in corridor_polys:
			if raw_corridor.size() < 3:
				continue
			if _polygon_area(raw_corridor) < 0:
				raw_corridor.reverse()
			if clip_rect.is_empty():
				result.append(raw_corridor)
				continue
			var clipped_corr: Array[PackedVector2Array] = Geometry2D.intersect_polygons(raw_corridor, clip_rect)
			for cp in clipped_corr:
				if cp.size() >= 3 and _polygon_area(cp) > 0.001:
					result.append(cp)
		return result

	# Closed-loop roads such as roundabouts produce a filled disk when treated as one
	# corridor polygon. Split them into overlapping segment quads so terrain clipping
	# removes only the road ribbon and preserves the center island.
	for i in range(points.size() - 1):
		var quad := _build_segment_corridor_quad(points[i], points[i + 1], delta)
		if quad.size() < 3:
			continue
		if _polygon_area(quad) < 0:
			quad.reverse()
		if clip_rect.is_empty():
			result.append(quad)
			continue
		var clipped_quads: Array[PackedVector2Array] = Geometry2D.intersect_polygons(quad, clip_rect)
		for cp in clipped_quads:
			if cp.size() >= 3 and _polygon_area(cp) > 0.001:
				result.append(cp)
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


## Subdivide polygon edges so no edge is longer than max_len.
## Ensures mesh vertices are dense enough to follow elevation profile.
## Split a polygon into grid-cell-sized sub-polygons for accurate elevation following.
## Each resulting polygon covers at most one grid cell (grid_step x grid_step), so
## linear triangle interpolation closely matches the bilinear elevation surface.
func _split_polygon_by_grid(poly: PackedVector2Array, grid_step: float) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if poly.size() < 3:
		return result
	# Find AABB
	var p_min_x := poly[0].x
	var p_max_x := poly[0].x
	var p_min_y := poly[0].y
	var p_max_y := poly[0].y
	for i in range(1, poly.size()):
		p_min_x = minf(p_min_x, poly[i].x)
		p_max_x = maxf(p_max_x, poly[i].x)
		p_min_y = minf(p_min_y, poly[i].y)
		p_max_y = maxf(p_max_y, poly[i].y)
	# If polygon fits in ~1.5 cells, no splitting needed
	if (p_max_x - p_min_x) <= grid_step * 1.5 and (p_max_y - p_min_y) <= grid_step * 1.5:
		result.append(poly)
		return result
	# Snap AABB to grid
	var gx0 := floorf(p_min_x / grid_step) * grid_step
	var gy0 := floorf(p_min_y / grid_step) * grid_step
	# Intersect polygon with each grid cell
	var y := gy0
	while y < p_max_y:
		var x := gx0
		while x < p_max_x:
			var cell := PackedVector2Array([
				Vector2(x, y),
				Vector2(x + grid_step, y),
				Vector2(x + grid_step, y + grid_step),
				Vector2(x, y + grid_step),
			])
			var clipped: Array[PackedVector2Array] = Geometry2D.intersect_polygons(poly, cell)
			for cp in clipped:
				if cp.size() >= 3 and absf(_polygon_area(cp)) >= 0.5:
					result.append(cp)
			x += grid_step
		y += grid_step
	if result.is_empty():
		result.append(poly)
	return result


static func _subdivide_polygon_edges(poly: PackedVector2Array, max_len: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	var n := poly.size()
	if n < 3:
		return poly
	for i in range(n):
		var p1 := poly[i]
		var p2 := poly[(i + 1) % n]
		result.append(p1)
		var edge_len := p1.distance_to(p2)
		if edge_len > max_len:
			var segments := ceili(edge_len / max_len)
			for s in range(1, segments):
				var t := float(s) / float(segments)
				result.append(p1.lerp(p2, t))
	return result


## Triangulate a polygon with interior grid points for proper slope following.
## Returns {vertices: PackedVector2Array, indices: PackedInt32Array}.
## Creates a regular grid within the polygon AABB, keeps grid quads that overlap
## the polygon, and clips boundary triangles to the polygon edge.
static func _triangulate_polygon_with_grid(poly: PackedVector2Array, grid_step: float) -> Dictionary:
	var result := {"vertices": PackedVector2Array(), "indices": PackedInt32Array()}
	if poly.size() < 3:
		return result
	# Find AABB
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_y := poly[0].y
	var max_y := poly[0].y
	for i in range(1, poly.size()):
		min_x = minf(min_x, poly[i].x)
		max_x = maxf(max_x, poly[i].x)
		min_y = minf(min_y, poly[i].y)
		max_y = maxf(max_y, poly[i].y)
	# If polygon is smaller than grid, just use standard triangulation
	if (max_x - min_x) < grid_step * 2.0 and (max_y - min_y) < grid_step * 2.0:
		result.indices = Geometry2D.triangulate_polygon(poly)
		result.vertices = poly
		return result
	# Build grid vertices, snap AABB to grid
	var gx0 := floorf(min_x / grid_step) * grid_step
	var gy0 := floorf(min_y / grid_step) * grid_step
	var cols := ceili((max_x - gx0) / grid_step) + 1
	var rows := ceili((max_y - gy0) / grid_step) + 1
	# Create grid points and check which are inside polygon
	var grid_pts := PackedVector2Array()
	var inside := PackedInt32Array()  # 1 if inside or on boundary
	grid_pts.resize(cols * rows)
	inside.resize(cols * rows)
	for r in range(rows):
		for c in range(cols):
			var pt := Vector2(gx0 + c * grid_step, gy0 + r * grid_step)
			var idx := r * cols + c
			grid_pts[idx] = pt
			inside[idx] = 1 if Geometry2D.is_point_in_polygon(pt, poly) else 0
	# Build triangles from grid cells where at least one vertex is inside
	var verts := PackedVector2Array()
	var idxs := PackedInt32Array()
	var vert_map := {}  # grid_idx → output vertex idx
	for r in range(rows - 1):
		for c in range(cols - 1):
			var i00 := r * cols + c
			var i10 := r * cols + c + 1
			var i01 := (r + 1) * cols + c
			var i11 := (r + 1) * cols + c + 1
			var any_inside := inside[i00] or inside[i10] or inside[i01] or inside[i11]
			if not any_inside:
				continue
			# Add vertices if not already added
			for gi in [i00, i10, i01, i11]:
				if not vert_map.has(gi):
					vert_map[gi] = verts.size()
					verts.append(grid_pts[gi])
			# Two triangles per cell
			idxs.append(vert_map[i00])
			idxs.append(vert_map[i10])
			idxs.append(vert_map[i11])
			idxs.append(vert_map[i00])
			idxs.append(vert_map[i11])
			idxs.append(vert_map[i01])
	if idxs.is_empty():
		# Fallback
		result.indices = Geometry2D.triangulate_polygon(poly)
		result.vertices = poly
		return result
	result.vertices = verts
	result.indices = idxs
	return result


## Add a thin slit (epsilon-width) from corridor to nearest chunk boundary.
## If corridor already touches any boundary edge, returns it unchanged.
## This prevents clip_polygons from producing CW holes for interior corridors.
func _add_boundary_slit(corridor: PackedVector2Array, ch_x0: float, ch_x1: float, ch_z0: float, ch_z1: float) -> PackedVector2Array:
	# Check if corridor already touches any boundary
	var eps := 0.1
	var touches_boundary := false
	for i in range(corridor.size()):
		var p := corridor[i]
		if p.x <= ch_x0 + eps or p.x >= ch_x1 - eps or p.y <= ch_z0 + eps or p.y >= ch_z1 - eps:
			touches_boundary = true
			break
	if touches_boundary:
		return corridor
	# Find corridor point closest to any boundary
	var best_idx := 0
	var best_dist := INF
	for i in range(corridor.size()):
		var p := corridor[i]
		var d := minf(minf(p.x - ch_x0, ch_x1 - p.x), minf(p.y - ch_z0, ch_z1 - p.y))
		if d < best_dist:
			best_dist = d
			best_idx = i
	var pt := corridor[best_idx]
	# Find nearest boundary edge
	var d_left := pt.x - ch_x0
	var d_right := ch_x1 - pt.x
	var d_bottom := pt.y - ch_z0
	var d_top := ch_z1 - pt.y
	var min_d := minf(minf(d_left, d_right), minf(d_bottom, d_top))
	var boundary_pt: Vector2
	if min_d == d_left:
		boundary_pt = Vector2(ch_x0, pt.y)
	elif min_d == d_right:
		boundary_pt = Vector2(ch_x1, pt.y)
	elif min_d == d_bottom:
		boundary_pt = Vector2(pt.x, ch_z0)
	else:
		boundary_pt = Vector2(pt.x, ch_z1)
	# Build slit: thin rectangle (0.02m wide) from corridor point to boundary
	# Start slit 0.5m INSIDE corridor so merge_polygons gets an overlap (not just touching)
	var slit_dir := (boundary_pt - pt).normalized()
	var slit_start := pt - slit_dir * 0.5  # extend 0.5m past corridor vertex into corridor
	var slit_perp := Vector2(-slit_dir.y, slit_dir.x) * 0.01
	var slit := PackedVector2Array([
		slit_start + slit_perp, boundary_pt + slit_perp,
		boundary_pt - slit_perp, slit_start - slit_perp
	])
	# Merge slit with corridor
	var merged := Geometry2D.merge_polygons(corridor, slit)
	if merged.size() > 0 and merged[0].size() >= 3:
		if _polygon_area(merged[0]) < 0:
			merged[0].reverse()
		return merged[0]
	return corridor


## Validates road direction to remove points that create loops/flips
## Removes points where the direction changes by more than 75 degrees
## Also removes backtracking points (where road reverses direction)
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

	# Second pass: remove backtracking points where consecutive segments reverse direction
	# This catches micro-loops created by smoothing (e.g. two very close points in wrong order)
	if result.size() >= 4:
		var cleaned := PackedVector2Array()
		cleaned.append(result[0])
		for i in range(1, result.size() - 1):
			var dir_in: Vector2 = (result[i] - cleaned[cleaned.size() - 1]).normalized()
			var dir_out: Vector2 = (result[i + 1] - result[i]).normalized()
			# Skip if this point creates a reversal (dot < 0 = >90 degrees)
			if dir_in.dot(dir_out) < 0.0:
				continue
			# Skip if distance to previous point is tiny and creates a kink
			if cleaned[cleaned.size() - 1].distance_to(result[i]) < 0.5:
				var overall_dir: Vector2 = (result[i + 1] - cleaned[cleaned.size() - 1]).normalized()
				if dir_in.dot(overall_dir) < 0.5:
					continue
			cleaned.append(result[i])
		cleaned.append(result[result.size() - 1])
		result = cleaned

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


## Проверяет, находится ли точка рядом с перекрёстком (через spatial hash)
## Возвращает индекс перекрёстка или -1
func _find_nearby_intersection(pos: Vector2, radius: float = 15.0, ck: String = "") -> int:
	var cell_x := int(floor(pos.x / INTERSECTION_CELL_SIZE))
	var cell_y := int(floor(pos.y / INTERSECTION_CELL_SIZE))
	var cells_needed := int(ceil(radius / INTERSECTION_CELL_SIZE))
	for cx in range(cell_x - cells_needed, cell_x + cells_needed + 1):
		for cy in range(cell_y - cells_needed, cell_y + cells_needed + 1):
			var key := Vector2i(cx, cy)
			var indices := _query_intersection_hash(key, ck)
			for i in indices:
				if i < _intersection_positions.size() and pos.distance_to(_intersection_positions[i]) < radius:
					return i
	return -1


## Проверяет, является ли перекрёсток равнозначным
func _is_equal_intersection(intersection_idx: int) -> bool:
	if intersection_idx < 0 or intersection_idx >= _intersection_types.size():
		return false
	return _intersection_types[intersection_idx]


## Ищет ближайший перекрёсток в пределах радиуса (через spatial hash)
func _find_nearest_intersection(pos: Vector2, max_dist: float, ck: String = "") -> int:
	var best_idx := -1
	var best_dist := max_dist
	# Search 3x3 cells around pos for nearby intersections
	var cell_x := int(floor(pos.x / INTERSECTION_CELL_SIZE))
	var cell_y := int(floor(pos.y / INTERSECTION_CELL_SIZE))
	for cx in range(cell_x - 1, cell_x + 2):
		for cy in range(cell_y - 1, cell_y + 2):
			var key := Vector2i(cx, cy)
			var indices := _query_intersection_hash(key, ck)
			for i in indices:
				if i >= _intersection_positions.size():
					continue
				var dist := pos.distance_to(_intersection_positions[i])
				if dist < best_dist:
					best_dist = dist
					best_idx = i
	return best_idx


## Query road segments from per-chunk hashes. If ck given — single chunk, else all loaded.
func _query_road_hash(key: Vector2i, ck: String = "") -> Array:
	if ck != "":
		var h: Dictionary = _chunk_road_hashes.get(ck, {})
		if h.has(key):
			return h[key]
		return []
	var result: Array = []
	for c in _chunk_road_hashes:
		var h: Dictionary = _chunk_road_hashes[c]
		if h.has(key):
			result.append_array(h[key])
	return result

## Query building segments from per-chunk hashes. If ck given — single chunk.
func _query_building_hash(key: Vector2i, ck: String = "") -> Array:
	if ck != "":
		var h: Dictionary = _chunk_building_hashes.get(ck, {})
		if h.has(key):
			return h[key]
		return []
	var result: Array = []
	for c in _chunk_building_hashes:
		var h: Dictionary = _chunk_building_hashes[c]
		if h.has(key):
			result.append_array(h[key])
	return result

## Query parking data from per-chunk hashes. If ck given — single chunk.
## Returns {"entries": Array, "polys": Array} for single chunk, or merged entries for all.
func _query_parking_in_chunk(key: Vector2i, ck: String) -> Dictionary:
	var data: Dictionary = _chunk_parking_hashes.get(ck, {})
	var h: Dictionary = data.get("hash", {})
	if h.has(key):
		return {"entries": h[key], "polys": data.get("polys", [])}
	return {"entries": [], "polys": data.get("polys", [])}

## Query water data from per-chunk hashes. If ck given — single chunk.
func _query_water_in_chunk(key: Vector2i, ck: String) -> Dictionary:
	var data: Dictionary = _chunk_water_hashes.get(ck, {})
	var h: Dictionary = data.get("hash", {})
	if h.has(key):
		return {"entries": h[key], "polys": data.get("polys", [])}
	return {"entries": [], "polys": data.get("polys", [])}

## Query intersection indices from per-chunk hashes. If ck given — single chunk.
func _query_intersection_hash(key: Vector2i, ck: String = "") -> Array:
	if ck != "":
		var h: Dictionary = _chunk_intersection_hashes.get(ck, {})
		if h.has(key):
			return h[key]
		return []
	var result: Array = []
	for c in _chunk_intersection_hashes:
		var h: Dictionary = _chunk_intersection_hashes[c]
		if h.has(key):
			result.append_array(h[key])
	return result

## Removes all spatial hash entries contributed by a chunk
func _cleanup_chunk_hash_cells(chunk_key: String) -> void:
	_chunk_hash_cells.erase(chunk_key)
	_chunk_road_hashes.erase(chunk_key)
	_chunk_building_hashes.erase(chunk_key)
	_chunk_building_poly_hashes.erase(chunk_key)
	_chunk_parking_hashes.erase(chunk_key)
	_chunk_water_hashes.erase(chunk_key)
	_chunk_intersection_hashes.erase(chunk_key)


## Добавляет перекрёсток в per-chunk intersection spatial hash
func _add_intersection_to_spatial_hash(pos: Vector2, radii: Vector2, idx: int, chunk_key: String = "") -> void:
	# Определяем bounding box перекрёстка с учётом максимального радиуса
	var max_radius := maxf(radii.x, radii.y) * 1.5  # С запасом для scale
	var min_cell_x := int(floor((pos.x - max_radius) / INTERSECTION_CELL_SIZE))
	var max_cell_x := int(floor((pos.x + max_radius) / INTERSECTION_CELL_SIZE))
	var min_cell_y := int(floor((pos.y - max_radius) / INTERSECTION_CELL_SIZE))
	var max_cell_y := int(floor((pos.y + max_radius) / INTERSECTION_CELL_SIZE))

	# Per-chunk intersection hash
	var ci_hash: Dictionary = {}
	if chunk_key != "":
		if not _chunk_intersection_hashes.has(chunk_key):
			_chunk_intersection_hashes[chunk_key] = {}
		ci_hash = _chunk_intersection_hashes[chunk_key]

	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if chunk_key != "":
				if not ci_hash.has(key):
					ci_hash[key] = []
				ci_hash[key].append(idx)


## Получает индексы перекрёстков рядом с точкой через spatial hash
func _get_nearby_intersections(pos: Vector2, ck: String = "") -> Array:
	var cell_x := int(floor(pos.x / INTERSECTION_CELL_SIZE))
	var cell_y := int(floor(pos.y / INTERSECTION_CELL_SIZE))
	var key := Vector2i(cell_x, cell_y)
	return _query_intersection_hash(key, ck)


## Добавляет сегмент дороги в per-chunk spatial hash
func _add_road_segment_to_spatial_hash(seg: Dictionary, chunk_key: String = "") -> void:
	if chunk_key.is_empty():
		return
	var p1: Vector2 = seg.p1
	var p2: Vector2 = seg.p2
	var width: float = seg.width

	var min_x := minf(p1.x, p2.x) - width / 2.0
	var max_x := maxf(p1.x, p2.x) + width / 2.0
	var min_y := minf(p1.y, p2.y) - width / 2.0
	var max_y := maxf(p1.y, p2.y) + width / 2.0

	var min_cell_x := int(floor(min_x / ROAD_CELL_SIZE))
	var max_cell_x := int(floor(max_x / ROAD_CELL_SIZE))
	var min_cell_y := int(floor(min_y / ROAD_CELL_SIZE))
	var max_cell_y := int(floor(max_y / ROAD_CELL_SIZE))

	if not _chunk_road_hashes.has(chunk_key):
		_chunk_road_hashes[chunk_key] = {}
	var h: Dictionary = _chunk_road_hashes[chunk_key]

	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not h.has(key):
				h[key] = []
			h[key].append(seg)


## Получает сегменты дорог рядом с точкой через spatial hash
func _get_nearby_road_segments(pos: Vector2, ck: String = "") -> Array:
	var cell_x := int(floor(pos.x / ROAD_CELL_SIZE))
	var cell_y := int(floor(pos.y / ROAD_CELL_SIZE))
	var key := Vector2i(cell_x, cell_y)
	return _query_road_hash(key, ck)


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
			var segs := _query_road_hash(key)

			for seg in segs:
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


## Публичный API: проверяет, находится ли точка на дороге
func is_point_on_road(pos: Vector2, margin: float = 0.5) -> bool:
	return _is_point_on_road(pos, margin)


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


## Добавляет сегмент стены здания в per-chunk spatial hash
func _add_building_segment_to_spatial_hash(seg: Dictionary, chunk_key: String = "") -> void:
	if chunk_key.is_empty():
		return
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

	if not _chunk_building_hashes.has(chunk_key):
		_chunk_building_hashes[chunk_key] = {}
	var h: Dictionary = _chunk_building_hashes[chunk_key]

	for cx in range(min_cell_x, max_cell_x + 1):
		for cy in range(min_cell_y, max_cell_y + 1):
			var key := Vector2i(cx, cy)
			if not h.has(key):
				h[key] = []
			h[key].append(seg)


## Добавляет полигон здания в per-chunk spatial hash
func _add_building_poly_to_hash(poly: PackedVector2Array, chunk_key: String = "") -> void:
	if chunk_key.is_empty():
		return
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_y := poly[0].y
	var max_y := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	var min_cx := int(floor(min_x / BUILDING_CELL_SIZE))
	var max_cx := int(floor(max_x / BUILDING_CELL_SIZE))
	var min_cy := int(floor(min_y / BUILDING_CELL_SIZE))
	var max_cy := int(floor(max_y / BUILDING_CELL_SIZE))
	if not _chunk_building_poly_hashes.has(chunk_key):
		_chunk_building_poly_hashes[chunk_key] = {}
	var h: Dictionary = _chunk_building_poly_hashes[chunk_key]
	for cx in range(min_cx, max_cx + 1):
		for cy in range(min_cy, max_cy + 1):
			var key := Vector2i(cx, cy)
			if not h.has(key):
				h[key] = []
			h[key].append(poly)


## Проверяет, находится ли точка слишком близко к любому зданию
func _is_point_near_building(point: Vector2, min_distance: float, ck: String = "") -> bool:
	var cell_x := int(floor(point.x / BUILDING_CELL_SIZE))
	var cell_y := int(floor(point.y / BUILDING_CELL_SIZE))

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell_x + dx, cell_y + dy)
			var segs := _query_building_hash(key, ck)
			for seg in segs:
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
func _is_point_in_intersection_shape(pos: Vector2, use_curb_contour: bool = false, ck: String = "") -> int:
	var nearby := _get_nearby_intersections(pos, ck)
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


## Создаёт заплатку на перекрёстке (чистый асфальт без разметки)
## Использует контур перекрёстка если доступен, иначе fallback на эллипс
## Каждая вершина следует за elevation terrain + наклон дороги
func _create_intersection_patch(pos: Vector2, parent: Node3D, intersection_idx: int = -1, height_offset: float = 0.096, chunk_key: String = "") -> void:
	if not _road_textures.has("intersection"):
		return

	# Z-offset: дороги имеют hash-based z_offset до 0.03, заплатка должна быть выше всех
	var z_off := 0.005
	var uv_ws := 1.0 / 6.0  # Совпадает с residential road uv_scale

	# Build full patch polygon (contour or ellipse)
	var patch_poly := PackedVector2Array()
	var contour := PackedVector2Array()
	if intersection_idx >= 0 and intersection_idx < _intersection_contours.size():
		contour = _intersection_contours[intersection_idx]

	if contour.size() >= 3:
		patch_poly = contour
	else:
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
			patch_poly.append(Vector2(pos.x + rx, pos.y + ry))

	if patch_poly.size() < 3:
		return

	# Clip to chunk bounds
	var polys_to_render: Array[PackedVector2Array] = []
	if chunk_key != "" and chunk_key != "initial":
		var ck_parts := chunk_key.split(",")
		var ck_x := int(ck_parts[0])
		var ck_z := int(ck_parts[1])
		var chunk_rect := PackedVector2Array([
			Vector2(float(ck_x) * chunk_size, float(ck_z) * chunk_size),
			Vector2(float(ck_x + 1) * chunk_size, float(ck_z) * chunk_size),
			Vector2(float(ck_x + 1) * chunk_size, float(ck_z + 1) * chunk_size),
			Vector2(float(ck_x) * chunk_size, float(ck_z + 1) * chunk_size),
		])
		# Ensure CCW winding for intersect_polygons
		if _polygon_area(patch_poly) < 0:
			patch_poly.reverse()
		var clipped := Geometry2D.intersect_polygons(patch_poly, chunk_rect)
		for cp in clipped:
			if cp.size() >= 3:
				polys_to_render.append(cp)
	else:
		polys_to_render.append(patch_poly)

	if polys_to_render.is_empty():
		return

	# Build mesh with ArrayMesh for proper clipped polygon triangulation
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	for poly in polys_to_render:
		# Split by 10m grid so each cell follows bilinear elevation
		var grid_cells := _split_polygon_by_grid(poly, 10.0)
		for cell_poly in grid_cells:
			var tri_idx := Geometry2D.triangulate_polygon(cell_poly)
			if tri_idx.is_empty():
				continue
			var base_idx := vertices.size()
			for p2 in cell_poly:
				var h := _sample_elevation(p2.x, p2.y) + height_offset + z_off
				vertices.append(Vector3(p2.x, h, p2.y))
				uvs.append(Vector2(p2.x * uv_ws, p2.y * uv_ws))
				normals.append(Vector3.UP)
			for ti in tri_idx:
				indices.append(base_idx + ti)

	if vertices.is_empty():
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = arr_mesh

	var albedo_tex: Texture2D = _road_textures.get("intersection", null)
	var normal_tex: Texture2D = _normal_textures.get("asphalt", null)
	var roughness_tex: Texture2D = _road_textures.get("road_roughness", null)
	var material: Material = WetRoadMaterial.create_road_shader_material(
		albedo_tex, normal_tex, _is_wet_mode, _is_night_mode,
		_noise_textures.get("micro", null),
		_noise_textures.get("macro", null),
		roughness_tex
	)
	if material is ShaderMaterial:
		WetRoadMaterial.apply_road_type_params(material, "intersection")
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Collision — StaticBody3D with trimesh collision
	var body := StaticBody3D.new()
	body.name = "IntersectionCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	body.add_to_group("Road")
	body.add_child(mesh_instance)
	mesh_instance.create_trimesh_collision()
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			var col_shape := child.get_child(0)
			if col_shape is CollisionShape3D:
				child.remove_child(col_shape)
				body.add_child(col_shape)
			child.queue_free()

	# Регистрируем материал для wet mode
	if chunk_key != "" and material is ShaderMaterial:
		if not _chunk_road_materials.has(chunk_key):
			_chunk_road_materials[chunk_key] = []
		_chunk_road_materials[chunk_key].append(material)

	parent.add_child(body)


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


## Чанк полностью финализирован: загружен, все очереди обработаны, RS instances активированы
func is_chunk_fully_ready(chunk_key: String) -> bool:
	if _chunk_state.has(chunk_key):
		return _chunk_state[chunk_key].get("stage", "") == "ready"
	return _loaded_chunks.has(chunk_key) and not _chunk_activation_pending.has(chunk_key)


## Lazy chunk activation — даёт Vulkan время подготовить GPU ресурсы перед показом
func _process_chunk_activation() -> void:
	if _chunk_activation_pending.is_empty():
		return

	# Состояния в _chunk_activation_pending:
	# -1 = ждём финализации
	# >= 0 = индекс следующего RS instance для активации
	# During initial loading: activate ALL instances immediately (loading screen hides stutter)
	# During gameplay: drip-feed 4 per frame to avoid Vulkan upload spikes
	var rs_per_frame := 999999 if _initial_loading else 4

	# Сортируем по приоритету: ближайшие к камере первыми
	var activation_keys: Array = _chunk_activation_pending.keys()
	if activation_keys.size() > 1:
		activation_keys.sort_custom(func(a, b): return _chunk_priority_score(a) < _chunk_priority_score(b))

	for chunk_key in activation_keys:
		var state: int = _chunk_activation_pending[chunk_key]
		var chunk_debug_state: Dictionary = _chunk_state.get(chunk_key, {})
		var data_loaded_ms: int = int(chunk_debug_state.get("data_loaded_ms", 0))
		var elapsed_since_data: int = Time.get_ticks_msec() - data_loaded_ms if data_loaded_ms > 0 else 0

		if state == -1:
			if elapsed_since_data > CHUNK_STALL_FAIL_MS:
				_emit_chunk_debug("CHUNK_DROP key=%s reason=activation_timeout stage=%s" % [chunk_key, str(chunk_debug_state.get("stage", ""))])
				if _chunk_debug_enabled():
					dump_chunk_pipeline(chunk_key)
				_retry_chunk_load(chunk_key, "activation_timeout")
				continue
			if elapsed_since_data > CHUNK_STALL_WARN_MS:
				var last_report_ms: int = int(chunk_debug_state.get("last_stall_report_ms", 0))
				if Time.get_ticks_msec() - last_report_ms > 1000:
					chunk_debug_state["last_stall_report_ms"] = Time.get_ticks_msec()
					_chunk_state[chunk_key] = chunk_debug_state
					dump_chunk_pipeline(chunk_key)
			if not _chunk_has_pending_work(chunk_key):
				_chunk_activation_pending[chunk_key] = 0  # начинаем пакетную активацию
				_set_chunk_stage(chunk_key, "activating")
		else:
			# Пакетная активация RS instances по N за кадр
			if not _chunk_rs_instances.has(chunk_key):
				# Нет RS instances — сразу включаем scene tree node
				var cn: Node3D = _get_chunk_node(chunk_key)
				if is_instance_valid(cn):
					cn.visible = true
				_chunk_activation_pending.erase(chunk_key)
				_remove_loading_placeholder(chunk_key)
				_chunk_culling_cooldown[chunk_key] = Time.get_ticks_msec() + 3000
				_set_chunk_stage(chunk_key, "ready", {"node": cn})
				continue

			var instances: Array = _chunk_rs_instances[chunk_key]
			var end_idx: int = mini(state + rs_per_frame, instances.size())
			var i := state
			while i < end_idx:
				RenderingServer.instance_set_visible(instances[i], true)
				i += 1
			if end_idx >= instances.size():
				# Все RS instances активированы — включаем scene tree node
				var cn: Node3D = _get_chunk_node(chunk_key)
				if is_instance_valid(cn):
					cn.visible = true
				_chunk_activation_pending.erase(chunk_key)
				_remove_loading_placeholder(chunk_key)
				_chunk_culling_cooldown[chunk_key] = Time.get_ticks_msec() + 3000
				_set_chunk_stage(chunk_key, "ready", {"node": cn})
			else:
				_chunk_activation_pending[chunk_key] = end_idx


## Budgeted add_child — limits scene tree insertions per frame.
## Returns true if added immediately, false if deferred.
func _budgeted_add_child(parent_node: Node, child_node: Node) -> bool:
	if _add_child_count < _add_child_budget:
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
		_culling_visible_count = _loaded_chunks.size()
		_culling_culled_count = 0
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
		# Чанки в процессе lazy activation — считаем видимыми (они уже рендерятся)
		if _chunk_activation_pending.has(chunk_key):
			visible_count += 1
			continue
		# Don't cull recently activated chunks (3s cooldown to prevent appear/disappear/appear)
		if _chunk_culling_cooldown.has(chunk_key):
			if Time.get_ticks_msec() < _chunk_culling_cooldown[chunk_key]:
				visible_count += 1
				continue
			else:
				_chunk_culling_cooldown.erase(chunk_key)

		var chunk_node: Node3D = _loaded_chunks[chunk_key]
		if not is_instance_valid(chunk_node):
			continue

		var coords: PackedStringArray = chunk_key.split(",")
		var chunk_x := int(coords[0])
		var chunk_z := int(coords[1])

		# AABB чанка с учётом высоты и elevation
		var elev_min := 0.0
		var elev_max := 0.0
		if enable_elevation:
			var ck_elev: Dictionary = _chunk_elevation_data.get(chunk_key, {})
			if ck_elev.has("grid"):
				var first := true
				for row in ck_elev.grid:
					for h in row:
						if h != null:
							var hf: float = float(h)
							if first:
								elev_min = hf
								elev_max = hf
								first = false
							else:
								if hf < elev_min:
									elev_min = hf
								if hf > elev_max:
									elev_max = hf
				elev_min -= 10.0  # margin
		var aabb_min := Vector3(chunk_x * chunk_size, elev_min - 5.0, chunk_z * chunk_size)
		var aabb_max := Vector3(aabb_min.x + chunk_size, elev_max + chunk_height, aabb_min.z + chunk_size)
		var aabb_center := (aabb_min + aabb_max) * 0.5
		var aabb_half := (aabb_max - aabb_min) * 0.5

		# Расстояние до ближнего ребра чанка
		var nearest_x := clampf(car_pos.x, aabb_min.x, aabb_max.x)
		var nearest_z := clampf(car_pos.z, aabb_min.z, aabb_max.z)
		var dist_to_edge := car_pos.distance_to(Vector3(nearest_x, car_pos.y, nearest_z))

		# Ближние чанки (< chunk_size до ребра) — всегда видимы
		if dist_to_edge < chunk_size:
			if not chunk_node.visible:
				chunk_node.visible = true
				if _chunk_rs_instances.has(chunk_key):
					for rid in _chunk_rs_instances[chunk_key]:
						RenderingServer.instance_set_visible(rid, true)
			visible_count += 1
			continue

		# Тест AABB vs frustum planes
		var inside_frustum := true
		var failed_plane_idx := -1
		for pi in frustum.size():
			var plane: Plane = frustum[pi]
			var d := aabb_center.dot(plane.normal) + plane.d
			var r := absf(aabb_half.x * plane.normal.x) + absf(aabb_half.y * plane.normal.y) + absf(aabb_half.z * plane.normal.z)
			if d + r < 0.0:
				inside_frustum = false
				failed_plane_idx = pi
				break

		var should_hide := not inside_frustum
		var cull_reason := ""
		if should_hide:
			cull_reason = "frustum_plane_%d" % failed_plane_idx

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
					cull_reason = "behind(dot=%.2f,dist=%.0f)" % [dot, dist]

		if should_hide:
			culled_count += 1
		else:
			visible_count += 1

		var want_visible := not should_hide
		if chunk_node.visible != want_visible:
			if want_visible:
				print("CULL: %s SHOW (was hidden)" % chunk_key)
			else:
				print("CULL: %s HIDE reason=%s aabb=(%.0f,%.0f,%.0f)-(%.0f,%.0f,%.0f) cam=(%.0f,%.0f,%.0f) fwd=(%.2f,%.2f) car=(%.0f,%.0f,%.0f)" % [
					chunk_key, cull_reason,
					aabb_min.x, aabb_min.y, aabb_min.z, aabb_max.x, aabb_max.y, aabb_max.z,
					cam_pos.x, cam_pos.y, cam_pos.z,
					cam_forward.x, cam_forward.z,
					car_pos.x, car_pos.y, car_pos.z])
			chunk_node.visible = want_visible
			# Also toggle RS instances (roads, buildings, fences, terrain)
			if _chunk_rs_instances.has(chunk_key):
				for rid in _chunk_rs_instances[chunk_key]:
					RenderingServer.instance_set_visible(rid, want_visible)
			# Clean queues when chunk becomes culled — free resources for visible chunks
			if not want_visible:
				var can_purge := _can_purge_chunk_on_cull(chunk_key)
				_emit_road_debug("CHUNK_CULL key=%s visible=%s purge=%s stage=%s blockers=%s" % [
					chunk_key,
					str(want_visible),
					str(can_purge),
					str(_chunk_state.get(chunk_key, {}).get("stage", "")),
					"|".join(_collect_chunk_blockers(chunk_key))
				])
				if can_purge:
					_purge_chunk_queues(chunk_key)

	# Сохраняем для HUD
	_culling_visible_count = visible_count
	_culling_culled_count = culled_count


## Purge all queued work for a chunk that became culled
func _purge_chunk_queues(chunk_key: String) -> void:
	# Don't purge initial chunks that haven't completed yet
	if _initial_loading and not _initial_chunks_completed.has(chunk_key):
		return
	# Per-chunk Dictionary queues — O(1) erase
	_road_queue.erase(chunk_key)
	_deferred_lamp_queue.erase(chunk_key)
	_deferred_manhole_queue.erase(chunk_key)
	_deferred_footway_queue.erase(chunk_key)
	_deferred_billboard_queue.erase(chunk_key)
	_deferred_building_collisions.erase(chunk_key)
	_deferred_tree_collisions.erase(chunk_key)
	_deferred_road_collisions.erase(chunk_key)
	_deferred_terrain_collisions.erase(chunk_key)
	_deferred_lamp_lights.erase(chunk_key)
	_deferred_fence_edges.erase(chunk_key)
	# Road batch data
	_road_batch_data.erase(chunk_key)
	_entrance_batch.erase(chunk_key)
	_window_batch_data.erase(chunk_key)
	# Array-based finalization queues — remove chunk_key if present
	var pbc_idx := _pending_batch_chunks.find(chunk_key)
	if pbc_idx >= 0:
		_pending_batch_chunks.remove_at(pbc_idx)
	var bgf_idx := _building_geo_finalize_queue.find(chunk_key)
	if bgf_idx >= 0:
		_building_geo_finalize_queue.remove_at(bgf_idx)
	var lb_idx := _lamp_batches_to_finalize.find(chunk_key)
	if lb_idx >= 0:
		_lamp_batches_to_finalize.remove_at(lb_idx)
	var tb_idx := _tree_batches_to_finalize.find(chunk_key)
	if tb_idx >= 0:
		_tree_batches_to_finalize.remove_at(tb_idx)
	var bb_idx := _billboard_batches_to_finalize.find(chunk_key)
	if bb_idx >= 0:
		_billboard_batches_to_finalize.remove_at(bb_idx)
	var fb_idx := _fence_batches_to_finalize.find(chunk_key)
	if fb_idx >= 0:
		_fence_batches_to_finalize.remove_at(fb_idx)
	# Building geo batch
	_building_geo_batch.erase(chunk_key)
	# Lamp batch data
	_lamp_batch_data.erase(chunk_key)
	# Tree batch data
	_tree_batch_data.erase(chunk_key)
	# Phase3 queue — remove entries for this chunk
	var p3_i := _phase3_queue.size() - 1
	while p3_i >= 0:
		if _phase3_queue[p3_i].chunk_key == chunk_key:
			_phase3_queue.remove_at(p3_i)
		p3_i -= 1


## Проверяет, находится ли текущая локация в Череповце
func _is_cherepovets_location() -> bool:
	# Простая проверка: если decoration_layer загружен, значит Череповец
	# (decoration_layer загружается только для активированных городов)
	return _decoration_layer != null


func _is_russia_location() -> bool:
	# Примерные границы России: lat 41-82, lon 19-180
	return start_lat >= 41.0 and start_lat <= 82.0 and start_lon >= 19.0 and start_lon <= 180.0


## Проверяет, является ли здание пятиэтажным
func _is_5_story_building(height: float, tags: Dictionary) -> bool:
	# Метод 1: Проверка явного тега levels
	if tags.has("building:levels"):
		var levels_str := str(tags.get("building:levels", ""))
		if levels_str.is_valid_int():
			var levels := int(levels_str)
			if levels == 5:
				return true

	# Метод 2: Проверка диапазона высоты (5 этажей × 3.2м ≈ 15-16.5м)
	if height >= 15.0 and height <= 16.5:
		return true

	return false


## Возвращает советскую текстуру на основе материала здания (детерминированную по way_id)
func _get_random_soviet_texture(way_id: int, tags: Dictionary) -> String:
	# Панельные текстуры (5 вариантов)
	const PANEL_TEXTURES := [
		"res://textures/buildings/5-soviet-panel.png",
		"res://textures/buildings/5-soviet-panel-2.png",
		"res://textures/buildings/5-soviet-panel-3.png",
		"res://textures/buildings/5-soviet-panel-4.png",
		"res://textures/buildings/5-soviet-panel-5.png"
	]

	# Кирпичная текстура (1 вариант)
	const BRICK_TEXTURE := "res://textures/buildings/5-soviet-brick.png"

	# Определяем материал из OSM тегов
	var material := str(tags.get("building:material", ""))

	# Кирпичные здания
	if material == "brick":
		return BRICK_TEXTURE

	# Панельные здания (concrete, panel) или по умолчанию
	# Используем way_id как seed для консистентных результатов между запусками игры
	var index := way_id % PANEL_TEXTURES.size()
	return PANEL_TEXTURES[index]
