extends Node3D
## 物流デバッグ用の 3D 図。都市を在庫の高さの棒、王道を線、隊商を点として描く。
##
## **本編の大陸図（map_view_3d.gd）とは別物で、あちらには一切触らない。**
## 大陸図は「その世界を眺める絵」なので、地形・草木・空・トゥーン輪郭が
## 乗っている。そこへデバッグ用の色分けを重ねると、見えているのが世界の色なのか
## 数値の色なのか区別できなくなり、しかも本編の見た目を壊す危険がある。
## ここは地面も空も持たない抽象図で、画面にあるものはすべて数値の写しになる。
##
## 都市の水平配置だけは大陸図と同じ `MapView3D.relax_positions()` を使う。
## 配置を別に持つと「地図で見た隣接」と「この図で見た隣接」が食い違い、
## デバッグ図を見て地図の不具合を推測できなくなる。
##
## 隊商の位置は sync() の時点に置くだけで、フレーム間の補間はしない。
## 大陸図の荷車は「運ばれている感じ」を出すために実時間で滑らかに動かして
## いる（map_view_3d.gd の CONVOY_TRAVEL_SECONDS）が、ここで同じことをすると
## 画面上の位置が logistics.leg_at() の値と一致しない瞬間ができ、
## 幾何を検査から確かめられなくなる。**この図では見た目＝データであること
## を優先する。**

const GameData = preload("res://scripts/systems/game_data.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const Logistics = preload("res://scripts/systems/logistics.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const MapView3D = preload("res://scripts/ui/map_view_3d.gd")

## 在庫が上限のときの棒の高さ。都市間の間隔（CITY_SPACING=10.58）に対して
## 十分低くして、隣の都市の棒に重なって見えないようにする。
const BAR_MAX_HEIGHT: float = 5.0
## 在庫0でも都市の位置が分かるように残す台座の高さ。0 にすると棒が消え、
## 「品切れの都市」と「そもそも棚が無い都市」が同じ絵（何も無い）になる。
const BAR_BASE_HEIGHT: float = 0.25
const BAR_RADIUS: float = 1.1

## 街道の線の太さ。隊商が通っている辺は TRAFFIC_WIDTH_PER_CONVOY ぶん太くする。
const ROAD_WIDTH: float = 0.16
const ROAD_WIDTH_PER_CONVOY: float = 0.14
const ROAD_LIFT: float = 0.04

## 隊商の点の大きさ。都市の棒（半径1.1）より十分小さく、かつ街道の線
## （太さ0.16）より大きくして、線の上に乗っているのが分かるようにする。
const CONVOY_SIZE: float = 0.62
const CONVOY_LIFT: float = 0.5

## 都市名ラベルの高さ（棒の先端からさらに上）と大きさ。
const LABEL_LIFT: float = 0.9
const LABEL_SIZE: float = 0.55

## カメラの既定の向きと距離。真上からだと棒の高さが読めず、低すぎると
## 手前の棒が奥を隠す。俯角はその間を取ってある。
const DEFAULT_YAW_DEGREES: float = 0.0
const DEFAULT_PITCH_DEGREES: float = -42.0
const DEFAULT_DISTANCE: float = 52.0
const MIN_DISTANCE: float = 18.0
const MAX_DISTANCE: float = 110.0
const MIN_PITCH_DEGREES: float = -88.0
const MAX_PITCH_DEGREES: float = -8.0

## 背景。パネルの地色（PANEL_FILL）より暗くして、図が浮いて見えるようにする。
const BACKGROUND := Color(0.07, 0.08, 0.10)

## 都市の水平配置（city_id -> Vector2）。大陸図と同じ計算。
var _flat: Dictionary = {}

var _camera: Camera3D
var _cities_root: Node3D
var _roads_root: Node3D
var _convoys_root: Node3D

## 今のカメラの向き。set_orbit() / orbit_by() が動かす。
var _yaw: float = DEFAULT_YAW_DEGREES
var _pitch: float = DEFAULT_PITCH_DEGREES
var _distance: float = DEFAULT_DISTANCE

## city_id -> 棒の MeshInstance3D。高さと色だけを毎回書き換える
## （作り直すと 10 都市ぶんのメッシュを毎日捨てることになる）。
var _city_bars: Dictionary = {}
## city_id -> Label3D。
var _city_labels: Dictionary = {}
## "a|b"（都市IDを昇順に並べた辺のキー）-> 街道の MeshInstance3D。
var _road_bars: Dictionary = {}
## 隊商の通し番号 -> MeshInstance3D。
var _convoy_nodes: Dictionary = {}

## 直近の sync() で描いた品目。検査と、パネルの見出しが読む。
var _item_id: String = ""


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


## ノードの組み立て。二重に呼ばれても安全。--script のハーネスでは _ready() が
## 走らないため _init() からも呼ぶ（docs/rules/ui.md）。
func _configure() -> void:
	if _camera != null:
		return

	_flat = MapView3D.relax_positions()

	_cities_root = Node3D.new()
	_cities_root.name = "Cities"
	add_child(_cities_root)

	_roads_root = Node3D.new()
	_roads_root.name = "Roads"
	add_child(_roads_root)

	_convoys_root = Node3D.new()
	_convoys_root.name = "Convoys"
	add_child(_convoys_root)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.current = true
	_camera.far = MAX_DISTANCE * 3.0
	_camera.environment = _make_environment()
	add_child(_camera)
	_apply_camera()

	# 平行光1本だけ。影は落とさない（棒の高さを読む図なので、影が落ちると
	# 隣の棒の色が変わって見え、色で表している在庫率と混ざる）。
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.0
	sun.shadow_enabled = false
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	add_child(sun)

	_build_static_geometry()


func _make_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.7)
	env.ambient_light_energy = 0.55
	return env


