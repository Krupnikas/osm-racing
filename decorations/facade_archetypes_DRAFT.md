# Архетипы фасадов — черновик для заполнения

> **Назначение:** описать архетипы фасадов так, чтобы движок мог
> процедурно выбирать материалы и компоновать стены для любого здания,
> у которого нет специфического override'а (как 111-125-12 для Северного
> Шоссе 35/37/39).
>
> **Что от тебя нужно:** в каждой секции
> 1. подтвердить/исправить атомы (я их выудил из папок),
> 2. заполнить _Metadata_ (material, geography, min/max этажей),
> 3. описать _Molecules_ — паттерны слотов, которые имеет смысл соседствовать,
> 4. ответить на _Open questions_ внизу каждой секции.

---

## 0. Глобальный реестр архетипов

| Archetype ID | Parent | Category | building:material | Geography | Min floors | Max floors | Status |
|---|---|---|---|---|---|---|---|
| `default-panels-1` | _(none)_ | panel | `panel`, `large_panel` | Череповец | 2 | 20 | base |
| `default-bricks-1` | _(none)_ | brick | `brick` | Череповец | 1 | 20 | base |
| `default-panel-brown` | `default-panels-1` | panel | (наследует) | Череповец | 2 | 20 | colour variant |
| `default-panel-pear` | `default-panels-1` | panel | (наследует) | Череповец | 2 | 20 | colour variant |
| `default-panel-pebble` | `default-panels-1` | panel | (наследует) | Череповец | 2 | 20 | colour variant |
| `default-panel-yellow` | `default-panels-1` | panel | (наследует) | Череповец | 2 | 20 | colour variant |
| `panel-concrete-series-1` | `default-panels-1` | panel | `panel`, `large_panel` | Череповец | 2 | 20 | special series |
| `panel-concrete-series-2` | `default-panels-1` | panel | `panel`, `large_panel` | Череповец | 2 | 20 | special series |
| `111-125-12` (existing) | — | panel | (hardcoded for ways 45836637/8/9) | Череповец | 12 | 12 | manual override, не трогаем |

> **Геогр-замечание (на будущее):** сейчас все архетипы — Череповец.
> Позже добавится более специфический override: «если way лежит в районе
> X (даже в Череповце), применяй архетип Y». Сейчас это не реализуем,
> но движок-сборщик нужно проектировать так, чтобы такая иерархия
> разрешений «город → район → конкретный way» подтягивалась без
> переписывания.
>
> **Правило выбора архетипа (внутри одной material-категории):**
> если у OSM-дома `building:material=panel` (или `large_panel`), движок
> выбирает один из применимых архетипов (`default-panel-brown`,
> `…-pear`, `…-pebble`, `…-yellow`, `panel-concrete-series-1`,
> `panel-concrete-series-2`) **случайно по хешу way_id**. Никакого
> OSM-сигнала, специфичного для series-1 или series-2, не существует —
> они равноправны с цветовыми вариантами base'а.
>
> **Правило целостности внутри здания:** молекулы для конкретного дома
> собираются **только из одного архетипа и одного цвета**. Нельзя
> смешивать `default-panel-brown` с `default-panel-pear` в одном
> фасаде. Архетип выбирается раз по way_id и применяется ко всем
> сторонам здания.

---

## 1. Slot / role naming (справочно)

**Backgrounds (opaque):**
- `wall` — 1 bay (≈ 3.2 m)
- `mid-wall` — 1.5 bay (≈ 4.8 m)
- `long-wall` — 2 bay (≈ 6.4 m)

**Overlays (alpha):**
- `window` — обычное окно, на `wall`
- `mid-window` — большое окно, на `mid-wall`
- `mid-balcony` — стандартный балкон, на `mid-wall`
- `long-balcony` — широкий балкон, на `long-wall`

**Seams (alpha):**
- `horizontal-seam` (под `wall`-шириной)
- `horizontal-mid-seam` (под `mid-wall`)
- `horizontal-long-seam` (под `long-wall`)
- `vertical-seam` (тонкий вертикальный)

