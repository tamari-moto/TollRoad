extends Control
## 物流デバッグ用のグラフ。折れ線（日ごとの推移）と横棒（品目ごとの集計）の
## 2つの描き方を持つ。
##
## price_chart.gd を使い回さなかったのは、あちらが「品目ID → 価格」に閉じて
## いるため。系列の色を `UiTheme.item_color()` から引き、縦軸を価格として
## 丸め、凡例も品目名で組む。ここで要るのは「隊商の本数」「品切れ組数」の
## ように品目ではない系列なので、広げると price_chart.gd 側の前提が緩んで
## 本編の価格グラフの検査（scenario_m29.gd）が守っている性質が曖昧になる。
##
## 方針は price_chart.gd / city_radar_chart.gd と同じ:
## ノードはすべてコードで組み立て、**ジオメトリは実サイズ（size）ではなく
## chart_size を基準にする**。--script のハーネスはツリー外でレイアウトが
## 走らず size が確定しないため（docs/rules/ui.md）。
##
## 折れ線と横棒を1つのクラスに入れてあるのは、軸の余白・目盛りの色・空表示の
## 扱いが共通で、分けると同じ調整を2箇所に書くことになるため。描き分けるのは
## _draw() の中だけで、外からは set_line_data() / set_bar_data() のどちらを
## 呼んだかでモードが決まる。

const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

enum Mode { LINE, BAR }

const DEFAULT_SIZE: Vector2 = Vector2(620, 220)
const MARGIN_LEFT: float = 52.0
const MARGIN_RIGHT: float = 14.0
const MARGIN_TOP: float = 12.0
const MARGIN_BOTTOM: float = 26.0
## 横棒モードは品目名を左に置くので、折れ線より左の余白を広く取る。
const BAR_LABEL_WIDTH: float = 96.0
const BAR_VALUE_WIDTH: float = 54.0
## 横棒1本の高さと間隔。19品目が収まる高さを panel 側が chart_size に渡す。
const BAR_HEIGHT: float = 13.0
const BAR_GAP: float = 4.0

const LINE_WIDTH: float = 2.0
const TICK_FONT_SIZE: int = 11
const TICK_LABEL_WIDTH: float = 60.0
const TICK_TARGET_COUNT: int = 6
const TICK_STEPS: Array[int] = [1, 2, 5, 10, 15, 20, 25, 30, 50, 100]

## グラフの大きさ。set_chart_size() で変える（横棒は本数ぶん縦に伸びるため）。
var chart_size: Vector2 = DEFAULT_SIZE

var _mode: int = Mode.LINE
## 折れ線の系列。各要素は {"label": String, "color": Color, "values": Array[int]}。
var _series: Array[Dictionary] = []
## 横棒。各要素は {"label": String, "color": Color, "value": int}。
var _bars: Array[Dictionary] = []
## 折れ線の横軸の両端（記録の最初の日と最後の日）。
var _first_day: int = 1
var _last_day: int = 1
var _tick_days: Array[int] = [1]
## 縦軸の上限。0 のときは系列の最大値から決める。
var _forced_max: int = 0

## 空のときに出す文言。何も無い理由はビューごとに違う。
var _empty_text: String = "記録がありません"

## 動的に作り直すラベル（軸・目盛り・横棒の名前）。まとめて捨てて組み直す。
var _dynamic_labels: Array[Label] = []
var _empty_label: Label

## ホバー中の日（折れ線モードのみ）。-1 はホバーしていない。
var _hover_day: int = -1
var _tooltip: PanelContainer
var _tooltip_title: Label
var _tooltip_box: VBoxContainer
var _tooltip_rows: Array[Label] = []


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	if is_instance_valid(_empty_label):
		return
	custom_minimum_size = chart_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not gui_input.is_connected(_on_gui_input):
		gui_input.connect(_on_gui_input)
	if not mouse_exited.is_connected(clear_hover):
		mouse_exited.connect(clear_hover)

	_empty_label = Label.new()
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_label.text = _empty_text
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	add_child(_empty_label)

	_build_tooltip()
	_layout_static()


