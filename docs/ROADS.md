# Road System — Reference

Вся дорожная геометрия строится в `osm/osm_terrain_generator.gd`.

---

## 1. Типы дорог и их параметры

### 1.1 Ширины (ROAD_WIDTHS, `_get_road_width`)

Базовые ширины из таблицы. Если в OSM-тегах есть `lanes=N`, ширина = `N × 3.5 m` (LANE_WIDTH).

| highway= | Ширина (м) | height_offset (м) |
|----------|-----------|-------------------|
| motorway | 16.0 | 0.012 |
| trunk | 14.0 | 0.012 |
| primary | 12.0 | 0.010 |
| secondary | 10.0 | 0.008 |
| tertiary | 8.0 | 0.007 |
| residential / unclassified | 6.0 / 5.0 | 0.006 |
| service | 4.0 | 0.004 |
| cycleway | 2.5 | 0.23 |
| footway | 2.0 | 0.23 |
| track | 3.5 | 0.23 |
| path | 1.5 | 0.23 |
| tram (bed) | 2.2 | 0.003 (ниже всех дорог) |
| tram_rails | 2.2 | 0.050 (рельсы поверх полотна) |

Footway/path/cycleway/track рендерятся на `+0.23 m` над terrain — приподнятый тротуар.

### 1.2 Текстурные ключи

| Тип | texture_key | Описание |
|-----|-------------|----------|
| motorway/trunk oneway N lanes | `owN` | Одностороннее N полос |
| motorway/trunk bidirectional N | `biN` | Двустороннее N полос |
| primary / secondary | `ow2`/`bi4` и т.д. | Зависит от lanes= |
| tertiary, residential, service, link | `residential` | Общая асфальтовая текстура |
| footway/path/cycleway/track | `path` | Sidewalk asphalt |
| intersection (зебра-основа) | `intersection` | Серый асфальт (+0.016 m) |
| crossing (зебра-полосы) | `crossing` | Процедурная зебра (+0.017 m) |
| tram_bed | `tram_bed` | Трамвайное полотно |
| tram_rails | `tram_rails` | Рельсы |

`steps` (highway=steps) — не рендерятся совсем (пропускаются в `_create_road`).

---

## 2. Pipeline генерации дороги

```
OSM way → _create_road()          — добавляет в _road_queue + spatial hash
         → _compute_road_geometry_thread()   — worker thread (Phase 1+2)
              lat/lon → local coords
              Catmull-Rom smooth (ChunkMath.smooth_road_corners)
              _subdivide_for_elevation (разрезает по 10 m grid)
              вычисляет corridor polygons (вырезы из terrain)
              _validate_road_direction (убирает развороты > 105°)
         → Phase 3 (main thread):
              dispatch по типу:
                on_deck → terrain_objects_queue (on_deck_lane_markings / on_deck_footway)
                bridge non-deck → _create_bridge_road
                footway/path → _deferred_footway_queue
                vehicle road → _add_road_to_batch_fast + curb_queue + lamp_queue + manhole_queue + traffic_queue
```

### 2.1 Clipping к chunk boundary

Дороги в OSM приходят с +100 m overlap. При clip_polyline_to_rect к bbox чанка вершины на границе вставляются через Liang–Barsky. Дополнительно `_insert_chunk_boundary_points` добавляет точки где дорожные кромки (±half_w) пересекают границу чанка — чтобы перпендикулярный офсет на краю не уводил вершину за пределы чанка.

---

## 3. Разрезание под terrain grid (subdivision)

Функция `_subdivide_for_elevation(points, grid_step=10.0)`:

- Проходит каждый сегмент полилинии
- Находит все t-значения где сегмент пересекает вертикальные (`X`) и горизонтальные (`Z`) линии сетки с шагом `grid_step`
- Вставляет вершины в эти точки через `lerp`
- Результат: каждый отрезок не пересекает ни одну линию сетки → высоту берёт из bilinear-интерполяции на 10 m grid, нет артефактов "пролёта сквозь горку"

