extends "res://scripts/systems/scenario_base.gd"
## 大陸図の 3D 表示の検証。地形・都市・カメラ・投影。
##
## 3D の描画結果そのものはヘッドレスで確認できない。ここで見るのは
## 座標計算とノード構成、そしてカメラ操作の上下限。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m17.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")



func _init() -> void:
	_test_world_geometry()
	_test_terrain()
	_test_selection_ring()
	_test_camera_limits()
	await _test_projection()
	_test_glow()
	_test_city_structure()
	_finish()


func _test_world_geometry() -> void:
	print("--- 3D 空間の配置（不規則グラフのばね緩和） ---")
	var world: MapView3D = MapView3D.new()

	_check(world.positions.size() == GameData.CITIES.size(), "全都市の座標がある", str(world.positions.size()))

	# 不規則グラフなので環のような厳密な等距離・等角度は前提にしない。
	# ばね緩和が「重ならない」「王道の間隔がおおむね妥当」「中心からの緩い
	# 求心力が効いている」ことだけを見る。
	var ring: Array[String] = GameData.royal_city_ids()
	var radii: Array[float] = []
	for city_id: String in ring:
		var p: Vector3 = world.positions[city_id]
		radii.append(Vector2(p.x, p.z).length())

	var min_radius: float = radii.min()
	var max_radius: float = radii.max()
	_check(min_radius > 1.0, "半径がゼロでない", str(min_radius))
	# oakhaven/wyndham は次数1の行き止まり都市で、わざと他より外側に来る
	# 設計（scenario_m11.gd の同名検査のコメント参照）。閾値は緩めに取り、
	# 0で急に増える暴走だけを検出する。
	_check(max_radius < min_radius * 6.0, "都市間で半径が極端にばらつかない",
		"最小 %.2f / 最大 %.2f" % [min_radius, max_radius])

	var overlap: bool = false
	for a: String in ring:
		for b: String in ring:
			if a == b:
				continue
			var pa: Vector2 = Vector2(world.positions[a].x, world.positions[a].z)
			var pb: Vector2 = Vector2(world.positions[b].x, world.positions[b].z)
			if pa.distance_to(pb) < 0.5:
				overlap = true
	_check(not overlap, "都市どうしが重ならない", "重なっている都市がある")

	# 王道でつながる都市どうしは、平均するとおおむね CITY_SPACING 前後の
	# 間隔になる（ばね緩和の目標距離）。個々の辺の厳密な一致は求めない。
	var total_edge_dist: float = 0.0
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		total_edge_dist += world.positions[edge[0]].distance_to(world.positions[edge[1]])
	var average_edge_dist: float = total_edge_dist / float(GameData.ROYAL_ROAD_EDGES.size())
	_check(average_edge_dist > MapView3D.CITY_SPACING * 0.5 and average_edge_dist < MapView3D.CITY_SPACING * 2.0,
		"王道でつながる都市どうしの平均間隔がおおむね妥当",
		"平均 %.2f（目標 %.2f）" % [average_edge_dist, MapView3D.CITY_SPACING])

	# 中心都市は水平面の中央。
	var c: Vector3 = world.positions[GameData.CAERLEON]
	_check(Vector2(c.x, c.z).length() < 0.01, "中心都市は中央にある",
		"中心から %.3f" % Vector2(c.x, c.z).length())

	# 都市は地面の上に乗っている（高さが地形と一致する）。
	for city_id: String in world.positions:
		var p: Vector3 = world.positions[city_id]
		var ground_y: float = world.height_at(p.x, p.z)
		_check(is_equal_approx(p.y, ground_y), "%s が地面に乗っている" % city_id,
			"%.2f / 地面 %.2f" % [p.y, ground_y])

	# 中心都市は盆地の底。周囲より低い。
	var center_y: float = world.positions[GameData.CAERLEON].y
	var ring_average: float = 0.0
	for city_id: String in ring:
		ring_average += world.positions[city_id].y
	ring_average /= float(ring.size())
	_check(center_y < ring_average, "中心都市は周囲より低い（盆地の底）",
		"%.2f vs 平均 %.2f" % [center_y, ring_average])

	world.free()


