extends "res://scripts/systems/scenario_base.gd"
## M8 の検証シナリオ。リザルト画面と再プレイ、および製作の阻害理由表示を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m8.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")



func _init() -> void:
	_test_result_dialog()
	_test_rebind_no_leak()
	_test_craft_blocked_reason()
	_test_growth_route_reachable()
	_test_main_scene()
	_finish()


func _test_result_dialog() -> void:
	print("--- リザルト画面 ---")
	var dialog: Node = _spawn("res://scenes/ui/ResultDialog.tscn")
	if dialog == null:
		return

	var session: GameSession = GameSession.new(8001)
	session.silver = 600000
	session.buy("ore", 10)
	dialog.bind(session)
	dialog.show_result()

	var rank_label: Label = UiUtil.find_node(dialog, "RankLabel")
	var net_label: Label = UiUtil.find_node(dialog, "NetWorthLabel")
	var breakdown: VBoxContainer = UiUtil.find_node(dialog, "Breakdown")

	_check(rank_label.text == "MASTER TRADER", "60万でMASTER TRADERと出る", rank_label.text)
	_check(net_label.text.contains(UiUtil.format_number(session.net_worth())),
		"純資産が桁区切りで出る", net_label.text)
	_check(breakdown.get_child_count() > 0, "内訳が生成される", str(breakdown.get_child_count()))

	# 内訳にシルバーと在庫評価が含まれる。
	var text_dump: String = ""
	for row: Node in breakdown.get_children():
		for cell: Node in row.get_children():
			if cell is Label:
				text_dump += (cell as Label).text + " "
	_check(text_dump.contains("所持シルバー"), "内訳に所持シルバーがある", "ない")
	_check(text_dump.contains("島倉庫"), "内訳に島倉庫がある", "ない")
	_check(text_dump.contains("次のランクまで"), "次のランクまでの差が出る", "ない")

	# ランクごとの色分け。実体は UiTheme にある（リザルトはそれを呼ぶだけ）。
	var script_ref = load("res://scripts/ui/result_dialog.gd")
	_check(UiTheme.rank_color("LEGENDARY MERCHANT") == script_ref.COLOR_LEGENDARY,
		"LEGENDARYは専用色", "違う")
	_check(UiTheme.rank_color("BANKRUPT") == script_ref.COLOR_BANKRUPT,
		"BANKRUPTは専用色", "違う")

	# 最上位なら「次のランク」は出ない。
	var top: GameSession = GameSession.new(8002)
	top.silver = 2000000
	dialog.bind(top)
	dialog.show_result()
	var top_dump: String = ""
	for row: Node in breakdown.get_children():
		for cell: Node in row.get_children():
			if cell is Label:
				top_dump += (cell as Label).text + " "
	_check(not top_dump.contains("次のランクまで"), "最上位では次のランクを出さない", "出ている")

	_despawn(dialog)


