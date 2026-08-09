extends PanelContainer
## 市場画面。現在地の全品目について相場と売買を行う。
##
## 各行は「品目名 / 価格 / 基準比 / 所持数 / 買うボタン / 売るボタン」で構成する。
## 数量は指定しない。ボタンを押すたびに1個だけ取引する（連打で数量を調整する）。

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
## 品目行だけ個別に拡大する。
const ROW_FONT_SIZE: int = 20
const HEADER_FONT_SIZE: int = 15
const ROW_ICON_SIZE: int = 28
const TRADE_BUTTON_MIN_SIZE: Vector2 = Vector2(64, 44)

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

	if _fx == null:
		_fx = FxLayer.new()
		add_child(_fx)

	# ヘッダ行。
	for heading: String in ["品目", "価格", "基準比", "所持", "", ""]:
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
	var name_cell: HBoxContainer = UiIcons.make_labeled_item(
		item_id, GameData.ITEMS[item_id]["name"], ROW_ICON_SIZE)
	for child: Node in name_cell.get_children():
		if child is Label:
			(child as Label).add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	# 基準比に応じた色帯。数字を読まなくても安い/高いが一目で分かる。
	var accent := ColorRect.new()
	accent.name = "RatioAccent"
	accent.custom_minimum_size = Vector2(4, 0)
	accent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_cell.add_child(accent)
	name_cell.move_child(accent, 0)
	# その都市で安い理由や「今お得」を示すバッジ。都市/相場が変わると付け替える。
	var badge := Label.new()
	badge.name = "Badge"
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override("font_color", UiTheme.GOOD)
	badge.visible = false
	name_cell.add_child(badge)
	_grid.add_child(name_cell)

	# 価格の数字とバーを縦に重ねる。列は増やさない。
	var price_cell := VBoxContainer.new()
	price_cell.add_theme_constant_override("separation", 2)
	price_cell.custom_minimum_size = Vector2(96, 0)

	var price_label := Label.new()
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	price_cell.add_child(price_label)

	var bar: PriceBar = PriceBar.new()
	bar.name = "Bar"
	price_cell.add_child(bar)
	_grid.add_child(price_cell)

	var ratio_label := Label.new()
	ratio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ratio_label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	_grid.add_child(ratio_label)

	var held_label := Label.new()
	held_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	held_label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	_grid.add_child(held_label)

	var buy_button := Button.new()
	buy_button.text = "買う"
	buy_button.custom_minimum_size = TRADE_BUTTON_MIN_SIZE
	buy_button.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	buy_button.pressed.connect(_on_buy_pressed.bind(item_id))
	_grid.add_child(buy_button)

	var sell_button := Button.new()
	sell_button.text = "売る"
	sell_button.custom_minimum_size = TRADE_BUTTON_MIN_SIZE
	sell_button.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	sell_button.pressed.connect(_on_sell_pressed.bind(item_id))
	_grid.add_child(sell_button)

	return {
		"price": price_label,
		"bar": bar,
		"badge": badge,
		"accent": accent,
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

	# 「今いちばんお得」な行を決めるため、先に全品目の比率と所持数を集める。
	var ratios: Dictionary = {}
	var held_counts: Dictionary = {}
	var best_buy_item: String = ""
	var best_sell_item: String = ""
	for item_id: String in _rows:
		var price: int = _session.prices.get_price(_session.current_city, item_id)
		var base: int = GameData.ITEMS[item_id]["base_price"]
		var ratio: float = float(price) / float(base)
		var held: int = _session.cargo_count(item_id)
		ratios[item_id] = ratio
		held_counts[item_id] = held
		if best_buy_item == "" or ratio < ratios[best_buy_item]:
			best_buy_item = item_id
		if held > 0 and (best_sell_item == "" or ratio > ratios[best_sell_item]):
			best_sell_item = item_id

	for item_id: String in _rows:
		var row: Dictionary = _rows[item_id]
		if not is_instance_valid(row["price"]):
			continue
		var price: int = _session.prices.get_price(_session.current_city, item_id)
		var ratio: float = ratios[item_id]
		var held: int = held_counts[item_id]

		row["price"].text = UiUtil.format_number(price)
		if is_instance_valid(row["bar"]):
			row["bar"].ratio = ratio

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


## 1行おきに薄い帯を敷き、横方向を追いやすくする。
## GridContainer には行の概念がないため、セルの背景として個別に敷く。
func _apply_row_stripes() -> void:
	if _grid == null:
		return
	# 色そのものが情報を持つセル（比率の色帯）には重ねない。
	var striped_keys: Array[String] = ["price", "bar", "badge", "ratio", "held"]
	var index: int = 0
	for item_id: String in _rows:
		if index % 2 == 1:
			var row: Dictionary = _rows[item_id]
			for key: String in striped_keys:
				var control: Control = row.get(key) as Control
				if control == null or not is_instance_valid(control):
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


# --- 行の状態を外から見る入口 ---
#
# 検査（scenario_m16.gd）が行の中身を確かめるために使う。_rows の辞書を
# そのまま公開すると、キーの構造まで契約になって内部表現を変えられなくなる。
# 用途ごとの細い関数を通し、辞書は private のまま閉じておく。
#
# バッジと比率は Label ではなく String を返す。検査が見ているのは文字列だけで、
# Label で描くという実装の選択まで契約に含める理由がないため。


## 並んでいる品目のID。表示している順。
func item_ids() -> Array[String]:
	var ids: Array[String] = []
	for item_id: String in _rows:
		ids.append(item_id)
	return ids


## その品目の価格バー。無ければ null。
func price_bar_for(item_id: String) -> PriceBar:
	if not _rows.has(item_id):
		return null
	return _rows[item_id]["bar"] as PriceBar


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


## 売るボタンを押すと常に1個だけ売却する（所持数が0ならボタンは無効）。
func _sell_amount(item_id: String) -> int:
	return mini(1, _session.cargo_count(item_id))


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
