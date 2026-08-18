extends PanelContainer
## 市場画面。現在地の全品目について相場と売買を行う。
##
## 各行は「品目名 / 価格 / 基準比 / 在庫と需要 / 所持数 / 買うボタン / 売るボタン」
## で構成する。
## 数量は指定しない。ボタンを押すたびに1個だけ取引し、押しっぱなしにすると
## 連続して取引し続ける（長押しの間だけ加速する。下の HOLD_* を参照）。
##
## 価格の欄は建値ではなく**実際に取引される単価**を出す（買値／売値）。
## 在庫が薄いと買値が上がり、需要が尽きかけていると売値が下がるため、
## 建値だけ見せると押した結果と食い違う。基準比は従来どおり建値で出す
## （都市間の比較に使う指標なので、その場の在庫で動かさない）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const PriceBar = preload("res://scripts/ui/price_bar.gd")
const FxLayer = preload("res://scripts/ui/fx_layer.gd")

## 安い理由を示すバッジの文言。
const BADGE_SPECIALTY: String = "特産"
const BADGE_BONUS: String = "生産地"
## 全品目中で最も条件が良い行に添える指標。
const BADGE_BEST_BUY: String = "◎最安"
const BADGE_BEST_SELL: String = "◎高値"

## 画面を大きく・タップしやすくするためのサイズ。既定のGodotテーマは
## 16px相当で、プロジェクト全体を上書きするテーマは無いため、ここで
## 品目行だけ個別に拡大する。列が7つあり右端のボタンまで収める必要があるため、
## サイドパネル幅（580px）に収まる範囲に抑える。
const ROW_FONT_SIZE: int = 16
const HEADER_FONT_SIZE: int = 13
const ROW_ICON_SIZE: int = 20
const TRADE_BUTTON_MIN_SIZE: Vector2 = Vector2(52, 40)

## 長押しで取引を繰り返す際の刻み。
##
## 押した瞬間に1個取引し、そこから HOLD_DELAY だけ待ってから連射を始める。
## この待ちが無いと「1個だけ買う」つもりが2個買う事故になる（クリックは
## 押して離すまでに必ず時間があるため）。
##
## 連射の間隔は HOLD_INTERVAL_MAX から始めて、押している間 HOLD_ACCEL の割合で
## 詰まり、HOLD_INTERVAL_MIN で頭打ちになる。最初を遅くするのは、数個だけ
## 欲しいときに行き過ぎないため。上限を設けるのは、1フレーム1個より速く
## 回しても押している側が止め時を判断できないため。
const HOLD_DELAY: float = 0.4
const HOLD_INTERVAL_MAX: float = 0.25
const HOLD_INTERVAL_MIN: float = 0.05
## 1回取引するごとに間隔へ掛ける率。0.25秒から0.05秒まで約9回で詰まる。
const HOLD_ACCEL: float = 0.82

## 価格の欄は買値と売値を並べるため、他より小さくする。
const PRICE_FONT_SIZE: int = 14
## 在庫と需要の欄は2つの数字を上下に並べるため、さらに小さくする。
const SUPPLY_FONT_SIZE: int = 12

## 品目 / 価格 / 基準比 / 在庫と需要 / 所持 / 買う / 売る。
## MarketPanel.tscn の columns と必ず一致させること（ずれると行が崩れる）。
const GRID_COLUMNS: int = 7

## 売買が成立した時に、その行の位置とともに知らせる。
## 演出はパネルをまたぐため、飛ばす先を知っている main.gd に任せる。
signal traded(item_id: String, is_buy: bool, origin: Vector2)

var _session: GameSession
var _rows: Dictionary = {}
var _displayed_held: Dictionary = {}
var _held_tweens: Dictionary = {}

var _grid: GridContainer
var _title: Label
var _fx: FxLayer

## 長押し中の対象と刻み。押していない間は _hold_item が空文字。
var _hold_item: String = ""
var _hold_is_buy: bool = false
## 次の1個までの残り時間。押した直後は HOLD_DELAY が入る。
var _hold_remaining: float = 0.0
## 現在の連射間隔。取引が成立するたび HOLD_ACCEL を掛けて詰める。
var _hold_interval: float = HOLD_INTERVAL_MAX


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		# silver_changed は引数を1つ渡すため、専用のハンドラで受ける。
		"silver_changed": _on_silver_changed,
		"cargo_changed": _on_state_changed,
		"market_changed": _on_state_changed,
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

	if _fx == null:
		_fx = FxLayer.new()
		add_child(_fx)

	# ヘッダ行。列を増やしたら GRID_COLUMNS と .tscn の columns も揃えること。
	for heading: String in ["品目", "価格", "基準比", "在庫/需要", "所持", "", ""]:
		var label := Label.new()
		label.text = heading
		label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		label.add_theme_font_size_override("font_size", HEADER_FONT_SIZE)
		_grid.add_child(label)

	for item_id: String in GameData.ITEMS:
		_rows[item_id] = _build_row(item_id)
	_apply_row_stripes()


