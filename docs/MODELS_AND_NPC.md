# Модели машин и NPC трафик

## Обзор системы

Игра поддерживает несколько моделей автомобилей, которые могут использоваться как для игрока, так и для NPC трафика. Система построена на расширяемой архитектуре, позволяющей легко добавлять новые модели.

## Текущие модели

### 1. Daewoo Nexia
- **Файлы модели**: `car/models/nexia/scene.gltf`
- **Сцена игрока**: `car/car_nexia.tscn`
- **Сцена NPC**: `traffic/npc_car.tscn`
- **Скрипт настройки**: `car/nexia_setup.gd`
- **Физика**:
  - Масса: 1400 кг
  - Collision box: 1.9 × 1.2 × 4.6 м
  - Радиус колёс: 0.35 м
  - Позиция колёс: y=0.5
  - Центр масс: y=-0.4

**Особенности**:
- Модель масштабируется в 10 раз (transform scale 10.0)
- Автоматическая перекраска кузова в вишнёвый цвет
- Тонировка стёкол в тёмно-серый
- Колёса из модели используются для визуала

### 2. ПАЗ-32053 (автобус)
- **Файлы модели**: `car/models/paz_32053/scene.gltf`
- **Сцена игрока**: `car/car_paz.tscn`
- **Сцена NPC**: `traffic/npc_paz.tscn`
- **Скрипт настройки**: `car/paz_setup.gd`
- **Физика**:
  - Масса: 5500 кг
  - Collision box: 2.5 × 2.8 × 7.0 м
  - Радиус колёс: 0.55 м
  - Позиция колёс: y=0.8
  - Длина подвески: wheel_rest_length = 0.4
  - Центр масс: y=0.0
  - **Подъём модели**: y=0.3 (чтобы колёса были видны)

**Особенности**:
- Модель НЕ масштабируется (scale 1.0)
- Цвет кузова: жёлто-оранжевый (типичный для ПАЗ)
- Колёса из модели используются для визуала
- Позиция колёс поднята (y=0.8), но длина подвески нормальная (0.4)

## Архитектура системы моделей

### Определение типа модели

Система автоматически определяет тип модели по имени дочернего узла в `car_lights.gd`:

```gdscript
enum CarModel { DEFAULT, NEXIA, PAZ }

func _detect_car_model() -> void:
    for child in _car.get_children():
        if child.name == "NexiaModel":
            _car_model = CarModel.NEXIA
            return
        elif child.name == "PAZModel":
            _car_model = CarModel.PAZ
            return
    _car_model = CarModel.DEFAULT
```

### Специфичные настройки для моделей

Каждая модель имеет свои позиции для фар:

**Nexia**:
- Передние фары: (±0.55, 0.6, 1.8)
- Задние фары: (±0.45, 0.80, -2.0)

**ПАЗ**:
- Передние фары: (±0.55, 0.1, 2.3)
- Задние фары: (±0.55, -0.4, -2.4)

## Скрипты настройки моделей

### nexia_setup.gd

Функции:
- `_change_body_color()` - перекрашивает кузов в вишнёвый цвет
- `_find_all_meshes()` - рекурсивно находит все mesh'и в модели
- Автоматическое определение типа деталей (стекло, фары, колёса)
- Применение материалов с правильными настройками прозрачности

### paz_setup.gd

Функции:
- `_debug_print_meshes()` - выводит информацию о mesh'ах модели для отладки
- `_find_all_meshes()` - рекурсивно находит все mesh'и
- `_create_visual_wheels()` - (отключено) создание процедурных колёс

**Важно**: ПАЗ использует колёса из модели, процедурные не требуются.

## NPC трафик система

### TrafficManager (traffic/traffic_manager.gd)

**Константы**:
```gdscript
const MAX_NPCS := 40              // Максимум NPC одновременно
const SPAWN_DISTANCE := 200.0     // Радиус spawning от игрока
const DESPAWN_DISTANCE := 300.0   // Дистанция despawning
const MIN_SPAWN_SEPARATION := 35.0 // Мин. расстояние между NPC
const NPCS_PER_CHUNK := 3         // Машин на чанк
```

**Object Pooling**:
- `active_npcs` - активные NPC на дороге
- `inactive_npcs` - pool неактивных NPC для переиспользования

