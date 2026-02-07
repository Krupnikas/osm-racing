# Procedural Decoration Layer

**Цель**: Добавлять атмосферу и жизнь поверх OSM данных — билборды, переопределения зданий, и другие декорации.

> OSM даёт структуру. Decoration Layer даёт жизнь.

---

## Архитектура

### Файлы

```
osm/
├── decoration_layer.gd              # Главный контроллер
└── decorations/
    ├── billboard_decoration.gd      # Рекламные щиты
    └── building_override.gd         # Переопределение зданий
```

### Классы

#### DecorationLayer (Node)

Главный контроллер, управляющий всеми декорациями.

```gdscript
class_name DecorationLayer
extends Node

# Загруженные декорации
var _billboards: Array = []           # BillboardDecoration[]
var _building_overrides: Array = []   # BuildingOverride[]

# Spatial index для быстрого поиска
var _building_override_by_way_id: Dictionary = {}  # way_id -> BuildingOverride

# Методы
func get_building_override_for_way(way_id: int)  # Возвращает override или null
func get_billboards_in_chunk(chunk_min, chunk_max) -> Array
func create_billboard_mesh(billboard, elevation) -> Node3D
```

#### BillboardDecoration (Resource)

Рекламный щит с текстом или текстурой.

```gdscript
class_name BillboardDecoration
extends Resource

# Позиционирование
@export var lat: float = 0.0
@export var lon: float = 0.0
@export var use_latlon: bool = true
@export var local_position: Vector2 = Vector2.ZERO

# Ориентация и размеры
@export var rotation_y: float = 0.0           # Поворот (радианы)
@export var size: Vector2 = Vector2(4.0, 3.0) # Ширина x Высота (метры)
@export var pole_height: float = 3.0          # Высота столба

# Контент
@export var text: String = ""                 # Текст на билборде
@export var texture_path: String = ""         # Путь к текстуре
@export var background_color: Color = Color.WHITE
@export var text_color: Color = Color.BLACK

# Освещение
@export var has_backlight: bool = true        # Подсветка ночью
@export var emission_strength: float = 0.5
```

#### BuildingOverride (Resource)

Переопределение свойств здания по OSM way ID.

```gdscript
class_name BuildingOverride
extends Resource

# Идентификация
@export var osm_way_id: int = 0               # OSM way ID (приоритет)
@export var position: Vector2 = Vector2.ZERO  # Позиция центра (lat, lon)
@export var match_radius: float = 10.0        # Радиус поиска

# Переопределения текстур
@export var wall_texture_path: String = ""
@export var roof_texture_path: String = ""

# Переопределение цвета
@export var color_tint: Color = Color.WHITE   # Оттенок
@export var use_color_tint: bool = false      # Использовать color_tint

# Параметры
@export var height_override: float = -1.0     # -1 = не менять
@export var height_multiplier: float = 1.0

# Дополнительные элементы
@export var custom_sign_text: String = ""
@export var add_entrance: bool = false
```

---

## Интеграция с OSM Terrain Generator

### Инициализация

В `osm_terrain_generator.gd`:

```gdscript
const DecorationLayerScript = preload("res://osm/decoration_layer.gd")
var _decoration_layer: Node = null  # DecorationLayer

func _ready() -> void:
    # ... other init ...

    # Инициализируем Decoration Layer
    _decoration_layer = DecorationLayerScript.new()
    _decoration_layer.set_terrain_generator(self)
    add_child(_decoration_layer)
```

### Building Overrides

При создании здания проверяется наличие override:

```gdscript
func _create_building(nodes, tags, parent, loader, elev_data, way_id: int = 0):
    # Проверяем override
    var building_override = null
    if _decoration_layer and way_id > 0:
        building_override = _decoration_layer.get_building_override_for_way(way_id)

    # Если есть override с цветом - используем прямой рендеринг
    if building_override and building_override.use_color_tint:
        var override_color: Color = building_override.color_tint
        _create_3d_building(points, override_color, building_height, parent, base_elev)
    else:
        # Стандартный батчинг
        _queue_building_for_thread(...)
```

### Billboard Creation

Билборды создаются при финализации чанка:

```gdscript
# В очереди финализации
var _billboard_batches_to_finalize: Array[String] = []

# После загрузки чанка
func _generate_chunk_async(...):
    # ... generation ...

    # Добавляем в очередь билбордов
    if _decoration_layer and not _billboard_batches_to_finalize.has(chunk_key):
        _billboard_batches_to_finalize.append(chunk_key)

# Финализация билбордов
func _finalize_billboard_batch_for_chunk(chunk_key: String):
    var billboards = _decoration_layer.get_billboards_in_chunk(chunk_min, chunk_max)
    for billboard in billboards:
        var mesh = _decoration_layer.create_billboard_mesh(billboard, elevation)
        parent.add_child(mesh)
```

---

## OSM Loader: Way ID

Для работы building overrides нужен OSM way ID. Добавлено в `osm_loader.gd`:

```gdscript
const CACHE_VERSION := 5  # v5: добавлен way id

# При парсинге ways:
var way_data := {
    "id": element.id,  # OSM way ID для decoration layer
    "nodes": way_nodes,
    "tags": element.get("tags", {})
}
```

**Важно**: После изменения версии кэша старые файлы игнорируются и данные загружаются заново с сервера.

---

## Пример использования

### Тестовые декорации

В `decoration_layer.gd`:

```gdscript
func _load_test_decorations() -> void:
    # Билборд "РЕКЛАМА" на координатах
    var billboard = BillboardDecorationScript.new()
    billboard.lat = 59.149878
    billboard.lon = 37.948709
    billboard.text = "РЕКЛАМА"
    billboard.size = Vector2(5.0, 2.5)
    billboard.pole_height = 4.0
    billboard.background_color = Color(0.1, 0.3, 0.7)  # Синий
    billboard.text_color = Color.WHITE
    billboard.has_backlight = true
    _billboards.append(billboard)

    # Красное здание по OSM way ID
    var building_override = BuildingOverrideScript.new()
    building_override.osm_way_id = 45836637  # 39 Северное шоссе
    building_override.color_tint = Color(0.85, 0.2, 0.2)  # Красный
    building_override.use_color_tint = true
    _building_overrides.append(building_override)
```

### Как найти OSM Way ID

1. Открыть https://www.openstreetmap.org
2. Найти нужное здание
3. Кликнуть на него
4. В URL будет `/way/XXXXXXXX` — это way ID

---

## Производительность

| Аспект | Решение |
|--------|---------|
| Building overrides | O(1) lookup по way_id через Dictionary |
| Billboards | Создаются один раз при финализации чанка |
| LOD | visibility_range_end = 300м на MeshInstance3D |
| Shadows | cast_shadow = OFF для билбордов |
| Draw calls | Билборды лёгкие (столб + щит + текст) |

---

## Планы расширения

### Готово
- [x] BillboardDecoration — рекламные щиты
- [x] BuildingOverride — перекраска зданий по way ID

### В планах
- [ ] Surface Decals — лужи, пятна, разметка
- [ ] Road Override — изменение текстуры дорог
- [ ] Zone Override — переопределение по полигону
- [ ] Props — скамейки, урны, киоски
- [ ] Vegetation Override — кастомные деревья/кусты
- [ ] Загрузка из .tres файлов вместо кода

---

## Отладка

### Логи

```
DecorationLayer: Loaded 1 billboards, 1 building overrides
OSM: Created 1 billboards for chunk -1,0
OSM: Building override applied for way 45836637 with color (0.85, 0.2, 0.2, 1)
```

### Проверка кэша

Кэш OSM данных: `~/Library/Application Support/Godot/app_userdata/OSM Racing/osm_cache/`

Проверить наличие way ID в кэше:
```bash
cat osm_v5_*.json | python3 -c "import json,sys; d=json.load(sys.stdin); print([w.get('id') for w in d['ways'][:5]])"
```

### Типичные проблемы

1. **Building override не работает**
   - Проверить версию кэша (должна быть v5+)
   - Удалить старые v4 файлы кэша
   - Проверить что way_id правильный (int, не float)

2. **Билборд не появляется**
   - Проверить координаты (lat/lon)
   - Убедиться что чанк с этими координатами загружен

3. **Type errors при загрузке**
   - Использовать `Script.new()` вместо `ClassName.new()`
   - Избегать типизированных массивов с class_name типами
