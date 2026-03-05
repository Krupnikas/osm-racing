# Дебаг: фонари не светят ночью

## Проблема
После pull с мейна (396a52b..8469551) фонари видны (MultiMesh), но OmniLight3D не включаются при переключении в ночной режим (N).

## Что изменил krupnikas

Коммиты:
- `950302e` Defer node creation and spread finalization across frames
- `7cf4c93` Limit add_child() to 2 per frame via global budget system
- `6e934d5` Use RenderingServer for terrain/road/building/curb meshes
- `8469551` Incremental building finalization, deferred footway/billboard, lazy chunk activation

Ключевое изменение в лампах: **перевод создания OmniLight3D на deferred очередь**.

### Было (до рефакторинга):
```gdscript
# В _finalize_lamp_batches_for_chunk():
for light_data in batch.light_data:
    var light := OmniLight3D.new()
    light.visible = is_night and not light_data.broken
    lights_container.add_child(light)
    _lamp_lights_by_chunk[chunk_key].append(light)
```

### Стало (после рефакторинга):
```gdscript
# В _finalize_lamp_batches_for_chunk():
_deferred_lamp_lights.append({
    "container": lights_container,
    "lights": batch.light_data,
    "idx": 0,
    "chunk_key": chunk_key,
    "is_night": is_night  # ← кешированное значение из момента финализации
})

# Обработка позже в _process_deferred_nodes():
light.visible = is_night and not light_data.broken  # is_night = cached
_budgeted_add_child(container, light)
_lamp_lights_by_chunk[chunk_key].append(light)
```

## Попытки починки

### Попытка 1: Использовать _is_night_mode вместо cached is_night
**Изменение:** строка ~5089 — заменил `is_night` на `_is_night_mode`
**Результат:** НЕ помогло. Фонари всё ещё не светят.
**Анализ:** Проблема не в кешированном значении.

### Попытка 2: Дебаг-логи
**Изменения:** Добавил print в `_update_lamp_night_mode` и в deferred batch completion.
**Дебаг-вывод:**
```
DEBUG_LAMP: toggle is_night=true total=0 toggled=0 deferred_remaining=0
DEBUG_LAMP: deferred batch done chunk=-2,0 lights=3 is_night_mode=true
```
**Анализ:** Night mode toggle срабатывает когда 0 лампочек существует и 0 deferred ожидают. Потом создаются всего 3 лампочки для одного чанка. Больше ничего не приходит.

### Попытка 3: Синхронное создание OmniLight3D (вместо deferred)
**Изменение:** Убрал `_deferred_lamp_lights` очередь полностью. Создаю OmniLight3D прямо в `_finalize_lamp_batches_for_chunk()` синхронно, до `_budgeted_add_child(parent, lamp_container)`.
**Результат:** ПОМОГЛО. Фонари светят ночью.

## Корневая причина

Три проблемы deferred подхода:

1. **Budget starvation**: Лампочки были на 4-й позиции в `_process_deferred_nodes()` (после road → building → tree collisions), с бюджетом `ADD_CHILD_BUDGET_PER_FRAME = 2`. Дорожные коллизии делали `return` после каждой обработки, блокируя остальную очередь. В итоге лампочки почти не создавались.

2. **Race с chunk activation**: `_process_chunk_activation()` проверяет `_lamp_batches_to_finalize` но НЕ проверяет `_deferred_lamp_lights`. Чанк активируется (visible=true) до того как deferred лампочки созданы.

3. **Race с night toggle**: `_on_night_mode_changed()` → `_update_lamp_night_mode()` срабатывает когда в `_lamp_lights_by_chunk` ещё 0 ссылок (лампочки ещё не создались через deferred очередь).

## Рекомендация для krupnikas

Лампочек на чанк всего ~3-10 штук. Нет смысла их дефёрить. Создавай OmniLight3D синхронно в `_finalize_lamp_batches_for_chunk()` как children `lights_container`, ДО `_budgeted_add_child(parent, lamp_container)`. Вся группа (MultiMesh + Lights) войдёт в scene tree одним budgeted вызовом.

Если нужен deferred подход — надо:
- Добавить `_deferred_lamp_lights` в проверку `_process_chunk_activation()` (строка 13357)
- Поднять приоритет ламп выше road/building/tree collisions (или дать отдельный бюджет)
- Вызывать `_update_lamp_night_mode()` после каждого batch completion, не только по toggle
