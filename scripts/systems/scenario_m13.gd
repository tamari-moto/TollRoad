extends "res://scripts/systems/scenario_base.gd"
## 目的の提示（開始画面・HUD の純資産表示）の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m13.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")



func _init() -> void:
	_test_goal_constant()
	_test_briefing_content()
	_test_briefing_follows_data()
	_test_hud_net_worth()
	_test_investment_is_visible()
	_test_main_scene()
	_test_scene_headers()
	await _test_dialog_sizing()
	_finish()


func _test_goal_constant() -> void:
	print("--- 目標ランクの定義 ---")
	_check(GameData.GOAL_RANK == "MASTER TRADER", "目標は MASTER TRADER", GameData.GOAL_RANK)

	# GOAL_RANK が RANKS に実在すること（綴り違いを検出する）。
	var found: bool = false
	for rank: Dictionary in GameData.RANKS:
		if rank["name"] == GameData.GOAL_RANK:
			found = true
	_check(found, "目標ランクが RANKS に実在する", "見つからない")

	var hud = load("res://scripts/ui/hud.gd")
	var briefing = load("res://scripts/ui/briefing_dialog.gd")
	_check(hud.goal_amount() == 500000, "目標額は500,000", str(hud.goal_amount()))
	_check(hud.goal_amount() == briefing.goal_amount(),
		"HUD と開始画面が同じ目標額を使う", "食い違っている")


func _test_briefing_content() -> void:
	print("--- 開始画面の内容 ---")
	var dialog: Node = _spawn("res://scenes/ui/BriefingDialog.tscn")
	if dialog == null:
		return
	dialog.show_briefing()

	var premise: Label = UiUtil.find_node(dialog, "Premise")
	var goal: Label = UiUtil.find_node(dialog, "GoalLabel")
	var hint: Label = UiUtil.find_node(dialog, "Hint")
	var ranks: VBoxContainer = UiUtil.find_node(dialog, "RankList")

	_check(premise != null and premise.text.contains("商人"), "導入文に商人と出る",
		premise.text if premise != null else "ない")
	_check(premise != null and premise.text.contains("カーレオン"),
		"カーレオンの危険が示される", "示されない")

	_check(goal != null and goal.text.contains("500,000"), "目標額が出る",
		goal.text if goal != null else "ない")
	_check(goal != null and goal.text.contains("MASTER TRADER"), "目標ランク名が出る",
		goal.text if goal != null else "ない")

	# ランク表が5段階すべて並ぶ。
	_check(ranks != null and ranks.get_child_count() == GameData.RANKS.size(),
		"ランク表が5段階出る", str(ranks.get_child_count()) if ranks != null else "ない")

	# 純資産の定義がヒントに書かれている（シルバーとの違いが要点）。
	_check(hint != null and hint.text.contains("純資産"), "純資産の説明がある",
		hint.text if hint != null else "ない")
	_check(hint != null and hint.text.contains("仕入れ"), "仕入れが投資だと示される", "示されない")
	_check(hint != null and hint.text.contains("装備"), "製作ルートが示唆される", "示されない")

	# 目標ランクだけ色が違う（どこを目指すか分かる）。
	if ranks != null and ranks.get_child_count() > 0:
		var goal_colored: bool = false
		for row: Node in ranks.get_children():
			var label: Label = row.get_child(0) as Label
			if label == null:
				continue
			if label.text == GameData.GOAL_RANK:
				var color: Color = label.get_theme_color("font_color")
				goal_colored = color == UiTheme.rank_color(GameData.GOAL_RANK)
		_check(goal_colored, "目標ランクだけ色で強調される", "されない")

	_despawn(dialog)


