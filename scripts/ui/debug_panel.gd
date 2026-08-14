extends PanelContainer
## デバッグモード: 全都市・全品目の在庫/需要/生産量/消費量を一覧表示する。
##
## F3 で開閉する常時利用可能なオーバーレイ。%SidePanel の7タブとは独立して
## 動く（main.gd の _unhandled_input から toggle_visible() を呼ぶだけ）。
##
## ノードはすべてコードで組み立てる（.tscn は作らない）。都市×品目の行を
## 動的に生成する都合上、手書き .tscn の当たり判定の罠（CLAUDE.md参照）を
## 踏む理由が無いため。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const StatBar = preload("res://scripts/ui/stat_bar.gd")

## 品目を選ぶと全都市を比較 / 都市を選ぶと全品目を一覧。
enum View { BY_ITEM, BY_CITY }

const PANEL_SIZE: Vector2 = Vector2(1080, 720)
const NAME_LABEL_WIDTH: int = 200
const BAR_COLUMN_WIDTH: int = 190
const PRICE_LABEL_WIDTH: int = 170

var _session: GameSession = null

var _view: int = View.BY_ITEM
var _item_ids: Array[String] = []
var _city_ids: Array[String] = []
var _item_index: int = 0
var _city_index: int = 0

## key: View.BY_ITEM のときは city_id、View.BY_CITY のときは item_id。
## 値は行の各ノード参照（検査（scenario_m26.gd）が中身を確かめるために使う。
## _rows の辞書自体は公開しない — 用途ごとの細い accessor を通す）。
var _rows: Dictionary = {}

var _by_item_button: Button
var _by_city_button: Button
var _close_button: Button
var _prev_button: Button
var _next_button: Button
var _picker_label: Label
var _grid: VBoxContainer


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


## ノードの構築。二重に呼ばれても安全（_grid が既にあれば何もしない）。
## --script のハーネスでは _ready() が走らないため、_init() からも呼ぶ。
func _configure() -> void:
	if _grid != null:
		return

	_item_ids.assign(GameData.ITEMS.keys())
	_city_ids.assign(GameData.CITIES.keys())

	UiTheme.apply_panel_style(self)
	custom_minimum_size = PANEL_SIZE
	anchor_left = 0.02
	anchor_top = 0.05
	anchor_right = 0.02
	anchor_bottom = 0.05
	offset_left = 0.0
	offset_top = 0.0
	offset_right = PANEL_SIZE.x
	offset_bottom = PANEL_SIZE.y
	visible = false

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)

	var title := Label.new()
	title.text = "デバッグ: 市場データ（F3で閉じる）"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UiTheme.TEXT)
	header.add_child(title)

	_by_item_button = Button.new()
	_by_item_button.text = "品目→都市"
	_by_item_button.tooltip_text = "品目を選び、全都市を比較する"
	header.add_child(_by_item_button)

	_by_city_button = Button.new()
	_by_city_button.text = "都市→品目"
	_by_city_button.tooltip_text = "都市を選び、全品目を一覧する"
	header.add_child(_by_city_button)

	_close_button = Button.new()
	_close_button.text = "×"
	_close_button.tooltip_text = "閉じる（F3）"
	header.add_child(_close_button)

	var picker := HBoxContainer.new()
	picker.add_theme_constant_override("separation", 8)
	column.add_child(picker)

	_prev_button = Button.new()
	_prev_button.text = "◀"
	picker.add_child(_prev_button)

	_picker_label = Label.new()
	_picker_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_picker_label.add_theme_color_override("font_color", UiTheme.TEXT)
	picker.add_child(_picker_label)

	_next_button = Button.new()
	_next_button.text = "▶"
	picker.add_child(_next_button)

	var column_header := HBoxContainer.new()
	column_header.add_theme_constant_override("separation", 8)
	column.add_child(column_header)
	_add_column_header(column_header, "名前", NAME_LABEL_WIDTH)
	_add_column_header(column_header, "在庫（現在値/上限）", BAR_COLUMN_WIDTH)
	_add_column_header(column_header, "需要（現在値/上限）", BAR_COLUMN_WIDTH)
	_add_column_header(column_header, "買値/売値", PRICE_LABEL_WIDTH)
	_add_column_header(column_header, "生産/消費", 0)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)

	_grid = VBoxContainer.new()
	_grid.add_theme_constant_override("separation", 4)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)

	_connect_once(_by_item_button.pressed, show_by_item_view)
	_connect_once(_by_city_button.pressed, show_by_city_view)
	_connect_once(_close_button.pressed, toggle_visible)
	_connect_once(_prev_button.pressed, _on_prev_pressed)
	_connect_once(_next_button.pressed, _on_next_pressed)


func _connect_once(sig: Signal, handler: Callable) -> void:
	if not sig.is_connected(handler):
		sig.connect(handler)


func _add_column_header(parent: HBoxContainer, text: String, width: int) -> void:
	var label := Label.new()
	label.text = text
	if width > 0:
		label.custom_minimum_size = Vector2(width, 0)
	else:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	parent.add_child(label)


# --- 公開 API（main.gd / scenario_m26.gd から使う） ---

func bind(session: GameSession) -> void:
	_configure()
	_session = session
	refresh()


func refresh() -> void:
	_configure()
	if _session == null:
		return
	_build_rows()