func _test_terrain() -> void:
	print("--- 地形 ---")
	var world: MapView3D = MapView3D.new()

	var terrain: MeshInstance3D = world.get_node_or_null("Terrain")
	_check(terrain != null, "地形のメッシュがある", "ない")
	if terrain != null and terrain.mesh != null:
		var arrays: Array = terrain.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		_check(vertices.size() > 0, "頂点がある", str(vertices.size()))

		# 起伏がある（すべて同じ高さではない）。
		var lowest: float = 9999.0
		var highest: float = -9999.0
		for v: Vector3 in vertices:
			lowest = minf(lowest, v.y)
			highest = maxf(highest, v.y)
		_check(highest - lowest > 0.5, "地形に起伏がある",
			"高低差 %.2f" % (highest - lowest))
		print("     頂点 %d / 高低差 %.2f" % [vertices.size(), highest - lowest])

		# 法線が上を向いていること。下向きだと地面が裏返り、光が
		# 当たらず真っ黒に描画される（実際にそうなった）。
		#
		# 「裏返っていない」ことと「傾斜が急すぎない」ことは別の性質なので
		# 分けて見る。以前は n.y > 0.5（＝60度以上の斜面を1枚でも許さない）
		# ひとつで両方を兼ねていたが、これは地形の形の選択にまで踏み込んだ
		# 条件で、稜線を立てた途端に落ちる。裏返りの検出だけなら符号で足り、
		# 急峻さは別途あとの検査が上限で歯止めをかける。
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		_check(normals.size() == vertices.size(), "全頂点に法線がある",
			"%d / %d" % [normals.size(), vertices.size()])
		var upward: int = 0
		for n: Vector3 in normals:
			if n.y > 0.0:
				upward += 1
		_check(upward == normals.size(), "法線が上を向いている（地面が表向き）",
			"上向き %d / %d" % [upward, normals.size()])

		# 急斜面（60度超）はあってよいが、地形の大半がそうなっていたら
		# 起伏を付けすぎている（都市や道が斜面に乗って読めなくなる）。
		# 割合の上限で歯止めをかける。
		var steep: int = 0
		for n: Vector3 in normals:
			if n.y <= 0.5:
				steep += 1
		var steep_ratio: float = float(steep) / float(normals.size())
		_check(steep_ratio < 0.05, "急斜面が地形のごく一部にとどまる",
			"60度超が %.1f%%" % (steep_ratio * 100.0))

	# 経路と光源。
	_check(world.get_node_or_null("Routes") != null, "経路のメッシュがある", "ない")
	_check(world.get_node_or_null("Sun") != null, "光源がある", "ない")

	# 都市の柱が全都市ぶんある。
	var pillars: int = 0
	for city_id: String in GameData.CITIES:
		if world.get_node_or_null(city_id) != null:
			pillars += 1
	_check(pillars == GameData.CITIES.size(), "全都市の柱がある", str(pillars))

	world.free()


