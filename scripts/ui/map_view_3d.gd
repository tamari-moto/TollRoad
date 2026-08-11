extends Node3D
## 大陸図の 3D 表示。地形・都市・経路を組み立てる。
##
## 都市の配置は GameData.ROYAL_ROAD_EDGES（不規則な連結グラフ）を、決定的な
## ばね緩和（Fruchterman-Reingold 型の力学モデル）で水平面に配置してから
## 3D 空間に写す。中央にはレイヴンスパイアを固定する。乱数は使わないので
## 毎回ビット単位で同じ配置になる。
##
## クリック判定は 3D では行わない。map_panel が unproject_position() で
## 画面座標へ変換し、既存の Button を重ねる。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## 王道でつながる都市間の目標間隔（3D 空間の単位）。ばね緩和の引力が
## この距離に収束させようとする（旧・環状配置時代の値をそのまま踏襲）。
const CITY_SPACING: float = 10.58
## 地形の一辺に足す余白（配置全体の直径の外側）。
const TERRAIN_MARGIN: float = 16.0
## 盆地の半径に足す余白（配置全体の半径の外側）。
const BASIN_MARGIN: float = 2.0

## ばね緩和の反復回数。多いほど収束するが、都市数が10程度なので十分少なくて済む。
const RELAXATION_ITERATIONS: int = 300
## 反復1回あたりの最大移動量（温度）。反復が進むにつれ線形に0へ冷やす
## ことで発散を防ぎ、後半ほど収束に近づける（Fruchterman-Reingold の cooling）。
const RELAXATION_INITIAL_TEMPERATURE: float = CITY_SPACING * 0.5
## 中心からの半径を大まかに一定へ寄せる、弱い求心力の強さ（0〜1の割合）。
## 強すぎるとばねと反発の均衡を崩し、弱すぎると配置が全体に広がりすぎる。
const CENTERING_STRENGTH: float = 0.02

## 配置全体の半径（3D 空間の単位）。緩和後の実際の座標の広がりから
## _compute_scale() が算出する（環のような閉形式の計算はしない）。
var _ring_radius: float = 0.0
## 地形の一辺。都市が乗る範囲より広く取る。_compute_scale() で算出する。
var _terrain_size: float = 0.0
## 地形の分割数。多いほど滑らかだが重い。
const TERRAIN_SUBDIVISIONS: int = 64

## 起伏の高さ。
const TERRAIN_HEIGHT: float = 2.4
## ノイズの細かさ。
const TERRAIN_NOISE_SCALE: float = 0.10
## 中央を掘り下げる深さ。レイヴンスパイアが盆地の底に見えるようにする。
const BASIN_DEPTH: float = 2.2
## 盆地の広がり。_compute_scale() で算出する。
var _basin_radius: float = 0.0

## 都市の柱の高さと太さ。
const CITY_HEIGHT: float = 1.5
const CITY_RADIUS: float = 0.55

## 現在地を囲むリング。内外の二重で描く。
const RING_INNER_RADIUS: float = 1.5
const RING_OUTER_RADIUS: float = 2.1
## 円の分割数。少ないと多角形に見える。
const RING_SEGMENTS: int = 48
## 都市の柱の上に架ける高さ。柱（CITY_HEIGHT）より上に出す。
const RING_LIFT: float = 2.0

## 脈動の周期（秒）。地図を見ている間ずっと動くので、目につかない遅さにする。
const RING_PULSE_PERIOD: float = 2.8
## 脈動で半径が変わる割合。控えめに保つ。
const RING_PULSE_AMOUNT: float = 0.06

var _terrain: MeshInstance3D
var _cities: Dictionary = {}
var _routes: MeshInstance3D
var _selection_ring: MeshInstance3D
## 脈動のためにリングを引き直し続けるので、現在地を覚えておく。
var _ring_city: String = ""
var _pulse_time: float = 0.0
var _noise: FastNoiseLite

## city_id -> Vector3。map_panel がボタンを重ねるのに使う。
var positions: Dictionary = {}


func _init() -> void:
	_build()


func _ready() -> void:
	_build()


func _build() -> void:
	if not _cities.is_empty():
		return
	_noise = FastNoiseLite.new()
	_noise.seed = 20260802
	_noise.frequency = TERRAIN_NOISE_SCALE

	# 高さ（height_at()）は _basin_radius に依存するため、まず水平面
	# （X-Z）の配置をばね緩和で決め、その広がりから空間定数を算出してから
	# 高さ込みの最終座標を確定させる、という順序を守る必要がある。
	var flat_positions: Dictionary = _relax_positions()
	_compute_scale(flat_positions)
	_compute_positions(flat_positions)
	_build_terrain()
	_build_cities()
	_build_routes()
	_build_selection_ring()
	_build_light()