func toggle_visible() -> void:
	visible = not visible
	if visible:
		refresh()


## 品目を選ぶと全都市を比較するビューへ切り替える。
func show_by_item_view() -> void:
	_view = View.BY_ITEM
	refresh()


## 都市を選ぶと全品目を一覧するビューへ切り替える。
func show_by_city_view() -> void:
	_view = View.BY_CITY
	refresh()


func current_view() -> int:
	return _view


## 表示する品目を指定する（View.BY_ITEM のとき有効）。
func select_item(item_id: String) -> void:
	var index: int = _item_ids.find(item_id)
	if index < 0:
		return
	_item_index = index
	refresh()


## 表示する都市を指定する（View.BY_CITY のとき有効）。
func select_city(city_id: String) -> void:
	var index: int = _city_ids.find(city_id)
	if index < 0:
		return
	_city_index = index
	refresh()


func row_count() -> int:
	return _rows.size()


func row_keys() -> Array:
	return _rows.keys()


func stock_bar_for(key: String) -> StatBar:
	return _rows.get(key, {}).get("stock_bar") as StatBar


func demand_bar_for(key: String) -> StatBar:
	return _rows.get(key, {}).get("demand_bar") as StatBar


func production_text_for(key: String) -> String:
	var label: Label = _rows.get(key, {}).get("rate_label") as Label
	return label.text if label != null else ""


func price_text_for(key: String) -> String:
	var label: Label = _rows.get(key, {}).get("price_label") as Label
	return label.text if label != null else ""


# --- 内部 ---

func _on_prev_pressed() -> void:
	_step_picker(-1)


func _on_next_pressed() -> void:
	_step_picker(1)


func _step_picker(delta: int) -> void:
	if _view == View.BY_ITEM:
		var count: int = _item_ids.size()
		_item_index = ((_item_index + delta) % count + count) % count
	else:
		var count2: int = _city_ids.size()
		_city_index = ((_city_index + delta) % count2 + count2) % count2
	refresh()


func _build_rows() -> void:
	UiUtil.clear_children(_grid)
	_rows.clear()

	if _view == View.BY_ITEM:
		var item_id: String = _item_ids[_item_index]
		_picker_label.text = "品目: %s (%s)" % [GameData.ITEMS[item_id]["name"], item_id]
		for city_id: String in _city_ids:
			_add_row(city_id, GameData.CITIES[city_id]["name"], city_id, item_id)
	else:
		var city_id2: String = _city_ids[_city_index]
		_picker_label.text = "都市: %s (%s)" % [GameData.CITIES[city_id2]["name"], city_id2]
		for item_id2: String in _item_ids:
			_add_row(item_id2, GameData.ITEMS[item_id2]["name"], city_id2, item_id2)


## row_key: _rows のキー（BY_ITEM なら city_id、BY_CITY なら item_id）。
func _add_row(row_key: String, display_name: String, city_id: String, item_id: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_grid.add_child(row)

	var name_label := Label.new()
	name_label.text = display_name
	name_label.custom_minimum_size = Vector2(NAME_LABEL_WIDTH, 0)
	name_label.clip_text = true
	name_label.tooltip_text = display_name
	name_label.add_theme_color_override("font_color", UiTheme.TEXT)
	row.add_child(name_label)

	var stock: int = _session.market.stock_of(city_id, item_id)
	var stock_cap: int = MarketTable.stock_cap(city_id, item_id)
	var stock_column := _build_bar_column(stock, stock_cap, UiTheme.GOOD)
	row.add_child(stock_column)

	var demand: int = _session.market.demand_of(city_id, item_id)
	var demand_cap: int = MarketTable.demand_cap(city_id, item_id)
	var demand_column := _build_bar_column(demand, demand_cap, UiTheme.FOCUS)
	row.add_child(demand_column)

	var buy_price: int = _session.prices.buy_price(city_id, item_id)
	var sell_price: int = _session.prices.sell_price(city_id, item_id)
	var price_label := Label.new()
	price_label.text = "買%s / 売%s" % [
		UiUtil.format_number(buy_price), UiUtil.format_number(sell_price)]
	price_label.custom_minimum_size = Vector2(PRICE_LABEL_WIDTH, 0)
	price_label.add_theme_color_override("font_color", UiTheme.TEXT)
	row.add_child(price_label)

	var production: int = MarketTable.production_of(city_id, item_id)
	var consumption: int = MarketTable.consumption_of(city_id, item_id)
	var rate_label := Label.new()
	rate_label.text = "生産%d/日・消費%d/日" % [production, consumption]
	rate_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rate_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	row.add_child(rate_label)

	_rows[row_key] = {
		"stock_bar": stock_column.get_meta("bar"),
		"demand_bar": demand_column.get_meta("bar"),
		"price_label": price_label,
		"rate_label": rate_label,
	}


func _build_bar_column(value: int, max_value: int, color: Color) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(BAR_COLUMN_WIDTH, 0)
	column.add_theme_constant_override("separation", 2)

	var text := Label.new()
	text.text = "%d / %d" % [value, max_value]
	text.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	column.add_child(text)

	var bar := StatBar.new()
	bar.value = value
	bar.max_value = max_value
	bar.fill_color = color
	column.add_child(bar)

	column.set_meta("bar", bar)
	return column