**Spawning логика**:
```gdscript
func _get_npc_from_pool():
    if inactive_npcs.size() > 0:
        # Берём из pool
        var npc = inactive_npcs.pop_back()
        npc.visible = true
        npc.process_mode = Node.PROCESS_MODE_INHERIT
        return npc

    if active_npcs.size() < MAX_NPCS:
        # Выбираем сцену (пример: 100% ПАЗов для теста)
        var scene_to_use: PackedScene = npc_paz_scene
        var npc = scene_to_use.instantiate()
        get_parent().add_child(npc)
        return npc
```

**Соотношение моделей NPC**:
Для баланса рекомендуется:
- 10% ПАЗы (автобусы)
- 90% обычные машины (Nexia и др.)

Для тестирования можно установить 100% одной модели.

## Добавление новой модели

### Шаг 1: Подготовка файлов модели

1. Создать папку `car/models/<название_модели>/`
2. Скопировать файлы модели (scene.gltf, текстуры)
3. Убедиться что модель импортирована в Godot

### Шаг 2: Создание setup скрипта

Создать `car/<название>_setup.gd`:

```gdscript
extends Node3D

var body_color := Color(1.0, 0.0, 0.0, 1.0)  # Красный пример

func _ready() -> void:
    await get_tree().process_frame
    _debug_print_meshes()
    print("Model setup complete")

func _debug_print_meshes() -> void:
    print("=== Model Meshes Debug ===")
    var meshes := _find_all_meshes(self)
    print("Total meshes found: ", meshes.size())
    for mesh in meshes:
        print("  - Mesh: ", mesh.name)

func _find_all_meshes(node: Node) -> Array:
    var meshes: Array = []
    if node is MeshInstance3D:
        meshes.append(node)
    for child in node.get_children():
        meshes.append_array(_find_all_meshes(child))
    return meshes
```

### Шаг 3: Создание сцены игрока

Создать `car/car_<название>.tscn`:

**Структура**:
```
[node name="Car" type="VehicleBody3D" groups=["car"]]
mass = <вес в кг>
collision_layer = 1
collision_mask = 7
center_of_mass_mode = 1
center_of_mass = Vector3(0, <y_offset>, 0)

[node name="<Название>Model" parent="." instance=<путь к scene.gltf>]
transform = Transform3D(1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0, 0, <y_offset>, 0)
script = ExtResource("<название>_setup.gd")

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, <y_position>, 0)
shape = SubResource("BoxShape3D_body")

[node name="WheelFL" type="VehicleWheel3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, <x>, <y>, <z>)
use_as_steering = true
wheel_radius = <радиус>
wheel_rest_length = <длина подвески>
...
```

**Важные параметры для настройки**:
- `mass` - масса автомобиля
- `center_of_mass` - центр масс (обычно ниже центра, y < 0)
- Позиция модели по Y - чтобы колёса были на правильной высоте
- `collision_layer` - слой 1 для игрока, 4 для NPC
- Позиции колёс - должны соответствовать модели

### Шаг 4: Создание сцены NPC

Создать `traffic/npc_<название>.tscn`:

Аналогично сцене игрока, но:
- `collision_layer = 4` (слой NPC)
- `script = ExtResource("npc_car.gd")`
- Без `EngineSound`, `CollisionSound`, `CarLights`

### Шаг 5: Добавление в систему освещения

В `night_mode/car_lights.gd` добавить:

1. В enum:
```gdscript
enum CarModel { DEFAULT, NEXIA, PAZ, <НОВАЯ_МОДЕЛЬ> }
```

2. В `_detect_car_model()`:
```gdscript
elif child.name == "<Название>Model":
    _car_model = CarModel.<НОВАЯ_МОДЕЛЬ>
    return
```

3. Добавить позиции фар в `_create_headlights()`:
```gdscript
elif _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    left_pos = Vector3(<x>, <y>, <z>)
    right_pos = Vector3(<x>, <y>, <z>)
```

4. Добавить позиции задних фонарей в `_create_taillights()`:
```gdscript
elif _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    left_pos = Vector3(<x>, <y>, <z>)
    right_pos = Vector3(<x>, <y>, <z>)
```

5. Добавить позиции mesh'ей фар в `_create_light_meshes()`:
```gdscript
elif _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    headlight_left_pos = Vector3(<x>, <y>, <z>)
    headlight_right_pos = Vector3(<x>, <y>, <z>)
    headlight_size = Vector3(<width>, <height>, <depth>)
```

