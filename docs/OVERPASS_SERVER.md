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
| Docker volume | `overpass_db_v2` (локальный диск; старый `overpass_db_all` оставлен для отката) |
| Исходники | `~/jotta/overpass/` (Jottacloud FUSE mount) |
| Образ | `wiktorn/overpass-api` |
| Rate limit | `OVERPASS_RATE_LIMIT=0` (без ограничений) |
| RAM | ~1–2GB (6 городов) — СПб (плотный, в пределах КАД) пока НЕ добавлен; следить за лимитом 8GB |

### Города в инстансе

| Город | Geofabrik регион | Файл извлечения | Bbox (lon_min,lat_min,lon_max,lat_max) |
|-------|-----------------|----------------|----------------------------------------|
| Череповец | Northwestern Fed. District | cherepovets.osm.pbf (1.7MB) | 37.67,59.06,38.05,59.19 |
| Москва | Central Fed. District | moscow.osm.pbf (31MB) | 37.45,55.75,37.75,55.95 |
| Тбилиси | Georgia | tbilisi.osm.pbf (11MB) | 44.65,41.65,44.85,41.80 |
| Дубай | GCC States | dubai.osm.pbf (23MB) | 55.05,25.05,55.55,25.35 |
| Донецк (весь город) | donetsk_oblast.osm.pbf (Geofabrik Ukraine) | donetsk.osm.pbf | 37.65,47.87,37.99,48.14 |
| Анталья (весь город) | mediterranean.osm.pbf (кусок Турции) | antalya.osm.pbf | 30.52,36.82,30.90,37.03 |

Все 6 городов объединены в `all_cities.osm.bz2` (**129MB**; pbf 83MB). ✅ **Донецк и Анталья залиты и проверены 2026-06-22** (curl: Донбасс Арена 1177 highways, Коньяалты 1282; Череповец/Дубай целы; см. «История деплоя» ниже).

**Санкт-Петербург (в пределах КАД)** — ⏸ подготовлен, но пока НЕ добавлен в инстанс. `spb_kad.osm.pbf` (51M) уже извлечён и лежит на сервере, но в merge НЕ включён (curl в bbox СПб отдаёт 0 — подтверждено). Чтобы добавить позже — раскомментировать его в команде merge и пересобрать.

> ⚠️ Bbox в таблице — в порядке **osmium** `lon_min,lat_min,lon_max,lat_max`. В запросе Overpass из игры порядок ОБРАТНЫЙ (`lat,lon,lat,lon`) — см. «Порядок координат» ниже.

### Файлы на сервере (`~/jotta/overpass/`)

```
# Регионы Geofabrik (можно удалить после извлечения городов)
northwestern.osm.pbf   # 608MB
central.osm.pbf        # 861MB
georgia.osm.pbf        #  95MB
gcc-states.osm.pbf     # 600MB

# Исходники новых городов (скачаны отдельно; хранить до извлечения)
donetsk_oblast.osm.pbf    # источник Донецка (Geofabrik Ukraine)
mediterranean.osm.pbf     # источник Антальи (кусок Турции)
saint_petersburg.osm.pbf  # источник СПб — ⏸ подготовка, пока не добавляем

# Извлечения городов (хранить!)
cherepovets.osm.pbf    # 1.7MB
moscow.osm.pbf         #  31MB
tbilisi.osm.pbf        #  11MB
dubai.osm.pbf          #  23MB
donetsk.osm.pbf        # 9.3M — из donetsk_oblast.osm.pbf
antalya.osm.pbf        # 5.8M — из mediterranean.osm.pbf
spb_kad.osm.pbf        # 51M — из saint_petersburg.osm.pbf (по bbox КАД) — ⏸ подготовлен, пока НЕ в merge

# Объединённые файлы (хранить!)
all_cities.osm.pbf     # 83M (6 городов)
all_cities.osm.bz2     # 129M (6 городов) — для инициализации Overpass
all_cities.osm.pbf.bak_4cities   # 67M — бэкап старой версии (4 города), для отката
all_cities.osm.bz2.bak_4cities   # 103M — бэкап старой версии (4 города), для отката

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

#### Готовые команды для Донецка / СПб / Антальи

```bash
# Донецк (весь город) — из donetsk_oblast.osm.pbf
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool extract --bbox 37.65,47.87,37.99,48.14 \
  /data/donetsk_oblast.osm.pbf -o /data/donetsk.osm.pbf --overwrite

# Санкт-Петербург — ⏸ ПОДГОТОВКА (пока НЕ добавляем в merge/инстанс)
# Обрезаем по КАД (материковая часть, без дамбы/Кронштадта)
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool extract --bbox 30.05,59.77,30.56,60.10 \
  /data/saint_petersburg.osm.pbf -o /data/spb_kad.osm.pbf --overwrite

# Анталья (весь город) — из mediterranean.osm.pbf (кусок Турции)
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool extract --bbox 30.52,36.82,30.90,37.03 \
  /data/mediterranean.osm.pbf -o /data/antalya.osm.pbf --overwrite
```

> СПб: bbox — прямоугольник вокруг кольца КАД, не сам контур. Чтобы включить
> Кронштадт и дамбу (КЗС), сдвинь западную границу с `30.05` до `29.65`.

### 3. Объединить все города

```bash
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool merge \
  /data/cherepovets.osm.pbf \
  /data/moscow.osm.pbf \
  /data/tbilisi.osm.pbf \
  /data/dubai.osm.pbf \
  /data/donetsk.osm.pbf \
  /data/antalya.osm.pbf \
  -o /data/all_cities.osm.pbf --overwrite
  # /data/spb_kad.osm.pbf \   # ⏸ СПб подготовлен — раскомментировать, когда решим добавить

