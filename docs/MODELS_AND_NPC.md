# Модели машин и NPC трафик

## Обзор системы

Игра поддерживает несколько моделей автомобилей, которые могут использоваться как для игрока, так и для NPC трафика. Система построена на расширяемой архитектуре с единым базовым классом физики.

## Архитектура

### Иерархия классов

```
VehicleBase (car/vehicle_base.gd)
├── Car (car/car.gd) - Автомобиль игрока
└── NPCCar (traffic/npc_car.gd) - NPC трафик
```

### VehicleBase - Базовый класс

**Путь**: `car/vehicle_base.gd`

**Ответственность**:
- Общая физика колёс (сбор, настройка traction)
- Расчёт крутящего момента и RPM
- Применение рулежки с учётом скорости
- Применение сил двигателя и тормозов
- Автоматическая КПП
- Расчёт скорости

**Абстрактные методы** (реализуются в наследниках):
```gdscript
func _get_steering_input() -> float  # Рулежка [-1.0 .. 1.0]
func _get_throttle_input() -> float  # Газ [0.0 .. 1.0]
func _get_brake_input() -> float     # Тормоз [0.0 .. 1.0]
```

**Экспортируемые параметры**:
- Двигатель: `max_engine_power`, `max_rpm`, `idle_rpm`, `gear_ratios`, `final_drive`
- Руление: `max_steering_angle`, `steering_speed`, `steering_return_speed`
- Тормоза: `brake_force`

### Car - Автомобиль игрока

**Путь**: `car/car.gd`

**Дополнительные возможности**:
- Input от клавиатуры (стрелки/WASD)
- Ручной тормоз (пробел)
- Тип привода (RWD/FWD/AWD)
- TCS (антипробуксовочная система)
- ESC (система стабилизации)
- Сигналы для UI

**Реализация абстрактных методов**:
```gdscript
func _get_steering_input() -> float:
    return Input.get_axis("ui_right", "ui_left")

func _get_throttle_input() -> float:
    return 1.0 if Input.is_action_pressed("ui_up") else 0.0

func _get_brake_input() -> float:
    # Обычный тормоз или ручной
    if handbrake_input > 0.1:
        return handbrake_input * handbrake_force / brake_force
    return brake_input
```

### NPCCar - NPC трафик

**Путь**: `traffic/npc_car.gd`

**Дополнительные возможности**:
- Pure Pursuit steering algorithm
- Waypoint navigation
- Obstacle detection
- AI driver behavior (cautious driving)
- Path extension
- Random color variation

**Реализация абстрактных методов**:
```gdscript
func _get_steering_input() -> float:
    return steering_input  # Рассчитан в _update_ai_driver()

func _get_throttle_input() -> float:
    return throttle_input  # Рассчитан в _update_ai_driver()

func _get_brake_input() -> float:
    return brake_input  # Рассчитан в _update_ai_driver()
```

**AI параметры**:
- `LOOKAHEAD_MIN`: 8.0 - минимальный lookahead для Pure Pursuit
- `LOOKAHEAD_MAX`: 20.0 - максимальный lookahead
- `CAUTIOUS_FACTOR`: 0.8 - осторожное вождение (80% от лимита)
- `UPDATE_INTERVAL`: 0.1 - обновление AI каждые 100ms

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

### 2. Lada 2109 DPS (полиция)
- **Файлы модели**: `car/models/lada_2109_dps/scene.gltf`
- **Сцена NPC**: `traffic/npc_lada_2109.tscn`
- **Скрипт настройки**: `car/lada_2109_setup.gd`
- **Физика**:
  - Масса: 1400 кг
  - Collision box: 1.68 × 1.2 × 4.33 м
  - Радиус колёс: 0.32 м
  - Позиция колёс: y=0.5
  - Центр масс: y=-0.3

**Особенности**:
- Модель масштабируется в 0.1 раз (scale -0.1 по X и Z для разворота)
- Использует ноду "Model" для определения типа

### 3. Lada 2109 Такси
- **Файлы модели**: `car/models/lada_2109_taxi/scene.gltf`
- **Сцена игрока**: `car/car_taxi.tscn`
- **Сцена NPC**: `traffic/npc_taxi.tscn`
- **Скрипт настройки**: `car/lada_2109_setup.gd`
- **Физика**: Идентична DPS версии

**Особенности**:
- Жёлтая текстура такси с шашечками на крыше
- Использует ту же ноду "Model" - система освещения определяет как LADA_2109

