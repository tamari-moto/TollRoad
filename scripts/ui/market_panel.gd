extends PanelContainer
## 市場画面。現在地の全品目について相場と売買を行う。
##
## 各行は「品目名 / 価格 / 基準比 / 所持数 / 数量ステッパー / 買うボタン / 売るボタン」
## で構成する。数量は行ごとに ±1 ボタンとマウスホイールで1個ずつ調整し、
## 「全部」ボタンで一気に上限まで持っていける。

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

## 売買が成立した時に、その行の位置とともに知らせる。
## 演出はパネルをまたぐため、飛ばす先を知っている main.gd に任せる。
signal traded(item_id: String, is_buy: bool, origin: Vector2)

var _session: GameSession
var _rows: Dictionary = {}
## 品目ごとの希望数量（買う/売るどちらにも使う。実行時に各上限へ丸める）。
var _row_quantity: Dictionary = {}
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
	for heading: String in ["品目", "価格", "基準比", "所持", "数量", "", ""]:
		var label := Label.new()
		label.text = heading
		label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		_grid.add_child(label)

	for item_id: String in GameData.ITEMS:
		_rows[item_id] = _build_row(item_id)
		_row_quantity[item_id] = 1
	_apply_row_stripes()


func _build_row(item_id: String) -> Dictionary:
	# アイコンと名前を1セルに収める。列を増やすと行数の検査が壊れるため。
	var name_cell: HBoxContainer = UiIcons.make_labeled_item(
		item_id, GameData.ITEMS[item_id]["name"])
	# 基準比に応じた色帯。数字を読まなくても安い/高いが一目で分かる。
	var accent := ColorRect.new()
	accent.name = "RatioAccent"
	accent.custom_minimum_size = Vector2(3, 0)
	accent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_cell.add_child(accent)
	name_cell.move_child(accent, 0)
	# その都市で安い理由や「今お得」を示すバッジ。都市/相場が変わると付け替える。
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

	# 数量ステッパー。±ボタンとホイールで1個ずつ、全部ボタンで上限まで一気に。
	var qty_cell := HBoxContainer.new()
	qty_cell.name = "QtyStepper"
	qty_cell.add_theme_constant_override("separation", 2)
	qty_cell.gui_input.connect(_on_qty_wheel.bind(item_id))

	var minus_button := Button.new()
	minus_button.text = "－"
	minus_button.custom_minimum_size = Vector2(26, 0)
	minus_button.pressed.connect(step_quantity.bind(item_id, -1))
	qty_cell.add_child(minus_button)

	var qty_label := Label.new()
	qty_label.name = "QtyValue"
	qty_label.custom_minimum_size = Vector2(20, 0)
	qty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty_cell.add_child(qty_label)

	var plus_button := Button.new()
	plus_button.text = "＋"
	plus_button.custom_minimum_size = Vector2(26, 0)
	plus_button.pressed.connect(step_quantity.bind(item_id, 1))
	qty_cell.add_child(plus_button)

	var max_button := Button.new()
	max_button.text = "全部"
	max_button.pressed.connect(set_quantity_to_max.bind(item_id))
	qty_cell.add_child(max_button)

	_grid.add_child(qty_cell)

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
		"accent": accent,
		"ratio": ratio_label,
		"held": held_label,
		"qty_stepper": qty_cell,
		"qty_label": qty_label,
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
		row["ratio"].text = "%s%d%%" % [_arrow(ratio), int(round(ratio * 100.0))]
		row["ratio"].add_theme_color_override("font_color", UiTheme.ratio_color(ratio))
		if is_instance_valid(row["accent"]):
			row["accent"].color = UiTheme.ratio_color(ratio)

		if _displayed_held.has(item_id) and _displayed_held[item_id] != held:
			_animate_held(item_id, _displayed_held[item_id], held)
		elif is_instance_valid(row["held"]):
			row["held"].text = str(held)
		_displayed_held[item_id] = held

		_refresh_badge(row["badge"], item_id, item_id == best_buy_item, item_id == best_sell_item)

		var quantity: int = _clamp_row_quantity(item_id)
		if is_instance_valid(row["qty_label"]):
			row["qty_label"].text = str(quantity)

		row["buy"].disabled = over or _buy_amount(item_id) <= 0
		row["sell"].disabled = over or _sell_amount(item_id) <= 0


