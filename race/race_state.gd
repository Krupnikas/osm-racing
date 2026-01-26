extends Node

## Глобальное состояние гонки (Autoload)
## Используется для передачи данных между сценами

# Выбранный трек для загрузки в RaceScene
var selected_track = null

# Свободная езда - локация и координаты
var free_roam_location: String = ""
var free_roam_lat: float = 0.0
var free_roam_lon: float = 0.0

# (Legacy) Трасса для автозапуска после перезагрузки сцены
var pending_track = null
