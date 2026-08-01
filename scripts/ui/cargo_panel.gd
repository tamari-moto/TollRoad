extends PanelContainer
## 積荷画面。積載量を品目別に色分けしたバーで示し、内訳を並べる。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

## 品目ごとの表示色。資源は寒色〜土色、装備は暖色で系統を分ける。
const ITEM_COLORS: Dictionary = {
	"ore":   Color(0.55, 0.58, 0.65),
	"wood":  Color(0.55, 0.42, 0.28),
	"fiber": Color(0.45, 0.65, 0.55),
	"hide":  Color(0.68, 0.5, 0.35),
	"stone": Color(0.5, 0.5, 0.5),
	"sword": Color(0.85, 0.45, 0.4),
	"bow":   Color(0.8, 0.65, 0.35),
	"robe":  Color(0.65, 0.45, 0.75),
	"armor": Color(0.8, 0.55, 0.3),
}

var _session: GameSession
var _title: Label
var _bar: HBoxContainer
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
		_bar.add_child(_make_segment(weight, ITEM_COLORS.get(item_id, Color.GRAY)))
		detail_parts.append("%s %d個" % [GameData.ITEMS[item_id]["name"], count])

	var free: int = capacity - used
	if free > 0:
		_bar.add_child(_make_segment(free, Color(0.2, 0.2, 0.22)))

	if is_instance_valid(_detail):
		_detail.text = "　".join(detail_parts) if not detail_parts.is_empty() else "（空）"


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