## 凡例（ホバー中に出す小窓）。price_chart.gd と同じ作り。
func _build_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override("panel", UiTheme.make_panel_style())
	_tooltip.visible = false

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)

	_tooltip_box = VBoxContainer.new()
	_tooltip_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_box.add_theme_constant_override("separation", 2)

	_tooltip_title = Label.new()
	_tooltip_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_title.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	_tooltip_title.add_theme_font_size_override("font_size", TICK_FONT_SIZE)
	_tooltip_box.add_child(_tooltip_title)

	margin.add_child(_tooltip_box)
	_tooltip.add_child(margin)
	add_child(_tooltip)


# --- 公開 API ---

## グラフの大きさを変える。横棒は本数ぶん縦に伸ばすので、パネル側が本数から
## 決めて渡す。呼んだら中身を入れ直すこと（軸の位置が変わる）。
func set_chart_size(new_size: Vector2) -> void:
	_configure()
	chart_size = new_size
	custom_minimum_size = new_size
	_layout_static()
	queue_redraw()


## 空のときに出す文言を変える。
func set_empty_text(text: String) -> void:
	_configure()
	_empty_text = text
	if is_instance_valid(_empty_label):
		_empty_label.text = text


## 折れ線を差し替える。
##
## series は {"label", "color", "values"} の配列。values は first_day から
## last_day まで1日ずつ埋まっている前提（記録がその形で来る）。
## forced_max に正の値を渡すと縦軸の上限をそこで固定する（品切れ組数の
## ように「母数に対して何組か」を見たいときに使う）。0 なら実測の最大値。
func set_line_data(series: Array[Dictionary], first_day: int, last_day: int,
		forced_max: int = 0) -> void:
	_configure()
	_mode = Mode.LINE
	_series = series.duplicate(true)
	_bars.clear()
	_first_day = maxi(first_day, 1)
	_last_day = maxi(last_day, _first_day)
	_forced_max = maxi(forced_max, 0)
	_tick_days = _compute_tick_days()
	clear_hover()
	_rebuild_tooltip_rows()
	_layout_static()
	queue_redraw()


## 横棒を差し替える。並びはそのまま上から下へ描く（並べ替えは呼ぶ側の責任）。
func set_bar_data(bars: Array[Dictionary]) -> void:
	_configure()
	_mode = Mode.BAR
	_bars = bars.duplicate(true)
	_series.clear()
	clear_hover()
	_layout_static()
	queue_redraw()


func mode() -> int:
	return _mode


## 折れ線の系列数 / 横棒の本数。検査が中身の件数を確かめるのに使う。
func series_count() -> int:
	return _series.size()


func bar_count() -> int:
	return _bars.size()


## 描くものがあるか。
##
## **系列の本数だけを見ないこと。** 記録が0日でも系列そのものは4本渡される
## （走行中・出発・到着・品切れ率）ため、系列数で判定すると「値が1つも
## 無いのに軸だけが引かれ、空の案内も出ない」という何も読み取れない絵になる。
func has_points() -> bool:
	for entry: Dictionary in _series:
		if not (entry["values"] as Array).is_empty():
			return true
	return not _bars.is_empty()


## 縦軸の上限（実際に描かれている値）。検査と、パネルの説明文に使う。
func value_max() -> int:
	if _forced_max > 0:
		return _forced_max
	var top: int = 0
	for entry: Dictionary in _series:
		for value: int in (entry["values"] as Array):
			top = maxi(top, value)
	for bar: Dictionary in _bars:
		top = maxi(top, int(bar["value"]))
	# 0 のままだと 0 除算になる。1 にすると「全部0」の線が下端に張り付く。
	return maxi(top, 1)


