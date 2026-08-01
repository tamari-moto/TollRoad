extends PanelContainer
## 積荷画面。積載量を品目別に色分けしたバーで示し、内訳を並べる。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")

var _session: GameSession
var _title: Label
var _bar: HBoxContainer
var _icons: HBoxContainer
var _detail: Label


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"cargo_changed": _on_changed,
		"day_advanced": _on_day_advanced,
		"mount_changed": _on_mount_changed,
	})
	_session = session
	_resolve()
	refresh()


func _resolve() -> void:
	if is_instance_valid(_bar):
		return
	_title = UiUtil.find_node(self, "CargoTitle")
	_bar = UiUtil.find_node(self, "CargoBar")
	_icons = UiUtil.find_node(self, "CargoIcons")
	_detail = UiUtil.find_node(self, "CargoDetail")


func refresh() -> void:
	if _session == null:
		return
	_resolve()
	if not is_instance_valid(_bar):
		return

	var capacity: int = _session.capacity()
	var used: int = _session.cargo_weight()
	if is_instance_valid(_title):
		_title.text = "積荷 — %s（%d / %d）" % [
			GameData.MOUNTS[_session.mount]["name"], used, capacity]

	for child: Node in _bar.get_children():
		_bar.remove_child(child)
		child.queue_free()

	# 品目ごとに重量ぶんの幅を占める矩形を並べ、残りを空きとして表示する。
	var detail_parts: PackedStringArray = []
	for item_id: String in _session.cargo:
		var count: int = _session.cargo[item_id]
		var weight: int = count * GameData.ITEMS[item_id]["weight"]
		_bar.add_child(_make_segment(weight, UiTheme.item_color(item_id)))
		detail_parts.append("%s %d個" % [GameData.ITEMS[item_id]["name"], count])

	var free: int = capacity - used
	if free > 0:
		_bar.add_child(_make_segment(free, UiTheme.CARGO_EMPTY))

	if is_instance_valid(_detail):
		_detail.text = "　".join(detail_parts) if not detail_parts.is_empty() else "（空）"

	_refresh_icons()


## 積んでいる品目をアイコン付きで並べる。画像が無ければ個数だけが出る。
func _refresh_icons() -> void:
	if not is_instance_valid(_icons):
		return
	for child: Node in _icons.get_children():
		_icons.remove_child(child)
		child.queue_free()
	for item_id: String in _session.cargo:
		_icons.add_child(UiIcons.make_labeled_item(
			item_id, "×%d" % _session.cargo[item_id]))


## 重量に比例した幅を持つ色付きの区画。
func _make_segment(weight: int, color: Color) -> Control:
	var rect := ColorRect.new()
	rect.color = color
	rect.custom_minimum_size = Vector2(0, 24)
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.size_flags_stretch_ratio = float(weight)
	return rect


func _on_changed() -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()


func _on_mount_changed(_mount_id: String) -> void:
	refresh()
