# Отладка бордюров на тротуарах - журнал попыток

## Цель
Добавить невысокие бордюры (3см высотой, 7см шириной) по обоим краям тротуаров (footway/path). Бордюры должны идти **внутрь** тротуара (не расширяя его), и обрезаться на перекрёстках тротуаров.

## Архитектура
- Существующая curb система в `osm_terrain_generator.gd` отключена (`curb_height = 0.0`)
- Бордюры позиционируются **снаружи** дороги: `road_width/2 + curb_width`
- Для тротуаров нужно **внутрь**: `road_width/2 - curb_width`
- Обрезка на перекрёстках дорог работает через `_is_point_in_intersection_shape()`
- Нужна новая логика для обрезки на перекрёстках тротуаров

---

## Попытка 1: Базовая реализация с `curb_inward`

### Что сделано
1. **Включён `curb_height = 0.03`** для footway/path (строки 3043-3046)
2. **Добавлен параметр `curb_inward: true`** в curb_queue для off-road сегментов:
   - Immediate path: строки 3088, 3107
   - Worker thread: строка 3412
   - `_process_footway_incremental`: строки 4171, 4190
3. **Пробросили `curb_inward`** через pipeline в `_process_curb_queue` (строка 7467)
4. **Изменили `_init_curb_mesh_state`** (строка 7509):
   - `curb_width = 0.07` для inward (vs 0.15 для дорог)
   - Сохранили `curb_inward` в state dict
5. **Изменили позиционирование** в `_process_curb_segments` (строки 7621-7628):
   - Inward: `left_inner = p + perp * (road_width/2 - curb_width)`
   - Inward: `left_outer = p + perp * (road_width/2)`
6. **Убрали underground drop** для inward curbs:
   - `left_bottom_y = left_road_y` (вместо `left_curb_y - 1.0`)
7. **Изменили collision positioning** в `_compute_curb_collisions_thread`:
   - Inward: `left_center = mid + perp * (road_width/2 - curb_width/2)`
   - Пробросили `curb_inward` в collision_task (строки 7812-7822)

### Результат
- **Успех:** Бордюры появились на тротуарах, 3см высотой, идут внутрь
- **Проблема:** На перекрёстках тротуаров бордюры НЕ обрезаются (видны сквозь тротуары)

---

## Попытка 2: Junction detection через `_road_spatial_hash`

### Идея
Использовать существующий `_road_spatial_hash` (содержит все дороги, включая тротуары) для детекции перекрёстков тротуаров.

### Реализация
Добавлена функция `_is_point_at_sidewalk_junction(point: Vector2, seg_dir: Vector2) -> bool`:
- Ищет в `_road_spatial_hash` сегменты с `width < 4.0` (тротуары 1.5-2.5м, дороги ≥ 4м)
- Проверяет: точка внутри другого тротуара **И** угол > 30° (`dot < 0.85`)
- Угловой фильтр исключает self-match (параллельные сегменты того же тротуара)

### Код (после строки 13554)
```gdscript
func _is_point_at_sidewalk_junction(point: Vector2, seg_dir: Vector2) -> bool:
    var cell_x := int(floor(point.x / ROAD_CELL_SIZE))
    var cell_y := int(floor(point.y / ROAD_CELL_SIZE))
    for dx in range(-1, 2):
        for dy in range(-1, 2):
            var key := Vector2i(cell_x + dx, cell_y + dy)
            if not _road_spatial_hash.has(key):
                continue
            for seg in _road_spatial_hash[key]:
                if seg.width >= 4.0:
                    continue
                var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, seg.p1, seg.p2)
                if point.distance_to(closest) >= seg.width / 2.0:
                    continue
                var other_dir: Vector2 = (seg.p2 - seg.p1).normalized()
                if abs(seg_dir.dot(other_dir)) < 0.85:
                    return true
    return false
```

Вызов в `_init_curb_mesh_state` (строка 7540):
```gdscript
if curb_inward and _is_point_at_sidewalk_junction(mid, seg_dir):
    skipped_count += 1
    continue
```

### Результат
- **Провал:** GDScript ошибка парсинга `var other_dir := (seg.p2 - seg.p1).normalized()`
- **Причина:** GDScript не выводит тип из Dictionary-доступа (`:=` требует явный тип)

---

## Попытка 3: Явная типизация