func _test_rebind_no_leak() -> void:
	print("--- 再プレイでシグナルが漏れない ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return

	var first: GameSession = GameSession.new(8003)
	panel.bind(first)
	_check(first.silver_changed.get_connections().size() == 1,
		"1回目の接続は1つ", str(first.silver_changed.get_connections().size()))

	# 同じセッションで再度 bind しても二重接続しない。
	panel.bind(first)
	_check(first.silver_changed.get_connections().size() == 1,
		"同じセッションを再bindしても増えない", str(first.silver_changed.get_connections().size()))

	# 新しいセッションに繋ぎ替えると、古い方は切れる。
	var second: GameSession = GameSession.new(8004)
	panel.bind(second)
	_check(first.silver_changed.get_connections().size() == 0,
		"古いセッションから切断される", str(first.silver_changed.get_connections().size()))
	_check(second.silver_changed.get_connections().size() == 1,
		"新しいセッションに接続される", str(second.silver_changed.get_connections().size()))

	# 古いセッションを動かしても新しい表示は変わらない。
	var grid: GridContainer = UiUtil.find_node(panel, "ItemGrid")
	var title: Label = UiUtil.find_node(panel, "MarketTitle")
	first.move_to(_adjacent_royal_city(first.current_city))
	_check(title.text.contains(GameData.CITIES[GameData.INITIAL_CITY]["name"]),
		"古いセッションの移動は表示に影響しない", title.text)

	_despawn(panel)


func _test_craft_blocked_reason() -> void:
	print("--- 製作できない理由の表示 ---")
	var panel: Node = _spawn("res://scenes/ui/WorkshopPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(8005)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "RecipeGrid")
	var sword_button: Button = grid.get_child(5 + 4) as Button

	# 材料なし。
	_check(sword_button.tooltip_text.contains("鉱石"), "材料不足の理由が出る", sword_button.tooltip_text)

	# 積荷を満杯にすると、材料はあるのに作れなくなる。
	# 資源2個(重量2)が装備1個(重量3)になるため正味+1の空きが要る。
	session.buy("ore", session.max_buyable("ore"))
	_check(session.free_capacity() == 0, "積荷を満杯にした", str(session.free_capacity()))
	_check(session.cargo_count("ore") >= 2, "材料は足りている", str(session.cargo_count("ore")))
	panel.refresh()
	_check(session.max_craftable("sword") == 0, "満杯だと作れない", str(session.max_craftable("sword")))
	_check(sword_button.tooltip_text.contains("積載"),
		"積載不足が理由として出る", sword_button.tooltip_text)

	# 1個売って空ければ作れるようになる。
	session.sell("ore", 2)
	panel.refresh()
	_check(session.max_craftable("sword") > 0, "空きを作れば製作できる", str(session.max_craftable("sword")))
	_check(sword_button.tooltip_text == "", "作れる時は理由を出さない", sword_button.tooltip_text)

	_despawn(panel)


func _test_growth_route_reachable() -> void:
	print("--- 成長ルートが機能する ---")
	# ボーナス都市で特産資源から装備を作り、中心都市で売る。
	var home: String = GameData.INITIAL_CITY
	var home_name: String = GameData.CITIES[home]["name"]
	var hub: String = GameData.CAERLEON
	var hub_name: String = GameData.CITIES[hub]["name"]
	var s: GameSession = GameSession.new(8006)
	var start: int = s.silver

	# 剣13個ぶんの鉱石を買う（積載40に完成品39が収まる量）。
	s.buy("ore", 26)
	_check(s.max_craftable("sword") == 13, "鉱石26個から剣13個作れる", str(s.max_craftable("sword")))
	s.craft("sword", 13)
	_check(s.cargo_count("sword") == 13, "剣13個できた", str(s.cargo_count("sword")))

	var sword_price: int = s.prices.get_price(hub, "sword")
	var ore_price: int = s.prices.get_price(home, "ore")
	# ボーナス都市では材料2個 + 手数料90 が1個の原価。
	var unit_cost: int = ore_price * 2 + GameData.CRAFT_FEE
	_check(sword_price > unit_cost * 2,
		"中心都市の剣は原価の2倍以上で売れる", "原価%d / 売値%d" % [unit_cost, sword_price])

	# 襲撃されなければ大きく増える。
	s.move_to(hub)
	if s.cargo_count("sword") > 0:
		s.sell("sword", s.cargo_count("sword"))
		_check(s.silver > start, "1サイクルで資金が増える", "%d -> %d" % [start, s.silver])
		print("     3日で %d -> %d" % [start, s.silver])
	else:
		print("     （このシードでは襲撃された）")

	# 装備は中心都市で最も高い。
	var hub_sword: int = s.prices.get_price(hub, "sword")
	var home_sword: int = s.prices.get_price(home, "sword")
	_check(hub_sword > home_sword, "中心都市の装備は他所より高い",
		"%s%d / %s%d" % [hub_name, hub_sword, home_name, home_sword])


func _test_main_scene() -> void:
	print("--- メイン画面 ---")
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	_check(scene != null, "Main.tscn が読み込める", "失敗")
	if scene == null:
		return
	var main: Node = scene.instantiate()
	for path: String in ["%HUD", "%MarketPanel", "%CargoPanel", "%Tabs",
			"%大陸図", "%製作所", "%相場メモ", "%島と装備",
			"%LogScroll", "%RestButton", "%ResultButton", "%StatusLabel", "%ResultDialog"]:
		_check(main.get_node_or_null(path) != null, "Main の %s が引ける" % path, "見つからない")

	var dialog: Node = main.get_node_or_null("%ResultDialog")
	if dialog != null:
		_check(dialog.has_method("show_result"), "リザルトに show_result がある", "ない")
		_check(dialog.has_signal("restart_requested"), "再プレイのシグナルがある", "ない")
	main.free()
