extends "res://scripts/systems/scenario_base.gd"
## M7 の検証シナリオ。製作所・相場メモ・島と装備の3画面を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m7.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")



func _init() -> void:
	_test_memo_api()
	_test_workshop_panel()
	_test_memo_panel()
	_test_memo_staleness()
	_test_island_panel()
	_test_main_scene_has_all_screens()
	_finish()


func _test_memo_api() -> void:
	print("--- 相場メモの API ---")
	var s: GameSession = GameSession.new(7001)
	_check(s.memo_age("ironhollow") == 0, "現在地の記録は0日前", str(s.memo_age("ironhollow")))
	_check(s.memo_age("ravenspire") == -1, "未訪問は-1", str(s.memo_age("ravenspire")))
	_check(s.memo_price("ravenspire", "ore") == -1, "未訪問の価格は-1", str(s.memo_price("ravenspire", "ore")))

	var recorded: int = s.memo_price("ironhollow", "ore")
	var actual: int = s.prices.get_price("ironhollow", "ore")
	_check(recorded == actual, "記録は訪問時の相場と一致", "%d vs %d" % [recorded, actual])

	# 移動して日が進むと、前の都市の記録は古くなるが値は残る。
	s.move_to("stonegate")
	_check(s.memo_price("ironhollow", "ore") == recorded, "去った都市の記録は保持される",
		str(s.memo_price("ironhollow", "ore")))
	_check(s.memo_age("ironhollow") == 1, "1日経つと1日前の記録", str(s.memo_age("ironhollow")))


