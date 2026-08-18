extends "res://scripts/systems/scenario_base.gd"
## M33 の検証シナリオ。売買ボタンの長押しによる連続取引を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m33.gd
##
## ツリー外では _process が走らないため、時間の経過は advance_hold(delta) を
## 直接呼んで作る。押した回数ではなく**押していた長さ**で個数が決まるので、
## 「増えるか」ではなく刻み（待ち・加速・頭打ち）を数で押さえる。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketPanel = preload("res://scripts/ui/market_panel.gd")


func _init() -> void:
	_test_press_still_buys_one()
	_test_hold_delay_before_repeat()
	_test_hold_accelerates()
	_test_release_stops_and_resets()
	_test_hold_stops_when_exhausted()
	_test_hold_sells()
	_finish()


## 長押しの土台。押して離すだけの操作は今までどおり1個でなければならない。
func _test_press_still_buys_one() -> void:
	print("--- 押して離すと1個だけ ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(33001)
	panel.bind(session)
	var item_id: String = _buyable_item(panel, session)

	var button: Button = panel.buy_button_for(item_id)
	# 実際の操作の順序をなぞる: button_down → (すぐ離す) → button_up → pressed。
	button.button_down.emit()
	button.button_up.emit()
	button.pressed.emit()
	_check(session.cargo_count(item_id) == 1, "押して離すと1個だけ買う",
		str(session.cargo_count(item_id)))
	_check(not panel.is_holding(), "離せば長押しは終わっている", "続いている")

	_despawn(panel)


## 押した直後は連射しない。ここが 0 だと「1個だけ」が2個になる。
func _test_hold_delay_before_repeat() -> void:
	print("--- 押し始めは待ってから連射する ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(33002)
	panel.bind(session)
	var item_id: String = _buyable_item(panel, session)

	var button: Button = panel.buy_button_for(item_id)
	button.button_down.emit()
	button.pressed.emit()
	var after_press: int = session.cargo_count(item_id)
	_check(after_press == 1, "押した時点では1個", str(after_press))

	# 待ちの手前までは1個も増えない。定数を直書きせず HOLD_DELAY から引く。
	var traded: int = panel.advance_hold(MarketPanel.HOLD_DELAY * 0.5)
	_check(traded == 0, "待ちの途中では連射しない", "%d個" % traded)
	_check(session.cargo_count(item_id) == after_press, "個数も増えない",
		str(session.cargo_count(item_id)))

	# 待ちを越えると連射が始まる。
	traded = panel.advance_hold(MarketPanel.HOLD_DELAY)
	_check(traded >= 1, "待ちを越えると連射が始まる", "%d個" % traded)

	_despawn(panel)


## 押し続けるほど速くなる。同じ長さでも後半のほうが多く取引される。
func _test_hold_accelerates() -> void:
	print("--- 押し続けると加速する ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	# 在庫と資金で頭打ちにならないよう、加速の観測は取引を通さずに
	# 間隔そのものを見る（買えなくなると長押しが打ち切られ、加速も止まるため）。
	var session: GameSession = GameSession.new(33003)
	panel.bind(session)
	var item_id: String = _buyable_item(panel, session)

	var button: Button = panel.buy_button_for(item_id)
	button.button_down.emit()
	var first_interval: float = panel.hold_interval()
	_check(is_equal_approx(first_interval, MarketPanel.HOLD_INTERVAL_MAX),
		"押し始めの間隔は最も遅い", str(first_interval))

	# 待ちを越えて数個取引させ、間隔が詰まることを見る。
	panel.advance_hold(MarketPanel.HOLD_DELAY + MarketPanel.HOLD_INTERVAL_MAX * 3.0)
	var later_interval: float = panel.hold_interval()
	_check(later_interval < first_interval, "取引するほど間隔が詰まる",
		"%f → %f" % [first_interval, later_interval])
	_check(later_interval >= MarketPanel.HOLD_INTERVAL_MIN,
		"間隔は下限を割らない", str(later_interval))

	# 長く押し続けても下限で頭打ちになる。青天井だと1フレームに何十個も入る。
	panel.advance_hold(10.0)
	_check(panel.hold_interval() >= MarketPanel.HOLD_INTERVAL_MIN,
		"押し続けても下限で止まる", str(panel.hold_interval()))

	_despawn(panel)


## 離したら止まり、次に押したときは速度も待ちもやり直す。
func _test_release_stops_and_resets() -> void:
	print("--- 離すと止まり、速度も戻る ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(33004)
	panel.bind(session)
	var item_id: String = _buyable_item(panel, session)

	var button: Button = panel.buy_button_for(item_id)
	button.button_down.emit()
	panel.advance_hold(MarketPanel.HOLD_DELAY + MarketPanel.HOLD_INTERVAL_MAX * 3.0)
	_check(panel.hold_interval() < MarketPanel.HOLD_INTERVAL_MAX,
		"離す前は加速している", str(panel.hold_interval()))

	button.button_up.emit()
	_check(not panel.is_holding(), "離せば長押しが終わる", "続いている")

	# 離した後は時間が経っても増えない。
	var held_before: int = session.cargo_count(item_id)
	var traded: int = panel.advance_hold(5.0)
	_check(traded == 0, "離した後は時間が経っても取引しない", "%d個" % traded)
	_check(session.cargo_count(item_id) == held_before, "個数も変わらない",
		str(session.cargo_count(item_id)))

	# 押し直すと最も遅い間隔から始まる（速いまま持ち越さない）。
	button.button_down.emit()
	_check(is_equal_approx(panel.hold_interval(), MarketPanel.HOLD_INTERVAL_MAX),
		"押し直すと速度が戻る", str(panel.hold_interval()))
	# 待ちもやり直す。持ち越すと押した瞬間に走り出す。
	traded = panel.advance_hold(MarketPanel.HOLD_DELAY * 0.5)
	_check(traded == 0, "押し直すと待ちもやり直す", "%d個" % traded)

	_despawn(panel)


## 買えなくなったら長押しは自動で終わる。押しっぱなしの状態が残ると、
## 在庫が戻った瞬間に指を離した後なのに取引が再開してしまう。
func _test_hold_stops_when_exhausted() -> void:
	print("--- 買えなくなれば長押しは終わる ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(33005)
	panel.bind(session)
	var item_id: String = _buyable_item(panel, session)

	var button: Button = panel.buy_button_for(item_id)
	button.button_down.emit()
	# 在庫・積載・資金のいずれかが尽きるまで十分長く押す。
	panel.advance_hold(600.0)
	_check(session.max_buyable(item_id) == 0, "押し続けて買えなくなった",
		str(session.max_buyable(item_id)))
	_check(not panel.is_holding(), "買えなくなれば長押しが終わる", "続いている")

	_despawn(panel)


## 売る側も同じ刻みで動く。買う側だけ直して売る側を忘れる形を防ぐ。
func _test_hold_sells() -> void:
	print("--- 売るボタンも長押しで売り続ける ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(33006)
	panel.bind(session)
	var item_id: String = _buyable_item(panel, session)

	# 売るものを用意する。長押しで買ってから、そのまま売りに回す。
	var buy_button: Button = panel.buy_button_for(item_id)
	buy_button.button_down.emit()
	panel.advance_hold(MarketPanel.HOLD_DELAY + 2.0)
	buy_button.button_up.emit()
	var stocked: int = session.cargo_count(item_id)
	_check(stocked >= 3, "売る分を長押しで仕入れられた", str(stocked))

	var sell_button: Button = panel.sell_button_for(item_id)
	sell_button.button_down.emit()
	var traded: int = panel.advance_hold(MarketPanel.HOLD_DELAY * 0.5)
	_check(traded == 0, "売る側も押し始めは待つ", "%d個" % traded)

	traded = panel.advance_hold(MarketPanel.HOLD_INTERVAL_MAX * 4.0)
	_check(traded >= 1, "待ちを越えると売り続ける", "%d個" % traded)
	_check(session.cargo_count(item_id) < stocked, "所持数が減る",
		"%d → %d" % [stocked, session.cargo_count(item_id)])

	sell_button.button_up.emit()
	_check(not panel.is_holding(), "離せば売りも止まる", "続いている")

	_despawn(panel)


## その都市で実際に買える品目を選ぶ。品目名を直書きすると、在庫の配り方を
## 変えたときに「買えない品目で長押しを試す」空回りの検査になる。
func _buyable_item(panel: Node, session: GameSession) -> String:
	for item_id: String in GameData.ITEMS:
		if session.max_buyable(item_id) > 0 and panel.buy_button_for(item_id) != null:
			return item_id
	return GameData.ITEMS.keys()[0]
