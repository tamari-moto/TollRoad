extends Control
## 品目ごとの価格推移を折れ線で描く。横軸は経過日数、縦軸は価格。
##
## city_radar_chart.gd と同じ方針: ノードはすべてコードで組み立て、ジオメトリは
## 実サイズ（size）ではなく固定の CHART_SIZE を基準にする（--script のハーネスは
## ツリー外でレイアウトが走らず size が確定しないため。docs/rules/ui.md）。
##
## 複数品目を同じ軸に重ね書きする。線の色は UiTheme.item_color() から取る
## （品目ごとに固定の色が既に定義済みで、他画面の色分けとも揃う）。
##
## 横軸には目盛り（グリッド線とラベル）を打つ。日数が伸びるたびに間隔を
## 「きりのいい数」に選び直す（1〜60日で目盛りが5〜8本に収まる範囲）。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

const CHART_SIZE: Vector2 = Vector2(600, 200)
const MARGIN_LEFT: float = 56.0
const MARGIN_RIGHT: float = 12.0
const MARGIN_TOP: float = 12.0
const MARGIN_BOTTOM: float = 26.0
const LINE_WIDTH: float = 2.0
const TICK_LABEL_WIDTH: float = 60.0
## 既定のフォントサイズ（16）より小さく抑える。目盛りは軸の飾りであって
## 主役ではないが、半分（8）だと小さすぎて読みにくかったため一段階上げてある。
const TICK_FONT_SIZE: int = 11
## 目盛りの本数の目安（多すぎると詰まって読めず、少なすぎると細かい動きを追えない）。
const TICK_TARGET_COUNT: int = 6
## 間隔として選ぶ「きりのいい日数」の候補。
const TICK_STEPS: Array[int] = [1, 2, 5, 10, 15, 20, 25, 30, 50, 100]

## item_id -> Array[int]（1日目起点、日ごとに1件）。
var _series: Dictionary = {}
var _max_day: int = 1
## 横軸に打つ目盛りの日数（1始まり、昇順、末尾は必ず _max_day）。
var _tick_days: Array[int] = [1]

var _y_top: Label
var _y_mid: Label
var _y_bottom: Label
var _x_tick_labels: Array[Label] = []
var _empty_label: Label

## ホバー中の凡例。マウスを重ねている日数の、選択中の全品目を色つきで並べる。
var _hover_day: int = -1
var _tooltip: PanelContainer
var _tooltip_title: Label
var _tooltip_box: VBoxContainer
var _tooltip_rows: Dictionary = {}


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	if is_instance_valid(_y_top):
		return
	custom_minimum_size = CHART_SIZE
	# ホバーで凡例を出すために入力を受ける（既定は IGNORE だったが、単独の
	# Control で ScrollContainer の中ではないので、他の操作とは競合しない）。
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not gui_input.is_connected(_on_gui_input):
		gui_input.connect(_on_gui_input)
	if not mouse_exited.is_connected(clear_hover):
		mouse_exited.connect(clear_hover)

	var rect: Rect2 = plot_rect()

	_y_top = _make_label(HORIZONTAL_ALIGNMENT_RIGHT, MARGIN_LEFT - 8.0)
	_y_top.position = Vector2(0.0, rect.position.y - 8.0)
	add_child(_y_top)

	_y_mid = _make_label(HORIZONTAL_ALIGNMENT_RIGHT, MARGIN_LEFT - 8.0)
	_y_mid.position = Vector2(0.0, rect.position.y + rect.size.y / 2.0 - 8.0)
	add_child(_y_mid)

	_y_bottom = _make_label(HORIZONTAL_ALIGNMENT_RIGHT, MARGIN_LEFT - 8.0)
	_y_bottom.position = Vector2(0.0, rect.position.y + rect.size.y - 8.0)
	add_child(_y_bottom)

	_empty_label = Label.new()
	_empty_label.text = "品目を選ぶと価格の推移が表示されます"
	_empty_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.custom_minimum_size = Vector2(rect.size.x, 0.0)
	_empty_label.position = Vector2(rect.position.x, rect.position.y + rect.size.y / 2.0 - 10.0)
	add_child(_empty_label)

	_build_tooltip()
	_update_labels()


## ホバー中に出す凡例。map_panel.gd の都市ツールチップと同じ作り
## （PanelContainer + マウス操作を通さない mouse_filter = IGNORE）。
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


func _make_label(align: HorizontalAlignment, width: float) -> Label:
	var label := Label.new()
	label.horizontal_alignment = align
	label.custom_minimum_size = Vector2(width, 0.0)
	label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	label.add_theme_font_size_override("font_size", TICK_FONT_SIZE)
	return label


## 描画領域（軸ラベル分の余白を除いた矩形）。CHART_SIZE 基準の固定値。
func plot_rect() -> Rect2:
	return Rect2(
		MARGIN_LEFT, MARGIN_TOP,
		CHART_SIZE.x - MARGIN_LEFT - MARGIN_RIGHT,
		CHART_SIZE.y - MARGIN_TOP - MARGIN_BOTTOM)


