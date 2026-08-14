extends Control
## 街のステータス画面: 基礎5資源（鉱石/木材/繊維/皮/石材）の生産量を
## 五角形のレーダーチャートで見せる。デバッグパネル（F3）の第3ビュー。
##
## 五角形の頂点順は構想スケッチに合わせ、上から時計回りに
## 鉱石→木材→繊維→皮→石材。生産量は特産地（distance 0）で最大の
## GameData.PRODUCTION_SPECIALTY に達するため、これを満点として正規化する
## （都市を跨いでも同じ物差しで形を比較できるようにするため）。
##
## ノードはすべてコードで組み立てる（他のデバッグ用パネルと同じ方針）。
## ジオメトリは実サイズ（size）ではなく固定の CHART_SIZE を基準にする —
## --script のハーネスではツリー外でレイアウトが走らず size が確定しない
## ため（docs/rules/ui.md）。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## 頂点の並び。スケッチと同じく上から時計回り。
const AXES: Array[String] = ["ore", "wood", "fiber", "hide", "stone"]

const CHART_SIZE: Vector2 = Vector2(380, 380)
const LABEL_MARGIN: float = 56.0
const LABEL_WIDTH: float = 96.0
const RING_RATIOS: Array[float] = [0.25, 0.5, 0.75, 1.0]

var _city_name: String = ""
var _raw: Dictionary = {}
var _labels: Dictionary = {}


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	if not _labels.is_empty():
		return
	custom_minimum_size = CHART_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	for item_id: String in AXES:
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
		label.add_theme_color_override("font_color", UiTheme.TEXT)
		add_child(label)
		_labels[item_id] = label
	_position_labels()


## city_id は現状 _raw の解釈には使わないが、都市を跨いで再利用する
## 呼び出し側の意図を明示するために受け取る（将来ツールチップ等で使う想定）。
func set_data(city_name: String, _city_id: String, raw_values: Dictionary) -> void:
	_configure()
	_city_name = city_name
	_raw = raw_values.duplicate()
	_update_labels()
	queue_redraw()


func city_name() -> String:
	return _city_name


func axis_ids() -> Array:
	return AXES.duplicate()


func raw_value_for(item_id: String) -> int:
	return int(_raw.get(item_id, 0))


## 満点（GameData.PRODUCTION_SPECIALTY）に対する充足度。0.0〜1.0。
func ratio_for(item_id: String) -> float:
	return clampf(float(raw_value_for(item_id)) / float(GameData.PRODUCTION_SPECIALTY), 0.0, 1.0)


func _center() -> Vector2:
	return CHART_SIZE / 2.0


func _radius() -> float:
	return CHART_SIZE.x / 2.0 - LABEL_MARGIN


func _angle_for(index: int) -> float:
	return -PI / 2.0 + float(index) * TAU / float(AXES.size())


func _vertex(index: int, radius: float) -> Vector2:
	var angle: float = _angle_for(index)
	return _center() + Vector2(cos(angle), sin(angle)) * radius


func _position_labels() -> void:
	var radius: float = _radius() + LABEL_MARGIN * 0.7
	for i: int in AXES.size():
		var label: Label = _labels[AXES[i]]
		var pos: Vector2 = _vertex(i, radius)
		label.position = pos - Vector2(LABEL_WIDTH / 2.0, 10.0)


func _update_labels() -> void:
	for item_id: String in AXES:
		var label: Label = _labels[item_id]
		label.text = "%s\n%d" % [GameData.ITEMS[item_id]["name"], raw_value_for(item_id)]


func _draw() -> void:
	var radius: float = _radius()
	if radius <= 0.0:
		return

	for ratio: float in RING_RATIOS:
		var ring: Array[Vector2] = []
		for i: int in AXES.size():
			ring.append(_vertex(i, radius * ratio))
		ring.append(ring[0])
		draw_polyline(ring, UiTheme.PANEL_BORDER, 1.0)

	for i: int in AXES.size():
		draw_line(_center(), _vertex(i, radius), UiTheme.PANEL_BORDER, 1.0)

	var points: Array[Vector2] = []
	for i: int in AXES.size():
		points.append(_vertex(i, radius * ratio_for(AXES[i])))

	var fill_color: Color = UiTheme.FOCUS
	fill_color.a = 0.28
	draw_colored_polygon(points, fill_color)

	var outline: Array[Vector2] = points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, UiTheme.FOCUS, 2.0)

	for point: Vector2 in points:
		draw_circle(point, 4.0, UiTheme.FOCUS)
