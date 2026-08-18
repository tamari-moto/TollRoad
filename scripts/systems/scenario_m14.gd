extends "res://scripts/systems/scenario_base.gd"
## 売買エフェクトの検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m14.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const FxLayer = preload("res://scripts/ui/fx_layer.gd")
const GameStateScript = preload("res://scripts/autoload/game_state.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")

## 検査用のセーブ先。start_new_game() は delete_save() を通るため、
## 差し替えずに走らせると本編のセーブを消す。
const TEST_SAVE_PATH: String = "user://scenario_m14_tmp.json"

## 着地点の判定に許す誤差（px）。飛翔は弧を終えてから弾けて消えるので、
## 最後に見えた位置は本来ぴったり飛び先に一致する。丸めぶんだけ緩めてある。
const LANDING_TOLERANCE: float = 2.0

## 演出が片付くまで待つ上限（ミリ秒）。
## 飛翔は FLIGHT_DURATION 0.42 + 弾け 0.08 + 消え 0.12 = 0.62 秒かかる。
## 倍以上を取っておき、遅い環境でも待ち切れるようにする。
const FLIGHT_TIMEOUT_MSEC: int = 2000

## 弧の標本を採る長さ（ミリ秒）。FLIGHT_DURATION の半ばまで進めてから
## 判定したいので、0.42 秒の半分あたりを取る。
const FLIGHT_SAMPLE_MSEC: int = 220


func _init() -> void:
	_test_layer_basics()
	await _test_flight_spawns_and_clears()
	_test_missing_icon_fallback()
	_test_market_signal()
	await _test_flight_path()
	await _test_trade_flight_reaches_hud()
	_finish()


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
	#
	# 待ちは実時間で計ること。フレーム数に固定値を掛けて時間を代用すると、
	# 実際の 1 フレームが何ミリ秒かは環境と出力先で変わるため、待ち切れずに
	# 落ちる（実測: 12 フレームで 93ms しか進まず、演出に必要な 620ms に
	# 遠く届かない）。標準出力をファイルへ向けただけで結果が変わっていた。
	await _wait_until_empty(fx, FLIGHT_TIMEOUT_MSEC)
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
	var target: Dictionary = _tradable_row(session)
	if target.is_empty():
		_check(false, "この都市で買える品目がある", "1つも無い")
		_despawn(panel)
		return
	var buttons: Dictionary = _trade_buttons(grid, target["index"])
	if buttons.is_empty():
		_check(false, "行の売買ボタンが引ける", "引けない")
		_despawn(panel)
		return
	var buy_button: Button = buttons["buy"]
	var sell_button: Button = buttons["sell"]

	buy_button.pressed.emit()
	_check(events.size() == 1, "購入で1件通知される", str(events.size()))
	if events.size() > 0:
		_check(events[0]["item"] == target["item"], "品目が渡る", str(events[0]["item"]))
		_check(events[0]["buy"] == true, "購入として渡る", str(events[0]["buy"]))

	sell_button.pressed.emit()
	_check(events.size() == 2, "売却でも通知される", str(events.size()))
	if events.size() > 1:
		_check(events[1]["buy"] == false, "売却として渡る", str(events[1]["buy"]))

	# 失敗した取引では通知しない（持っていない物は売れない）。
	# 直前に買った品目は手元にあるため、1個も持っていない別の行で確かめる。
	var before: int = events.size()
	var empty_row: int = _row_without_cargo(session, target["index"])
	if empty_row < 0:
		_check(false, "1個も持っていない行がある", "全部持っている")
	else:
		var empty_buttons: Dictionary = _trade_buttons(grid, empty_row)
		(empty_buttons["sell"] as Button).pressed.emit()
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
	#
	# 飛翔の半ばまで実時間で進めてから標本を採る。フレーム数で数えると
	# 弧の頂点へ達する前（実測で行程の 22%）に判定してしまい、直線との差が
	# 数ピクセルしか出ないため、わずかな揺れで合否が反転していた。
	var samples: Array[Vector2] = await _sample_flight(flyer, FLIGHT_SAMPLE_MSEC)

	if samples.size() >= 3:
		var mid: Vector2 = samples[samples.size() / 2]
		var straight_y: float = (from_point.y + to_point.y) * 0.5 - half.y
		_check(mid.y < straight_y, "直線より上を通る（弧を描く）",
			"中間 %.0f / 直線 %.0f" % [mid.y, straight_y])
		# 動いている。
		_check(samples[0].distance_to(samples[samples.size() - 1]) > 10.0,
			"実際に移動する", "ほぼ動いていない")

	_despawn_layer(fx)