**Кто вызывает:**
- Vehicle roads: в `_compute_road_geometry_thread` с grid=10 m
- Bridge roads (standalone): в `_create_bridge_road` с grid=10 m
- On-deck lane markings: в `_create_on_deck_lane_markings` с grid=5 m
- On-deck footways: в `_create_on_deck_footway` с grid=5 m
- Terrain polygons (natural/landuse): `_split_polygon_by_grid` с grid=10 m

На мосту используется 5 m grid — там нужна точность для следования профилю рампы через `_deck_surface_y_at`.

---

## 4. Вырезание травы/растительности

### 4.1 Spatial hash дорог

При Phase 1 (worker thread) каждый дорожный сегмент записывается в `_road_spatial_hash` и `_chunk_road_hashes` с ячейкой 20 m. Ключ — `Vector2i(cx, cy)`, значение — массив `{p1, p2, width, way_id, bridge}`.

Функции поиска:
- `_is_point_near_road(point, min_dist, ck)` — main thread, использует глобальный hash
- `_is_point_near_road_threadsafe(point, min_dist, road_hash)` — worker thread, использует per-chunk hash

### 4.2 Вырезание для деревьев

В vegetation worker thread (`_generate_trees_thread`):
```
if _is_point_near_road_threadsafe(test_point, 5.0, road_hash): skip
```
Деревья не появляются ближе **5 m** от края дороги (т.е. от середины минус half_width, plus 5 m буфер).

### 4.3 Вырезание для билбордов/кустарников

```
_is_point_near_road_threadsafe(test_point, 4.0, road_hash)  → 4 m буфер
_is_point_near_road_threadsafe(test_point, 3.0, road_hash)  → 3 m (dense areas)
```

### 4.4 Terrain corridors (вырезы из ground mesh)

`_compute_road_geometry_thread` строит `corridors` — полигоны вдоль дороги шириной = ширина + небольшой margin. Terrain ground mesh (`_create_landuse_immediate`, `_create_natural_immediate`) вычитает эти corridors через polygon clipping (Clipper2/Geometry2D). Результат: под дорогой нет зелёного terrain mesh.

**Тротуары (footway/path)** terrain НЕ вырезают — по дизайну трава остаётся под ними. Тротуар выше на 1 cm (terrain = elevation + 0.22 m, footway = elevation + 0.23 m). Выравнивание обоих по одной 5m grid гарантирует 1 cm зазор в каждом треугольнике.

---

## 5. Бордюры (curbs)

Добавляются для всех vehicle roads где `curb_height > 0` (сейчас `curb_height = 0.0` для всех типов — бордюры строятся другим путём).

Фактически бордюры строятся в worker thread (`_compute_road_geometry_thread_curb`) по данным road_queue:
- Ширина бордюра: 0.15 m, высота: 0.22 m
- Left/right inner и outer edges вдоль дороги
- Геометрия батчится в `_curb_geo_batch[chunk_key]`, применяется в `_apply_curb_collisions`
- Бордюры под bridge deck polygon пропускаются (`_any_point_on_bridge_deck`)

---

## 6. Тротуары (footway/path)

### 6.1 Обычный тротуар (вне дороги)

Pipeline через `_deferred_footway_queue`:
1. `_process_footway_incremental` — классифицирует каждую точку: `on_road` (bool) + `in_parking` (bool) через spatial hash. Инкрементально, с budget per frame.
2. Если точка НЕ на дороге — рисуется обычный sidewalk (`_add_path_clipped_to_batch`, texture=`path`, height=+0.23 m).
3. Если точка НА дороге — это пешеходный переход (см. §7).

### 6.2 Тротуар на деке моста (`on_deck_footway`)