## 都市の棒・都市名・街道を1度だけ作る。sync() は高さ・色・太さを書き換えるだけ。
func _build_static_geometry() -> void:
	for city_id: String in GameData.CITIES:
		if not _flat.has(city_id):
			continue
		var bar := MeshInstance3D.new()
		bar.name = "City_%s" % city_id
		bar.mesh = CylinderMesh.new()
		bar.material_override = _make_material(UiTheme.TEXT_DIM)
		bar.position = _ground_position(city_id)
		_cities_root.add_child(bar)
		_city_bars[city_id] = bar

		var label := Label3D.new()
		label.name = "Label_%s" % city_id
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# 棒に隠れても読めるようにする。数値を読むための図なので、
		# 手前の棒に隠れて見えないラベルは無いのと同じ。
		label.no_depth_test = true
		label.font_size = 48
		label.pixel_size = LABEL_SIZE / 48.0
		label.modulate = UiTheme.TEXT
		label.outline_modulate = BACKGROUND
		_cities_root.add_child(label)
		_city_labels[city_id] = label

	for edge: Array in _all_edges():
		var key: String = _edge_key(edge[0], edge[1])
		if _road_bars.has(key):
			continue
		var road := MeshInstance3D.new()
		road.name = "Road_%s" % key
		road.mesh = BoxMesh.new()
		road.material_override = _make_material(UiTheme.PIN_STEM)
		_roads_root.add_child(road)
		_road_bars[key] = road
		_place_road(key, edge[0], edge[1], 0)


## 隊商が通れる辺すべて（王道＋黒ゾーンのゲート）。logistics.gd の
## _neighbors_of() と同じ道でなければ、街道の無い所を隊商が走って見える。
func _all_edges() -> Array:
	var edges: Array = []
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		edges.append([edge[0], edge[1]])
	for gate: String in GameData.BLACK_ZONE_GATES:
		edges.append([GameData.CAERLEON, gate])
	return edges


static func _edge_key(a: String, b: String) -> String:
	# 辺は向きを持たない。キーを昇順に固定しないと "a|b" と "b|a" が
	# 別の辺になり、同じ街道が2本描かれる。
	return "%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	# 図であって世界ではないので、陰影は付けるが金属反射は要らない。
	material.roughness = 1.0
	material.metallic = 0.0
	return material


## city_id の地面の位置（Y=0）。
func ground_position_of(city_id: String) -> Vector3:
	return _ground_position(city_id)


func _ground_position(city_id: String) -> Vector3:
	var flat: Vector2 = _flat.get(city_id, Vector2.ZERO)
	return Vector3(flat.x, 0.0, flat.y)


# --- 公開 API ---

## 図を今の状態に合わせる。item_id を指定するとその品目の在庫を、
## 空文字なら全品目の在庫率の平均を棒の高さにする。
##
## market と logistics を別々に受け取るのは、GameSession を知らずに済ませる
## ため（--script から MarketTable と Logistics を直接組んで呼べる）。
func sync(market: MarketTable, logistics: Logistics, item_id: String) -> void:
	_configure()
	_item_id = item_id
	_sync_cities(market, item_id)
	_sync_roads(logistics)
	_sync_convoys(logistics)


func item_id() -> String:
	return _item_id


## 検査とパネルが中身を確かめるための入口。
func city_bar_of(city_id: String) -> MeshInstance3D:
	return _city_bars.get(city_id) as MeshInstance3D


func city_label_of(city_id: String) -> Label3D:
	return _city_labels.get(city_id) as Label3D


func road_of(city_a: String, city_b: String) -> MeshInstance3D:
	return _road_bars.get(_edge_key(city_a, city_b)) as MeshInstance3D


