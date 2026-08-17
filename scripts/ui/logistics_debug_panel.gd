extends PanelContainer
## デバッグモード: 物流（logistics.gd）の状態を、グラフと 3D 図で見る。
## 併せて、物流の定数を実行中だけ上書きして効き方を確かめられる。
##
## **これは中身だけを持つ。** 置き場所（別ウィンドウ）と開閉は
## [logistics_debug_window.gd](logistics_debug_window.gd) が持つ。分けてあるのは、
## パネル自身が位置と可視状態を決めると、ウィンドウ側の可視状態と二重になり
## 「開いているのに見えない」組み合わせが作れてしまうため。
##
## 市場データの F3（debug_panel.gd）とは別の画面にしてある。物流は
## 「日ごとの推移」「街道の上のどこ」という時間と空間の軸を持ち、
## F3 の「今の在庫・需要の一覧」とは見る単位が違う。同じ画面に混ぜると、
## どちらの目的で開いたのか操作のたびに迷う。
##
## ノードはすべてコードで組み立てる（.tscn は作らない）。調整スライダーは
## logistics_tuning.gd の SPECS から生えるので、項目を足したら勝手に増える
## ——手書き .tscn だと項目を足すたびに2箇所を直すことになる。
##
## **記録（logistics_stats.gd）はこのパネルが持つ。** GameSession に持たせると
## セーブへ入れるか捨てるかを決めねばならず、デバッグ用の記録に払う代償として
## 重い（logistics_stats.gd 冒頭のコメント参照）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const LogisticsStats = preload("res://scripts/systems/logistics_stats.gd")
const LogisticsTuning = preload("res://scripts/systems/logistics_tuning.gd")
const LogisticsChart = preload("res://scripts/ui/logistics_chart.gd")
const LogisticsView3D = preload("res://scripts/ui/logistics_view_3d.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

## 推移 … 隊商の本数と出発・到着、品切れ組数の折れ線
## 在庫 … 選んだ品目の、全都市の在庫の折れ線
## 流量 … 直近 N 日に品目ごとに運ばれた個数の横棒
## 立体 … 3D 図（都市＝在庫の高さ、街道＝混み具合、隊商＝点）
enum View { TREND, STOCK, FLOW, WORLD }

## 右側の調整欄の幅。スライダーと数値入力と「戻す」が1行に収まる幅。
const TUNING_WIDTH: int = 360
const CHART_WIDTH: float = 700.0
const TREND_CHART_HEIGHT: float = 200.0
const STOCK_CHART_HEIGHT: float = 260.0
## 3D 図の大きさ。パネルの左半分にそのまま収まる。
const WORLD_SIZE: Vector2 = Vector2(700, 520)

## 流量の集計に使う日数の候補。切り替えて「直近1日」と「通し」を見比べる。
const FLOW_DAY_OPTIONS: Array[int] = [1, 7, 30, 400]

## 3D 図のドラッグ感度（1px あたりの度）とホイール1段の距離。
const ORBIT_DEGREES_PER_PIXEL: float = 0.35
const ZOOM_PER_WHEEL: float = 4.0

var _session: GameSession = null
var _stats: LogisticsStats = LogisticsStats.new()

var _view: int = View.TREND
var _item_ids: Array[String] = []
var _item_index: int = 0
var _flow_days_index: int = 1

var _view_buttons: Dictionary = {}
var _picker_row: HBoxContainer
var _prev_button: Button
var _next_button: Button
var _picker_label: Label
var _chart: LogisticsChart
var _chart_scroll: ScrollContainer
var _world_container: SubViewportContainer
var _world_viewport: SubViewport
var _world: LogisticsView3D
var _summary_label: Label
var _warning_label: Label
var _reset_all_button: Button
## key -> {"slider": HSlider, "spin": SpinBox, "reset": Button, "label": Label}
var _tuning_rows: Dictionary = {}
## スライダーと数値入力が互いを書き換えて無限に往復するのを止める。
var _syncing_tuning: bool = false
## 3D 図のドラッグ中か。
var _dragging: bool = false


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


## ノードの構築。二重に呼ばれても安全（_chart が既にあれば何もしない）。
## --script のハーネスでは _ready() が走らないため _init() からも呼ぶ。
func _configure() -> void:
	if _chart != null:
		return

	_item_ids.assign(GameData.ITEMS.keys())

	UiTheme.apply_panel_style(self)
	# 位置・大きさ・可視状態はここでは決めない。ウィンドウ側が
	# UiUtil.fill_window() で親いっぱいに広げる（冒頭のコメント参照）。

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	column.add_child(_build_header())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)

	body.add_child(_build_view_column())
	body.add_child(_build_tuning_column())

	_summary_label = Label.new()
	_summary_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	column.add_child(_summary_label)

	_rebuild_tuning_rows()


