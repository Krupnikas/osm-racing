# OSM Racing Facade Archetype Pipeline

Этот документ фиксирует текущее устройство модульных фасадов в Череповце:
`default-panel-*`, `default-bricks-1`, специальные серии, 111-125 на
Северном шоссе 35/37/39, слоты окон/балконов и extrusion балконов.

## Основные файлы

- `osm/facade_assembler.gd` - универсальный сборщик JSON-архетипов.
- `decorations/russia/cherepovets/facades/*.json` - текущие архетипы.
- `decorations/russia/cherepovets/*-atoms/` - PNG-атомы фасадов.
- `osm/facade_111_125.gd` - ручной специальный фасад серии 111-125.
- `decorations/russia/cherepovets/building_overrides.json` - way-specific
  overrides, включая Северное шоссе 35/37/39.
- `osm/osm_terrain_generator.gd` - точка подключения фасадов к OSM-зданиям.

Связанные implementation-документы:

- `docs/FACADE_IMPLEMENTATION_LOG_2026_06_24.md` - что было сделано для DCH,
  Советского проспекта и Курманова 13.
- `docs/KURMANOVA_13_FACADE_OVERRIDE.md` - точечный фасадный override для OSM
  way `45119820`.
- `docs/DCH_PIPELINE_PROGRESS.md` - прогресс и выводы DCH-пайплайна.
- `docs/SOVETSKY_LOWRISE_FACADE_PIPELINE.md` - low-rise пайплайн для
  Советского проспекта.

## Где включается FacadeAssembler

В `osm/osm_terrain_generator.gd` генерация здания идет по приоритетам:

1. `custom_model` полностью заменяет здание.
2. Way IDs `45836637`, `45836638`, `45836639` используют `Facade111_125`,
   если у override есть `wall_texture_path`.
3. Другие explicit `wall_texture` / `color_tint` идут старым flat texture путем.
4. Для обычных зданий в Череповце пробуется `FacadeAssembler`.
   Way-specific override может принудительно выбрать конкретный
   `FacadeAssembler` архетип через `facade_archetype`, даже если здание не
   проходит обычный material/category подбор.
5. Если архетип не найден или нет atom-текстур, используется старый fallback.

Для `FacadeAssembler` материал берется из `building:material`. Если тега нет,
код детерминированно назначает примерно 40% зданий в `brick`, остальные в
`panel` по hash от `way_id`. Гаражи получают `mat_tag = "garage"` по типу
`building=garage/garages`.

Текущая мапа категорий в `FacadeAssembler._tag_to_category()`:

| OSM tag / synthetic tag | Category |
|---|---|
| `panel` | `panel` |
| `large_panel` | `panel` |
| `brick` | `brick` |
| `garage` | `garage` |
| `modern` | `modern` |

Важно: поле `material_tags` в JSON сейчас описательное. Селекция реально
использует `category`, `min_floors`, `max_floors` и hash `way_id`.
Исключение: `building_overrides.json` может задать `facade_archetype`, тогда
архетип берется напрямую по `id` через `FacadeAssembler.get_archetype()`.

## Архетипы и "наследование"

Архетип JSON содержит:

- `id`
- `category`
- `min_floors` / `max_floors`
- `has_seams`
- `has_roofbottom`
- `atom_dir`
- `atoms`
- `molecules`
- optional `forbidden`
- optional `slot_overrides`
- optional `floor_atom_overrides`
- optional `slot_extrusion`

Для точечных зданий можно использовать override:

```json
{
  "osm_way_id": 45119820,
  "comment": "13 улица Курманова (NORTHIS)",
  "facade_archetype": "kurmanova-13-brick-commercial-1",
  "height_override": 10.5
}
```

Такой forced archetype не участвует в обычной выборке по `building:material`.
Это нужно для landmark/special зданий, где look должен быть конкретным, а не
статистическим.

Сейчас нет полноценного поля `parent`. Наследование сделано практично:
атом роли может быть массивом локальных файлов или ссылкой на другой каталог:

```json
"window": {
  "dir": "res://decorations/russia/cherepovets/default-panels-atoms/",
  "files": ["window-1", "window-2"]
}
```

