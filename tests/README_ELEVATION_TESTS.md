# Terrain Elevation Tests Suite

Набор тестов для проверки корректности системы высот в игре.

## Список тестов

### 1. Синтетический тест (рекомендуется для CI/CD)
**Файл:** `test_synthetic_terrain.gd`
**Запуск:** `./tests/run_synthetic_test.sh`

Быстрый детерминированный тест без загрузки OSM данных.

**Проверяет:**
- ✓ 5 платформ на разных высотах (0m, 5m, 10m, -3m, 7m)
- ✓ Raycast правильно определяет высоту земли
- ✓ Дороги размещаются на правильной высоте
- ✓ Здания размещаются на правильной высоте
- ✓ Физика машины работает корректно

**Время выполнения:** ~10 секунд
**Зависимости:** Нет (не требует интернет)

### 2. Тест наклонных поверхностей
**Файл:** `test_sloped_terrain.gd`
**Запуск:** `./tests/run_sloped_test.sh`

Проверяет размещение объектов на склонах.

**Проверяет:**
- ✓ 4 склона с разными углами (10°, 20°, 30°, 45°)
- ✓ Дороги выровнены по углу склона
- ✓ Здания стоят вертикально (не наклонены)
- ✓ Здания находятся на поверхности склона

**Время выполнения:** ~5 секунд
**Зависимости:** Нет

### 3. Интеграционный тест с OSM (WIP)
**Файл:** `test_terrain_elevation_runner.gd`
**Запуск:** `./tests/run_terrain_test.sh`

Полный тест с реальными OSM данными.

**Проверяет:**
- ✓ Загрузка высот из Open-Elevation API
- ✓ Машина не проваливается сквозь землю
- ✓ Дороги на уровне земли
- ✓ Здания стоят на земле

**Время выполнения:** ~30-40 секунд
**Зависимости:** Интернет (Open-Elevation API)

**Статус:** ⚠️ Обнаружен баг - дороги и здания на высоте 0.0м вместо ожидаемой высоты земли

## Запуск всех тестов

```bash
# Быстрые тесты (без интернета)
./tests/run_synthetic_test.sh && ./tests/run_sloped_test.sh

# Все тесты включая OSM
./tests/run_synthetic_test.sh && \
./tests/run_sloped_test.sh && \
./tests/run_terrain_test.sh
```

## Интерпретация результатов

### ✓ Успешный результат
```
[PASS] All terrain tests passed!
Total points tested: 5
Passed: 5
Failed: 0
```

### ✗ Провальный результат
```
[FAIL] 2 terrain tests failed

Failed points:
  - Low hill: expected=5.00m, measured=3.50m, error=1.500m
```

## Обнаруженные проблемы

### 1. Дороги и здания на высоте 0.0м
**Тест:** OSM Integration Test
**Описание:** При включённой системе высот (elevation) все дороги и здания размещаются на высоте 0.0м, игнорируя данные о высоте земли.

**Ожидаемое:** Дороги и здания должны быть на высоте земли согласно elevation data
**Фактическое:** Все объекты на y=0.0м
**Ошибка:** До 1.00м для разных объектов

**Необходимо исправить:**
- `_create_road_mesh_with_texture()` - использовать elevation data
- `_create_3d_building_with_texture()` - применять base_elev правильно
- Проверить что `_get_elevation_at_point()` вызывается и работает

## Следующие шаги

1. **Исправить размещение дорог и зданий** - использовать elevation data
2. **Добавить тесты для:**
   - Разные типы дорог (highway, residential, etc.)
   - Разные типы зданий
   - Мосты и туннели (если будут)
   - Переходы между разными высотами
3. **Оптимизация:**
   - Добавить бенчмарк-тесты производительности
   - Тестировать разные resolution для elevation grid

## Структура тестов

```
tests/
├── test_synthetic_terrain.gd          # Синтетический тест
├── test_synthetic_terrain.tscn
├── run_synthetic_test.sh
├── README_SYNTHETIC_TEST.md
│
├── test_sloped_terrain.gd             # Тест склонов
├── test_sloped_terrain.tscn
├── run_sloped_test.sh
│
├── test_terrain_elevation.gd          # OSM тест (класс)
├── test_terrain_elevation_runner.gd   # OSM тест (runner)
├── test_terrain_elevation_runner.tscn
├── run_terrain_test.sh
├── README_TERRAIN_TEST.md
│
└── README_ELEVATION_TESTS.md          # Этот файл
```

## Для разработчиков

### Добавление нового теста

1. Создайте файл `test_my_feature.gd`
2. Унаследуйтесь от Node3D
3. Реализуйте логику теста в `_ready()`
4. Используйте `get_tree().quit(0)` для успеха, `quit(1)` для провала
5. Создайте `.tscn` файл и скрипт запуска

### Соглашения

- Тесты должны быть автономными (не зависеть от порядка запуска)
- Выводить понятные сообщения об ошибках
- Использовать `print()` для логирования прогресса
- Завершаться с правильным exit code (0 = success, 1 = failure)

## CI/CD

Для CI/CD рекомендуется запускать:

```bash
# Быстрые тесты (< 20 секунд)
godot --path . tests/test_synthetic_terrain.tscn --headless
godot --path . tests/test_sloped_terrain.tscn --headless

# Полный тест (если есть интернет)
godot --path . tests/test_terrain_elevation_runner.tscn --headless
```