## 売買の演出が、市場（サイドパネルの中）から HUD まで跨いで飛ぶか。
##
## かつては市場パネルの内側で完結していた。SidePanel は clip_contents なので、
## パネルの中に演出層を置くと縁で切り取られ、HUD へは届かない。**置き場所と
## 飛び先の両方**を見る（層の位置だけを見ても、飛び先が同じなら買いと売りが
## 見分けられない）。
func _test_trade_flight_reaches_hud() -> void:
	print("--- 売買の演出が HUD まで届く ---")
	var main: Node = _spawn("res://scenes/main/Main.tscn")
	if main == null:
		return
	var state: Node = GameStateScript.new()
	state.name = "GameState"
	# start_new_game() は delete_save() を通る。**差し替えを先に済ませる。**
	state.use_save_path(TEST_SAVE_PATH)
	root.add_child(state)
	state.start_new_game(14002)
	main.bind_state(state)

	# レイアウトが決まるまで待つ。global_position を見る検査なので、
	# 決まる前に読むとすべて (0,0) になり、飛び先の違いが出ない。
	await process_frame
	await process_frame

	var fx: Node = main.get_node_or_null("UI/Root/TradeFx")
	_check(fx != null, "演出層が UI/Root の直下にある", "見つからない")

	var market: Node = UiUtil.find_node(main, "MarketPanel")
	_check(market != null and _find_fx_layer(market) == null,
		"市場パネルは演出層を抱えていない（縁で切られる）",
		"抱えている" if market != null else "市場パネルが無い")

	if fx != null:
		var clipper: String = _clipping_ancestor(fx)
		_check(clipper == "", "縁で切り取る親の中にいない", "%s の中にいる" % clipper)
		_check(fx.get_index() == fx.get_parent().get_child_count() - 1,
			"最後の子（＝最前面）に置かれている", str(fx.get_index()))

	var hud: Node = UiUtil.find_node(main, "HUD")
	_check(hud != null and hud.has_method("cargo_anchor")
			and hud.has_method("silver_anchor"),
		"HUD が飛び先を答えられる", "答えられない")

	if hud != null and hud.has_method("cargo_anchor"):
		var cargo_point: Vector2 = hud.cargo_anchor()
		var silver_point: Vector2 = hud.silver_anchor()
		_check(cargo_point.distance_to(silver_point) > 1.0,
			"積載とシルバーは別の場所を指す", "同じ場所 %s" % cargo_point)
		if fx != null and market != null:
			await _check_landing(fx, market, state.session, hud)

	_despawn(main)
	root.remove_child(state)
	state.free()
	SaveManager.delete_save(TEST_SAVE_PATH)


## 買いは積載へ、売りはシルバーへ着く。実際に飛ばして着地点を実測する。
##
## 飛び先は着地の**直後**に読み直す。売買で桁が変わるとラベルの幅が変わり、
## 横並びの HUD では右隣（積載）の位置がずれるため、飛ばす前に控えた座標と
## 比べると数px の差で落ちうる。
func _check_landing(fx: Node, market: Node, session: GameSession, hud: Node) -> void:
	var grid: GridContainer = UiUtil.find_node(market, "ItemGrid")
	var target: Dictionary = _tradable_row(session)
	if grid == null or target.is_empty():
		_check(false, "売買できる行がある", "無い")
		return
	var buttons: Dictionary = _trade_buttons(grid, target["index"])
	if buttons.is_empty():
		_check(false, "行の売買ボタンが引ける", "引けない")
		return

	(buttons["buy"] as Button).pressed.emit()
	_check(fx.get_child_count() > 0, "買うと飛翔物が生まれる", str(fx.get_child_count()))
	var buy_landing: Vector2 = await _final_center(fx, FLIGHT_TIMEOUT_MSEC)
	var cargo_point: Vector2 = hud.cargo_anchor()
	_check(buy_landing.distance_to(cargo_point) < LANDING_TOLERANCE,
		"買いは積載へ着く", "着地 %s / 積載 %s" % [buy_landing, cargo_point])

	(buttons["sell"] as Button).pressed.emit()
	_check(fx.get_child_count() > 0, "売ると飛翔物が生まれる", str(fx.get_child_count()))
	var sell_landing: Vector2 = await _final_center(fx, FLIGHT_TIMEOUT_MSEC)
	var silver_point: Vector2 = hud.silver_anchor()
	_check(sell_landing.distance_to(silver_point) < LANDING_TOLERANCE,
		"売りはシルバーへ着く", "着地 %s / シルバー %s" % [sell_landing, silver_point])


