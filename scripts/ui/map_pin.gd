extends Control
## 都市マーカーのピン。菱形の枠・軸・都市名の下線を描く。
##
## Button の中に重ねて使う。クリック判定は Button 側が持つので、
## ここは見た目だけを担当し、入力は透過させる。

const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## 菱形の枠の大きさ（対角線の長さ）。
const FRAME_SIZE: float = 42.0
## 枠から地盤へ伸びる軸の長さ。
const STEM_LENGTH: float = 14.0
const LINE_WIDTH: float = 1.4
## 都市名の下線の幅。
const UNDERLINE_WIDTH: float = 1.0

## 危険な行き先（カーレオン）は枠の色を変える。
var danger: bool = false:
	set(value):
		danger = value
		queue_redraw()

## 現在地は枠を強調する。
var is_current: bool = false:
	set(value):
		is_current = value
		queue_redraw()

## 都市名ラベルの下線を引く高さ。親が設定する。
var underline_y: float = 0.0:
	set(value):
		underline_y = value
		queue_redraw()

## 下線の幅。
var underline_width: float = 0.0:
	set(value):
		underline_width = value
		queue_redraw()


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return

	var frame_color: Color = UiTheme.PIN_FRAME
	if is_current:
		frame_color = UiTheme.FOCUS
	elif danger:
		frame_color = UiTheme.WARN

	# 菱形の枠。紋章を囲む。
	var center := Vector2(size.x * 0.5, FRAME_SIZE * 0.5 + 2.0)
	var half: float = FRAME_SIZE * 0.5
	var diamond: PackedVector2Array = [
		center + Vector2(0.0, -half),
		center + Vector2(half * 0.72, 0.0),
		center + Vector2(0.0, half),
		center + Vector2(-half * 0.72, 0.0),
		center + Vector2(0.0, -half),
	]
	draw_polyline(diamond, frame_color, LINE_WIDTH, true)

	# 地盤へ伸びる軸。ピンが地面に刺さっているように見せる。
	var stem_top: float = center.y + half
	draw_line(
		Vector2(center.x, stem_top),
		Vector2(center.x, stem_top + STEM_LENGTH),
		UiTheme.PIN_STEM, LINE_WIDTH, true)

	# 都市名の下線。
	if underline_y > 0.0 and underline_width > 0.0:
		var half_width: float = underline_width * 0.5
		draw_line(
			Vector2(center.x - half_width, underline_y),
			Vector2(center.x + half_width, underline_y),
			UiTheme.PIN_UNDERLINE, UNDERLINE_WIDTH, true)
