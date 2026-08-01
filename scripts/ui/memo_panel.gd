extends PanelContainer
## 相場メモ。全都市 × 全品目の既知価格を一覧する。
##
## 訪問した都市の価格だけが記録され、7日以上経つと薄字になる（仕様 5.3）。
## 未訪問は「?」。全都市の価格を常時見せると判断が単純作業になるため、
## 記録の鮮度管理そのものを戦略要素にする、という設計意図に基づく。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

const COLOR_FRESH := Color(0.88, 0.88, 0.9)
## 古い記録。読めるが確度が落ちていることが一目で分かる濃度にする。
const COLOR_STALE := Color(0.5, 0.5, 0.55)
const COLOR_UNKNOWN := Color(0.38, 0.38, 0.42)
const COLOR_CURRENT := Color(0.55, 0.8, 0.95)
const COLOR_HEADER := Color(0.6, 0.6, 0.65)
## 既知の中で最安を示す色。買い先を探す用途に直結する。
const COLOR_CHEAPEST := Color(0.45, 0.85, 0.5)

var _session: GameSession
var _grid: GridContainer
var _cells: Dictionary = {}
var _city_headers: Dictionary = {}


func bind(session: GameSession) -> void:
	_session = session
	session.day_advanced.connect(_on_day_advanced)
	_build()
	refresh()


func _build() -> void:
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
		var name_label := Label.new()
		name_label.text = GameData.ITEMS[item_id]["name"]
		_grid.add_child(name_label)

		var row: Dictionary = {}
		for city_id: String in cities:
			var cell := Label.new()
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_grid.add_child(cell)
			row[city_id] = cell
		_cells[item_id] = row


## 表の幅を抑えるため、都市名を短く表示する。
static func _short_city_name(city_id: String) -> String:
	match city_id:
		"fort_sterling": return "F.スタ"
		"lymhurst": return "リムハ"
		"bridgewatch": return "ブリジ"
		"martlock": return "マート"
		"thetford": return "セット"
		_: return "カーレ"


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