func _build_row(item_id: String) -> Dictionary:
	# アイコンと名前を1セルに収める。列を増やすと行数の検査が壊れるため。
	var name_row: HBoxContainer = UiIcons.make_labeled_item(
		item_id, GameData.ITEMS[item_id]["name"], ROW_ICON_SIZE)
	for child: Node in name_row.get_children():
		if child is Label:
			(child as Label).add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	# 基準比に応じた色帯。数字を読まなくても安い/高いが一目で分かる。
	var accent := ColorRect.new()
	accent.name = "RatioAccent"
	accent.custom_minimum_size = Vector2(4, 0)
	accent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(accent)
	name_row.move_child(accent, 0)

	# その都市で安い理由や「今お得」を示すバッジ。都市/相場が変わると付け替える。
	# 「特産・◎最安」のような長い文言もあるため、名前と横並びにすると列（＝
	# サイドパネル全体）の幅が伸びて右側の列がはみ出す。名前の下へ折り返す
	# 形にして、セルの幅をアイコン＋名前だけで決まるようにする（列は増やさない。
	# make_labeled_item() が返す HBox に対する外側の入れ物を追加しただけ）。
	var badge := Label.new()
	badge.name = "Badge"
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override("font_color", UiTheme.GOOD)
	badge.visible = false
	# clip_text により、文言の実際の長さに関わらず名前行(name_row)の幅を
	# 超えて列を広げない（はみ出す分は省略される）。
	badge.clip_text = true

	var name_cell := VBoxContainer.new()
	name_cell.add_theme_constant_override("separation", 0)
	name_cell.add_child(name_row)
	name_cell.add_child(badge)
	_grid.add_child(name_cell)

	# 価格の数字とバーを縦に重ねる。列は増やさない。
	# 買値と売値の2つを並べるため、他の行より一段小さい字で置く
	# （ROW_FONT_SIZE のままだと列が広がり、右端のボタンがはみ出す）。
	var price_cell := VBoxContainer.new()
	price_cell.add_theme_constant_override("separation", 2)
	price_cell.custom_minimum_size = Vector2(84, 0)

	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_label.add_theme_font_size_override("font_size", PRICE_FONT_SIZE)
	price_cell.add_child(price_label)

	var bar: PriceBar = PriceBar.new()
	bar.name = "Bar"
	price_cell.add_child(bar)
	_grid.add_child(price_cell)

	var ratio_label := Label.new()
	ratio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ratio_label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	_grid.add_child(ratio_label)

	# 在庫（買える上限）と需要（売れる上限）を上下に並べる。列は増やさない。
	var supply_cell := VBoxContainer.new()
	supply_cell.add_theme_constant_override("separation", 0)
	supply_cell.custom_minimum_size = Vector2(48, 0)

	var stock_label := Label.new()
	stock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stock_label.add_theme_font_size_override("font_size", SUPPLY_FONT_SIZE)
	supply_cell.add_child(stock_label)

	var demand_label := Label.new()
	demand_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	demand_label.add_theme_font_size_override("font_size", SUPPLY_FONT_SIZE)
	supply_cell.add_child(demand_label)
	_grid.add_child(supply_cell)

	var held_label := Label.new()
	held_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	held_label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	_grid.add_child(held_label)

	var buy_button := Button.new()
	buy_button.text = "買う"
	buy_button.custom_minimum_size = TRADE_BUTTON_MIN_SIZE
	buy_button.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	# pressed は「押して離した」時に1個。button_down/up は長押しの連射を
	# 受け持つ。連射は2個目以降だけを出すので、1個目と二重にならない。
	buy_button.pressed.connect(_on_buy_pressed.bind(item_id))
	buy_button.button_down.connect(_on_trade_button_down.bind(item_id, true))
	buy_button.button_up.connect(_on_trade_button_up)
	_grid.add_child(buy_button)

	var sell_button := Button.new()
	sell_button.text = "売る"
	sell_button.custom_minimum_size = TRADE_BUTTON_MIN_SIZE
	sell_button.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	sell_button.pressed.connect(_on_sell_pressed.bind(item_id))
	sell_button.button_down.connect(_on_trade_button_down.bind(item_id, false))
	sell_button.button_up.connect(_on_trade_button_up)
	_grid.add_child(sell_button)

	return {
		"price": price_label,
		"bar": bar,
		"badge": badge,
		"accent": accent,
		"ratio": ratio_label,
		"stock": stock_label,
		"demand": demand_label,
		"held": held_label,
		"buy": buy_button,
		"sell": sell_button,
		# 行ごと隠すために、グリッドへ直接入れたセルを控えておく。
		# ラベルではなくセル（＝グリッドの子）でなければ、隠しても
		# GridContainer は列を詰めてくれず空白の行が残る。
		# GRID_COLUMNS と同じ数・同じ順で並べること。
		"cells": [
			name_cell, price_cell, ratio_label, supply_cell,
			held_label, buy_button, sell_button,
		] as Array[Control],
	}