## 描画領域。折れ線と横棒で左の余白が違う（横棒は品目名を左に置くため）。
func plot_rect() -> Rect2:
	var left: float = BAR_LABEL_WIDTH if _mode == Mode.BAR else MARGIN_LEFT
	var right: float = (MARGIN_RIGHT + BAR_VALUE_WIDTH) if _mode == Mode.BAR else MARGIN_RIGHT
	var bottom: float = MARGIN_BOTTOM if _mode == Mode.LINE else MARGIN_TOP
	return Rect2(
		left, MARGIN_TOP,
		chart_size.x - left - right,
		chart_size.y - MARGIN_TOP - bottom)


## 日（1始まり）を描画領域内のX座標へ。
func x_for_day(day: int) -> float:
	var rect: Rect2 = plot_rect()
	if _last_day <= _first_day:
		return rect.position.x + rect.size.x / 2.0
	var ratio: float = float(day - _first_day) / float(_last_day - _first_day)
	return rect.position.x + clampf(ratio, 0.0, 1.0) * rect.size.x


## 系列 index の day_index（0始まり）番目の点の描画座標。
func point_for(index: int, day_index: int) -> Vector2:
	if index < 0 or index >= _series.size():
		return Vector2.ZERO
	var values: Array = _series[index]["values"]
	if day_index < 0 or day_index >= values.size():
		return Vector2.ZERO
	var rect: Rect2 = plot_rect()
	var ratio: float = clampf(float(values[day_index]) / float(value_max()), 0.0, 1.0)
	return Vector2(
		x_for_day(_first_day + day_index),
		rect.position.y + rect.size.y - ratio * rect.size.y)


## 横棒 index の矩形。長さは value_max() に対する割合。
func bar_rect(index: int) -> Rect2:
	if index < 0 or index >= _bars.size():
		return Rect2()
	var rect: Rect2 = plot_rect()
	var ratio: float = clampf(float(_bars[index]["value"]) / float(value_max()), 0.0, 1.0)
	return Rect2(
		rect.position.x,
		rect.position.y + float(index) * (BAR_HEIGHT + BAR_GAP),
		maxf(ratio * rect.size.x, 1.0),
		BAR_HEIGHT)


## 横棒モードで、本数を収めるのに要る高さ。パネルが set_chart_size() へ渡す。
static func height_for_bars(count: int) -> float:
	return MARGIN_TOP * 2.0 + float(maxi(count, 1)) * (BAR_HEIGHT + BAR_GAP)


# --- ホバー（折れ線モードのみ） ---

func _on_gui_input(event: InputEvent) -> void:
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		hover_at(motion.position)


## local_position に最も近い日へ凡例を合わせる。--script からは実際のマウスを
## 動かせないため、検査が直接呼べるよう公開している（price_chart.gd と同じ理由）。
func hover_at(local_position: Vector2) -> void:
	var rect: Rect2 = plot_rect()
	if _mode != Mode.LINE or _series.is_empty() or not rect.has_point(local_position):
		clear_hover()
		return
	var ratio: float = clampf((local_position.x - rect.position.x) / rect.size.x, 0.0, 1.0)
	var day: int = _first_day + int(round(ratio * float(_last_day - _first_day)))
	if day == _hover_day:
		return
	_hover_day = day
	_update_tooltip_content()
	_position_tooltip(local_position)
	_tooltip.visible = true
	queue_redraw()


func clear_hover() -> void:
	if _hover_day == -1:
		return
	_hover_day = -1
	if is_instance_valid(_tooltip):
		_tooltip.visible = false
	queue_redraw()


func hover_day() -> int:
	return _hover_day


func is_legend_visible() -> bool:
	return is_instance_valid(_tooltip) and _tooltip.visible


## ホバー中の凡例の index 番目の行の文字列。ホバーしていなければ空文字。
func legend_text_at(index: int) -> String:
	if _hover_day == -1 or index < 0 or index >= _tooltip_rows.size():
		return ""
	return _tooltip_rows[index].text


