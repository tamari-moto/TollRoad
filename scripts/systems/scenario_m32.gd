extends "res://scripts/systems/scenario_base.gd"
## 市場デバッグ画面を別ウィンドウにしたこと（debug_window.gd）の検証。
##
## 中身の一覧そのものは scenario_m26.gd / scenario_m29.gd が既に見ている。
## ここで見るのは**窓にしたことで新しく壊れうる所**だけで、3つある。
## どれも壊れても画面は動いたまま（＝目視で気づきにくい）。
##
##   1. **埋め込みに落ちていないこと。** force_native は「表示中」だと
##      setter が代入を捨てる。Window は visible=true で生まれるので、
##      先に隠さないと必ず捨てられる。落ちると窓は出るが本編の中に
##      埋め込まれ、オーバーレイに戻る（F5 の窓で実際に踏んだ）。
##
##   2. **本編の隣に置かれること。** get_window() は Window 自身を返すため、
##      自分の位置に offset を足す形になり (0,0) に取り残される。
##      本編が原点の近くにあると真上に重なり、別窓にした意味が消える
##      （これも F5 の窓で実際に踏んだ。同じ轍を踏まないよう見張る）。
##
##   3. **「×」で窓ごと閉じること。** パネルは自前の「×」を持っており、
##      繋ぎ替えないとパネルだけが消えて**空の窓が残る**。しかもパネルは
##      単体（オーバーレイ）でも使えなければならず、両立を確かめる必要がある。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m32.gd

const GameSession = preload("res://scripts/systems/game_session.gd")
const DebugPanel = preload("res://scripts/ui/debug_panel.gd")
const DebugWindow = preload("res://scripts/ui/debug_window.gd")

## シードは固定する（物流が RNG を消費するため。scenario_m31.gd と同じ理由）。
const SEED: int = 20260817


func _init() -> void:
	_test_window_is_native_and_not_exclusive()
	_test_window_sits_beside_main()
	_test_window_offset_differs_from_logistics()
	_test_close_button_closes_the_window()
	_test_panel_alone_still_hides_itself()
	_test_toggle_and_bind_pass_through()
	_finish()


## 別ウィンドウとして組まれること。
##
## **root へ入れない。** Window はツリーに入った時点で実体を作りにいくので、
## ヘッドレスの検査で native のウィンドウを開こうとすることになる。ここで
## 見たいのは「どう組まれているか」だけなので、ツリー外のまま確かめる。
func _test_window_is_native_and_not_exclusive() -> void:
	print("--- ウィンドウ: 別ウィンドウとして組まれる ---")

	var window := DebugWindow.new()

	# ここが false だと本編のウィンドウの中に埋め込まれる＝オーバーレイに戻る。
	# 見た目では「窓っぽいもの」が出るので、目視では気づきにくい。
	_check(window.force_native, "OS の別ウィンドウとして出す設定になっている",
		"force_native=%s" % window.force_native)
	_check(not window.exclusive,
		"排他ではない（本編が入力を受け取り続ける）",
		"exclusive=%s" % window.exclusive)
	_check(not window.transient,
		"追従しない（別モニタへ出して置いておける）",
		"transient=%s" % window.transient)

	_check(window.panel() != null, "中身のパネルを抱えている", "null")
	_check(window.size == DebugWindow.DEFAULT_SIZE,
		"開いたときの大きさが既定と一致する", str(window.size))

	# パネルの実寸（1080x720）が入る大きさであること。窓の方が小さいと
	# 一覧が切れ、都市どうしの比較ができなくなる。
	_check(float(window.size.x) >= DebugPanel.PANEL_SIZE.x
			and float(window.size.y) >= DebugPanel.PANEL_SIZE.y,
		"窓がパネルの実寸を収められる",
		"窓 %s / パネル %s" % [window.size, DebugPanel.PANEL_SIZE])

	# F3 は閉じた状態で始まる（F5 と違い、遡って見返す記録を持たないため）。
	_check(not DebugWindow.OPEN_ON_START,
		"起動時は閉じている", str(DebugWindow.OPEN_ON_START))
	_check(window.visible == DebugWindow.OPEN_ON_START,
		"起動直後の開閉が OPEN_ON_START と一致する", str(window.visible))

	window.free()


