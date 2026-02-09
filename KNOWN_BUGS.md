# Known Bugs

## Здания с кастомными текстурами: тёмные поверхности и отсутствие теней

**Статус:** Открыт

**Описание:**
У некоторых зданий с кастомными текстурами (building_override) наблюдаются:
- Тёмные поверхности на некоторых стенах
- Отсутствие теней

**Вероятные причины:**
1. Неправильные нормали освещения (зависит от направления обхода полигона в OSM данных)
2. CULL_DISABLED с фиксированными нормалями — обратные стороны получают неправильное освещение
3. Shadow LOD отключает тени для далёких зданий

**Затронутые здания:**
- Химико-технологический колледж (way 45747168)
- Возможно другие здания с building_override

**Попытки исправления:**
- Двусторонняя геометрия с инвертированными нормалями — не помогло

**Файлы:**
- `osm/osm_terrain_generator.gd` — функция `_create_3d_building_with_custom_texture()`
- `osm/decorations/building_override.gd`

---

## Emissive mask для светящихся окон

**Статус:** Решено

**Описание:**
Emission texture в Godot 4 StandardMaterial3D не работает как маска — вместо того чтобы чёрные пиксели давали нулевую эмиссию, весь материал светится.

**Решение:**
Создан кастомный шейдер `osm/building_wall_custom.gdshader`:
- Использует `global uniform bool is_night_global` для динамического переключения
- Emission применяется только если `has_emission_mask && is_night_global`
- NightModeManager регистрирует и обновляет глобальный параметр через RenderingServer

**Файлы:**
- `osm/building_wall_custom.gdshader` — кастомный шейдер с правильной emission mask
- `osm/osm_terrain_generator.gd` — использует ShaderMaterial для зданий с emissive
- `night_mode/night_mode_manager.gd` — регистрирует и обновляет `is_night_global`
- `textures/buildings/111-125_emissive_mask.png` — маска (RGB, чёрный фон, цветные окна)