func _rebuild_tooltip_rows() -> void:
	if not is_instance_valid(_tooltip_box):
		return
	for row: Label in _tooltip_rows:
		if is_instance_valid(row):
			_tooltip_box.remove_child(row)
			row.queue_free()
	_tooltip_rows.clear()

	for entry: Dictionary in _series:
		var row := Label.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_color_override("font_color", entry["color"])
		row.add_theme_font_size_override("font_size", TICK_FONT_SIZE)
		_tooltip_box.add_child(row)
		_tooltip_rows.append(row)


func _update_tooltip_content() -> void:
	_tooltip_title.text = "%d日目" % _hover_day
	var day_index: int = _hover_day - _first_day
	for index: int in _tooltip_rows.size():
		var values: Array = _series[index]["values"]
		var value: int = int(values[day_index]) if day_index >= 0 and day_index < values.size() else 0
		_tooltip_rows[index].text = "%s: %s" % [
			_series[index]["label"], UiUtil.format_number(value)]


func _position_tooltip(local_position: Vector2) -> void:
	var box: Vector2 = _tooltip.size
	var pos: Vector2 = local_position + Vector2(12.0, 12.0)
	if pos.x + box.x > chart_size.x:
		pos.x = local_position.x - box.x - 12.0
	if pos.y + box.y > chart_size.y:
		pos.y = local_position.y - box.y - 12.0
	_tooltip.position = Vector2(maxf(pos.x, 0.0), maxf(pos.y, 0.0))


# --- 目盛りとラベル ---

func _compute_tick_days() -> Array[int]:
	var span: int = _last_day - _first_day
	if span <= 0:
		return [_first_day]

	var step: int = TICK_STEPS[TICK_STEPS.size() - 1]
	var raw: float = float(span) / float(TICK_TARGET_COUNT)
	for candidate: int in TICK_STEPS:
		if float(candidate) >= raw:
			step = candidate
			break

	var days: Array[int] = [_first_day]
	var d: int = _first_day + step
	while d < _last_day:
		days.append(d)
		d += step
	# 直前の目盛りが最終日に近すぎるとラベルが重なる（price_chart.gd で
	# 実際に潰れた）。間隔の半分未満なら直前を捨ててから最終日を足す。
	if days.size() > 1 and float(_last_day - days[days.size() - 1]) < float(step) / 2.0:
		days.remove_at(days.size() - 1)
	days.append(_last_day)
	return days


## 軸ラベル・目盛りラベル・横棒の名前を作り直す。本数がデータで変わるため、
## 位置決めだけでなく生成からやり直す。remove_child() と queue_free() の
## 両方が要る理由は ui_util.gd の clear_children() 参照。
func _layout_static() -> void:
	for label: Label in _dynamic_labels:
		if is_instance_valid(label):
			remove_child(label)
			label.queue_free()
	_dynamic_labels.clear()

	var rect: Rect2 = plot_rect()
	var is_empty: bool = not has_points()

	if is_instance_valid(_empty_label):
		_empty_label.visible = is_empty
		_empty_label.text = _empty_text
		_empty_label.custom_minimum_size = Vector2(rect.size.x, 0.0)
		_empty_label.position = Vector2(
			rect.position.x, rect.position.y + rect.size.y / 2.0 - 10.0)
	if is_empty:
		return

	if _mode == Mode.LINE:
		_layout_line_labels(rect)
	else:
		_layout_bar_labels(rect)


func _layout_line_labels(rect: Rect2) -> void:
	var top: int = value_max()
	_add_label(UiUtil.format_number(top), HORIZONTAL_ALIGNMENT_RIGHT,
		MARGIN_LEFT - 8.0, Vector2(0.0, rect.position.y - 8.0))
	_add_label(UiUtil.format_number(int(round(float(top) / 2.0))), HORIZONTAL_ALIGNMENT_RIGHT,
		MARGIN_LEFT - 8.0, Vector2(0.0, rect.position.y + rect.size.y / 2.0 - 8.0))
	_add_label("0", HORIZONTAL_ALIGNMENT_RIGHT,
		MARGIN_LEFT - 8.0, Vector2(0.0, rect.position.y + rect.size.y - 8.0))

	for day: int in _tick_days:
		_add_label("%d日目" % day, HORIZONTAL_ALIGNMENT_CENTER, TICK_LABEL_WIDTH,
			Vector2(x_for_day(day) - TICK_LABEL_WIDTH / 2.0,
				rect.position.y + rect.size.y + 4.0))


