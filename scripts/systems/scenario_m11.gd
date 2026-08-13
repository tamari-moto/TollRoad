extends "res://scripts/systems/scenario_base.gd"
## 大陸図の地図化の検証。円周配置・経路線・紋章。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m11.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")



func _init() -> void:
	_test_city_crests()
	_test_map_layout()
	_test_route_lines()
	_test_node_contents()
	_finish()


func _test_city_crests() -> void:
	print("--- 都市の紋章 ---")
	for city_id: String in GameData.CITIES:
		var texture: Texture2D = UiIcons.city_texture(city_id)
		_check(texture != null, "%s の紋章がある" % city_id, "null")

	# 品目と都市で名前が衝突しても別のテクスチャを引く。
	_check(UiIcons.city_texture("nonexistent_city") == null, "未定義の都市は null", "null でない")

	# 品目アイコンと都市紋章は別のキャッシュ空間にある。
	var ore_item: Texture2D = UiIcons.item_texture("ore")
	var ore_city: Texture2D = UiIcons.city_texture("ore")
	_check(ore_item != null, "品目の ore は存在する", "null")
	_check(ore_city == null, "都市の ore は存在しない（種別が混ざらない）", "引けてしまった")


func _test_map_layout() -> void:
	print("--- 都市の配置（不規則グラフのばね緩和） ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(11001)
	panel.bind(session)

	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_check(false, "CityList がある", "ない")
		_despawn(panel)
		return

	# 配置は領域サイズに依存するので、明示的に大きさを与えて再配置させる。
	area.size = Vector2(400, 320)
	panel.layout_nodes()

	# 3D になったので、配置は 3D 座標（Vector3）で確認する。
	# 投影後の画面座標はカメラの向き次第で変わるため、幾何の検査には使わない。
	var world: Node = panel.world()
	_check(world != null, "3D の世界がある", "ない")
	if world == null:
		_despawn(panel)
		return

	var ring: Array[String] = GameData.royal_city_ids()
	for city_id: String in ring:
		_check(panel.node_for(city_id) != null, "%s のノードがある" % city_id, "ない")
		_check(world.positions.has(city_id), "%s の3D座標がある" % city_id, "ない")

	# 中心都市は中央（水平面の原点）。
	var center3: Vector3 = world.positions.get(GameData.CAERLEON, Vector3.ZERO)
	_check(Vector2(center3.x, center3.z).length() < 0.01, "中心都市は中央にある",
		"中心から %.3f" % Vector2(center3.x, center3.z).length())

	# 王国都市どうしが同じ座標に重ならない（水平面）。
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

	# 不規則グラフなので環のような厳密な等距離は前提にしない。
	# 半径がゼロでなく、都市間で極端にばらつかないことだけ確認する。
	#
	# oakhaven/wyndham は次数1の行き止まり都市で、わざと他より外側に来る
	# 設計（GameData.ROYAL_ROAD_EDGES のコメント参照）。PENDANT_EDGE_PULL_
	# MULTIPLIER で反発に押し負けすぎないよう引力を強めてあるが、それでも
	# 通常の都市より外側に来ること自体は意図どおりなので閾値は緩めに取る
	# （実測 5.0倍前後。0で急に増える暴走だけを検出できればよい）。
	var radii: Array[float] = []
	for city_id: String in ring:
		radii.append(Vector2(world.positions[city_id].x, world.positions[city_id].z).length())
	var min_radius: float = radii.min()
	var max_radius: float = radii.max()
	_check(min_radius > 1.0, "半径がゼロでない", str(min_radius))
	_check(max_radius < min_radius * 6.0, "都市間で半径が極端にばらつかない",
		"最小 %.2f / 最大 %.2f" % [min_radius, max_radius])

	# 王道でつながる都市どうしは、平均するとおおむね CITY_SPACING 前後の
	# 間隔になる（ばね緩和の目標距離）。個々の辺の厳密な一致は求めない。
	const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
	var total_edge_dist: float = 0.0
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		total_edge_dist += world.positions[edge[0]].distance_to(world.positions[edge[1]])
	var average_edge_dist: float = total_edge_dist / float(GameData.ROYAL_ROAD_EDGES.size())
	_check(average_edge_dist > MapView3D.CITY_SPACING * 0.5 and average_edge_dist < MapView3D.CITY_SPACING * 2.0,
		"王道でつながる都市どうしの平均間隔がおおむね妥当",
		"平均 %.2f（目標 %.2f）" % [average_edge_dist, MapView3D.CITY_SPACING])

	_despawn(panel)


func _test_route_lines() -> void:
	print("--- 経路線 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(11002)
	panel.bind(session)

	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_despawn(panel)
		return
	area.size = Vector2(400, 320)
	panel.layout_nodes()

	# 経路線は 3D の中のメッシュになった。
	var world: Node = panel.world()
	_check(world != null, "3D の世界がある", "ない")
	if world == null:
		_despawn(panel)
		return

	var routes: MeshInstance3D = world.get_node_or_null("Routes")
	_check(routes != null, "経路線のメッシュがある", "ない")
	if routes != null:
		_check(routes.mesh != null, "経路線に中身がある", "空")

	# 地形と光源も揃っている。
	_check(world.get_node_or_null("Terrain") != null, "地形がある", "ない")
	_check(world.get_node_or_null("Sun") != null, "光源がある", "ない")

	# 全都市の座標が 3D 側にある。
	_check(world.positions.size() == GameData.CITIES.size(), "全都市の座標がある", str(world.positions.size()))
	for city_id: String in GameData.CITIES:
		_check(world.positions.has(city_id), "%s の座標がある" % city_id, "ない")

	_despawn(panel)


func _test_node_contents() -> void:
	print("--- ノードの中身 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(11003)
	panel.bind(session)

	var home: String = GameData.INITIAL_CITY
	var neighbor: String = _adjacent_royal_city(home)

	# 現在地（初期都市）のノード。
	var current: Control = panel.node_for(home)
	_check(current != null, "現在地のノードがある", "ない")
	_check(not panel.is_selectable(home), "現在地は選択できない", "選択できる")
	var current_note: String = panel.note_text_for(home)
	_check(current_note != "", "ラベルがある", "ない")
	_check(current_note.contains("現在地"), "現在地と表示される", current_note)
	_check(current_note.contains(GameData.CITIES[home]["name"]), "都市名が出る", current_note)

	# 隣接都市には日数と費用。
	var neighbour_note: String = panel.note_text_for(neighbor)
	_check(neighbour_note.contains("1日"), "隣接は1日と出る", neighbour_note)
	_check(neighbour_note.contains("250"), "隣接は250と出る", neighbour_note)

	# 中心都市には襲撃率。
	var ravenspire_note: String = panel.note_text_for(GameData.CAERLEON)
	_check(ravenspire_note.contains("襲撃22%"), "中心都市に襲撃率が出る", ravenspire_note)

	# 紋章が入っている。
	var crest_count: int = 0
	for city_id: String in panel.city_ids():
		crest_count += panel.crest_count_for(city_id)
	_check(crest_count == GameData.CITIES.size(), "全都市に紋章が入る", str(crest_count))

	# 移動すると現在地の表示が移る。
	session.move_to(neighbor)
	var moved_note: String = panel.note_text_for(neighbor)
	_check(moved_note.contains("現在地"), "移動先が現在地になる", moved_note)
	var old_note: String = panel.note_text_for(home)
	_check(not old_note.contains("現在地"), "元の都市は現在地でなくなる", old_note)

	_despawn(panel)