func _test_selection_ring() -> void:
	print("--- 現在地のリング ---")
	var world: MapView3D = MapView3D.new()

	var ring: MeshInstance3D = world.get_node_or_null("SelectionRing")
	_check(ring != null, "リングのメッシュがある", "ない")
	if ring == null:
		world.free()
		return

	var home: String = GameData.INITIAL_CITY
	var neighbor: String = _adjacent_royal_city(home)

	world.set_current_city(home)
	var mesh: ImmediateMesh = ring.mesh
	_check(mesh.get_surface_count() > 0, "リングが描かれている", "空")
	if mesh.get_surface_count() == 0:
		world.free()
		return

	# 発光していないと都市の柱と違ってグロウが乗らず、地図上で浮いて見える
	# （かつて unshaded だが emission は付いておらず、実際には光っていなかった）。
	var ring_material: StandardMaterial3D = mesh.surface_get_material(0)
	_check(ring_material != null and ring_material.emission_enabled,
		"リングが発光している", "発光していない")
	if ring_material != null:
		var ring_luminance: float = 0.2126 * ring_material.emission.r \
			+ 0.7152 * ring_material.emission.g + 0.0722 * ring_material.emission.b
		_check(ring_luminance * ring_material.emission_energy_multiplier > MapView3D.GLOW_HDR_THRESHOLD,
			"リングの発光がHDR閾値を超える",
			"%.2f <= 閾値%.2f" % [ring_luminance * ring_material.emission_energy_multiplier, MapView3D.GLOW_HDR_THRESHOLD])

	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# 二重の円。各円が RING_SEGMENTS 本の線分＝2頂点ずつ。
	var expected: int = MapView3D.RING_SEGMENTS * 2 * 2
	_check(vertices.size() == expected, "二重の円ぶんの頂点がある",
		"%d / 期待 %d" % [vertices.size(), expected])

	# 現在地を囲んでいる。中心からの距離が内外の半径に一致する。
	var center: Vector3 = world.positions[home]
	var near_inner: int = 0
	var near_outer: int = 0
	for v: Vector3 in vertices:
		var flat: float = Vector2(v.x - center.x, v.z - center.z).length()
		if absf(flat - MapView3D.RING_INNER_RADIUS) < 0.01:
			near_inner += 1
		elif absf(flat - MapView3D.RING_OUTER_RADIUS) < 0.01:
			near_outer += 1
	_check(near_inner > 0 and near_outer > 0, "内側と外側の円がある",
		"内 %d / 外 %d" % [near_inner, near_outer])
	_check(near_inner + near_outer == vertices.size(),
		"全頂点が現在地を囲んでいる",
		"%d / %d" % [near_inner + near_outer, vertices.size()])

	# 平らな輪。全頂点が同じ高さに並ぶ。
	var lowest: float = 9999.0
	var highest: float = -9999.0
	for v: Vector3 in vertices:
		lowest = minf(lowest, v.y)
		highest = maxf(highest, v.y)
	_check(highest - lowest < 0.001, "輪が水平",
		"高低差 %.4f" % (highest - lowest))

	# 都市の柱より上にある。埋まると架かって見えない。
	_check(lowest > center.y + MapView3D.CITY_HEIGHT, "柱より上に架かる",
		"輪 %.2f / 柱の先 %.2f" % [lowest, center.y + MapView3D.CITY_HEIGHT])

	# 高さは足元を基準にする。高地の都市では輪もそのぶん高い。
	var want_y: float = world.ring_height(center)
	_check(absf(lowest - want_y) < 0.001, "足元からの高さで架かる",
		"%.3f / 期待 %.3f" % [lowest, want_y])

	# 地形が違えば輪の高さも違う。
	var far_city: String = _far_royal_city(home)
	var other: Vector3 = world.positions[far_city]
	if absf(world.height_at(other.x, other.z) - world.height_at(center.x, center.z)) > 0.01:
		_check(not is_equal_approx(world.ring_height(other), want_y),
			"都市ごとに輪の高さが変わる", "同じ高さ")

	# 移動すると追従する。
	world.set_current_city(neighbor)
	var moved: PackedVector3Array = ring.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var new_center: Vector3 = world.positions[neighbor]
	var around_new: bool = true
	for v: Vector3 in moved:
		var flat: float = Vector2(v.x - new_center.x, v.z - new_center.z).length()
		if flat > MapView3D.RING_OUTER_RADIUS + 0.01:
			around_new = false
	_check(around_new, "移動先の都市を囲む", "元の位置に残っている")

	# 脈動。到着直後は 1.0 から始まり、時間とともに上下する。
	world.set_current_city(home)
	_check(is_equal_approx(world.pulse_scale(), 1.0), "到着直後の倍率は1.0",
		"%.3f" % world.pulse_scale())

	# 周期の 1/4 で最大、3/4 で最小になる。
	# pulse_scale_at() は内部状態を持たない純関数なので、位相を渡すだけで
	# 任意の瞬間を確かめられる（以前は _pulse_time を直接書き換えていた）。
	var peak: float = MapView3D.pulse_scale_at(MapView3D.RING_PULSE_PERIOD * 0.25)
	var trough: float = MapView3D.pulse_scale_at(MapView3D.RING_PULSE_PERIOD * 0.75)
	_check(peak > 1.0 and trough < 1.0, "1.0 を挟んで上下する",
		"最大 %.3f / 最小 %.3f" % [peak, trough])

	# 控えめであること。大きく動くと地図を見ている間ずっと気が散る。
	_check(absf(peak - 1.0) <= MapView3D.RING_PULSE_AMOUNT + 0.001,
		"変化幅が設定を超えない", "%.3f" % absf(peak - 1.0))
	_check(MapView3D.RING_PULSE_AMOUNT <= 0.15, "脈動が控えめ",
		"振幅 %.2f" % MapView3D.RING_PULSE_AMOUNT)
	_check(MapView3D.RING_PULSE_PERIOD >= 1.5, "周期が速すぎない",
		"%.1f 秒" % MapView3D.RING_PULSE_PERIOD)

	# 一周すると元に戻る。
	var full_cycle: float = MapView3D.pulse_scale_at(MapView3D.RING_PULSE_PERIOD)
	_check(is_equal_approx(full_cycle, 1.0), "一周で元に戻る", "%.3f" % full_cycle)

	# 脈動しても半径の比は保たれる（内外が入れ替わらない）。
	world.redraw_selection_ring_at(MapView3D.RING_PULSE_PERIOD * 0.25)
	var pulsed: PackedVector3Array = ring.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var center2: Vector3 = world.positions[home]
	var largest: float = 0.0
	var smallest: float = 9999.0
	for v: Vector3 in pulsed:
		var flat: float = Vector2(v.x - center2.x, v.z - center2.z).length()
		largest = maxf(largest, flat)
		smallest = minf(smallest, flat)
	_check(largest > smallest, "脈動中も二重の円のまま",
		"内 %.2f / 外 %.2f" % [smallest, largest])

	# _process を通しても実際に脈動する。
	#
	# 上の検査は純関数と明示的な引き直しを見ているだけなので、_process から
	# リングへ倍率が渡らなくなっても素通りする（脈動が止まっても気づけない）。
	# 実際の経路を1度は通しておく。
	world.set_current_city(home)
	var outer_radius := func() -> float:
		var verts: PackedVector3Array = ring.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var center3: Vector3 = world.positions[home]
		var found: float = 0.0
		for v: Vector3 in verts:
			found = maxf(found, Vector2(v.x - center3.x, v.z - center3.z).length())
		return found

	var at_start: float = outer_radius.call()
	world._process(MapView3D.RING_PULSE_PERIOD * 0.25)
	var at_peak: float = outer_radius.call()
	world._process(MapView3D.RING_PULSE_PERIOD * 0.5)
	var at_trough: float = outer_radius.call()
	_check(at_peak > at_start and at_trough < at_peak,
		"_process を通すと実際に半径が上下する",
		"開始 %.3f / 最大 %.3f / 最小 %.3f" % [at_start, at_peak, at_trough])

	# 未知の都市を指定しても落ちず、リングを隠す。
	world.set_current_city("nonexistent")
	_check(not ring.visible, "未知の都市ではリングを隠す", "出たまま")
	_check(world.ring_city() == "", "脈動の対象も外れる", world.ring_city())

	world.free()