**Crown atoms (новые, замечены только в `panel-concrete-series-*`):**
- `roofbottom` — ободок над верхним этажом, под крышей (ширина 1 bay)
- `long-roofbottom` — то же, но 2 bay
- Рисуются после последнего этажа в отдельной горизонтальной полосе.
  По ширине следует логике стен (под `wall` → `roofbottom`, под
  `long-wall` → `long-roofbottom`).

---

## 2. `default-panels-1`

### Metadata
| Field | Value |
|---|---|
| Category | panel |
| Parent | _(base)_ |
| building:material | `panel`, `large_panel` |
| Geography (cities/regions) | Череповец |
| Min floors | 2 |
| Max floors | 20 |
| Balcony placement | `centre` |
| Has entrance overlay | **NO** (по тз: общие дома без entrance, только shop entrances из существующей системы) |

### Цветовые варианты
Найдено 4 цвета: `brown`, `pear`, `pebble`, `yellow`. Каждый — отдельный
архетип-наследник (см. реестр выше). Цвет влияет на: `wall`, `mid-wall`,
`long-wall`, все горизонтальные швы, вертикальный шов. **Окна и балконы
не цветовые** — они общие.

### Атомы

| Slot | Цветовые варианты (per colour) | Общие | Найдено в папке |
|---|---|---|---|
| `wall` | `wall-{brown,pear,pebble,yellow}-1` | — | по 1 варианту на цвет |
| `mid-wall` | `mid-wall-{brown,pear,pebble,yellow}-1` | — | по 1 |
| `long-wall` | `long-wall-{brown,pear,pebble,yellow}-1` | — | по 1 |
| `window` | — | `window-1..6` | 6 общих |
| `mid-window` | — | `mid-window-1..6` | 6 общих |
| `mid-balcony` | — | `mid-balcony-1..5` | 5 общих |
| `long-balcony` | — | `long-balcony-1..6` | 6 общих |
| `horizontal-seam` | `horizontal-seam-{brown,pear,pebble,yellow}-1` | — | по 1 на цвет |
| `horizontal-mid-seam` | `horizontal-mid-seam-{brown,pear,pebble,yellow}-1` | — | по 1 |
| `horizontal-long-seam` | `horizontal-long-seam-{brown,pear,pebble,yellow}-1` | — | по 1 |
| `vertical-seam` | `vertical-seam-{brown,pear,pebble,yellow}-1` | — | по 1 |

### Molecules
> Заполни. Каждый паттерн = одна "молекула" — последовательность ролей,
> которая имеет смысл стоять рядом. Движок будет покрывать стену
> молекулами, подбирая по ширине так, чтобы суммарная длина была ≈ длине
> стороны OSM-полигона. Поле "Nominal width" предзаполнено из суммы
> ширин атомов (3.2 / 4.8 / 6.4 м).

| Molecule ID | Pattern (left → right) | Nominal width (m) | Notes |
|---|---|---|---|
| `panel-win-bal-win` | window, mid-balcony, window | 11.2 | пример из 111-125 |
| `panel-win-win` | window, window | 6.4 | |
| `panel-bal-trio` | window, long-balcony, window | 12.8 | |
| `panel-mid-pair` | mid-wall, mid-wall | 9.6 | торцевая молекула |
| `panel-wall-win-wall` | wall, window, wall | 9.6 | |
| `…` | _добавь свои_ | | |

### Corner / угловые молекулы
> Что должно быть на самом краю стороны (угол здания)?

| Pattern | Notes |
|---|---|
| _e.g. `mid-wall`_ | торец прямоугольной панельной коробки |
| TODO | |