## 表示する系列を差し替える。series は item_id -> Array[int]（同じ長さの前提）。
## max_day は横軸の終端（= 記録済みの日数）。
func set_data(series: Dictionary, max_day: int) -> void:
	_configure()
	_series = {}
	for item_id: String in series:
		var copy: Array[int] = []
		for value: Variant in (series[item_id] as Array):
			copy.append(int(value))
		_series[item_id] = copy
	_max_day = maxi(max_day, 1)
	_tick_days = _compute_tick_days(_max_day)
	_rebuild_tooltip_rows()
	_update_labels()
	clear_hover()
	queue_redraw()


## 凡例の行を選択中の品目に合わせて作り直す。品目の入れ替え（トグル操作）で
## 呼ぶため、ホバー中の値の更新（_update_tooltip_content()）とは別にしてある。
func _rebuild_tooltip_rows() -> void:
	if not is_instance_valid(_tooltip_box):
		return
	for item_id: String in _tooltip_rows:
		var row: Label = _tooltip_rows[item_id]
		if is_instance_valid(row):
			_tooltip_box.remove_child(row)
			row.queue_free()
	_tooltip_rows.clear()

	for item_id: String in _series:
		var row := Label.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_color_override("font_color", UiTheme.item_color(item_id))
		row.add_theme_font_size_override("font_size", TICK_FONT_SIZE)
		_tooltip_box.add_child(row)
		_tooltip_rows[item_id] = row


func item_ids() -> Array:
	return _series.keys()


func max_day() -> int:
	return _max_day


## 現在の横軸の目盛り（日数の一覧、昇順）。検査から目盛りの間隔を確かめるために公開する。
func tick_days() -> Array[int]:
	return _tick_days.duplicate()


func _on_gui_input(event: InputEvent) -> void:
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		hover_at(motion.position)


## local_position（この Control 内のローカル座標）に最も近い日へ凡例を合わせる。
## 描画領域の外なら凡例を消す。--script のハーネスは実際のマウスを動かせない
## ため、検査から直接呼べるよう公開している（map_panel.gd の pick_city_at() と同じ理由）。
func hover_at(local_position: Vector2) -> void:
	var rect: Rect2 = plot_rect()
	if _series.is_empty() or not rect.has_point(local_position):
		clear_hover()
		return

	var ratio: float = clampf((local_position.x - rect.position.x) / rect.size.x, 0.0, 1.0)
	var day: int = clampi(int(round(ratio * float(_max_day - 1))) + 1, 1, _max_day)
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


## 検査用。ホバー中でなければ -1。
func hover_day() -> int:
	return _hover_day


## ホバー中の凡例に出ている item_id の行の文字列（"品目名: 価格"）。
## ホバーしていない、またはその品目を表示していなければ空文字。
func legend_text_for(item_id: String) -> String:
	if _hover_day == -1 or not _tooltip_rows.has(item_id):
		return ""
	return (_tooltip_rows[item_id] as Label).text


## 凡例が表示されているか（ホバー中か）。
func is_legend_visible() -> bool:
	return is_instance_valid(_tooltip) and _tooltip.visible


func _update_tooltip_content() -> void:
	_tooltip_title.text = "%d日目" % _hover_day
	for item_id: String in _tooltip_rows:
		var values: Array = _series[item_id]
		var index: int = _hover_day - 1
		var price: int = values[index] if index >= 0 and index < values.size() else 0
		var name: String = GameData.ITEMS[item_id]["name"] if GameData.ITEMS.has(item_id) else item_id
		(_tooltip_rows[item_id] as Label).text = "%s: %s" % [name, UiUtil.format_number(price)]


## 凡例をマウスの近くへ置く。CHART_SIZE の右端・下端をはみ出さないよう寄せる。
func _position_tooltip(local_position: Vector2) -> void:
	var size: Vector2 = _tooltip.size
	var pos: Vector2 = local_position + Vector2(12.0, 12.0)
	if pos.x + size.x > CHART_SIZE.x:
		pos.x = local_position.x - size.x - 12.0
	if pos.y + size.y > CHART_SIZE.y:
		pos.y = local_position.y - size.y - 12.0
	_tooltip.position = Vector2(maxf(pos.x, 0.0), maxf(pos.y, 0.0))


## 目盛りの間隔を「きりのいい日数」から選ぶ。TICK_TARGET_COUNT 本に近づく
## 最小の候補を採用し、1日目と最終日は間隔に関わらず必ず含める。
func _compute_tick_days(max_day: int) -> Array[int]:
	if max_day <= 1:
		return [1]

	var step: int = TICK_STEPS[TICK_STEPS.size() - 1]
	var raw: float = float(max_day) / float(TICK_TARGET_COUNT)
	for candidate: int in TICK_STEPS:
		if float(candidate) >= raw:
			step = candidate
			break

	var days: Array[int] = [1]
	var d: int = step
	while d < max_day:
		days.append(d)
		d += step
	if days[days.size() - 1] != max_day:
		# 直前の目盛りが最終日に近すぎるとラベルが重なる（実測で "30日目" と
		# 隣接する目盛りが重なり "30日目目" のように潰れて見えた）。
		# 間隔の半分未満まで近ければ、直前の目盛りを削ってから最終日を足す。
		var last_regular: int = days[days.size() - 1]
		if days.size() > 1 and float(max_day - last_regular) < float(step) / 2.0:
			days.remove_at(days.size() - 1)
		days.append(max_day)
	return days