func road_count() -> int:
	return _road_bars.size()


func convoy_node_count() -> int:
	return _convoy_nodes.size()


func convoy_node_of(convoy_id: int) -> MeshInstance3D:
	return _convoy_nodes.get(convoy_id) as MeshInstance3D


func camera() -> Camera3D:
	return _camera


func orbit_yaw() -> float:
	return _yaw


func orbit_pitch() -> float:
	return _pitch


func orbit_distance() -> float:
	return _distance


## カメラの向きを直接指定する。俯角と距離は範囲へ丸める。
func set_orbit(yaw_degrees: float, pitch_degrees: float, distance: float) -> void:
	_configure()
	_yaw = wrapf(yaw_degrees, -180.0, 180.0)
	_pitch = clampf(pitch_degrees, MIN_PITCH_DEGREES, MAX_PITCH_DEGREES)
	_distance = clampf(distance, MIN_DISTANCE, MAX_DISTANCE)
	_apply_camera()


## 相対的に動かす。パネルのドラッグとホイールから呼ぶ。
func orbit_by(yaw_delta: float, pitch_delta: float, distance_delta: float) -> void:
	set_orbit(_yaw + yaw_delta, _pitch + pitch_delta, _distance + distance_delta)


func reset_orbit() -> void:
	set_orbit(DEFAULT_YAW_DEGREES, DEFAULT_PITCH_DEGREES, DEFAULT_DISTANCE)


# --- 内部 ---

## カメラを原点まわりの球面上へ置く。
##
## look_at() ではなく look_at_from_position() を使うのは、ツリー外では
## global_transform が更新されず look_at() が使えないため（docs/rules/ui.md）。
func _apply_camera() -> void:
	var pitch: float = deg_to_rad(_pitch)
	var yaw: float = deg_to_rad(_yaw)
	var offset := Vector3(
		cos(pitch) * sin(yaw),
		-sin(pitch),
		cos(pitch) * cos(yaw)) * _distance
	_camera.look_at_from_position(offset, Vector3.ZERO, Vector3.UP)


## 都市の棒の高さと色を在庫に合わせる。
##
## 色は3通りに分ける。連続した色だけにすると「産地だから在庫が厚い」のか
## 「たまたま今日は運ばれてきた」のか区別できず、物流が効いているかどうかを
## この図から読めない。
##   産地      … GOOD（緑）。自分で作っているので運ばれてこない側。
##   棚が無い  … TEXT_UNKNOWN（灰）。stock_cap が0で、そもそも置けない。
##   それ以外  … WARN（空）→ FOCUS（満）の間を在庫率で補間。
func _sync_cities(market: MarketTable, target_item: String) -> void:
	for city_id: String in _city_bars:
		var ratio: float = _stock_ratio(market, city_id, target_item)
		var is_producer: bool = _is_producer(city_id, target_item)
		var has_shelf: bool = _has_shelf(city_id, target_item)

		var height: float = BAR_BASE_HEIGHT + ratio * BAR_MAX_HEIGHT
		var bar: MeshInstance3D = _city_bars[city_id]
		var mesh: CylinderMesh = bar.mesh
		mesh.top_radius = BAR_RADIUS
		mesh.bottom_radius = BAR_RADIUS
		mesh.height = height
		# CylinderMesh は原点が中心なので、底面を地面に合わせるには半分持ち上げる。
		bar.position = _ground_position(city_id) + Vector3(0.0, height / 2.0, 0.0)

		var color: Color = UiTheme.TEXT_UNKNOWN
		if is_producer:
			color = UiTheme.GOOD
		elif has_shelf:
			color = UiTheme.WARN.lerp(UiTheme.FOCUS, ratio)
		(bar.material_override as StandardMaterial3D).albedo_color = color

		var label: Label3D = _city_labels[city_id]
		label.text = _label_text(market, city_id, target_item)
		label.position = _ground_position(city_id) + Vector3(0.0, height + LABEL_LIFT, 0.0)


func _label_text(market: MarketTable, city_id: String, target_item: String) -> String:
	var city_name: String = GameData.CITIES[city_id]["name"]
	if target_item == "":
		return "%s\n平均 %d%%" % [
			city_name, int(round(_stock_ratio(market, city_id, "") * 100.0))]
	if not _has_shelf(city_id, target_item):
		return "%s\n棚なし" % city_name
	var mark: String = "産地 " if _is_producer(city_id, target_item) else ""
	return "%s\n%s%d/%d" % [
		city_name, mark,
		market.stock_of(city_id, target_item),
		MarketTable.stock_cap(city_id, target_item)]


