extends "res://scripts/systems/scenario_base.gd"
## 探索の検証。成功率の算出式、報酬、失敗時のリスク、島倉庫ブースト、
## セーブ/ロードの往復を確かめる。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m20.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")


func _init() -> void:
	_test_city_flavors()
	_test_chance_formula()
	_test_ravenspire_penalty()
	_test_success_rate()
	_test_reward_bounds()
	_test_capacity_safety()
	_test_failure()
	_test_day_and_over()
	_test_boost()
	_test_save_round_trip()
	_finish()


func _test_city_flavors() -> void:
	print("--- 都市ごとの探索フレーバー ---")
	for city_id: String in GameData.CITIES:
		var flavor: String = GameData.CITIES[city_id].get("explore_flavor", "")
		_check(flavor != "", "%s に探索フレーバーがある" % city_id, "ない")


func _test_chance_formula() -> void:
	print("--- 成功率の算出式 ---")
	var s: GameSession = GameSession.new(20001)
	_check(is_equal_approx(s.explore_chance(), GameData.EXPLORE_BASE_CHANCE),
		"装備なしは基本確率のまま", str(s.explore_chance()))

	s.buy("sword", 1)
	_check(s.cargo_count("sword") == 1, "検査の前提: 剣を1個買えた", str(s.cargo_count("sword")))
	_check(is_equal_approx(s.explore_chance(),
			GameData.EXPLORE_BASE_CHANCE + GameData.EXPLORE_EQUIP_BONUS_PER_UNIT),
		"装備1個で+3%相当のボーナス", str(s.explore_chance()))

	s.buy("sword", 5)
	_check(s.cargo_count("sword") >= GameData.EXPLORE_EQUIP_UNIT_CAP,
		"検査の前提: 剣を頭打ち数以上持っている", str(s.cargo_count("sword")))
	_check(is_equal_approx(s.explore_chance(),
			GameData.EXPLORE_BASE_CHANCE + GameData.EXPLORE_EQUIP_UNIT_CAP * GameData.EXPLORE_EQUIP_BONUS_PER_UNIT),
		"同種の装備は頭打ち数までしか加算されない", str(s.explore_chance()))

	# 種類を跨ぐとボーナスが伸びるが、合計は上限でクランプされる。
	# ここで見たいのは explore_chance() のクランプ式そのものであり、市場から
	# 買い集める経済的な妥当性ではない（装備の生産地は都市ごとに1種類しかなく、
	# IMPORT_INITIAL_RATIO=0.0 の下では初日に全種類を1都市でまとめ買いできない）。
	# そのため cargo を直接積んで前提を作る。
	var s2: GameSession = GameSession.new(20002)
	s2.silver = 999999
	s2.buy_mount("mammoth")
	for item_id: String in GameData.EXPLORE_COMBAT_ITEMS:
		s2.cargo[item_id] = GameData.EXPLORE_EQUIP_UNIT_CAP
	var uncapped_bonus: float = GameData.EXPLORE_COMBAT_ITEMS.size() * GameData.EXPLORE_EQUIP_UNIT_CAP * GameData.EXPLORE_EQUIP_BONUS_PER_UNIT
	_check(uncapped_bonus > GameData.EXPLORE_EQUIP_BONUS_CAP,
		"検査の前提: クランプ無しなら上限を超える", str(uncapped_bonus))
	_check(is_equal_approx(s2.explore_chance(), GameData.EXPLORE_BASE_CHANCE + GameData.EXPLORE_EQUIP_BONUS_CAP),
		"ボーナス合計は上限でクランプされる", str(s2.explore_chance()))


func _test_ravenspire_penalty() -> void:
	print("--- レイヴンスパイアのペナルティ ---")
	var s: GameSession = GameSession.new(20003)
	if s.current_city != GameData.CAERLEON:
		s.move_to(GameData.CAERLEON)
	_check(s.current_city == GameData.CAERLEON, "検査の前提: レイヴンスパイアにいる", s.current_city)
	_check(is_equal_approx(s.explore_chance(), GameData.EXPLORE_BASE_CHANCE - GameData.EXPLORE_CAERLEON_PENALTY),
		"レイヴンスパイアは基本確率が下がる", str(s.explore_chance()))


func _test_success_rate() -> void:
	print("--- 成功率の実測（1000回・装備なし） ---")
	var trials: int = 1000
	var successes: int = 0
	for i: int in trials:
		var s: GameSession = GameSession.new(21000 + i)
		s.explore()
		if s.log_entries[-1].contains("探索成功"):
			successes += 1
	var rate: float = float(successes) / float(trials)
	_check(absf(rate - GameData.EXPLORE_BASE_CHANCE) < 0.05, "実測成功率が基本確率に近い",
		"%.1f%%（期待 %.1f%%）" % [rate * 100.0, GameData.EXPLORE_BASE_CHANCE * 100.0])


func _test_reward_bounds() -> void:
	print("--- 報酬の範囲（200回） ---")
	var min_gem: int = 999
	var max_gem: int = -999
	var min_gain: int = 999999999
	var trials_succeeded: int = 0
	for i: int in 200:
		var s: GameSession = GameSession.new(22000 + i)
		var silver_before: int = s.silver
		s.explore()
		if not s.log_entries[-1].contains("探索成功"):
			continue
		trials_succeeded += 1
		var gem: int = s.cargo_count("sunstone")
		min_gem = mini(min_gem, gem)
		max_gem = maxi(max_gem, gem)
		min_gain = mini(min_gain, s.silver - silver_before)
	_check(trials_succeeded > 0, "成功する試行がある", "0件")
	_check(min_gem >= GameData.EXPLORE_GEM_MIN, "陽光石の最小個数が範囲内", str(min_gem))
	_check(max_gem <= GameData.EXPLORE_GEM_MAX, "陽光石の最大個数が範囲内", str(max_gem))
	_check(min_gain >= GameData.EXPLORE_SILVER_MIN, "シルバー報酬が最低額以上", str(min_gain))


