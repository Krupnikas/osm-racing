# Bridge elevation: полная переработка по модели OSM2World

**Статус**: дизайн, утверждён пользователем 2026-04-11. Реализация не начата.
**Контекст**: Октябрьский мост в Череповце и другие многопутные мосты в OSM.
**Цель**: получить бесшовный 3D-мост из набора связных OSM-way'ев, без ступеней на стыках, без провалов, с корректными рампами только на свободных концах.

---

## 1. Что у нас есть прямо сейчас

### 1.1 OSM-данные по Октябрьскому мосту (подтверждено)

Центр моста ≈ `(59.1137, 37.9036)`. 13 ways с тегом `bridge=yes`:

**Главная проезжая часть (primary, 3 полосы, oneway)**:
| way_id | функция | lanes | длина | first_node | last_node |
|---|---|---|---|---|---|
| `82697419` | main север (S→N) | 3 | ~730 м | (59.1089378, 37.9049764) | (59.1155088, 37.9031708) |
| `45481839` | северный стык | 3 | ~80 м | (59.1155088, 37.9031708) | (59.1162238, 37.9030786) |
| `82697420` | северное продолжение | 3 | ~210 м | (59.1162238, 37.9030786) | (59.1181365, 37.9028658) |
| `116079419` | main юг (N→S) | 3 | ~730 м | (59.1155086, 37.9030099) | (59.1089249, 37.9047900) |
| `72047662` | южный стык | 3 | ~80 м | (59.1162731, 37.9027009) | (59.1155086, 37.9030099) |
| `78314252` | северный съезд (main) | 3 | ~210 м | (59.1180540, 37.9020291) | (59.1162731, 37.9027009) |

**Съезды / развязки (secondary, 2 полосы, oneway)**:
| way_id | функция | first_node | last_node |
|---|---|---|---|
| `43844912` | secondary_link | (59.1162238, 37.9030786) | (59.1172106, 37.9035319) |
| `78314250` | secondary съезд | (59.1170854, 37.9010357) | (59.1162731, 37.9027009) |

**Тротуары вдоль всего моста (footway bridge=yes)**:
| way_id | функция | first_node | last_node |
|---|---|---|---|
| `128566919` | западный тротуар | (59.1172024, 37.9036292) | (59.1089439, 37.9050656) |
| `233791607` | восточный тротуар | (59.1089186, 37.9047002) | (59.1170486, 37.9010203) |

**Лестницы (steps bridge=yes)** — подъёмы на мост с земли:
`587234728`, `587234742`, `973550712`.

### 1.2 Шарнирные узлы (вычислены по точному совпадению lat/lon)

Совпадают до последнего знака — это OSM node IDs, разделяемые между way'ями:

- **`(59.1162238, 37.9030786)`** — `45481839.last` = `43844912.first` = `82697420.first` — **T-развязка** северного направления (main идёт прямо, link отходит)
- **`(59.1155088, 37.9031708)`** — `82697419.last` = `45481839.first` — линейное соединение двух main-сегментов
- **`(59.1155086, 37.9030099)`** — `72047662.last` = `116079419.first` — линейное соединение южного main
- **`(59.1162731, 37.9027009)`** — `72047662.first` = `78314250.last` = `78314252.last` — **T-развязка** южного направления (сходятся main + два съезда)

**Свободные концы (ramp to ground)**:
- Южный абатмент main-N: `(59.1089378, 37.9049764)` (start 82697419)
- Южный абатмент main-S: `(59.1089249, 37.9047900)` (end 116079419)
- Северные концы съездов: `(59.1181365, 37.9028658)`, `(59.1180540, 37.9020291)`, `(59.1172106, 37.9035319)`, `(59.1170854, 37.9010357)`

**Тротуары** — их узлы сдвинуты на ~1.5 м от дорожной оси, поэтому lat/lon не совпадают с main. Оба конца каждого тротуара — **свободные**. Рампа у южного и северного абатментов вдоль всей длины тротуара.