Так `panel-concrete-series-*` наследует окна из `default-panels-atoms`, но
держит собственные стены, long balconies, seams и roofbottom. Цветовые
варианты `default-panel-brown/pear/pebble/yellow` не наследуют JSON друг от
друга: они повторяют одинаковые molecules и общие окна/балконы, меняя только
цветовые wall/seam атомы.

## Этажные переопределения атомов

Некоторые малоэтажные исторические фасады не сводятся к одному цвету стены:
например, на Советском проспекте у двухэтажных домов нижний этаж может быть
охристым, а верхний кремовым. Для этого есть `floor_atom_overrides`.

Пример:

```json
"floor_atom_overrides": {
  "ground": {
    "wall": "lower-wall",
    "mid-wall": "lower-mid-wall",
    "long-wall": "lower-long-wall",
    "window": "window"
  },
  "upper": {
    "wall": "upper-wall",
    "mid-wall": "upper-mid-wall",
    "long-wall": "upper-long-wall",
    "window": "arched-window"
  }
}
```

Поддерживаемые зоны: `ground`, `middle`, `upper`, опционально `top`.
Если для зоны или категории нет переопределения, используется исходная
категория из slot catalog. Это сохраняет поведение старых архетипов.

## Слоты: short, mid, long

`FacadeAssembler.SLOT_CATALOG` задает базовую сетку:

| Slot role | Фон | Overlay | Width |
|---|---|---|---|
| `wall` | `wall` | none | 3.2 m |
| `mid-wall` | `mid-wall` | none | 4.8 m |
| `long-wall` | `long-wall` | none | 6.4 m |
| `window` | `wall` | `window` | 3.2 m |
| `mid-window` | `mid-wall` | `mid-window` | 4.8 m |
| `entrance` | `mid-wall` | `entrance` | 4.8 m |
| `mid-balcony` | `mid-wall` | `mid-balcony` | 4.8 m |
| `long-balcony` | `long-wall` | `long-balcony` | 6.4 m |
| `roofbottom` | `roofbottom` | none | 3.2 m |
| `long-roofbottom` | `long-roofbottom` | none | 6.4 m |
| `long-garage` | `long-wall` | `long-garage` | 6.4 m |

"Short/mid/long" здесь в основном значит ширину фасадного bay:

- short/default bay: 3.2 m (`wall`, `window`)
- mid bay: 4.8 m (`mid-wall`, `mid-window`, `mid-balcony`)
- long bay: 6.4 m (`long-wall`, `long-balcony`)

`entrance` intentionally uses the same 4.8 m mid-bay width as `mid-window`.
This lets a shop/office entrance replace one mid-window bay on the ground floor
without changing the bay grid on upper floors.

Отдельно у molecules есть tags `any`, `short`, `long`. Класс ребра считается
на стороне здания: edge считается `long`, если его длина больше или равна
меньшей из двух соседних сторон, иначе `short`. Это позволяет garage-архетипу
рисовать двери на длинных сторонах, а стены на коротких. Большинство жилых
архетипов пока используют только `any`.

## Пиксельная сетка атомов

Атомы рисуются в PNG на единой авторской сетке. Это важно: сборщик не знает,
что на картинке "окно" или "балкон" по смыслу, он берет пиксельный размер
PNG и переводит его в метры по правилам ниже.

Базовая фасадная клетка:

- `512 px` по ширине = `3.2 m` фасада.
- Значит горизонтальный масштаб = `160 px/m`.
- `512 px` по высоте = один этаж.
- Реальная высота этажа не зашита в PNG: она считается из высоты здания и
  количества этажей, а PNG растягивается на этот floor height.

Отсюда получаются размеры wall atoms:

| Atom family | PNG size | Смысл | Game width |
|---|---:|---|---:|
| `wall` | `512x512 px` | одна обычная секция стены | `3.2 m` |
| `mid-wall` | `768x512 px` | полторы секции | `4.8 m` |
| `long-wall` | `1024x512 px` | две секции | `6.4 m` |
| `small-wall` в 111-125 | `256x512 px` | половина секции | `1.6 m` |

`mid` и `long` нужны не как произвольное растяжение, а как отдельные
нарисованные атомы под более широкие фасадные ситуации:

- широкий оконный/лоджийный блок лучше класть на `mid-wall`, чтобы фон был
  нарисован под 768 px, а не растянутый 512 px;
