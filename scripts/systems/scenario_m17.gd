extends SceneTree
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
const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")

var _failures: int = 0


func _init() -> void:
	_test_world_geometry()
	_test_terrain()
	_test_selection_ring()
	_test_camera_limits()
	await _test_projection()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_world_geometry() -> void:
	print("--- 3D 空間の配置 ---")
	var world: MapView3D = MapView3D.new()

	_check(world.positions.size() == 6, "6都市の座標がある", str(world.positions.size()))

	# 5都市が水平面で等距離、72度間隔。移動ルールとの対応の担保。
	var ring: Array[String] = GameData.royal_city_ids()
	var angles: Array[float] = []
	var radii: Array[float] = []
	for city_id: String in ring:
		var p: Vector3 = world.positions[city_id]
		var flat := Vector2(p.x, p.z)
		radii.append(flat.length())
		angles.append(flat.angle())

	if radii.size() == 5:
		_check(radii.max() - radii.min() < 0.01, "5都市が等距離",
			"差 %.3f" % (radii.max() - radii.min()))
		_check(is_equal_approx(radii[0], MapView3D.RING_RADIUS), "半径が設定どおり",
			"%.2f / %.2f" % [radii[0], MapView3D.RING_RADIUS])

	if angles.size() == 5:
		var even: bool = true
		for i: int in 5:
			var diff: float = angles[(i + 1) % 5] - angles[i]
			while diff < 0.0:
				diff += TAU
			if absf(diff - TAU / 5.0) > 0.01:
				even = false
		_check(even, "隣り合う都市が72度ずつ離れている", "間隔が不均等")

	# カーレオンは水平面の中央。
	var c: Vector3 = world.positions[GameData.CAERLEON]
	_check(Vector2(c.x, c.z).length() < 0.01, "カーレオンは中央",
		"中心から %.3f" % Vector2(c.x, c.z).length())

	# 都市は地面の上に乗っている（高さが地形と一致する）。
	for city_id: String in world.positions:
		var p: Vector3 = world.positions[city_id]
		var ground_y: float = world.height_at(p.x, p.z)
		_check(is_equal_approx(p.y, ground_y), "%s が地面に乗っている" % city_id,
			"%.2f / 地面 %.2f" % [p.y, ground_y])

	# カーレオンは盆地の底。周囲より低い。
	var caerleon_y: float = world.positions[GameData.CAERLEON].y
	var ring_average: float = 0.0
	for city_id: String in ring:
		ring_average += world.positions[city_id].y
	ring_average /= float(ring.size())
	_check(caerleon_y < ring_average, "カーレオンは周囲より低い（盆地の底）",
		"%.2f vs 平均 %.2f" % [caerleon_y, ring_average])

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
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		_check(normals.size() == vertices.size(), "全頂点に法線がある",
			"%d / %d" % [normals.size(), vertices.size()])
		var upward: int = 0
		for n: Vector3 in normals:
			if n.y > 0.5:
				upward += 1
		_check(upward == normals.size(), "法線が上を向いている（地面が表向き）",
			"上向き %d / %d" % [upward, normals.size()])

	# 経路と光源。
	_check(world.get_node_or_null("Routes") != null, "経路のメッシュがある", "ない")
	_check(world.get_node_or_null("Sun") != null, "光源がある", "ない")

	# 都市の柱が6本。
	var pillars: int = 0
	for city_id: String in GameData.CITIES:
		if world.get_node_or_null(city_id) != null:
			pillars += 1
	_check(pillars == 6, "6都市の柱がある", str(pillars))

	world.free()


