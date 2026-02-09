# Decoration Layer

Система декораций поверх OSM данных. Позволяет добавлять билборды, переопределять текстуры зданий и другие элементы без изменения кода.

## Структура папок

```
decorations/
├── index.json                      # Главный индекс всех городов
├── README.md                       # Эта документация
└── russia/
    └── cherepovets/
        ├── meta.json               # Метаданные города
        ├── billboards.json         # Билборды
        ├── building_overrides.json # Переопределения зданий
        └── generators/             # Скрипты процедурной генерации (опционально)
```

## Файлы конфигурации

### index.json

Главный индекс, определяет какие города загружать.

```json
{
  "version": "1.0",
  "texture_base_path": "res://textures/",
  "sources": [
    {
      "id": "cherepovets",
      "name": "Череповец",
      "path": "russia/cherepovets/",
      "bounds": {
        "min_lat": 59.10,
        "max_lat": 59.18,
        "min_lon": 37.85,
        "max_lon": 38.05
      },
      "enabled": true
    }
  ]
}
```

| Поле | Тип | Описание |
|------|-----|----------|
| `texture_base_path` | string | Базовый путь для текстур (добавляется к относительным путям) |
| `sources[].id` | string | Уникальный идентификатор города |
| `sources[].path` | string | Путь к папке города относительно `decorations/` |
| `sources[].bounds` | object | Границы города (lat/lon) для ленивой загрузки |
| `sources[].enabled` | bool | Включить/выключить загрузку города |

### meta.json (город)

Метаданные конкретного города.

```json
{
  "name": "Череповец",
  "region": "Вологодская область",
  "country": "Россия",
  "center": [59.13, 37.93],
  "files": [
    "billboards.json",
    "building_overrides.json"
  ],
  "generators": [],
  "settings": {
    "billboard_density": 1.0,
    "default_lamp_color": "#FFE4B5"
  }
}
```

| Поле | Тип | Описание |
|------|-----|----------|
| `files` | array | Список JSON файлов для загрузки |
| `generators` | array | Список GDScript генераторов (пока не реализовано) |
| `settings` | object | Настройки города (для будущего использования) |

---

## Билборды (billboards.json)

```json
{
  "billboards": [
    {
      "id": "mvideo_severnoe",
      "comment": "МВидео / Лада у Северного шоссе",
      "lat": 59.14986,
      "lon": 37.952547,
      "rotation_deg": -90,
      "size": [6.0, 3.35],
      "pole_height": 4.0,
      "texture": "billboards/mvideo-banner.jpg",
      "texture_back": "billboards/lada-banner.jpg",
      "backlight": true,
      "emission": 0.3
    }
  ]
}
```

### Поля билборда

| Поле | Тип | По умолчанию | Описание |
|------|-----|--------------|----------|
| `id` | string | — | Уникальный идентификатор (для отладки) |
| `comment` | string | — | Комментарий (игнорируется) |
| `lat` | float | **обязательно** | Широта (latitude) |
| `lon` | float | **обязательно** | Долгота (longitude) |
| `rotation_deg` | float | 0 | Поворот в градусах (по часовой = отрицательное) |
| `size` | [w, h] | [4.0, 3.0] | Размер в метрах [ширина, высота] |
| `pole_height` | float | 3.0 | Высота столба в метрах |
| `texture` | string | — | Путь к текстуре передней стороны |
| `texture_back` | string | — | Путь к текстуре задней стороны |
| `text` | string | — | Текст (если нет текстуры) |
| `background` | string | "#FFFFFF" | Цвет фона в hex (для текстовых билбордов) |
| `text_color` | string | "#000000" | Цвет текста в hex |
| `backlight` | bool | true | Подсветка ночью |
| `emission` | float | 0.5 | Сила свечения (0.0 - 1.0) |

### Примеры билбордов

**С текстурой:**
```json
{
  "id": "coca_cola_1",
  "lat": 59.15,
  "lon": 37.95,
  "rotation_deg": 45,
  "size": [6.0, 3.0],
  "texture": "billboards/coca-cola.jpg"
}
```

**С текстом:**
```json
{
  "id": "sale_banner",
  "lat": 59.14,
  "lon": 37.94,
  "size": [5.0, 2.5],
  "text": "РАСПРОДАЖА",
  "background": "#FF0000",
  "text_color": "#FFFFFF"
}
```

**Двусторонний с разными картинками:**
```json
{
  "id": "double_sided",
  "lat": 59.13,
  "lon": 37.93,
  "rotation_deg": -90,
  "size": [6.0, 3.35],
  "texture": "billboards/front.jpg",
  "texture_back": "billboards/back.jpg"
}
```

---

## Переопределения зданий (building_overrides.json)

Позволяет заменить текстуру конкретного здания по его OSM way ID.

```json
{
  "building_overrides": [
    {
      "osm_way_id": 45836637,
      "comment": "39 Северное шоссе",
      "wall_texture": "buildings/my-building.png",
      "wall_emissive": "buildings/my-building_emissive.png",
      "repeat_y": 2.0,
      "adaptive_repeat": {
        "enabled": true,
        "short": 1.0,
        "long": 3.0
      }
    }
  ]
}
```

### Поля переопределения

| Поле | Тип | По умолчанию | Описание |
|------|-----|--------------|----------|
| `osm_way_id` | int | **обязательно** | OSM way ID здания |
| `comment` | string | — | Комментарий (адрес, название) |
| `wall_texture` | string | — | Текстура стен |
| `wall_emissive` | string | — | Emissive маска для окон |
| `repeat_y` | float | 1.0 | Повторение текстуры по вертикали |
| `adaptive_repeat` | object | — | Адаптивное повторение по длине стены |

### Адаптивное повторение

Автоматически подбирает количество повторений текстуры в зависимости от длины стены:

```json
"adaptive_repeat": {
  "enabled": true,
  "short": 1.0,   // Повторений на коротких стенах
  "long": 3.0     // Повторений на длинных стенах
}
```

### Как найти OSM way ID

1. Открыть [OpenStreetMap](https://www.openstreetmap.org/)
2. Найти нужное здание
3. Кликнуть на него → в URL появится `way/12345678`
4. Число `12345678` — это way ID

---

## Добавление нового города

1. Создать папку: `decorations/russia/moscow/`
2. Создать `meta.json`:
```json
{
  "name": "Москва",
  "files": ["billboards.json"]
}
```
3. Создать `billboards.json` с массивом билбордов
4. Добавить город в `index.json`:
```json
{
  "id": "moscow",
  "path": "russia/moscow/",
  "bounds": { ... },
  "enabled": true
}
```

---

## Пути к текстурам

Все пути к текстурам **относительные** от `texture_base_path` (по умолчанию `res://textures/`).

```
texture: "billboards/coca-cola.jpg"
→ res://textures/billboards/coca-cola.jpg

wall_texture: "buildings/school.png"
→ res://textures/buildings/school.png
```

---

## Загрузка и порядок

1. При старте `DecorationLayer` читает `index.json`
2. Для каждого `enabled` города загружается `meta.json`
3. Файлы из `meta.files` парсятся и создаются объекты
4. Строится spatial index для быстрого поиска

Декорации загружаются **один раз** при старте игры. Для hot-reload нужен перезапуск.

---

## Отладка

В консоли Godot выводится:
```
DecorationLayer: Loaded 2 billboards, 5 building overrides from JSON
```

При ошибках парсинга:
```
DecorationLayer: JSON parse error in res://decorations/.../file.json at line 15: Expected ','
```
