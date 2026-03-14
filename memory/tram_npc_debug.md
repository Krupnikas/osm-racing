# NPC на трамвайных путях — РЕШЕНО

## Корневая причина

**Баг в `traffic/road_network.gd`**: функция `_create_directional_waypoints()` безусловно
добавляла каждый создаваемый waypoint в road-коллекции (`all_waypoints`, `waypoints_by_chunk`,
`_spatial_grid`). Когда `add_tram_segment()` вызывала эту функцию, трамвайные waypoints
попадали в road-коллекции. NPC спавнились через `get_waypoints_in_chunk()` →
находили трамвайные waypoints (w=3.0, lanes=1) → ехали по рельсам.

## Фикс (2 строки)

1. Параметр `tram_only: bool = false` в `_create_directional_waypoints()`
2. `if not tram_only:` перед добавлением в road-коллекции
3. `add_tram_segment()` передаёт `tram_only=true`

## Ограничения проекта

- НИКАКИХ воркэраундов (деспавн, gap, проверки расстояния)
- Только root cause fix