func _test_camera_limits() -> void:
	print("--- カメラの上下限 ---")
	var camera: MapCamera = MapCamera.new()

	# 仰角は制限される。真上・真横まで行くと位置関係が読めなくなる。
	camera.rotate_by(0.0, 99.0)
	_check(camera.pitch <= MapCamera.MAX_PITCH, "仰角が上限を超えない",
		"%.2f / 上限 %.2f" % [camera.pitch, MapCamera.MAX_PITCH])
	camera.rotate_by(0.0, -99.0)
	_check(camera.pitch >= MapCamera.MIN_PITCH, "仰角が下限を下回らない",
		"%.2f / 下限 %.2f" % [camera.pitch, MapCamera.MIN_PITCH])

	# 距離も制限される。
	camera.zoom_by(-99.0)
	_check(camera.distance >= MapCamera.MIN_DISTANCE, "近づきすぎない",
		"%.1f / 下限 %.1f" % [camera.distance, MapCamera.MIN_DISTANCE])
	camera.zoom_by(999.0)
	_check(camera.distance <= MapCamera.MAX_DISTANCE, "離れすぎない",
		"%.1f / 上限 %.1f" % [camera.distance, MapCamera.MAX_DISTANCE])

	# 方位角は一周できる（制限しない）。
	var before: float = camera.yaw
	camera.rotate_by(TAU, 0.0)
	_check(not is_equal_approx(camera.yaw, before), "方位角は回せる", "変わらない")

	# 注視点を都市へ移せる。ツリー外なので即座に着く。
	var target := Vector3(6.0, 0.5, -3.0)
	camera.focus_on(target)
	_check(is_equal_approx(camera.focus.x, target.x)
		and is_equal_approx(camera.focus.z, target.z),
		"注視点が都市へ移る",
		"(%.1f, %.1f)" % [camera.focus.x, camera.focus.z])
	_check(camera.is_settled(), "移動後は落ち着いている", "追従中のまま")

	# 見下ろす量は保つ。都市の足元を見ると地平が上に寄る。
	_check(camera.focus.y < target.y, "足元より下を見る",
		"%.2f / 足元 %.2f" % [camera.focus.y, target.y])

	# カメラはその都市を向く。位置と向きの両方が移る。
	var to_focus: Vector3 = (camera.focus - camera.transform.origin).normalized()
	var facing: Vector3 = -camera.transform.basis.z
	_check(to_focus.dot(facing) > 0.99, "移した先を向く",
		"内積 %.3f" % to_focus.dot(facing))

	# 距離は保たれる。中心が移っても寄り引きは変わらない。
	var eye_gap: float = camera.transform.origin.distance_to(camera.focus)
	_check(absf(eye_gap - camera.distance) < 0.01, "中心からの距離を保つ",
		"%.2f / 設定 %.2f" % [eye_gap, camera.distance])

	# 別の都市へ移すと追いかける。
	camera.focus_on(Vector3(-8.0, 0.0, 4.0))
	_check(is_equal_approx(camera.focus.x, -8.0), "移動先へ追従する",
		"%.1f" % camera.focus.x)

	# 視点を戻しても中心は現在地のまま。角度と距離だけ戻る。
	var held: Vector3 = camera.focus
	camera.reset_view()
	_check(camera.focus.is_equal_approx(held), "視点を戻しても中心は残る",
		"(%.1f, %.1f)" % [camera.focus.x, camera.focus.z])

	# 初期状態に戻せる。
	camera.reset_view()
	_check(is_equal_approx(camera.pitch, MapCamera.DEFAULT_PITCH), "視点を戻せる",
		str(camera.pitch))

	# カメラが中心の方を向いている。
	# global_transform はツリー外では更新されないため transform を見る。
	camera.reset_view()
	var forward: Vector3 = -camera.transform.basis.z
	# 中心は現在地に移っているので、定数ではなく今の注視点と比べる。
	var to_center: Vector3 = (camera.focus - camera.position).normalized()
	_check(forward.dot(to_center) > 0.95, "カメラが中心を向いている",
		"内積 %.2f" % forward.dot(to_center))

	# 中心より高い位置から見下ろしている。
	_check(camera.position.y > camera.focus.y, "見下ろす高さにある",
		"y=%.1f" % camera.position.y)

	camera.free()