### Фикс
Изменили все Dictionary-доступы на явную типизацию:
```gdscript
var sp1: Vector2 = seg.p1
var sp2: Vector2 = seg.p2
var sw: float = seg.width
if sw >= 4.0:
    continue
var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, sp1, sp2)
if point.distance_to(closest) >= sw / 2.0:
    continue
var other_dir: Vector2 = (sp2 - sp1).normalized()
if abs(seg_dir.dot(other_dir)) < 0.85:
    return true
```

### Результат
- **Успех:** Игра запускается без ошибок
- **Проблема:** На перекрёстках тротуаров **всё ещё есть бордюры**

---

## Попытка 4: Проверка spatial hash

### Диагностика
Бордюры не обрезаются → junction detection не срабатывает → возможно, тротуары не добавляются в `_road_spatial_hash`.

### Проверка кода
- `_road_spatial_hash` заполняется в `_add_road_to_batch_fast` (строка ~6900)
- Footway/path вызывают `_add_road_to_batch_fast(..., "path", 0.23, ...)` → добавляются в hash
- **Вывод:** Тротуары ДОЛЖНЫ быть в spatial hash

### Результат
- **Причина найдена:** Junction detection проверяет только **центр сегмента** (`mid`), а для длинных сегментов середина может быть далеко от перекрёстка

---

## Попытка 5: Segment-to-segment проверка

### Идея
Проверять не одну точку, а весь curb-сегмент (от `p0` до `p1`) на пересечение с другими тротуарами.

### Изменение
Вызов в `_init_curb_mesh_state`:
```gdscript
if curb_inward and _is_sidewalk_segment_at_junction(item.local_points[i], item.local_points[i+1]):
    skipped_count += 1
    continue
```

Функция `_is_sidewalk_segment_at_junction(p0: Vector2, p1: Vector2) -> bool`:
- Перебирает spatial hash ячейки вокруг p0 и p1
- Для каждого тротуарного сегмента:
  1. Проверяет угол (> 30°) → если параллельны, skip
  2. Проверяет пересечение сегментов через `Geometry2D.segment_intersects_segment()`

### Результат
- **Провал:** Бордюры **пропали почти везде** (массово удаляются)
- **Причина:** Функция матчит сегменты того же тротуара (на поворотах угол > 30° → ложное срабатывание)

---

## Попытка 6: Exclusion через координаты

### Идея
Исключать self-match проверкой координат: если `seg.p1 == p0 or seg.p2 == p1` → skip (тот же сегмент).

### Код
```gdscript
if sp1.is_equal_approx(p0) or sp2.is_equal_approx(p1):
    continue  # Same segment
```

### Результат
- **Провал:** Не изменилось, бордюры всё равно пропадают
- **Причина:** Проверка недостаточна — нужно исключать **весь тротуар**, а не один сегмент

---

## Попытка 7: Centerline intersection only

### Идея
Убрать edge expansion, проверять только пересечение центральных линий тротуаров.

### Код
```gdscript
# Удалили edge expansion (perpendicular offset)
# Только Geometry2D.segment_intersects_segment(p0, p1, sp1, sp2)
```

### Результат
- **Провал:** Бордюры всё ещё пропадают массово
- **Гипотеза:** Проблема не в junction detection, а раньше — в `_is_point_in_intersection_shape()`

---

## Попытка 8: Временное отключение junction detection

### Идея
Полностью отключить `_is_sidewalk_segment_at_junction` и проверить, останутся ли бордюры.

### Код
```gdscript
# Закомментировали вызов в _init_curb_mesh_state:
# if curb_inward and _is_sidewalk_segment_at_junction(...):
#     skipped_count += 1
#     continue
```

### Результат
- **Провал:** Бордюры вернулись везде, включая перекрёстки тротуаров
- **Вывод:** Junction detection нужен, но предыдущие версии были слишком агрессивными

---

## Попытка 9: Way ID Self-Exclusion - ФИНАЛЬНОЕ РЕШЕНИЕ

### Идея
Использовать `way_id` из OSM данных для надёжного исключения сегментов того же тротуара. Вместо эвристик (угол, расстояние, координаты), проверяем: `seg.way_id == current_way_id` → skip.

### Реализация
1. **Добавили way_id в pipeline:**
   - `_deferred_footway_queue.append({..., "way_id": result.get("way_id", 0)})`
   - `_process_footway_incremental`: `var way_id: int = item.get("way_id", 0)`
   - `_curb_queue.append({..., "way_id": way_id})`

