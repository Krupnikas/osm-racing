# Архитектура VehicleBase

## Обзор

VehicleBase - это базовый класс для всех автомобилей в игре (игрока и NPC). Он содержит общую физику и предоставляет абстрактные методы для переопределения в наследниках.

## Иерархия классов

```
VehicleBody3D (Godot встроенный класс)
    ↓
VehicleBase (car/vehicle_base.gd) - Базовая физика
    ↓
    ├── Car (car/car.gd) - Автомобиль игрока
    └── NPCCar (traffic/npc_car.gd) - NPC трафик
```

## VehicleBase - API

### Экспортируемые параметры

Все параметры можно переопределить в сценах через Inspector:

#### Двигатель
```gdscript
@export var max_engine_power := 300.0  # Максимальная мощность (Н·м)
@export var max_rpm := 7000.0          # Максимальные обороты
@export var idle_rpm := 900.0          # Обороты холостого хода
@export var gear_ratios: Array[float] = [-3.5, 0.0, 3.5, 2.2, 1.4, 1.0, 0.8]
@export var final_drive := 3.7         # Главная передача
```

#### Рулевое управление
```gdscript
@export var max_steering_angle := 35.0      # Макс. угол (градусы)
@export var steering_speed := 3.0           # Скорость поворота руля
@export var steering_return_speed := 5.0    # Скорость возврата
```

#### Тормоза
```gdscript
@export var brake_force := 30.0  # Сила тормозов
```

### Внутреннее состояние

Эти переменные доступны в наследниках:

```gdscript
# Колёса
var wheels_front: Array[VehicleWheel3D] = []
var wheels_rear: Array[VehicleWheel3D] = []

# Трансмиссия
var current_gear := 2        # 0=R, 1=N, 2-6=1-5
var current_rpm := 0.0
var current_speed_kmh := 0.0

# Input (заполняются наследниками через абстрактные методы)
var steering_input := 0.0
var throttle_input := 0.0
var brake_input := 0.0
```

### Абстрактные методы

**Обязательно переопределить в наследниках**:

```gdscript
func _get_steering_input() -> float:
    """Возвращает текущий input рулежки [-1.0 .. 1.0]"""
    return 0.0

func _get_throttle_input() -> float:
    """Возвращает текущий input газа [0.0 .. 1.0]"""
    return 0.0

func _get_brake_input() -> float:
    """Возвращает текущий input тормоза [0.0 .. 1.0]"""
    return 0.0
```

### Публичные методы

```gdscript
func get_speed_kmh() -> float:
    """Возвращает текущую скорость в км/ч"""
```

### Защищённые методы

Доступны для переопределения в наследниках:

```gdscript
func _collect_wheels() -> void:
    """Собирает все VehicleWheel3D в массивы"""

func _update_speed() -> void:
    """Обновляет current_speed_kmh"""

func _apply_steering(delta: float) -> void:
    """Применяет рулежку с учётом скорости"""

func _apply_forces() -> void:
    """Применяет силы двигателя и тормозов"""

func _get_torque_curve(rpm_normalized: float) -> float:
    """Возвращает множитель крутящего момента"""

func _auto_shift() -> void:
    """Автоматическое переключение передач"""

func _get_average_wheel_rpm() -> float:
    """Средние RPM ведущих колёс"""
```

### Основной метод физики

```gdscript
func _base_physics_process(delta: float) -> void:
    """Базовая физика - вызывается наследниками в их _physics_process

    Обрабатывает:
    - Получение input от наследников
    - Обновление скорости
    - Применение рулежки
    - Применение сил двигателя и тормозов
    - Автоматическое переключение передач
    """
```

## Как использовать VehicleBase

### Пример 1: Автомобиль игрока (Car)

```gdscript
extends VehicleBase
class_name Car

# Дополнительные параметры игрока
@export var handbrake_force := 50.0
@export var traction_control := true

# Внутренние переменные
var handbrake_input := 0.0

func _ready() -> void:
    super._ready()  # Вызываем базовый _ready
    # Дополнительная инициализация...

func _physics_process(delta: float) -> void:
    _handle_input()  # Обрабатываем клавиатуру

    # Вызываем базовую физику
    _base_physics_process(delta)

    # Дополнительная логика игрока
    _apply_tcs()
    _apply_esc()

# Реализуем абстрактные методы
func _get_steering_input() -> float:
    return Input.get_axis("ui_right", "ui_left")

func _get_throttle_input() -> float:
    return 1.0 if Input.is_action_pressed("ui_up") else 0.0

func _get_brake_input() -> float:
    if handbrake_input > 0.1:
        return handbrake_input * handbrake_force / brake_force
    return brake_input
```

### Пример 2: NPC автомобиль (NPCCar)

```gdscript
extends VehicleBase
class_name NPCCar

# AI параметры
const LOOKAHEAD_MIN := 8.0
const UPDATE_INTERVAL := 0.1

var ai_state := AIState.DRIVING
var update_timer := 0.0

func _ready() -> void:
    super._ready()  # Вызываем базовый _ready
    # Инициализация AI...

func _physics_process(delta: float) -> void:
    # Обновляем AI периодически
    update_timer += delta
    if update_timer >= UPDATE_INTERVAL:
        update_timer = 0.0
        _update_ai_driver()  # Рассчитываем input

    # Вызываем базовую физику
    _base_physics_process(delta)

# Реализуем абстрактные методы
func _get_steering_input() -> float:
    return steering_input  # Рассчитан в _update_ai_driver()

func _get_throttle_input() -> float:
    return throttle_input  # Рассчитан в _update_ai_driver()

func _get_brake_input() -> float:
    return brake_input  # Рассчитан в _update_ai_driver()

func _update_ai_driver() -> void:
    # Pure Pursuit steering
    var lookahead_point := _get_lookahead_point(10.0)
    steering_input = _calculate_steering(lookahead_point)

    # Speed control
    var speed_error := target_speed - current_speed_kmh
    if speed_error < 0:
        throttle_input = 0.0
        brake_input = abs(speed_error) / 25.0
    else:
        throttle_input = speed_error / 12.0
        brake_input = 0.0
```

