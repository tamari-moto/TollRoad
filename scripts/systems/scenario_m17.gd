extends SceneTree
## 大陸図の斜め見下ろし表示の検証。楕円配置・地盤・ピン・描画順。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m17.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const MapPin = preload("res://scripts/ui/map_pin.gd")
const MapGround = preload("res://scripts/ui/map_ground.gd")

var _failures: int = 0


func _init() -> void:
	_test_tilt_constant()
	_test_ellipse_layout()
	_test_angles_even()
	_test_depth_order()
	_test_ground_layer()
	await _test_pins_render()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_tilt_constant() -> void:
	print("--- 傾きの設定 ---")
	_check(UiTheme.MAP_TILT > 0.0, "圧縮率が正の値", str(UiTheme.MAP_TILT))
	_check(UiTheme.MAP_TILT < 1.0, "1未満（真上からではない）", str(UiTheme.MAP_TILT))
	# 潰しすぎると都市が重なって読めなくなる。
	_check(UiTheme.MAP_TILT > 0.25, "潰しすぎていない", str(UiTheme.MAP_TILT))


func _test_ellipse_layout() -> void:
	print("--- 楕円配置 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(17001)
	panel.bind(session)

	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_despawn(panel)
		return
	area.size = Vector2(400, 320)
	panel._layout_nodes()

	# 5都市の広がりを測る。横に広く、縦に潰れているのが斜め見下ろし。
	var min_x: float = 99999.0
	var max_x: float = -99999.0
	var min_y: float = 99999.0
	var max_y: float = -99999.0
	for city_id: String in GameData.royal_city_ids():
		var button: Button = panel._buttons.get(city_id)
		if button == null:
			continue
		var c: Vector2 = button.position + button.custom_minimum_size * 0.5
		min_x = minf(min_x, c.x)
		max_x = maxf(max_x, c.x)
		min_y = minf(min_y, c.y)
		max_y = maxf(max_y, c.y)

	var width: float = max_x - min_x
	var height: float = max_y - min_y
	_check(width > height, "横の広がりが縦より大きい（斜めから見た形）",
		"横 %.0f / 縦 %.0f" % [width, height])
	print("     広がり: 横 %.0f / 縦 %.0f（比 %.2f）" % [width, height, height / width])

	# 潰れ具合が設定した圧縮率とおおむね一致する。
	var expected: float = UiTheme.MAP_TILT
	_check(absf(height / width - expected) < 0.1, "圧縮率が設定どおり",
		"実測 %.2f / 設定 %.2f" % [height / width, expected])

	_despawn(panel)


func _test_angles_even() -> void:
	print("--- 5都市が等間隔 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(17002)
	panel.bind(session)
	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_despawn(panel)
		return
	area.size = Vector2(400, 320)
	panel._layout_nodes()

	var center: Vector2 = area.size * 0.5
	var angles: Array[float] = []
	for city_id: String in GameData.royal_city_ids():
		var button: Button = panel._buttons.get(city_id)
		if button == null:
			continue
		var offset: Vector2 = button.position + button.custom_minimum_size * 0.5 - center
		# Y を戻してから角度を求める。
		offset.y /= UiTheme.MAP_TILT
		angles.append(offset.angle())

	_check(angles.size() == 5, "5都市ぶんの角度が取れる", str(angles.size()))
	if angles.size() == 5:
		# 隣り合う角度の差が 72度（TAU/5）ずつになっている。
		var expected: float = TAU / 5.0
		var even: bool = true
		for i: int in 5:
			var diff: float = angles[(i + 1) % 5] - angles[i]
			# 角度の巻き戻りを吸収する。
			while diff < 0.0:
				diff += TAU
			if absf(diff - expected) > 0.05:
				even = false
		_check(even, "隣り合う都市が72度ずつ離れている", "間隔が不均等")

	# カーレオンは中央のまま（移動ルールとの対応が崩れていない）。
	var caerleon: Button = panel._buttons.get(GameData.CAERLEON)
	if caerleon != null:
		var c: Vector2 = caerleon.position + caerleon.custom_minimum_size * 0.5
		_check(c.distance_to(center) < 1.0, "カーレオンは中央のまま",
			"中心から %.2f" % c.distance_to(center))

	_despawn(panel)


func _test_depth_order() -> void:
	print("--- 奥行きの重なり ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(17003)
	panel.bind(session)
	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_despawn(panel)
		return
	area.size = Vector2(400, 320)
	panel._layout_nodes()

	# ボタンの並び順が Y の昇順（奥が先、手前が後）になっている。
	var previous_y: float = -99999.0
	var ordered: bool = true
	var checked: int = 0
	for child: Node in area.get_children():
		var button: Button = child as Button
		if button == null:
			continue
		var y: float = button.position.y
		if y < previous_y - 0.5:
			ordered = false
		previous_y = y
		checked += 1

	_check(checked == 6, "6都市のボタンが並ぶ", str(checked))
	_check(ordered, "奥の都市ほど先に描かれる（手前が上に重なる）", "順序が逆")

	_despawn(panel)


func _test_ground_layer() -> void:
	print("--- 地盤 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(17004)
	panel.bind(session)
	var area: Control = UiUtil.find_node(panel, "CityList")
	if area == null:
		_despawn(panel)
		return
	area.size = Vector2(400, 320)
	panel._layout_nodes()

	var ground: Node = area.get_node_or_null("Ground")
	_check(ground != null, "地盤の層がある", "ない")
	if ground == null:
		_despawn(panel)
		return

	_check(ground.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"地盤はクリックを妨げない", str(ground.mouse_filter))
	_check(ground._positions.size() == 6, "6都市ぶんの地盤がある",
		str(ground._positions.size()))
	_check(ground._current_city == session.current_city,
		"現在地が地盤に伝わる", ground._current_city)

	# 移動すると現在地の地盤が移る。
	session.move_to("bridgewatch")
	panel._layout_nodes()
	_check(ground._current_city == "bridgewatch", "移動で現在地の地盤が移る",
		ground._current_city)

	_despawn(panel)


func _test_pins_render() -> void:
	print("--- ピンが描画される ---")
	# M13 の「サイズ 0 で描画されない」罠の再発防止。
	var pin: MapPin = MapPin.new()
	root.add_child(pin)
	pin.size = Vector2(104, 96)
	await process_frame
	_check(pin.size.x > 0 and pin.size.y > 0, "ピンに大きさがある", str(pin.size))
	_check(pin.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"ピンはクリックを妨げない", str(pin.mouse_filter))
	root.remove_child(pin)
	pin.free()

	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(17005)
	panel.bind(session)
	var area: Control = UiUtil.find_node(panel, "CityList")
	if area != null:
		area.size = Vector2(400, 320)
		panel._layout_nodes()
	await process_frame
	await process_frame

	# 全都市にピンが入っている。
	var pin_count: int = 0
	for city_id: String in panel._buttons:
		var button: Button = panel._buttons[city_id]
		if button.find_child("Pin", true, false) != null:
			pin_count += 1
	_check(pin_count == 6, "6都市すべてにピンがある", str(pin_count))

	# 現在地のピンが強調される。
	var current_pin: MapPin = panel._buttons[session.current_city].find_child(
		"Pin", true, false)
	if current_pin != null:
		_check(current_pin.is_current, "現在地のピンが強調される", "されない")

	# カーレオンのピンは危険色。
	var caerleon_pin: MapPin = panel._buttons[GameData.CAERLEON].find_child(
		"Pin", true, false)
	if caerleon_pin != null:
		_check(caerleon_pin.danger, "カーレオンのピンは危険を示す", "示さない")

	# 都市名と経路情報は従来どおり残っている（情報量を減らしていない）。
	var note: Label = panel._buttons["bridgewatch"].find_child("Note", true, false)
	if note != null:
		_check(note.text.contains("ブリッジウォッチ"), "都市名が出る", note.text)
		_check(note.text.contains("1日") and note.text.contains("250"),
			"経路情報が残っている", note.text)

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
