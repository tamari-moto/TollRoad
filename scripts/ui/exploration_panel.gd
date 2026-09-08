extends PanelContainer
## 探索。現在地に応じた討伐/遺跡探索を1日かけて行う。
##
## **探索スロット（GameData.EXPLORE_SLOT_COUNT 枠）に挿した戦闘装備だけ**が
## 成功率に効き、失敗したときに失われる。積荷に何個あるかは関係しない。
## 成功した場合はスロットの中身は減らない（消費は失敗時のみ）。
##
## スロットは積荷とは別の置き場なので、挿すと積荷から出て積載重量が空く。
## 戻すには積載に空きが要る（無ければ GameSession.unequip_slot() が false）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")

var _session: GameSession
var _title: Label
var _chance_label: Label
var _slots_row: HBoxContainer
var _equip_list: VBoxContainer
var _hint_label: Label
var _explore_button: Button


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _on_silver_changed,
		"cargo_changed": _on_changed,
		"day_advanced": _on_day_advanced,
	})
	_session = session
	_resolve()
	refresh()


func _resolve() -> void:
	if is_instance_valid(_explore_button):
		return
	_title = UiUtil.find_node(self, "ExplorationTitle")
	_chance_label = UiUtil.find_node(self, "ChanceLabel")
	_slots_row = UiUtil.find_node(self, "SlotsRow")
	_equip_list = UiUtil.find_node(self, "EquipList")
	_hint_label = UiUtil.find_node(self, "HintLabel")
	_explore_button = UiUtil.find_node(self, "ExploreButton")
	if is_instance_valid(_explore_button):
		_explore_button.pressed.connect(_on_explore_pressed)


func refresh() -> void:
	if _session == null:
		return
	_resolve()
	if not is_instance_valid(_explore_button):
		return

	var city: Dictionary = GameData.CITIES[_session.current_city]
	if is_instance_valid(_title):
		_title.text = "探索 — %s（%s）" % [city["name"], city["explore_flavor"]]

	var chance: float = _session.explore_chance()
	var bonus: float = _session.explore_equip_bonus()
	if is_instance_valid(_chance_label):
		_chance_label.text = "成功率 %d%%（スロット +%d%%）" % [
			int(round(chance * 100.0)), int(round(bonus * 100.0))]
		_chance_label.add_theme_color_override("font_color", _chance_color(chance))

	_build_slots()
	_build_equip_list()

	if is_instance_valid(_hint_label):
		# 賭けているのはスロットの中身だけ。実数を出す。
		var at_risk_total: int = 0
		var at_risk: Dictionary = _session.explore_equip_at_risk()
		for item_id: String in at_risk:
			at_risk_total += at_risk[item_id]
		_hint_label.text = ("成功: シルバー・%s・低確率で%sを獲得し、%d日間は島の労働者の産出が倍になる（スロットは減らない）\n" +
			"失敗: スロットの装備 %d 個を失う（積荷は無傷）") % [
			GameData.ITEMS["sunstone"]["name"], GameData.ITEMS["ancient_relic"]["name"],
			GameData.EXPLORE_BOOST_DAYS, at_risk_total]

	var over: bool = _session.is_over()
	_explore_button.text = "探索する（1日）"
	_explore_button.disabled = over


## スロットを枠ぶん並べる。押すと中身を積荷へ戻す（空き枠は押せない）。
func _build_slots() -> void:
	if not is_instance_valid(_slots_row):
		return
	UiUtil.clear_children(_slots_row)
	for i: int in _session.explore_slots.size():
		var item_id: String = _session.slot_item(i)
		var button := Button.new()
		button.custom_minimum_size = Vector2(0, 40)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if item_id == "":
			button.text = "空き"
			button.disabled = true
			button.add_theme_color_override("font_color", UiTheme.TEXT_UNKNOWN)
		else:
			button.text = GameData.ITEMS[item_id]["name"]
			button.icon = UiIcons.item_texture(item_id)
			button.tooltip_text = "押すと積荷へ戻す"
			# 積載に空きが無いと戻せない。押せる/押せないを先に見せる。
			button.disabled = _session.free_capacity() < GameData.ITEMS[item_id]["weight"]
			if button.disabled:
				button.tooltip_text = "積載に空きが無いため戻せない"
			button.pressed.connect(_on_slot_pressed.bind(i))
		_slots_row.add_child(button)


## 積荷にある戦闘装備を並べる。押すと空いている枠へ挿す。
func _build_equip_list() -> void:
	if not is_instance_valid(_equip_list):
		return
	UiUtil.clear_children(_equip_list)
	var has_any: bool = false
	for item_id: String in GameData.EXPLORE_COMBAT_ITEMS:
		var count: int = _session.cargo_count(item_id)
		if count <= 0:
			continue
		has_any = true
		var button := Button.new()
		button.text = "%s ×%d を挿す" % [GameData.ITEMS[item_id]["name"], count]
		button.icon = UiIcons.item_texture(item_id)
		button.disabled = _session.first_empty_slot() < 0
		if button.disabled:
			button.tooltip_text = "スロットに空きが無い"
		button.pressed.connect(_on_equip_pressed.bind(item_id))
		_equip_list.add_child(button)
	if not has_any:
		var label := Label.new()
		label.text = "積荷に戦闘装備がない"
		label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		_equip_list.add_child(label)


## 成功率に応じた色。装備で伸ばせる余地が分かるよう、控えめな三段階にする。
##
## スロット制で到達できる上限が下がった（基本35% + 枠5×3% = 50%）ため、
## GOOD の敷居も 0.5 のままだと「全枠を別種で埋めてようやく1段階上がる」に
## なる。押し上げた実感が出るよう 0.45 にしてある。
func _chance_color(chance: float) -> Color:
	if chance >= 0.45:
		return UiTheme.GOOD
	if chance < 0.3:
		return UiTheme.WARN
	return UiTheme.TEXT


func _on_slot_pressed(index: int) -> void:
	_session.unequip_slot(index)


func _on_equip_pressed(item_id: String) -> void:
	_session.equip_slot(_session.first_empty_slot(), item_id)


func _on_explore_pressed() -> void:
	_session.explore()


func _on_changed() -> void:
	refresh()


func _on_silver_changed(_amount: int) -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()
