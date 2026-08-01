extends PanelContainer
## 大陸図。6都市をボタンとして並べ、押すと移動確認ダイアログを出す。
##
## 環状の5都市とカーレオン（中央・黒ゾーン）で経路条件が異なるため、
## 各ボタンに日数・費用・襲撃率を併記して選択前に判断できるようにする。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

signal move_requested(city_id: String)

const COLOR_CURRENT := UiTheme.FOCUS
const COLOR_DANGER := UiTheme.WARN

var _session: GameSession
var _list: VBoxContainer
var _buttons: Dictionary = {}
var _confirm: ConfirmationDialog
var _pending_city: String = ""


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"day_advanced": _on_day_advanced,
		"silver_changed": _on_silver_changed,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if not _buttons.is_empty():
		return
	_list = UiUtil.find_node(self, "CityList")
	if _list == null:
		return

	# 環状の並び順に王国都市を置き、最後にカーレオン。
	var ordered: Array[String] = GameData.royal_city_ids()
	ordered.append(GameData.CAERLEON)
	for city_id: String in ordered:
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, 36)
		button.pressed.connect(_on_city_pressed.bind(city_id))
		_list.add_child(button)
		_buttons[city_id] = button

	_confirm = ConfirmationDialog.new()
	_confirm.title = "移動の確認"
	_confirm.ok_button_text = "移動する"
	_confirm.cancel_button_text = "やめる"
	_confirm.confirmed.connect(_on_confirmed)
	add_child(_confirm)


func refresh() -> void:
	if _session == null or _buttons.is_empty():
		return
	var over: bool = _session.is_over()
	for city_id: String in _buttons:
		var button: Button = _buttons[city_id]
		if not is_instance_valid(button):
			continue
		var city_name: String = GameData.CITIES[city_id]["name"]

		if city_id == _session.current_city:
			button.text = "%s（現在地）" % city_name
			button.disabled = true
			button.add_theme_color_override("font_color", COLOR_CURRENT)
			continue

		button.remove_theme_color_override("font_color")
		var route: Dictionary = _session.route_to(city_id)
		if route.is_empty():
			button.text = city_name
			button.disabled = true
			continue

		var note: String = "%d日 / %d" % [route["days"], route["cost"]]
		if route["raid_chance"] > 0.0:
			note += " / 襲撃%d%%" % int(round(route["raid_chance"] * 100.0))
			button.add_theme_color_override("font_color", COLOR_DANGER)
		button.text = "%s　%s" % [city_name, note]
		button.disabled = over or not _session.can_move_to(city_id)


func _on_city_pressed(city_id: String) -> void:
	var route: Dictionary = _session.route_to(city_id)
	if route.is_empty():
		return
	_pending_city = city_id

	var lines: PackedStringArray = []
	lines.append("%s へ移動しますか？" % GameData.CITIES[city_id]["name"])
	lines.append("")
	lines.append("日数: %d日　費用: %s シルバー" % [route["days"], UiUtil.format_number(route["cost"])])
	if route["raid_chance"] > 0.0:
		lines.append("")
		lines.append("黒ゾーンを通ります。%d%% の確率で襲撃され、" % int(round(route["raid_chance"] * 100.0)))
		lines.append("積荷を全て失います（シルバーと島倉庫は無事）。")
		if _session.cargo_weight() > 0:
			lines.append("現在の積荷: %d / %d" % [_session.cargo_weight(), _session.capacity()])

	_confirm.dialog_text = "\n".join(lines)
	_confirm.popup_centered()


func _on_confirmed() -> void:
	if _pending_city == "":
		return
	move_requested.emit(_pending_city)
	_session.move_to(_pending_city)
	_pending_city = ""
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()


func _on_silver_changed(_amount: int) -> void:
	refresh()
