# OSM Racing - Development Documentation

## Запуск игры через консоль

### Команда для запуска игры
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/alekseiaksenov/osm-racing res://main.tscn
```

### Описание параметров
- `/Applications/Godot.app/Contents/MacOS/Godot` - путь к исполняемому файлу Godot
- `--path /Users/alekseiaksenov/osm-racing` - путь к проекту
- `res://main.tscn` - главная сцена игры для запуска

### Запуск в фоне
Для запуска в фоновом режиме:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/alekseiaksenov/osm-racing res://main.tscn 2>&1 &
```

### Остановка игры
Для остановки запущенной игры:
```bash
killall -9 Godot
```

### Перезапуск игры
Для полного перезапуска (остановка + запуск):
```bash
killall -9 Godot 2>/dev/null; sleep 1 && /Applications/Godot.app/Contents/MacOS/Godot --path /Users/alekseiaksenov/osm-racing res://main.tscn 2>&1 &
```

## Структура проекта

### Модели автомобилей
- `car/car_nexia.tscn` - Daewoo Nexia (легковой автомобиль)
- `car/car_paz.tscn` - ПАЗ-32053 (автобус)
- `car/models/nexia/` - 3D модель Nexia
- `car/models/paz_32053/` - 3D модель ПАЗ

### Система освещения
- `night_mode/car_lights.gd` - основной скрипт управления фарами
- Поддерживает несколько моделей автомобилей через enum CarModel
- Автоматически определяет модель и настраивает позиции фар

### Главная сцена
- `main.tscn` - основная игровая сцена
- Для смены модели автомобиля изменить path в `[ext_resource id="2_car"]`

## Добавление новой модели автомобиля

1. Создать папку в `car/models/название_модели/`
2. Скопировать glTF модель и текстуры
3. Создать setup скрипт `car/название_setup.gd`
4. Создать scene файл `car/car_название.tscn` с VehicleBody3D
5. Добавить модель в enum CarModel в `night_mode/car_lights.gd`
6. Настроить позиции фар для новой модели в `car_lights.gd`
7. Обновить `main.tscn` для использования новой модели

## Параметры физики автомобилей

### Nexia (легковой)
- Масса: 1400 кг
- Размер коллизии: 1.8×1.5×4.5 м
- Радиус колёс: 0.35 м

### ПАЗ (автобус)
- Масса: 5500 кг
- Размер коллизии: 2.5×2.8×7.0 м
- Радиус колёс: 0.45 м