func _test_projection() -> void:
	print("--- 3D から画面への投影 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(17001)
	panel.bind(session)

	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_despawn(panel)
		return
	area.size = Vector2(420, 340)
	panel.layout_nodes()
	await process_frame

	_check(panel.viewport() != null, "SubViewport がある", "ない")
	if panel.viewport() != null:
		_check(panel.viewport().own_world_3d,
			"独自の 3D 世界を持つ（本編の 2D を映さない）", "共有している")

	_check(panel.camera() != null, "カメラがある", "ない")
	_check(panel.world() != null, "3D の世界がある", "ない")

	# 都市が投影先に置かれ、重なっていない。
	var seen: Array[Vector2] = []
	var distinct: bool = true
	for city_id: String in panel.world().positions:
		var pos: Vector2 = panel.screen_position_for(city_id)
		for previous: Vector2 in seen:
			if pos.distance_to(previous) < 1.0:
				distinct = false
		seen.append(pos)
	_check(distinct, "都市が重ならない", "同じ位置にある")

	# 自分の投影位置をクリックすれば自分が当たる（レイキャストの往復確認）。
	var pick_ok: bool = true
	for city_id: String in panel.world().positions:
		var picked: String = panel.pick_city_at(panel.screen_position_for(city_id))
		if picked != city_id:
			pick_ok = false
	_check(pick_ok, "投影位置をクリックすると同じ都市が当たる", "食い違いがある")

	# カメラを回すと投影位置が追従する。
	var any_city: String = GameData.royal_city_ids()[0]
	var before: Vector2 = panel.screen_position_for(any_city)
	panel.camera().rotate_by(1.0, 0.0)
	panel.update_node_positions()
	var after: Vector2 = panel.screen_position_for(any_city)
	_check(before.distance_to(after) > 1.0, "カメラを回すと投影位置が追従する",
		"%.1f しか動かない" % before.distance_to(after))

	# 拡大でも追従する。
	var home: String = GameData.INITIAL_CITY
	var zoom_before: Vector2 = panel.screen_position_for(home)
	panel.camera().zoom_by(-6.0)
	panel.update_node_positions()
	_check(zoom_before.distance_to(panel.screen_position_for(home)) > 1.0,
		"拡大でも投影位置が追従する", "動かない")

	# カメラの背後にある都市のラベルは隠れる。
	#
	# unproject_position() は背後の点も前方へ折り返した座標を返すため、
	# 弾かないと地図の裏側の都市が画面上に紛れ込む。近づいて見下ろすと
	# 遠い都市が背後へ回るので、その状態で検査する。
	panel.camera().zoom_by(-MapCamera.MAX_DISTANCE)
	panel.update_node_positions()
	var behind: Array[String] = []
	for city_id: String in panel.world().positions:
		if panel.is_behind_camera(city_id):
			behind.append(city_id)
	_check(not behind.is_empty(),
		"最接近すると背後に回る都市がある（検査の前提）", "1つも背後に無い")

	var hidden_ok: bool = true
	var shown_ok: bool = true
	for city_id: String in panel.world().positions:
		var node: Control = panel.node_for(city_id)
		if node == null:
			continue
		if panel.is_behind_camera(city_id):
			if node.visible:
				hidden_ok = false
		elif not node.visible:
			shown_ok = false
	_check(hidden_ok, "背後の都市のラベルは表示されない", "背後なのに出ている")
	_check(shown_ok, "前方の都市のラベルは表示される", "前方なのに消えている")

	# 背後の都市はクリックでも当たらない（レイキャストが t<0 を弾く）。
	var behind_pick_ok: bool = true
	for city_id: String in behind:
		if panel.pick_city_at(panel.screen_position_for(city_id)) == city_id:
			behind_pick_ok = false
	_check(behind_pick_ok, "背後の都市は折り返した座標でも当たらない", "当たってしまう")

	# 引き戻して以降の検査を通常の視点で行う。
	panel.camera().zoom_by(MapCamera.MAX_DISTANCE)
	panel.update_node_positions()

	# 移動しても操作は従来どおり効く（レイキャストへ移行した設計の担保）。
	var neighbor: String = _adjacent_royal_city(session.current_city)
	session.move_to(neighbor)
	_check(not panel.is_selectable(neighbor), "現在地は選択できない", "選択できる")
	_check(panel.tooltip_text_for(neighbor).contains("現在地"),
		"現在地がツールチップに出る", panel.tooltip_text_for(neighbor))

	_despawn(panel)


## 都市の建物が光っていないこと、リングの発光はグローの HDR 閾値を超えること。
##
## **建物は光らせない。** 街並みを1〜2本の尖塔から7〜8軒に増やしたとき、
## 発光体の数が数倍になって白飛びし、屋根の形が読めなくなった（実機で確認）。
## 建物を光らせ直したら、この検査は落ちなければならない。
##
## リング側は「妥当か」を見る（CLAUDE.md参照）: 輝度×発光エネルギーが閾値を
## 上回っていることそのものを確かめる。値だけ揃っていても閾値の方が高ければ
## 無効化されたのと同じになるため、二値の関係を直接見る必要がある。一度、
## 旧値（発光エネルギー0.35）では閾値を超えず、グローが実際には出ていなかった
## 不具合があった（実機で発見）。
func _test_glow() -> void:
	print("--- 都市の発光グロー ---")

	# 建物の実物のマテリアルを見る（色から計算し直すと、実装がどう変わっても
	# 検査だけが素通りする）。現在地の町も含めて確かめるため、現在地を据える。
	var world := MapView3D.new()
	world.set_current_city("ironhollow")
	var lit: int = 0
	var checked: int = 0
	for city_id: String in GameData.CITIES:
		var container: Node3D = world.get_node_or_null(NodePath(city_id))
		if container == null:
			continue
		for part: Node in container.get_children():
			var mesh_part: MeshInstance3D = part as MeshInstance3D
			if mesh_part == null or mesh_part.mesh == null:
				continue
			var material: StandardMaterial3D = mesh_part.mesh.surface_get_material(0)
			if material == null:
				continue
			checked += 1
			if material.emission_enabled:
				lit += 1
	_check(checked > 0, "都市の建物を検査できた", "パーツが見つからない")
	_check(lit == 0, "都市の建物は光らない", "%d/%d 個が発光している" % [lit, checked])
	world.free()

	# 現在地リングは光る（現在地がひと目で分かる必要がある）。
	var luminance: float = 0.2126 * UiTheme.FOCUS.r + 0.7152 * UiTheme.FOCUS.g \
		+ 0.0722 * UiTheme.FOCUS.b
	var glow_value: float = luminance * MapView3D.CITY_EMISSION_ENERGY
	_check(glow_value > MapView3D.GLOW_HDR_THRESHOLD,
		"リングの発光がHDR閾値を超える",
		"%.2f <= 閾値%.2f" % [glow_value, MapView3D.GLOW_HDR_THRESHOLD])


## 都市の構造（区画・門・高さの予算）。
##
## 門は「街道が伸びる方向」に立っていなければ意味がない（道の無い方角に
## 門があると、そちらへ行けるように見える）。向きを実装から借りずに、
## _flat_positions から期待する方向を組み直して照合する。
func _test_city_structure() -> void:
	print("--- 都市の構造（区画と門） ---")
	var world: MapView3D = MapView3D.new()

	# 高さの予算。区画・建物・門を足しても現在地リングにめり込まないこと。
	# ここが破れると _test_selection_ring() の「柱より上に架かる」も破れる。
	var over: int = 0
	for city_id: String in GameData.CITIES:
		for part: MeshInstance3D in world._city_structure_parts(city_id):
			var mesh: Mesh = part.mesh
			var height: float = 0.0
			if mesh is CylinderMesh:
				height = (mesh as CylinderMesh).height
			elif mesh is BoxMesh:
				height = (mesh as BoxMesh).size.y
			elif mesh is PrismMesh:
				height = (mesh as PrismMesh).size.y
			if part.position.y + height * 0.5 > MapView3D.CITY_HEIGHT + 0.0001:
				over += 1
	_check(over == 0, "構造物が高さの予算に収まる", "%d 個が CITY_HEIGHT を超える" % over)

	# 門の向きが街道と一致する。期待する向きは _flat_positions から作り直す。
	var mismatched: int = 0
	var missing: int = 0
	for city_id: String in GameData.CITIES:
		var origin: Vector2 = world._flat_positions[city_id]
		var wanted: Array[Vector2] = []
		var targets: Array[String] = GameData.road_neighbors(city_id)
		if city_id == GameData.CAERLEON:
			targets.append_array(GameData.BLACK_ZONE_GATES)
		elif GameData.BLACK_ZONE_GATES.has(city_id):
			targets.append(GameData.CAERLEON)
		for target: String in targets:
			wanted.append((world._flat_positions[target] - origin).normalized())

		var actual: Array[Vector2] = world._city_gate_directions(city_id)
		if actual.size() != wanted.size():
			missing += 1
		for want: Vector2 in wanted:
			var found: bool = false
			for got: Vector2 in actual:
				if got.distance_to(want) < 0.001:
					found = true
					break
			if not found:
				mismatched += 1
	_check(missing == 0, "門の数が街道の数と一致する", "%d 都市でずれている" % missing)
	_check(mismatched == 0, "門が街道の向きに立つ", "%d 本の道に門が無い" % mismatched)

	# 区画は接続数に連動し、行き止まりは1区画、交差点は増える。
	_check(MapView3D._city_ward_count("oakhaven") == 1,
		"行き止まりの町は1区画", str(MapView3D._city_ward_count("oakhaven")))
	_check(MapView3D._city_ward_count("ironhollow") > MapView3D._city_ward_count("oakhaven"),
		"交差点の町は区画が多い",
		"%d <= %d" % [MapView3D._city_ward_count("ironhollow"), MapView3D._city_ward_count("oakhaven")])

	# 城壁が門の正面を塞いでいないこと。塞ぐと出入口に見えず、門を
	# 街道の向きに立てた意味が無くなる。
	#
	# **判定の角度に実装の定数（CITY_WALL_GATE_CLEARANCE）を使わない。**
	# 使うと定数を 0 にしたとき実装と検査が同時にずれて素通りする（実際に
	# 一度そうなった）。門柱が実際に占める幅から必要な隙間を出して照合する。
	var gate_half_angle: float = atan2(MapView3D.CITY_GATE_WIDTH * 0.5,
		MapView3D.CITY_RADIUS * MapView3D.CITY_GATE_DISTANCE)
	var blocked: int = 0
	for city_id2: String in GameData.CITIES:
		var directions: Array[Vector2] = world._city_gate_directions(city_id2)
		for wall: MeshInstance3D in world._city_wall_parts(directions, Color.WHITE):
			var at := Vector2(wall.position.x, wall.position.z).normalized()
			for direction: Vector2 in directions:
				if absf(at.angle_to(direction)) < gate_half_angle:
					blocked += 1
	_check(blocked == 0, "城壁が門の正面を塞がない", "%d 枚が門を塞いでいる" % blocked)

	# 装飾が草木の除外半径からはみ出さないこと。はみ出すと木や低木と重なる。
	var outside: int = 0
	for city_id3: String in GameData.CITIES:
		for part2: MeshInstance3D in world._city_structure_parts(city_id3):
			var reach: float = Vector2(part2.position.x, part2.position.z).length()
			if reach > MapView3D.VEGETATION_CITY_CLEARANCE:
				outside += 1
	_check(outside == 0, "装飾が草木の除外半径に収まる", "%d 個がはみ出す" % outside)

	# 小物の数は規模に連動し、指定の範囲に収まる。
	_check(MapView3D._city_prop_count("ironhollow") > MapView3D._city_prop_count("wyndham"),
		"大きな町ほど小物が多い",
		"%d <= %d" % [MapView3D._city_prop_count("ironhollow"), MapView3D._city_prop_count("wyndham")])
	for city_id4: String in GameData.CITIES:
		var props: int = MapView3D._city_prop_count(city_id4)
		_check(props >= MapView3D.CITY_PROP_MIN and props <= MapView3D.CITY_PROP_MAX,
			"%s の小物が範囲内" % city_id4, str(props))

	world.free()