### 1.3 Текущая имплементация (то, что надо выбросить)

Файл: [osm/osm_terrain_generator.gd](../osm/osm_terrain_generator.gd).

- `_calculate_road_elevation()` (line ~4001) — вычисляет `bridge_height` со скейлом `BRIDGE_BASE_HEIGHT * length_ratio`, где `length_ratio = road_length / 100`. **Это и есть первопричина ступеней**: длинный way 730м → 3 м, короткий 80м → 2.4 м, 30м → 0.9 м. На стыке 45481839→82697420 видимая ступень.
- `_create_bridge_road()` (line ~4595) — рендерит дорогу. Рампа на обоих концах по `ramp_length` — отсюда "провал до земли между двумя соседними way'ями".
- `_create_bridge_barriers()` (line ~4878) — отбойники в воздухе по своей рампе, плюс добавленный мной костыль skip-по-другому-bridge-через-road-hash.
- `_create_bridge_pillars()` — опоры вдоль моста, тоже используют ramp-логику.
- Мои вчерашние костыли `start_continuous`/`end_continuous` через `_bridge_endpoint_shared()` по road_hash (line ~15000+) — ненадёжны: road_hash содержит сегменты со сглаженными координатами, ищем raw-координаты endpoint, счёт сегментов ошибается внутри самого way'я, плюс race между чанками.

Константы текущей системы:
```gdscript
const BRIDGE_REFERENCE_LENGTH := 100.0
const BRIDGE_BASE_HEIGHT := 3.0
const BRIDGE_MIN_HEIGHT := 0.5
const BRIDGE_RAMP_RATIO := 0.4
const BRIDGE_MAX_RAMP := 35.0
```

### 1.4 Баги, которые сейчас видит пользователь (скриншоты в [docs/oktyabrsky/](oktyabrsky/))

- **bug1 `стыки на разных высотах`** — два соседних bridge way'я имеют разный `bridge_height` из-за скейла по длине. На стыке ступенька.
- **bug2 `несвязные части моста`** — короткая секция ramp'ится вниз, длинная остаётся наверху, визуально мост разрывается.
- **bug3 `обрыв`** — аналогично: одна половина на деке, вторая на земле в 6м ниже, без перехода.
- **плюс**: тротуар на мосту порой оказывается выше главной проезжей части (own independent ramp/length scaling для footway).
- **плюс**: отбойники посреди проезжей части на развязках, где съезд сливается с главной (без знания о слиянии).

---

## 2. Что говорят лучшие практики (OSM2World)

