extends Window
## 60日終了時のリザルト画面。純資産の内訳とランクを示す。
##
## 純資産 = シルバー + (積荷 + 島倉庫) の基準価格 × 0.9 という式を、
## 内訳として分解して見せる（何が効いたのかを振り返れるように）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

signal restart_requested

const COLOR_LEGENDARY := UiTheme.RANK_LEGENDARY
const COLOR_MASTER := UiTheme.RANK_MASTER
const COLOR_NORMAL := UiTheme.RANK_NORMAL
const COLOR_BANKRUPT := UiTheme.RANK_BANKRUPT

var _session: GameSession
var _rank_label: Label
var _net_worth_label: Label
var _breakdown: VBoxContainer
var _restart_button: Button
var _close_button: Button


func bind(session: GameSession) -> void:
	_session = session
	_resolve()


func _resolve() -> void:
	if is_instance_valid(_rank_label):
		return
	_rank_label = UiUtil.find_node(self, "RankLabel")
	_net_worth_label = UiUtil.find_node(self, "NetWorthLabel")
	_breakdown = UiUtil.find_node(self, "Breakdown")
	_restart_button = UiUtil.find_node(self, "RestartButton")
	_close_button = UiUtil.find_node(self, "CloseButton")

	if is_instance_valid(_restart_button) and not _restart_button.pressed.is_connected(_on_restart):
		_restart_button.pressed.connect(_on_restart)
	if is_instance_valid(_close_button) and not _close_button.pressed.is_connected(_on_close):
		_close_button.pressed.connect(_on_close)
	if not close_requested.is_connected(_on_close):
		close_requested.connect(_on_close)


## 結果を組み立てて表示する。
func show_result() -> void:
	if _session == null:
		return
	_resolve()
	_populate()
	popup_centered()


func _populate() -> void:
	var rank_name: String = _session.rank()
	if is_instance_valid(_rank_label):
		_rank_label.text = rank_name
		_rank_label.add_theme_color_override("font_color", _rank_color(rank_name))

	if is_instance_valid(_net_worth_label):
		_net_worth_label.text = "純資産 %s シルバー" % UiUtil.format_number(_session.net_worth())

	if not is_instance_valid(_breakdown):
		return
	for child: Node in _breakdown.get_children():
		_breakdown.remove_child(child)
		child.queue_free()

	var cargo_value: int = _stock_value(_session.cargo)
	var warehouse_value: int = _stock_value(_session.warehouse)
	var stock_total: int = int(round((cargo_value + warehouse_value) * GameData.NET_WORTH_STOCK_RATE))

	_add_row("所持シルバー", UiUtil.format_number(_session.silver))
	_add_row("積荷の基準価格", UiUtil.format_number(cargo_value))
	_add_row("島倉庫の基準価格", UiUtil.format_number(warehouse_value))
	_add_row("在庫の評価額（×0.9）", UiUtil.format_number(stock_total))
	_add_separator()
	_add_row("島レベル", "%d（労働者 %d 人）" % [_session.island_level, _session.worker_count()])
	_add_row("騎乗", "%s（積載 %d）" % [
		GameData.MOUNTS[_session.mount]["name"], _session.capacity()])
	_add_row("行動記録", "%d 件" % _session.log_entries.size())

	# 次のランクまでどれだけ足りなかったかを示す。
	var next_threshold: int = _next_threshold(_session.net_worth())
	if next_threshold > 0:
		_add_separator()
		_add_row("次のランクまで", "あと %s" % UiUtil.format_number(next_threshold - _session.net_worth()))


func _stock_value(stock: Dictionary) -> int:
	var total: int = 0
	for item_id: String in stock:
		total += GameData.ITEMS[item_id]["base_price"] * stock[item_id]
	return total


## その純資産の1つ上のランクの閾値。最上位なら -1。
static func _next_threshold(net_worth: int) -> int:
	var best: int = -1
	for rank: Dictionary in GameData.RANKS:
		var threshold: int = rank["threshold"]
		if threshold > net_worth and (best < 0 or threshold < best):
			best = threshold
	return best


static func _rank_color(rank_name: String) -> Color:
	return UiTheme.rank_color(rank_name)


func _add_row(label_text: String, value_text: String) -> void:
	var row := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = label_text
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	row.add_child(name_label)

	var value_label := Label.new()
	value_label.text = value_text
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	_breakdown.add_child(row)


func _add_separator() -> void:
	_breakdown.add_child(HSeparator.new())


func _on_restart() -> void:
	hide()
	restart_requested.emit()


func _on_close() -> void:
	hide()