func _build_header() -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	# 閉じるボタンは置かない。ウィンドウのタイトルバーが×を持っており、
	# 2つあると「どちらがウィンドウごと閉じるのか」が見た目で判らない。
	var title := Label.new()
	title.text = "運送（Space で1日進む・F5 で閉じる）"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UiTheme.TEXT)
	header.add_child(title)

	_add_view_button(header, View.TREND, "推移", "隊商の本数・出発・到着と品切れ組数の日ごとの推移")
	_add_view_button(header, View.STOCK, "在庫", "選んだ品目の、全都市の在庫の推移")
	_add_view_button(header, View.FLOW, "流量", "直近N日に品目ごとに運ばれた個数")
	_add_view_button(header, View.WORLD, "立体", "都市＝在庫の高さ、街道＝混み具合、隊商＝点")
	return header


func _add_view_button(parent: HBoxContainer, view: int, text: String, help: String) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = help
	_connect_once(button.pressed, show_view.bind(view))
	parent.add_child(button)
	_view_buttons[view] = button


func _build_view_column() -> VBoxContainer:
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_picker_row = HBoxContainer.new()
	_picker_row.add_theme_constant_override("separation", 8)
	left.add_child(_picker_row)

	_prev_button = Button.new()
	_prev_button.text = "◀"
	_connect_once(_prev_button.pressed, _on_prev_pressed)
	_picker_row.add_child(_prev_button)

	_picker_label = Label.new()
	_picker_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_picker_label.add_theme_color_override("font_color", UiTheme.TEXT)
	_picker_row.add_child(_picker_label)

	_next_button = Button.new()
	_next_button.text = "▶"
	_connect_once(_next_button.pressed, _on_next_pressed)
	_picker_row.add_child(_next_button)

	# グラフは縦に伸びうる（流量の横棒は品目数ぶん）のでスクロールに入れる。
	_chart_scroll = ScrollContainer.new()
	_chart_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_chart_scroll)

	_chart = LogisticsChart.new()
	_chart_scroll.add_child(_chart)

	left.add_child(_build_world())
	return left


func _build_world() -> SubViewportContainer:
	_world_container = SubViewportContainer.new()
	_world_container.stretch = true
	_world_container.custom_minimum_size = WORLD_SIZE
	_world_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_world_container.visible = false
	_connect_once(_world_container.gui_input, _on_world_input)

	_world_viewport = SubViewport.new()
	# 付けないと本編の 2D 世界を映す（docs/rules/ui.md）。
	_world_viewport.own_world_3d = true
	_world_viewport.size = Vector2i(WORLD_SIZE)
	_world_viewport.transparent_bg = false
	# UPDATE_ALWAYS にしないこと。このパネルは普段閉じており、立体ビュー以外を
	# 開いている間もコンテナごと隠れている。常時更新にすると、見えない 3D を
	# 毎フレーム描き続ける（本編の大陸図と二重に描くことになる）。
	_world_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_world_container.add_child(_world_viewport)

	_world = LogisticsView3D.new()
	_world_viewport.add_child(_world)
	return _world_container


func _build_tuning_column() -> VBoxContainer:
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.custom_minimum_size = Vector2(TUNING_WIDTH, 0)
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = "調整（上書き。既定値は logistics.gd の const）"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(TUNING_WIDTH, 0)
	title.add_theme_color_override("font_color", UiTheme.TEXT)
	right.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)

	var box := VBoxContainer.new()
	box.name = "TuningRows"
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(TUNING_WIDTH - 16, 0)
	scroll.add_child(box)

	_warning_label = Label.new()
	_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning_label.custom_minimum_size = Vector2(TUNING_WIDTH, 0)
	_warning_label.add_theme_color_override("font_color", UiTheme.WARN)
	right.add_child(_warning_label)

	_reset_all_button = Button.new()
	_reset_all_button.text = "全部を既定値へ戻す"
	_connect_once(_reset_all_button.pressed, reset_all_tuning)
	right.add_child(_reset_all_button)
	return right