func _layout_bar_labels(rect: Rect2) -> void:
	for index: int in _bars.size():
		var bar: Rect2 = bar_rect(index)
		var name_label: Label = _add_label(_bars[index]["label"],
			HORIZONTAL_ALIGNMENT_RIGHT, BAR_LABEL_WIDTH - 8.0,
			Vector2(0.0, bar.position.y - 2.0))
		name_label.add_theme_color_override("font_color", UiTheme.TEXT)
		name_label.clip_text = true
		# 値は棒の右端ではなく描画領域の右外に揃える。棒に合わせると短い棒の
		# 数字が左に寄り、上下で桁が揃わず読み比べられない。
		_add_label(UiUtil.format_number(int(_bars[index]["value"])),
			HORIZONTAL_ALIGNMENT_LEFT, BAR_VALUE_WIDTH,
			Vector2(rect.position.x + rect.size.x + 6.0, bar.position.y - 2.0))


func _add_label(text: String, align: HorizontalAlignment, width: float,
		pos: Vector2) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.horizontal_alignment = align
	label.custom_minimum_size = Vector2(width, 0.0)
	label.position = pos
	label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	label.add_theme_font_size_override("font_size", TICK_FONT_SIZE)
	add_child(label)
	_dynamic_labels.append(label)
	return label


# --- 描画 ---

func _draw() -> void:
	var rect: Rect2 = plot_rect()
	draw_rect(rect, UiTheme.PANEL_BORDER, false, 1.0)
	if _mode == Mode.LINE:
		_draw_lines(rect)
	else:
		_draw_bars(rect)


func _draw_lines(rect: Rect2) -> void:
	var grid_color: Color = UiTheme.PANEL_BORDER
	grid_color.a = 0.35
	for day: int in _tick_days:
		var x: float = x_for_day(day)
		draw_line(Vector2(x, rect.position.y),
			Vector2(x, rect.position.y + rect.size.y), grid_color, 1.0)

	for index: int in _series.size():
		var values: Array = _series[index]["values"]
		var color: Color = _series[index]["color"]
		if values.size() <= 1:
			if values.size() == 1:
				draw_circle(point_for(index, 0), 3.0, color)
			continue
		var points: Array[Vector2] = []
		for i: int in values.size():
			points.append(point_for(index, i))
		draw_polyline(points, color, LINE_WIDTH)

	if _hover_day != -1:
		var hx: float = x_for_day(_hover_day)
		draw_line(Vector2(hx, rect.position.y),
			Vector2(hx, rect.position.y + rect.size.y), UiTheme.TEXT_DIM, 1.0)
		var day_index: int = _hover_day - _first_day
		for index2: int in _series.size():
			if day_index >= 0 and day_index < (_series[index2]["values"] as Array).size():
				draw_circle(point_for(index2, day_index), 4.0, _series[index2]["color"])


func _draw_bars(rect: Rect2) -> void:
	# 目盛りは縦線1本（上限の位置）だけ。横棒は長さを比べるためのもので、
	# 細かい格子を引くと棒より目立って比較の邪魔になる。
	var grid_color: Color = UiTheme.PANEL_BORDER
	grid_color.a = 0.35
	var mid_x: float = rect.position.x + rect.size.x / 2.0
	draw_line(Vector2(mid_x, rect.position.y),
		Vector2(mid_x, rect.position.y + rect.size.y), grid_color, 1.0)

	for index: int in _bars.size():
		var bar: Rect2 = bar_rect(index)
		draw_rect(Rect2(rect.position.x, bar.position.y, rect.size.x, bar.size.y),
			UiTheme.BAR_TRACK, true)
		draw_rect(bar, _bars[index]["color"], true)