func _test_briefing_follows_data() -> void:
	print("--- 文面が GameData に追従する ---")
	var dialog: Node = _spawn("res://scenes/ui/BriefingDialog.tscn")
	if dialog == null:
		return
	dialog.show_briefing()

	var premise: Label = UiUtil.find_node(dialog, "Premise")
	var goal: Label = UiUtil.find_node(dialog, "GoalLabel")

	# 数値はハードコードでなく定数由来であること。
	_check(premise.text.contains(str(GameData.TOTAL_DAYS)), "日数が定数由来", premise.text)
	_check(premise.text.contains(UiUtil.format_number(GameData.INITIAL_SILVER)),
		"初期シルバーが定数由来", premise.text)
	_check(goal.text.contains(str(GameData.TOTAL_DAYS)), "目標文にも日数が入る", goal.text)

	_despawn(dialog)


func _test_hud_net_worth() -> void:
	print("--- HUD の純資産表示 ---")
	var hud: Node = _spawn("res://scenes/ui/HUD.tscn")
	if hud == null:
		return
	var session: GameSession = GameSession.new(13001)
	hud.bind(session)

	var label: Label = UiUtil.find_node(hud, "NetWorthLabel")
	var bar: ProgressBar = UiUtil.find_node(hud, "GoalBar")
	_check(label != null, "NetWorthLabel がある", "ない")
	_check(bar != null, "GoalBar がある", "ない")
	if label == null or bar == null:
		_despawn(hud)
		return

	_check(label.text.contains(UiUtil.format_number(session.net_worth())),
		"純資産が net_worth() と一致する", label.text)
	_check(label.text.contains("500,000"), "目標額が併記される", label.text)
	_check(bar.max_value == 500000, "バーの最大が目標額", str(bar.max_value))
	_check(bar.value == float(session.net_worth()), "バーが純資産を指す", str(bar.value))

	# 目標に届くと色が変わる。
	_check(label.get_theme_color("font_color") == UiTheme.TEXT, "未達成は標準色", "違う")
	session.silver = 600000
	# シルバーを直接書き換えたのでシグナルは飛ばない。パネル規約の refresh() で更新する。
	hud.refresh()
	_check(label.get_theme_color("font_color") == UiTheme.GOOD, "達成すると好調色", "変わらない")
	_check(bar.value == 500000, "バーは目標で頭打ち", str(bar.value))

	# 島倉庫も純資産に入る。
	var island: GameSession = GameSession.new(13002)
	island.silver = 1000000
	hud.bind(island)
	island.upgrade_island()
	var before: String = label.text
	island.rest()
	_check(label.text != before, "島倉庫が増えると表示が更新される", "変わらない")

	_despawn(hud)


func _test_investment_is_visible() -> void:
	print("--- 仕入れが投資だと分かるか ---")
	var hud: Node = _spawn("res://scenes/ui/HUD.tscn")
	if hud == null:
		return
	var session: GameSession = GameSession.new(13003)
	hud.bind(session)

	var silver_label: Label = UiUtil.find_node(hud, "SilverLabel")
	var worth_label: Label = UiUtil.find_node(hud, "NetWorthLabel")

	var silver_before: int = session.silver
	var worth_before: int = session.net_worth()
	_check(silver_before == worth_before, "積荷が無ければシルバー＝純資産",
		"%d vs %d" % [silver_before, worth_before])

	# 特産地で安く仕入れる。シルバーは大きく減る。
	session.buy("ore", 20)
	var silver_after: int = session.silver
	var worth_after: int = session.net_worth()

	_check(silver_after < silver_before, "仕入れでシルバーは減る",
		"%d -> %d" % [silver_before, silver_after])

	# 純資産の目減りはシルバーの減りより小さい（積荷が資産に計上される）。
	var silver_drop: int = silver_before - silver_after
	var worth_drop: int = worth_before - worth_after
	_check(worth_drop < silver_drop, "純資産の目減りはシルバーより小さい",
		"シルバー -%d / 純資産 -%d" % [silver_drop, worth_drop])

	# 表示にも反映されている。
	_check(worth_label.text.contains(UiUtil.format_number(worth_after)),
		"仕入れ後の純資産が表示される", worth_label.text)

	_despawn(hud)


