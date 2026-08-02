extends Node3D
## 大陸図の 3D 表示。地形・都市・経路を組み立てる。
##
## 都市の配置は 2D 版と同じ規則（環状5都市＋中央カーレオン、72度間隔）を
## そのまま 3D 空間に写す。移動ルールと地図の対応を崩さないため。
##
## クリック判定は 3D では行わない。map_panel が unproject_position() で
## 画面座標へ変換し、既存の Button を重ねる。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## 環状の半径（3D 空間の単位）。
const RING_RADIUS: float = 9.0
## 地形の一辺。都市が乗る範囲より広く取る。
const TERRAIN_SIZE: float = 34.0
## 地形の分割数。多いほど滑らかだが重い。
const TERRAIN_SUBDIVISIONS: int = 48

## 起伏の高さ。
const TERRAIN_HEIGHT: float = 2.4
## ノイズの細かさ。
const TERRAIN_NOISE_SCALE: float = 0.10
## 中央を掘り下げる深さ。カーレオンが盆地の底に見えるようにする。
const BASIN_DEPTH: float = 2.2
## 盆地の広がり。
const BASIN_RADIUS: float = 11.0

## 都市の柱の高さと太さ。
const CITY_HEIGHT: float = 1.5
const CITY_RADIUS: float = 0.55

## 現在地を囲むリング。内外の二重で描く。
const RING_INNER_RADIUS: float = 1.5
const RING_OUTER_RADIUS: float = 2.1
## 円の分割数。少ないと多角形に見える。
const RING_SEGMENTS: int = 48
## 地面から浮かせる高さ。埋まらない程度に。
const RING_LIFT: float = 0.08

var _terrain: MeshInstance3D
var _cities: Dictionary = {}
var _routes: MeshInstance3D
var _selection_ring: MeshInstance3D
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

	_compute_positions()
	_build_terrain()
	_build_cities()
	_build_routes()
	_build_selection_ring()
	_build_light()


## 都市の 3D 座標。2D 版と同じ規則で並べる。
## 環状位置 0 を奥（-Z）にして時計回り。カーレオンは中央。
func _compute_positions() -> void:
	var ring: Array[String] = GameData.royal_city_ids()
	for index: int in ring.size():
		var angle: float = -PI / 2.0 + TAU * float(index) / float(ring.size())
		var x: float = cos(angle) * RING_RADIUS
		var z: float = sin(angle) * RING_RADIUS
		positions[ring[index]] = Vector3(x, height_at(x, z), z)

	positions[GameData.CAERLEON] = Vector3(0.0, height_at(0.0, 0.0), 0.0)


## その地点の地面の高さ。都市も経路もこれに沿わせる。
func height_at(x: float, z: float) -> float:
	var h: float = _noise.get_noise_2d(x, z) * TERRAIN_HEIGHT
	# 中央を掘り下げる。カーレオンが盆地の底になり、
	# 外周の王国都市がそれを囲む地形として読める。
	var distance: float = Vector2(x, z).length()
	var basin: float = clampf(1.0 - distance / BASIN_RADIUS, 0.0, 1.0)
	return h - basin * basin * BASIN_DEPTH


func _build_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(TERRAIN_SIZE, TERRAIN_SIZE)
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
func _build_routes() -> void:
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)

	var ring: Array[String] = GameData.royal_city_ids()
	for i: int in ring.size():
		_add_route(mesh, positions[ring[i]],
			positions[ring[(i + 1) % ring.size()]],
			Color(0.45, 0.42, 0.36), false)

	var center: Vector3 = positions[GameData.CAERLEON]
	for city_id: String in ring:
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


## リングをその都市の足元に描き直す。
##
## 平らな円を作って位置だけ動かすのでは駄目で、都市ごとに地面の高さが
## 違うため斜面に埋まったり浮いたりする。円周上の各点で地形の高さを
## 引き直し、地面に寝かせる。
func _redraw_selection_ring(center: Vector3) -> void:
	if not is_instance_valid(_selection_ring):
		return
	var mesh: ImmediateMesh = _selection_ring.mesh
	mesh.clear_surfaces()

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	_add_ring(mesh, center, RING_INNER_RADIUS, UiTheme.FOCUS)
	_add_ring(mesh, center, RING_OUTER_RADIUS, UiTheme.FOCUS)
	mesh.surface_end()


## 地形に沿った円を1本引く。
func _add_ring(mesh: ImmediateMesh, center: Vector3, radius: float,
		color: Color) -> void:
	for i: int in RING_SEGMENTS:
		var a0: float = TAU * float(i) / float(RING_SEGMENTS)
		var a1: float = TAU * float(i + 1) / float(RING_SEGMENTS)
		var p0 := Vector3(center.x + cos(a0) * radius, 0.0,
			center.z + sin(a0) * radius)
		var p1 := Vector3(center.x + cos(a1) * radius, 0.0,
			center.z + sin(a1) * radius)
		p0.y = height_at(p0.x, p0.z) + RING_LIFT
		p1.y = height_at(p1.x, p1.z) + RING_LIFT
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(p0)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(p1)


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
		_redraw_selection_ring(positions[city_id])
		if is_instance_valid(_selection_ring):
			_selection_ring.visible = true
	elif is_instance_valid(_selection_ring):
		_selection_ring.visible = false