### Шаг 6: Добавление в TrafficManager

В `traffic/traffic_manager.gd`:

1. Добавить переменную:
```gdscript
var npc_<название>_scene: PackedScene
```

2. Загрузить в `_ready()`:
```gdscript
npc_<название>_scene = preload("res://traffic/npc_<название>.tscn")
```

3. Добавить в `_get_npc_from_pool()`:
```gdscript
# Пример: 10% новая модель
var rand := randf()
if rand < 0.1:
    scene_to_use = npc_<название>_scene
elif rand < 0.2:
    scene_to_use = npc_paz_scene
else:
    scene_to_use = npc_car_scene
```

## Настройка физики колёс

### Ключевые параметры VehicleWheel3D

**Позиция колеса**:
- `transform.origin` - позиция в локальных координатах VehicleBody3D
- Обычно: передние колёса z > 0, задние z < 0

**Параметры колеса**:
- `wheel_radius` - радиус колеса (влияет на клиренс)
- `wheel_rest_length` - длина подвески в покое
- `wheel_friction_slip` - сцепление с дорогой (обычно 2.5-3.0)

**Подвеска**:
- `suspension_stiffness` - жёсткость (передние ~50-55, задние ~55-60)
- `suspension_max_force` - макс. сила подвески
- `suspension_travel` - ход подвески (обычно 0.25-0.3)
- `damping_compression` - демпфирование при сжатии
- `damping_relaxation` - демпфирование при разжатии

**Рулевое управление**:
- `use_as_steering = true` - для передних колёс
- `use_as_traction = true` - для задних колёс (привод)

### Типичные проблемы и решения

**Проблема**: Машина проваливается под землю
**Решение**:
- Проверить позицию колёс по Y
- Убедиться что `wheel_rest_length` достаточная
- Проверить что collision box не слишком низко
- Поднять визуальную модель (изменить y в transform модели)

**Проблема**: Колёса не видны
**Решение**:
- Убедиться что в модели есть mesh'и колёс
- Проверить что они не скрыты в setup скрипте
- Поднять позицию модели относительно VehicleBody3D
- Увеличить `wheel_radius` и поднять позицию колёс

**Проблема**: Машина не едет
**Решение**:
- Проверить что `use_as_traction = true` для ведущих колёс
- Проверить что `wheel_friction_slip` достаточный
- Убедиться что колёса касаются земли
- Проверить настройки подвески

**Проблема**: Машина слишком высоко "висит"
**Решение**:
- Уменьшить `wheel_rest_length`
- Опустить collision box
- Опустить центр масс
- Опустить позицию колёс по Y

## Collision Layers

- **Layer 1**: Машина игрока
- **Layer 2**: Дороги и здания
- **Layer 4**: NPC машины

**Collision Mask**:
- Машины: `7` (биты 1+2+4, взаимодействуют со всем)
- Статичная геометрия: `1+4` (взаимодействует с машинами)

## Отладка

### Debug Box

Каждая машина имеет полупрозрачный зелёный box для визуализации collision shape:

```gdscript
[node name="DebugBox" type="MeshInstance3D" parent="."]
visible = false  # Включить для отладки
mesh = SubResource("BoxMesh_debug")
```

Установить `visible = true` для визуализации collision box.

### Debug Print

В setup скриптах есть `_debug_print_meshes()` для вывода информации о mesh'ах модели.

### Логи TrafficManager

```gdscript
print("TrafficManager: Spawned NPC at %s" % npc.global_position)
print("TrafficManager: %d active NPCs" % active_npcs.size())
```

## Производительность

- **Object Pooling**: NPC переиспользуются вместо создания/удаления
- **Spawn Cooldown**: 1 секунда между spawning
- **Distance Culling**: NPC за пределами DESPAWN_DISTANCE удаляются
- **Chunk-based Spawning**: NPC spawning ограничен по чанкам

## Будущие улучшения

- [ ] Динамический выбор моделей NPC с весами
- [ ] Цветовые вариации для каждой модели
- [ ] Автоматическое определение позиций фар из модели
- [ ] Система лодов (LOD) для далёких NPC
- [ ] Больше типов машин (грузовики, легковые, спорткары)