## 調整スライダーを SPECS から生やす。既定値は Logistics が持つので、
## 実際の値の書き込みは bind() 後の _refresh_tuning() が行う。
func _rebuild_tuning_rows() -> void:
	var box: Node = find_child("TuningRows", true, false)
	if box == null:
		return
	UiUtil.clear_children(box)
	_tuning_rows.clear()

	for spec: Dictionary in LogisticsTuning.SPECS:
		var key: String = spec["key"]

		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		box.add_child(row)

		var name_label := Label.new()
		name_label.text = spec["label"]
		name_label.tooltip_text = spec["help"]
		name_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		row.add_child(name_label)

		var controls := HBoxContainer.new()
		controls.add_theme_constant_override("separation", 6)
		row.add_child(controls)

		var slider := HSlider.new()
		slider.min_value = spec["min"]
		slider.max_value = spec["max"]
		slider.step = spec["step"]
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.tooltip_text = spec["help"]
		slider.value_changed.connect(_on_tuning_changed.bind(key))
		controls.add_child(slider)

		var spin := SpinBox.new()
		spin.min_value = spec["min"]
		spin.max_value = spec["max"]
		spin.step = spec["step"]
		spin.custom_minimum_size = Vector2(84, 0)
		spin.value_changed.connect(_on_tuning_changed.bind(key))
		controls.add_child(spin)

		var reset := Button.new()
		reset.text = "戻す"
		reset.tooltip_text = "この項目だけ既定値へ戻す"
		reset.pressed.connect(reset_tuning.bind(key))
		controls.add_child(reset)

		_tuning_rows[key] = {
			"slider": slider, "spin": spin, "reset": reset, "label": name_label,
		}


func _connect_once(sig: Signal, handler: Callable) -> void:
	if not sig.is_connected(handler):
		sig.connect(handler)


# --- 公開 API（main.gd / シナリオから使う） ---

func bind(session: GameSession) -> void:
	_configure()
	# セッションが入れ替わったら記録を捨てる。前のプレイの日数が残っていると
	# 横軸が繋がって見え、再プレイした瞬間にグラフが読めなくなる。
	if _session != session:
		_stats.clear()
	_session = session
	refresh()


## 今の状態を記録し、表示を組み直す。
##
## 同じ日に何度呼ばれても記録は増えない（logistics_stats.record() が同じ日を
## 上書きする）。移動や取引でも main.gd が refresh() を回すため、ここで
## 日数が増えると横軸が実際の経過日数とずれる。
func refresh() -> void:
	_configure()
	if _session == null:
		return
	_stats.record(_session.day, _session.logistics, _session.market)
	_refresh_view()
	_refresh_tuning()
	_refresh_summary()


func show_view(view: int) -> void:
	_configure()
	_view = view
	refresh()


func current_view() -> int:
	return _view


## 今つながっているセッション（未 bind なら null）。
## ウィンドウ側が Space で日を進めるのに使う。
func session() -> GameSession:
	return _session


## 在庫ビューで見る品目を指定する。
func select_item(item_id: String) -> void:
	var index: int = _item_ids.find(item_id)
	if index < 0:
		return
	_item_index = index
	refresh()


func current_item() -> String:
	return _item_ids[_item_index] if not _item_ids.is_empty() else ""


## 流量ビューの集計日数。
func flow_days() -> int:
	return FLOW_DAY_OPTIONS[_flow_days_index]


## 記録本体。検査が中身を確かめるために公開する。
func stats() -> LogisticsStats:
	return _stats


func chart() -> LogisticsChart:
	return _chart


func world() -> LogisticsView3D:
	return _world


func summary_text() -> String:
	return _summary_label.text if is_instance_valid(_summary_label) else ""


func warning_text() -> String:
	return _warning_label.text if is_instance_valid(_warning_label) else ""


# --- 調整 ---

## key を value へ上書きする。スライダー・数値入力の両方からここへ入る。
func set_tuning(key: String, value: float) -> void:
	_configure()
	if _session == null:
		return
	_session.logistics.tuning.set_override(key, value)
	refresh()


func reset_tuning(key: String) -> void:
	_configure()
	if _session == null:
		return
	_session.logistics.tuning.clear_override(key)
	refresh()


func reset_all_tuning() -> void:
	_configure()
	if _session == null:
		return
	_session.logistics.tuning.clear_all()
	refresh()


func _on_tuning_changed(value: float, key: String) -> void:
	if _syncing_tuning:
		return
	set_tuning(key, value)


# --- 表示の組み立て ---

func _refresh_view() -> void:
	for view: Variant in _view_buttons:
		(_view_buttons[view] as Button).disabled = view == _view

	var is_world: bool = _view == View.WORLD
	_chart_scroll.visible = not is_world
	_world_container.visible = is_world
	_picker_row.visible = _view != View.TREND

	match _view:
		View.TREND:
			_build_trend_chart()
		View.STOCK:
			_build_stock_chart()
		View.FLOW:
			_build_flow_chart()
		View.WORLD:
			_build_world_view()