# --- ヘルパ ---

## 演出層が空になるまで実時間で待つ。上限に達したら諦めて戻る
## （戻った時点の子の数を呼び出し側が検査する）。
##
## フレーム数ではなく Time.get_ticks_msec() で計ること。1 フレームの実尺は
## 環境と出力先で変わるため、フレーム数に固定値を掛けると待ちが足りなくなる。
func _wait_until_empty(fx: FxLayer, timeout_msec: int) -> void:
	var started: int = Time.get_ticks_msec()
	while fx.get_child_count() > 0:
		if Time.get_ticks_msec() - started >= timeout_msec:
			return
		await process_frame


## 飛翔中の位置を実時間で標本する。duration_msec を過ぎるまで毎フレーム採る。
func _sample_flight(flyer: Control, duration_msec: int) -> Array[Vector2]:
	var samples: Array[Vector2] = []
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < duration_msec:
		await process_frame
		if not is_instance_valid(flyer):
			break
		samples.append(flyer.position)
	return samples


func _despawn_layer(fx: FxLayer) -> void:
	root.remove_child(fx)
	fx.free()


## 市場の row_index 番目の行の「買う」「売る」ボタン。引けなければ {}。
##
## **グリッドの子を通し番号で決め打ちしないこと。** かつて `6 + 4` と書いて
## あり、列が6→7に増えた（在庫/需要の列が入った）ときに別のセルを掴んで
## 落ちるようになっていた。Button は行につき「買う」「売る」の2つだけが
## 品目の並び順に入るので、Button だけを拾って2つずつ数える。
func _trade_buttons(grid: GridContainer, row_index: int) -> Dictionary:
	var buttons: Array[Button] = []
	for child: Node in grid.get_children():
		var button: Button = child as Button
		if button != null:
			buttons.append(button)
	var buy_index: int = row_index * 2
	if buy_index + 1 >= buttons.size():
		return {}
	return {"buy": buttons[buy_index], "sell": buttons[buy_index + 1]}


## 今この都市で「1個買えて、その1個を売れる」品目の行番号と id。無ければ {}。
##
## 品目を決め打ちしない。在庫と需要は都市・シードで変わるため、決め打ちだと
## 演出の検査なのに市場の都合で落ちる。
func _tradable_row(session: GameSession) -> Dictionary:
	var index: int = 0
	for item_id: String in GameData.ITEMS:
		if session.max_buyable(item_id) > 0 and session.demand_count(item_id) > 0:
			return {"index": index, "item": item_id}
		index += 1
	return {}


## 1個も積んでいない品目の行番号。except_index の行は除く。無ければ -1。
func _row_without_cargo(session: GameSession, except_index: int) -> int:
	var index: int = 0
	for item_id: String in GameData.ITEMS:
		if index != except_index and session.cargo_count(item_id) == 0:
			return index
		index += 1
	return -1


## node から親をたどり、中身を縁で切り取る Control の名前を返す。無ければ ""。
func _clipping_ancestor(node: Node) -> String:
	var current: Node = node.get_parent()
	while current != null:
		var control: Control = current as Control
		if control != null and control.clip_contents:
			return str(control.name)
		current = current.get_parent()
	return ""


## node の下から演出層を探す。無ければ null。
func _find_fx_layer(node: Node) -> Node:
	if node == null:
		return null
	if node.get_script() == FxLayer:
		return node
	for child: Node in node.get_children():
		var found: Node = _find_fx_layer(child)
		if found != null:
			return found
	return null


## 飛翔が消えるまで実時間で追い、最後に見えた中心（グローバル座標）を返す。
## 弧を終えた後に弾けて消えるため、最後の標本は必ず着地点にいる。
func _final_center(fx: Node, timeout_msec: int) -> Vector2:
	var last := Vector2.INF
	var started: int = Time.get_ticks_msec()
	while fx.get_child_count() > 0:
		if Time.get_ticks_msec() - started >= timeout_msec:
			break
		var flyer: Control = fx.get_child(0) as Control
		if flyer != null:
			last = flyer.global_position + flyer.custom_minimum_size * 0.5
		await process_frame
	return last
