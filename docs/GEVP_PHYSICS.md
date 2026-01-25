# GEVP Physics Documentation

## Overview

GEVP (Godot Enhanced Vehicle Physics) - это продвинутая симуляция автомобильной физики для Godot 4, основанная на [Godot-Advanced-Vehicle](https://github.com/Dechode/Godot-Advanced-Vehicle) от Dechode.

## Архитектура

### Основные компоненты

```
Vehicle (RigidBody3D)
├── CollisionShape3D (ConvexPolygonShape3D) - коллизия кузова
├── Wheel (RayCast3D) x4 - симуляция колёс через raycast
│   └── WheelNode (Node3D) - визуальное представление колеса
└── VehicleInput - обработка ввода
```

### Vehicle (`vehicle.gd`)

Главный класс симуляции. Наследует `RigidBody3D`.

#### Ключевые системы:

1. **Физика кузова** - стандартная физика Godot RigidBody3D
2. **Подвеска** - пружинно-демпферная модель
3. **Шины** - модифицированная brush tire model
4. **Двигатель** - симуляция крутящего момента и оборотов
5. **Трансмиссия** - автоматическая/ручная КПП
6. **Стабилизация** - система контроля устойчивости

### Wheel (`wheel.gd`)

Симуляция колеса через RayCast3D (не физическое колесо).

## Физика подвески

### Параметры пружины

```gdscript
spring_length: float       # Длина хода подвески (м)
spring_rate: float         # Жёсткость пружины (авто-расчёт)
resting_ratio: float       # Сжатие в покое (0.5 = середина хода)
```

### Расчёт жёсткости

```gdscript
func calculate_spring_rate(weight, spring_length, resting_ratio):
    target_compression = spring_length * resting_ratio * 1000.0  # мм
    return weight / target_compression  # N/mm
```

### Демпфирование

```gdscript
damping_ratio: float           # Коэф. демпфирования (0.3-0.9)
bump_damp_multiplier: float    # Множитель сжатия (обычно 0.67)
rebound_damp_multiplier: float # Множитель отбоя (обычно 1.5)
```

- **Пассажирские авто**: damping_ratio ~0.3, bump 0.67, rebound 1.5
- **Гоночные авто**: damping_ratio ~0.9, bump 1.5, rebound 0.67

### Antiroll Bar (стабилизатор поперечной устойчивости)

```gdscript
arb_ratio: float  # Жёсткость ARB как доля от spring_rate
```

Связывает левое и правое колесо оси, уменьшая крены в поворотах.

## Физика шин (Brush Tire Model)

### Модель трения

Используется модифицированная brush tire model без падения сцепления после пика.

```gdscript
# Расчёт силы трения
cornering_stiffness = 0.5 * tire_stiffness * contact_patch^2
friction = CoF * spring_force - load_sensitivity
```

### Параметры шин

```gdscript
tire_radius: float      # Радиус шины (м)
tire_width: float       # Ширина шины (мм) - влияет на load sensitivity
contact_patch: float    # Длина пятна контакта (м)
```

### Поверхности

Поверхности определяются через **группы узлов** StaticBody3D/RigidBody3D:

```gdscript
tire_stiffnesses = { "Road": 10.0, "Dirt": 0.5, "Grass": 0.5 }
coefficient_of_friction = { "Road": 3.0, "Dirt": 2.4, "Grass": 2.0 }
rolling_resistance = { "Road": 1.0, "Dirt": 2.0, "Grass": 4.0 }
lateral_grip_assist = { "Road": 0.05, "Dirt": 0.0, "Grass": 0.0 }
longitudinal_grip_ratio = { "Road": 0.5, "Dirt": 0.5, "Grass": 0.5 }
```

### Скольжение (Slip)

```gdscript
slip_vector.x  # Боковое скольжение (угол увода)
slip_vector.y  # Продольное скольжение (пробуксовка)
```

## Двигатель

### Параметры

```gdscript
max_torque: float     # Максимальный крутящий момент (Нм)
max_rpm: float        # Максимальные обороты
idle_rpm: float       # Обороты холостого хода
torque_curve: Curve   # Кривая крутящего момента по оборотам
motor_drag: float     # Сопротивление двигателя (по оборотам)
motor_brake: float    # Торможение двигателем
motor_moment: float   # Момент инерции двигателя
```

### Расчёт мощности

```gdscript
torque_output = torque_curve.sample(rpm / max_rpm) * max_torque * throttle
torque_output -= drag_torque * (1.0 + clutch * (1.0 - throttle))
```

## Трансмиссия

### Параметры КПП

```gdscript
gear_ratios: Array[float]  # Передаточные числа [3.8, 2.3, 1.7, 1.3, 1.0, 0.8]
final_drive: float         # Главная передача
reverse_ratio: float       # Передача заднего хода
shift_time: float          # Время переключения (сек)
automatic_transmission: bool
```

### Сцепление

```gdscript
clutch_out_rpm: float         # Обороты для старта
max_clutch_torque_ratio: float # Макс. момент сцепления относительно двигателя
```

## Привод (Drivetrain)

### Распределение момента

```gdscript
front_torque_split: float  # 1.0 = FWD, 0.0 = RWD, 0.5 = AWD
variable_torque_split: bool # Динамическое распределение при пробуксовке
front_variable_split: float # Целевое распределение при пробуксовке
```

### Дифференциал

```gdscript
locking_differential_engage_torque: float  # Момент блокировки дифференциала
torque_vectoring: float  # Перераспределение момента по рулению (0-1)
```

## Системы помощи

### ABS (Антиблокировочная система)

```gdscript
abs_pulse_time: float                  # Время отпускания тормоза
abs_spin_difference_threshold: float   # Порог срабатывания
```

### Traction Control (Контроль тяги)

```gdscript
traction_control_max_slip: float  # Макс. пробуксовка (отключить: < 0)
```

### Stability Control (Контроль устойчивости)

```gdscript
enable_stability: bool
stability_yaw_engage_angle: float    # Угол срабатывания (0-1, dot product)
stability_yaw_strength: float        # Сила коррекции
stability_yaw_ground_multiplier: float
stability_upright_spring: float      # Удержание вертикали в воздухе
stability_upright_damping: float
```

## Аэродинамика

```gdscript
coefficient_of_drag: float  # Коэф. аэродин. сопротивления (~0.3-0.4)
air_density: float          # Плотность воздуха (1.225 кг/м³)
frontal_area: float         # Площадь лобового сечения (м²)

# Расчёт сопротивления
drag = 0.5 * air_density * speed² * frontal_area * Cd
```

## Коллизия

### Тип коллизии

Машина использует `ConvexPolygonShape3D` - выпуклый многогранник из точек:

```
Размеры примерно: 1.3 x 0.9 x 2.45 м (Nexia)
Позиция: Y = 0.2 от корня машины
```

### Collision Layers

По умолчанию используются стандартные слои Godot (не переопределены в GEVP).

## Центр масс

```gdscript
front_weight_distribution: float       # Доля веса на передней оси (0.5 = 50/50)
center_of_gravity_height_offset: float # Смещение ЦМ по высоте

# Расчёт
center_of_mass = lerp(rear_axle_pos, front_axle_pos, front_weight_distribution)
center_of_mass.y += center_of_gravity_height_offset
```

## Инерция

```gdscript
inertia_multiplier: float  # Множитель расчётной инерции

# Расчёт
vehicle_inertia = PhysicsServer3D.body_get_direct_state(rid).inverse_inertia.inverse()
inertia = vehicle_inertia * inertia_multiplier
```

## Главный цикл физики

```gdscript
func _physics_process(delta):
    process_drag()          # Аэродинамика
    process_braking(delta)  # Торможение
    process_steering(delta) # Рулевое управление
    process_throttle(delta) # Газ
    process_motor(delta)    # Двигатель
    process_clutch(delta)   # Сцепление
    process_transmission()  # КПП
    process_drive(delta)    # Привод на колёса
    process_forces(delta)   # Силы подвески и шин
    process_stability()     # Стабилизация
```

## Колёса - цикл обработки сил

```gdscript
func process_forces(delta):
    # 1. Обновление raycast
    force_raycast_update()

    # 2. Определение поверхности (по группам узла коллайдера)
    surface_type = collider.get_groups()[0]

    # 3. Расчёт подвески
    compression = process_suspension(opposite_compression, delta)

    # 4. Расчёт сил шин
    process_tires(braking, delta)

    # 5. Применение сил к кузову
    vehicle.apply_force(normal * spring_force, contact)
    vehicle.apply_force(basis.x * force_vector.x, contact)  # Боковая
    vehicle.apply_force(basis.z * force_vector.y, contact)  # Продольная
```

## Ввод (Controller Inputs)

Внешний скрипт должен устанавливать эти значения:

```gdscript
var throttle_input := 0.0   # 0.0 - 1.0
var steering_input := 0.0   # -1.0 - 1.0
var brake_input := 0.0      # 0.0 - 1.0
var handbrake_input := 0.0  # 0.0 - 1.0
var clutch_input := 0.0     # 0.0 - 1.0
```

## Отличия от VehicleBody3D

| Аспект | GEVP | VehicleBody3D |
|--------|------|---------------|
| Колёса | RayCast3D | VehicleWheel3D |
| Модель шин | Brush tire model | Упрощённая |
| Подвеска | Полная симуляция | Базовая |
| Двигатель | Полная симуляция | Нет |
| КПП | Авто/Ручная | Нет |
| Дифференциал | Блокируемый + векторизация | Нет |
| Поверхности | Группы узлов | Friction |
| Настраиваемость | Высокая | Низкая |

## Файлы

- `addons/gevp/scripts/vehicle.gd` - Главный класс машины
- `addons/gevp/scripts/wheel.gd` - Класс колеса
- `addons/gevp/scripts/vehicle_input.gd` - Обработка ввода
- `addons/gevp/scenes/nexia_car.tscn` - Пример машины
