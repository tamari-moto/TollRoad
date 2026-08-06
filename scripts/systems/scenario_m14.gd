extends SceneTree
## 売買エフェクトの検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m14.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const FxLayer = preload("res://scripts/ui/fx_layer.gd")

var _failures: int = 0


func _init() -> void:
	_test_layer_basics()
	await _test_flight_spawns_and_clears()
	_test_missing_icon_fallback()
	_test_market_signal()
	await _test_flight_path()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_layer_basics() -> void:
	print("--- 演出層の性質 ---")
	var fx: FxLayer = FxLayer.new()
	root.add_child(fx)

	_check(fx.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"クリックを透過する（演出中もボタンが押せる）", str(fx.mouse_filter))
	_check(fx.anchor_right == 1.0 and fx.anchor_bottom == 1.0,
		"全画面を覆う", "%s / %s" % [fx.anchor_right, fx.anchor_bottom])
	_check(fx.get_child_count() == 0, "初期状態では何も無い", str(fx.get_child_count()))

	root.remove_child(fx)
	fx.free()


func _test_flight_spawns_and_clears() -> void:
	print("--- 飛翔の生成と後始末 ---")
	var fx: FxLayer = FxLayer.new()
	root.add_child(fx)

	fx.fly_item("ore", Vector2(10, 10), Vector2(200, 300))
	_check(fx.get_child_count() == 1, "飛ぶノードが1つ生まれる", str(fx.get_child_count()))

	var flyer: Control = fx.get_child(0) as Control
	_check(flyer != null, "Control として生まれる", "違う")
	if flyer != null:
		_check(flyer.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"飛翔物もクリックを透過する", str(flyer.mouse_filter))

	# 複数同時に飛ばせる（連打しても壊れない）。
	fx.fly_item("wood", Vector2(10, 10), Vector2(200, 300))
	fx.fly_item("sword", Vector2(10, 10), Vector2(200, 300))
	_check(fx.get_child_count() == 3, "同時に複数飛ばせる", str(fx.get_child_count()))

	# 演出が終わると自動で片付く（残り続けない）。
	var elapsed: float = 0.0
	while elapsed < 1.2 and fx.get_child_count() > 0:
		await process_frame
		elapsed += 0.016
	_check(fx.get_child_count() == 0, "終わると自動的に消える",
		"%d 個残った" % fx.get_child_count())

	root.remove_child(fx)
	fx.free()


func _test_missing_icon_fallback() -> void:
	print("--- 画像が無い品目 ---")
	var fx: FxLayer = FxLayer.new()
	root.add_child(fx)

	# 未定義の品目でも落ちず、演出は出る。
	fx.fly_item("nonexistent_item", Vector2.ZERO, Vector2(100, 100))
	_check(fx.get_child_count() == 1, "画像が無くても飛ぶものが出る", str(fx.get_child_count()))
	if fx.get_child_count() > 0:
		_check(fx.get_child(0) is ColorRect, "代用の矩形が使われる",
			fx.get_child(0).get_class())

	# ツリー外では何も起こさない（--script の外で呼ばれても落ちない）。
	var orphan: FxLayer = FxLayer.new()
	orphan.fly_item("ore", Vector2.ZERO, Vector2(50, 50))
	_check(orphan.get_child_count() == 0, "ツリー外では何もしない", str(orphan.get_child_count()))
	orphan.free()

	root.remove_child(fx)
	fx.free()


func _test_market_signal() -> void:
	print("--- 市場からの通知 ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(14001)
	panel.bind(session)

	_check(panel.has_signal("traded"), "traded シグナルがある", "ない")

	var events: Array[Dictionary] = []
	panel.traded.connect(func(item_id: String, is_buy: bool, origin: Vector2) -> void:
		events.append({"item": item_id, "buy": is_buy, "origin": origin}))

	var grid: GridContainer = UiUtil.find_node(panel, "ItemGrid")
	var first_item: String = GameData.ITEMS.keys()[0]
	var buy_button: Button = grid.get_child(7 + 5) as Button
	var sell_button: Button = grid.get_child(7 + 6) as Button

	buy_button.pressed.emit()
	_check(events.size() == 1, "購入で1件通知される", str(events.size()))
	if events.size() > 0:
		_check(events[0]["item"] == first_item, "品目が渡る", str(events[0]["item"]))
		_check(events[0]["buy"] == true, "購入として渡る", str(events[0]["buy"]))

	sell_button.pressed.emit()
	_check(events.size() == 2, "売却でも通知される", str(events.size()))
	if events.size() > 1:
		_check(events[1]["buy"] == false, "売却として渡る", str(events[1]["buy"]))

	# 失敗した取引では通知しない（持っていない物は売れない）。
	var before: int = events.size()
	sell_button.pressed.emit()
	_check(events.size() == before, "成立しない取引では通知しない",
		"%d -> %d" % [before, events.size()])

	_despawn(panel)


func _test_flight_path() -> void:
	print("--- 飛翔の軌跡 ---")
	var fx: FxLayer = FxLayer.new()
	root.add_child(fx)
	fx.size = Vector2(800, 600)

	var from_point := Vector2(100, 400)
	var to_point := Vector2(600, 200)
	fx.fly_item("ore", from_point, to_point)
	var flyer: Control = fx.get_child(0) as Control
	if flyer == null:
		_despawn_layer(fx)
		return

	# 出発点に置かれている。
	var half: Vector2 = flyer.custom_minimum_size * 0.5
	_check(flyer.global_position.distance_to(from_point - half) < 2.0,
		"出発点から始まる", str(flyer.global_position))

	# 途中で弧を描く（直線より上を通る）。
	var samples: Array[Vector2] = []
	for i: int in 12:
		await process_frame
		if is_instance_valid(flyer):
			samples.append(flyer.position)

	if samples.size() >= 3:
		var mid: Vector2 = samples[samples.size() / 2]
		var straight_y: float = (from_point.y + to_point.y) * 0.5 - half.y
		_check(mid.y < straight_y, "直線より上を通る（弧を描く）",
			"中間 %.0f / 直線 %.0f" % [mid.y, straight_y])
		# 動いている。
		_check(samples[0].distance_to(samples[samples.size() - 1]) > 10.0,
			"実際に移動する", "ほぼ動いていない")

	_despawn_layer(fx)


# --- ヘルパ ---

func _despawn_layer(fx: FxLayer) -> void:
	root.remove_child(fx)
	fx.free()


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
