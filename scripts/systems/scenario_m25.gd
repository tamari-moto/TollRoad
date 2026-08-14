extends "res://scripts/systems/scenario_base.gd"
## 日送りランダムイベント（シルバー・物資の増減）の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m25.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const Sfx = preload("res://scripts/ui/sfx.gd")


func _init() -> void:
	_test_event_occurs()
	_test_event_variants()
	_test_silver_never_negative()
	_test_cargo_within_capacity()
	_test_severity_by_message()
	_test_chance_varies_by_specialty()
	_finish()


## logged シグナルが受け取った (本文, 種別) を溜める。
var _seen: Array = []


func _on_logged(message: String, kind: int) -> void:
	_seen.append([message, kind])


func _logged_from(session: GameSession, action: Callable) -> Array:
	_seen = []
	session.logged.connect(_on_logged)
	action.call()
	session.logged.disconnect(_on_logged)
	return _seen


## 最初に見つかった EVENT 種別の行の本文を返す（無ければ空文字）。
func _first_event_message(entries: Array) -> String:
	for entry: Array in entries:
		if entry[1] == GameSession.LogKind.EVENT:
			return entry[0]
	return ""


## 積荷を持たせておくと荷崩れ（cargo_loss）も出せる。現在地の specialty を
## 少量買っておくだけで十分（襲撃と違い黒ゾーン移動は要らない）。
func _new_session_with_cargo(seed_value: int) -> GameSession:
	var session: GameSession = GameSession.new(seed_value)
	var specialty: String = GameData.CITIES[session.current_city]["specialty"]
	if specialty != "":
		session.buy(specialty, 3)
	return session


## rest() で本文に keyword を含む EVENT が出る seed を探す。無ければ -1。
func _find_seed_for(keyword: String, max_seed: int) -> int:
	for seed_value: int in range(1, max_seed):
		var session: GameSession = _new_session_with_cargo(seed_value)
		var entries: Array = _logged_from(session, func() -> void: session.rest())
		if _first_event_message(entries).contains(keyword):
			return seed_value
	return -1


func _test_event_occurs() -> void:
	print("--- 日送りでイベントが発生する ---")
	var found: bool = false
	for seed_value: int in range(1, 500):
		var session: GameSession = _new_session_with_cargo(seed_value)
		var entries: Array = _logged_from(session, func() -> void: session.rest())
		if not _first_event_message(entries).is_empty():
			found = true
			break
	_check(found, "500seed以内に少なくとも1回イベントが発生する", str(found))


func _test_event_variants() -> void:
	print("--- イベントの種類（シルバー・物資の増減） ---")
	for keyword: String in ["受け取った", "馬車の修理", "譲り受けた", "荷崩れ"]:
		var seed_value: int = _find_seed_for(keyword, 4000)
		_check(seed_value >= 0, "「%s」を含むイベントが発生する seed が見つかる" % keyword,
			str(seed_value))


func _test_silver_never_negative() -> void:
	print("--- シルバーが負にならない ---")
	var seed_value: int = _find_seed_for("馬車の修理", 4000)
	if seed_value < 0:
		_check(false, "シルバー減少イベントの seed が見つかる", "見つからない")
		return
	var session: GameSession = _new_session_with_cargo(seed_value)
	session.silver = 10
	session.rest()
	_check(session.silver >= 0, "シルバーが負にならない", str(session.silver))


func _test_cargo_within_capacity() -> void:
	print("--- 積荷が積載量を超えない ---")
	var seed_value: int = _find_seed_for("譲り受けた", 4000)
	if seed_value < 0:
		_check(false, "物資獲得イベントの seed が見つかる", "見つからない")
		return
	var session: GameSession = GameSession.new(seed_value)
	session.silver = 100000000
	var item_id: String = GameData.CITIES[session.current_city]["specialty"]
	if item_id == "":
		item_id = "ore"
	# 積荷をほぼ満杯にしてからイベントを発生させる。容量超過分は
	# _grant_item() の既存挙動でシルバーに換わり、積載量を超えないはず。
	while session.free_capacity() >= GameData.ITEMS[item_id]["weight"]:
		if not session.buy(item_id, 1):
			break
	session.rest()
	_check(session.cargo_weight() <= session.capacity(), "積荷が積載量を超えない",
		"%d / %d" % [session.cargo_weight(), session.capacity()])


func _test_severity_by_message() -> void:
	print("--- 悪いイベントだけ警戒色になる ---")
	_check(Sfx.is_severe_log_kind(GameSession.LogKind.EVENT, "馬車の修理でシルバーを100失った。"),
		"シルバーを失うイベントは警戒色", "false")
	_check(Sfx.is_severe_log_kind(GameSession.LogKind.EVENT, "荷崩れで木材を2個失った。"),
		"物資を失うイベントは警戒色", "false")
	_check(not Sfx.is_severe_log_kind(GameSession.LogKind.EVENT,
		"行商人に道を教え、礼として100シルバーを受け取った。"),
		"シルバーを得るイベントは警戒色でない", "true")
	_check(Sfx.sound_for_log_kind(GameSession.LogKind.EVENT) == Sfx.Kind.EVENT,
		"EVENT に音が対応する", str(Sfx.sound_for_log_kind(GameSession.LogKind.EVENT)))


## 都市の specialty によって発生率が変わることを、実際に発生回数を数えて確かめる。
## アイアンホロウ（ore: 12%）とウィンダム（clay: 8%）で比較する。
func _test_chance_varies_by_specialty() -> void:
	print("--- 都市によって発生率が変わる ---")
	const TRIALS: int = 500
	var count_high: int = 0
	var count_low: int = 0
	for seed_value: int in range(1, TRIALS + 1):
		var stay_session: GameSession = GameSession.new(seed_value)
		var stay_entries: Array = _logged_from(stay_session, func() -> void: stay_session.rest())
		if not _first_event_message(stay_entries).is_empty():
			count_high += 1

		var moved_session: GameSession = GameSession.new(seed_value)
		moved_session.silver = 1000000
		moved_session.move_to("wyndham")
		var moved_entries: Array = _logged_from(moved_session, func() -> void: moved_session.rest())
		if not _first_event_message(moved_entries).is_empty():
			count_low += 1

	_check(count_high > count_low,
		"アイアンホロウ(%d件)がウィンダム(%d件)より発生しやすい" % [count_high, count_low],
		"%d vs %d" % [count_high, count_low])
