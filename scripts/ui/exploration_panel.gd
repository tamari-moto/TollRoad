extends PanelContainer
## 探索。現在地に応じた討伐/遺跡探索を1日かけて行う。
##
## 積荷にある戦闘装備（GameData.EXPLORE_COMBAT_ITEMS）を持っているほど成功率が上がる。
## 成功すればシルバー・レア品・島倉庫のブーストを得るが、失敗すると
## 成功率へ寄与した分の戦闘装備——同種 EXPLORE_EQUIP_UNIT_CAP 個まで——を
## 失う（資源は無傷）。失う数は GameSession.explore_equip_at_risk() が返す。

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
		# 失うのは成功率へ寄与した分だけなので、いま賭けている実数を出す。
		# 「全て失う」と書くと、頭打ちを超えて積んだ交易用の装備まで
		# 取られるように読め、装備を運びながらの探索を過大に恐れさせる。
		var at_risk: Dictionary = _session.explore_equip_at_risk()
		var at_risk_total: int = 0
		for item_id: String in at_risk:
			at_risk_total += at_risk[item_id]
		_hint_label.text = ("成功: シルバー・%s・低確率で%sを獲得し、%d日間は島の労働者の産出が倍になる\n" +
			"失敗: 積荷の戦闘装備（%s）を %d 個失う（同種%d個まで／資源は無傷）") % [
			GameData.ITEMS["sunstone"]["name"], GameData.ITEMS["ancient_relic"]["name"],
			GameData.EXPLORE_BOOST_DAYS, "・".join(combat_names),
			at_risk_total, GameData.EXPLORE_EQUIP_UNIT_CAP]

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