func refresh() -> void:
	if _session == null or _rows.is_empty():
		return
	if is_instance_valid(_title):
		var companion_note: String = ""
		if _session.active_companion == "fina":
			# 割引率は GameData の定数から出す。ここに数値を直書きすると、
			# 定数を変えたときに表示だけが嘘になる。
			companion_note = "（フィナ同行中・買値-%d%%）" % int(round(
				GameData.COMPANION_BUY_DISCOUNT * 100.0))
		_title.text = "市場 — %s%s" % [GameData.CITIES[_session.current_city]["name"], companion_note]

	var over: bool = _session.is_over()

	# 「今いちばんお得」な行を決めるため、先に全品目の比率と所持数を集める。
	# 隠す行は候補から外す。見えない行に◎最安が付くと、どこにも出ないまま
	# 「今日いちばん安いもの」を指す指標が消えてしまう。
	var ratios: Dictionary = {}
	var held_counts: Dictionary = {}
	var visible_items: Dictionary = {}
	var best_buy_item: String = ""
	var best_sell_item: String = ""
	for item_id: String in _rows:
		var price: int = _session.prices.get_price(_session.current_city, item_id)
		var base: int = GameData.ITEMS[item_id]["base_price"]
		var ratio: float = float(price) / float(base)
		var held: int = _session.cargo_count(item_id)
		ratios[item_id] = ratio
		held_counts[item_id] = held
		var shown: bool = _is_tradable_here(item_id, held)
		visible_items[item_id] = shown
		if not shown:
			continue
		if best_buy_item == "" or ratio < ratios[best_buy_item]:
			best_buy_item = item_id
		if held > 0 and (best_sell_item == "" or ratio > ratios[best_sell_item]):
			best_sell_item = item_id

	for item_id: String in _rows:
		var row: Dictionary = _rows[item_id]
		if not is_instance_valid(row["price"]):
			continue
		_set_row_visible(row, visible_items[item_id])
		if not visible_items[item_id]:
			# 行ごと消えたなら長押しの対象も消えている。上の disabled と
			# 同じ理由で、ここでも打ち切っておく。
			if _hold_item == item_id:
				_stop_hold()
			# 隠した行の中身は更新しない。次に現れるときに refresh() が
			# 作り直すため、古い値が見えることはない。
			# ただし所持数の記録だけは合わせておく（隠れている間の増減を
			# 復帰時にまとめてアニメーションさせないため）。
			_displayed_held[item_id] = held_counts[item_id]
			continue
		var ratio: float = ratios[item_id]
		var held: int = held_counts[item_id]

		# 建値ではなく実際の単価を出す。買値と売値は在庫・需要で開くため、
		# 「買 / 売」の2段で並べて押す前に差が見えるようにする。
		row["price"].text = "%s / %s" % [
			UiUtil.format_number(_session.buy_price(item_id)),
			UiUtil.format_number(_session.sell_price(item_id)),
		]
		if is_instance_valid(row["bar"]):
			row["bar"].ratio = ratio

		_refresh_supply(row, item_id)

		# 色に頼らず向きが分かるよう記号を添える。
		row["ratio"].text = "%s%d%%" % [arrow_for(ratio), int(round(ratio * 100.0))]
		row["ratio"].add_theme_color_override("font_color", UiTheme.ratio_color(ratio))
		if is_instance_valid(row["accent"]):
			row["accent"].color = UiTheme.ratio_color(ratio)

		if _displayed_held.has(item_id) and _displayed_held[item_id] != held:
			_animate_held(item_id, _displayed_held[item_id], held)
		elif is_instance_valid(row["held"]):
			row["held"].text = str(held)
		_displayed_held[item_id] = held

		_refresh_badge(row["badge"], item_id, item_id == best_buy_item, item_id == best_sell_item)

		row["buy"].disabled = over or _buy_amount(item_id) <= 0
		row["sell"].disabled = over or _sell_amount(item_id) <= 0
		# 長押し中のボタンが無効化・非表示になったら長押しを打ち切る。
		# Godot は disabled にしても button_up を出さないため、放っておくと
		# 「押していないのに押しっぱなし」の状態が残る（次に在庫が戻った
		# 瞬間、指を離した後なのに取引が再開してしまう）。
		if _hold_item == item_id:
			var held_button: Button = row["buy"] if _hold_is_buy else row["sell"]
			if held_button.disabled:
				_stop_hold()
		# 押せない理由は在庫切れ・需要切れと資金不足で違う。ボタンが灰色に
		# なるだけでは区別できないので、ツールチップで理由を出す。
		row["buy"].tooltip_text = _buy_blocked_reason(item_id)
		row["sell"].tooltip_text = _sell_blocked_reason(item_id)

	_update_row_stripes(visible_items)


