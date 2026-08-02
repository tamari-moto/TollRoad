extends PanelContainer
## 市場画面。現在地の全品目について相場と売買を行う。
##
## 各行は「品目名 / 価格 / 基準比 / 所持数 / 買うボタン / 売るボタン」で構成し、
## 数量は 1 / 5 / 半分 / 全部 から選ぶ（仕様 6.1）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const PriceBar = preload("res://scripts/ui/price_bar.gd")

## 安い理由を示すバッジの文言。
const BADGE_SPECIALTY: String = "特産"
const BADGE_BONUS: String = "生産地"

## 売買が成立した時に、その行の位置とともに知らせる。
## 演出はパネルをまたぐため、飛ばす先を知っている main.gd に任せる。
signal traded(item_id: String, is_buy: bool, origin: Vector2)

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
		# silver_changed は引数を1つ渡すため、専用のハンドラで受ける。
		"silver_changed": _on_silver_changed,
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
	_apply_row_stripes()


func _build_row(item_id: String) -> Dictionary:
	# アイコンと名前を1セルに収める。列を増やすと行数の検査が壊れるため。
	var name_cell: HBoxContainer = UiIcons.make_labeled_item(
		item_id, GameData.ITEMS[item_id]["name"])
	# その都市で安い理由を示すバッジ。都市が変わると付け替える。
	var badge := Label.new()
	badge.name = "Badge"
	badge.add_theme_font_size_override("font_size", 10)
	badge.add_theme_color_override("font_color", UiTheme.GOOD)
	badge.visible = false
	name_cell.add_child(badge)
	_grid.add_child(name_cell)

	# 価格の数字とバーを縦に重ねる。列は増やさない。
	var price_cell := VBoxContainer.new()
	price_cell.add_theme_constant_override("separation", 1)
	price_cell.custom_minimum_size = Vector2(74, 0)

	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_cell.add_child(price_label)

	var bar: PriceBar = PriceBar.new()
	bar.name = "Bar"
	price_cell.add_child(bar)
	_grid.add_child(price_cell)

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
		"bar": bar,
		"badge": badge,
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
		if is_instance_valid(row["bar"]):
			row["bar"].ratio = ratio

		# 色に頼らず向きが分かるよう記号を添える。
		row["ratio"].text = "%s%d%%" % [_arrow(ratio), int(round(ratio * 100.0))]
		row["ratio"].add_theme_color_override("font_color", UiTheme.ratio_color(ratio))
		row["held"].text = str(_session.cargo_count(item_id))
		_refresh_badge(row["badge"], item_id)

		row["buy"].disabled = over or _buy_amount(item_id) <= 0
		row["sell"].disabled = over or _sell_amount(item_id) <= 0


## 1行おきに薄い帯を敷き、横方向を追いやすくする。
## GridContainer には行の概念がないため、セルの背景として個別に敷く。
func _apply_row_stripes() -> void:
	if _grid == null:
		return
	var index: int = 0
	for item_id: String in _rows:
		if index % 2 == 1:
			for cell: Node in _rows[item_id].values():
				var control: Control = cell as Control
				if control == null or not is_instance_valid(control):
					continue
				# ボタンは自前の見た目を持つので触らない。
				if control is Button:
					continue
				_add_stripe(control)
		index += 1


func _add_stripe(control: Control) -> void:
	if control.get_node_or_null("Stripe") != null:
		return
	var stripe := ColorRect.new()
	stripe.name = "Stripe"
	stripe.color = UiTheme.ROW_STRIPE
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stripe.set_anchors_preset(Control.PRESET_FULL_RECT)
	stripe.anchor_right = 1.0
	stripe.anchor_bottom = 1.0
	stripe.offset_right = 0.0
	stripe.offset_bottom = 0.0
	control.add_child(stripe)
	control.move_child(stripe, 0)


## 基準価格に対する向き。色が見分けにくい場合の手がかりになる。
static func _arrow(ratio: float) -> String:
	if ratio <= UiTheme.CHEAP_RATIO:
		return "▼"
	if ratio >= UiTheme.DEAR_RATIO:
		return "▲"
	return "　"


## その品目がこの都市で安い理由を示す。特産でもボーナスでもなければ隠す。
func _refresh_badge(badge: Label, item_id: String) -> void:
	if not is_instance_valid(badge):
		return
	var city: Dictionary = GameData.CITIES[_session.current_city]
	if city["specialty"] == item_id:
		badge.text = BADGE_SPECIALTY
		badge.visible = true
	elif city["bonus"] == item_id:
		badge.text = BADGE_BONUS
		badge.visible = true
	else:
		badge.text = ""
		badge.visible = false


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
	if _session.buy(item_id, _buy_amount(item_id)):
		traded.emit(item_id, true, _row_origin(item_id))


func _on_sell_pressed(item_id: String) -> void:
	if _session.sell(item_id, _sell_amount(item_id)):
		traded.emit(item_id, false, _row_origin(item_id))


## その品目の行のアイコン位置（グローバル座標）。演出の発着点に使う。
func _row_origin(item_id: String) -> Vector2:
	var row: Dictionary = _rows.get(item_id, {})
	var anchor: Control = row.get("buy")
	if is_instance_valid(anchor):
		return anchor.global_position + anchor.size * 0.5
	return global_position + size * 0.5


func _on_state_changed() -> void:
	refresh()


func _on_silver_changed(_amount: int) -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()
