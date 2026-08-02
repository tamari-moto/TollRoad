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

	# 初期状態に戻せる。
	camera.reset_view()
	_check(is_equal_approx(camera.pitch, MapCamera.DEFAULT_PITCH), "視点を戻せる",
		str(camera.pitch))

	# カメラが中心の方を向いている。
	# global_transform はツリー外では更新されないため transform を見る。
	camera.reset_view()
	var forward: Vector3 = -camera.transform.basis.z
	var to_center: Vector3 = (MapCamera.FOCUS - camera.position).normalized()
	_check(forward.dot(to_center) > 0.95, "カメラが中心を向いている",
		"内積 %.2f" % forward.dot(to_center))

	# 中心より高い位置から見下ろしている。
	_check(camera.position.y > MapCamera.FOCUS.y, "見下ろす高さにある",
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

	# ボタンが投影先に置かれ、重なっていない。
	var seen: Array[Vector2] = []
	var distinct: bool = true
	for city_id: String in panel._buttons:
		var button: Button = panel._buttons[city_id]
		for previous: Vector2 in seen:
			if button.position.distance_to(previous) < 1.0:
				distinct = false
		seen.append(button.position)
	_check(distinct, "都市ボタンが重ならない", "同じ位置にある")

	# カメラを回すとボタンが追従する。
	var before: Vector2 = panel._buttons["fort_sterling"].position
	panel._camera.rotate_by(1.0, 0.0)
	panel._update_button_positions()
	var after: Vector2 = panel._buttons["fort_sterling"].position
	_check(before.distance_to(after) > 1.0, "カメラを回すとボタンが追従する",
		"%.1f しか動かない" % before.distance_to(after))

	# 拡大でも追従する。
	var zoom_before: Vector2 = panel._buttons["martlock"].position
	panel._camera.zoom_by(-6.0)
	panel._update_button_positions()
	_check(zoom_before.distance_to(panel._buttons["martlock"].position) > 1.0,
		"拡大でもボタンが追従する", "動かない")

	# 移動しても操作は従来どおり効く（ボタンを残した設計の担保）。
	session.move_to("bridgewatch")
	var current_button: Button = panel._buttons["bridgewatch"]
	_check(current_button.disabled, "現在地のボタンは無効", "押せる")
	_check(current_button.tooltip_text.contains("現在地"),
		"現在地がツールチップに出る", current_button.tooltip_text)

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
