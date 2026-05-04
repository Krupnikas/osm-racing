# Overpass API Server

Свой инстанс Overpass API на `mc.skrup.ru:12346`. Обслуживает все города игры из одного контейнера.

**Приоритетный сервер**: игра шлёт ВСЕ запросы сначала на этот сервер (без round-robin). Публичные серверы используются только как fallback если наш на cooldown (429/503). Логика в `_pick_available_server()` в `osm_loader.gd`.

## Текущая конфигурация

| Параметр | Значение |
|----------|---------|
| Хост | `mc.skrup.ru` |
| Порт | `12346` |
| URL | `http://mc.skrup.ru:12346/api/interpreter` |
| Контейнер | `overpass-cities` |
| Docker volume | `overpass_db_all` (локальный диск) |
| Исходники | `~/jotta/overpass/` (Jottacloud FUSE mount) |
| Образ | `wiktorn/overpass-api` |
| Rate limit | `OVERPASS_RATE_LIMIT=0` (без ограничений) |
| RAM | ~500MB–1GB (4 города) |

### Города в инстансе

| Город | Geofabrik регион | Файл извлечения | Bbox (lon_min,lat_min,lon_max,lat_max) |
|-------|-----------------|----------------|----------------------------------------|
| Череповец | Northwestern Fed. District | cherepovets.osm.pbf (1.7MB) | 37.67,59.06,38.05,59.19 |
| Москва | Central Fed. District | moscow.osm.pbf (31MB) | 37.45,55.75,37.75,55.95 |
| Тбилиси | Georgia | tbilisi.osm.pbf (11MB) | 44.65,41.65,44.85,41.80 |
| Дубай | GCC States | dubai.osm.pbf (23MB) | 55.05,25.05,55.55,25.35 |

Все 4 города объединены в `all_cities.osm.bz2` (~103MB).

### Файлы на сервере (`~/jotta/overpass/`)

```
# Регионы Geofabrik (можно удалить после извлечения городов)
northwestern.osm.pbf   # 608MB
central.osm.pbf        # 861MB
georgia.osm.pbf        #  95MB
gcc-states.osm.pbf     # 600MB

# Извлечения городов (хранить!)
cherepovets.osm.pbf    # 1.7MB
moscow.osm.pbf         #  31MB
tbilisi.osm.pbf        #  11MB
dubai.osm.pbf          #  23MB

# Объединённые файлы (хранить!)
all_cities.osm.pbf     #  67MB
all_cities.osm.bz2     # 103MB — используется для инициализации Overpass

# Скрипт запуска
run.sh                 # entrypoint: фиксит permissions, запускает supervisord
```

## Управление контейнером

```bash
ssh sergey@mc.skrup.ru

# Статус
docker ps | grep overpass

# Логи
docker logs overpass-cities --tail 20

# Перезапуск
docker restart overpass-cities

# Остановка / запуск
docker stop overpass-cities
docker start overpass-cities
```

## Как добавить новый город

Все операции выполняются на сервере (`ssh sergey@mc.skrup.ru`).

### 1. Скачать регион с Geofabrik

Найти нужный регион на https://download.geofabrik.de/ и скачать PBF:

```bash
curl -L -o ~/jotta/overpass/REGION.osm.pbf 'https://download.geofabrik.de/path/to/region-latest.osm.pbf'
```

### 2. Вырезать bbox города

Bbox определяется как `lon_min,lat_min,lon_max,lat_max`. Используем osmium через Docker (не нужно устанавливать на сервер):

```bash
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool extract \
  --bbox LON_MIN,LAT_MIN,LON_MAX,LAT_MAX \
  /data/REGION.osm.pbf \
  -o /data/CITY.osm.pbf --overwrite
```

### 3. Объединить все города

```bash
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool merge \
  /data/cherepovets.osm.pbf \
  /data/moscow.osm.pbf \
  /data/tbilisi.osm.pbf \
  /data/dubai.osm.pbf \
  /data/CITY.osm.pbf \
  -o /data/all_cities.osm.pbf --overwrite
```

### 4. Конвертировать в bz2

Overpass API ожидает `.osm.bz2`:

```bash
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool cat /data/all_cities.osm.pbf \
  -o /data/all_cities.osm.bz2 --overwrite
```

### 5. Пересоздать контейнер

```bash
# Остано��ить и удалить старый контейнер
docker stop overpass-cities && docker rm overpass-cities

# Удалить старый volume с БД
docker volume rm overpass_db_all

# Инициализ��ровать новую БД
docker run --rm \
  -e OVERPASS_META=yes \
  -e OVERPASS_MODE=init \
  -e OVERPASS_PLANET_URL=file:///db/source/all_cities.osm.bz2 \
  -e OVERPASS_RULES_LOAD=10 \
  -e OVERPASS_USE_AREAS=false \
  -v overpass_db_all:/db \
  -v ~/jotta/overpass:/db/source \
  wiktorn/overpass-api

# Запустить рабочий контейнер (rate limit отключён — свой сервер)
docker run -d \
  -v overpass_db_all:/db \
  -v ~/jotta/overpass/run.sh:/run.sh:ro \
  --entrypoint /bin/bash \
  -e OVERPASS_RATE_LIMIT=0 \
  -e OVERPASS_MAX_TIMEOUT=60s \
  -p 12346:80 \
  --restart unless-stopped \
  --name overpass-cities \
  wiktorn/overpass-api /run.sh
```

### 6. Проверить

```bash
# Простой тест
curl -s -d 'data=[out:json];node(1);out 1;' http://localhost:12346/api/interpreter

# Тест запроса к новому городу
curl -s -d 'data=[out:json][timeout:10];way["highway"](LAT1,LON1,LAT2,LON2);out body geom;' \
  http://localhost:12346/api/interpreter | python3 -c 'import json,sys; d=json.load(sys.stdin); print("Elements:", len(d.get("elements",[])))'
```

## Где прописан сервер в игре

1. **`osm/osm_loader.gd`**:
   - Массив `OVERPASS_SERVERS` — наш сервер первый (index 0)
   - `_pick_available_server()` — всегда выбирает index 0 если не на cooldown, остальные как fallback
   - Массивы `_server_cooldown_until` и `_last_request_time` должны соответствовать количеству серверов
   ```gdscript
   const OVERPASS_SERVERS := [
       "http://mc.skrup.ru:12346/api/interpreter",  # приоритетный
       "https://overpass.kumi.systems/api/interpreter",
       ...
   ]
   ```

2. **`tools/precache_overpass.py`** — массив `REMOTE_SERVERS`, первый элемент.

## Важные нюансы

### Почему БД на локальном диске, а не на jotta
Overpass dispatcher использует Unix domain sockets для IPC. FUSE-маунты (rclone/jotta) не поддерживают сокеты — dispatcher падает с `Address already in use`. Поэтому рабочая БД хранится в Docker volume на локальном диске (`overpass_db_all`), а исходные PBF/bz2 файлы — на jotta.

### Запросы за пределами загруженных городов
Если игрок окажется за пределами bbox загруженных городов, Overpass вернёт пустой ответ (0 элементов). Игра обработает это нормально — просто не будет зданий/дорог. Для полного покрытия нужен planet.osm.pbf (~70GB, ~32-64GB RAM) — на текущем сервере (8GB RAM) это невозможно.

### Обновление данных OSM
Geofabrik обновляет PBF ежедневно. Чтобы обновить данные, повторите весь процесс (скачать PBF → извлечь → объединить → переинициализировать). `OVERPASS_DIFF_URL` не настроен — автообновлений нет.