## その品目が今この都市で売買の対象になりうるか。
##
## 在庫が無ければ買えず、積荷に無ければ売れない。両方なら行を出す意味がない
## ので隠す。**資金不足や積載超過では隠さない** — それは品目ではなくこちらの
## 都合で、行が消えると「高くて買えない」ことすら分からなくなるため
## （買値は見せたまま、ボタンを無効にしてツールチップで理由を出す）。
##
## 需要切れは売れない理由になるが、それだけでは隠さない。在庫があれば買えるし、
## 積荷にあるなら「ここでは捌けない」と分かること自体が判断の材料になる。
##
## この条件により、レア品（探索でのみ手に入り生産は 0）は所持している都市でだけ
## 行が出る。市場で買えない品目が常時並んでいる状態が無くなる。
func _is_tradable_here(item_id: String, held: int) -> bool:
	return _session.stock_count(item_id) > 0 or held > 0


## 行を構成するセルをまとめて出し入れする。
## GridContainer は隠れた子を配置から外すため、行の7セルすべてを隠せば
## 行そのものが消える（1つでも残すと列がずれて以降の行が崩れる）。
func _set_row_visible(row: Dictionary, shown: bool) -> void:
	var cells: Array = row.get("cells", [])
	for cell: Control in cells:
		if is_instance_valid(cell):
			cell.visible = shown


## 在庫と需要の欄。残りが少ないほど警戒色にして、品切れが近いことを示す。
func _refresh_supply(row: Dictionary, item_id: String) -> void:
	var stock_label: Label = row.get("stock") as Label
	var demand_label: Label = row.get("demand") as Label
	if is_instance_valid(stock_label):
		var stock: int = _session.stock_count(item_id)
		stock_label.text = "在%d" % stock
		stock_label.add_theme_color_override("font_color",
			UiTheme.supply_color(_session.market.stock_ratio(_session.current_city, item_id)))
	if is_instance_valid(demand_label):
		var demand: int = _session.demand_count(item_id)
		demand_label.text = "需%d" % demand
		demand_label.add_theme_color_override("font_color",
			UiTheme.supply_color(_session.market.demand_ratio(_session.current_city, item_id)))


## 買えない理由。買える場合は空文字（ツールチップを出さない）。
func _buy_blocked_reason(item_id: String) -> String:
	if _session.is_over():
		return ""
	if _buy_amount(item_id) > 0:
		return ""
	if _session.stock_count(item_id) <= 0:
		return "この都市はこの品目を切らしている。日が変わると入荷する。"
	if _session.silver < _session.buy_price(item_id):
		return "シルバーが足りない。"
	return "積載に空きがない。"


## 売れない理由。売れる場合は空文字。
func _sell_blocked_reason(item_id: String) -> String:
	if _session.is_over():
		return ""
	if _sell_amount(item_id) > 0:
		return ""
	if _session.cargo_count(item_id) <= 0:
		return "積荷に無い。"
	return "この都市はこれ以上買い取れない。日が変わると需要が戻る。"


