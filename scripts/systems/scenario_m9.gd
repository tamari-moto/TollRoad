extends SceneTree
## 手触りの調整（パレット統一・フィードバック・キー操作）の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m9.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

var _failures: int = 0


func _init() -> void:
	_test_palette()
	_test_palette_shared()
	_test_input_map()
	_test_silver_feedback()
	_test_cargo_colors()
	_test_raid_log_tint()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_palette() -> void:
	print("--- パレット ---")
	_check(UiTheme.GOOD != UiTheme.WARN, "好調と警戒は別の色", "同じ")
	_check(UiTheme.TEXT != UiTheme.TEXT_STALE, "標準と古い記録は別の色", "同じ")
	_check(UiTheme.TEXT_STALE != UiTheme.TEXT_UNKNOWN, "古い記録と未訪問は別の色", "同じ")

	# 古い記録・未訪問ほど暗く、読みの優先度が下がる並びになっている。
	_check(UiTheme.TEXT.v > UiTheme.TEXT_STALE.v, "古い記録は標準より暗い",
		"%.2f vs %.2f" % [UiTheme.TEXT.v, UiTheme.TEXT_STALE.v])
	_check(UiTheme.TEXT_STALE.v > UiTheme.TEXT_UNKNOWN.v, "未訪問は古い記録より暗い",
		"%.2f vs %.2f" % [UiTheme.TEXT_STALE.v, UiTheme.TEXT_UNKNOWN.v])

	# 比率から色を引く。
	_check(UiTheme.ratio_color(0.8) == UiTheme.GOOD, "安い比率は好調色", "違う")
	_check(UiTheme.ratio_color(1.2) == UiTheme.WARN, "高い比率は警戒色", "違う")
	_check(UiTheme.ratio_color(1.0) == UiTheme.TEXT, "標準の比率は標準色", "違う")

	# ランク色。
	_check(UiTheme.rank_color("LEGENDARY MERCHANT") == UiTheme.RANK_LEGENDARY,
		"LEGENDARYの色", "違う")
	_check(UiTheme.rank_color("BANKRUPT") == UiTheme.RANK_BANKRUPT, "BANKRUPTの色", "違う")
	_check(UiTheme.rank_color("SURVIVOR") == UiTheme.RANK_NORMAL, "既定は通常色", "違う")

	# 全9品目に色がある。
	for item_id: String in GameData.ITEMS:
		_check(UiTheme.ITEM_COLORS.has(item_id), "%s に色がある" % item_id, "ない")
	_check(UiTheme.item_color("unknown_item") == Color.GRAY, "未定義の品目は灰色", "違う")


func _test_palette_shared() -> void:
	print("--- パネルがパレットを共有している ---")
	var market = load("res://scripts/ui/market_panel.gd")
	var memo = load("res://scripts/ui/memo_panel.gd")
	var workshop = load("res://scripts/ui/workshop_panel.gd")
	var map_panel = load("res://scripts/ui/map_panel.gd")
	var result = load("res://scripts/ui/result_dialog.gd")

	# 以前は同じ緑が3ファイルに重複していた。今は1つの定義を指す。
	_check(memo.COLOR_CHEAPEST == UiTheme.GOOD, "相場メモの最安色はパレット由来", "違う")
	_check(workshop.COLOR_BONUS == UiTheme.GOOD, "製作ボーナス色はパレット由来", "違う")
	_check(memo.COLOR_CHEAPEST == workshop.COLOR_BONUS, "両者が同じ色を指す", "ずれている")

	# 注目色も同様に3ファイルで共有。
	_check(memo.COLOR_CURRENT == UiTheme.FOCUS, "相場メモの現在地色", "違う")
	_check(map_panel.COLOR_CURRENT == UiTheme.FOCUS, "大陸図の現在地色", "違う")
	_check(memo.COLOR_CURRENT == map_panel.COLOR_CURRENT, "両者が同じ色を指す", "ずれている")

	# 警戒色。
	_check(map_panel.COLOR_DANGER == UiTheme.WARN, "黒ゾーンの危険色", "違う")

	# ランク色。
	_check(result.COLOR_LEGENDARY == UiTheme.RANK_LEGENDARY, "リザルトのLEGENDARY色", "違う")

	# M7 が参照している COLOR_STALE が生きていること（互換の確認）。
	_check(memo.COLOR_STALE == UiTheme.TEXT_STALE, "COLOR_STALE がパレット由来", "違う")


