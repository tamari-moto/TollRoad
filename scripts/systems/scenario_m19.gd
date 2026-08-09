extends "res://scripts/systems/scenario_base.gd"
## M19 の検証シナリオ。**main.gd の UI ハンドラを実物のまま走らせる。**
##
## これまで main.gd は autoload の GameState を識別子で参照しており、
## --script ではコンパイルできなかった（Failed to load script）。そのため
## Main.tscn はスクリプト無しのノード木としてしか立てられず、開始画面の分岐や
## 再プレイは scenario_m18.gd がソースを grep して判断を写すしかなかった。
## main.gd が bind_state() を持つようになり、実物を通せるようになった。
##
## 守りたいのは「セーブがいつ作られ、いつ変わらないか」。実装を写した検査は
## main.gd 側を変えたときに追随せず、素通りする。
##
## **scenario_all.gd の AWAIT_SCENARIOS に登録すること。**
## このシナリオ自身は await を書かないが、main.gd の _append_log() が
## `await get_tree().process_frame` を含み、_bind_session() から必ず呼ばれる。
## 子の SceneTree ではフレームループが回らず復帰しないため、同じプロセスで
## 動かすと未完了のコルーチンが積み上がる。_verify_await_list() はシナリオ
## 自身のソースしか見ないので、この事情は検出できない。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m19.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")
const GameStateScript = preload("res://scripts/autoload/game_state.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

## 検査専用のパス。SaveManager.SAVE_PATH は絶対に使わないこと
## （シナリオを流すたびにプレイヤーのセーブが消える）。
const TEST_PATH: String = "user://scenario_m19_tmp.json"


func _init() -> void:
	_test_main_loads()
	_test_briefing_new_game()
	_test_briefing_reread()
	_test_continue_success()
	_test_continue_failure()
	_test_restart()
	_test_autosave()
	_finish()


## Main.tscn を立て、本物の game_state.gd を差し込む。
##
## bind_state() は _spawn() の**後**に呼ぶ。_spawn() の add_child で
## main.gd の _ready() が走るが、そのとき _state はまだ null なので
## _bind_session(null) が早期 return し、パネルの結線とスタイル適用だけが済む。
## その後 bind_state() を呼ぶと、本編の起動と同じ経路で配布が走る。
##
## 返り値は {"main": Node, "state": Node}。立てられなければ空。
func _make_main(rng_seed: int) -> Dictionary:
	var main: Node = _spawn("res://scenes/main/Main.tscn")
	if main == null:
		return {}
	var state: Node = GameStateScript.new()
	state.name = "GameState"
	# start_new_game() は delete_save() を通る。**差し替えを先に済ませる。**
	state.use_save_path(TEST_PATH)
	root.add_child(state)
	# --script では _ready() が走らないので、セッションは明示的に作る。
	# シードを固定するのは規約（CLAUDE.md）。
	state.start_new_game(rng_seed)
	main.bind_state(state)
	return {"main": main, "state": state}


func _teardown(parts: Dictionary) -> void:
	if parts.has("main"):
		_despawn(parts["main"])
	if parts.has("state"):
		var state: Node = parts["state"]
		root.remove_child(state)
		state.free()


## 開始画面の「商いを始める」を押す（= closed が飛ぶ）。
func _press_start(main: Node) -> void:
	var dialog: Node = UiUtil.find_node(main, "BriefingDialog")
	if dialog == null:
		_check(false, "BriefingDialog がある", "ない")
		return
	var button: Button = dialog.find_child("StartButton", true, false)
	if button == null:
		_check(false, "StartButton がある", "ない")
		return
	button.pressed.emit()


func _hud_day_text(main: Node) -> String:
	var hud: Node = UiUtil.find_node(main, "HUD")
	if hud == null:
		return ""
	var label: Label = hud.find_child("DayLabel", true, false) as Label
	return label.text if label != null else ""


func _log_count(main: Node) -> int:
	var list: Node = UiUtil.find_node(main, "LogList")
	return list.get_child_count() if list != null else 0


# --- 検査 ---

## この設計そのものの回帰を止める。main.gd に GameState. を書き戻すと落ちる。
func _test_main_loads() -> void:
	print("--- main.gd が --script でも扱えること ---")
	var script: Script = load("res://scenes/main/main.gd") as Script
	_check(script != null, "main.gd をロードできる", "できない")
	if script != null:
		_check(script.can_instantiate(), "インスタンス化できる", "できない")

	var parts: Dictionary = _make_main(19001)
	_check(not parts.is_empty(), "Main.tscn を立てて状態を差し込める", "失敗")
	if parts.is_empty():
		return
	var main: Node = parts["main"]
	_check(main.get_script() != null, "立てた Main にスクリプトが付いている", "付いていない")
	# 差し込んだセッションが配られ、HUD に出ている。
	_check(_hud_day_text(main).contains("1日目"), "HUD に1日目が出る",
		_hud_day_text(main))
	_teardown(parts)


## 開始画面を閉じる経路1: 新規開始。そのセッションで保存される。
func _test_briefing_new_game() -> void:
	print("--- 開始画面を閉じる（新規開始） ---")
	SaveManager.delete_save(TEST_PATH)
	var parts: Dictionary = _make_main(19002)
	if parts.is_empty():
		return
	var main: Node = parts["main"]

	_check(not SaveManager.has_save(TEST_PATH), "閉じる前はセーブが無い", "ある")
	_press_start(main)
	_check(SaveManager.has_save(TEST_PATH), "閉じるとセーブが出来る", "出来ない")

	var saved: GameSession = SaveManager.load_game(TEST_PATH)
	_check(saved != null, "そのセーブを読める", SaveManager.last_error())
	if saved != null:
		# 1日目**でなければならない**（1以上ではない）。
		_check(saved.day == 1, "保存されたのは1日目", str(saved.day))
		_check(saved.silver == GameData.INITIAL_SILVER, "初期シルバーで保存される",
			str(saved.silver))

	# 新規開始の入口は一度しか効かない。閉じた後にもう一度 closed が飛んでも
	# 保存し直さない（_briefing_starts_play を倒しているか）。
	var state: Node = parts["state"]
	state.session.rest()
	var day_after_rest: int = state.session.day
	SaveManager.delete_save(TEST_PATH)
	_press_start(main)
	_check(not SaveManager.has_save(TEST_PATH),
		"二度目に閉じても保存しない（入口は一度きり）", "保存された")
	_check(day_after_rest == 2, "検査の前提: 1日進めている", str(day_after_rest))

	_teardown(parts)
	SaveManager.delete_save(TEST_PATH)


## 開始画面を閉じる経路2: 目標の読み返し。**セーブに触らない。**
func _test_briefing_reread() -> void:
	print("--- 開始画面を閉じる（目標の読み返し） ---")
	var parts: Dictionary = _make_main(19003)
	if parts.is_empty():
		return
	var main: Node = parts["main"]
	var state: Node = parts["state"]

	# 進んだ状態を保存しておく。
	for i: int in 5:
		state.session.rest()
	state.save_game()
	var before: GameSession = SaveManager.load_game(TEST_PATH)
	_check(before != null and before.day > 1, "進んだ状態のセーブがある",
		str(before.day) if before != null else "無い")
	if before == null:
		_teardown(parts)
		return

	# HUD の「目標」ボタンから開き直して閉じる。
	var briefing_button: Button = UiUtil.find_node(main, "BriefingButton") as Button
	_check(briefing_button != null, "目標ボタンがある", "ない")
	if briefing_button != null:
		briefing_button.pressed.emit()
		_press_start(main)

	var after: GameSession = SaveManager.load_game(TEST_PATH)
	_check(after != null, "読み返しの後もセーブが残る", SaveManager.last_error())
	if after != null:
		# 「残っている」だけでは弱い。完全一致を見る。
		_check(after.day == before.day, "読み返しても日付が変わらない",
			"%d / %d" % [after.day, before.day])
		_check(after.silver == before.silver, "読み返してもシルバーが変わらない",
			"%d / %d" % [after.silver, before.silver])

	_teardown(parts)
	SaveManager.delete_save(TEST_PATH)


## 「続きから」が成功する経路。
func _test_continue_success() -> void:
	print("--- 続きから（成功） ---")
	# まず進んだセーブを作る。
	var seed_parts: Dictionary = _make_main(19004)
	if seed_parts.is_empty():
		return
	var seed_state: Node = seed_parts["state"]
	for i: int in 6:
		seed_state.session.rest()
	seed_state.save_game()
	var saved_day: int = seed_state.session.day
	_teardown(seed_parts)

	# 別の main を立て、続きからを押す。
	var main_node: Node = _spawn("res://scenes/main/Main.tscn")
	if main_node == null:
		return
	var state: Node = GameStateScript.new()
	state.name = "GameState"
	state.use_save_path(TEST_PATH)
	root.add_child(state)
	# ここでは start_new_game() を呼ばない（セーブを消してしまうため）。
	# 起動直後と同じく1日目のセッションを持たせる。
	state.set("session", GameSession.new(19005))
	main_node.bind_state(state)

	var dialog: Node = UiUtil.find_node(main_node, "BriefingDialog")
	var continue_button: Button = dialog.find_child("ContinueButton", true, false) if dialog != null else null
	_check(continue_button != null, "続きからボタンがある", "ない")
	if continue_button != null:
		continue_button.pressed.emit()

	_check(state.session.day == saved_day, "保存した日から再開する",
		"%d / %d" % [state.session.day, saved_day])
	_check(_hud_day_text(main_node).contains("%d日目" % saved_day),
		"HUD が復帰後の日を出す（配り直しが起きている）", _hud_day_text(main_node))
	# 復帰した直後に開始画面をもう一度開かない。
	if dialog != null:
		_check(not dialog.visible, "復帰後に開始画面が開かない", "開いている")

	_despawn(main_node)
	root.remove_child(state)
	state.free()
	SaveManager.delete_save(TEST_PATH)


## 「続きから」が失敗する経路。セッションを切ったまま放置しない。
func _test_continue_failure() -> void:
	print("--- 続きから（失敗） ---")
	SaveManager.delete_save(TEST_PATH)
	var parts: Dictionary = _make_main(19006)
	if parts.is_empty():
		return
	var main: Node = parts["main"]
	var state: Node = parts["state"]

	# start_new_game() がセーブを消しているので、読むものが無い状態。
	_check(not SaveManager.has_save(TEST_PATH), "セーブが無い状態にできている", "ある")
	var before_day: int = state.session.day
	var session_before: GameSession = state.session

	var dialog: Node = UiUtil.find_node(main, "BriefingDialog")
	if dialog != null:
		dialog.continue_requested.emit()

	_check(state.session == session_before, "失敗してもセッションが差し替わらない",
		"差し替わった")
	_check(state.session.day == before_day, "日付も変わらない", str(state.session.day))

	# **切断されたままになっていないこと。** ここが要点で、読み込みの前に
	# 切ると日誌もパネル更新も止まる。rest() して日誌が伸びるかで見る。
	var log_before: int = _log_count(main)
	state.session.rest()
	_check(_log_count(main) > log_before,
		"失敗後もセッションが生きている（日誌が伸びる）",
		"%d -> %d" % [log_before, _log_count(main)])

	_teardown(parts)
	SaveManager.delete_save(TEST_PATH)


## 再プレイ。古いセッションのシグナルが切れていること。
func _test_restart() -> void:
	print("--- 再プレイ ---")
	var parts: Dictionary = _make_main(19007)
	if parts.is_empty():
		return
	var main: Node = parts["main"]
	var state: Node = parts["state"]

	for i: int in 4:
		state.session.rest()
	var old_session: GameSession = state.session
	_check(old_session.day > 1, "検査の前提: 進んでいる", str(old_session.day))

	var result: Node = UiUtil.find_node(main, "ResultDialog")
	_check(result != null, "ResultDialog がある", "ない")
	if result != null:
		result.restart_requested.emit()

	_check(state.session != old_session, "新しいセッションに差し替わる", "同じまま")
	_check(state.session.day == 1, "1日目から始まる", str(state.session.day))
	# 日誌は空になる。「減った」ではなく 0 を見る。
	_check(_log_count(main) == 0, "日誌が空になる", str(_log_count(main)))

	# **古いセッションのシグナルが切れている。** これが _disconnect_session() の
	# 効き目そのもので、これまで一切検査できていなかった。
	old_session.rest()
	_check(_log_count(main) == 0, "古いセッションのログが混ざらない",
		str(_log_count(main)))

	_teardown(parts)
	SaveManager.delete_save(TEST_PATH)


## 日送りの自動保存と、60日終了でセーブが消えること。
func _test_autosave() -> void:
	print("--- 日送りの自動保存 ---")
	SaveManager.delete_save(TEST_PATH)
	var parts: Dictionary = _make_main(19008)
	if parts.is_empty():
		return
	var main: Node = parts["main"]
	var state: Node = parts["state"]

	state.session.rest()
	_check(SaveManager.has_save(TEST_PATH), "日が進むと自動保存される", "されない")
	var saved: GameSession = SaveManager.load_game(TEST_PATH)
	_check(saved != null and saved.day == state.session.day,
		"保存された日が現在の日と一致する",
		"%d / %d" % [saved.day if saved != null else -1, state.session.day])

	# 実物の保存経路でも RNG state が 64bit のまま往復する。
	if saved != null:
		_check(str(saved.to_dict()["rng"]["state"]) == str(state.session.to_dict()["rng"]["state"]),
			"実物の保存経路でも RNG state が往復する", "ずれた")

	# 60日を終えるとセーブが消える（最終日をやり直せない）。
	while not state.session.is_over():
		state.session.rest()
	_check(state.session.is_over(), "60日を終えた", str(state.session.day))
	_check(not SaveManager.has_save(TEST_PATH),
		"終了するとセーブが消える（最終日をやり直せない）", "残っている")

	# 画面も終了状態になる。
	var rest_button: Button = UiUtil.find_node(main, "RestButton") as Button
	if rest_button != null:
		_check(rest_button.disabled, "休息ボタンが無効になる", "押せるまま")
	var status: Label = UiUtil.find_node(main, "StatusLabel") as Label
	if status != null:
		_check(status.text.contains("60日が終了"), "終了の案内が出る", status.text)

	_teardown(parts)
	SaveManager.delete_save(TEST_PATH)