## 1行おきに薄い帯を敷き、横方向を追いやすくする。
## GridContainer には行の概念がないため、セルの背景として個別に敷く。
##
## 帯は全行へ最初に敷いておき、**見せるかどうかは refresh() のたびに
## 決め直す**（`_update_row_stripes()`）。行が隠れると見えている行の並びが
## 変わるため、作成時の順番で固定すると帯が2行続いたり消えたりする。
func _apply_row_stripes() -> void:
	if _grid == null:
		return
	for item_id: String in _rows:
		var row: Dictionary = _rows[item_id]
		for control: Control in _striped_controls(row):
			_add_stripe(control)


## 帯を敷く対象のセル。色そのものが情報を持つセル（比率の色帯）には重ねない。
func _striped_controls(row: Dictionary) -> Array[Control]:
	var out: Array[Control] = []
	for key: String in ["price", "bar", "badge", "ratio", "stock", "demand", "held"]:
		var control: Control = row.get(key) as Control
		if control != null and is_instance_valid(control):
			out.append(control)
	return out


## 見えている行だけを数えて、1行おきに帯を出す。
## 隠れた行を飛ばさないと、行が消えた箇所で縞が途切れて見える。
func _update_row_stripes(visible_items: Dictionary) -> void:
	var index: int = 0
	for item_id: String in _rows:
		if not visible_items.get(item_id, true):
			continue
		var striped: bool = index % 2 == 1
		for control: Control in _striped_controls(_rows[item_id]):
			var stripe: ColorRect = control.get_node_or_null("Stripe") as ColorRect
			if is_instance_valid(stripe):
				stripe.visible = striped
		index += 1


func _add_stripe(control: Control) -> void:
	if control.get_node_or_null("Stripe") != null:
		return
	var stripe := ColorRect.new()
	stripe.name = "Stripe"
	stripe.color = UiTheme.ROW_STRIPE
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiUtil.fill_parent(stripe)
	control.add_child(stripe)
	control.move_child(stripe, 0)


# --- 行の状態を外から見る入口 ---
#
# 検査（scenario_m16.gd）が行の中身を確かめるために使う。_rows の辞書を
# そのまま公開すると、キーの構造まで契約になって内部表現を変えられなくなる。
# 用途ごとの細い関数を通し、辞書は private のまま閉じておく。
#
# バッジと比率は Label ではなく String を返す。検査が見ているのは文字列だけで、
# Label で描くという実装の選択まで契約に含める理由がないため。


## 並んでいる品目のID。表示している順。
## 隠れている行も含む（行を作ってあるかを見るための入口）。
## 実際に見えているものは visible_item_ids() を使うこと。
func item_ids() -> Array[String]:
	var ids: Array[String] = []
	for item_id: String in _rows:
		ids.append(item_id)
	return ids


## 今この都市で実際に画面へ出ている品目のID。表示している順。
## 売買のどちらもできない品目（在庫0かつ所持0）は含まれない。
func visible_item_ids() -> Array[String]:
	var ids: Array[String] = []
	for item_id: String in _rows:
		if is_row_visible(item_id):
			ids.append(item_id)
	return ids


## その品目の行が画面に出ているか。
## 行の7セルは一括で出し入れするので、先頭のセルで代表させる。
func is_row_visible(item_id: String) -> bool:
	if not _rows.has(item_id):
		return false
	var cells: Array = _rows[item_id].get("cells", [])
	if cells.is_empty():
		return false
	var first: Control = cells[0] as Control
	return is_instance_valid(first) and first.visible


## その品目の価格バー。無ければ null。
func price_bar_for(item_id: String) -> PriceBar:
	if not _rows.has(item_id):
		return null
	return _rows[item_id]["bar"] as PriceBar


## その品目に表示中の価格の文言。無ければ空文字。
func price_text_for(item_id: String) -> String:
	return _row_label_text(item_id, "price")


## その品目に表示中の所持数の文言。無ければ空文字。
func held_text_for(item_id: String) -> String:
	return _row_label_text(item_id, "held")


## その品目に表示中の在庫の文言（"在12" の形）。無ければ空文字。
func stock_text_for(item_id: String) -> String:
	return _row_label_text(item_id, "stock")


## その品目に表示中の需要の文言（"需8" の形）。無ければ空文字。
func demand_text_for(item_id: String) -> String:
	return _row_label_text(item_id, "demand")


