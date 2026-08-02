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

	var center: Vector2 = area.size * 0.5
	var ring: Array[String] = GameData.royal_city_ids()
	var radii: Array[float] = []

	for city_id: String in ring:
		var button: Button = panel._buttons.get(city_id)
		_check(button != null, "%s のノードがある" % city_id, "ない")
		if button == null:
			continue
		var node_center: Vector2 = button.position + button.custom_minimum_size * 0.5
		radii.append(node_center.distance_to(center))

	# 斜め見下ろしにしたため円は楕円に潰れている。Y を戻してから
	# 等距離を確認する（真上から見れば同一円周上にあること）。
	var unprojected: Array[float] = []
	for city_id: String in ring:
		var button: Button = panel._buttons.get(city_id)
		if button == null:
			continue
		var node_center: Vector2 = button.position + button.custom_minimum_size * 0.5
		var offset: Vector2 = node_center - center
		# 圧縮した Y を元に戻す。
		offset.y /= UiTheme.MAP_TILT
		unprojected.append(offset.length())

	if unprojected.size() == 5:
		var spread: float = unprojected.max() - unprojected.min()
		_check(spread < 1.0, "逆変換すると5都市が同一円周上にある",
			"半径の差 %.2f" % spread)
		_check(unprojected[0] > 10.0, "半径がゼロでない", str(unprojected[0]))

	# カーレオンは中央。
	var caerleon: Button = panel._buttons.get(GameData.CAERLEON)
	if caerleon != null:
		var caerleon_center: Vector2 = caerleon.position + caerleon.custom_minimum_size * 0.5
		_check(caerleon_center.distance_to(center) < 1.0, "カーレオンは中央にある",
			"中心から %.2f" % caerleon_center.distance_to(center))

	# 環状の隣接どうしは、非隣接より近い。
	var fort: Button = panel._buttons.get("fort_sterling")
	var lym: Button = panel._buttons.get("lymhurst")
	var bridge: Button = panel._buttons.get("bridgewatch")
	if fort != null and lym != null and bridge != null:
		var adjacent_dist: float = fort.position.distance_to(lym.position)
		var far_dist: float = fort.position.distance_to(bridge.position)
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

	var routes: Node = area.get_node_or_null("Routes")
	_check(routes != null, "経路線の層がある", "ない")
	if routes == null:
		_despawn(panel)
		return

	# 線はノードより後ろに描かれる（先に追加されている）。
	# 層は下から順に 地盤 → 経路線 → 都市ノード。
	var ground: Node = area.get_node_or_null("Ground")
	_check(ground != null, "地盤の層がある", "ない")
	_check(area.get_child(0) == ground, "地盤が最も下に敷かれる", "順序が違う")
	_check(area.get_child(1) == routes, "経路線は地盤の上・ノードの下", "順序が違う")
	_check(routes.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"経路線はクリックを妨げない", "妨げる")

	# 全6都市の座標が渡されている。
	_check(routes._positions.size() == 6, "6都市の座標が渡る", str(routes._positions.size()))
	for city_id: String in GameData.CITIES:
		_check(routes._positions.has(city_id), "%s の座標がある" % city_id, "ない")

	_despawn(panel)


func _test_node_contents() -> void:
	print("--- ノードの中身 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(11003)
	panel.bind(session)

	# 現在地（マートロック）のノード。
	var current: Button = panel._buttons.get("martlock")
	_check(current != null, "現在地のノードがある", "ない")
	if current != null:
		_check(current.disabled, "現在地は押せない", "押せる")
		var note: Label = current.find_child("Note", true, false)
		_check(note != null, "ラベルがある", "ない")
		if note != null:
			_check(note.text.contains("現在地"), "現在地と表示される", note.text)
			_check(note.text.contains("マートロック"), "都市名が出る", note.text)

	# 隣接都市には日数と費用。
	var neighbour: Button = panel._buttons.get("bridgewatch")
	if neighbour != null:
		var note: Label = neighbour.find_child("Note", true, false)
		if note != null:
			_check(note.text.contains("1日"), "隣接は1日と出る", note.text)
			_check(note.text.contains("250"), "隣接は250と出る", note.text)

	# カーレオンには襲撃率。
	var caerleon: Button = panel._buttons.get(GameData.CAERLEON)
	if caerleon != null:
		var note: Label = caerleon.find_child("Note", true, false)
		if note != null:
			_check(note.text.contains("襲撃22%"), "カーレオンに襲撃率が出る", note.text)

	# 紋章が入っている。
	var crest_count: int = 0
	for city_id: String in panel._buttons:
		var button: Button = panel._buttons[city_id]
		for child: Node in button.find_children("*", "TextureRect", true, false):
			crest_count += 1
	_check(crest_count == 6, "6都市に紋章が入る", str(crest_count))

	# 移動すると現在地の表示が移る。
	session.move_to("bridgewatch")
	var moved_note: Label = panel._buttons["bridgewatch"].find_child("Note", true, false)
	if moved_note != null:
		_check(moved_note.text.contains("現在地"), "移動先が現在地になる", moved_note.text)
	var old_note: Label = panel._buttons["martlock"].find_child("Note", true, false)
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
