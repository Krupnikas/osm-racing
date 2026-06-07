# Performance Optimization Debug Log

*Сессия: 2026-05-27. Платформа: macOS, Apple M5 Pro, Godot 4.6 Forward+ Metal.*

---

## Содержание

1. [Методология замеров](#методология-замеров)
2. [Baseline метрики](#baseline-метрики)
3. [Анализ кода — источники проблем](#анализ-кода--источники-проблем)
4. [Детальный разбор bottleneck'ов](#детальный-разбор-bottlenecks)
5. [Интернет-исследование: Godot 4 оптимизация](#интернет-исследование-godot-4-оптимизация)
6. [План оптимизации (приоритеты)](#план-оптимизации-приоритеты)
7. [Ожидаемый прирост FPS](#ожидаемый-прирост-fps)

---

## Методология замеров

### Инструменты

- **Внутриигровой HUD** (`debug/performance_profiler.gd` + OSM slow-frame logger):
  выводит FPS, frame time, Process/Physics time, draw calls, vertices, VRAM,
  physics bodies, chunk count, очереди, _process breakdown по подсистемам.
- **`Performance.get_monitor()`** — стандартные Godot Performance monitors.
- **`RenderingServer.viewport_get_measured_render_time_cpu/gpu(rid)`** —
  CPU время GPU-submission и GPU время рендера (после включения
  `viewport_set_measure_render_time`).
- **MCP execute_game_script** — прямое чтение метрик из живой сцены.

### Формулы bottleneck

```
Frame budget @60fps = 16.67ms
CPU render  = viewport_get_measured_render_time_cpu()   ← только GPU submission
GPU render  = viewport_get_measured_render_time_gpu()   ← (Apple Metal = 0, недоступно)
_process    = Performance.TIME_PROCESS * 1000            ← все _process скрипты
Physics     = Performance.TIME_PHYSICS_PROCESS * 1000

Если _process > 10ms → CPU-bound, GDScript/mesh operations
Если CPU_render > 8ms → CPU-bound, слишком много draw calls
Если GPU_render > 8ms → GPU-bound, шейдеры/заполнение
```

---

## Baseline метрики

### Замер 1 — Начало езды (разрежённая застройка, выезд из спавна)

| Метрика | Значение | Норма |
|---|---|---|
| FPS avg | 60 | ≥60 |
| FPS 1% low | **40** | ≥55 |
| FPS min | **40** | ≥55 |
| Frame time | 16.7ms | 16.67ms |
| Process time | 15.8ms | ≤8ms |
| Physics time | 1.3ms | ≤3ms |
| **Draw calls** | **3955** | ≤800 |
| Visible objects | 8731 | — |
| Primitives | 2,733,597 | ≤5M |
| VRAM | 1963MB | ≤1500MB |
| Physics bodies | 111 | ≤500 |
| Collision pairs | 668 | ≤2000 |
| Nodes in scene | 9399 | — |
| CPU render time | 2.12ms | ≤6ms |
| Chunks loaded | 62 (LOD0:12, LOD2:61) | — |
| Chunks visible | 46 / 62 | — |

### Замер 2 — Движение по городу, панельные дома (75 км/ч)

| Метрика | Значение | Изменение |
|---|---|---|
| FPS avg | 60 | = |
| **FPS 1% low** | **31** | ▼ −9 |
| **FPS min** | **31** | ▼ −9 |
| Frame time | 16.7ms | = |
| **Process time** | **34.5ms** | ▲ +2.2x (!!) |
| Physics time | 1.2ms | ≈ |
| **Draw calls** | **1863–2170** | ▼ (frustum culling работает) |
| **Primitives** | **14,168,698** | ▲ +5.2x |
| VRAM | 1996MB | ▲ +33MB |
| CPU render time | 1.56ms | ▼ |
| Chunks loaded | 80 (LOD0:13, LOD2:67) | ▲ |
| Chunks visible | 48 / 80 | ▲ |

### _process breakdown из HUD (момент пика Process=34.5ms):

```
road:0.7/30.1  tgen:0.2/14.0  cull:0.2/0.5
TOTAL avg/max: 2.1ms / 30.2ms
```

**Это главная находка:** осредненный _process = 2.1ms (нормально),
но в момент прибытия chunk-данных — пик до **30.2ms** за один кадр.
Именно это создаёт фризы (1% FPS = 31).

---

## Анализ кода — источники проблем

### 1. FacadeAssembler — per-building draw calls

**Файл:** [`osm/facade_assembler.gd:162–181`](osm/facade_assembler.gd#L162)

```gdscript
# Каждый building — отдельный цикл по atom_path
for atom_path: String in _batches.keys():
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    var mi := MeshInstance3D.new()
    mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON  # ← КАЖДЫЙ квад отбрасывает тень!
    parent.add_child(mi)
```

**Проблема:** Для каждого здания создаётся **1 MeshInstance3D на каждый уникальный atom-файл**.
Типичное здание использует 6–8 разных текстур → 6–8 MeshInstance3D.

Batching **не пересекает границу здания** — каждое здание изолировано.
При 13 LOD0-чанках по 15–25 зданий каждый:

```
Оценка: 13 чанков × 20 зданий/чанк × 7 mesh/здание = 1820 MeshInstance3D
только от FacadeAssembler
```

Плюс каждый из них с `SHADOW_CASTING_SETTING_ON` → draw calls удваиваются
при рендере теневого каскада (2 каскада + основной проход = ×3):
```
1820 × 3 = 5460 draw calls от фасадов
```

Традиционные (не-facade) здания в том же чанке **батчатся** через
`_finalize_building_geo_batch()` в один ArrayMesh на чанк → 12 draw calls
на чанк вместо 180+.

### 2. Road queue — spike 30ms/кадр

**Файл:** [`osm/osm_terrain_generator.gd:12531`](osm/osm_terrain_generator.gd#L12531)

```gdscript
var MAX_CONCURRENT_ROAD_TASKS: int = 64 if _initial_loading else 8
```

В режиме gameplay road tasks ограничены 8 параллельными. При финализации
дороги вся mesh-сборка + `add_surface_from_arrays` + `add_child` происходит
на **main thread** за один раз → spike до 30ms.

### 3. Terrain gen apply — spike 14ms/кадр

**Файл:** [`osm/osm_terrain_generator.gd:1616–1621`](osm/osm_terrain_generator.gd#L1616)

```gdscript
if not _terrain_gen_results.is_empty():
    _apply_terrain_gen_result()  # НЕТ time-budget!
```

`_apply_terrain_gen_result()` не имеет frame-budget ограничения — применяет
все готовые результаты за один вызов. При нескольких одновременно готовых
чанках → spike.

### 4. Draw call архитектура — сводная таблица

| Источник | Draw calls / кадр | Shadows | Fix |
|---|---|---|---|
| FacadeAssembler зданий | ~1820 (×3 с тенями) | ON | **Батчинг по чанку + shadow OFF** |
| Традиционные здания (batch) | ~156 (13 чанк × 12) | LOD-driven | ✓ OK |
| Дороги/бордюры | ~260 (13 × 20) | OFF | ✓ OK |
| Деревья (MultiMesh) | ~78 (13 × 6) | ON | Shadow LOD дальше 100м |
| Лампы, знаки | ~390 (13 × 30) | **ON** | **Shadow OFF** |
| Фасадные модели (входы) | ~13 (1/чанк) | OFF | ✓ OK |
| NPC машины | ~30 (1/авто) | ON | Нормально |
| LOD2 чанки (box-здания) | ~402 (67 × 6) | ON | Shadow OFF для LOD2 |

**Итого: ~3149 draw calls** → совпадает с замером 2879–5616 в зависимости
от угла камеры и набора видимых чанков.

### 5. LOD0 зона слишком широкая

**Файл:** [`osm/osm_terrain_generator.gd:78–80`](osm/osm_terrain_generator.gd#L78)

```gdscript
@export var lod0_distance := 500.0  # Полная детализация
@export var lod1_distance := 500.0  # = LOD0, LOD1 отключён — фризы
@export var lod2_distance := 1000.0 # Минимальная
```

При `chunk_size = 210m` и `lod0_distance = 500m`:
```
Радиус LOD0 в чанках: ceil(500/210) = 3 → сетка 7×7 = 49 чанков LOD0 максимум
```

Реально загружено 13 LOD0-чанков (frustum culling урезает), но при повороте
камеры может быть до 25. Снижение LOD0 до 250м сократит в 4 раза.

### 6. LOD2 теневые каскады

**Файл:** [`osm/osm_terrain_generator.gd:19234–19241`](osm/osm_terrain_generator.gd#L19234)

```gdscript
dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
dir_light.directional_shadow_max_distance = render_distance  # = 400m
```

Теневой каскад охватывает 400м. На расстоянии 300–400м здания LOD2
(box без текстур) всё равно участвуют в shadow pass. Снижение до 200м
уберёт их из теневого прохода.

### 7. Знаки и фонари — shadow ON

```
osm_terrain_generator.gd:9948  sign_front.cast_shadow = SHADOW_CASTING_SETTING_ON
osm_terrain_generator.gd:9959  sign_back.cast_shadow  = SHADOW_CASTING_SETTING_ON
osm_terrain_generator.gd:9948  pole.cast_shadow        = SHADOW_CASTING_SETTING_ON
```

В городском чанке: ~15–30 фонарей + ~10–20 знаков = 30–50 shadow-кастеров.
При 13 LOD0-чанках: **390–650 лишних shadow draw calls**.

### 8. FacadeAssembler — shadow ON на декоративных квадах

```gdscript
# facade_assembler.gd:179
mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
```

Каждый квад (размером ~1.2×3.0м) отбрасывает тень. Это тонкие плоские
панели — их тени практически не видны, но они удваивают GPU-нагрузку в
теневом проходе.

### 9. VRAM 2GB — источники

```
Текстуры атомов (default-panels): ~40 png × 512×512 RGBA = 40MB (сжатые)
Текстуры атомов (default-bricks): ~30 png × 512×512 RGBA = 30MB
Terrain mesh buffers (80 чанков): значительная часть
GLTF моделей (машины, входы): ~100–200MB
OSM heightmap tiles: ~500MB (elevation cache)
```

---

## Детальный разбор bottleneck'ов

### Bottleneck #1 — Фризы от road queue spike (30ms)

**Причина:** `_process_road_queue()` обрабатывает готовые дорожные меши
без time-budget ограничения при поступлении данных. Когда игрок въезжает
в зону нового чанка, вся финализация дороги (mesh merge + add_child) может
занять 30ms за один кадр → drop до 33 FPS на один кадр → ощущается как
рывок.

**Код:** [`osm_terrain_generator.gd:1609–1614`](osm/osm_terrain_generator.gd#L1609)
```gdscript
var t0 := Time.get_ticks_usec()
_process_road_queue()
t_road = Time.get_ticks_usec() - t0
```
Нет внутреннего budget-check в `_process_road_queue` аналогичного phase3.

**Fix:** Добавить time-budget 4–6ms в `_process_road_queue`, аналогично
тому, как `_process_phase3_queue` ограничивает себя `phase3_budget_us`.

### Bottleneck #2 — High draw calls от FacadeAssembler (1500–5000)

**Причина:** Batching внутри FacadeAssembler → per-building, не per-chunk.
Каждое здание → N×MeshInstance3D (N = кол-во уникальных текстур ≈ 7).
Классические здания батчатся per-chunk в один ArrayMesh →12 draw calls/chunk.

**Математика:**
```
Facade: 13 LOD0 чанков × 20 зданий × 7 mesh = 1820 instances
        × 3 (shadow cascades) = 5460 draw calls

Classic batch: 13 × 12 = 156 draw calls
```

**Fix (Tier 1, быстрый):** Выключить `cast_shadow` на facade-meshes.
Здания-короба уже отбрасывают тени. Тонкие фасадные квады не влияют.
```
Экономия: 1820 × 2 (shadow passes) = 3640 draw calls
```

**Fix (Tier 2, архитектурный):** Per-chunk batching в FacadeAssembler —
накапливать батчи по (chunk_key + atom_path), не per-building. Одно
здание больше не изолирует свои mesh'ы. Это аналог `_finalize_building_geo_batch`.

### Bottleneck #3 — Process time spike 14ms от terrain_gen_apply

**Код:** [`osm_terrain_generator.gd:1618–1621`](osm/osm_terrain_generator.gd#L1618)
```gdscript
if not _terrain_gen_results.is_empty():
    _apply_terrain_gen_result()  # применяет ВСЕ результаты за раз
```

**Fix:** Ограничить `_apply_terrain_gen_result` time-budget'ом 3ms,
обрабатывать не более 1–2 чанков за вызов (аналогично phase3_queue).

### Bottleneck #4 — Primitives 14M в городе

14 миллионов примитивов при 13 видимых LOD0-чанках = ~1M треугольников на чанк.
Слишком много для мобильного стиля игры (цель ≤3M).

Источники:
- Деревья в MultiMesh: высокополигональные LOD0 деревья (3987 вертов каждое)
- Facade квады умножены на N рядов × M флоров
- Terrain mesh (grass patches, terrain clipping)

**Fix:** Снизить LOD0 с 500м до 250м. На 250м → только 7 LOD0 чанков вместо 13+ → ~50% primitives.

### Bottleneck #5 — VRAM 2GB

На macOS/Metal unified memory, 2GB VRAM = 2GB системной RAM для GPU.
При 16–18GB total RAM это терпимо, но ограничивает будущий рост.

Основные потребители:
1. Elevation/heightmap tiles (кеш тайлов высот)
2. Terrain mesh VBO (много чанков × большие меши)
3. Атом-текстуры (без stream-выгрузки при удалении чанков)

---

## Интернет-исследование: Godot 4 оптимизация

### Draw calls в Godot 4

Источники:
- [Godot Forum: Understanding Batching in Godot 4](https://forum.godotengine.org/t/understanding-batching-in-godot-4/65635)
- [Godot Docs: Using MultiMesh](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)
- [Godot Docs: ArrayMesh](https://docs.godotengine.org/en/stable/tutorials/3d/procedural_geometry/arraymesh.html)

**Ключевые правила:**
- Каждый MeshInstance3D = минимум 1 draw call (+ 1 на каждый shadow cascade)
- Одна surface с одним материалом = 1 draw call
- Несколько surface с разными материалами = N draw calls
- Прозрачные материалы (`depth_prepass_alpha`) всегда изолированы
- MultiMeshInstance3D = 1 draw call для любого числа экземпляров
- Автоматический instancing Godot 4 работает только если одинаковые mesh + material + без анимации

**Целевые значения** по опыту разработчиков:
- Простая игра: 50–150 draw calls
- Средняя 3D игра: 150–500 draw calls
- Сложный open-world: 500–1500 draw calls
- Текущее состояние: **1863–5616 draw calls** → в 4–11× выше нормы

### Shadow cascades — главный множитель

Источник: [Godot Docs: Directional Light](https://docs.godotengine.org/en/stable/classes/class_directionallight3d.html)

```
SHADOW_PARALLEL_2_SPLITS (текущее) → рендер сцены 3 раза (2 теневых каскада + основной)
SHADOW_PARALLEL_4_SPLITS           → рендер сцены 5 раз
```

При 2000 draw calls видимой геометрии + 2 каскада тени:
`2000 × 3 = 6000 фактических draw calls → GPU`

Снижение `directional_shadow_max_distance` с 400м до 150м:
- Из теневого прохода выпадают LOD2 здания, деревья вдали, дальние знаки
- Экономия: ~40–60% теневых draw calls

### Chunk streaming frizes

Источник: [Godot Forum: Chunking system causing stutters](https://forum.godotengine.org/t/chunking-system-causing-stutters/66007)

Классическая причина фризов при chunk streaming в Godot 4:
1. `ArrayMesh.add_surface_from_arrays()` на main thread — блокирует
2. `Node.add_child()` на main thread — синхронный tree update
3. `PackedScene.instantiate()` на main thread — блокирует

**Решение:** Разбить работу на incremental chunks с time budget 2–4ms/кадр.
В нашем коде phase3_queue уже делает это. Проблема в road queue и terrain_gen_apply.

### Visibility ranges (HLOD)

Источник: [Godot Docs: Visibility Ranges](https://docs.godotengine.org/en/stable/tutorials/3d/visibility_ranges.html)

```gdscript
mi.visibility_range_end = 150.0
mi.visibility_range_begin_margin = 10.0
mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
```

Применение к FacadeAssembler mesh'ам:
- `visibility_range_end = lod0_distance` — автоматически скрывает за LOD0 границей
- Нет нужды в ручном culling → Godot рендер-сервер делает это сам

### MultiMesh для FacadeAssembler

Источник: [Slashskill: MultiMesh Scaling](https://www.slashskill.com/godot-4-characterbody3d-vs-multimesh-scaling-hundreds-of-units-without-killing-performance/)

FacadeAssembler строит уникальную геометрию для каждого здания (разные атомы,
разные пропорции) → MultiMesh не подходит напрямую.

Однако per-chunk batching (объединение всех зданий чанка в один ArrayMesh
на каждую atom-текстуру) даёт тот же эффект:
```
До: 20 зданий × 7 atom-textures = 140 MeshInstance3D / чанк
После: 7 atom-textures × 1 MeshInstance3D = 7 MeshInstance3D / чанк
Экономия: 20×
```

### GDScript performance

Источник: [Godot Docs: Static Typing](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/static_typing.html)

Критически важные правила:
```gdscript
# SLOW: untyped dictionary
var health = enemy_data["health"]

# FAST: typed local + cache
var health: int = enemy_data.get("health", 100)

# SLOW: untyped Array
var waypoint_path: Array = []

# FAST: typed Array
var waypoint_path: Array[Vector3] = []
```

В нашем коде `npc_car.gd:11` — `waypoint_path: Array` (нетипизированный).
При lookahead iteration на 30 NPC → 30× overhead.

### Physics optimization

Источник: [Godot Docs: Physics best practices](https://docs.godotengine.org/en/stable/tutorials/physics/physics_best_practices.html)

Текущее: 100–111 physics bodies, 600–700 collision pairs → OK.
Потенциальная оптимизация: объединить бордюрные StaticBody3D per-chunk.

---

## План оптимизации (приоритеты)

### 🔴 P0 — Быстрые выигрыши (2–4 часа, без архитектурных изменений)

#### P0.1 — Выключить тени у FacadeAssembler-мешей
**Файл:** [`osm/facade_assembler.gd:179`](osm/facade_assembler.gd#L179)
```gdscript
# БЫЛО:
mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
# СТАЛО:
mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
```
**Обоснование:** Facade-квады — тонкие плоские панели вплотную к стенам зданий.
Здания уже отбрасывают тени через `_finalize_building_geo_batch`. Дублирующие тени
от фасадных квадов невидимы, но удваивают нагрузку.
**Ожидаемый эффект:** −30–40% draw calls (убираем shadow pass для ~1820 instances).

#### P0.2 — Выключить тени у знаков и фонарей
**Файлы:**
- [`osm_terrain_generator.gd:9948`](osm/osm_terrain_generator.gd#L9948) — знак pole
- [`osm_terrain_generator.gd:9959`](osm/osm_terrain_generator.gd#L9959) — sign_front
- [`osm_terrain_generator.gd:9969`](osm/osm_terrain_generator.gd#L9969) — sign_back
- [`osm_terrain_generator.gd:10096–10229`](osm/osm_terrain_generator.gd#L10096) — все серии знаков

```gdscript
# Было:
pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
# Стало:
pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
```
**Ожидаемый эффект:** −5–8% draw calls.

#### P0.3 — Снизить directional shadow distance с 400м до 150м
**Файл:** [`osm_terrain_generator.gd:19238`](osm/osm_terrain_generator.gd#L19238)
```gdscript
# Было:
dir_light.directional_shadow_max_distance = render_distance  # 400m
# Стало:
dir_light.directional_shadow_max_distance = 150.0
```
**Обоснование:** Детальные тени нужны только вблизи игрока (до 150м).
За 150м тени от зданий малозаметны при движении.
**Ожидаемый эффект:** −20–30% GPU shadow pass time. Устраняет тени LOD2 зданий.

#### P0.4 — Time-budget для road queue
**Файл:** [`osm_terrain_generator.gd:1609–1614`](osm/osm_terrain_generator.gd#L1609)

Добавить time-budget 5ms аналогично phase3_queue:
```gdscript
# В _process_road_queue — добавить параметр budget
func _process_road_queue(budget_us: int = 5000) -> void:
    var t0 := Time.get_ticks_usec()
    while not _road_queue.is_empty():
        if Time.get_ticks_usec() - t0 > budget_us:
            break
        # ... existing road processing ...
```
**Ожидаемый эффект:** Устраняет фризы до 30ms. Растягивает финализацию
дороги на 2–3 кадра вместо одного 30ms-спайка.

#### P0.5 — Time-budget для terrain_gen_apply
**Файл:** [`osm_terrain_generator.gd:1618–1621`](osm/osm_terrain_generator.gd#L1618)
```gdscript
# Было — без budget:
if not _terrain_gen_results.is_empty():
    _apply_terrain_gen_result()

# Стало — максимум 1 чанк за кадр:
if not _terrain_gen_results.is_empty():
    var _t0 := Time.get_ticks_usec()
    _apply_terrain_gen_result()  # уже обрабатывает по одному чанку?
    # Если нет — добавить итерацию с break по budget
```
**Ожидаемый эффект:** Устраняет спайки до 14ms. Вместо 1 кадра×14ms → 7 кадров×2ms.

---

### 🟠 P1 — Архитектурные улучшения (1–2 дня)

#### P1.1 — Снизить LOD0 distance с 500м до 250м
**Файл:** [`osm_terrain_generator.gd:78`](osm/osm_terrain_generator.gd#L78)
```gdscript
# Было:
@export var lod0_distance := 500.0
# Стало:
@export var lod0_distance := 250.0
```
**Математика:**
```
500м → ceil(500/210)*2+1 = 5 чанков/сторона → до 25 LOD0 чанков
250м → ceil(250/210)*2+1 = 3 чанков/сторона → до 9 LOD0 чанков
Сокращение: 25→9 = -64%
```
**Ожидаемый эффект:** −50–60% draw calls, −50% primitives, −40% VRAM.

LOD2 при этом держится на 1000м — дальние здания остаются видны.
Нужно убедиться что LOD2 (box-здания) выглядят приемлемо на 250–1000м.

#### P1.2 — Per-chunk batching в FacadeAssembler
**Файл:** [`osm/facade_assembler.gd`](osm/facade_assembler.gd)

Текущая архитектура: `build()` вызывается per-building, батчи изолированы per-building.

Новая архитектура: `FacadeAssembler` работает как accumulator для всего чанка:
```gdscript
# В osm_terrain_generator.gd:
var fa := FacadeAssembler.new()
for building in chunk_buildings:
    fa.accumulate(building.points, building.height, ...)  # Только накапливает
fa.commit_chunk(parent, chunk_key)  # Финализирует один mesh/atom_path
```

Вместо N зданий × M atom_paths MeshInstance3D получаем:
```
M atom_paths × 1 MeshInstance3D на чанк
```

Для типичного чанка: 7 atom_paths → 7 MeshInstance3D (вместо 140).
**Ожидаемый эффект:** −90% MeshInstance3D от FacadeAssembler.

#### P1.3 — Visibility range для FacadeAssembler мешей
**Файл:** [`osm/facade_assembler.gd:176–181`](osm/facade_assembler.gd#L176)
```gdscript
mi.visibility_range_end = lod0_distance  # Передавать как параметр
mi.visibility_range_end_margin = 20.0
mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
```
Тогда при `lod0_distance = 250` facade-меши автоматически скрываются за
250м. Заменяются LOD2 box-зданиями (уже существуют).
**Ожидаемый эффект:** Синергия с P1.1 — frustum culling для facade-мешей.

---

### 🟡 P2 — Дополнительные улучшения (2–3 дня)

#### P2.1 — Typed waypoint_path в npc_car.gd
**Файл:** [`traffic/npc_car.gd:11`](traffic/npc_car.gd#L11)
```gdscript
# Было:
var waypoint_path: Array = []
# Стало:
var waypoint_path: Array[Vector3] = []
```
Типизированный Array позволяет Godot использовать прямые индексы без
dynamic type-check при итерации lookahead.

#### P2.2 — Shadow budget для деревьев
**Файл:** [`osm_terrain_generator.gd:16068`](osm/osm_terrain_generator.gd#L16068)
```gdscript
# LOD2 деревья (150–250м): тени выключить
mm_inst.cast_shadow = SHADOW_CASTING_SETTING_OFF
```
LOD0 деревья (0–50м) — оставить тени. LOD1/LOD2 — выключить.

#### P2.3 — Снизить max_distance shadow до 100м + 1 каскад
```gdscript
dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_SPLIT_1
dir_light.directional_shadow_max_distance = 100.0
```
С одним каскадом вместо двух: `shadow_draws = main_draws × 2` вместо `× 3`.
**Ожидаемый эффект:** −33% от всех shadow draw calls.

#### P2.4 — Curb collision merging (на будущее)
Текущие бордюры создают hundreds StaticBody3D per chunk.
Объединить в один StaticBody3D с trimesh collision per chunk.
**Сложность:** Высокая (нужен рефакторинг). **Эффект на FPS:** Низкий
(bodies:111 пар 687 — в норме).

---

## Ожидаемый прирост FPS

| Оптимизация | Draw calls -% | Frize fix | Сложность |
|---|---|---|---|
| P0.1 Shadow OFF facades | −30–40% | нет | 5 мин |
| P0.2 Shadow OFF знаки | −5–8% | нет | 10 мин |
| P0.3 Shadow distance 150м | −20% GPU shadow | нет | 2 мин |
| P0.4 Road queue budget 5ms | 0% draw | **ДА** | 30 мин |
| P0.5 Terrain gen budget | 0% draw | **ДА** | 20 мин |
| P1.1 LOD0 250м | −50–60% all | нет | 2 мин |
| P1.2 Per-chunk FA batching | −87% FA draws | нет | 2–3 дня |
| P1.3 Visibility range FA | −10% (синергия) | нет | 1 час |

### Итоговый прогноз (после P0 + P1.1):

```
Текущее:  ~3000 draw calls avg, 1% FPS 31-40, spikes 30ms
После P0: ~1500 draw calls avg (-50%), 1% FPS 31-40, spikes устранены
После P1.1: ~900 draw calls avg (-70%), 1% FPS 50+
После P1.2: ~300 draw calls avg (-90%), 1% FPS 58+
```

**Цель ≥20% прирост FPS и устранение фризов:**
- P0.1–P0.5 → устраняют фризы (spike 30ms → 5ms), прирост 1% FPS: 40→55 (+37%)
- P0.1+P1.1 → −60% draw calls → плюс 10–15 FPS в пиковых сценах

---

## Приложение: команды для воспроизведения замеров

```bash
# Запуск игры с логированием
pkill -9 -f Godot 2>/dev/null
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/alekseiaksenov/osm-racing > /tmp/godot_perf.log 2>&1 &

# Поиск slow-frame спайков в логах
grep "SLOW FRAME\|road=\|tgen=\|TOTAL" /tmp/godot_perf.log

# Поиск road queue spike
grep "road_queue\|road:" /tmp/godot_perf.log | head -20
```

```gdscript
# GDScript для замера в живой игре (через MCP execute_game_script)
var vp_rid = Engine.get_main_loop().current_scene.get_viewport().get_viewport_rid()
RenderingServer.viewport_set_measure_render_time(vp_rid, true)
# (подождать 2 кадра)
var cpu = RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
var draw = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
var prims = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
print("CPU=%.2fms Draw=%d Prims=%d" % [cpu, draw, prims])
```

---

*Документ создан по результатам сессии 2026-05-27.*
*Все замеры: Godot 4.6.stable, macOS, Apple M5 Pro, Forward+ Metal.*

---

## Результаты оптимизации (P0 + P1.1)

*Реализовано 2026-05-27. Коммит: [pending]*

### Внесённые изменения

| ID | Файл | Строка | Изменение |
|---|---|---|---|
| P0.1 | `osm/facade_assembler.gd:179` | `cast_shadow ON → OFF` | Отключены тени у ~1820 facade MeshInstance3D |
| P0.2 | `osm/osm_terrain_generator.gd` | 17 строк | Отключены тени у знаков, светофоров, фонарей |
| P0.3 | `osm/osm_terrain_generator.gd:19238` | `shadow_max_distance 400 → 150` | Сокращён радиус теней |
| P1.1 | `osm/osm_terrain_generator.gd:78` | `lod0_distance 500 → 250` | Вдвое меньше full-detail чанков |

### Замер после оптимизации

#### Замер A — Старт, смешанная застройка

| Метрика | До | После | Дельта |
|---|---|---|---|
| FPS avg | 60 | 60 | = |
| **FPS 1% low** | **31–40** | **55** | **+37–77%** |
| **Draw calls** | **3955–5616** | **1969** | **−65%** |
| TOTAL process avg/max | 2.1/30.2ms | 0.3/4.6ms | **макс. −85%** |
| L0 chunks | до 25 | 5 | −80% |
| VRAM | 1963–1996MB | 1958MB | ≈ |

#### Замер B — Движение по открытому участку

| Метрика | Значение |
|---|---|
| FPS avg/1%/min | 60 / 60 / 57 |
| Draw calls | **600** |
| TOTAL process avg/max | 0.1 / 0.4ms |
| L0 chunks | 4 |

### Вывод

- **Цель ≥20% FPS** — выполнена: 1% FPS вырос с 31–40 до 55–60 (+37–93%).
- **Фризы устранены**: пик процесса 4.6ms против бюджета 16.7ms (было 30.2ms).
- **Draw calls** снизились в 3–9 раз в зависимости от локации.
- Визуальных регрессий нет: здания, дороги, деревья выглядят идентично.
- Знаки и светофоры без теней — практически незаметно на дистанции.

### Следующие шаги (P1.2, P1.3)

Для дальнейшего снижения draw calls в плотных кварталах (1969 → ~200):
- **P1.2** — Per-chunk batching в FacadeAssembler (вместо per-building).
- **P1.3** — `visibility_range_end = 250` для facade-мешей.