- длинный балкон или лоджия кладется на `long-wall`, то есть на 1024 px фон;
- horizontal seam тоже должен совпадать с шириной слота, иначе шов визуально
  не попадет в сетку фасада.

Overlay atoms используют свой реальный PNG size:

| Overlay family | Типичный PNG size | Куда кладется | Default top offset |
|---|---:|---|---:|
| `window` | `320x320 px` | центр `wall` / `window` slot | `80 px` |
| `mid-window` | `480x320 px` или близко к ширине mid-секции | центр `mid-wall` | `80 px` |
| `entrance` | обычно `768x512 px` | центр `mid-wall` | `0 px` |
| `mid-balcony` | обычно `768x512 px` | центр `mid-wall` | `0 px` |
| `long-balcony` | обычно до `1024x512 px` | центр `long-wall` | `0 px` |
| `entrance` в 111-125 | `768x512 px` | `mid-wall-entrance` | `0 px` |

Сборщик считает размеры overlay так:

- overlay width in meters = `texture_width / 160 * slot_scale`;
- overlay height in meters = `texture_height / 512 * floor_h`;
- overlay центрируется по горизонтали в slot;
- верх overlay опускается от верха этажа на `overlay_offset_top_px`.

Пример: обычное окно `320x320 px` при `slot_scale = 1` станет `2.0 m`
шириной (`320 / 160`) и `0.625` высоты этажа (`320 / 512`). С offset `80 px`
его верх будет ниже верха этажа на `80 / 512` высоты этажа.

### Швы в пикселях

Панельные архетипы используют отдельные alpha-атомы швов:

| Seam atom | PNG size | Куда применяется |
|---|---:|---|
| `horizontal-seam` | `512x30 px` | между этажами на 3.2 m slot |
| `horizontal-mid-seam` | `768x30 px` | между этажами на 4.8 m slot |
| `horizontal-long-seam` | `1024x30 px` | между этажами на 6.4 m slot |
| `vertical-seam` | обычно узкая вертикальная текстура | на границе слотов |

В универсальном сборщике фактическая толщина горизонтального шва сейчас
задается не чтением `30 px` из PNG, а константой `SEAM_FRACTION = 0.06` от
высоты этажа. Это близко к `30 / 512 = 0.0586`. В ручном `Facade111_125`
используется явная константа `SEAM_PX = 30`.

Вертикальный шов имеет фиксированную игровую ширину `0.1875 m`, что равно
примерно `30 px / 160 px/m`. Он рисуется поверх фасада на границах между
соседними slots.

### Архетипы без швов

Швы не обязательны. Если в JSON стоит:

```json
"has_seams": false
```

то сборщик пропускает и горизонтальные, и вертикальные швы. Так сейчас
работают:

- `default-bricks-1` - кирпичные фасады без панельных seams;
- `panel-teal-tiles-series-1` - плиточная панельная серия без отдельных seams;
- `default-garage-1` - гаражный архетип без seams.

Для таких архетипов можно вообще не класть seam atoms в `atoms`. Если
`has_seams = true`, то для всех используемых ширин желательно иметь
соответствующие horizontal seam atoms, иначе часть швов просто не нарисуется.

## Ручной авторский пайплайн создания атомов

Цель этой системы - не точное повторение каждого дома, а убедительный
look and feel конкретного города, района или страны. Ключевые здания можно
делать вручную, как Северное шоссе 35/37/39, но массовые дома должны
собираться из стереотипных постсоветских "панельки/кирпичи" атомов.

Текущий ручной процесс был таким:

1. Найти в Google Maps / Street View характерные стены района: панельный
   бетон, кирпич, покраска, возрастные пятна, разводы, ржавчина, самодельные
   балконы, остекленные лоджии.
2. Сделать скриншоты не всего здания, а конкретных компонентов:
   - чистая стена без окна;
   - межпанельный шов, если он есть;
   - обычное окно;
   - более широкое/mid окно;
   - mid-балкон;
   - long-балкон или лоджия;
   - entrance group, если архетип должен иметь подъезды.
3. Для стены сгенерировать три фона одной текстуры и цвета:
   - `512x512` - обычный `wall`;
   - `768x512` - `mid-wall`;
   - `1024x512` - `long-wall`.
4. Если у серии есть межпанельные швы, сгенерировать вертикальный шов
   `30x572`. Горизонтальные швы можно делать отдельно или получить из
   вертикального поворотом/сжатием до `512x30`, затем при необходимости
   сделать `768x30` и `1024x30`.