## free_capacity() が常に非負であるという他の計算（max_withdrawable() 等）の
## 前提を、探索の報酬付与が崩していないこと。
func _test_capacity_safety() -> void:
	print("--- 積載超過にならないこと（1000回） ---")
	for i: int in 1000:
		var s: GameSession = GameSession.new(60000 + i)
		s.buy("stone", s.max_buyable("stone"))
		s.explore()
		if s.cargo_weight() > s.capacity():
			_check(false, "探索後も積載超過しない（シード %d）" % (60000 + i),
				"%d / %d" % [s.cargo_weight(), s.capacity()])
			return
	_check(true, "1000回とも積載超過しない", "")


func _test_failure() -> void:
	print("--- 探索失敗時のリスク ---")
	var failed: GameSession = null
	for i: int in 200:
		var s: GameSession = GameSession.new(40000 + i)
		s.buy("sword", 1)
		s.buy("ore", 5)
		if s.cargo_count("sword") != 1 or s.cargo_count("ore") != 5:
			continue
		s.explore()
		if s.log_entries[-1].contains("探索失敗"):
			failed = s
			break

	if failed == null:
		_check(false, "探索に失敗するシードが見つかる", "200シード試して0件")
		return
	_check(failed.cargo_count("sword") == 0, "失敗すると戦闘装備を失う", str(failed.cargo_count("sword")))
	_check(failed.cargo_count("ore") == 5, "資源は無傷", str(failed.cargo_count("ore")))

	var found_log: bool = false
	for entry: String in failed.log_entries:
		if entry.contains("探索失敗"):
			found_log = true
	_check(found_log, "探索失敗が航海日誌に記録される", "記録なし")


func _test_day_and_over() -> void:
	print("--- 日数消費とゲーム終了後の扱い ---")
	var s: GameSession = GameSession.new(70001)
	var day_before: int = s.day
	_check(s.explore(), "探索が実行できる", "できない")
	_check(s.day == day_before + 1, "1日だけ消費する", str(s.day - day_before))

	var over: GameSession = GameSession.new(70002)
	while not over.is_over():
		over.rest()
	_check(not over.explore(), "60日を終えると探索できない", "できてしまった")


func _test_boost() -> void:
	print("--- 探索成功後の島倉庫ブースト ---")
	var successful: GameSession = null
	var gain_on_success_day: int = 0
	for i: int in 500:
		var s: GameSession = GameSession.new(30000 + i)
		s.silver = 999999
		s.upgrade_island()
		var before: int = s.warehouse_total()
		s.explore()
		if s.log_entries[-1].contains("探索成功"):
			successful = s
			gain_on_success_day = s.warehouse_total() - before
			break

	if successful == null:
		_check(false, "島レベル1で探索に成功するシードが見つかる", "500シード試して0件")
		return

	var workers: int = successful.worker_count()
	_check(workers > 0, "検査の前提: 労働者がいる", str(workers))
	var normal_daily: int = workers * GameData.RESOURCES_PER_WORKER_PER_DAY
	var boosted_daily: int = normal_daily * GameData.EXPLORE_BOOST_MULT

	_check(gain_on_success_day == boosted_daily,
		"探索成功当日はブーストが乗る（%d個/日）" % boosted_daily, str(gain_on_success_day))

	for i: int in GameData.EXPLORE_BOOST_DAYS - 1:
		var before2: int = successful.warehouse_total()
		successful.rest()
		var gain: int = successful.warehouse_total() - before2
		_check(gain == boosted_daily, "ブースト%d日目も継続する" % (i + 2), str(gain))

	var before3: int = successful.warehouse_total()
	successful.rest()
	var gain_after: int = successful.warehouse_total() - before3
	_check(gain_after == normal_daily, "ブースト終了後は通常量に戻る", str(gain_after))


## 64bit の RNG state と同じ注意点: 辞書どうしの比較だけでは壊れた実装でも
## 通ってしまうため、必ず JSON.stringify() を経由して比較する。
func _test_save_round_trip() -> void:
	print("--- セーブ/ロードでブースト日数が往復する ---")
	var successful: GameSession = null
	for i: int in 300:
		var s: GameSession = GameSession.new(80000 + i)
		s.explore()
		if s.log_entries[-1].contains("探索成功"):
			successful = s
			break

	if successful == null:
		_check(false, "探索に成功するシードが見つかる", "300シード試して0件")
		return

	var data: Dictionary = successful.to_dict()
	_check(data.has("boost_days_left") and int(data["boost_days_left"]) > 0,
		"to_dict にブースト日数が入る", str(data.get("boost_days_left")))

	var via_json: Variant = JSON.parse_string(JSON.stringify(data))
	_check(via_json is Dictionary, "JSON として往復できる", str(typeof(via_json)))
	if not (via_json is Dictionary):
		return
	_check(int(via_json["boost_days_left"]) == int(data["boost_days_left"]),
		"JSON を経由してもブースト日数が変わらない", str(via_json["boost_days_left"]))

	var restored: GameSession = GameSession.new(0)
	restored.from_dict(via_json)
	restored.silver = 999999
	if restored.island_level == 0:
		restored.upgrade_island()
	var before: int = restored.warehouse_total()
	restored.rest()
	var gain: int = restored.warehouse_total() - before
	var expected: int = restored.worker_count() * GameData.RESOURCES_PER_WORKER_PER_DAY * GameData.EXPLORE_BOOST_MULT
	_check(gain == expected, "復元後もブーストが効いている", "%d / %d" % [gain, expected])