func _test_selection_ring() -> void:
	print("--- 現在地のリング ---")
	var world: MapView3D = MapView3D.new()

	var ring: MeshInstance3D = world.get_node_or_null("SelectionRing")
	_check(ring != null, "リングのメッシュがある", "ない")
	if ring == null:
		world.free()
		return

	world.set_current_city("martlock")
	var mesh: ImmediateMesh = ring.mesh
	_check(mesh.get_surface_count() > 0, "リングが描かれている", "空")
	if mesh.get_surface_count() == 0:
		world.free()
		return

	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# 二重の円。各円が RING_SEGMENTS 本の線分＝2頂点ずつ。
	var expected: int = MapView3D.RING_SEGMENTS * 2 * 2
	_check(vertices.size() == expected, "二重の円ぶんの頂点がある",
		"%d / 期待 %d" % [vertices.size(), expected])

	# 現在地を囲んでいる。中心からの距離が内外の半径に一致する。
	var center: Vector3 = world.positions["martlock"]
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
	var other: Vector3 = world.positions["lymhurst"]
	if absf(world.height_at(other.x, other.z) - world.height_at(center.x, center.z)) > 0.01:
		_check(not is_equal_approx(world.ring_height(other), want_y),
			"都市ごとに輪の高さが変わる", "同じ高さ")

	# 移動すると追従する。
	world.set_current_city("bridgewatch")
	var moved: PackedVector3Array = ring.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var new_center: Vector3 = world.positions["bridgewatch"]
	var around_new: bool = true
	for v: Vector3 in moved:
		var flat: float = Vector2(v.x - new_center.x, v.z - new_center.z).length()
		if flat > MapView3D.RING_OUTER_RADIUS + 0.01:
			around_new = false
	_check(around_new, "移動先の都市を囲む", "元の位置に残っている")

	# 脈動。到着直後は 1.0 から始まり、時間とともに上下する。
	world.set_current_city("martlock")
	_check(is_equal_approx(world.pulse_scale(), 1.0), "到着直後の倍率は1.0",
		"%.3f" % world.pulse_scale())

	# 周期の 1/4 で最大、3/4 で最小になる。
	world._pulse_time = MapView3D.RING_PULSE_PERIOD * 0.25
	var peak: float = world.pulse_scale()
	world._pulse_time = MapView3D.RING_PULSE_PERIOD * 0.75
	var trough: float = world.pulse_scale()
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
	world._pulse_time = MapView3D.RING_PULSE_PERIOD
	_check(is_equal_approx(world.pulse_scale(), 1.0), "一周で元に戻る",
		"%.3f" % world.pulse_scale())

	# 脈動しても半径の比は保たれる（内外が入れ替わらない）。
	world._pulse_time = MapView3D.RING_PULSE_PERIOD * 0.25
	world._redraw_selection_ring(world.positions["martlock"])
	var pulsed: PackedVector3Array = ring.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var center2: Vector3 = world.positions["martlock"]
	var largest: float = 0.0
	var smallest: float = 9999.0
	for v: Vector3 in pulsed:
		var flat: float = Vector2(v.x - center2.x, v.z - center2.z).length()
		largest = maxf(largest, flat)
		smallest = minf(smallest, flat)
	_check(largest > smallest, "脈動中も二重の円のまま",
		"内 %.2f / 外 %.2f" % [smallest, largest])

	# 未知の都市を指定しても落ちず、リングを隠す。
	world.set_current_city("nonexistent")
	_check(not ring.visible, "未知の都市ではリングを隠す", "出たまま")
	_check(world._ring_city == "", "脈動の対象も外れる", world._ring_city)

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
	panel._layout_nodes()
	await process_frame

	_check(panel._viewport != null, "SubViewport がある", "ない")
	if panel._viewport != null:
		_check(panel._viewport.own_world_3d,
			"独自の 3D 世界を持つ（本編の 2D を映さない）", "共有している")

	_check(panel._camera != null, "カメラがある", "ない")
	_check(panel._world != null, "3D の世界がある", "ない")

	# 都市が投影先に置かれ、重なっていない。
	var seen: Array[Vector2] = []
	var distinct: bool = true
	for city_id: String in panel._world.positions:
		var pos: Vector2 = panel.screen_position_for(city_id)
		for previous: Vector2 in seen:
			if pos.distance_to(previous) < 1.0:
				distinct = false
		seen.append(pos)
	_check(distinct, "都市が重ならない", "同じ位置にある")

	# 自分の投影位置をクリックすれば自分が当たる（レイキャストの往復確認）。
	var pick_ok: bool = true
	for city_id: String in panel._world.positions:
		var picked: String = panel.pick_city_at(panel.screen_position_for(city_id))
		if picked != city_id:
			pick_ok = false
	_check(pick_ok, "投影位置をクリックすると同じ都市が当たる", "食い違いがある")

	# カメラを回すと投影位置が追従する。
	var before: Vector2 = panel.screen_position_for("fort_sterling")
	panel._camera.rotate_by(1.0, 0.0)
	panel._update_button_positions()
	var after: Vector2 = panel.screen_position_for("fort_sterling")
	_check(before.distance_to(after) > 1.0, "カメラを回すと投影位置が追従する",
		"%.1f しか動かない" % before.distance_to(after))

	# 拡大でも追従する。
	var zoom_before: Vector2 = panel.screen_position_for("martlock")
	panel._camera.zoom_by(-6.0)
	panel._update_button_positions()
	_check(zoom_before.distance_to(panel.screen_position_for("martlock")) > 1.0,
		"拡大でも投影位置が追従する", "動かない")

	# 移動しても操作は従来どおり効く（レイキャストへ移行した設計の担保）。
	session.move_to("bridgewatch")
	_check(not panel.is_selectable("bridgewatch"), "現在地は選択できない", "選択できる")
	_check(panel.tooltip_text_for("bridgewatch").contains("現在地"),
		"現在地がツールチップに出る", panel.tooltip_text_for("bridgewatch"))

	_despawn(panel)


# --- ヘルパ ---

func _spawn(path: String) -> Node:
	var scene: PackedScene = load(path)
	if scene == null:
		_check(false, "%s が読み込める" % path, "失敗")
		return null
	var node: Node = scene.instantiate()
	root.add_child(node)
	return node


func _despawn(node: Node) -> void:
	root.remove_child(node)
	node.free()


func _check(condition: bool, description: String, actual: String) -> void:
	if condition:
		print("  OK   %s" % description)
	else:
		_failures += 1
		print("  FAIL %s（実際: %s）" % [description, actual])