### 4. ПАЗ-32053 (автобус)
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
enum CarModel { DEFAULT, NEXIA, PAZ, LADA_2109 }

func _detect_car_model() -> void:
    for child in _car.get_children():
        if child.name == "NexiaModel":
            _car_model = CarModel.NEXIA
            return
        elif child.name == "PAZModel":
            _car_model = CarModel.PAZ
            return
        elif child.name == "Model":
            # Lada 2109 (taxi, DPS) uses "Model" node name
            _car_model = CarModel.LADA_2109
            return
    _car_model = CarModel.DEFAULT
```

### Специфичные настройки для моделей

Каждая модель имеет свои позиции для фар:

**Nexia**:
- Передние фары: (±0.55, 0.6, 1.8)
- Задние фары: (±0.45, 0.80, -2.0)

**Lada 2109**:
- Передние фары: (±0.5, 0.6, 2.15)
- Задние фары: (±0.35, 0.55, -2.05)

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

**Соотношение моделей NPC** (текущее):
- 5% Lada 2109 DPS (полиция)
- 15% Lada 2109 Такси
- 20% ПАЗы (автобусы)
- 60% блочные машинки

**На парковках**:
- 60% блочные машинки
- 20% Lada 2109 Такси
- 20% Lada 2109 DPS

## Система освещения NPC

### Раздельные фары для реальных моделей

NPC машины используют `npc_car_lights.gd` который автоматически создаёт фары.

**Блочные машинки** используют одну центральную фару:
- Одна передняя фара по центру (x=0)
- Одна задняя фара по центру (x=0)

**Реальные модели** (Nexia, PAZ, Lada 2109) используют раздельные фары:
- Две передние фары (левая и правая)
- Две задние фары (левая и правая)

Система автоматически определяет тип по флагу `_use_split_lights`:
```gdscript
var _use_split_lights := false

func _create_headlight() -> void:
    if _car_model == CarModel.LADA_2109:
        _use_split_lights = true
        var left_pos = Vector3(-0.5, 0.6, 2.15)
        var right_pos = Vector3(0.5, 0.6, 2.15)
        headlight_left = _create_single_headlight("NPCHeadlightL", left_pos)
        headlight_right = _create_single_headlight("NPCHeadlightR", right_pos)
        return
    # ... другие модели

    # Блочные машинки - одна центральная фара
    headlight = _create_single_headlight("NPCHeadlight", Vector3(0, 0.55, 2.1))
```

### Синхронизация с car_lights.gd

**ВАЖНО**: Позиции фар в `npc_car_lights.gd` должны быть синхронизированы с `car_lights.gd`.

При добавлении новой модели нужно обновить оба файла:
1. `night_mode/car_lights.gd` - фары игрока
2. `night_mode/npc_car_lights.gd` - фары NPC

## Добавление новой модели

### Обзор процесса

Добавление новой модели не требует дублирования физики - все модели используют VehicleBase. Необходимо только:
1. Подготовить 3D модель (GLTF)
2. Создать setup скрипт для настройки внешнего вида
3. Создать сцены для player и NPC (если нужно)
4. Настроить позиции фар в системе освещения

### Шаг 1: Подготовка файлов модели

1. Создать папку `car/models/<название_модели>/`
2. Скопировать файлы модели (scene.gltf, текстуры)
3. Убедиться что модель импортирована в Godot

### Шаг 2: Создание setup скрипта

Создать `car/<название>_setup.gd`:

**Важно**: Setup скрипт отвечает только за визуал (цвета, материалы). Физика настраивается в сцене через параметры VehicleBase.

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

**Важно**: Сцена должна использовать скрипт `car.gd` который наследуется от VehicleBase.

**Структура**:
```
[node name="Car" type="VehicleBody3D" groups=["car"]]
mass = <вес в кг>
collision_layer = 1
collision_mask = 7
center_of_mass_mode = 1
center_of_mass = Vector3(0, <y_offset>, 0)
script = ExtResource("res://car/car.gd")

# Параметры VehicleBase (наследуются от базового класса)
max_engine_power = 300.0
max_rpm = 7000.0
idle_rpm = 900.0
gear_ratios = [-3.5, 0.0, 3.5, 2.2, 1.4, 1.0, 0.8]
final_drive = 3.7
max_steering_angle = 35.0
steering_speed = 3.0
steering_return_speed = 5.0
brake_force = 30.0

# Параметры Car (специфичные для игрока)
handbrake_force = 50.0
auto_transmission = true
drive_type = 2  # AWD
traction_control = true
stability_control = true

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
suspension_stiffness = 55.0  # Жёсткая для игрока
...

