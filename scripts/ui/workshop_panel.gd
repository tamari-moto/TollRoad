extends PanelContainer
## 製作所。資源3個から装備1個を作る。生産ボーナス都市では材料が還元される。
##
## 製作は1日消費するため、まとめて作れる数を明示して一度に処理させる。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

const COLOR_BONUS := Color(0.45, 0.85, 0.5)

var _session: GameSession
var _title: Label
var _grid: GridContainer
var _rows: Dictionary = {}


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _on_changed,
		"cargo_changed": _on_changed,
		"day_advanced": _on_day_advanced,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if not _rows.is_empty():
		return
	_title = UiUtil.find_node(self, "WorkshopTitle")
	_grid = UiUtil.find_node(self, "RecipeGrid")
	if _grid == null:
		return

	for heading: String in ["装備", "材料", "消費", "作れる数", ""]:
		var label := Label.new()
		label.text = heading
		label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		_grid.add_child(label)

	for item_id: String in GameData.ITEMS:
		if GameData.ITEMS[item_id]["kind"] != GameData.ItemKind.EQUIPMENT:
			continue
		_rows[item_id] = _build_row(item_id)


func _build_row(item_id: String) -> Dictionary:
	var item: Dictionary = GameData.ITEMS[item_id]
	var material_id: String = item["material"]

	var name_label := Label.new()
	name_label.text = item["name"]
	_grid.add_child(name_label)

	var material_label := Label.new()
	material_label.text = GameData.ITEMS[material_id]["name"]
	_grid.add_child(material_label)

	# ボーナス都市では消費数が減るため、都市によって変わる。
	var cost_label := Label.new()
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grid.add_child(cost_label)

	var max_label := Label.new()
	max_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grid.add_child(max_label)

	var craft_button := Button.new()
	craft_button.text = "作る"
	craft_button.pressed.connect(_on_craft_pressed.bind(item_id))
	_grid.add_child(craft_button)

	return {
		"cost": cost_label,
		"max": max_label,
		"button": craft_button,
	}


func refresh() -> void:
	if _session == null or _rows.is_empty():
		return

	var city_name: String = GameData.CITIES[_session.current_city]["name"]
	var bonus_id: String = GameData.CITIES[_session.current_city]["bonus"]
	if is_instance_valid(_title):
		if bonus_id != "":
			_title.text = "製作所 — %s（%s の生産ボーナスあり・手数料 %d/個）" % [
				city_name, GameData.ITEMS[bonus_id]["name"], GameData.CRAFT_FEE]
		else:
			_title.text = "製作所 — %s（手数料 %d/個）" % [city_name, GameData.CRAFT_FEE]

	var over: bool = _session.is_over()
	for item_id: String in _rows:
		var row: Dictionary = _rows[item_id]
		if not is_instance_valid(row["cost"]):
			continue
		var per_unit: int = _session.material_cost_per_unit(item_id)
		var maximum: int = _session.max_craftable(item_id)
		var has_bonus: bool = _session.has_craft_bonus(item_id)

		row["cost"].text = "%d個" % per_unit
		if has_bonus:
			row["cost"].add_theme_color_override("font_color", COLOR_BONUS)
		else:
			row["cost"].remove_theme_color_override("font_color")

		row["max"].text = str(maximum)
		row["button"].text = "作る（%d）" % maximum if maximum > 0 else "作る"
		row["button"].disabled = over or maximum <= 0
		row["button"].tooltip_text = _blocked_reason(item_id, per_unit) if maximum <= 0 else ""


## なぜ作れないのかを返す。特に積載不足は気づきにくい:
## 資源2〜3個（重量2〜3）が装備1個（重量3）になるため正味の重量が増え、
## 積荷を満杯にしていると製作できなくなる。
func _blocked_reason(item_id: String, per_unit: int) -> String:
	var material: String = GameData.ITEMS[item_id]["material"]
	var material_name: String = GameData.ITEMS[material]["name"]

	if _session.cargo_count(material) < per_unit:
		return "%s が %d 個必要（所持 %d 個）" % [
			material_name, per_unit, _session.cargo_count(material)]
	if _session.silver < GameData.CRAFT_FEE:
		return "手数料 %d シルバーが足りない" % GameData.CRAFT_FEE

	var weight_delta: int = GameData.ITEMS[item_id]["weight"] - GameData.ITEMS[material]["weight"] * per_unit
	if weight_delta > 0 and _session.free_capacity() < weight_delta:
		return "積載に空きが %d 必要（%s %d個 → %s 1個で重量が %d 増えるため）" % [
			weight_delta, material_name, per_unit, GameData.ITEMS[item_id]["name"], weight_delta]
	return ""


func _on_craft_pressed(item_id: String) -> void:
	# 1日消費するので、作れるだけまとめて作る。
	_session.craft(item_id, _session.max_craftable(item_id))


func _on_changed() -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()
