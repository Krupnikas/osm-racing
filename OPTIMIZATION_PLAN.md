# Performance Optimization Plan - Приоритизированный список

## Текущие метрики (последний тест)

- **FPS**: 40.9 avg (целевой: 60)
- **Frame Time**: 22.46 ms avg (цель: 16.67 ms)
- **Draw Calls**: 3700 avg, 4636 max
- **Vertices**: 3.3M avg
- **Physics Bodies**: 360

## Draw Call Breakdown (главная проблема)

Total: 2789 tracked draw calls

| Feature     | Draw Calls | Percentage | Priority |
|-------------|------------|------------|----------|
| Lamps       | 1152       | 41.3%      | 🔴 #1    |
| Vegetation  | 730        | 26.2%      | 🔴 #2    |
| Buildings   | 646        | 23.2%      | 🟠 #3    |
| Terrain     | 169        | 6.1%       | 🟡 #6    |
| Roads       | 47         | 1.7%       | ✅ OK    |
| Signs       | 26         | 0.9%       | ✅ OK    |
| Windows     | 19         | 0.7%       | ✅ OK    |

**Вывод**: Infrastructure (Lamps + Signs + Roads) = 44% всех draw calls!

---

## 🔴 PRIORITY 1: Street Lamps (41.3% draw calls)

**Проблема**: 1152 draw calls для фонарей - каждый фонарь = отдельный draw call

**Решение**: MultiMesh батчинг для фонарей

### Детали:
- Сейчас: каждый фонарь = StaticBody3D с MeshInstance3D
- Надо: один MultiMeshInstance3D на чанк для всех фонарей одного типа
- Collision можно оставить как отдельные BoxShape3D (физика не так критична)

### Ожидаемый эффект:
- Draw calls: 1152 → ~20-30 (один batch на chunk для стандартных фонарей)
- **Снижение draw calls на ~40%**
- **FPS может вырасти до ~55-60**

### Реализация:
```gdscript
# В osm_terrain_generator.gd
var _lamp_batch_data: Dictionary = {}  # chunk_key -> Array of transforms

func _add_lamp_to_batch(chunk_key: String, transform: Transform3D, type: String):
    if not _lamp_batch_data.has(chunk_key):
        _lamp_batch_data[chunk_key] = {"standard": [], "tall": []}
    _lamp_batch_data[chunk_key][type].append(transform)

func _finalize_lamp_batches_for_chunk(chunk_key: String):
    # Create MultiMesh for each lamp type
    for lamp_type in ["standard", "tall"]:
        var transforms = _lamp_batch_data[chunk_key][lamp_type]
        var mm = MultiMesh.new()
        mm.transform_format = MultiMesh.TRANSFORM_3D
        mm.mesh = _lamp_meshes[lamp_type]  # Prebuilt mesh
        mm.instance_count = transforms.size()
        for i in range(transforms.size()):
            mm.set_instance_transform(i, transforms[i])
        # Create MultiMeshInstance3D and add to chunk
```

**Файлы**: `osm/osm_terrain_generator.gd` (lines ~6284-6347)

---

## 🔴 PRIORITY 2: Vegetation (26.2% draw calls)

**Проблема**: 730 draw calls для деревьев - каждое дерево = отдельный draw call

**Решение**: MultiMesh батчинг + Billboard LOD для дальних деревьев

### Детали:
- Сейчас: каждое дерево = Node3D + 2 MeshInstance3D (trunk + leaves)
- Надо:
  1. **Close range (<100m)**: MultiMesh с full 3D geometry
  2. **Medium range (100-200m)**: MultiMesh с упрощённой geometry
  3. **Far range (>200m)**: Billboard texture (один quad)

### Ожидаемый эффект:
- Draw calls: 730 → ~50-80 (batches + billboards)
- **Снижение draw calls ещё на ~25%**
- **FPS может вырасти до ~65-70 с учётом Lamps**

### Реализация:
```gdscript
var _tree_batch_data: Dictionary = {}  # chunk_key -> {close: [], medium: [], far: []}

func _add_tree_to_batch(chunk_key: String, pos: Vector3, car_distance: float):
    var lod_level = "close" if car_distance < 100.0 else "medium" if car_distance < 200.0 else "far"
    _tree_batch_data[chunk_key][lod_level].append(Transform3D(Basis(), pos))

func _finalize_tree_batches_for_chunk(chunk_key: String):
    # Close: full tree mesh
    # Medium: simple cylinder + sphere
    # Far: billboard quad
```

**Lazy loading**: деревья создавать только после того как чанк стал видимым 2+ секунды

**Файлы**: `osm/osm_terrain_generator.gd` (lines ~5404-5464, ~5711-5817)

---

## 🟠 PRIORITY 3: Buildings (23.2% draw calls)

**Проблема**: 646 draw calls для зданий

**Решение**: Lazy loading + LOD для зданий

### Детали:
- Сейчас: все здания создаются сразу при загрузке чанка
- Надо:
  1. **Immediate**: только здания в радиусе 150m от игрока
  2. **Lazy (2s delay)**: здания 150-300m
  3. **LOD простые boxes**: здания >300m (без окон, без текстур)

