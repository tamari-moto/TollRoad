extends PanelContainer
## 相場メモ。全都市 × 全品目の既知価格を一覧する。
##
## 訪問した都市の価格だけが記録され、7日以上経つと薄字になる（仕様 5.3）。
## 未訪問は「?」。全都市の価格を常時見せると判断が単純作業になるため、
## 記録の鮮度管理そのものを戦略要素にする、という設計意図に基づく。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")

const COLOR_FRESH := UiTheme.TEXT
## 古い記録。読めるが確度が落ちていることが一目で分かる濃度にする。
const COLOR_STALE := UiTheme.TEXT_STALE
const COLOR_UNKNOWN := UiTheme.TEXT_UNKNOWN
const COLOR_CURRENT := UiTheme.FOCUS
const COLOR_HEADER := UiTheme.TEXT_DIM
## 既知の中で最安を示す色。買い先を探す用途に直結する。
const COLOR_CHEAPEST := UiTheme.GOOD

var _session: GameSession
var _grid: GridContainer
var _cells: Dictionary = {}
var _city_headers: Dictionary = {}

## 価格推移グラフの制御。全都市が常時記録されているため、訪問の有無を
## 問わずどの都市でも選べる（相場メモの「?」表示とは別方針）。
var _city_select: OptionButton
var _item_toggles: Container
var _chart: Control
var _chart_cities: Array[String] = []
var _selected_items: Dictionary = {}


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {"day_advanced": _on_day_advanced})
	_session = session
	_build()
	refresh()


func _build() -> void:
	_build_chart_controls()
	if not _cells.is_empty():
		return
	_grid = UiUtil.find_node(self, "MemoGrid")
	if _grid == null:
		return

	var cities: Array[String] = GameData.royal_city_ids()
	cities.append(GameData.CAERLEON)
	_grid.columns = cities.size() + 1

	# 左上の空白 + 都市名の見出し。
	var corner := Label.new()
	corner.text = "品目"
	corner.add_theme_color_override("font_color", COLOR_HEADER)
	_grid.add_child(corner)

	for city_id: String in cities:
		var header := Label.new()
		header.text = _short_city_name(city_id)
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		header.add_theme_color_override("font_color", COLOR_HEADER)
		_grid.add_child(header)
		_city_headers[city_id] = header

	# 品目ごとの行。
	for item_id: String in GameData.ITEMS:
		# アイコンと名前を1セルに収める。列数は変えない。
		_grid.add_child(UiIcons.make_labeled_item(item_id, GameData.ITEMS[item_id]["name"]))

		var row: Dictionary = {}
		for city_id: String in cities:
			var cell := Label.new()
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_grid.add_child(cell)
			row[city_id] = cell
		_cells[item_id] = row


## 都市選択と品目トグルを組み立てる。全都市を常時記録しているので、
## 相場メモの表と違い訪問の有無は問わない（未訪問でも選べる）。
func _build_chart_controls() -> void:
	if _city_select != null:
		return
	_city_select = UiUtil.find_node(self, "CitySelect")
	_item_toggles = UiUtil.find_node(self, "ItemToggles")
	_chart = UiUtil.find_node(self, "PriceChart")
	if _city_select == null or _item_toggles == null or _chart == null:
		_city_select = null
		return

	_chart_cities = GameData.royal_city_ids()
	_chart_cities.append(GameData.CAERLEON)
	for city_id: String in _chart_cities:
		_city_select.add_item(GameData.CITIES[city_id]["name"])
	# 既定は現在地。全都市が常時記録されているので選び直しても構わない。
	var initial_index: int = _chart_cities.find(_session.current_city) if _session != null else 0
	_city_select.selected = maxi(initial_index, 0)
	if not _city_select.item_selected.is_connected(_on_chart_option_changed):
		_city_select.item_selected.connect(_on_chart_option_changed)

	for item_id: String in GameData.ITEMS:
		var toggle := CheckButton.new()
		toggle.text = GameData.ITEMS[item_id]["name"]
		var color: Color = UiTheme.item_color(item_id)
		# 既定の Button テーマは ON（pressed）やフォーカス時に別の文字色を出す
		# （実測で白くなる）。グラフの線と同じ色で見分けられるようにしたいので、
		# 状態ごとの上書きを全て同じ色で埋めて固定する。
		for state: String in ["font_color", "font_hover_color", "font_pressed_color",
				"font_hover_pressed_color", "font_focus_color"]:
			toggle.add_theme_color_override(state, color)
		toggle.toggled.connect(_on_item_toggled.bind(item_id))
		_item_toggles.add_child(toggle)
		_selected_items[item_id] = false


func _on_chart_option_changed(_index: int) -> void:
	_refresh_chart()


func _on_item_toggled(pressed: bool, item_id: String) -> void:
	_selected_items[item_id] = pressed
	_refresh_chart()


## 選ばれている都市 id。何も選ばれていなければ現在地に倣う。
func _selected_chart_city() -> String:
	if _city_select == null or _city_select.selected < 0:
		return _session.current_city if _session != null else ""
	return _chart_cities[_city_select.selected]


func _refresh_chart() -> void:
	if _session == null or _chart == null:
		return
	var series: Dictionary = {}
	for item_id: String in _selected_items:
		if _selected_items[item_id]:
			series[item_id] = _session.price_history.series(_selected_chart_city(), item_id)
	_chart.set_data(series, _session.day)


## 表の幅を抑えるため、都市名を先頭3文字に短縮して表示する。
## 都市数・都市名を変えてもそのまま追従する（固定の略称表は持たない）。
static func _short_city_name(city_id: String) -> String:
	return String(GameData.CITIES[city_id]["name"]).substr(0, 3)


func refresh() -> void:
	if _session == null or _cells.is_empty():
		return

	# 現在地の見出しを強調する。
	for city_id: String in _city_headers:
		var header: Label = _city_headers[city_id]
		if not is_instance_valid(header):
			continue
		if city_id == _session.current_city:
			header.add_theme_color_override("font_color", COLOR_CURRENT)
		else:
			header.add_theme_color_override("font_color", COLOR_HEADER)

	for item_id: String in _cells:
		_refresh_row(item_id)

	_refresh_chart()


func _refresh_row(item_id: String) -> void:
	var row: Dictionary = _cells[item_id]

	# 既知の中での最安を求め、買い先の候補を色で示す。
	var cheapest_city: String = ""
	var cheapest_price: int = -1
	for city_id: String in row:
		if not _session.has_memo(city_id):
			continue
		var price: int = _session.memo_price(city_id, item_id)
		if price > 0 and (cheapest_price < 0 or price < cheapest_price):
			cheapest_price = price
			cheapest_city = city_id

	for city_id: String in row:
		var cell: Label = row[city_id]
		if not is_instance_valid(cell):
			continue

		if not _session.has_memo(city_id):
			cell.text = "?"
			cell.add_theme_color_override("font_color", COLOR_UNKNOWN)
			continue

		var price: int = _session.memo_price(city_id, item_id)
		var age: int = _session.memo_age(city_id)
		cell.text = UiUtil.format_number(price)

		if _session.is_memo_stale(city_id):
			cell.add_theme_color_override("font_color", COLOR_STALE)
			cell.tooltip_text = "%d日前の記録" % age
		elif city_id == cheapest_city:
			cell.add_theme_color_override("font_color", COLOR_CHEAPEST)
			cell.tooltip_text = "既知の中で最安"
		else:
			cell.add_theme_color_override("font_color", COLOR_FRESH)
			cell.tooltip_text = "%d日前の記録" % age if age > 0 else "現在地の相場"


func _on_day_advanced(_day: int) -> void:
	refresh()