### Open questions (resolved)
1. ~~Какие OSM `building:material` теги?~~ → `panel`, `large_panel`.
2. **По цветам:** одинаковые ли molecules у разных цветов? Сейчас
   считаем, что молекулы общие на уровне `default-panels-1`, а цвет
   просто меняет текстуры — другими словами, цветовой вариант
   подмешивает только палитру, а паттерны компоновки общие. Если у
   тебя в голове разные паттерны для разных цветов — скажи, и я
   разнесу molecules по дочерним архетипам.

---

## 3. `default-bricks-1`

### Metadata
| Field | Value |
|---|---|
| Category | brick |
| Parent | _(base)_ |
| building:material | `brick` |
| Geography | Череповец |
| Min floors | 1 |
| Max floors | 20 |
| Balcony placement | **`top-of-long-wall`** (важное отличие от panel: балкон рисуется в верхней части long-wall, низ long-wall — это сам экран ограждения балкона; кирпичная текстура одинакова, балкон сам по себе на ней) |
| Has entrance overlay | **NO** |
| Has seams | **NO** (кирпичные стены без панельных швов) |
| Color variants | **NONE** найдено в папке (single texture set) |

### Атомы

| Slot | Файлы | Найдено | Заметка |
|---|---|---|---|
| `wall` | `wall-1` | 1 | |
| `mid-wall` | `mid-wall-1` | 1 | |
| `long-wall` | `long-wall-1` | 1 | низ играет роль экрана ограждения балкона |
| `window` | `window-1..5` | 5 | (не 6 как у панелей) |
| `mid-window` | — | **0** | сознательно отсутствует — кирпичи используют только обычные `window` (центрированные на mid-wall, если надо) |
| `mid-balcony` | `mid-balcony-1..6` | 6 | |
| `long-balcony` | `long-balcony-1..6` | 6 | overlay'ится сверху на long-wall (см. balcony_placement) |
| Все швы | — | — | архетип без швов |

### Molecules
| Molecule ID | Pattern | Nominal width (m) | Notes |
|---|---|---|---|
| `brick-win-pair` | window, window | 6.4 | |
| `brick-balcony-stack` | long-balcony | 6.4 | долгий балкон в одиночку |
| `brick-mid-bal-pair` | mid-balcony, mid-balcony | 9.6 | |
| `…` | TODO | | |

### Corner / угловые молекулы
| Pattern | Notes |
|---|---|
| TODO | |

### Open questions (resolved)
1. ~~5 window-вариантов вместо 6 — OK?~~ → ОК. Любое количество
   вариантов — на что хватило фантазии автора.
2. ~~Какой OSM-тег?~~ → только `brick`.

---

## 4. `panel-concrete-series-1`

### Metadata
| Field | Value |
|---|---|
| Category | panel (особая разновидность) |
| Parent | `default-panels-1` |
| building:material | `panel`, `large_panel` (как и base) |
| Geography | Череповец |
| Min floors | 2 |
| Max floors | 20 |
| Color | `pebble` (только) |
| Balcony placement | `centre` (если не задано иначе) |
| Has crown / roofbottom | **YES** (новые атомы `roofbottom`, `long-roofbottom`) |
| Forbidden sizes | `mid-wall`, `mid-window`, `mid-balcony`, `horizontal-mid-seam` — **не использовать** в этом архетипе |

> **Селекция:** этот архетип попадает в пул выбора для всех домов с
> `building:material=panel` или `large_panel`. Выбирается случайно по
> хешу way_id наравне с цветовыми вариантами base'а. Никакого
> специального OSM-сигнала.

### Атомы

| Slot | Файлы | Источник | Заметка |
|---|---|---|---|
| `wall` | `wall-pebble-1` | local | переопределяет default |
| `mid-wall` | — | **FORBIDDEN** | нет атома — нельзя использовать |
| `long-wall` | `long-wall-pebble-1` | local | |
| `window` | _(inherit)_ `window-1..6` | parent (default-panels-1) | используем оттуда |
| `mid-window` | — | **FORBIDDEN** | |
| `mid-balcony` | — | **FORBIDDEN** | |
| `long-balcony` | `long-balcony-1..5` | local | переопределяет default (там 6, тут 5) |
| `horizontal-seam` | `horizontal-seam-pebble-1` | local | |
| `horizontal-mid-seam` | — | **FORBIDDEN** | |
| `horizontal-long-seam` | `horizontal-long-seam-pebble-1` | local | |
| `vertical-seam` | `vertical-seam-pebble-1` | local | |
| `roofbottom` | `roofbottom-1` | local | ободок над верхним этажом, под крышей; ширина = `wall` |
| `long-roofbottom` | `long-roofbottom-1` | local | то же, ширина = `long-wall` |