### Ожидаемый эффект:
- Draw calls: 646 → ~400-500 (delayed loading + LOD)
- **Снижение draw calls ещё на ~5-8%**
- Главное: **уменьшение фризов при загрузке чанков**

### Реализация:
```gdscript
func _queue_building_for_thread(...):
    var distance_from_player = pos.distance_to(car.global_position)

    if distance_from_player < 150.0:
        # Create immediately
        _building_queue.append(task_data)
    elif distance_from_player < 300.0:
        # Lazy load after 2s
        _lazy_building_queue.append({
            "task": task_data,
            "delay": 2.0,
            "timer": 0.0
        })
    else:
        # Simple LOD box only
        _create_simple_building_box(points, height, parent)

func _process(delta):
    # Process lazy queue
    for item in _lazy_building_queue:
        item.timer += delta
        if item.timer >= item.delay:
            _building_queue.append(item.task)
            _lazy_building_queue.erase(item)
```

**Файлы**: `osm/osm_terrain_generator.gd` (lines ~3974-4010)

---

## 🟡 PRIORITY 4: Traffic NPCs - Physics Optimization

**Проблема**: 360 physics bodies (хотя мы уже оптимизировали до 1 body/NPC вместо 5)

**Решение**: Дистанционный LOD для физики NPC

### Детали:
- Сейчас: все NPC = VehicleBody3D с полной физикой
- Надо:
  1. **Close (<100m)**: VehicleBody3D (полная физика)
  2. **Medium (100-200m)**: CharacterBody3D (упрощённая физика)
  3. **Far (>200m)**: Kinematic движение по пути (без физики)

### Ожидаемый эффект:
- Physics bodies: 360 → ~100-150
- **Physics time: может снизиться с 5.64ms до ~3-4ms**

**Файлы**: `traffic/traffic_manager.gd`

---

## 🟡 PRIORITY 5: Vertex Count Optimization

**Проблема**: 3.3M vertices avg

**Решение**:
1. ✅ Terrain уже упрощён (16x16 → 8x8)
2. ✅ Roads уже упрощены (6.0 meters_per_point)
3. 🔴 Building meshes - можно упростить ещё больше

### Здания:
- Текущая детализация: нормальная
- Можно: уменьшить высоту секций с 4m до 6m (меньше вертикальных полигонов)

---

## 🟡 PRIORITY 6: Terrain Chunks - Culling Optimization

**Текущий frustum culling**: работает, но можно улучшить

**Идея**: Distance-based detail для чанков
- Near chunks (<200m): full detail
- Medium chunks (200-400m): half detail (skip every 2nd window, reduce lamp density)
- Far chunks (>400m): minimal detail (no lamps, no trees, simple buildings)

---

## 📊 Итоговая стратегия (порядок реализации)

### Этап 1 (Максимальный эффект) - **~2 часа работы**
1. ✅ **Lamps MultiMesh** → -40% draw calls → ~55-60 FPS
2. ✅ **Vegetation MultiMesh + LOD** → -25% draw calls → ~65-70 FPS

**Ожидаемый результат после Этапа 1**: FPS 60-70 (ЦЕЛЬ ДОСТИГНУТА!)

### Этап 2 (Стабильность) - **~1 час работы**
3. ✅ **Buildings Lazy Loading** → меньше фризов при загрузке
4. ✅ **Traffic Physics LOD** → physics time < 4ms

**Ожидаемый результат после Этапа 2**: Stable 60 FPS, no freezes

### Этап 3 (Полировка) - опционально
5. Frustum culling improvements
6. Chunk detail LOD
7. Building mesh simplification

---

## Feature Flags для тестирования

Добавлены в `osm_terrain_generator.gd`:

```gdscript
@export_group("Features", "enable_")
@export var enable_buildings := true
@export var enable_windows := true
@export var enable_roads := true
@export var enable_curbs := true
@export var enable_vegetation := true
@export var enable_street_lamps := true
@export var enable_traffic_signs := true
@export var enable_traffic_lights := true
@export var enable_frustum_culling := true
```

**Для A/B тестирования**: отключать по одному флагу и замерять FPS

---

## Замеры эффективности (TODO)

После каждой оптимизации запускать:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . res://tests/performance_test_detailed.tscn
```

И записывать:
- FPS avg/min
- Draw calls avg/max
- Frame time avg/max
- Spike count

---

## Заметки

- ✅ Windows уже оптимизированы (QuadMesh) - 0.7% draw calls
- ✅ Roads уже оптимизированы (упрощённая геометрия) - 1.7% draw calls
- ✅ Signs уже простые - 0.9% draw calls
- 🔴 **Lamps - ГЛАВНАЯ ПРОБЛЕМА** (41.3% draw calls)
- 🔴 **Vegetation - ВТОРАЯ ПРОБЛЕМА** (26.2% draw calls)

**Без оптимизации Lamps и Vegetation - невозможно достичь 60 FPS!**