2. **Добавили way_id в spatial hash:**
   - `_create_road`: `var seg := {..., "way_id": way_id}` (строка 2987)
   - Worker thread: `var w_id: int = int(way.get("id", 0))`, затем `var rseg := {..., "way_id": w_id}` (строка 2411)

3. **Изменили `_is_segment_at_sidewalk_junction`:**
   - Добавили параметр `current_way_id: int`
   - В начале loop:
     ```gdscript
     var seg_way_id: int = seg.get("way_id", 0)
     if seg_way_id > 0 and seg_way_id == current_way_id:
         continue  # Same sidewalk - skip
     ```

4. **Обновили вызов:**
   - `_init_curb_mesh_state`: `var way_id: int = item.get("way_id", 0)`
   - Вызов: `_is_segment_at_sidewalk_junction(p1, p2, dir, way_id)`

### Результат
- **Провал:** `current_way=0` во всех случаях - way_id не передавался через `_curb_smoothed_queue`
- **Причина:** Забыли добавить `"way_id": item.get("way_id", 0)` в строке 7481

---

## Попытка 10: Исправление way_id pipeline

### Проблема
Way_id передавался в curb_queue, но терялся при переходе в `_curb_smoothed_queue`.

### Исправление
Добавлена строка 7481: `"way_id": item.get("way_id", 0)` в `_process_curb_queue`.

### Результат
- **Частичный успех:** way_id теперь правильные (не 0), self-exclusion работает
- **Провал:** Бордюры всё ещё на перекрёстках - junction detection срабатывает слишком редко

---

## Попытка 11: Проверка трёх точек вместо мидпоинта

### Идея
Мидпоинт-проверка пропускала перекрёстки где концы сегмента внутри другого тротуара. Проверяем p1, p2, mid.

### Изменения
```gdscript
var mid := (p1 + p2) * 0.5
if _is_point_at_sidewalk_junction(p1, way_id) or \
   _is_point_at_sidewalk_junction(p2, way_id) or \
   _is_point_at_sidewalk_junction(mid, way_id):
    continue
```

Порог увеличен с `width * 0.25` до `width * 0.5`.

### Результат
- **Провал:** Дырки на углах, отсутствие бордюров с другой стороны T-перекрёстка
- **Причина:** Слишком широкий порог, обрезает близкие параллельные участки

---

## Попытка 12: Добавление углового фильтра

### Идея
Обрезать только если угол между тротуарами > 30° (не параллельны).

### Изменения
```gdscript
var other_dir: Vector2 = (sp2 - sp1).normalized()
if abs(seg_dir.dot(other_dir)) >= 0.85:  # < 30° → skip
    continue
```

### Результат
- **Провал:** 0 junction detections - угловой фильтр слишком строгий

---

## Попытка 13: Удаление углового фильтра

### Изменения
Полностью убран угловой фильтр. Проверка только:
1. way_id != current_way_id (self-exclusion)
2. width < 4.0 (только тротуары)
3. distance < width * 0.5 (точка внутри коридора)

### Результат
- **Провал:** Junction detection активен (обрезает 1-9 сегментов на тротуар), но визуально бордюры всё ещё на перекрёстках
- **Статистика:** way 694466366: 95 сегментов, 9 обрезано; way 694466406: 102 сегмента, 7 обрезано
- **Вывод:** Либо обрезаются не те сегменты, либо обрезается слишком мало

---

## Попытка 14: Уменьшение порога до 30см

### Проблема
T-образный перекрёсток: бордюры на перекрёстке, дырки на углах, с другой стороны Т нет тротуара.

### Изменения
Порог уменьшен с `width * 0.5` (≈1м) до **фиксированных 0.3м (30см)**:
```gdscript
if point.distance_to(closest) < 0.3:  // Fixed threshold
```

### Результат
- **Провал:** Визуально ничего не изменилось
- **Вывод:** Проблема не в пороге расстояния

---

## Гипотезы о корневой причине

1. **Обрезаются не те сегменты** - junction detection срабатывает, но не на перекрёстке
2. **Сегменты слишком длинные** - один curb сегмент может покрывать большую часть тротуара
3. **Координаты не совпадают** - points в curb могут отличаться от spatial hash points
4. **Топология OSM** - тротуары могут не пересекаться геометрически в данных

---

## Выводы на данный момент

### Что работает
1. ✅ Бордюры генерируются с правильной геометрией (3см × 7см, внутрь)
2. ✅ Позиционирование inward работает корректно
3. ✅ Коллизии работают