## 隊商の本数・出発・到着と、品切れ組数。
##
## 品切れは別の縦軸（母数153）を持つので同じグラフに重ねない。重ねると
## 隊商の本数（0〜12）が下端に潰れて読めなくなる。2枚に分けたいところだが、
## 画面を2つ持つと切り替えが増えるので、品切れは割合（%）に直して同じ軸へ
## 乗せてある。「隊商12本」と「品切れ40%」が同じ高さに見えるのは承知の上で、
## 見たいのはそれぞれの線の**動き方**なので実害はない。
func _build_trend_chart() -> void:
	var denominator: int = maxi(LogisticsStats.shortage_denominator(), 1)
	var shortage_percent: Array[int] = []
	for value: int in _stats.series_of("shortage"):
		shortage_percent.append(int(round(float(value) * 100.0 / float(denominator))))

	var series: Array[Dictionary] = [
		{"label": "走行中", "color": UiTheme.FOCUS, "values": _stats.series_of("active")},
		{"label": "出発", "color": UiTheme.GOOD, "values": _stats.series_of("departed")},
		{"label": "到着", "color": UiTheme.TEXT, "values": _stats.series_of("arrived")},
		{"label": "品切れ率（全%d組）" % denominator, "color": UiTheme.WARN,
			"values": shortage_percent},
	]
	_chart.set_chart_size(Vector2(CHART_WIDTH, TREND_CHART_HEIGHT))
	_chart.set_empty_text("記録がありません（1日進めると記録が始まります）")
	_chart.set_line_data(series, _stats.first_day(), _stats.last_day())


## 選んだ品目の、全都市の在庫の推移。
func _build_stock_chart() -> void:
	var item_id: String = current_item()
	_picker_label.text = "品目: %s (%s)" % [GameData.ITEMS[item_id]["name"], item_id]

	var series: Array[Dictionary] = []
	for city_id: String in GameData.CITIES:
		# 棚の無い都市は常に0の線になる。19品目のうち何本かは必ずこうなり、
		# 底に張り付いた線が積み上がって他が読めなくなるので外す。
		if MarketTable.stock_cap(city_id, item_id) <= 0:
			continue
		# 産地は太い色（GOOD）、それ以外は都市を区別しない一色にはできない
		# ——どの都市の線か分からないと「どこへ届いていないか」が読めない。
		# 都市ごとの色は無いので、産地だけ GOOD にして残りは品目色から
		# 明度を振り分ける。
		var is_producer: bool = MarketTable.production_of(city_id, item_id) > 0
		series.append({
			"label": "%s%s" % [
				GameData.CITIES[city_id]["name"], "（産地）" if is_producer else ""],
			"color": UiTheme.GOOD if is_producer else _city_tint(city_id, item_id),
			"values": _stats.stock_series(city_id, item_id),
		})

	_chart.set_chart_size(Vector2(CHART_WIDTH, STOCK_CHART_HEIGHT))
	_chart.set_empty_text("この品目を置ける都市がありません（棚が無い）")
	_chart.set_line_data(series, _stats.first_day(), _stats.last_day())


## 消費地の線の色。品目色を都市ごとに明度で振り分ける。
##
## 都市に固有の色は UiTheme に無い（大陸図は紋章で区別しており色は使って
## いない）。ここで新しく10色を決めると、他の画面と食い違う色の体系が
## 増える。品目色から振るだけなら「どの品目のグラフか」も色から分かる。
func _city_tint(city_id: String, item_id: String) -> Color:
	var ids: Array = GameData.CITIES.keys()
	var index: int = ids.find(city_id)
	var span: float = maxf(float(ids.size() - 1), 1.0)
	var t: float = float(maxi(index, 0)) / span
	# 0.55〜1.25 倍。1.0 を跨ぐので、暗い側にも明るい側にも振れる。
	return UiTheme.item_color(item_id) * (0.55 + t * 0.7)


