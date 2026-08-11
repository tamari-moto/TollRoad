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

## --- 空・霧・グロウ ---
## GL Compatibility でも動作する範囲（プロシージャルな空、ボリューメトリック
## でない深度フォグ、グロウ）に絞ってある。数値は初期値であり、実際の見え方
## は実機のGUIでしか判断できない（CLAUDE.md参照）。
const SKY_TOP_COLOR := Color(0.08, 0.09, 0.15)
const SKY_HORIZON_COLOR := Color(0.30, 0.26, 0.28)
const SKY_GROUND_COLOR := Color(0.05, 0.05, 0.07)
const AMBIENT_LIGHT_ENERGY: float = 0.6
const FOG_DENSITY: float = 0.01
const GLOW_INTENSITY: float = 0.8
const GLOW_BLOOM: float = 0.15

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

## 地形の頂点カラーに使う3色。盆地に近いほど暗く危険な色、外周に近いほど
## 明るい色を基調にし、傾斜が急なところほど岩肌寄りの色を混ぜる。
const TERRAIN_BASIN_COLOR := Color(0.16, 0.16, 0.20)
const TERRAIN_UPLAND_COLOR := Color(0.30, 0.34, 0.30)
const TERRAIN_ROCK_COLOR := Color(0.24, 0.22, 0.22)

## 都市の構造物（土台＋尖塔）が使える高さの予算と太さの基準。
## 現在地リングは地形の高さ + RING_LIFT に浮かぶ固定位置で、構造物の実際の
## 高さには追従しない。構造物がめり込んで見えないよう、パーツを増やしても
## 最高点がこの値を超えないようにすること
## （scenario_m17.gd の「柱より上に架かる」検査もこの前提）。
const CITY_HEIGHT: float = 1.5
const CITY_RADIUS: float = 0.55
## 土台が使う高さの割合。残りを尖塔に配分する。
const CITY_BASE_HEIGHT_RATIO: float = 0.5
## 尖塔が使う高さの割合（土台を除いた残りに対する比率）。本数を増やしても
## 個々の高さはほぼ揃えたままにする（本数で密度を、高さで危険度を示さない）。
const CITY_SPIRE_HEIGHT_RATIO: float = 0.85
## 尖塔の本数（中心都市以外）。city_id のハッシュから決定的に決める
## （真の乱数は使わない。同じ都市は毎回同じ見た目になる）。
const CITY_SPIRE_MIN: int = 1
const CITY_SPIRE_MAX: int = 2
## 中心都市の尖塔本数。密集させて、他と違う特別な場所だと分かるようにする。
const CAERLEON_SPIRE_COUNT: int = 4

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
	_build_environment()
	_build_terrain()
	_build_cities()
	_build_routes()
	_build_selection_ring()
	_build_light()


## 空・霧・グロウをまとめた環境設定。own_world_3d の SubViewport 内で
## 完結するので、本編の2D世界には影響しない。
func _build_environment() -> void:
	var environment := Environment.new()

	environment.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = SKY_TOP_COLOR
	sky_material.sky_horizon_color = SKY_HORIZON_COLOR
	sky_material.ground_bottom_color = SKY_GROUND_COLOR
	sky_material.ground_horizon_color = SKY_HORIZON_COLOR
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment.sky = sky

	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = AMBIENT_LIGHT_ENERGY

	# 地形の縁が霧に溶け、閉塞感（黒ゾーンを匂わせる雰囲気）を出す。
	environment.fog_enabled = true
	environment.fog_light_color = SKY_HORIZON_COLOR
	environment.fog_density = FOG_DENSITY

	# 都市の柱・現在地リングは自己発光しているので、グロウで街明かりのように滲む。
	environment.glow_enabled = true
	environment.glow_intensity = GLOW_INTENSITY
	environment.glow_bloom = GLOW_BLOOM

	var world_environment := WorldEnvironment.new()
	world_environment.name = "Environment"
	world_environment.environment = environment
	add_child(world_environment)


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

	# 傾斜（法線）と中心からの距離（盆地との近さ）から頂点カラーを塗る。
	# 法線再計算の後でないと傾斜が求まらないので、この順序を守ること。
	_assign_terrain_colors(arrays)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.metallic = 0.0
	mesh.surface_set_material(0, material)

	_terrain = MeshInstance3D.new()
	_terrain.name = "Terrain"
	_terrain.mesh = mesh
	add_child(_terrain)


