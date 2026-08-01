extends Node2D
## メイン画面。HUD と航海日誌を表示し、休息で日を進められる。
##
## ゲームのルールは GameState.session（GameSession）にあり、ここは
## 表示と入力の橋渡しのみを行う。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

## 航海日誌に表示する最大件数。古いものから捨てる。
const LOG_DISPLAY_LIMIT: int = 200

@onready var _hud: PanelContainer = %HUD
@onready var _market_panel: PanelContainer = %MarketPanel
@onready var _cargo_panel: PanelContainer = %CargoPanel
@onready var _map_panel: PanelContainer = %MapPanel
@onready var _log_scroll: ScrollContainer = %LogScroll
@onready var _log_list: VBoxContainer = %LogList
@onready var _rest_button: Button = %RestButton
@onready var _status_label: Label = %StatusLabel

var _session: GameSession


func _ready() -> void:
	_session = GameState.session
	print("TollRoad start. Day: %d/%d, Silver: %d, City: %s" % [
		_session.day, GameData.TOTAL_DAYS, _session.silver, _session.current_city])

	_hud.bind(_session)
	_market_panel.bind(_session)
	_cargo_panel.bind(_session)
	_map_panel.bind(_session)

	_session.logged.connect(_append_log)
	_session.day_advanced.connect(_on_day_advanced)

	_rest_button.pressed.connect(_on_rest_pressed)

	for entry: String in _session.log_entries:
		_append_log(entry)
	_refresh_status()


func _on_rest_pressed() -> void:
	_session.rest()


func _on_day_advanced(_day: int) -> void:
	# 移動で現在地が変わると市場の相場も変わるため、まとめて更新する。
	_market_panel.refresh()
	_map_panel.refresh()
	_refresh_status()


func _refresh_status() -> void:
	if _session.is_over():
		_rest_button.disabled = true
		_status_label.text = "60日が終了した。純資産 %d（%s）" % [_session.net_worth(), _session.rank()]
		return
	if _session.is_stranded():
		_status_label.text = "資金が尽きて移動できない。休息して島の収入を待つしかない。"
	else:
		_status_label.text = ""


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
