extends PanelContainer
## 市場画面。現在地の全品目について相場と売買を行う。
##
## 各行は「品目名 / 価格 / 基準比 / 所持数 / 買うボタン / 売るボタン」で構成し、
## 数量は 1 / 5 / 半分 / 全部 から選ぶ（仕様 6.1）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## 数量の選び方。half は所持数/購入可能数の半分。
enum Quantity { ONE, FIVE, HALF, ALL }

var _session: GameSession
var _rows: Dictionary = {}
var _quantity: Quantity = Quantity.ONE

var _grid: GridContainer
var _title: Label
var _quantity_buttons: Dictionary = {}


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _on_state_changed,
		"cargo_changed": _on_state_changed,
		"day_advanced": _on_day_advanced,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if _grid != null:
		return
	_title = UiUtil.find_node(self, "MarketTitle")
	_grid = UiUtil.find_node(self, "ItemGrid")
	if _grid == null:
		return

	for quantity: Quantity in [Quantity.ONE, Quantity.FIVE, Quantity.HALF, Quantity.ALL]:
		var button: Button = UiUtil.find_node(self, "Qty%d" % quantity)
		if button != null:
			_quantity_buttons[quantity] = button
			button.pressed.connect(_on_quantity_selected.bind(quantity))
	_update_quantity_buttons()

	# ヘッダ行。
	for heading: String in ["品目", "価格", "基準比", "所持", "", ""]:
		var label := Label.new()
		label.text = heading
		label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		_grid.add_child(label)

	for item_id: String in GameData.ITEMS:
		_rows[item_id] = _build_row(item_id)


func _build_row(item_id: String) -> Dictionary:
	var name_label := Label.new()
	name_label.text = GameData.ITEMS[item_id]["name"]
	_grid.add_child(name_label)

	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grid.add_child(price_label)

	var ratio_label := Label.new()
	ratio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grid.add_child(ratio_label)

	var held_label := Label.new()
	held_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grid.add_child(held_label)

	var buy_button := Button.new()
	buy_button.text = "買う"
	buy_button.pressed.connect(_on_buy_pressed.bind(item_id))
	_grid.add_child(buy_button)

	var sell_button := Button.new()
	sell_button.text = "売る"
	sell_button.pressed.connect(_on_sell_pressed.bind(item_id))
	_grid.add_child(sell_button)

	return {
		"price": price_label,
		"ratio": ratio_label,
		"held": held_label,
		"buy": buy_button,
		"sell": sell_button,
	}


func refresh() -> void:
	if _session == null or _rows.is_empty():
		return
	if is_instance_valid(_title):
		_title.text = "市場 — %s" % GameData.CITIES[_session.current_city]["name"]

	var over: bool = _session.is_over()
	for item_id: String in _rows:
		var row: Dictionary = _rows[item_id]
		if not is_instance_valid(row["price"]):
			continue
		var price: int = _session.prices.get_price(_session.current_city, item_id)
		var base: int = GameData.ITEMS[item_id]["base_price"]
		var ratio: float = float(price) / float(base)

		row["price"].text = UiUtil.format_number(price)
		row["ratio"].text = "%d%%" % int(round(ratio * 100.0))
		row["ratio"].add_theme_color_override("font_color", UiTheme.ratio_color(ratio))
		row["held"].text = str(_session.cargo_count(item_id))

		row["buy"].disabled = over or _buy_amount(item_id) <= 0
		row["sell"].disabled = over or _sell_amount(item_id) <= 0


## 選択中の数量指定に基づく実際の購入数。
func _buy_amount(item_id: String) -> int:
	var maximum: int = _session.max_buyable(item_id)
	return _apply_quantity(maximum)


func _sell_amount(item_id: String) -> int:
	var held: int = _session.cargo_count(item_id)
	return _apply_quantity(held)


func _apply_quantity(maximum: int) -> int:
	if maximum <= 0:
		return 0
	match _quantity:
		Quantity.ONE:
			return 1
		Quantity.FIVE:
			return mini(5, maximum)
		Quantity.HALF:
			return maxi(1, maximum / 2)
		_:
			return maximum


func _on_quantity_selected(quantity: Quantity) -> void:
	_quantity = quantity
	_update_quantity_buttons()
	refresh()


func _update_quantity_buttons() -> void:
	for quantity: Quantity in _quantity_buttons:
		var button: Button = _quantity_buttons[quantity]
		if is_instance_valid(button):
			button.button_pressed = quantity == _quantity


func _on_buy_pressed(item_id: String) -> void:
	_session.buy(item_id, _buy_amount(item_id))


func _on_sell_pressed(item_id: String) -> void:
	_session.sell(item_id, _sell_amount(item_id))


func _on_state_changed() -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()