## Физика VehicleBase

### Кривая крутящего момента

```gdscript
func _get_torque_curve(rpm_normalized: float) -> float:
    if rpm_normalized < 0.2:
        # Низкие обороты: 0.4-0.8
        return lerp(0.4, 0.8, rpm_normalized / 0.2)
    elif rpm_normalized < 0.6:
        # Средние обороты: 0.8-1.0 (пик)
        return lerp(0.8, 1.0, (rpm_normalized - 0.2) / 0.4)
    else:
        # Высокие обороты: 1.0-0.7 (падение)
        return lerp(1.0, 0.7, (rpm_normalized - 0.6) / 0.4)
```

График:
```
Torque
  1.0 |     ___________
      |    /           \
  0.8 |   /             \
  0.6 |  /               \
  0.4 | /                 \
      +--------------------
      0  0.2  0.6  1.0  RPM (normalized)
```

### Рулежка с учётом скорости

```gdscript
func _apply_steering(delta: float) -> void:
    # Максимальный угол уменьшается на скорости
    var speed_factor: float = clamp(1.0 - current_speed_kmh / 200.0, 0.3, 1.0)
    var max_steer: float = deg_to_rad(max_steering_angle) * speed_factor

    # Целевой угол
    var target_steer: float = steering_input * max_steer

    # Плавный поворот
    steering = lerp(steering, target_steer, steering_speed * delta)
```

На скорости 0 км/ч: 100% от max_steering_angle
На скорости 100 км/ч: 65% от max_steering_angle
На скорости 200 км/ч: 30% от max_steering_angle

### Автоматическая КПП

```gdscript
func _auto_shift() -> void:
    # Переключение вверх при 85% от max_rpm
    if current_rpm > max_rpm * 0.85 and current_gear < gear_ratios.size() - 1:
        current_gear += 1
        current_rpm = max_rpm * 0.6  # Падение после переключения

    # Переключение вниз при 30% от max_rpm
    elif current_rpm < max_rpm * 0.3 and current_gear > 2:
        current_gear -= 1
        current_rpm = max_rpm * 0.7  # Подъём после переключения
```

## Настройка параметров

### В сцене через Inspector

Параметры можно настроить для каждой модели отдельно:

**Player Nexia** (car_nexia.tscn):
```
max_engine_power = 300.0      # Мощный
max_steering_angle = 35.0     # Резкое руление
suspension_stiffness = 55.0   # Жёсткая подвеска
```

**NPC Nexia** (npc_car.tscn):
```
max_engine_power = 150.0      # Слабее
max_steering_angle = 30.0     # Плавнее
suspension_stiffness = 35.0   # Мягкая подвеска
```

### Через код (переопределение)

Если нужно динамически изменить параметры:

```gdscript
func _ready() -> void:
    super._ready()

    # Настраиваем для спорткара
    max_engine_power = 500.0
    max_rpm = 9000.0
    max_steering_angle = 40.0
```

## Отладка

### Вывод состояния

```gdscript
func _physics_process(delta: float) -> void:
    _base_physics_process(delta)

    # Debug info
    if Input.is_key_pressed(KEY_F3):
        print("Speed: %.1f km/h, RPM: %.0f, Gear: %d" %
              [current_speed_kmh, current_rpm, current_gear])
```

### Проверка колёс

```gdscript
func _ready() -> void:
    super._ready()

    print("Wheels front: %d, rear: %d" %
          [wheels_front.size(), wheels_rear.size()])

    for wheel in wheels_front + wheels_rear:
        print("  %s: pos=%.2f, radius=%.2f" %
              [wheel.name, wheel.position.y, wheel.wheel_radius])
```

## Часто задаваемые вопросы

### Q: Как добавить новый тип машины?

A: Создайте класс, наследуйте от VehicleBase, реализуйте 3 абстрактных метода:

```gdscript
extends VehicleBase
class_name MotorcycleCar

func _get_steering_input() -> float:
    # Ваша логика

func _get_throttle_input() -> float:
    # Ваша логика

func _get_brake_input() -> float:
    # Ваша логика
```

### Q: Можно ли изменить кривую крутящего момента?

A: Да, переопределите метод в наследнике:

```gdscript
func _get_torque_curve(rpm_normalized: float) -> float:
    # Ваша кривая (например, для электромобиля)
    return 1.0  # Постоянный момент
```

### Q: Как отключить автоматическую КПП?

A: Переопределите `_auto_shift()`:

```gdscript
func _auto_shift() -> void:
    # Ничего не делаем - ручная КПП
    pass
```

### Q: Как изменить физику для всех машин сразу?

A: Измените методы в `VehicleBase` - изменения применятся ко всем:

```gdscript
# В car/vehicle_base.gd
func _apply_forces() -> void:
    # Новая логика применения сил
    # Затронет Car и NPCCar автоматически
```

## Совместимость

- **Godot версия**: 4.x
- **Требуемые узлы**: VehicleWheel3D (минимум 3)
- **Collision layers**: Настраиваются в сценах (1 для player, 4 для NPC)