## その品目の買うボタン。無ければ null。
func buy_button_for(item_id: String) -> Button:
	if not _rows.has(item_id):
		return null
	return _rows[item_id]["buy"] as Button


## その品目の売るボタン。無ければ null。
func sell_button_for(item_id: String) -> Button:
	if not _rows.has(item_id):
		return null
	return _rows[item_id]["sell"] as Button


## その品目に出ているバッジの文言（特産・◎最安・◎高値など）。無ければ空文字。
## 隠れているバッジは「出ていない」として空文字を返す（文字だけ残って
## 非表示、という状態を検査が見逃さないようにするため）。
func badge_text_for(item_id: String) -> String:
	var label: Label = _row_label(item_id, "badge")
	if label == null or not label.visible:
		return ""
	return label.text


## その品目に出ている基準比の文言（"▼72%" の形）。無ければ空文字。
func ratio_text_for(item_id: String) -> String:
	return _row_label_text(item_id, "ratio")


## その品目の色帯。無ければ null。
func accent_for(item_id: String) -> ColorRect:
	if not _rows.has(item_id):
		return null
	return _rows[item_id]["accent"] as ColorRect


func _row_label_text(item_id: String, key: String) -> String:
	var label: Label = _row_label(item_id, key)
	return label.text if label != null else ""


func _row_label(item_id: String, key: String) -> Label:
	if not _rows.has(item_id):
		return null
	var label: Label = _rows[item_id].get(key) as Label
	if label == null or not is_instance_valid(label):
		return null
	return label


## 基準価格に対する向き。色が見分けにくい場合の手がかりになる。
## 純関数なので --script の検査から直接呼べる（scenario_m16.gd）。
static func arrow_for(ratio: float) -> String:
	if ratio <= UiTheme.CHEAP_RATIO:
		return "▼"
	if ratio >= UiTheme.DEAR_RATIO:
		return "▲"
	return "　"


## その品目がこの都市で安い理由や、今お得であることを示す。
## 何も無ければ隠す。特産・生産地・最安・高値は共存しうるので併記する。
func _refresh_badge(badge: Label, item_id: String,
		is_best_buy: bool, is_best_sell: bool) -> void:
	if not is_instance_valid(badge):
		return
	var city: Dictionary = GameData.CITIES[_session.current_city]
	var reasons: PackedStringArray = []
	if city["specialty"] == item_id:
		reasons.append(BADGE_SPECIALTY)
	elif city["bonus"] == item_id:
		reasons.append(BADGE_BONUS)
	if is_best_buy:
		reasons.append(BADGE_BEST_BUY)
	if is_best_sell:
		reasons.append(BADGE_BEST_SELL)

	if reasons.is_empty():
		badge.text = ""
		badge.visible = false
	else:
		badge.text = "・".join(reasons)
		badge.visible = true


## 買うボタンを押すと常に1個だけ購入する（購入可能数が0ならボタンは無効）。
func _buy_amount(item_id: String) -> int:
	return mini(1, _session.max_buyable(item_id))


## 売るボタンを押すと常に1個だけ売却する
## （所持数が0か、都市の需要が尽きていればボタンは無効）。
func _sell_amount(item_id: String) -> int:
	return mini(1, _session.max_sellable(item_id))


## 所持数の変化を短くカウントアップ／ダウンさせ、増減を色で示す。
## hud.gd の _animate_silver と同じ手法。ツリー外では即座に反映する。
func _animate_held(item_id: String, from: int, to: int) -> void:
	var row: Dictionary = _rows.get(item_id, {})
	var label: Label = row.get("held")
	if not is_instance_valid(label):
		return
	if not is_inside_tree():
		label.text = str(to)
		return

	if _held_tweens.has(item_id) and _held_tweens[item_id].is_valid():
		_held_tweens[item_id].kill()

	label.add_theme_color_override("font_color", UiTheme.GOOD if to > from else UiTheme.WARN)

	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_method(func(value: int) -> void: label.text = str(value),
		from, to, UiTheme.TWEEN_DURATION)
	tween.tween_property(label, "theme_override_colors/font_color",
		UiTheme.TEXT, UiTheme.FLASH_DURATION)
	tween.chain().tween_callback(func() -> void: label.text = str(to))
	_held_tweens[item_id] = tween


