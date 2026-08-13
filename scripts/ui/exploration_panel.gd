extends PanelContainer
## 探索。現在地に応じた討伐/遺跡探索を1日かけて行う。
##
## 積荷にある戦闘装備（GameData.EXPLORE_COMBAT_ITEMS）を持っているほど成功率が上がる。
## 成功すればシルバー・レア品・島倉庫のブーストを得るが、失敗すると
## 積荷の戦闘装備を全て失う（資源は無傷）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

var _session: GameSession
var _title: Label
var _chance_label: Label
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
		_chance_label.text = "成功率 %d%%（装備ボーナス +%d%%）" % [
			int(round(chance * 100.0)), int(round(bonus * 100.0))]
		_chance_label.add_theme_color_override("font_color", _chance_color(chance))

	if is_instance_valid(_hint_label):
		var combat_names: PackedStringArray = []
		for item_id: String in GameData.EXPLORE_COMBAT_ITEMS:
			combat_names.append(GameData.ITEMS[item_id]["name"])
		_hint_label.text = ("成功: シルバー・%s・低確率で%sを獲得し、%d日間は島の労働者の産出が倍になる\n" +
			"失敗: 積荷の戦闘装備（%s）を全て失う（資源は無傷）") % [
			GameData.ITEMS["sunstone"]["name"], GameData.ITEMS["ancient_relic"]["name"],
			GameData.EXPLORE_BOOST_DAYS, "・".join(combat_names)]

	var over: bool = _session.is_over()
	_explore_button.text = "探索する（1日）"
	_explore_button.disabled = over


## 成功率に応じた色。装備で伸ばせる余地が分かるよう、控えめな三段階にする。
func _chance_color(chance: float) -> Color:
	if chance >= 0.5:
		return UiTheme.GOOD
	if chance < 0.3:
		return UiTheme.WARN
	return UiTheme.TEXT


func _on_explore_pressed() -> void:
	_session.explore()


func _on_changed() -> void:
	refresh()


func _on_silver_changed(_amount: int) -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()