Референс: [tordanik/OSM2World](https://github.com/tordanik/OSM2World), самый зрелый open-source 3D-рендерер OSM, написанный на Java Тоби "Tordanik" Кнопп-Диком с ~2011 года. Рекомендован wiki ([OSM2World — wiki](https://wiki.openstreetmap.org/wiki/OSM2World)).

### 2.1 Ключевой инсайт: **НЕ СТРОИТЬ ЯВНЫЙ ГРАФ МОСТОВ**

OSM2World **не имеет** отдельного bridge-graph-pipeline. Вместо этого elevation решается глобально для всех дорог через union-find по "соединяющимся" точкам.

### 2.2 Архитектура OSM2World elevation

Три главных класса (пути — относительно `core/src/main/java/org/osm2world/`):

1. **`map_elevation/data/EleConnector.java`** (строки 22–85)
   Точка с координатами, значением Y (изначально 0) и метаданными:
   ```java
   public class EleConnector {
       VectorXZ pos;           // XZ-позиция
       Object reference;       // MapNode, если это разделяемый узел. null иначе.
       GroundState groundState; // ON | ABOVE | BELOW
       double ele;             // assigned at end
   }
   ```
   Правило слияния (строки 81–85):
   ```java
   public boolean connectsTo(EleConnector other) {
       return pos.equals(other.pos)
           && ((reference != null && reference == other.reference)
               || (groundState == ON && other.groundState == ON));
   }
   ```
   **Либо** они на одной XZ-позиции с одним `reference` MapNode (общий узел), **либо** обе на земле. Если один ABOVE и другой ON — НЕ сливаются, даже в одной точке. Именно это создаёт рампу между мостом и землёй автоматически.

2. **`world/network/AbstractNetworkWaySegmentWorldObject.java`** (строки 121–230)
   Для каждого сегмента дороги испускает EleConnectors:
   - На обоих endpoint'ах (`reference = shared MapNode`)
   - На outline-точках (левый/правый край)
   - На intersection-insert-точках (где пересекается с другими дорогами)
   - `groundState(node)` возвращает ABOVE, если хотя бы один way через этот узел имеет `bridge=yes`, иначе ON.

3. **`map_elevation/creation/SimpleEleConstraintEnforcer.java`** (строки 28–183)
   Global union-find (`StiffConnectorSet`). В `addConnectors()` делается O(n²)-pairwise `connectsTo` проверка, при совпадении — `requireSameEle` → union двух сетов. В `enforceConstraints()`:
   ```java
   for each stiff set:
       avgEle = average(terrainEle of all members)
       for each member:
           member.ele = avgEle
           if member.groundState == ABOVE: member.ele += 5.0
           if member.groundState == BELOW: member.ele -= 5.0
   ```
   Фиксированный подъём `+5м` для моста — деко-высота.

4. **`map_elevation/creation/BridgeTunnelEleCalculator.java`** (37 строк всего)
   Seed значения Y из тегов: `bridge=yes` → `terrainEle + 0.1`, `tunnel=yes` → `terrainEle`, иначе null. Дальше enforcer усредняет и лифтует.

5. **`world/modules/common/BridgeOrTunnel.java`** (строки 65–213)
   Добавляет дополнительные ограничения для `requireVerticalDistance(MIN, 10m, bridgeConn, roadUnderConn)` — чтобы мост не провалился в реку/дорогу под ним. Опционально.

### 2.3 Как это решает ВСЕ наши проблемы

- **Стыковка соседних bridge-way'ев без ступеней**: оба испускают коннектор в общем узле с `reference = same MapNode`, оба ABOVE → union-find объединяет → одна Y. Бесшовно. *Без* явного "is endpoint shared".

- **Рампа только на свободных концах**: bridge-way упирается в ground-way в общем узле. Bridge-коннектор ABOVE, ground-коннектор ON. `connectsTo` возвращает false (разный groundState). Два разных сета. Bridge получает y=5, ground y=0. Линейная интерполяция по сегменту = рампа. **Никаких явных "ramp meshes"**, это просто наклонённый сегмент той же дороги.

- **T-развязка**: общий узел, все коннекторы в одном сете → одинаковая Y → непрерывная дека.

- **Тротуары на мосту**: если тротуар тегирован `bridge=yes`, он проходит тот же pipeline — его endpoint'ы получают ABOVE, рампа сама возникает на свободных концах.

- **Отбойники на слияниях**: OSM2World **вообще не рисует end-caps** на мостах. Поверхность — это outline'ы дорог, которые сходятся в общем коннекторе. Барьеры (`BridgeModule.drawBridgeUnderside`) — чисто косметические, рисуются по уже посчитанной outline.

### 2.4 Что OSM2World НЕ делает (важно для нас)

- Не авто-поднимает footway, который идёт параллельно мосту, но сам не тегирован `bridge=yes`. Если в данных тротуар не помечен — он остаётся на земле. У нас в Октябрьском мосте оба тротуара помечены, так что это не проблема.
- Incline-based propagation работает только в `ConstraintEleCalculator` (более сложный), а `SimpleEleConstraintEnforcer` просто лифтит на `+5м`. Нам хватит простого.

### 2.5 Ссылки на источники

- [OSM2World GitHub](https://github.com/tordanik/OSM2World)
- [OSM2World wiki](https://wiki.openstreetmap.org/wiki/OSM2World)
- [Key:bridge — OSM wiki](https://wiki.openstreetmap.org/wiki/Key:bridge)
- [Bridge3D — OSM wiki](https://wiki.openstreetmap.org/wiki/Bridge3D)
- [Key:layer — OSM wiki](https://wiki.openstreetmap.org/wiki/Key:layer)
- [kendzi3d](https://wiki.openstreetmap.org/wiki/Kendzi3D) — второй рендерер, использует тот же подход, заимствованный из OSM2World
- [Key:man_made=bridge — OSM wiki](https://wiki.openstreetmap.org/wiki/Tag:man_made=bridge)

Локальные копии исходников скачаны для референса в `/tmp/osm2world/`:
- `BridgeModule.java`
- `BridgeOrTunnel.java`
- `BridgeTunnelEleCalculator.java`
- `EleConnector.java`
- `SimpleEleConstraintEnforcer.java`

---

## 3. План имплементации в Godot / GDScript

### 3.1 Философия

Адаптируем OSM2World-подход в минимальной форме. **Не нужен** полный constraint solver с incline'ами — у нас нет incline в данных, а +5м постоянной высоты + ramp на свободных концах — это уже правильный профиль.

Вместо полного O(n²) union-find мы используем **более простой** аналог: per-way lookup, "разделяется ли мой endpoint с другим bridge way'ем". Это эквивалентно union-find на два сета {bridge-ways, ground-ways}, что нам и нужно.

### 3.2 Новые структуры данных

```gdscript
# Глобальный класс-level член, живёт всю сессию.
# key: "%.6f,%.6f" % [lat, lon] — квантизация до 6 знаков (~0.1 м), OSM-узлы совпадают точно.
# value: Dictionary, ключи = way_ids (int) всех bridge=yes ways, у которых ЭТА точка является
#        первым или последним узлом.
var _bridge_node_ways: Dictionary = {}
```

```gdscript
func _bridge_coord_key(lat: float, lon: float) -> String:
    return "%.6f,%.6f" % [lat, lon]

func _register_bridge_endpoint(lat: float, lon: float, way_id: int) -> void:
    var k := _bridge_coord_key(lat, lon)
    if not _bridge_node_ways.has(k):
        _bridge_node_ways[k] = {}
    _bridge_node_ways[k][way_id] = true

func _bridge_endpoint_is_shared(lat: float, lon: float) -> bool:
    var k := _bridge_coord_key(lat, lon)
    var entries: Dictionary = _bridge_node_ways.get(k, {})
    return entries.size() >= 2
```

### 3.3 Где и когда строится `_bridge_node_ways`

Pre-scan должен случиться ДО того, как первый bridge-way попадёт в `_create_bridge_road`.

**Вариант А (выбранный)**: в phase 1 worker'е — одновременно с построением road_hash. Возвращать через `result` структуру `bridge_endpoints: Array[{lat, lon, way_id}]`. В main thread после возврата phase 1 для чанка — merge в `_bridge_node_ways`.

**Что это гарантирует**: к моменту, когда `_create_bridge_road` вызывается в phase 2 для данного чанка, все bridge endpoints ВСЕХ ways в данных для этого чанка и соседних (уже загруженных) чанков известны. Остаётся риск: если чанк B с другой половиной моста загрузится ПОСЛЕ того, как в A уже отрендерился bridge-way, то A не знает про общий узел в B. Но для спавна рядом с мостом все ways попадают в initial radius и загружаются одновременно.

**Резервный вариант**: перед вызовом `_create_bridge_road` синхронно сканировать `osm_loader.get_ways_in_bbox(current_chunk + 1 neighbor)` и собирать bridge endpoints на лету. Дороже, но корректно всегда.

### 3.4 Новые константы

```gdscript
# Полностью заменяют старые BRIDGE_* константы (оставим или удалим старые — по коду).
const BRIDGE_DECK_HEIGHT := 5.0          # Высота деки моста над землёй, константа, НЕ скейлится
const BRIDGE_RAMP_LENGTH := 35.0         # Длина рампы на свободном конце (макс)
const BRIDGE_SEGMENT_SUBDIVIDE := 10.0   # Подразделение длинных сегментов для плавной рампы
const BRIDGE_PILLAR_SPACING := 20.0      # Шаг опор (оставляем как было)
```

### 3.5 Переписанный `_create_bridge_road()`

Псевдокод (один цикл без скейла, без `bridge_info`):

```gdscript
func _create_bridge_road(nodes, width, texture_key, height_offset, parent):
    if nodes.size() < 2:
        return

    # 1. Локальные координаты
    var points: PackedVector2Array = []
    for n in nodes:
        points.append(_latlon_to_local(n.lat, n.lon))

    # 2. Подразделение длинных сегментов (для плавной интерполяции высоты)
    points = _subdivide_polyline(points, BRIDGE_SEGMENT_SUBDIVIDE)

    # 3. Общая длина
    var total_length := 0.0
    for i in range(points.size() - 1):
        total_length += points[i].distance_to(points[i + 1])
    if total_length < 1.0:
        return

    # 4. Shared/free ends — используем ИСХОДНЫЕ OSM-узлы, не сабдивизии
    var start_shared := _bridge_endpoint_is_shared(nodes[0].lat, nodes[0].lon)
    var end_shared := _bridge_endpoint_is_shared(nodes[nodes.size()-1].lat, nodes[nodes.size()-1].lon)

    # 5. Длины рамп. Если конец shared — рампы нет, мост стыкуется на полной высоте.
    var ramp_from_start: float = 0.0 if start_shared else minf(BRIDGE_RAMP_LENGTH, total_length)
    var ramp_from_end: float = 0.0 if end_shared else minf(BRIDGE_RAMP_LENGTH, total_length)

    # 6. Защита: оба конца свободны и way слишком короткий для двух рамп — делим пополам
    if not start_shared and not end_shared and total_length < BRIDGE_RAMP_LENGTH * 2:
        ramp_from_start = total_length * 0.5
        ramp_from_end = total_length * 0.5

    # 7. Функция высоты в точке по накопленной длине
    var height_at := func(accumulated: float) -> float:
        var h := BRIDGE_DECK_HEIGHT
        if ramp_from_start > 0.0 and accumulated < ramp_from_start:
            var t: float = accumulated / ramp_from_start
            h = _smooth_step(t) * BRIDGE_DECK_HEIGHT
        elif ramp_from_end > 0.0 and accumulated > total_length - ramp_from_end:
            var t: float = (total_length - accumulated) / ramp_from_end
            h = _smooth_step(t) * BRIDGE_DECK_HEIGHT
        return height_offset + h

    # 8. Генерация меша — обычная, только Y берётся из height_at(accumulated)
    # ... (vertex/uv/normal/indices, как сейчас, но без bridge_info)

    # 9. Коллизия, опоры, отбойники — те же функции, новая сигнатура:
    _create_bridge_collision(vertices, indices, parent)
    _create_bridge_pillars_new(points, ramp_from_start, ramp_from_end, total_length, parent)
    _create_bridge_barriers_new(points, width, ramp_from_start, ramp_from_end, total_length, height_offset, parent, way_id)
```

### 3.6 Переписанный `_create_bridge_barriers()`

Та же функция высоты (подавая те же `ramp_from_start/end`). Плюс решение "рисовать или нет" для каждого сегмента отбойника:

```gdscript
# Для каждой точки барьера — её XZ-координата
var barrier_pt := ...
# Проверяем: есть ли ДРУГОЙ (way_id != self) bridge way в этой точке
var in_other_bridge := _point_is_in_other_bridge_corridor(barrier_pt, self_way_id, barrier_ck)
skip_point[i] = in_other_bridge
```

`_point_is_in_other_bridge_corridor(point, self_way_id, ck)`:
- Обходит road hash в окрестности `point`
- Сегмент считается совпадающим если `seg.bridge == true` AND `seg.way_id != self_way_id` AND distance `<= seg.width/2 - margin`
- Уже добавил `way_id` в `rseg` (коммит-кандидат) — нужно сохранить это

Сегменты отбойника, оба endpoint'а которых в in_other_bridge, пропускаются. Отсюда gap на слияниях.

### 3.7 Переписанный `_create_bridge_pillars()`

Простое: использовать ту же функцию `height_at(accumulated)`. Опоры ставить каждые 20м (BRIDGE_PILLAR_SPACING), **только там, где высота >= BRIDGE_DECK_HEIGHT - 0.5** (т.е. только на плоской деке, не на рампах). Опора = бетонная колонна от Y=0 до Y=height_at(pos).

### 3.8 Сидевалки / тротуары

Footway с `bridge=yes` уже проходит через `_create_road` → `_calculate_road_elevation` → (с новой логикой) → `_create_bridge_road`. В новой реализации:

- Тротуар регистрирует свои endpoint'ы в `_bridge_node_ways` в pre-scan.
- Его endpoint'ы — свои собственные (не совпадают с main road endpoints), `_bridge_endpoint_is_shared` вернёт false → оба конца свободны → рампа с обеих сторон (35 м у абатментов), плоско 5 м между ними.
- Визуально получаем долгую дорожку на высоте 5 м, с плавными рампами у южного и северного концов. Совпадает с высотой главной проезжей.

**Тонкость**: тротуары 800м+. Ровный участок 730 м на высоте 5 м. Подразделение `BRIDGE_SEGMENT_SUBDIVIDE=10` даёт 80 вершин — приемлемо.

### 3.9 Что удаляем из `_calculate_road_elevation()`

```gdscript
# БЫЛО:
if bridge_val == "yes":
    result.is_bridge = true
    var length_ratio := clampf(road_length / BRIDGE_REFERENCE_LENGTH, 0.0, 1.0)
    var base_height := maxf(BRIDGE_MIN_HEIGHT, BRIDGE_BASE_HEIGHT * length_ratio)
    result.bridge_height = base_height + maxf(0, layer) * LAYER_HEIGHT
    result.height = base_elevation + bridge_height
    result.ramp_length = minf(BRIDGE_MAX_RAMP, road_length * BRIDGE_RAMP_RATIO)

# СТАНЕТ:
if bridge_val == "yes":
    result.is_bridge = true
    result.bridge_height = BRIDGE_DECK_HEIGHT  # константа, конкретная высота у-рендеринга считается в _create_bridge_road
    result.height = base_elevation + BRIDGE_DECK_HEIGHT
    # ramp_length не нужен — решается в _create_bridge_road через shared-check
```

Тем самым `bridge_info.ramp_length` больше не используется; всем бриджам, которые попадают в `_create_bridge_road`, даётся одинаковая рамочная длина `BRIDGE_RAMP_LENGTH`, и та применяется только на свободных концах.

### 3.10 Что удаляем из моих вчерашних фиксов

- Функция `_bridge_endpoint_shared(point, ck)` через road_hash — заменяется на `_bridge_endpoint_is_shared(lat, lon)` по словарю
- Override `bridge_height = BRIDGE_BASE_HEIGHT if start_continuous or end_continuous` — не нужен, константа всегда применяется
- `_is_point_on_bridge_road` — не нужна, заменяется на `_point_is_in_other_bridge_corridor` которая фильтрует по way_id (исключая self)
- Поле `bridge` и `way_id` в `rseg` — остаются, они нужны для фильтрации барьеров

---

## 4. Пошаговый план коммита

1. **Расширить phase 1 worker** — собирать `bridge_endpoints: Array[{lat, lon, way_id}]` из всех ways с `highway + bridge=yes`
2. **Merge в main thread** после phase 1 — добавлять в `_bridge_node_ways` через `_register_bridge_endpoint`
3. **Добавить константы** `BRIDGE_DECK_HEIGHT`, `BRIDGE_RAMP_LENGTH`, `BRIDGE_SEGMENT_SUBDIVIDE`
4. **Добавить хелпер** `_bridge_coord_key`, `_register_bridge_endpoint`, `_bridge_endpoint_is_shared`
5. **Упростить `_calculate_road_elevation()`** — убрать length_ratio скейл для bridge=yes
6. **Переписать `_create_bridge_road()`** — новая функция высоты по shared-check
7. **Переписать `_create_bridge_barriers()`** — та же функция высоты + skip по way_id на слияниях
8. **Переписать `_create_bridge_pillars()`** — та же функция высоты, опоры только на плоской части
9. **Удалить старые костыли**: `_bridge_endpoint_shared` (через road_hash), `_is_point_on_bridge_road`, override `bridge_height` в `_create_bridge_road`
10. **Протестировать** в Godot MCP: спавн "Октябрьский мост", проехать весь мост от южного абатмента до северного, проверить съезды, проверить вид сверху (все ways на одинаковой высоте), убедиться в отсутствии провалов/ступеней
11. **Проверить другие мосты** в игре (другие спавны) — не сломали ли
12. **Один чистый коммит** с сообщением описывающим перестройку по модели OSM2World

---

## 5. Риски и угловые случаи

- **Чанки грузятся в разном порядке** — bridge-way может отрендериться до того, как его сосед в другом чанке попал в `_bridge_node_ways`. Митигация: initial load радиус обычно покрывает весь мост. Полная гарантия: re-render, но это дорого.
- **OSM данные могут содержать `bridge=yes` в не-highway ways** (ж.д., велодорожки). Наша фильтрация `highway + bridge=yes` — безопасна.
- **Короткие bridge ways (30 м) с двумя shared концами** — плоский мост на 5м, короткий, норм.
- **Одинокие bridge ways без соседей вообще** (малые мосты через ручей) — оба конца свободны, рампа пополам. Норм.
- **Tunnel'ы** — не затрагиваем, `tunnel=yes` по-прежнему остаётся на земле.
- **Layer>0 без bridge** — эстакады. Оставить текущую логику (подъём по layer). Не смешивать с bridge-pipeline.

---

## 6. Текущий коммит и что в нём уже есть

Коммит `53b0537` "Add Oktyabrsky Bridge V-pylon + fix water rendering and NPC despawning" — **не затрагивает** bridge elevation. Там пилон, вода, npc-деспавн, текстуры моста. Его не откатываем.

Мои НЕЗАКОМИЧЕННЫЕ изменения в `osm/osm_terrain_generator.gd`:
- `_bridge_endpoint_shared` (через road_hash) — **удалить**
- `_is_point_on_bridge_road` — **удалить**
- `start_continuous`/`end_continuous` хак в `_create_bridge_road` и `_create_bridge_barriers` — **удалить**
- `way_id` + `bridge` поля в `rseg` в phase 1 — **оставить** (пригодятся для барьеров)
- Гейт `_is_point_on_vehicle_road` margin=-0.5 в барьерах — **удалить**

---

## 7. Что будет проверяться в приёмке

1. Спавн "Октябрьский мост". Вид от спавна на пилон: мост плоский на одной высоте до пилона и за ним.
2. Сверху (debug camera y=300): все 13 bridge-way'ев на одинаковой высоте 5 м. Никаких ступеней между 45481839 ↔ 82697419, 82697420 ↔ 45481839, 116079419 ↔ 72047662 и т.д.
3. Северные съезды (78314250, 78314252, 43844912) сходятся на главную deck высоту без провалов.
4. Рампа только на южном абатменте и на СВОБОДНЫХ концах съездов — плавная, 35 м.
5. Тротуары 128566919 и 233791607 — на высоте деки, рампят на ~35 м у обоих концов.
6. Отбойник: есть на всём протяжении внешних краёв моста, НЕТ на местах слияния съездов с главной проезжей.
7. Регрессия: Новый Век, Череповец, Ледовый дворец — спавн работает, дороги рендерятся.
8. Отсутствие `SCRIPT ERROR` в `get_editor_errors`.
