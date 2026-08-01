extends Node2D
## メイン画面。各画面パネルを束ね、日誌とリザルトを扱う。
##
## ゲームのルールは GameState.session（GameSession）にあり、ここは
## 表示と入力の橋渡しのみを行う。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

## 航海日誌に表示する最大件数。古いものから捨てる。
const LOG_DISPLAY_LIMIT: int = 200

@onready var _hud: PanelContainer = %HUD
@onready var _log_scroll: ScrollContainer = %LogScroll
@onready var _log_list: VBoxContainer = %LogList
@onready var _rest_button: Button = %RestButton
@onready var _result_button: Button = %ResultButton
@onready var _status_label: Label = %StatusLabel
@onready var _result_dialog: Window = %ResultDialog

var _session: GameSession

## bind と refresh を持つ画面パネル。日送り時にまとめて更新する。
var _panels: Array[Node] = []


func _ready() -> void:
	_panels = [%MarketPanel, %CargoPanel, %大陸図, %製作所, %相場メモ, %島と装備]

	_rest_button.pressed.connect(_on_rest_pressed)
	_result_button.pressed.connect(_show_result)
	_result_dialog.restart_requested.connect(_on_restart_requested)

	_bind_session(GameState.session)


## セッションを各画面に配る。再プレイ時にも呼ばれる。
func _bind_session(session: GameSession) -> void:
	_session = session
	print("TollRoad start. Day: %d/%d, Silver: %d, City: %s" % [
		_session.day, GameData.TOTAL_DAYS, _session.silver, _session.current_city])

	_hud.bind(_session)
	for panel: Node in _panels:
		panel.bind(_session)
	_result_dialog.bind(_session)

	_session.logged.connect(_append_log)
	_session.day_advanced.connect(_on_day_advanced)

	_clear_log()
	for entry: String in _session.log_entries:
		_append_log(entry)

	_rest_button.disabled = false
	_result_button.visible = false
	_refresh_status()


func _on_rest_pressed() -> void:
	_session.rest()


func _on_day_advanced(_day: int) -> void:
	# 移動で現在地が変わると相場も製作ボーナスも変わるため、まとめて更新する。
	for panel: Node in _panels:
		panel.refresh()
	_refresh_status()

	if _session.is_over():
		_show_result()


func _refresh_status() -> void:
	if _session.is_over():
		_rest_button.disabled = true
		_result_button.visible = true
		_status_label.text = "60日が終了した。純資産 %d（%s）" % [
			_session.net_worth(), _session.rank()]
		return
	if _session.is_stranded():
		_status_label.text = "資金が尽きて移動できない。休息して島の収入を待つしかない。"
	else:
		_status_label.text = ""


func _show_result() -> void:
	_result_dialog.show_result()


func _on_restart_requested() -> void:
	# 古いセッションのシグナルは新しいセッションに繋ぎ替えるので切っておく。
	if _session.logged.is_connected(_append_log):
		_session.logged.disconnect(_append_log)
	if _session.day_advanced.is_connected(_on_day_advanced):
		_session.day_advanced.disconnect(_on_day_advanced)

	GameState.start_new_game()
	_bind_session(GameState.session)


func _clear_log() -> void:
	for child: Node in _log_list.get_children():
		_log_list.remove_child(child)
		child.queue_free()


func _append_log(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_list.add_child(label)

	while _log_list.get_child_count() > LOG_DISPLAY_LIMIT:
		var oldest: Node = _log_list.get_child(0)
		_log_list.remove_child(oldest)
		oldest.queue_free()

	# 追加直後はまだレイアウトが確定していないので、1フレーム待ってから最下部へ。
	await get_tree().process_frame
	if is_instance_valid(_log_scroll):
		_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)