## 王国都市の水平面(X-Z)配置を、GameData.ROYAL_ROAD_EDGES に沿った決定的な
## ばね緩和で求める（Fruchterman-Reingold 型）。乱数は使わない。
## 中心都市（GameData.CAERLEON）は原点固定で、緩和の対象に含めない。
func _relax_positions() -> Dictionary:
	var ring: Array[String] = GameData.royal_city_ids()
	var flat: Dictionary = {}

	# 初期値は崩壊防止のための単なる仮配置（正円）。緩和で実際の間隔に収束する。
	var seed_radius: float = CITY_SPACING / (2.0 * sin(PI / float(ring.size())))
	for index: int in ring.size():
		var angle: float = -PI / 2.0 + TAU * float(index) / float(ring.size())
		flat[ring[index]] = Vector2(cos(angle), sin(angle)) * seed_radius

	var k: float = CITY_SPACING
	for iteration: int in RELAXATION_ITERATIONS:
		var forces: Dictionary = {}
		for city_id: String in ring:
			forces[city_id] = Vector2.ZERO

		# 反発力: 全ペア。近いほど強く押し合う（都市が重なるのを防ぐ）。
		for i: int in ring.size():
			for j: int in range(i + 1, ring.size()):
				var a: String = ring[i]
				var b: String = ring[j]
				var delta: Vector2 = flat[a] - flat[b]
				var dist: float = maxf(delta.length(), 0.01)
				var push: Vector2 = delta.normalized() * (k * k / dist)
				forces[a] += push
				forces[b] -= push

		# 引力: 王道でつながる都市どうしのみ。離れているほど強く引き合う。
		for edge: Array in GameData.ROYAL_ROAD_EDGES:
			var a: String = edge[0]
			var b: String = edge[1]
			var delta: Vector2 = flat[b] - flat[a]
			var dist: float = maxf(delta.length(), 0.01)
			var pull: Vector2 = delta.normalized() * (dist * dist / k)
			forces[a] += pull
			forces[b] -= pull

		# 中心からの半径を大まかに一定へ寄せる、弱い求心力。
		for city_id: String in ring:
			var radius: float = flat[city_id].length()
			if radius > 0.01:
				forces[city_id] -= flat[city_id].normalized() * (radius - seed_radius) * CENTERING_STRENGTH

		# 温度を反復とともに線形に冷やし、1回の移動量に上限をかける
		# （発散を防ぎ、後半の反復ほど収束に近づく）。
		var temperature: float = RELAXATION_INITIAL_TEMPERATURE * (1.0 - float(iteration) / float(RELAXATION_ITERATIONS))
		for city_id: String in ring:
			var force: Vector2 = forces[city_id]
			var magnitude: float = force.length()
			if magnitude > 0.01:
				flat[city_id] += force.normalized() * minf(magnitude, temperature)

	flat[GameData.CAERLEON] = Vector2.ZERO
	return flat


## 緩和後の実際の座標の広がりから空間定数を算出する
## （環のような閉形式の計算はせず、実測値から地形・盆地の大きさを決める）。
func _compute_scale(flat_positions: Dictionary) -> void:
	var max_radius: float = 0.0
	for city_id: String in flat_positions:
		max_radius = maxf(max_radius, flat_positions[city_id].length())
	_ring_radius = max_radius
	_terrain_size = _ring_radius * 2.0 + TERRAIN_MARGIN
	_basin_radius = _ring_radius + BASIN_MARGIN


## 緩和済みの水平面座標に高さ（height_at()）を足して最終的な 3D 座標にする。
func _compute_positions(flat_positions: Dictionary) -> void:
	for city_id: String in flat_positions:
		var p: Vector2 = flat_positions[city_id]
		positions[city_id] = Vector3(p.x, height_at(p.x, p.y), p.y)


## その地点の地面の高さ。都市も経路もこれに沿わせる。
func height_at(x: float, z: float) -> float:
	var h: float = _noise.get_noise_2d(x, z) * TERRAIN_HEIGHT
	# 中央を掘り下げる。レイヴンスパイアが盆地の底になり、
	# 外周の王国都市がそれを囲む地形として読める。
	var distance: float = Vector2(x, z).length()
	var basin: float = clampf(1.0 - distance / _basin_radius, 0.0, 1.0)
	return h - basin * basin * BASIN_DEPTH


