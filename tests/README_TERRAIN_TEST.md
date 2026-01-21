# Terrain Elevation Test

Тест проверяет корректность высот земли в игре.

## Что проверяет тест

1. **Физика машины**
   - Машина не проваливается сквозь землю
   - Машина остаётся выше порогового значения (-50м)
   - Собирает статистику движения машины

2. **Высоты дорог**
   - Дороги находятся на уровне земли
   - Допустимая погрешность: 0.5м
   - Находит и показывает дороги с ошибками высоты

3. **Высоты зданий**
   - Здания стоят на земле
   - Допустимая погрешность: 0.5м
   - Находит и показывает здания с ошибками высоты

## Запуск теста

```bash
# Из корня проекта
godot --path . tests/test_terrain_elevation_runner.tscn --headless
```

Или с визуализацией (без --headless):
```bash
godot --path . tests/test_terrain_elevation_runner.tscn
```

## Параметры теста

Можно изменить в `test_terrain_elevation.gd`:

- `_test_duration` - длительность теста (по умолчанию 10 секунд)
- `_fall_threshold` - порог падения машины (по умолчанию -50м)
- Допуск высоты в `_check_road_height()` и `_check_building_height()` (по умолчанию 0.5м)

## Параметры elevation в сцене

В `test_terrain_elevation_runner.tscn` настроены:
- `enable_elevation = true` - включена система высот
- `elevation_scale = 1.0` - реальный масштаб высот
- `elevation_grid_resolution = 16` - разрешение сетки высот

## Интерпретация результатов

### Успешный тест
```
[PASS] Terrain Elevation Test
Car stayed above ground (min_y=2.34)
All roads at correct height
All buildings at correct height
```

### Тест с ошибками
```
[FAIL] Terrain Elevation Test
Car stayed above ground (min_y=2.34)
Found 3 roads with height errors
  - Road at (123.4, 567.8): error=1.23m
Found 2 buildings with height errors
  - Building at (234.5, 678.9): error=0.87m
```

### Критический провал
```
[FAIL] Terrain Elevation Test
Car fell through ground! y=-51.23 (threshold=-50.00)
```

## Отладка

Если тест падает:

1. **Машина проваливается**
   - Проверьте коллизии меша земли
   - Проверьте что высоты правильно применяются к вершинам
   - Увеличьте `elevation_grid_resolution` для более точной геометрии

2. **Дороги на неправильной высоте**
   - Проверьте `_get_elevation_at_point()` в `osm_terrain_generator.gd`
   - Проверьте что дороги используют высоты из elevation data
   - Посмотрите на ошибки в логах: `[WARN] Road at ...`

3. **Здания на неправильной высоте**
   - Аналогично дорогам
   - Проверьте что базовая высота здания рассчитывается правильно

## Файлы теста

- `test_terrain_elevation.gd` - основной класс теста
- `test_terrain_elevation_runner.gd` - раннер для запуска теста
- `test_terrain_elevation_runner.tscn` - сцена с настройками