## 日数（1始まり）を描画領域内のX座標に変換する。
func _x_for_day(day: int) -> float:
	var rect: Rect2 = plot_rect()
	if _max_day <= 1:
		return rect.position.x + rect.size.x / 2.0
	var ratio: float = float(day - 1) / float(_max_day - 1)
	return rect.position.x + ratio * rect.size.x


## item_id の day_index（0始まり）番目の値を描画座標へ変換する。
## 範囲外や未知の item_id なら Vector2.ZERO。
func point_for(item_id: String, day_index: int) -> Vector2:
	if not _series.has(item_id):
		return Vector2.ZERO
	var values: Array = _series[item_id]
	if day_index < 0 or day_index >= values.size():
		return Vector2.ZERO

	var rect: Rect2 = plot_rect()
	var bounds: Vector2 = price_bounds()
	var y_ratio: float = 0.5
	if bounds.y > bounds.x:
		y_ratio = float(values[day_index] - bounds.x) / float(bounds.y - bounds.x)

	return Vector2(
		_x_for_day(day_index + 1),
		rect.position.y + rect.size.y - y_ratio * rect.size.y)


## 表示中の全系列を通した価格の範囲（上下に余白を足したもの）。
## 系列が空なら (0, 1) を返す（0除算を避けるためのプレースホルダ）。
func price_bounds() -> Vector2:
	var lo: float = INF
	var hi: float = -INF
	for item_id: String in _series:
		for value: int in (_series[item_id] as Array):
			lo = minf(lo, value)
			hi = maxf(hi, value)
	if lo == INF:
		return Vector2(0.0, 1.0)
	if lo == hi:
		lo -= 1.0
		hi += 1.0
	var pad: float = (hi - lo) * 0.08
	# 価格は負にならないため、下側の余白で0を割り込ませない。
	return Vector2(maxf(lo - pad, 0.0), hi + pad)


func _update_labels() -> void:
	if not is_instance_valid(_y_top):
		return
	var bounds: Vector2 = price_bounds()
	_y_top.text = UiUtil.format_number(int(round(bounds.y)))
	_y_mid.text = UiUtil.format_number(int(round((bounds.x + bounds.y) / 2.0)))
	_y_bottom.text = UiUtil.format_number(int(round(bounds.x)))

	_rebuild_x_labels()
	_empty_label.visible = _series.is_empty()


## 目盛りの本数が日数によって変わるため、ラベルは毎回作り直す。
## remove_child() と queue_free() の両方が要る（ui_util.gd の clear_children()
## と同じ理由。ここは対象がこの Control 自身の一部の子だけなので直接書く）。
func _rebuild_x_labels() -> void:
	for label: Label in _x_tick_labels:
		if is_instance_valid(label):
			remove_child(label)
			label.queue_free()
	_x_tick_labels.clear()

	var rect: Rect2 = plot_rect()
	for day: int in _tick_days:
		var label := _make_label(HORIZONTAL_ALIGNMENT_CENTER, TICK_LABEL_WIDTH)
		label.text = "%d日目" % day
		label.position = Vector2(
			_x_for_day(day) - TICK_LABEL_WIDTH / 2.0, rect.position.y + rect.size.y + 4.0)
		add_child(label)
		_x_tick_labels.append(label)


func _draw() -> void:
	var rect: Rect2 = plot_rect()
	draw_rect(rect, UiTheme.PANEL_BORDER, false, 1.0)

	# 目盛り線。境界を上塗りしないよう内側だけに薄く引く（city_radar_chart.gd と
	# 同じく、既存の色に alpha だけ足して使う）。
	var grid_color: Color = UiTheme.PANEL_BORDER
	grid_color.a = 0.35
	for day: int in _tick_days:
		var x: float = _x_for_day(day)
		draw_line(
			Vector2(x, rect.position.y), Vector2(x, rect.position.y + rect.size.y),
			grid_color, 1.0)

	if _series.is_empty():
		return

	for item_id: String in _series:
		var values: Array = _series[item_id]
		var color: Color = UiTheme.item_color(item_id)
		if values.size() <= 1:
			draw_circle(point_for(item_id, 0), 3.0, color)
			continue
		var points: Array[Vector2] = []
		for i: int in values.size():
			points.append(point_for(item_id, i))
		draw_polyline(points, color, LINE_WIDTH)

	if _hover_day != -1:
		var x: float = _x_for_day(_hover_day)
		draw_line(
			Vector2(x, rect.position.y), Vector2(x, rect.position.y + rect.size.y),
			UiTheme.TEXT_DIM, 1.0)
		for item_id: String in _series:
			var index: int = _hover_day - 1
			if index >= 0 and index < (_series[item_id] as Array).size():
				draw_circle(point_for(item_id, index), 4.0, UiTheme.item_color(item_id))
