extends SceneTree
## M6 の検証シナリオ。市場・積荷・大陸図の3画面が実際に動くことを確認する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m6.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

var _failures: int = 0


func _init() -> void:
	_test_scenes_load()
	_test_market_panel()
	_test_quantity_selection()
	_test_cargo_panel()
	_test_map_panel()
	_test_main_scene_structure()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_scenes_load() -> void:
	print("--- シーンの読み込み ---")
	for path: String in [
		"res://scenes/ui/MarketPanel.tscn",
		"res://scenes/ui/CargoPanel.tscn",
		"res://scenes/ui/MapPanel.tscn",
	]:
		var scene: PackedScene = load(path)
		_check(scene != null, "%s が読み込める" % path.get_file(), "失敗")
		if scene != null:
			var node: Node = scene.instantiate()
			_check(node != null and node.has_method("bind"), "%s に bind がある" % path.get_file(), "ない")
			if node != null:
				node.free()


func _test_market_panel() -> void:
	print("--- 市場画面 ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(6001)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "ItemGrid")
	_check(grid != null, "ItemGrid がある", "ない")
	if grid == null:
		_despawn(panel)
		return

	# ヘッダ6列 + 9品目 × 6列 = 60ノード
	var expected: int = 6 + GameData.ITEMS.size() * 6
	_check(grid.get_child_count() == expected, "全9品目の行が生成される",
		"%d / 期待 %d" % [grid.get_child_count(), expected])

	var title: Label = UiUtil.find_node(panel, "MarketTitle")
	_check(title.text.contains("マートロック"), "現在地が題名に出る", title.text)

	# 価格表示が実際の相場と一致する。行の並びは ITEMS の順。
	var first_item: String = GameData.ITEMS.keys()[0]
	var price_label: Label = grid.get_child(6 + 1) as Label
	var actual_price: int = session.prices.get_price(session.current_city, first_item)
	_check(price_label.text == UiUtil.format_number(actual_price),
		"価格が相場と一致する", "%s vs %d" % [price_label.text, actual_price])

	# 買うボタンで実際に購入できる。
	var buy_button: Button = grid.get_child(6 + 4) as Button
	_check(not buy_button.disabled, "買うボタンが押せる", "無効")
	var silver_before: int = session.silver
	buy_button.pressed.emit()
	_check(session.silver < silver_before, "買うボタンで購入される", "変化なし")
	_check(session.cargo_count(first_item) == 1, "数量1で1個買える", str(session.cargo_count(first_item)))

	# 所持数の表示が追従する。
	var held_label: Label = grid.get_child(6 + 3) as Label
	_check(held_label.text == "1", "所持数の表示が追従する", held_label.text)

	# 売るボタンが有効になり、売却できる。
	var sell_button: Button = grid.get_child(6 + 5) as Button
	_check(not sell_button.disabled, "所持していれば売るボタンが押せる", "無効")
	sell_button.pressed.emit()
	_check(session.cargo_count(first_item) == 0, "売るボタンで売却される", str(session.cargo_count(first_item)))

	# 終了後は全ボタンが無効になる。
	while not session.is_over():
		session.rest()
	panel.refresh()
	_check(buy_button.disabled and sell_button.disabled, "終了後はボタンが無効", "押せてしまう")

	_despawn(panel)


func _test_quantity_selection() -> void:
	print("--- 数量選択 ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(6002)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "ItemGrid")
	var first_item: String = GameData.ITEMS.keys()[0]
	var buy_button: Button = grid.get_child(6 + 4) as Button

	# 「5」を選ぶと5個買う。
	var qty5: Button = UiUtil.find_node(panel, "Qty1")
	qty5.pressed.emit()
	buy_button.pressed.emit()
	_check(session.cargo_count(first_item) == 5, "数量5で5個買える", str(session.cargo_count(first_item)))

	# 「全部」を選ぶと売れるだけ売る。
	var qty_all: Button = UiUtil.find_node(panel, "Qty3")
	qty_all.pressed.emit()
	var sell_button: Button = grid.get_child(6 + 5) as Button
	sell_button.pressed.emit()
	_check(session.cargo_count(first_item) == 0, "全部で全て売れる", str(session.cargo_count(first_item)))

	# 「半分」は購入可能数の半分。
	var qty_half: Button = UiUtil.find_node(panel, "Qty2")
	qty_half.pressed.emit()
	var maximum: int = session.max_buyable(first_item)
	buy_button.pressed.emit()
	_check(session.cargo_count(first_item) == maxi(1, maximum / 2), "半分で約半量買える",
		"%d / 上限 %d" % [session.cargo_count(first_item), maximum])

	_despawn(panel)


func _test_cargo_panel() -> void:
	print("--- 積荷画面 ---")
	var panel: Node = _spawn("res://scenes/ui/CargoPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(6003)
	panel.bind(session)

	var title: Label = UiUtil.find_node(panel, "CargoTitle")
	var detail: Label = UiUtil.find_node(panel, "CargoDetail")
	var bar: HBoxContainer = UiUtil.find_node(panel, "CargoBar")

	_check(title.text.contains("0 / 40"), "空のとき積載0/40と出る", title.text)
	_check(detail.text == "（空）", "空のとき（空）と出る", detail.text)
	# 空でもバーには空き領域の1区画がある。
	_check(bar.get_child_count() == 1, "空でも空き区画が1つ", str(bar.get_child_count()))

	session.buy("ore", 10)
	_check(title.text.contains("10 / 40"), "購入で積載表示が変わる", title.text)
	_check(detail.text.contains("鉱石"), "内訳に品目名が出る", detail.text)
	_check(bar.get_child_count() == 2, "積荷1種＋空きで2区画", str(bar.get_child_count()))

	session.buy("wood", 5)
	_check(bar.get_child_count() == 3, "積荷2種＋空きで3区画", str(bar.get_child_count()))

	# 騎乗を変えると容量表示が変わる。
	session.silver = 100000
	session.buy_mount("ox")
	_check(title.text.contains("/ 85"), "騎乗購入で容量表示が変わる", title.text)
	_check(title.text.contains("雄牛"), "騎乗名が出る", title.text)

	_despawn(panel)


func _test_map_panel() -> void:
	print("--- 大陸図 ---")
	var panel: Node = _spawn("res://scenes/ui/MapPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(6004)
	panel.bind(session)

	var list: VBoxContainer = UiUtil.find_node(panel, "CityList")
	_check(list != null, "CityList がある", "ない")
	if list == null:
		_despawn(panel)
		return
	_check(list.get_child_count() == 6, "6都市のボタンがある", str(list.get_child_count()))

	# 現在地は無効かつ「現在地」と表示される。
	var found_current: bool = false
	var found_raid: bool = false
	var found_adjacent: bool = false
	for child: Node in list.get_children():
		var button: Button = child as Button
		if button.text.contains("現在地"):
			found_current = true
			_check(button.disabled, "現在地のボタンは無効", "押せる")
		if button.text.contains("襲撃22%"):
			found_raid = true
		if button.text.contains("1日 / 250"):
			found_adjacent = true
	_check(found_current, "現在地が明示される", "ない")
	_check(found_raid, "カーレオンに襲撃率が出る", "ない")
	_check(found_adjacent, "隣接都市に1日/250と出る", "ない")

	# 移動確認ダイアログが出る。
	var caerleon_button: Button = null
	for child: Node in list.get_children():
		if (child as Button).text.contains("カーレオン"):
			caerleon_button = child as Button
	_check(caerleon_button != null, "カーレオンのボタンがある", "ない")
	if caerleon_button != null:
		caerleon_button.pressed.emit()
		var dialog: ConfirmationDialog = null
		for child: Node in panel.get_children():
			if child is ConfirmationDialog:
				dialog = child
		_check(dialog != null, "確認ダイアログが生成される", "ない")
		if dialog != null:
			_check(dialog.dialog_text.contains("黒ゾーン"), "黒ゾーンの警告が出る", dialog.dialog_text)
			_check(dialog.dialog_text.contains("22%"), "襲撃率が出る", dialog.dialog_text)
			# 確認すると実際に移動する。
			var before_city: String = session.current_city
			dialog.confirmed.emit()
			_check(session.current_city == "caerleon", "確認で移動する",
				"%s -> %s" % [before_city, session.current_city])

	# 資金が尽きると移動ボタンが無効になる。
	session.silver = 10
	panel.refresh()
	var all_disabled: bool = true
	for child: Node in list.get_children():
		var button: Button = child as Button
		if not button.disabled:
			all_disabled = false
	_check(all_disabled, "資金不足で全移動先が無効", "押せるものがある")

	_despawn(panel)


func _test_main_scene_structure() -> void:
	print("--- メイン画面の構成 ---")
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	_check(scene != null, "Main.tscn が読み込める", "失敗")
	if scene == null:
		return
	var main: Node = scene.instantiate()
	# 大陸図は M7 でタブ化した際にノード名を「大陸図」に変えている。
	for path: String in ["%HUD", "%MarketPanel", "%CargoPanel", "%大陸図",
			"%LogScroll", "%LogList", "%RestButton", "%StatusLabel"]:
		_check(main.get_node_or_null(path) != null, "Main の %s が引ける" % path, "見つからない")
	main.free()


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
