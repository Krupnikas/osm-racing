# Known Bugs

## Здания: тёмные стены днём, не освещаются фарами ночью

**Статус:** Решено

**Описание:**
Все здания (процедурные, текстурированные, кастомные) были слишком тёмными днём и не реагировали на свет фар (SpotLight3D) ночью. При прямом попадании фар на стену она была полностью чёрной, под углом — чуть видна.

**Корневая причина — инвертированные нормали:**

Формула нормали стены: `normal = Vector3(-dir.y * normal_sign, 0, dir.x * normal_sign)`,
где `dir = (p2 - p1).normalized()` — направление ребра стены в XZ плоскости.

Cross product winding order вершин (v1→v2→v3) **всегда** даёт нормаль `(-dir.y, 0, dir.x)` — это геометрический факт, не зависящий от CCW/CW полигона.

Проблема: `normal_sign` был `1.0` для CCW и `-1.0` для CW. Но в системе координат Godot (X вправо, Z «от камеры») 2D-координаты OSM полигонов `Vector2(x, y)` маппятся в 3D как `Vector3(x, 0, y)`. При таком маппинге CCW-обход в 2D даёт **CW** обход при виде сверху в 3D. Поэтому:

- Для CCW полигонов (signed_area > 0): `(-dir.y, 0, dir.x)` смотрит **внутрь** здания
- Для CW полигонов (signed_area < 0): `(-dir.y, 0, dir.x)` смотрит **наружу**

`normal_sign = 1.0` для CCW оставлял нормали внутрь → `dot(normal, light_dir) < 0` при прямом свете → чёрные стены.

**Исправление:**

1. **Инверсия `normal_sign`** во всех 4 местах в `osm_terrain_generator.gd`:
   ```gdscript
   # Было (НЕПРАВИЛЬНО):
   var normal_sign := 1.0 if is_ccw else -1.0
   # Стало (ПРАВИЛЬНО):
   var normal_sign := -1.0 if is_ccw else 1.0
   ```
   Затронутые функции:
   - `_create_3d_building()` — прямое создание (color override)
   - `_compute_building_mesh_thread()` — threaded путь (основной)
   - `_create_3d_building_with_texture()` — текстурированные здания
   - `_create_3d_building_with_custom_texture()` — кастомные PBR здания

2. **Шейдер `building_wall.gdshader`:**
   - Добавлен `render_mode diffuse_lambert_wrap` — мягкое затухание diffuse, свет «обворачивает» стены
   - `ROUGHNESS` снижен с 0.85 до 0.7 (процедурные) и с 0.6 до 0.55 (текстурированные)
   - Добавлен явный `SPECULAR = 0.5` для specular highlight от фар

3. **Шейдер `building_wall_custom.gdshader`:**
   - Аналогичный `diffuse_lambert_wrap`
   - `AO_LIGHT_AFFECT` снижен до 0.5 — AO меньше подавляет прямой свет (фары)
   - Добавлен `SPECULAR = 0.5`

**Файлы:**
- `osm/osm_terrain_generator.gd` — 4 места с `normal_sign`
- `osm/building_wall.gdshader` — шейдер процедурных/текстурированных стен
- `osm/building_wall_custom.gdshader` — шейдер кастомных PBR стен

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

---

## Бордюр пропадает на стыке чанков у северного шоссе

**Статус:** Открыт

**Описание:**
В одном месте на северном шоссе (~59.150372, 37.949004) бордюр не виден по краю дороги. Появилось после фикса треугольников травы на шоссе (commit 3a0ca91).

**Координаты:**
- Geo: 59.150372, 37.949004
- Локальные: ~(-20.8, -34.0), chunk -1,-1, граница с 0,-1 или -1,0

**Причина:**
Шоссе проходит через chunk -1,-1 без узлов OSM — для terrain cutout нет точной геометрии дороги (`_chunk_terrain_roads`). Cutout делается через spatial hash коридоры — простые прямоугольники по `seg.p1`/`seg.p2` с `width * 0.5` перпендикулярным отступом. Эти прямоугольники не совпадают с реальным road mesh (который строится из smoothed_points с кривизной), поэтому край террейна и бордюр оказываются не на месте.

**Попытки исправления:**
- Перенос `_chunk_terrain_roads.erase()` из `_create_deferred_terrain` в `_unload_chunk()` — не помогло

**Возможные решения:**
1. Построить точный коридор из mesh-вершин дороги для сегментов, проходящих через чанк (вместо spatial hash прямоугольников)
2. Генерировать бордюр по реальному краю road mesh (из `smoothed_points` + `width`), а не по краю terrain cutout
3. Расширить spatial hash коридоры на ~0.3м и добавить бордюр отдельно по центральной линии сегмента

**Файлы:**
- `osm/osm_terrain_generator.gd` — `_create_deferred_terrain()` ~строка 4567 (spatial hash коридоры)
- `osm/osm_terrain_generator.gd` — `_create_chunk_ground_terrain()` ~строка 10190 (генерация бордюров по краям terrain)
