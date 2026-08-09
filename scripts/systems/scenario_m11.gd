extends SceneTree
## 大陸図の地図化の検証。円周配置・経路線・紋章。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m11.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

var _failures: int = 0


func _init() -> void:
	_test_city_crests()
	_test_map_layout()
	_test_route_lines()
	_test_node_contents()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


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
	print("--- 円周配置 ---")
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
	panel._layout_nodes()

	# 3D になったので、配置は 3D 座標（Vector3）で確認する。
	# 投影後の画面座標はカメラの向き次第で変わるため、幾何の検査には使わない。
	var world: Node = panel._world
	_check(world != null, "3D の世界がある", "ない")
	if world == null:
		_despawn(panel)
		return

	var ring: Array[String] = GameData.royal_city_ids()
	for city_id: String in ring:
		_check(panel._nodes.has(city_id), "%s のノードがある" % city_id, "ない")
		_check(world.positions.has(city_id), "%s の3D座標がある" % city_id, "ない")

	# 水平面（X-Z）で中心からの距離を測る。高さは地形に沿うので除く。
	var center3: Vector3 = world.positions.get(GameData.CAERLEON, Vector3.ZERO)
	var radii: Array[float] = []
	for city_id: String in ring:
		if not world.positions.has(city_id):
			continue
		var p: Vector3 = world.positions[city_id]
		radii.append(Vector2(p.x, p.z).length())

	if radii.size() == 5:
		var spread: float = radii.max() - radii.min()
		_check(spread < 0.01, "5都市が中心から等距離にある", "半径の差 %.3f" % spread)
		_check(radii[0] > 1.0, "半径がゼロでない", str(radii[0]))

	# カーレオンは中央（水平面の原点）。
	_check(Vector2(center3.x, center3.z).length() < 0.01, "カーレオンは中央にある",
		"中心から %.3f" % Vector2(center3.x, center3.z).length())

	# 環状の隣接どうしは、非隣接より近い。移動ルールとの対応の担保。
	if world.positions.has("fort_sterling") and world.positions.has("lymhurst") \
			and world.positions.has("bridgewatch"):
		var fort3: Vector3 = world.positions["fort_sterling"]
		var lym3: Vector3 = world.positions["lymhurst"]
		var bridge3: Vector3 = world.positions["bridgewatch"]
		var adjacent_dist: float = fort3.distance_to(lym3)
		var far_dist: float = fort3.distance_to(bridge3)
		_check(adjacent_dist < far_dist, "隣接都市は非隣接より近くに置かれる",
			"隣接 %.1f / 非隣接 %.1f" % [adjacent_dist, far_dist])

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
	panel._layout_nodes()

	# 経路線は 3D の中のメッシュになった。
	var world: Node = panel._world
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

	# 全6都市の座標が 3D 側にある。
	_check(world.positions.size() == 6, "6都市の座標がある", str(world.positions.size()))
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

	# 現在地（マートロック）のノード。
	var current: Control = panel._nodes.get("martlock")
	_check(current != null, "現在地のノードがある", "ない")
	if current != null:
		_check(not panel.is_selectable("martlock"), "現在地は選択できない", "選択できる")
		var note: Label = current.find_child("Note", true, false)
		_check(note != null, "ラベルがある", "ない")
		if note != null:
			_check(note.text.contains("現在地"), "現在地と表示される", note.text)
			_check(note.text.contains("マートロック"), "都市名が出る", note.text)

	# 隣接都市には日数と費用。
	var neighbour: Control = panel._nodes.get("bridgewatch")
	if neighbour != null:
		var note: Label = neighbour.find_child("Note", true, false)
		if note != null:
			_check(note.text.contains("1日"), "隣接は1日と出る", note.text)
			_check(note.text.contains("250"), "隣接は250と出る", note.text)

	# カーレオンには襲撃率。
	var caerleon: Control = panel._nodes.get(GameData.CAERLEON)
	if caerleon != null:
		var note: Label = caerleon.find_child("Note", true, false)
		if note != null:
			_check(note.text.contains("襲撃22%"), "カーレオンに襲撃率が出る", note.text)

	# 紋章が入っている。
	var crest_count: int = 0
	for city_id: String in panel._nodes:
		var node: Control = panel._nodes[city_id]
		for child: Node in node.find_children("*", "TextureRect", true, false):
			crest_count += 1
	_check(crest_count == 6, "6都市に紋章が入る", str(crest_count))

	# 移動すると現在地の表示が移る。
	session.move_to("bridgewatch")
	var moved_note: Label = panel._nodes["bridgewatch"].find_child("Note", true, false)
	if moved_note != null:
		_check(moved_note.text.contains("現在地"), "移動先が現在地になる", moved_note.text)
	var old_note: Label = panel._nodes["martlock"].find_child("Note", true, false)
	if old_note != null:
		_check(not old_note.text.contains("現在地"), "元の都市は現在地でなくなる", old_note.text)

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