## 買う/売るボタンから所持数ラベルへアイコンを飛ばす。同一パネル内で完結する演出。
func _play_trade_fx(item_id: String, is_buy: bool) -> void:
	if not is_instance_valid(_fx) or not is_inside_tree():
		return
	var row: Dictionary = _rows.get(item_id, {})
	var from_control: Control = row.get("buy") if is_buy else row.get("sell")
	var to_control: Control = row.get("held")
	if not is_instance_valid(from_control) or not is_instance_valid(to_control):
		return
	var from_point: Vector2 = from_control.global_position + from_control.size * 0.5
	var to_point: Vector2 = to_control.global_position + to_control.size * 0.5
	_fx.fly_item(item_id, from_point, to_point, UiTheme.item_color(item_id))


## 長押しの開始。ここでは取引しない — 1個目は pressed（押して離した時）が
## 出す。押した瞬間に取引してしまうと、離す前に pressed も来て2個になる。
func _on_trade_button_down(item_id: String, is_buy: bool) -> void:
	_hold_item = item_id
	_hold_is_buy = is_buy
	_hold_remaining = HOLD_DELAY
	_hold_interval = HOLD_INTERVAL_MAX


## 指を離したら止める。次に押したときは待ちも速度も最初からやり直す
## （速いまま持ち越すと、1個だけ欲しくて押した2回目が走り出す）。
func _on_trade_button_up() -> void:
	_stop_hold()


func _stop_hold() -> void:
	_hold_item = ""
	_hold_remaining = 0.0
	_hold_interval = HOLD_INTERVAL_MAX


## 長押し中かどうか。検査から状態を確かめるために公開する。
func is_holding() -> bool:
	return _hold_item != ""


## 現在の連射間隔（秒）。押し続けるほど短くなる。検査用に公開する。
func hold_interval() -> float:
	return _hold_interval


## 経過時間を渡して、長押しの連射をその分だけ進める。返り値は成立した取引の数。
##
## _process から呼ぶが、**時間を引数で受け取る純粋な形にしてある** —
## ツリー外（--script のハーネス）ではフレームが進まず _process が走らないため、
## 検査はこれを直接呼んで長押しを再現する。
func advance_hold(delta: float) -> int:
	if _hold_item == "":
		return 0
	var traded_count: int = 0
	# 1フレームが長い（処理落ち・ブレークポイント）場合に取りこぼさないよう、
	# 残り時間が尽きる限り繰り返す。取引が成立しなくなったら抜ける。
	_hold_remaining -= delta
	# _repeat_once() は buy()/sell() 経由で refresh() を呼び、そこで長押しが
	# 打ち切られることがある（在庫が尽きてボタンが無効になった場合）。
	# 毎回 _hold_item を見直さないと、空になった対象で取引を続けようとする。
	while _hold_remaining <= 0.0 and _hold_item != "":
		if not _repeat_once():
			# 在庫切れ・資金切れ。押し続けても何も起きないので長押しを終える
			# （残り時間が負のまま回り続けると次のフレームで無駄に空回りする）。
			_stop_hold()
			break
		traded_count += 1
		_hold_interval = maxf(HOLD_INTERVAL_MIN, _hold_interval * HOLD_ACCEL)
		_hold_remaining += _hold_interval
	return traded_count


## 長押し中の1個を取引する。成立したら true。
func _repeat_once() -> bool:
	if _session == null or _session.is_over():
		return false
	if _hold_is_buy:
		if _buy_amount(_hold_item) <= 0 or not _session.buy(_hold_item, _buy_amount(_hold_item)):
			return false
		_play_trade_fx(_hold_item, true)
		traded.emit(_hold_item, true, _row_origin(_hold_item))
		return true
	if _sell_amount(_hold_item) <= 0 or not _session.sell(_hold_item, _sell_amount(_hold_item)):
		return false
	_play_trade_fx(_hold_item, false)
	traded.emit(_hold_item, false, _row_origin(_hold_item))
	return true


func _process(delta: float) -> void:
	advance_hold(delta)


func _on_buy_pressed(item_id: String) -> void:
	var amount: int = _buy_amount(item_id)
	if _session.buy(item_id, amount):
		_play_trade_fx(item_id, true)
		traded.emit(item_id, true, _row_origin(item_id))


func _on_sell_pressed(item_id: String) -> void:
	var amount: int = _sell_amount(item_id)
	if _session.sell(item_id, amount):
		_play_trade_fx(item_id, false)
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