### Проблемы
1. ❌ Junction detection не работает надёжно:
   - Point-based проверка пропускает длинные сегменты
   - Segment-based проверка матчит сам тротуар (ложные срабатывания)
   - Self-exclusion по координатам недостаточен
2. ❌ Возможна интерференция с `_is_point_in_intersection_shape()`

### Следующие шаги
1. Понять, почему бордюры массово пропадают (диагностика с логами)
2. Разработать надёжный алгоритм self-exclusion для тротуаров

---

## Попытка 16: Отключить `_is_point_in_intersection_shape` для тротуаров

### Проблема
Попытки 9-15 пытались обрезать бордюры на **перекрёстках тротуаров** (sidewalk junctions). Но пользователь показал фото из реальной жизни: на перекрёстках тротуаров бордюр **ЕСТЬ** - это непрерывная рамка вокруг тротуаров.

**Корневая причина**: `_is_point_in_intersection_shape` проверяет на перекрёстки **ДОРОГ** (road intersections). Эта проверка применялась ко ВСЕМ бордюрам, включая тротуары. Когда тротуар проходит через дорожный перекрёсток, его бордюры обрезались - это неправильно! Тротуары должны иметь бордюры везде, даже на дорожных перекрёстках.

### Решение
1. Добавить `curb_inward: true` в curb_queue для тротуаров
2. Пробросить `curb_inward` через pipeline (`_curb_smoothed_queue` → `_init_curb_mesh_state` → `_process_curb_segments`)
3. В `_init_curb_mesh_state`: проверять `_is_point_in_intersection_shape` только если `NOT curb_inward`
4. Изменить `curb_width` на 0.07 для inward (вместо 0.15)
5. Изменить позиционирование: inward = внутрь от края тротуара
6. Изменить высоты: outer wall на уровне дороги (без underground drop)

### Изменения

**Шаг 1: Включить curb_height для тротуаров**
```gdscript
"footway", "path", "cycleway", "track":
    curb_height = 0.03  // было 0.0
```

**Шаг 2: Исключить тротуары из основного curb_queue, добавить с curb_inward**
```gdscript
// Immediate path (строки 3111, 3414):
if curb_height > 0.0 and highway_type not in ["footway", "path"]:
    _curb_queue.append({..., "curb_inward": false})

// После каждого off-road сегмента тротуара (строки 3089, 3108, 4178, 4197):
_add_road_to_batch_fast(current_pts, width, "path", 0.23, parent)
_curb_queue.append({"local_points": current_pts, "width": width, "height_offset": 0.23, "curb_height": 0.03, "curb_inward": true, "parent": parent, "is_bridge": false, "bridge_info": {}})
```

**Шаг 3: Пробросить curb_inward**
```gdscript
// _process_curb_queue (строка 7475):
_curb_smoothed_queue.append({
    ...,
    "curb_inward": item.get("curb_inward", false)
})
```

**Шаг 4: Изменить _init_curb_mesh_state**
```gdscript
var curb_inward: bool = item.get("curb_inward", false)
var curb_width := 0.07 if curb_inward else 0.15

// Проверка перекрёстков только для обычных дорог:
if curb_inward:
    valid_segments.append(i)
elif _is_point_in_intersection_shape(left1, true) < 0 and ...
    valid_segments.append(i)

_curb_mesh_state = {..., "curb_inward": curb_inward}
```

**Шаг 5: Изменить позиционирование в _process_curb_segments**
```gdscript
if curb_inward:
    left_inner = p + perp * (road_width/2 - curb_width)  // внутрь
    left_outer = p + perp * (road_width/2)               // на краю
else:
    left_inner = p + perp * (road_width/2)               // на краю
    left_outer = p + perp * (road_width/2 + curb_width)  // снаружи

// Высоты:
var left_bottom_y = left_road_y if curb_inward else (left_curb_y - 1.0)
```

### Результат
- **КРИТИЧЕСКИЙ ПРОВАЛ:** Бордюры появились ПОВЕРХ дорожного полотна
- **Причина**: Curb создавался для ВСЕГО footway (все smoothed_points), включая crossing сегменты, которые проходят по дороге на уровне 0.013м. Бордюр с height_offset=0.23м оказался выше дороги.
- **Дополнительная проблема**: Даже если создавать curb только для off-road сегментов, бордюры шли посреди тротуара (по краям каждого path-сегмента), а не по внешним краям всего тротуара.

### Вывод
Подход с использованием существующей curb-инфраструктуры **не работает** для тротуаров:
1. Тротуары разбиваются на сегменты (path/crossing/path)
2. Curb для каждого сегмента создаёт бордюры внутри тротуара
3. Curb для всего footway создаёт бордюры поверх crossing'ов