## 開いたときに本編の窓の隣へ置かれること。
##
## 検査には親の窓が要る（本編の位置を引く先）。root へ入れると native の窓を
## 開きにいくので、ホストの Window をツリー外で組んでそこへ吊る。
func _test_window_sits_beside_main() -> void:
	print("--- ウィンドウ: 本編の隣へ置かれる ---")

	var host := Window.new()
	host.position = Vector2i(400, 300)

	var window := DebugWindow.new()
	host.add_child(window)
	window.show_window()

	var expected: Vector2i = host.position + DebugWindow.POSITION_OFFSET
	_check(window.position == expected,
		"本編の窓の右下へずらして置かれる",
		"実際 %s / 期待 %s" % [window.position, expected])
	# 自分を見ていると (0,0) のままになる。
	_check(window.position != Vector2i.ZERO,
		"画面の左上に取り残されない", str(window.position))

	# 一度置いたら動かさない。見ている途中で窓が飛ぶと、どこを見ていたか
	# 分からなくなる。
	var moved := Vector2i(50, 60)
	window.position = moved
	window.hide_window()
	window.show_window()
	_check(window.position == moved,
		"二度目に開いても位置を動かさない（見ていた所を保つ）",
		str(window.position))

	host.free()


## F3 と F5 の窓が完全には重ならないこと。
##
## 同じ offset だと両方開いたときに後から開いた方が先の方を隠し、
## 「開いたのに出てこない」ように見える。
func _test_window_offset_differs_from_logistics() -> void:
	print("--- ウィンドウ: F5 の窓と重ならない ---")

	var logistics_offset: Vector2i = load(
		"res://scripts/ui/logistics_debug_window.gd").POSITION_OFFSET
	_check(DebugWindow.POSITION_OFFSET != logistics_offset,
		"F3 と F5 で初期位置がずれている",
		"F3 %s / F5 %s" % [DebugWindow.POSITION_OFFSET, logistics_offset])


## パネルの「×」が、パネルだけでなく窓ごと閉じること。
##
## 繋ぎ替えを忘れると visible=false になるのはパネルの方で、**中身の無い窓が
## 残る**。窓は開いたままなので「閉じない」と見え、閉じ方も分からなくなる。
func _test_close_button_closes_the_window() -> void:
	print("--- 「×」: 窓ごと閉じる ---")

	var window := DebugWindow.new()
	window.show_window()
	_check(window.visible, "前提: 開いている", str(window.visible))

	var panel: DebugPanel = window.panel()
	panel.press_close()

	_check(not window.visible, "「×」で窓が閉じる", str(window.visible))
	# パネル側が隠れていると、次に開いたとき中身が出てこない。
	_check(panel.visible,
		"パネル自身は隠れない（次に開いたとき中身が出る）", str(panel.visible))

	window.free()


## パネル単体（オーバーレイ）では、これまでどおり自分を隠すこと。
##
## 窓に入れるために「×」を signal へ回したので、**誰も繋いでいない場合に
## 何も起きなくなる**という壊し方がありうる。パネルは本編以外からも
## 単体で使える形を保っている（scenario_m26 / m29 がその形で触る）。
func _test_panel_alone_still_hides_itself() -> void:
	print("--- パネル単体: 「×」で自分を隠す ---")

	var panel := DebugPanel.new()
	panel.visible = true
	panel.press_close()

	_check(not panel.visible,
		"窓に入っていなければ自分を隠す（従来どおり）", str(panel.visible))

	panel.free()


## 開閉と bind が窓を素通ししてパネルへ届くこと。
func _test_toggle_and_bind_pass_through() -> void:
	print("--- 窓: 開閉と bind を素通しする ---")

	var window := DebugWindow.new()

	var before: bool = window.visible
	window.toggle_visible()
	_check(window.visible != before, "F3（toggle_visible）で開閉が反転する",
		"%s → %s" % [before, window.visible])
	window.toggle_visible()
	_check(window.visible == before, "もう一度で戻る", str(window.visible))

	var session := GameSession.new(SEED)
	window.bind(session)
	_check(window.panel().session() == session,
		"bind したセッションがパネルまで届く", "届いていない")

	window.free()