### Molecules
> Поскольку mid-* запрещены, паттерны строятся только из `wall (3.2)` и
> `long-wall (6.4)` ширин.

| Molecule ID | Pattern | Nominal width (m) | Notes |
|---|---|---|---|
| `concrete1-win-bal-win` | window, long-balcony, window | 12.8 | |
| `concrete1-bal-only` | long-balcony | 6.4 | |
| `concrete1-win-pair` | window, window | 6.4 | |
| `…` | TODO | | |

### Corner / угловые молекулы
| Pattern | Notes |
|---|---|
| TODO | |

### Crown / roofbottom
Семантика подтверждена: это **ободок над верхним этажом, под крышей**.
Рисуется как отдельная горизонтальная полоса после самого верхнего
этажа. Ширина каждого сегмента совпадает с шириной нижестоящего слота:
под `wall` рисуется `roofbottom`, под `long-wall` — `long-roofbottom`.

### Open questions
1. ~~Откуда узнать, что нужен именно series-1?~~ → если material `panel`
   / `large_panel`, **случайно** выбираем один из применимых архетипов
   (включая series-1, series-2 и цветовые варианты base'а) по хешу
   way_id. Никакого специального признака для series-1 нет.
2. **Открыт:** все 5 `long-balcony-N` здесь — те же самые, что у
   `default-panels-1`, или другие (другой стиль)? Если другие — это
   локальный override (так и оставляем). Если случайно совпадают —
   можем не класть локально и наследовать.

---

## 5. `panel-concrete-series-2`

### Metadata
| Field | Value |
|---|---|
| Category | panel (особая разновидность) |
| Parent | `default-panels-1` |
| building:material | `panel`, `large_panel` (как и base) |
| Geography | Череповец |
| Min floors | 2 |
| Max floors | 20 |
| Color | без цветового суффикса (цвет не категорируется в этой серии) |
| Balcony placement | `centre` |
| Has crown / roofbottom | **YES** |
| Forbidden sizes | `mid-wall`, `mid-window`, `mid-balcony`, `horizontal-mid-seam` |

> **Селекция:** ровно как у `panel-concrete-series-1` — попадает в пул
> выбора для `building:material=panel`/`large_panel`, выбирается
> случайно по хешу way_id.

### Атомы

| Slot | Файлы | Источник | Заметка |
|---|---|---|---|
| `wall` | `wall-1` | local | |
| `mid-wall` | — | **FORBIDDEN** | |
| `long-wall` | `long-wall-1` | local | |
| `window` | _(inherit)_ | parent | |
| `mid-window` | — | **FORBIDDEN** | |
| `mid-balcony` | — | **FORBIDDEN** | |
| `long-balcony` | `long-balcony-1..4` | local | 4 варианта (меньше чем series-1) |
| `horizontal-seam` | `horizontal-seam-1` | local | |
| `horizontal-mid-seam` | — | **FORBIDDEN** | |
| `horizontal-long-seam` | `horizontal-long-seam-1` | local | |
| `vertical-seam` | `vertical-seam-1` | local | |
| `roofbottom` | `roofbottom-1` | local | |
| `long-roofbottom` | `long-roofbottom-1` | local | |

### Molecules
| Molecule ID | Pattern | Nominal width (m) | Notes |
|---|---|---|---|
| TODO | TODO | | |

### Corner / угловые молекулы
| Pattern | Notes |
|---|---|
| TODO | |

### Open questions (resolved)
- ~~Цветовой суффикс отсутствует — нейтральный?~~ → Цвет неважен; серия
  без цветового деления.
- ~~Только 4 `long-balcony` (vs 5 у series-1, 6 у default-panels) —
  специально?~~ → Любое количество вариантов нормально.

Селекция тоже та же, что у series-1.

---

## 6. Сводные open questions

### Resolved
- **(1) Default building selection.**
  - Step 1: `building:material` → категория (`panel`/`large_panel` →
    panel; `brick` → brick).
  - Step 2: внутри категории — случайно выбирается архетип
    (включая цветовые варианты base'а и `panel-concrete-series-*`)
    по хешу way_id.
  - Step 3: если material тег отсутствует или не из списка — пока
    fallback оставляем «не процедурный фасад» (рисуем как сейчас,
    дефолтной плоской текстурой). Позже можно добавить fallback по
    тегу `building=residential` + height/floors.
- **(2) Series-1/2 selection.** ↑ Решено в (1). Никаких
  OSM-признаков — равноправный участник пула.
- **(3) `roofbottom` семантика.** Ободок над верхним этажом, под
  крышей. Это новая верхняя полоса фасада (НЕ часть `roof_y`
  системы). Применяется только в архетипах, где есть атомы
  `roofbottom`/`long-roofbottom` (сейчас — `panel-concrete-series-*`).
- **(7) Brown без своего шва.** Уже дорезан (`horizontal-seam-brown-1`
  есть в папке). Закрыто.

### Open
- **(4) Этажность.** Подтверди: дом OSM с 9 этажами → ищем архетип,
  у которого 9 ∈ [min, max]. Если подходит несколько — случайно по
  хешу way_id. Если ни один — fallback (см. (1) step 3). ОК?
- **(5) Молекулы и торцы.** Long side vs short side: один пул
  молекул, движок сам подбирает по ширине? Или раздельные пулы
  («short-side molecules», «long-side molecules»)? Я бы предложил
  начать с одного пула + помечать молекулы тегом `short_only` /
  `long_only` / `any` при необходимости.
- **(6) Ground floor.** Тот же пул, что upper? Или отдельный (на
  ground больше «глухой стены», меньше балконов)?

---

## 7. Что делать дальше

Когда заполнишь:
1. Я переведу таблицу в JSON-схемы (один файл на архетип, `decorations/.../facades/{id}.json`).
2. Напишу `facade_assembler.gd` (универсальный), который:
   - грузит архетип по id (или по матчингу material/geography),
   - резолвит атомы через parent-цепочку,
   - выбирает molecules под длину стены,
   - применяет правила balcony_placement, forbidden sizes, и т.д.
3. Существующий `facade_111_125.gd` останется для конкретных way 35/37/39 (как «архетип 111-125-12» с захардкоженным рецептом). 15-я Северного шоссе и Окинина 8 (если есть) — не трогаю.
4. Все остальные жилые дома без override начнут получать процедурный фасад.

Общие молекулы по типам домов
bricks 
	- wall - window
	- wall - window - window
	- window - window
	- window - mid-balcony - window
	- window - mid-balcony - mid-balcony - window
	- window - window - long-balcony - window - window
	- long-balcony - window - mid-balcony - window - balcony
	- long-balcony - window - mid-balcony - window - window - mid-balcony - window - balcony

panels 
	- wall - window
	- window - wall - wall - window
	- window - window
	- window - mid-balcony - window
	- window - mid-balcony - mid-balcony - window
	- mid-balcony - window - window
	- mid-balcony - window - window - window
	- mid-balcony - window - window - window - mid-balcony - window - window
	- mid-window - window - window
	- mid-window - window - window - window
	- mid-window - window - window - window - mid-window - window - window
	- window - window - long-balcony - window - window
	- long-balcony - window - mid-balcony - window - balcony
	- long-balcony - window - mid-balcony - window - window - mid-balcony - window - balcony