func _build_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(_terrain_size, _terrain_size)
	plane.subdivide_width = TERRAIN_SUBDIVISIONS
	plane.subdivide_depth = TERRAIN_SUBDIVISIONS

	# 頂点を高さで動かして起伏を作る。
	var arrays: Array = plane.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i: int in vertices.size():
		var v: Vector3 = vertices[i]
		vertices[i] = Vector3(v.x, height_at(v.x, v.z), v.z)
	arrays[Mesh.ARRAY_VERTEX] = vertices

	# 法線を引き直さないと陰影が平らに見える。
	_recalculate_normals(arrays)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.22, 0.26, 0.30)
	material.roughness = 0.95
	material.metallic = 0.0
	mesh.surface_set_material(0, material)

	_terrain = MeshInstance3D.new()
	_terrain.name = "Terrain"
	_terrain.mesh = mesh
	add_child(_terrain)


## 頂点を動かした後の法線を求め直す。面の向きから平均する。
func _recalculate_normals(arrays: Array) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normals := PackedVector3Array()
	normals.resize(vertices.size())

	var i: int = 0
	while i + 2 < indices.size():
		var a: int = indices[i]
		var b: int = indices[i + 1]
		var c: int = indices[i + 2]
		# 外積の順序に注意。逆にすると法線が下を向き、地面が裏返って
		# 光が当たらず真っ黒になる。
		var face: Vector3 = (vertices[c] - vertices[a]).cross(
			vertices[b] - vertices[a])
		normals[a] += face
		normals[b] += face
		normals[c] += face
		i += 3

	for j: int in normals.size():
		normals[j] = normals[j].normalized() if normals[j].length() > 0.0 else Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = normals


func _build_cities() -> void:
	for city_id: String in positions:
		var pillar := MeshInstance3D.new()
		pillar.name = city_id

		var mesh := CylinderMesh.new()
		mesh.top_radius = CITY_RADIUS * 0.6
		mesh.bottom_radius = CITY_RADIUS
		mesh.height = CITY_HEIGHT
		mesh.radial_segments = 6
		pillar.mesh = mesh

		var material := StandardMaterial3D.new()
		material.albedo_color = _city_color(city_id)
		material.roughness = 0.6
		# 暗い地形の中でも都市が目立つよう、わずかに自己発光させる。
		material.emission_enabled = true
		material.emission = _city_color(city_id)
		material.emission_energy_multiplier = 0.35
		mesh.surface_set_material(0, material)

		var point: Vector3 = positions[city_id]
		pillar.position = point + Vector3(0.0, CITY_HEIGHT * 0.5, 0.0)
		add_child(pillar)
		_cities[city_id] = pillar


static func _city_color(city_id: String) -> Color:
	if city_id == GameData.CAERLEON:
		return UiTheme.WARN
	return UiTheme.PIN_FRAME


## 経路を地形の上に沿わせて描く。
## 王道は実線、黒ゾーンは切れ目のある線にして、2D 版と同じ区別を保つ。
## 黒ゾーンの破線は GameData.BLACK_ZONE_GATES の都市からのみ引く
## （それ以外の王国都市は中心都市と直結していない）。
func _build_routes() -> void:
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)

	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		_add_route(mesh, positions[edge[0]], positions[edge[1]],
			Color(0.45, 0.42, 0.36), false)

	var center: Vector3 = positions[GameData.CAERLEON]
	for city_id: String in GameData.BLACK_ZONE_GATES:
		_add_route(mesh, positions[city_id], center, UiTheme.WARN, true)

	mesh.surface_end()

	_routes = MeshInstance3D.new()
	_routes.name = "Routes"
	_routes.mesh = mesh
	add_child(_routes)


## 地形に沿った線を引く。dashed なら区切って破線にする。
func _add_route(mesh: ImmediateMesh, from_point: Vector3, to_point: Vector3,
		color: Color, dashed: bool) -> void:
	const STEPS: int = 24
	const LIFT: float = 0.12
	for i: int in STEPS:
		if dashed and i % 2 == 1:
			continue
		var t0: float = float(i) / float(STEPS)
		var t1: float = float(i + 1) / float(STEPS)
		var a: Vector3 = from_point.lerp(to_point, t0)
		var b: Vector3 = from_point.lerp(to_point, t1)
		# 地面にめり込まないよう、その地点の高さに合わせて少し浮かせる。
		a.y = height_at(a.x, a.z) + LIFT
		b.y = height_at(b.x, b.z) + LIFT
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(a)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(b)


## 現在地を囲むリング。入れ物だけ先に作り、中身は到着のたびに引き直す。
func _build_selection_ring() -> void:
	_selection_ring = MeshInstance3D.new()
	_selection_ring.name = "SelectionRing"
	_selection_ring.mesh = ImmediateMesh.new()
	add_child(_selection_ring)