5. Для обычных окон сгенерировать несколько вариантов на прозрачном фоне.
   В `default-panel` это `320x320`: одинаковый размер, но немного разные
   рамы, шторы, мебель/цветы/детали за стеклом и степень износа.
6. Для mid-окон сгенерировать варианты `480x320` на прозрачном фоне.
   Важно выпрямлять перспективу: окно должно быть прямоугольным, а не
   параллелограммом со скриншота.
7. Для mid-балконов сгенерировать несколько вариантов. В `default-panel`
   это `700x512` на прозрачном фоне, потому что балкон чуть уже `mid-wall`
   слота (`768 px`) и центрируется внутри него. Вариативность важна:
   ржавый металл, пластиковый сайдинг, разная степень износа, разное
   остекление.
8. Для long-балконов/лоджий сгенерировать варианты `1024x512`, обычно от
   края до края, без боковых гэпов. Это соответствует полному `long-wall`
   слоту.
9. Если генератор изображений дал правильный ratio, но неправильный
   фактический pixel size, вручную resize до нужного размера перед импортом.

Авторская идея: у фасада есть не "одна текстура дома", а библиотека деталей.
Стены задают общий цвет и материал района. Окна и балконы дают бытовую
вариативность. Швы включаются только там, где они являются частью визуального
языка серии.

## Mapping ручного процесса к default-panel

`decorations/russia/cherepovets/default-panels-atoms/` уже устроен ровно по
этому пайплайну:

| Ручной компонент | Роль в JSON | Файлы default-panel | Размер |
|---|---|---|---:|
| обычная стена | `wall` | `wall-{brown,pear,pebble,yellow}-1.png` | `512x512` |
| mid стена | `mid-wall` | `mid-wall-{brown,pear,pebble,yellow}-1.png` | `768x512` |
| long стена | `long-wall` | `long-wall-{brown,pear,pebble,yellow}-1.png` | `1024x512` |
| обычное окно | `window` overlay | `window-1..6.png` | `320x320` |
| mid окно | `mid-window` overlay | `mid-window-1..6.png` | `480x320` |
| mid балкон | `mid-balcony` overlay | `mid-balcony-1..5.png` | `700x512` |
| лоджия / long балкон | `long-balcony` overlay | `long-balcony-1..6.png` | `1024x512` |
| вертикальный шов | `vertical-seam` | `vertical-seam-{color}-1.png` | `30x572` |
| горизонтальный шов | `horizontal-seam` | `horizontal-seam-{color}-1.png` | `512x30` |
| mid горизонтальный шов | `horizontal-mid-seam` | `horizontal-mid-seam-{color}-1.png` | `768x30` |
| long горизонтальный шов | `horizontal-long-seam` | `horizontal-long-seam-{color}-1.png` | `1024x30` |
| маска ночного свечения | emission convention | `window-emission-1..6.png` | `320x320` |

Что важно для automation:

- walls должны быть непрозрачными фонами без окон и без швов;
- seams должны быть отдельными alpha overlays или узкими opaque/alpha атомами,
  чтобы можно было включать/выключать `has_seams`;
- windows/balconies/loggias должны быть PNG с прозрачностью и без текстуры
  стены;
- варианты одного типа должны иметь одинаковый canvas size, иначе в игре они
  будут иметь разные физические размеры;
- pink/chroma фон из генератора допустим только как промежуточный шаг, но
  финальный PNG должен иметь alpha channel.

## Молекулы

Молекула - это последовательность slot roles. Сборщик:

1. фильтрует molecules по `forbidden` и tag (`any`, `short`, `long`);
2. считает номинальную ширину как сумму slot widths;
3. выбирает одну molecule на edge детерминированно по `way_id + edge_idx`;
4. повторяет ее `round(edge_len / molecule_width)` раз;
5. равномерно масштабирует все слоты по длине edge.

Если ни одна molecule не помещается без сильного сжатия, берется самая
маленькая, а при экстремальном сжатии fallback строит plain `wall` tiles.

## default-panel-*

Текущие color variants:

- `default-panel-brown`
- `default-panel-pear`
- `default-panel-pebble`
- `default-panel-yellow`

Все имеют:

- `category = "panel"`
- `min_floors = 4`, `max_floors = 20`
- `has_seams = true`
- `has_roofbottom = false`
- `balcony_placement = "centre"` как metadata
- `slot_extrusion.mid-balcony.depth_m = 0.8`

Атомы:

- цветные: `wall`, `mid-wall`, `long-wall`, `horizontal-seam`,
  `horizontal-mid-seam`, `horizontal-long-seam`, `vertical-seam`
- общие: `window-1..6`, `mid-window-1..6`, `mid-balcony-1..5`,
  `long-balcony-1..6`
- emission masks для окон лежат рядом как `window-emission-N.png`

Molecules у всех четырех цветов одинаковые. Примеры:

- `wall-win`: `wall`, `window`
- `win-wall-wall-win`: `window`, `wall`, `wall`, `window`
- `win-midbal-win`: `window`, `mid-balcony`, `window`
- `midwin-win3-midwin-win2`
- `win-win-longbal-win-win`
- `longbal-win-midbal-win-win-midbal-win-longbal`

## default-bricks-1

`default-bricks-1`:

- `category = "brick"`
- `min_floors = 4`, `max_floors = 20`
- `has_seams = false`
- `has_roofbottom = false`
- `balcony_placement = "top"` как metadata
- `slot_extrusion.mid-balcony.depth_m = 0.8`

Атомы:

- `wall-1`, `mid-wall-1`, `long-wall-1`
- `window-1..5`
- `mid-balcony-1..6`
- `long-balcony-1..6`
- seams отсутствуют

У кирпичей `slot_overrides.window.overlay_offset_top_px = 0`. То есть окно
рисуется от верхней границы этажа, а не с отступом 80 px, как у панелей.
Поле `balcony_placement = "top"` сейчас не обрабатывается отдельной веткой
кода; фактическая вертикальная позиция задается offset и самой PNG-геометрией
overlay.

## panel-concrete-series-1/2

Обе серии:

- `category = "panel"`
- `min_floors = 4`, `max_floors = 20`
- `has_seams = true`
- `has_roofbottom = true`
- `balcony_placement = "centre"`
- запрещают `mid-wall`, `mid-window`, `mid-balcony`, `horizontal-mid-seam`
- наследуют `window-1..6` из `default-panels-atoms`

`panel-concrete-series-1` имеет pebble-стены, 5 вариантов `long-balcony`,
свои pebble seams и `roofbottom`/`long-roofbottom`.

`panel-concrete-series-2` имеет свои стены без цветового суффикса, 4 варианта
`long-balcony`, свои seams и `roofbottom`/`long-roofbottom`.

Из-за `forbidden` эти серии строятся только из 3.2 m и 6.4 m слотов.
`slot_extrusion` сейчас настроен для `mid-balcony`, но `mid-balcony` запрещен
и не встречается в molecules этих серий. Значит extrusion для этих серий на
практике не сработает, пока не добавить extrusion для `long-balcony`.

## panel-teal-tiles-series-1

В проекте уже есть еще одна panel-серия, которой нет в старом draft:
`panel-teal-tiles-series-1`.

Она:

- `category = "panel"`
- `has_seams = false`
- имеет собственные teal mosaic wall/mid/long walls
- наследует окна и балконы из `default-panels-atoms`
- использует часть panel molecules
- имеет `slot_extrusion.mid-balcony.depth_m = 0.8`

Так как selection выбирает любой подходящий `category=panel` архетип по hash,
эта серия уже находится в общем пуле панельных домов.

## 111-125: Северное шоссе 35/37/39

Специальная серия находится в `osm/facade_111_125.gd`. Она применяется только
к way IDs:

- `45836637` - Северное шоссе 39
- `45836638` - Северное шоссе 37
- `45836639` - Северное шоссе 35

Эти way IDs также описаны в `building_overrides.json`, где задана старая
flat texture, emissive mask, adaptive repeat, entrances и:

```json
"slot_extrusion": {
  "mid-balcony": {"depth_m": 0.8, "shape": "box"}
}
```

Для 111-125 используется отдельная жесткая логика:

- `TOTAL_FLOORS = 12`
- long side: длина edge >= 30 m
- short side: остальные edge >= 1 m
- seed фиксирован как `45836637`, поэтому все три дома получают одинаковое
  распределение вариантов atom textures