**ВСЕ ИЗМЕНЕНИЯ ОТКАЧЕНЫ**. Нужен другой подход.

---

## Возможные решения

### Вариант 1: Статический анализ "что рядом?" ✅ ВЫБРАН
**Идея**: Для каждой точки тротуара проверять - что находится слева/справа на расстоянии width/2.

```gdscript
Для каждого footway:
  Для каждой точки:
    point_left = point + perp * (width/2 + margin)
    point_right = point - perp * (width/2 + margin)

    Если _is_point_on_vehicle_road(point_left) == false:
      → нужен левый бордюр (граничит с травой/парковкой)
    Если _is_point_on_vehicle_road(point_right) == false:
      → нужен правый бордюр
```

Собрать отдельные polylines для левого/правого бордюра, создать геометрию.

**Плюсы**:
- Простая реализация
- Использует существующую `_is_point_on_vehicle_road`
- Не требует сложной топологии

**Минусы**:
- Может пропустить границы с другими тротуарами (но это ОК по фото пользователя - бордюры везде)

---

### Вариант 2: Edge-based detection
**Идея**: Собрать все рёбра (edges) отрисованных path-сегментов, найти "свободные" рёбра.

```gdscript
После рендера всех path сегментов:
  1. Собрать все рёбра каждого path quad'а
  2. Найти рёбра которые встречаются только 1 раз (не shared)
  3. Эти "свободные" рёбра = внешние края тротуара
  4. Создать бордюры вдоль свободных рёбер
```

**Плюсы**:
- Точно определяет внешние края
- Корректно обрабатывает сложные топологии

**Минусы**:
- Требует хранения геометрии всех path сегментов
- Сложнее реализация
- Требует post-processing после всех path

---

### Вариант 3: Модифицированная curb-система
**Идея**: Создавать curb для каждого off-road сегмента, но обрезать на границах с crossing.

**Проблема**: Всё ещё создаёт бордюры внутри тротуара (между параллельными path сегментами).

---

### Вариант 4: OSM landuse analysis
**Идея**: Анализировать OSM данные - где footway граничит с landuse=grass, natural=*.

**Проблема**: Нет этих данных в текущем OSM loader.

---

## Попытка 17: Статический анализ "что рядом?"

### Идея
Создать отдельную систему для sidewalk curbs. Для каждой точки тротуара проверить - граничит ли она с дорогой или с травой/парковкой. Создавать бордюры только там где граничит НЕ с дорогой.

### План реализации
1. Новая функция `_create_sidewalk_curbs(smoothed_points, width, parent)`
2. Вызывать в конце обработки footway (после всех path/crossing сегментов)
3. Для каждой точки проверять: `_is_point_on_vehicle_road(point ± perp * width/2)`
4. Собрать polylines для левого/правого бордюра
5. Создать геометрию (3см × 7см inward)

### Результат
- **Провал:** На большинстве тротуаров нет бордюров
- **Проблема на перекрёстках:** Бордюры посреди тротуара (на внутренних краях T-перекрёстка)

### Анализ причин
1. **Большинство тротуаров без бордюров**: `_is_point_on_vehicle_road()` возвращает true для точек возле тротуара. Возможно:
   - Точки на расстоянии width/2 + margin попадают на дорогу (тротуары часто идут вдоль дорог)
   - Margin 5см недостаточен
   - Нужна другая логика определения "внешнего края"

2. **Бордюры на перекрёстках тротуаров**: Когда тротуары пересекаются T-образно:
   - На внутренних краях Т проверка показывает "не на дороге" → создаётся бордюр
   - Но это ВНУТРЕННИЙ край тротуара, не внешний
   - Нужна проверка не только "на дороге?", но и "на другом тротуаре?"

### Вывод
Подход "что рядом?" требует более сложной логики:
- Проверять не только дороги, но и другие тротуары
- Возможно нужен spatial hash для тротуаров
- Или нужен совсем другой критерий "внешнего края"

---

## Попытка 18: Edge-based detection

### Идея
Собрать все рёбра (edges) отрисованных path quad'ов. Рёбра которые встречаются только 1 раз (не shared) = внешние края тротуара. Создать бордюры вдоль этих свободных рёбер.