[node name="EngineSound" type="AudioStreamPlayer" parent="."]
script = ExtResource("res://car/audio/engine_sound.gd")

[node name="CollisionSound" type="Node" parent="."]
script = ExtResource("res://car/audio/collision_sound.gd")

[node name="CarLights" type="Node3D" parent="."]
script = ExtResource("res://night_mode/car_lights.gd")
```

**Ключевые параметры**:
- **Физика VehicleBase**: Все параметры двигателя, руления и тормозов
- **Масса и центр масс**: Влияют на управляемость
- **Подвеска игрока**: `suspension_stiffness = 55.0` (жёсткая, отзывчивая)
- **Collision layer**: 1 для игрока
- **Дополнительные узлы**: EngineSound, CollisionSound, CarLights

### Шаг 4: Создание сцены NPC

Создать `traffic/npc_<название>.tscn`:

**Важно**: Сцена должна использовать скрипт `traffic/npc_car.gd` который наследуется от VehicleBase.

**Структура** (аналогична player, но с отличиями):
```
[node name="NPCCar" type="VehicleBody3D"]
mass = <вес в кг>
collision_layer = 4  # NPC слой
collision_mask = 7
center_of_mass_mode = 1
center_of_mass = Vector3(0, <y_offset>, 0)
script = ExtResource("res://traffic/npc_car.gd")

# Параметры VehicleBase (слабее чем у игрока)
max_engine_power = 150.0  # Меньше мощность
max_rpm = 6000.0
idle_rpm = 900.0
gear_ratios = [-3.5, 0.0, 3.5, 2.2, 1.4, 1.0, 0.8]
final_drive = 3.7
max_steering_angle = 30.0  # Более осторожное руление
steering_speed = 3.0
steering_return_speed = 5.0
brake_force = 30.0

[node name="<Название>Model" parent="." instance=<путь к scene.gltf>]
transform = Transform3D(1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0, 0, <y_offset>, 0)
script = ExtResource("<название>_setup.gd")

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
shape = SubResource("BoxShape3D_body")

[node name="WheelFL" type="VehicleWheel3D" parent="."]
use_as_steering = true
wheel_radius = <радиус>
suspension_stiffness = 35.0  # Мягкая для NPC (плавная для AI)
...
```

**Ключевые отличия от player**:
- **Collision layer**: 4 (NPC)
- **Меньше мощности**: `max_engine_power = 150.0`
- **Мягкая подвеска**: `suspension_stiffness = 35.0` (для плавного AI управления)
- **Нет дополнительных узлов**: Без EngineSound, CollisionSound (AI создаёт свои lights)
- **AI управление**: Input рассчитывается в `_update_ai_driver()`

### Шаг 5: Добавление в систему освещения

**ВАЖНО**: Нужно обновить ОБА файла: `car_lights.gd` и `npc_car_lights.gd`!

#### В `night_mode/car_lights.gd` (фары игрока):

1. В enum:
```gdscript
enum CarModel { DEFAULT, NEXIA, PAZ, LADA_2109, <НОВАЯ_МОДЕЛЬ> }
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

#### В `night_mode/npc_car_lights.gd` (фары NPC):

1. В enum (должен совпадать с car_lights.gd):
```gdscript
enum CarModel { DEFAULT, NEXIA, PAZ, LADA_2109, <НОВАЯ_МОДЕЛЬ> }
```

2. В `_detect_car_model()` (аналогично car_lights.gd):
```gdscript
elif child.name == "<Название>Model":
    _car_model = CarModel.<НОВАЯ_МОДЕЛЬ>
    print("NPCCarLights: Detected <НОВАЯ_МОДЕЛЬ>")
    return
```

3. В `_create_headlight()` (раздельные фары для реальных моделей):
```gdscript
if _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    _use_split_lights = true
    var left_pos = Vector3(<x>, <y>, <z>)
    var right_pos = Vector3(<x>, <y>, <z>)
    headlight_left = _create_single_headlight("NPCHeadlightL", left_pos)
    headlight_right = _create_single_headlight("NPCHeadlightR", right_pos)
    return
```

4. В `_create_taillight()`:
```gdscript
if _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    var left_pos = Vector3(<x>, <y>, <z>)
    var right_pos = Vector3(<x>, <y>, <z>)
    taillight_left = _create_single_taillight("NPCTaillightL", left_pos)
    taillight_right = _create_single_taillight("NPCTaillightR", right_pos)
    return
```

