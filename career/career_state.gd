extends Node

## CareerState - Autoload для управления профилями карьеры
##
## Сохраняет/загружает профили игроков, баланс, гараж (купленные машины), тюнинг.
## Стиль NFS Underground: покупка машин + тюнинг + гонки за деньги.

const SAVE_PATH := "user://career_profiles.cfg"
const STARTING_BALANCE := 150000
const SELL_RATIO := 0.7  # Продажа за 70% от цены покупки

# Цены на машины (в рублях)
const CAR_PRICES := {
	"matiz": 80000,
	"logan": 150000,
	"nexia": 250000,
	"polo": 300000,
	"beetle": 700000,
	"bmw_m3_gtr": 1500000,
}

# Тюнинг: 4 категории, 3 уровня
const TUNING_CATEGORIES := ["engine", "suspension", "transmission", "brakes"]
const TUNING_NAMES := {
	"engine": "Двигатель",
	"suspension": "Подвеска",
	"transmission": "Коробка",
	"brakes": "Тормоза",
}
const TUNING_MAX_LEVEL := 3
const TUNING_PRICES := {1: 20000, 2: 50000, 3: 100000}

# Призовые за вызовы (track_id -> приз за 1 место)
const CHALLENGE_PRIZES := {
	"pionerskaya": 15000,
	"fanera": 20000,
	"fanera_sprint": 25000,
}

# Множители приза по месту
const PRIZE_MULTIPLIERS := {
	1: 1.0,
	2: 0.5,
	3: 0.25,
}

# Текущий активный профиль
var active_profile: String = ""
var balance: int = 0
var owned_cars: Array[String] = []
var selected_car: String = ""
var races_won: int = 0
var total_races: int = 0
var car_tuning: Dictionary = {}  # {car_id: {category: level}}


func get_profile_names() -> Array[String]:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return []
	var result: Array[String] = []
	for section in config.get_sections():
		result.append(section)
	return result


func create_profile(profile_name: String) -> void:
	active_profile = profile_name
	balance = STARTING_BALANCE
	owned_cars = []
	selected_car = ""
	races_won = 0
	total_races = 0
	car_tuning = {}
	save_profile()


func load_profile(profile_name: String) -> bool:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return false
	if not config.has_section(profile_name):
		return false

	active_profile = profile_name
	balance = config.get_value(profile_name, "balance", STARTING_BALANCE)
	var cars_raw: Array = config.get_value(profile_name, "owned_cars", [])
	owned_cars = []
	for c in cars_raw:
		owned_cars.append(str(c))
	selected_car = config.get_value(profile_name, "selected_car", "")
	races_won = config.get_value(profile_name, "races_won", 0)
	total_races = config.get_value(profile_name, "total_races", 0)
	car_tuning = config.get_value(profile_name, "car_tuning", {})

	# Применяем выбранную машину
	if CarSettings:
		CarSettings.selected_car_id = selected_car
		CarSettings.save_settings()
	return true


func save_profile() -> void:
	if active_profile == "":
		return
	var config := ConfigFile.new()
	config.load(SAVE_PATH)  # Загружаем чтобы не потерять другие профили

	config.set_value(active_profile, "balance", balance)
	config.set_value(active_profile, "owned_cars", owned_cars as Array)
	config.set_value(active_profile, "selected_car", selected_car)
	config.set_value(active_profile, "races_won", races_won)
	config.set_value(active_profile, "total_races", total_races)
	config.set_value(active_profile, "car_tuning", car_tuning)
	config.save(SAVE_PATH)


func delete_profile(profile_name: String) -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	if config.has_section(profile_name):
		config.erase_section(profile_name)
		config.save(SAVE_PATH)
	if active_profile == profile_name:
		active_profile = ""


func select_car(car_id: String) -> void:
	if car_id in owned_cars:
		selected_car = car_id
		if CarSettings:
			CarSettings.selected_car_id = car_id
			CarSettings.save_settings()
		save_profile()


func buy_car(car_id: String) -> bool:
	if car_id in owned_cars:
		return false
	var price: int = CAR_PRICES.get(car_id, 0)
	if price <= 0 or balance < price:
		return false
	balance -= price
	owned_cars.append(car_id)
	save_profile()
	return true


func sell_car(car_id: String) -> int:
	"""Продать машину. Возвращает сумму продажи. Тюнинг теряется."""
	if car_id not in owned_cars:
		return 0
	var sell_price := get_sell_price(car_id)
	owned_cars.erase(car_id)
	if car_tuning.has(car_id):
		car_tuning.erase(car_id)
	if selected_car == car_id:
		selected_car = owned_cars[0] if not owned_cars.is_empty() else ""
		if CarSettings:
			CarSettings.selected_car_id = selected_car
			CarSettings.save_settings()
	balance += sell_price
	save_profile()
	return sell_price


func get_sell_price(car_id: String) -> int:
	return int(CAR_PRICES.get(car_id, 0) * SELL_RATIO)


func get_car_price(car_id: String) -> int:
	return CAR_PRICES.get(car_id, 0)


func can_afford(car_id: String) -> bool:
	return balance >= CAR_PRICES.get(car_id, 0)


# === Тюнинг ===

func get_tuning_level(car_id: String, category: String) -> int:
	if not car_tuning.has(car_id):
		return 0
	return car_tuning[car_id].get(category, 0)


func get_tuning_upgrade_price(car_id: String, category: String) -> int:
	var current := get_tuning_level(car_id, category)
	var next := current + 1
	if next > TUNING_MAX_LEVEL:
		return 0
	return TUNING_PRICES.get(next, 0)


func upgrade_tuning(car_id: String, category: String) -> bool:
	if car_id not in owned_cars:
		return false
	var current := get_tuning_level(car_id, category)
	if current >= TUNING_MAX_LEVEL:
		return false
	var price := get_tuning_upgrade_price(car_id, category)
	if price <= 0 or balance < price:
		return false
	balance -= price
	if not car_tuning.has(car_id):
		car_tuning[car_id] = {}
	car_tuning[car_id][category] = current + 1
	save_profile()
	return true


# === Гонки ===

func get_challenge_prize(track_id: String) -> int:
	return CHALLENGE_PRIZES.get(track_id, 10000)


func get_entry_fee(track_id: String) -> int:
	"""Взнос = 1/4 от приза за 1 место"""
	return get_challenge_prize(track_id) / 4


func can_afford_entry(track_id: String) -> bool:
	return balance >= get_entry_fee(track_id)


func pay_entry_fee(track_id: String) -> void:
	"""Списать взнос перед гонкой"""
	balance -= get_entry_fee(track_id)
	save_profile()


func award_race_prize(track_id: String, position: int) -> int:
	"""Начислить приз за гонку. Возвращает сумму приза."""
	var base_prize := get_challenge_prize(track_id)
	var multiplier: float = PRIZE_MULTIPLIERS.get(position, 0.0)
	var prize := int(base_prize * multiplier)
	total_races += 1
	if position == 1:
		races_won += 1
	if prize > 0:
		balance += prize
	save_profile()
	return prize


func format_money(amount: int) -> String:
	var s := str(amount)
	var result := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = " " + result
		result = s[i] + result
		count += 1
	return result + " руб."