func _test_input_map() -> void:
	print("--- 入力マップ ---")
	for action: String in ["tr_rest", "tr_tab_1", "tr_tab_2", "tr_tab_3", "tr_tab_4"]:
		_check(InputMap.has_action(action), "%s が登録されている" % action, "ない")

	# キー割り当てを確認する。
	var expected: Dictionary = {
		"tr_rest": KEY_SPACE,
		"tr_tab_1": KEY_1,
		"tr_tab_2": KEY_2,
		"tr_tab_3": KEY_3,
		"tr_tab_4": KEY_4,
	}
	for action: String in expected:
		if not InputMap.has_action(action):
			continue
		var found: bool = false
		for event: InputEvent in InputMap.action_get_events(action):
			var key_event: InputEventKey = event as InputEventKey
			if key_event != null and key_event.physical_keycode == expected[action]:
				found = true
		_check(found, "%s が期待のキーに割り当てられている" % action, "違うキー")


func _test_silver_feedback() -> void:
	print("--- シルバーのフィードバック ---")
	var hud: Node = _spawn("res://scenes/ui/HUD.tscn")
	if hud == null:
		return
	var session: GameSession = GameSession.new(9001)
	hud.bind(session)

	var label: Label = UiUtil.find_node(hud, "SilverLabel")
	_check(label.text.contains("30,000"), "初期額が出る", label.text)

	# --script のハーネスはツリー外扱いなので、Tween を挟まず即座に反映される。
	# アニメーションの有無にかかわらず最終値が正しいことが要点。
	session.buy("ore", 10)
	_check(label.text.contains(UiUtil.format_number(session.silver)),
		"購入後の額が即座に反映される", label.text)

	# 連続で操作しても最終値に収束する。
	session.buy("ore", 5)
	session.sell("ore", 3)
	_check(label.text.contains(UiUtil.format_number(session.silver)),
		"連続操作でも最終値に一致する", "%s / 実際 %d" % [label.text, session.silver])

	# 再プレイでは前回の残額からカウントし始めない。
	var fresh: GameSession = GameSession.new(9002)
	hud.bind(fresh)
	_check(label.text.contains("30,000"), "再プレイで初期額に戻る", label.text)

	_despawn(hud)


func _test_cargo_colors() -> void:
	print("--- 積荷バーの色 ---")
	var panel: Node = _spawn("res://scenes/ui/CargoPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(9003)
	panel.bind(session)

	var bar: HBoxContainer = UiUtil.find_node(panel, "CargoBar")
	# 空のときは空き区画だけ。
	_check(bar.get_child_count() == 1, "空なら1区画", str(bar.get_child_count()))
	var empty_rect: ColorRect = bar.get_child(0) as ColorRect
	_check(empty_rect.color == UiTheme.CARGO_EMPTY, "空き部分はパレットの色", "違う")

	# 積むと品目の色が入る。
	session.buy("ore", 10)
	_check(bar.get_child_count() == 2, "積荷1種＋空きで2区画", str(bar.get_child_count()))
	var ore_rect: ColorRect = bar.get_child(0) as ColorRect
	_check(ore_rect.color == UiTheme.item_color("ore"), "鉱石はパレットの色", "違う")

	_despawn(panel)


func _test_raid_log_tint() -> void:
	print("--- 襲撃ログの着色 ---")
	# 襲撃メッセージが警戒色になる条件を確認する。判定は文字列の一致。
	var raid_message: String = "[2日目] 襲撃された。積荷を全て失った。"
	var normal_message: String = "[2日目] 休息した。"
	_check(raid_message.contains("襲撃"), "襲撃メッセージが判定される", "されない")
	_check(not normal_message.contains("襲撃"), "通常メッセージは判定されない", "される")

	# 実際に襲撃が起きるセッションで、その文言がログに入ることを確認する。
	var found: bool = false
	for seed_value: int in range(1, 300):
		var s: GameSession = GameSession.new(seed_value)
		s.buy("ore", 5)
		if s.cargo_count("ore") == 0:
			continue
		s.move_to("caerleon")
		if s.cargo.is_empty():
			for entry: String in s.log_entries:
				if entry.contains("襲撃"):
					found = true
			break
	_check(found, "襲撃時にその文言がログへ記録される", "見つからない")


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
