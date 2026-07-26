extends Node

## Чистый выход из игры.
## Обычный quit падает при teardown движка: WorkerThreadPool::finish() уничтожает висящие
## bound-Callable (задачи стриминга чанков) уже полу-снесённого GDScript → SIGSEGV и окно
## ошибки macOS при Cmd+Q / «Выход». Career сохраняется по ходу игры, настройки stateless —
## на выходе критичного сохранять нечего, поэтому жёстко завершаем процесс (SIGKILL):
## мгновенно, без crash-handler и без диалога.

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if get_tree():
		get_tree().set_auto_accept_quit(false)  # перехватываем закрытие окна / Cmd+Q


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		quit_clean()


## Единая точка выхода. Кнопки «Выход» должны звать её вместо get_tree().quit().
func quit_clean() -> void:
	# Защитно сохраняем карьеру (она и так пишется по ходу игры).
	var cs := get_node_or_null("/root/CareerState")
	if cs and cs.has_method("save_profile"):
		cs.save_profile()
	OS.kill(OS.get_process_id())
