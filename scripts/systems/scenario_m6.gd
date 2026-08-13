extends "res://scripts/systems/scenario_base.gd"
## M6 の検証シナリオ。市場・積荷・大陸図の3画面が実際に動くことを確認する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m6.gd
##
## _check() / _spawn() / _despawn() / _finish() は scenario_base.gd にある。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")


func _init() -> void:
	_test_scenes_load()
	_test_market_panel()
	_test_quantity_selection()
	_test_cargo_panel()
	_test_map_panel()
	_test_main_scene_structure()
	_finish()


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

	# ヘッダ6列 + 全品目 × 6列
	var expected: int = 6 + GameData.ITEMS.size() * 6
	_check(grid.get_child_count() == expected, "全品目の行が生成される",
		"%d / 期待 %d" % [grid.get_child_count(), expected])

	var title: Label = UiUtil.find_node(panel, "MarketTitle")
	_check(title.text.contains(GameData.CITIES[GameData.INITIAL_CITY]["name"]), "現在地が題名に出る", title.text)

	# 価格表示が実際の相場と一致する。行の並びは ITEMS の順。
	var first_item: String = GameData.ITEMS.keys()[0]
	var price_label: Label = grid.get_child(6 + 1) as Label
	var actual_price: int = session.prices.get_price(session.current_city, first_item)
	_check(price_label.text == UiUtil.format_number(actual_price),
		"価格が相場と一致する", "%s vs %d" % [price_label.text, actual_price])

	# 買うボタンで実際に購入できる。個数指定は無く、常に1個。
	var buy_button: Button = grid.get_child(6 + 4) as Button
	_check(not buy_button.disabled, "買うボタンが押せる", "無効")
	var silver_before: int = session.silver
	buy_button.pressed.emit()
	_check(session.silver < silver_before, "買うボタンで購入される", "変化なし")
	_check(session.cargo_count(first_item) == 1, "1回押すと1個買える", str(session.cargo_count(first_item)))

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
	print("--- クリック連打で数量を調整する ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(6002)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "ItemGrid")
	var first_item: String = GameData.ITEMS.keys()[0]
	var buy_button: Button = grid.get_child(6 + 4) as Button
	var sell_button: Button = grid.get_child(6 + 5) as Button

	# 個数指定のUIは無い。買うボタンを5回連打すると5個買える。
	for i in range(5):
		buy_button.pressed.emit()
	_check(session.cargo_count(first_item) == 5, "買うボタンを5回押すと5個買える",
		str(session.cargo_count(first_item)))

	# 売るボタンも同様に、押した回数だけ売れる。
	for i in range(3):
		sell_button.pressed.emit()
	_check(session.cargo_count(first_item) == 2, "売るボタンを3回押すと3個売れる",
		str(session.cargo_count(first_item)))

	# 所持数を超えて売ろうとしても、無効になった時点で止まる（過剰売却しない）。
	for i in range(10):
		sell_button.pressed.emit()
	_check(session.cargo_count(first_item) == 0, "押し続けても所持数以下で止まる",
		str(session.cargo_count(first_item)))
	_check(sell_button.disabled, "所持が無くなると売るボタンが無効になる", "押せてしまう")

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

	var list: Control = UiUtil.find_node(panel, "CityList")
	_check(list != null, "CityList がある", "ない")
	if list == null:
		_despawn(panel)
		return

	# 都市の選択は Button ではなくレイキャストで判定する（CLAUDE.md参照）。
	_check(panel.node_count() == GameData.CITIES.size(), "全都市のノードがある", str(panel.node_count()))

	# 表示テキストはツールチップの文言に入る。
	var found_current: bool = false
	var found_raid: bool = false
	var found_adjacent: bool = false
	for city_id: String in GameData.CITIES:
		var tip: String = panel.tooltip_text_for(city_id)
		if tip.contains("現在地"):
			found_current = true
			_check(not panel.is_selectable(city_id), "現在地は選択できない", "選択できる")
		if tip.contains("襲撃22%"):
			found_raid = true
		if tip.contains("1日 / 250"):
			found_adjacent = true
	_check(found_current, "現在地が明示される", "ない")
	_check(found_raid, "中心都市に襲撃率が出る", "ない")
	_check(found_adjacent, "隣接都市に1日/250と出る", "ない")

	# 移動確認ダイアログが出る。
	panel.select_city(GameData.CAERLEON)
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
		_check(session.current_city == GameData.CAERLEON, "確認で移動する",
			"%s -> %s" % [before_city, session.current_city])

	# 資金が尽きると移動先が全て選択できなくなる。
	session.silver = 10
	panel.refresh()
	var all_unselectable: bool = true
	for city_id: String in GameData.CITIES:
		if panel.is_selectable(city_id):
			all_unselectable = false
	_check(all_unselectable, "資金不足で全移動先が選択不可", "選択できるものがある")

	_despawn(panel)


func _test_main_scene_structure() -> void:
	print("--- メイン画面の構成 ---")
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	_check(scene != null, "Main.tscn が読み込める", "失敗")
	if scene == null:
		return
	var main: Node = scene.instantiate()
	# 大陸図はタブに属さず常時表示。ノード名は「大陸図」のまま。
	for path: String in ["%HUD", "%MarketPanel", "%CargoPanel", "%大陸図",
			"%LogScroll", "%LogList", "%RestButton", "%StatusLabel"]:
		_check(main.get_node_or_null(path) != null, "Main の %s が引ける" % path, "見つからない")
	main.free()