func _test_workshop_panel() -> void:
	print("--- 製作所 ---")
	var panel: Node = _spawn("res://scenes/ui/WorkshopPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(7002)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "RecipeGrid")
	_check(grid != null, "RecipeGrid がある", "ない")
	if grid == null:
		_despawn(panel)
		return

	# ヘッダ5列 + 装備種数 × 5列
	var equipment_count: int = 0
	for item_id: String in GameData.ITEMS:
		if GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.EQUIPMENT:
			equipment_count += 1
	_check(grid.get_child_count() == 5 + equipment_count * 5, "全装備の行が生成される", str(grid.get_child_count()))

	var title: Label = UiUtil.find_node(panel, "WorkshopTitle")
	# アイアンホロウは剣のボーナス都市。
	_check(title.text.contains("剣"), "ボーナス対象が題名に出る", title.text)
	_check(title.text.contains("90"), "手数料が題名に出る", title.text)

	# 剣の行（ITEMS の並びで sword は6番目、装備としては1番目）。
	var sword_cost: Label = grid.get_child(5 + 2) as Label
	_check(sword_cost.text == "2個", "ボーナス都市では消費2個", sword_cost.text)

	# 材料が無ければ作れない。
	var sword_button: Button = grid.get_child(5 + 4) as Button
	_check(sword_button.disabled, "材料なしでは作るボタンが無効", "押せる")

	# 材料を買うと作れるようになる。
	session.buy("ore", 10)
	_check(not sword_button.disabled, "材料があれば押せる", "無効のまま")
	_check(sword_button.text.contains("5"), "作れる数がボタンに出る", sword_button.text)

	var day_before: int = session.day
	sword_button.pressed.emit()
	_check(session.cargo_count("sword") == 5, "作るボタンでまとめて製作される",
		str(session.cargo_count("sword")))
	_check(session.day == day_before + 1, "製作は1日消費", str(session.day - day_before))

	# ボーナスのない都市では消費3個になる。
	session.move_to("stonegate")
	panel.refresh()
	_check(sword_cost.text == "3個", "ボーナス外では消費3個", sword_cost.text)

	_despawn(panel)


func _test_memo_panel() -> void:
	print("--- 相場メモ表 ---")
	var panel: Node = _spawn("res://scenes/ui/MemoPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(7003)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "MemoGrid")
	_check(grid != null, "MemoGrid がある", "ない")
	if grid == null:
		_despawn(panel)
		return

	# 見出し行(1+都市数) + 全品目 × (1+都市数)
	var columns: int = GameData.CITIES.size() + 1
	var expected: int = columns + GameData.ITEMS.size() * columns
	_check(grid.get_child_count() == expected, "全都市×全品目の表になる",
		"%d / 期待 %d" % [grid.get_child_count(), expected])
	_check(grid.columns == columns, "列数は品目＋全都市", str(grid.columns))

	# 未訪問の都市は「?」。開始時はアイアンホロウのみ既知。
	var unknown_count: int = 0
	var known_count: int = 0
	for child: Node in grid.get_children():
		var label: Label = child as Label
		if label == null:
			continue
		if label.text == "?":
			unknown_count += 1
		elif label.text.strip_edges().is_valid_int() or label.text.contains(","):
			known_count += 1
	var unvisited: int = GameData.CITIES.size() - 1
	_check(unknown_count == GameData.ITEMS.size() * unvisited, "未訪問都市×全品目が?になる", str(unknown_count))
	_check(known_count == GameData.ITEMS.size(), "現在地の品目だけ既知", str(known_count))

	# 訪問すると「?」が減る。
	session.move_to("stonegate")
	panel.refresh()
	var after_unknown: int = 0
	for child: Node in grid.get_children():
		var label: Label = child as Label
		if label != null and label.text == "?":
			after_unknown += 1
	_check(after_unknown == GameData.ITEMS.size() * (unvisited - 1), "訪問すると?が全品目分減る", str(after_unknown))

	_despawn(panel)


func _test_memo_staleness() -> void:
	print("--- 記録の鮮度（7日で薄字） ---")
	var panel: Node = _spawn("res://scenes/ui/MemoPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(7004)
	panel.bind(session)
	var grid: GridContainer = UiUtil.find_node(panel, "MemoGrid")

	# アイアンホロウを離れ、7日経過させる。
	session.move_to("stonegate")
	_check(not session.is_memo_stale("ironhollow"), "1日後はまだ新しい", "古い扱い")

	for i: int in 6:
		session.rest()
	_check(session.is_memo_stale("ironhollow"), "7日経つと古い記録になる",
		"age=%d" % session.memo_age("ironhollow"))
	panel.refresh()

	# 薄字（COLOR_STALE）になっているセルが存在する。
	var memo_script = load("res://scripts/ui/memo_panel.gd")
	var stale_color: Color = memo_script.COLOR_STALE
	var stale_cells: int = 0
	for child: Node in grid.get_children():
		var label: Label = child as Label
		if label == null:
			continue
		if label.has_theme_color_override("font_color"):
			if label.get_theme_color("font_color") == stale_color:
				stale_cells += 1
	_check(stale_cells == GameData.ITEMS.size(), "古い都市の全品目が薄字になる", str(stale_cells))

	# 現在地の記録は毎日更新されるので薄字にならない。
	_check(not session.is_memo_stale("stonegate"), "現在地は常に新しい", "古い扱い")

	_despawn(panel)


func _test_island_panel() -> void:
	print("--- 島と装備 ---")
	var panel: Node = _spawn("res://scenes/ui/IslandPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(7005)
	panel.bind(session)

	var island_label: Label = UiUtil.find_node(panel, "IslandLabel")
	var upgrade_button: Button = UiUtil.find_node(panel, "UpgradeButton")
	var warehouse_label: Label = UiUtil.find_node(panel, "WarehouseLabel")
	var withdraw_button: Button = UiUtil.find_node(panel, "WithdrawButton")
	var mount_list: VBoxContainer = UiUtil.find_node(panel, "MountList")

	_check(island_label.text.contains("レベル 0"), "初期は島レベル0", island_label.text)
	_check(island_label.text.contains("0 人"), "労働者0人", island_label.text)
	_check(upgrade_button.text.contains("26,000"), "拡張費用が出る", upgrade_button.text)
	_check(not upgrade_button.disabled, "初期資金で拡張できる", "無効")
	_check(warehouse_label.text.contains("空"), "倉庫は空", warehouse_label.text)
	_check(withdraw_button.disabled, "倉庫が空なら引き取り不可", "押せる")

	# 拡張すると労働者が増える。
	upgrade_button.pressed.emit()
	_check(island_label.text.contains("レベル 1"), "拡張でレベルが上がる", island_label.text)
	_check(island_label.text.contains("3 人"), "労働者3人になる", island_label.text)
	_check(island_label.text.contains("6 個"), "1日6個と出る", island_label.text)
	_check(upgrade_button.disabled, "資金不足で次の拡張は無効", "押せる")

	# 休息で倉庫が貯まり、引き取れるようになる。
	session.rest()
	_check(not warehouse_label.text.contains("空"), "倉庫に資源が入る", warehouse_label.text)
	_check(warehouse_label.text.contains("計 6 個"), "計6個と出る", warehouse_label.text)
	_check(not withdraw_button.disabled, "引き取りが押せる", "無効")

	var day_before: int = session.day
	withdraw_button.pressed.emit()
	_check(session.cargo_weight() > 0, "引き取りで積荷に入る", str(session.cargo_weight()))
	_check(session.day == day_before + 1, "引き取りは1日消費", str(session.day - day_before))

	# 騎乗のボタン。
	_check(mount_list.get_child_count() == 3, "騎乗3種のボタンがある", str(mount_list.get_child_count()))
	var found_current: bool = false
	for child: Node in mount_list.get_children():
		var button: Button = child as Button
		if button.text.contains("使用中"):
			found_current = true
			_check(button.disabled, "使用中の騎乗は選べない", "押せる")
	_check(found_current, "使用中の騎乗が明示される", "ない")

	# 資金を与えると騎乗を買える。
	session.silver = 100000
	panel.refresh()
	var ox_button: Button = null
	for child: Node in mount_list.get_children():
		if (child as Button).text.contains("雄牛"):
			ox_button = child as Button
	_check(ox_button != null and not ox_button.disabled, "資金があれば騎乗を買える", "無効")
	if ox_button != null:
		ox_button.pressed.emit()
		_check(session.mount == "ox", "騎乗が変わる", session.mount)
		_check(ox_button.text.contains("使用中"), "購入後は使用中になる", ox_button.text)

	_despawn(panel)


func _test_main_scene_has_all_screens() -> void:
	print("--- メイン画面に全画面が揃う ---")
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	_check(scene != null, "Main.tscn が読み込める", "失敗")
	if scene == null:
		return
	var main: Node = scene.instantiate()
	for path: String in ["%HUD", "%MarketPanel", "%CargoPanel", "%Tabs",
			"%大陸図", "%製作所", "%相場メモ", "%島と装備", "%探索",
			"%TabStrip", "%SidePanel",
			"%MarketTabButton", "%CargoTabButton", "%WorkshopTabButton",
			"%MemoTabButton", "%IslandTabButton", "%ExplorationTabButton",
			"%LogScroll", "%RestButton", "%StatusLabel"]:
		_check(main.get_node_or_null(path) != null, "Main の %s が引ける" % path, "見つからない")

	var tabs: TabContainer = main.get_node_or_null("%Tabs")
	if tabs != null:
		# 大陸図はタブの外（常時表示）。市場・積荷・製作所・相場メモ・島と装備・探索の6つがタブ。
		_check(tabs.get_tab_count() == 6, "タブが6つある", str(tabs.get_tab_count()))
		_check(not tabs.tabs_visible, "Tabsのタブバー自体は隠れている（TabStripが選択を持つ）",
			"見えている")

	# SidePanel は既定で閉じている（幅0、非表示）。main.gd の _ready() は
	# GameState オートロードに依存するため、--script では main をツリーに
	# 入れず構造だけを検査する（他の Main シナリオと同じ方針）。
	var side_panel: Control = main.get_node_or_null("%SidePanel")
	if side_panel != null:
		_check(not side_panel.visible, "サイドパネルは既定で閉じている", "開いている")
		_check(side_panel.offset_left == side_panel.offset_right,
			"閉状態では幅が0", "%.1f" % (side_panel.offset_right - side_panel.offset_left))
	main.free()