## 脈動させる。地図を見ている間ずっと動くので、変化幅は小さく保つ。
func _process(delta: float) -> void:
	if _ring_city == "" or not is_instance_valid(_selection_ring):
		return
	if not _selection_ring.visible:
		return
	_pulse_time += delta
	_redraw_selection_ring(positions[_ring_city], pulse_scale())


## 経過時間に対する半径の倍率。1.0 を中心にゆっくり上下する。
##
## 内部状態を持たない純関数にしてあるのは、位相ごとの振る舞いを
## --script の検査から直接確かめられるようにするため
## （以前は _pulse_time を外から書き換えていた）。
static func pulse_scale_at(elapsed: float) -> float:
	var phase: float = TAU * elapsed / RING_PULSE_PERIOD
	return 1.0 + sin(phase) * RING_PULSE_AMOUNT


## 今この瞬間の半径の倍率。
func pulse_scale() -> float:
	return pulse_scale_at(_pulse_time)


## リングが付いている都市。付いていなければ空文字。
func ring_city() -> String:
	return _ring_city


## 指定した位相でリングを引き直す。
##
## 検査は時間を進められない（ツリー外では _process が回らない）ため、
## 位相を渡して任意の瞬間を再現できるようにしている。
func redraw_selection_ring_at(elapsed: float) -> void:
	if _ring_city == "" or not positions.has(_ring_city):
		return
	_redraw_selection_ring(positions[_ring_city], pulse_scale_at(elapsed))


## リングをその都市の足元に描き直す。
##
## 平らな円を作って位置だけ動かすのでは駄目で、都市ごとに地面の高さが
## 違うため斜面に埋まったり浮いたりする。円周上の各点で地形の高さを
## 引き直し、地面に寝かせる。
func _redraw_selection_ring(center: Vector3, scale: float) -> void:
	if not is_instance_valid(_selection_ring):
		return
	var mesh: ImmediateMesh = _selection_ring.mesh
	mesh.clear_surfaces()

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	_add_ring(mesh, center, RING_INNER_RADIUS * scale, UiTheme.FOCUS)
	_add_ring(mesh, center, RING_OUTER_RADIUS * scale, UiTheme.FOCUS)
	mesh.surface_end()


## 都市の頭上に水平な円を1本引く。
## 高さは中心の一点で決める。地形をなぞると輪が傾き、
## 都市に架かっているようには見えなくなる。
func _add_ring(mesh: ImmediateMesh, center: Vector3, radius: float,
		color: Color) -> void:
	var y: float = ring_height(center)
	for i: int in RING_SEGMENTS:
		var a0: float = TAU * float(i) / float(RING_SEGMENTS)
		var a1: float = TAU * float(i + 1) / float(RING_SEGMENTS)
		var p0 := Vector3(center.x + cos(a0) * radius, y,
			center.z + sin(a0) * radius)
		var p1 := Vector3(center.x + cos(a1) * radius, y,
			center.z + sin(a1) * radius)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(p0)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(p1)


## 輪を架ける高さ。都市の足元を基準にするので、
## 高地の都市では輪もそのぶん高くなる。
func ring_height(center: Vector3) -> float:
	return height_at(center.x, center.z) + RING_LIFT


func _build_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	# 斜め上から当てて起伏に陰影を付ける。影は gl_compatibility の
	# 制約と負荷を考えて無効のまま。
	light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	light.light_energy = 1.1
	add_child(light)


## 現在地を示す。都市の色を状態に合わせて塗り替える。
func set_current_city(city_id: String) -> void:
	for id: String in _cities:
		var pillar: MeshInstance3D = _cities[id]
		if not is_instance_valid(pillar) or pillar.mesh == null:
			continue
		var material: StandardMaterial3D = pillar.mesh.surface_get_material(0)
		if material == null:
			continue
		var color: Color = UiTheme.FOCUS if id == city_id else _city_color(id)
		material.albedo_color = color
		material.emission = color

	# 足元のリングを現在地へ移す。地面の高さが都市ごとに違うので引き直す。
	if positions.has(city_id):
		_ring_city = city_id
		# 到着のたびに位相を戻し、リングが広がるところから始まるようにする。
		_pulse_time = 0.0
		_redraw_selection_ring(positions[city_id], pulse_scale())
		if is_instance_valid(_selection_ring):
			_selection_ring.visible = true
	else:
		_ring_city = ""
		if is_instance_valid(_selection_ring):
			_selection_ring.visible = false