# Примечание: перечисляй ВСЕ города инстанса. При добавлении нового
# просто допиши его .osm.pbf в этот список и пересобери all_cities.
```

### 4. Конвертировать в bz2

Overpass API ожидает `.osm.bz2`:

```bash
docker run --rm --entrypoint osmium -v ~/jotta/overpass:/data \
  stefda/osmium-tool cat /data/all_cities.osm.pbf \
  -o /data/all_cities.osm.bz2 --overwrite
```

### 5. Пересоздать контейнер

> 💡 **Zero-downtime вариант (рекомендуется, так делался деплой 2026-06-22):**
> вместо удаления рабочего volume инициализируй БД в **новый** volume (`overpass_db_v2`),
> пока старый контейнер продолжает обслуживать игру. Init читает bz2 — это несколько минут.
> Когда init закончится — мгновенно подменить контейнер на новый volume (простой = секунды),
> а старый volume оставить для отката. Команды init/подмены — те же, что ниже, но с
> `-v overpass_db_v2:/db` и без `docker volume rm` рабочего тома.
> Источник bz2 при init можно монтировать из локальной staging-папки (`-v ~/overpass_work:/db/source`) —
> быстрее, чем читать с jotta.

Классический (с простоем) вариант:

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

## История деплоя

### 2026-06-22 — добавлены Донецк и Анталья (zero-downtime)
- Исходники (`donetsk_oblast.osm.pbf` 55M, `mediterranean.osm.pbf` 95M, `saint_petersburg.osm.pbf` 72M) загружены с локального Мака в staging `~/overpass_work/src/`.
- Извлечены bbox → `donetsk.osm.pbf` (9.3M, 954k нод), `antalya.osm.pbf` (5.8M, 652k нод), `spb_kad.osm.pbf` (51M — подготовка).
- Merge **Донецк+Анталья** (СПб НЕ включён) → `all_cities.osm.pbf` 83M → `all_cities.osm.bz2` 129M.
- Init в **новый** volume `overpass_db_v2` (~5 мин), старый контейнер всё это время обслуживал игру. Затем мгновенная подмена контейнера. Простой ≈ секунды.
- Проверка curl: Донбасс Арена 1177 highways, Коньяалты 1282, Череповец 4050, Дубай 6550, СПб 0 (корректно отсутствует).
- **Откат:** старый volume `overpass_db_all` цел; на jotta — `all_cities.osm.{pbf,bz2}.bak_4cities`.
- **Незавершённое (game-side):** для Антальи нужна точка старта free-roam + кнопка в `ui/location_select.gd` (рекоменд. Коньяалты `36.8730, 30.6480`). Донбасс Арена уже заведена. СПб не добавлен (по решению — только подготовлен).
- **Можно почистить позже:** staging `~/overpass_work/` и volume `overpass_db_all`, когда новый инстанс подтверждён в игре.

## Важные нюансы

### Почему БД на локальном диске, а не на jotta
Overpass dispatcher использует Unix domain sockets для IPC. FUSE-маунты (rclone/jotta) не поддерживают сокеты — dispatcher падает с `Address already in use`. Поэтому рабочая БД хранится в Docker volume на локальном диске (`overpass_db_all`), а исходные PBF/bz2 файлы — на jotta.

### Точки старта free-roam (НЕ забыть!)
Данные на сервере ≠ доступная локация в игре. Чтобы в город можно было заехать в free-roam, нужна **точка старта внутри bbox** и кнопка в меню — заводится в `ui/location_select.gd` (массив `LOCATIONS`, поля `lat`/`lon`).
- ✅ **Донбасс Арена** — `48.0200783, 37.8068528` (внутри bbox Донецка) — уже добавлена.
- ⬜ **Анталья** — точка старта не выбрана. Любая точка внутри `lat 36.82..37.03, lon 30.52..30.90`.
- ⏸ **Санкт-Петербург** — город пока НЕ добавлен в инстанс (подготовлен). Когда добавим: точка старта внутри `lat 59.77..60.10, lon 30.05..30.56`.

### Порядок координат — легко перепутать
- osmium `--bbox` = `LON_MIN,LAT_MIN,LON_MAX,LAT_MAX` (запад,юг,восток,север).
- Запрос Overpass в игре (`osm_loader.gd`) = `(LAT_MIN,LON_MIN,LAT_MAX,LON_MAX)` (юг,запад,север,восток) — порядок **обратный**. Не перепутать при ручной проверке через `curl`.

### Высоты (elevation) — отдельная система, сервер их НЕ ускоряет
Работа с skrup.ru ускоряет только Overpass (дороги/здания). Высоты тянутся с opentopodata (SRTM, 1 запрос/сек, `elevation_loader.gd`) и от нашего сервера не зависят — первый заезд в новый район всё равно будет ждать высоты (это был основной тормоз при первой загрузке Донецка). Для мгновенного старта кэш высот нужно прогревать отдельно.

### Запросы за пределами загруженных городов
Если игрок окажется за пределами bbox загруженных городов, Overpass вернёт пустой ответ (0 элементов). Игра обработает это нормально — просто не будет зданий/дорог. Для полного покрытия нужен planet.osm.pbf (~70GB, ~32-64GB RAM) — на текущем сервере (8GB RAM) это невозможно.

### Обновление данных OSM
Geofabrik обновляет PBF ежедневно. Чтобы обновить данные, повторите весь процесс (скачать PBF → извлечь → объединить → переинициализировать). `OVERPASS_DIFF_URL` не настроен — автообновлений нет.