## 1行おきに薄い帯を敷き、横方向を追いやすくする。
## GridContainer には行の概念がないため、セルの背景として個別に敷く。
func _apply_row_stripes() -> void:
	if _grid == null:
		return
	# 色そのものが情報を持つセル（比率の色帯・数量の値）には重ねない。
	var striped_keys: Array[String] = [
		"price", "bar", "badge", "ratio", "held", "qty_stepper"]
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


## 基準価格に対する向き。色が見分けにくい場合の手がかりになる。
static func _arrow(ratio: float) -> String:
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


## 行ごとの希望数量を、その時点の上限（購入可能数と所持数の大きい方）に丸める。
func _clamp_row_quantity(item_id: String) -> int:
	var ceiling: int = maxi(1, maxi(_session.max_buyable(item_id), _session.cargo_count(item_id)))
	var clamped: int = clampi(_row_quantity.get(item_id, 1), 1, ceiling)
	_row_quantity[item_id] = clamped
	return clamped


## 希望数量に基づく実際の購入数（購入可能数を超えない）。
func _buy_amount(item_id: String) -> int:
	return mini(_row_quantity.get(item_id, 1), _session.max_buyable(item_id))


## 希望数量に基づく実際の売却数（所持数を超えない）。
func _sell_amount(item_id: String) -> int:
	return mini(_row_quantity.get(item_id, 1), _session.cargo_count(item_id))


## 品目の行に設定されている希望数量。--script からの検査用にも公開する。
func quantity_for(item_id: String) -> int:
	return _row_quantity.get(item_id, 1)


## 希望数量を1個ずつ増減する。±ボタンのクリック連打とホイールの両方から呼ばれる。
func step_quantity(item_id: String, delta: int) -> void:
	if not _rows.has(item_id):
		return
	var ceiling: int = maxi(1, maxi(_session.max_buyable(item_id), _session.cargo_count(item_id)))
	var before: int = _row_quantity.get(item_id, 1)
	var after: int = clampi(before + delta, 1, ceiling)
	if after == before:
		return
	_row_quantity[item_id] = after
	refresh()
	_animate_qty_pop(item_id)


## 希望数量を一気に上限まで引き上げる（「全部」ボタン）。
func set_quantity_to_max(item_id: String) -> void:
	if not _rows.has(item_id):
		return
	var ceiling: int = maxi(1, maxi(_session.max_buyable(item_id), _session.cargo_count(item_id)))
	var before: int = _row_quantity.get(item_id, 1)
	_row_quantity[item_id] = ceiling
	refresh()
	if ceiling != before:
		_animate_qty_pop(item_id)


## 数量ステッパー上でのマウスホイール操作。1ノッチ = ±1。
func _on_qty_wheel(event: InputEvent, item_id: String) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_WHEEL_UP:
		step_quantity(item_id, 1)
	elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step_quantity(item_id, -1)


## 数量が変わったことを一瞬の拡大とフラッシュで伝える。
## ツリー外（--script のハーネス）では Tween が作れないため何もしない。
func _animate_qty_pop(item_id: String) -> void:
	if not is_inside_tree():
		return
	var row: Dictionary = _rows.get(item_id, {})
	var label: Label = row.get("qty_label")
	if not is_instance_valid(label):
		return

	label.pivot_offset = label.size * 0.5
	label.scale = Vector2.ONE * 1.3
	label.add_theme_color_override("font_color", UiTheme.FOCUS)

	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, UiTheme.TWEEN_DURATION)
	tween.tween_property(label, "theme_override_colors/font_color",
		UiTheme.TEXT, UiTheme.FLASH_DURATION)


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