## 高さ（盆地への近さ）と傾斜から頂点カラーを塗る。
## 盆地に近いほど TERRAIN_BASIN_COLOR、外周に近いほど TERRAIN_UPLAND_COLOR
## を基調にし、急斜面ほど TERRAIN_ROCK_COLOR を混ぜる。
func _assign_terrain_colors(arrays: Array) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors := PackedColorArray()
	colors.resize(vertices.size())

	for i: int in vertices.size():
		var v: Vector3 = vertices[i]
		# height_at() の basin と同じ考え方（中心に近いほど1.0）。
		var basin: float = clampf(1.0 - Vector2(v.x, v.z).length() / _basin_radius, 0.0, 1.0)
		var base: Color = TERRAIN_BASIN_COLOR.lerp(TERRAIN_UPLAND_COLOR, 1.0 - basin)
		var slope: float = clampf(1.0 - normals[i].y, 0.0, 1.0)
		colors[i] = base.lerp(TERRAIN_ROCK_COLOR, slope * 0.6)

	arrays[Mesh.ARRAY_COLOR] = colors


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
		var container := Node3D.new()
		container.name = city_id
		container.position = positions[city_id]
		add_child(container)
		_cities[city_id] = container

		for part: MeshInstance3D in _city_structure_parts(city_id):
			container.add_child(part)


## 都市ごとの構造物（土台＋尖塔）を組み立てる。真の乱数は使わず、city_id の
## ハッシュから決定的にばらつきを付ける（同じ都市は毎回同じ見た目になる。
## --script 検査と save/load の再現性を壊さないため）。
func _city_structure_parts(city_id: String) -> Array[MeshInstance3D]:
	var color: Color = _city_color(city_id)
	var is_hub: bool = city_id == GameData.CAERLEON
	var parts: Array[MeshInstance3D] = []

	# 土台。中心都市は少しだけ太くする。
	var base_height: float = CITY_HEIGHT * CITY_BASE_HEIGHT_RATIO
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = CITY_RADIUS * (0.85 if is_hub else 0.75)
	base_mesh.bottom_radius = CITY_RADIUS * (1.3 if is_hub else 1.0)
	base_mesh.height = base_height
	base_mesh.radial_segments = 6
	var base: MeshInstance3D = _make_city_part(base_mesh, color)
	base.position = Vector3(0.0, base_height * 0.5, 0.0)
	parts.append(base)

	# 尖塔。中心都市は本数を増やして密集させる（高さの予算は他都市と共通。
	# CITY_HEIGHT を超えると現在地リングにめり込むため、本数を増やしても
	# 個々の高さはほぼ揃えたままにする）。
	var spire_count: int = CAERLEON_SPIRE_COUNT if is_hub \
		else CITY_SPIRE_MIN + int(city_id.hash() % (CITY_SPIRE_MAX - CITY_SPIRE_MIN + 1))
	var spire_height: float = (CITY_HEIGHT - base_height) * CITY_SPIRE_HEIGHT_RATIO
	var cluster_radius: float = CITY_RADIUS * 0.4

	for i: int in spire_count:
		var spire_mesh := CylinderMesh.new()
		spire_mesh.top_radius = CITY_RADIUS * 0.12
		spire_mesh.bottom_radius = CITY_RADIUS * 0.3
		spire_mesh.height = spire_height
		spire_mesh.radial_segments = 6
		var spire: MeshInstance3D = _make_city_part(spire_mesh, color)
		# 複数本あるときは土台の中心周りに均等配置する（決定的、乱数不使用）。
		var angle: float = TAU * float(i) / float(spire_count)
		var offset: Vector2 = Vector2.ZERO if spire_count == 1 \
			else Vector2(cos(angle), sin(angle)) * cluster_radius
		spire.position = Vector3(offset.x, base_height + spire_height * 0.5, offset.y)
		parts.append(spire)

	return parts


## パーツ1つぶんの MeshInstance3D を作る。マテリアルは自己発光つき
## （暗い地形の中でも都市が目立つように。グロウで街明かりのように滲む）。
func _make_city_part(mesh: Mesh, color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.6
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.35
	mesh.surface_set_material(0, material)

	var part := MeshInstance3D.new()
	part.mesh = mesh
	return part


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
	# 斜め上から当てて起伏に陰影を付ける。
	light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	light.light_energy = 1.1
	# シーンが小さい（都市10×パーツ数個＋地形1枚）ため負荷は軽いはずだが、
	# シャドウアクネ等が出ないかは実機のGUIでしか判断できない（要確認）。
	light.shadow_enabled = true
	add_child(light)


## 現在地を示す。都市の色を状態に合わせて塗り替える（構造物の全パーツぶん）。
func set_current_city(city_id: String) -> void:
	for id: String in _cities:
		var container: Node3D = _cities[id]
		if not is_instance_valid(container):
			continue
		var color: Color = UiTheme.FOCUS if id == city_id else _city_color(id)
		for part: Node in container.get_children():
			var mesh_part: MeshInstance3D = part as MeshInstance3D
			if mesh_part == null or mesh_part.mesh == null:
				continue
			var material: StandardMaterial3D = mesh_part.mesh.surface_get_material(0)
			if material == null:
				continue
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