- long side имеет `LONG_UPPER` для этажей 2..12 и `LONG_GROUND` для первого
  этажа с entrance slots
- short side использует `SHORT = ["long-wall", "long-wall-decorative-window"]`

Это не JSON-архетип и не участвует в `FacadeAssembler.select_archetype()`.
По смыслу это эталонный ручной прототип, из которого потом вырос общий
словарь slots/molecules.

## Где именно рисуется окно или балкон

Для модульных фасадов окно/балкон - это alpha overlay поверх фонового wall
slot. Алгоритм в `FacadeAssembler._build_edge()`:

1. По role берется slot info из `SLOT_CATALOG`.
2. Рисуется фоновый quad на полный slot: от `t_left` до `t_right`, от
   `y_bot` до `y_top`.
3. Если у slot есть overlay, выбирается PNG overlay atom.
4. Размер overlay берется из реального размера PNG:
   - width in meters = `texture_width / 160 * slot_scale`
   - height in meters = `texture_height / 512 * floor_h`
5. Overlay центрируется по горизонтали в slot.
6. Верх overlay ставится на `y_top - overlay_offset_top_px / 512 * floor_h`.
7. Низ overlay = верх минус рассчитанная высота.

Значения offset по умолчанию:

- `window`: 80 px от верха этажа
- `mid-window`: 80 px от верха этажа
- `mid-balcony`: 0 px
- `long-balcony`: 0 px

У bricks `slot_overrides` меняет `window` и `mid-window` на offset 0 px.

Ночные окна в модульных фасадах работают через emission texture convention:
`window-1.png` ищет `window-emission-1.png` в той же папке. Если маска есть,
материал получает emission texture и участвует в night mode. Вероятность
свечения конкретного окна около 30%, детерминирована по seed/floor/edge/slot.

Старый `_add_building_windows()` с MultiMesh применяется к fallback-зданиям,
а не к фасадам, собранным `FacadeAssembler`.

## Extrusion балконов на 80 см

Extrusion задается в JSON как:

```json
"slot_extrusion": {
  "mid-balcony": {
    "depth_m": 0.8,
    "shape": "box"
  }
}
```

Когда slot role имеет overlay и для этой role есть extrusion:

1. Фоновая wall-текстура рисуется еще раз на передней плоскости на расстоянии
   `depth_m` от стены.
2. Overlay рисуется поверх этой передней плоскости на `depth_m + Z_OVERLAY`.
3. `_emit_balcony_box_sides()` строит top, bottom, left и right faces коробки.
4. Все faces используют тот же background atom, что и стена.

Extrusion ориентирован по outward normal edge: глубина 0.8 m означает выступ
наружу от стены на 80 см. Поддерживаемая shape сейчас только `box`. В 111-125
та же идея реализована отдельно в `_emit_balcony_box_sides_111()`.

Ограничение текущей конфигурации: почти все JSON задают extrusion только для
`mid-balcony`. Значит `long-balcony` визуально остается плоским, если явно не
добавить `slot_extrusion.long-balcony`.

## Что важно для автоматизации новых архетипов

1. Генератор архетипа должен создавать JSON и atom PNGs, а также проверять,
   что `wall` существует: `FacadeAssembler.has_atoms()` смотрит именно на
   `_resolved_atoms.wall[0]`.
2. Если нужна настоящая иерархия, ее стоит добавить явно: `parent` +
   merge atoms/molecules/metadata. Сейчас ссылки `{dir, files}` решают только
   частный случай наследования атомов.
3. `material_tags` стоит либо начать использовать в selection, либо убрать
   двусмысленность из будущего формата.
4. `balcony_placement` сейчас metadata. Для автоматизации лучше формализовать
   его как правило, которое меняет `overlay_offset_top_px` или slot layout.
5. Для серий без `mid-balcony`, но с выступающими длинными балконами, нужно
   задавать extrusion на `long-balcony`.
6. Нужно различать slot width tags (`wall`/`mid-wall`/`long-wall`) и edge tags
   (`short`/`long` molecules): это разные уровни системы.
7. Если архетип должен выглядеть одинаково на нескольких конкретных домах,
   как 111-125, нужен режим fixed seed. В общем `FacadeAssembler` seed равен
   `way_id`, поэтому разные дома одной серии получают разные atom variants.