func _test_main_scene() -> void:
	print("--- メイン画面への組み込み ---")
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	_check(scene != null, "Main.tscn が読み込める", "失敗")
	if scene == null:
		return
	var main: Node = scene.instantiate()

	for path: String in ["%BriefingDialog", "%BriefingButton"]:
		_check(main.get_node_or_null(path) != null, "Main の %s が引ける" % path, "見つからない")

	var dialog: Node = main.get_node_or_null("%BriefingDialog")
	if dialog != null:
		_check(dialog.has_method("show_briefing"), "show_briefing がある", "ない")
		_check(dialog.has_signal("closed"), "closed シグナルがある", "ない")
	main.free()


## ダイアログの中身が実際に描画されうる大きさになっているか。
##
## Window の子に anchors_preset だけ書いて offset を省くとサイズ 0 のまま
## 描画されず、中身のない黒い矩形だけが出る。ノードを引く検査は通って
## しまうため、実寸を見て検出する必要がある。
func _test_dialog_sizing() -> void:
	print("--- ダイアログの実寸 ---")
	for path: String in ["res://scenes/ui/BriefingDialog.tscn",
			"res://scenes/ui/ResultDialog.tscn"]:
		var window: Window = _spawn(path) as Window
		if window == null:
			continue
		if window.has_method("bind"):
			window.bind(GameSession.new(13100))
		if window.has_method("show_briefing"):
			window.show_briefing()
		else:
			window.show_result()

		# レイアウトの確定を待つ。
		await process_frame
		await process_frame

		var content: Control = window.get_child(0) as Control
		var name: String = path.get_file()
		_check(content != null, "%s に中身がある" % name, "ない")
		if content == null:
			_despawn(window)
			continue

		_check(content.size.x > 0 and content.size.y > 0,
			"%s の中身に大きさがある" % name, str(content.size))

		# ハーネスでは Window のサイズが実機と一致しないことがあるため、
		# 「中身が窓に収まるか」ではなく「中身が無制限に膨張していないか」を見る。
		# autowrap の Label が幅を得られないと数千pxに伸びるので、それを検出する。
		_check(content.size.y < 2000, "%s の中身が縦に膨張していない" % name,
			"高さ %.0f" % content.size.y)

		# 文字が実際に幅を持っている（autowrap で潰れていない）。
		for label_name: String in ["Premise", "Hint", "RankLabel"]:
			var label: Label = window.find_child(label_name, true, false)
			if label != null:
				_check(label.size.x > 10, "%s の %s に幅がある" % [name, label_name],
					str(label.size))
		_despawn(window)


## .tscn の load_steps が実際の ext_resource 数と合っているか。
##
## 手書きの .tscn で load_steps を書き忘れると、Godot は読み込み自体は
## 成功させるが中身が展開されず、実行時に空のウィンドウだけが出る。
## instantiate() は通ってしまうため、シナリオでは検出できなかった。
func _test_scene_headers() -> void:
	print("--- .tscn のヘッダ整合 ---")
	var dir: DirAccess = DirAccess.open("res://scenes")
	if dir == null:
		_check(false, "scenes/ を開ける", "開けない")
		return

	var paths: PackedStringArray = []
	_collect_scenes("res://scenes", paths)
	_check(paths.size() > 0, "シーンが見つかる", "0件")

	for path: String in paths:
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var header: String = file.get_line()
		var body: String = file.get_as_text()
		file.close()

		var ext_count: int = body.count("[ext_resource ")
		var sub_count: int = body.count("[sub_resource ")
		var expected: int = ext_count + sub_count + 1
		if ext_count + sub_count == 0:
			continue

		var declared: int = 0
		var marker: int = header.find("load_steps=")
		if marker >= 0:
			declared = header.substr(marker + 11).split(" ")[0].to_int()

		_check(declared == expected, "%s の load_steps" % path.get_file(),
			"宣言 %d / 期待 %d" % [declared, expected])


func _collect_scenes(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		var full: String = "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			_collect_scenes(full, out)
		elif entry.ends_with(".tscn"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
