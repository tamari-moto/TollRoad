extends Control
## 大陸図の地盤。各都市の足元に同心円を描く。
##
## 斜め見下ろしに合わせて円は楕円に潰す。都市が地面の上に立っている
## ように見せ、図ではなく地形として読めるようにするためのもの。
##
## 経路線よりさらに下に敷く。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## 同心円の重ね数。
const RING_COUNT: int = 4
## 一番外側の半径。
const OUTER_RADIUS: float = 46.0
## 円を描く分割数。多いほど滑らかになる。
const SEGMENTS: int = 40
const RING_WIDTH: float = 1.0
## 破線の1区切りが占める角度の割合。
const DASH_RATIO: float = 0.5

## city_id -> 中心座標。親が配置後に渡す。
var _positions: Dictionary = {}
var _current_city: String = ""


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_positions(positions: Dictionary, current_city: String) -> void:
	_positions = positions
	_current_city = current_city
	queue_redraw()


func _draw() -> void:
	for city_id: String in _positions:
		var center: Vector2 = _positions[city_id]
		var color: Color = UiTheme.GROUND_RING
		if city_id == _current_city:
			color = UiTheme.GROUND_RING_CURRENT
		elif city_id == GameData.CAERLEON:
			color = UiTheme.GROUND_RING_DANGER

		# カーレオンは破線にして、黒ゾーンであることを地面でも示す。
		var dashed: bool = city_id == GameData.CAERLEON
		for index: int in RING_COUNT:
			var scale: float = float(index + 1) / float(RING_COUNT)
			var radius: float = OUTER_RADIUS * scale
			# 外側ほど薄くして、地面に溶けるようにする。
			var fade: Color = color
			fade.a *= 1.0 - scale * 0.55
			_draw_ellipse(center, radius, fade, dashed)


## 斜め見下ろしに合わせて Y を潰した楕円を描く。
func _draw_ellipse(center: Vector2, radius: float, color: Color,
		dashed: bool) -> void:
	var points: PackedVector2Array = []
	for i: int in SEGMENTS + 1:
		var angle: float = TAU * float(i) / float(SEGMENTS)
		points.append(center + Vector2(
			cos(angle) * radius,
			sin(angle) * radius * UiTheme.MAP_TILT))

	if not dashed:
		draw_polyline(points, color, RING_WIDTH, true)
		return

	# 破線: 一定の区切りごとに線を飛ばす。
	var step: int = maxi(2, int(float(SEGMENTS) * DASH_RATIO / 4.0))
	var i: int = 0
	while i < SEGMENTS:
		var segment: PackedVector2Array = []
		for j: int in range(i, mini(i + step, SEGMENTS + 1)):
			segment.append(points[j])
		if segment.size() >= 2:
			draw_polyline(segment, color, RING_WIDTH, true)
		i += step * 2