### План реализации
1. Создать глобальный `_sidewalk_edges: Dictionary` для хранения рёбер
2. В `_add_road_to_batch_fast()` для path: сохранять edges каждого quad'а
3. Edge key = hash от двух точек (порядок не важен)
4. После всех chunk: найти edges с count=1
5. Создать бордюры для свободных edges

### Реализация
1. `_sidewalk_edges: Dictionary` — hash таблица (edge_key → count)
2. `_add_sidewalk_edge(a, b)` — добавляет ребро с direction-independent ключом
3. В `_add_road_to_batch_fast()` для `texture_key=="path" && height==0.23`: собирать left/right edges каждого квада
4. В финализации phase 0 (после всех road batches): вызывать `_finalize_sidewalk_curbs()`
5. `_finalize_sidewalk_curbs()`: найти edges с count==1, сгруппировать в polylines, создать curbs

### Проблема с загрузкой (отладка)
Изначально чанки не загружались (Nodes: 273 вместо ~6000). Причина: неправильный порядок в finalization:
```gdscript
// НЕПРАВИЛЬНО:
0:  # Roads
    _finalize_phase = 1  // ← слишком рано!
    if not _pending_batch_chunks.is_empty():
        ...

// ПРАВИЛЬНО:
0:  # Roads
    if not _pending_batch_chunks.is_empty():
        ...
    else:
        _finalize_sidewalk_curbs()
        _finalize_phase = 1  // ← переход в else
```

Когда `_finalize_phase = 1` выполнялось сразу, код переходил к следующей фазе до обработки chunks → бесконечный цикл / пропуск finalization.

### Результат: НЕУДАЧА ❌

**Проблема**: Бордюры появляются на перекрёстках тротуаров, хотя не должны.

**Статистика** (с SNAP=0.10м / 10см):
- 1110 edges собрано
- 1090 free edges (внешние)
- 587 polylines

**Почему edge detection не работает**:

Когда тротуары примыкают T-образно, их edges **геометрически не совпадают по координатам**:
```
Горизонтальный тротуар: edge от (0, 0) до (10, 0)
Вертикальный примыкает:  edge от (5, -5) до (5, 5)
                                   ↑
                        Пересекаются в (5, 0), но НЕ разделяют
                        общие координаты концов!
```

Оба edges имеют count=1 → считаются "свободными" → создаётся бордюр.

**Попытки исправить**:
- SNAP=0.02м (2см): 1092 free edges
- SNAP=0.10м (10см): 1090 free edges
- Результат: snapping объединил polylines (592→587), но НЕ уменьшил free edges

**Вывод**: Проблема НЕ в точности координат. Edges физически не совпадают при T-образных примыканиях.

**Что НЕ работает**:
- Edge detection (count-based) — не видит геометрические пересечения
- Coordinate snapping — не помогает, т.к. edges не разделяют концы

**Возможные решения** (НЕ реализованы, очень сложные):
1. **Анализ пересечений edges** — проверять line-line intersection для каждой пары edges (~O(n²))
2. **OSM топология** — использовать информацию о shared nodes между ways (требует изменения архитектуры)
3. **Буферная зона** — spatial query: не создавать бордюр, если edge в радиусе 1м от другого path segment
4. **Rasterization** — растеризовать все path segments в grid, найти boundary pixels

Все подходы требуют значительных изменений архитектуры или O(n²) проверок.

**Решение**: Отложено. Изменения откачены.

---

## Технические детали

### GDScript Gotchas (из этой задачи)
- **`:=` не работает с Dictionary-доступом** — GDScript не выводит тип. Всегда используй: `var x: Type = dict["key"]`
- **`normalized()` на результате арифметики** — всё равно требует явную типизацию для переменной

### Curb Pipeline
1. `_curb_queue.append()` — добавление сырых данных
2. `_process_curb_queue()` → `_curb_smoothed_queue` — сглаживание + клиппинг по chunk
3. `_init_curb_mesh_state()` → группировка непрерывных сегментов, проверки junction/intersection
4. `_process_curb_segments()` — генерация меша (inner wall, top, outer wall, caps)
5. Batch finalization — merged ArrayMesh на чанк
6. Collision thread — `_compute_curb_collisions_thread()`

### Spatial Hash
- `ROAD_CELL_SIZE = 20.0` (для дорог)
- Каждая ячейка: `Vector2i(x/20, y/20)` → `Array` of `{p1, p2, width}`
- Заполняется в `_add_road_to_batch_fast()` → `_add_road_segment_to_spatial_hash()`
- Footway/path уже добавляются (width 1.5-2.5м)