## 直近 N 日に品目ごとに運ばれた個数（隊商で着いた分）。
##
## 交易路（地図に出ない定常の補充）はここに含まれない。含めると総量の
## ほとんどが交易路になり、隊商がどの品目に偏っているかという肝心の
## 差が見えなくなる。
func _build_flow_chart() -> void:
	var days: int = flow_days()
	var label: String = "記録の全期間"
	if days < LogisticsStats.MAX_DAYS:
		label = "直近 %d 日" % days
	_picker_label.text = "集計: %s（隊商で着いた個数。交易路は含まない）" % label

	var totals: Dictionary = _stats.delivered_totals(days)
	var bars: Array[Dictionary] = []
	for item_id: String in _item_ids:
		bars.append({
			"label": GameData.ITEMS[item_id]["name"],
			"color": UiTheme.item_color(item_id),
			"value": int(totals.get(item_id, 0)),
		})
	# 多い順。宣言順のままだと、運ばれている品目を探すのに全部の棒を
	# 見比べることになる。
	var by_value := func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["value"]) > int(b["value"])
	bars.sort_custom(by_value)

	_chart.set_chart_size(Vector2(CHART_WIDTH, LogisticsChart.height_for_bars(bars.size())))
	_chart.set_empty_text("まだ何も着いていません")
	_chart.set_bar_data(bars)


func _build_world_view() -> void:
	var item_id: String = current_item()
	_picker_label.text = "品目: %s (%s)　ドラッグで回転・ホイールで拡大" % [
		GameData.ITEMS[item_id]["name"], item_id]
	_world.sync(_session.market, _session.logistics, item_id)


func _refresh_summary() -> void:
	var latest: Dictionary = _stats.latest()
	var denominator: int = LogisticsStats.shortage_denominator()
	var tuning: LogisticsTuning = _session.logistics.tuning
	var overridden: int = tuning.overridden_keys().size()
	_summary_label.text = \
		"%d日目 ／ 走行中 %d／%d本　今日: 出発 %d・到着 %d　品切れ %d／%d組　記録 %d日　上書き %d項目" % [
			_session.day,
			int(latest.get("active", 0)),
			tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS),
			int(latest.get("departed", 0)),
			int(latest.get("arrived", 0)),
			int(latest.get("shortage", 0)), denominator,
			_stats.day_count(), overridden,
		]


## スライダーと数値入力を今の値に合わせ、上書き中の項目に印を付ける。
##
## 値を書き戻すと value_changed が飛び、set_tuning() へ入って無限に往復する。
## _syncing_tuning でその往復だけを止める（set_block_signals() だと
## SpinBox の内部の LineEdit まで黙らせてしまい、表示が更新されない）。
func _refresh_tuning() -> void:
	var tuning: LogisticsTuning = _session.logistics.tuning
	_syncing_tuning = true
	for key: String in _tuning_rows:
		var row: Dictionary = _tuning_rows[key]
		var value: float = tuning.value_of(key)
		(row["slider"] as HSlider).value = value
		(row["spin"] as SpinBox).value = value

		var spec: Dictionary = LogisticsTuning.spec_of(key)
		var is_overridden: bool = tuning.is_overridden(key)
		var default_text: String = _format_value(tuning.default_of(key), spec)
		(row["label"] as Label).text = "%s%s（既定 %s）" % [
			"● " if is_overridden else "", spec["label"], default_text]
		(row["label"] as Label).add_theme_color_override(
			"font_color", UiTheme.FOCUS if is_overridden else UiTheme.TEXT_DIM)
		(row["reset"] as Button).disabled = not is_overridden
	_syncing_tuning = false

	(_reset_all_button as Button).disabled = not tuning.has_overrides()
	var warnings: Array[String] = tuning.warnings()
	_warning_label.visible = not warnings.is_empty()
	_warning_label.text = "\n".join(warnings)


static func _format_value(value: float, spec: Dictionary) -> String:
	if spec.is_empty():
		return str(value)
	return str(int(round(value))) if bool(spec["is_int"]) else "%.2f" % value


# --- 操作 ---

func _on_prev_pressed() -> void:
	_step_picker(-1)


func _on_next_pressed() -> void:
	_step_picker(1)


## ◀▶ が何を送るかはビューで違う（在庫と立体は品目、流量は集計日数）。
func _step_picker(delta: int) -> void:
	if _view == View.FLOW:
		var count: int = FLOW_DAY_OPTIONS.size()
		_flow_days_index = ((_flow_days_index + delta) % count + count) % count
	else:
		var items: int = _item_ids.size()
		_item_index = ((_item_index + delta) % items + items) % items
	refresh()


## 3D 図のドラッグ回転とホイール拡大。--script からは実際のマウスを動かせない
## ので、向きを変えるのは world().set_orbit() を直接呼んで確かめる。
func _on_world_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_world.orbit_by(0.0, 0.0, -ZOOM_PER_WHEEL)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_world.orbit_by(0.0, 0.0, ZOOM_PER_WHEEL)
		return

	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _dragging:
		_world.orbit_by(
			-motion.relative.x * ORBIT_DEGREES_PER_PIXEL,
			-motion.relative.y * ORBIT_DEGREES_PER_PIXEL,
			0.0)
