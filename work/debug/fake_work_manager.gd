extends Node

## Минимальный двойник WorkManager — ТОЛЬКО для превью HUD (work/debug).
## Реализует крючки, которые читает work_hud.gd. Геймплея нет.
## В продакшн не подключается.

signal order_spawned(pickup_pos: Vector3)
signal order_accepted(fare: int, destination: String)
signal order_completed(result: Dictionary)
signal balance_changed(new_balance: int)
signal bonus_updated(speed_pct: float, safe_pct: float)

var state: int = 0          # 0=SEARCHING, 2=DRIVING, 3=AT_DROPOFF
var elapsed: float = 0.0
var estimated: float = 0.0
var speed_pct: float = 1.0
var safe_pct: float = 1.0
var dest: String = "ул. Ленина"
var dropoff: Vector3 = Vector3.ZERO
var car: Node3D = null


func get_state() -> int: return state
func get_trip_elapsed() -> float: return elapsed
func get_estimated_time() -> float: return estimated
func get_speed_pct() -> float: return speed_pct
func get_safe_pct() -> float: return safe_pct
func get_car() -> Node3D: return car
func get_dropoff_pos() -> Vector3: return dropoff
func get_destination_name() -> String: return dest
func accept_order() -> void: pass
func decline_order() -> void: pass
func finish_result_screen() -> void: pass