5. В `_create_reverse_light()`:
```gdscript
elif _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    pos = Vector3(0, <y>, <z>)
```

6. В `_create_split_light_meshes()` (если используются раздельные фары):
```gdscript
elif _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    hl_left_pos = Vector3(<x>, <y>, <z>)
    hl_right_pos = Vector3(<x>, <y>, <z>)
    hl_size = Vector3(<width>, <height>, <depth>)
    tl_left_pos = Vector3(<x>, <y>, <z>)
    tl_right_pos = Vector3(<x>, <y>, <z>)
    tl_size = Vector3(<width>, <height>, <depth>)
```

7. В `_create_light_meshes()` (позиция reverse light mesh):
```gdscript
elif _car_model == CarModel.<НОВАЯ_МОДЕЛЬ>:
    reverse_pos = Vector3(0, <y>, <z>)
    reverse_size = Vector3(<width>, <height>, <depth>)
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
# Текущее распределение: 5% DPS, 15% такси, 20% ПАЗ, 60% блочные
var rand := randf()
if rand < 0.05:
    scene_to_use = npc_lada_scene
    car_type = "Lada 2109 DPS"
elif rand < 0.20:
    scene_to_use = npc_taxi_scene
    car_type = "Taxi"
elif rand < 0.40:
    scene_to_use = npc_paz_scene
    car_type = "PAZ bus"
else:
    scene_to_use = npc_car_scene
    car_type = "box car"
```

### Шаг 7: Добавление на парковки (опционально)

В `osm/osm_terrain_generator.gd`:

1. Добавить переменную:
```gdscript
var _parked_<название>_scene: PackedScene
```

2. Загрузить в `_ready()`:
```gdscript
_parked_<название>_scene = preload("res://traffic/npc_<название>.tscn")
```

3. Добавить в `_spawn_parked_cars()`:
```gdscript
# Текущее распределение: 60% блочные, 20% такси, 20% DPS
var rand := randf()
if rand < 0.6:
    car = _parked_car_scene.instantiate()
elif rand < 0.8:
    car = _parked_taxi_scene.instantiate()
else:
    car = _parked_lada_scene.instantiate()
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

## Преимущества архитектуры VehicleBase

### 1. Устранение дублирования кода

**До рефакторинга**:
- ~500 строк дублированной физики в `car.gd` и `npc_car.gd`
- Одинаковые методы: `_apply_steering()`, `_apply_forces()`, `_get_torque_curve()`, `_auto_shift()`, `_update_speed()`
- Изменения нужно было вносить в двух местах

**После рефакторинга**:
- ~300 строк общей физики в `VehicleBase`
- Используется обоими типами автомобилей
- Изменения вносятся в одном месте

### 2. Единая точка изменений

Все изменения физики делаются в `VehicleBase`:
```gdscript
// Изменение кривой крутящего момента
func _get_torque_curve(rpm_normalized: float) -> float:
    // Новая логика применяется ко всем машинам автоматически
```

### 3. Гибкость настройки

Каждая сцена может переопределить параметры через `@export`:
```
# Player Nexia
max_engine_power = 300.0
suspension_stiffness = 55.0  # Жёсткая

# NPC Nexia
max_engine_power = 150.0
suspension_stiffness = 35.0  # Мягкая
```

### 4. Расширяемость

Новые типы машин получают физику бесплатно:
```gdscript
extends VehicleBase
class_name TruckCar

# Переопределяем только input методы
func _get_steering_input() -> float:
    # Специфичная логика для грузовика
    return truck_steering_input
```

### 5. Сохранение различий

**Player (car.gd)** сохраняет:
- Input handling (клавиатура)
- TCS и ESC системы
- Ручной тормоз
- Тип привода (RWD/FWD/AWD)

**NPC (npc_car.gd)** сохраняет:
- AI steering (Pure Pursuit)
- Waypoint navigation
- Obstacle detection
- Path extension

### 6. Упрощение тестирования

Изменения в базовой физике тестируются один раз:
- Запуск игры с player машиной
- Проверка NPC трафика
- Оба используют одну и ту же физику

## Будущие улучшения

- [ ] Динамический выбор моделей NPC с весами
- [ ] Цветовые вариации для каждой модели
- [ ] Автоматическое определение позиций фар из модели
- [ ] Система лодов (LOD) для далёких NPC
- [ ] Больше типов машин (грузовики, легковые, спорткары)
- [ ] Мотоциклы (наследуются от VehicleBase с 2 колёсами)