Создаётся через `_create_on_deck_footway`. Геометрически: узкая полоска (~footway_width×2) на поверхности деки (`_deck_surface_y_at_cached` + 0.01 m). Добавляется в `_terrain_objects_queue` и ждёт `ref_elev` (см. bridge_debug.md §9).

---

## 7. Пешеходные переходы (zebra/crossing)

Автоматически определяются в `_process_footway_incremental` когда footway пересекает vehicle road.

### Алгоритм определения

1. Для каждого сегмента footway определяется `on_road[i]` — находится ли точка в полосе отвода дороги.
2. На переходе off→on→off: on-road часть = `cross_pts` (два edge point'а, где footway входит и выходит из дороги).
3. `_detect_road_crossing(on_start, on_end)` — находит дорогу в spatial hash, возвращает `{road_width, p1, p2, direction}`.
4. Если `edge_span < 4 m` (короткий on-road сегмент, оба входа с одной стороны): строится по направлению footway через центр.

### Геометрия

Два mesh'а на одних и тех же cross_pts:
- `intersection` (+0.016 m) — серый асфальт (убирает зелёный terrain в зоне перехода)
- `crossing` (+0.017 m) — процедурная текстура зебры (`TextureGeneratorScript.create_crossing_markings(256)`)

Ширина = ширина footway × 2 (visual width).

### Знаки пешеходного перехода

Если `enable_crossing_signs = true`: `_enqueue_crossing_signs(cross_pts, parent, ck)` добавляет инфраструктурные объекты — знаки 5.19.1/5.19.2 на стойках по краям перехода.

---

## 8. Разметка дорог (lane markings)

### 8.1 Vehicle roads — текстурная разметка

Полосы/разделительные линии запечены в текстуры:
- `bi2`, `bi4` — двусторонние 2/4 полосы со сплошной разделительной
- `ow2`, `ow3` — односторонние 2/3 полосы с пунктирными разделителями
- Текстуры 512×512 px, UV вдоль дороги с масштабом по длине

### 8.2 Standalone bridge roads — геометрическая разметка

`_create_bridge_road_lane_markings` — белые полосы поверх bridge road mesh:
- Вычисляет per-vertex heights через `_deck_surface_y_at` вдоль рампы
- Рисует dashed lane dividers (3 m dash / 3 m gap) как тонкие quad-strips (+0.003 m над road mesh)
- Только для дорог с `lanes > 1`

### 8.3 On-deck roads — геометрическая разметка

`_create_on_deck_lane_markings`:
- `_subdivide_for_elevation(pts, 5.0)` — вершины каждые 5 m вдоль деки
- Y через `_deck_surface_y_at_cached + 0.003 m`
- Dashed dividers: 3 m / 3 m, ширина линии 0.15 m
- Добавляется в `_terrain_objects_queue` → ждёт `ref_elev`

---

## 9. NPC навигация по дорогам

В `_deferred_traffic_queue` попадают все vehicle roads (motorway, trunk, primary, secondary, tertiary).

Waypoints строятся в `road_network.gd → _create_directional_waypoints`:
- Height: `get_surface_y(x, z)` — возвращает deck Y если точка внутри bridge polygon, иначе `_sample_elevation`
- Bridge roads в traffic queue реофёрятся до тех пор пока `ref_elev != NAN` для соответствующей деки

Lampочки появляются только на: motorway, trunk, primary, secondary, tertiary. Смещение = half_width + 0.5 m от центра, на дорогах шириной ≥12 m — с двух сторон.

---

## 10. Перекрёстки (intersections)

В Phase 2 (worker thread) `_build_intersection_contour_from_data`:
- Нода используется ≥2 дорогами разного типа → перекрёсток
- Строится контур (PackedVector2Array) покрывающий "пятно" где встречаются дороги
- Контур добавляется в `_intersection_contours` и `_intersection_spatial_hash` (cell=50 m)
- Используется для: подавления фонарей и бордюров на перекрёстке, определения зоны crossing-знаков