## target_item が空なら、棚のある品目すべての在庫率の平均。
## 棚の無い組を平均に入れると、特産資源から遠い都市が常に低く見える
## （在庫の問題ではなく、置ける品目が少ないだけなのに）。
func _stock_ratio(market: MarketTable, city_id: String, target_item: String) -> float:
	if target_item != "":
		return clampf(market.stock_ratio(city_id, target_item), 0.0, 1.0)
	var total: float = 0.0
	var count: int = 0
	for id: String in GameData.ITEMS:
		if not _has_shelf(city_id, id):
			continue
		total += clampf(market.stock_ratio(city_id, id), 0.0, 1.0)
		count += 1
	return total / float(count) if count > 0 else 0.0


static func _is_producer(city_id: String, target_item: String) -> bool:
	return target_item != "" and MarketTable.production_of(city_id, target_item) > 0


static func _has_shelf(city_id: String, target_item: String) -> bool:
	return target_item == "" or MarketTable.stock_cap(city_id, target_item) > 0


## 街道の太さと色を、その辺を今通っている隊商の数に合わせる。
##
## 「今どの道が混んでいるか」は本数の分布そのもので、地図の荷車が偏って
## いないか（同じ道ばかり使っていないか）をここで見る。
func _sync_roads(logistics: Logistics) -> void:
	var traffic: Dictionary = {}
	for index: int in logistics.active_count():
		var leg: Dictionary = logistics.leg_at(index)
		if leg["from"] == "" or leg["to"] == "":
			continue
		var key: String = _edge_key(leg["from"], leg["to"])
		traffic[key] = int(traffic.get(key, 0)) + 1

	for key: String in _road_bars:
		var parts: PackedStringArray = key.split("|")
		_place_road(key, parts[0], parts[1], int(traffic.get(key, 0)))


func _place_road(key: String, city_a: String, city_b: String, traffic: int) -> void:
	var road: MeshInstance3D = _road_bars[key]
	var from_pos: Vector3 = _ground_position(city_a)
	var to_pos: Vector3 = _ground_position(city_b)
	var delta: Vector3 = to_pos - from_pos
	var length: float = delta.length()
	if length <= 0.001:
		road.visible = false
		return
	road.visible = true

	var width: float = ROAD_WIDTH + float(traffic) * ROAD_WIDTH_PER_CONVOY
	var mesh: BoxMesh = road.mesh
	mesh.size = Vector3(width, ROAD_WIDTH, length)

	var middle: Vector3 = (from_pos + to_pos) / 2.0 + Vector3(0.0, ROAD_LIFT, 0.0)
	# BoxMesh の長辺は Z。辺の向きへ Z を向ける。ツリー外では look_at() が
	# 使えないので、こちらも look_at_from_position() を通す。
	road.look_at_from_position(middle, middle + delta.normalized(), Vector3.UP)

	var color: Color = UiTheme.PIN_STEM
	if traffic > 0:
		color = UiTheme.FOCUS
	(road.material_override as StandardMaterial3D).albedo_color = color


## 隊商の点を今の一覧に合わせる。着いた隊商のノードは取り除く。
func _sync_convoys(logistics: Logistics) -> void:
	var seen: Dictionary = {}
	for index: int in logistics.active_count():
		var convoy_id: int = logistics.id_of(index)
		seen[convoy_id] = true

		var node: MeshInstance3D = _convoy_nodes.get(convoy_id) as MeshInstance3D
		if node == null:
			node = MeshInstance3D.new()
			node.name = "Convoy_%d" % convoy_id
			var box := BoxMesh.new()
			box.size = Vector3(CONVOY_SIZE, CONVOY_SIZE, CONVOY_SIZE)
			node.mesh = box
			node.material_override = _make_material(UiTheme.TEXT)
			_convoys_root.add_child(node)
			_convoy_nodes[convoy_id] = node

		var leg: Dictionary = logistics.leg_at(index)
		node.position = _leg_position(leg)
		(node.material_override as StandardMaterial3D).albedo_color = \
			UiTheme.item_color(logistics.item_of(index))

	for convoy_id: Variant in _convoy_nodes.keys():
		if seen.has(convoy_id):
			continue
		var stale: MeshInstance3D = _convoy_nodes[convoy_id]
		_convoys_root.remove_child(stale)
		stale.queue_free()
		_convoy_nodes.erase(convoy_id)


## leg_at() の結果を街道の上の位置へ写す。
func _leg_position(leg: Dictionary) -> Vector3:
	var from_city: String = leg["from"]
	var to_city: String = leg["to"]
	if from_city == "" or to_city == "":
		return Vector3(0.0, CONVOY_LIFT, 0.0)
	var from_pos: Vector3 = _ground_position(from_city)
	var to_pos: Vector3 = _ground_position(to_city)
	return from_pos.lerp(to_pos, float(leg["t"])) + Vector3(0.0, CONVOY_LIFT, 0.0)
