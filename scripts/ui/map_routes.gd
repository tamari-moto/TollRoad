extends Control
## 大陸図の経路線を描く層。都市ノードの下に敷く。
##
## 環状の王道（隣接都市どうし）は実線、カーレオンへ向かう黒ゾーンは
## 破線で描き、線を見ただけで危険な経路が分かるようにする。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

const ROAD_WIDTH: float = 3.0
const BLACK_ZONE_WIDTH: float = 2.0
## 破線の1区切りの長さ。
const DASH_LENGTH: float = 7.0

var _road_color := Color(0.45, 0.42, 0.36)
var _black_zone_color := UiTheme.WARN

## city_id -> 中心座標（親が配置後に渡す）。
var _positions: Dictionary = {}


func set_positions(positions: Dictionary) -> void:
	_positions = positions
	queue_redraw()


func _draw() -> void:
	if _positions.size() < 2:
		return

	# 王道: 環状に隣接する都市どうしを実線で結ぶ。
	var ring: Array[String] = GameData.royal_city_ids()
	for i: int in ring.size():
		var from_id: String = ring[i]
		var to_id: String = ring[(i + 1) % ring.size()]
		if _positions.has(from_id) and _positions.has(to_id):
			draw_line(_positions[from_id], _positions[to_id], _road_color, ROAD_WIDTH, true)

	# 黒ゾーン: 各王国都市からカーレオンへ破線を引く。
	if not _positions.has(GameData.CAERLEON):
		return
	var center: Vector2 = _positions[GameData.CAERLEON]
	for city_id: String in ring:
		if _positions.has(city_id):
			_draw_dashed(_positions[city_id], center)


## 破線を引く。危険な経路であることを線種で示す。
func _draw_dashed(from_point: Vector2, to_point: Vector2) -> void:
	var delta: Vector2 = to_point - from_point
	var length: float = delta.length()
	if length <= 0.0:
		return
	var direction: Vector2 = delta / length
	var traveled: float = 0.0
	while traveled < length:
		var segment_end: float = minf(traveled + DASH_LENGTH, length)
		draw_line(
			from_point + direction * traveled,
			from_point + direction * segment_end,
			_black_zone_color, BLACK_ZONE_WIDTH, true)
		traveled = segment_end + DASH_LENGTH
