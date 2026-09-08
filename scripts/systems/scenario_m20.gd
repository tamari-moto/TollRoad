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
	_test_slot_shape()
	_test_slot_moves()
	_test_slot_net_worth()
	_test_chance_formula()
	_test_ravenspire_penalty()
	_test_success_rate()
	_test_reward_bounds()
	_test_capacity_safety()
	_test_failure()
	_test_success_keeps_slots()
	_test_day_and_over()
	_test_boost()
	_test_save_round_trip()
	_test_slot_save_round_trip()
	_finish()


func _test_city_flavors() -> void:
	print("--- 都市ごとの探索フレーバー ---")
	for city_id: String in GameData.CITIES:
		var flavor: String = GameData.CITIES[city_id].get("explore_flavor", "")
		_check(flavor != "", "%s に探索フレーバーがある" % city_id, "ない")


func _test_slot_shape() -> void:
	print("--- スロットの形 ---")
	var s: GameSession = GameSession.new(20100)
	_check(s.explore_slots.size() == GameData.EXPLORE_SLOT_COUNT,
		"開始時からスロットが定数ぶん並ぶ", str(s.explore_slots.size()))
	var all_empty: bool = true
	for i: int in s.explore_slots.size():
		if s.slot_item(i) != "":
			all_empty = false
	_check(all_empty, "開始時は全枠が空", str(s.explore_slots))
	_check(s.first_empty_slot() == 0, "最初の空き枠は0番", str(s.first_empty_slot()))
	_check(s.slot_item(-1) == "" and s.slot_item(999) == "",
		"範囲外の参照は空を返す（落ちない）", "落ちるか空以外を返した")

	# 装備以外は挿せない。資源を挿せてしまうと成功率と純資産の前提が崩れる。
	s.buy("ore", 3)
	var ore_before: int = s.cargo_count("ore")
	_check(not s.equip_slot(0, "ore"), "資源はスロットに挿せない", "挿せてしまった")
	_check(s.slot_item(0) == "", "拒否された後もスロットは空のまま", s.slot_item(0))
	_check(s.cargo_count("ore") == ore_before, "拒否時に積荷が減らない",
		"%d / %d" % [s.cargo_count("ore"), ore_before])

	# 積荷に無い装備は挿せない。
	_check(not s.equip_slot(0, "staff"), "積荷に無い装備は挿せない", "挿せてしまった")


## スロットは積荷とは別の置き場——挿すと積荷から出て積載重量が空く。
## 戻すときは積載に空きが要る。
func _test_slot_moves() -> void:
	print("--- スロットへの出し入れ ---")
	var s: GameSession = GameSession.new(20101)
	s.buy("sword", 2)
	if s.cargo_count("sword") != 2:
		_check(false, "検査の前提: 剣を2個買えた", str(s.cargo_count("sword")))
		return
	var weight_before: int = s.cargo_weight()
	var sword_weight: int = GameData.ITEMS["sword"]["weight"]

	_check(s.equip_slot(0, "sword"), "スロットへ挿せる", "挿せない")
	_check(s.cargo_count("sword") == 1, "挿した分だけ積荷から減る", str(s.cargo_count("sword")))
	_check(s.cargo_weight() == weight_before - sword_weight,
		"挿すと積載重量が空く", "%d / %d" % [s.cargo_weight(), weight_before - sword_weight])

	_check(s.unequip_slot(0), "スロットから戻せる", "戻せない")
	_check(s.cargo_count("sword") == 2, "戻すと積荷が元に戻る", str(s.cargo_count("sword")))
	_check(s.cargo_weight() == weight_before, "重量も元に戻る", str(s.cargo_weight()))
	_check(not s.unequip_slot(0), "空のスロットは戻せない", "戻せてしまった")

	# 入れ替え。挿さっている物は積荷へ返る。
	var s2: GameSession = GameSession.new(20102)
	s2.silver = 999999
	s2.cargo["sword"] = 1
	s2.cargo["bow"] = 1
	_check(s2.equip_slot(0, "sword"), "検査の前提: 剣を挿せた", "挿せない")
	_check(s2.equip_slot(0, "bow"), "同じ枠へ別の装備を挿すと入れ替わる", "入れ替わらない")
	_check(s2.slot_item(0) == "bow", "枠の中身が新しい方になる", s2.slot_item(0))
	_check(s2.cargo_count("sword") == 1, "元の中身は積荷へ返る", str(s2.cargo_count("sword")))
	_check(s2.cargo_count("bow") == 0, "新しい方は積荷から出る", str(s2.cargo_count("bow")))

	# 積載が満杯だと戻せない。free_capacity() が負にならないこと。
	var s3: GameSession = GameSession.new(20103)
	s3.cargo["sword"] = 1
	if not s3.equip_slot(0, "sword"):
		_check(false, "検査の前提: 剣を挿せた", "挿せない")
		return
	s3.cargo.clear()
	var stone_weight: int = GameData.ITEMS["stone"]["weight"]
	s3.cargo["stone"] = int(s3.capacity() / stone_weight)
	_check(s3.free_capacity() < GameData.ITEMS["sword"]["weight"],
		"検査の前提: 積載に剣ぶんの空きが無い", str(s3.free_capacity()))
	_check(not s3.unequip_slot(0), "積載が埋まっていれば戻せない", "戻せてしまった")
	_check(s3.slot_item(0) == "sword", "拒否されても装備は消えない", s3.slot_item(0))
	_check(s3.free_capacity() >= 0, "積載超過にならない", str(s3.free_capacity()))


## スロットへ移しても純資産が変わらないこと。
## 数え漏らすと、装備を挿すだけでランクが下がる（勝利条件が置き場所で動く）。
func _test_slot_net_worth() -> void:
	print("--- スロットの中身も純資産に数える ---")
	var s: GameSession = GameSession.new(20104)
	s.buy("sword", 2)
	if s.cargo_count("sword") != 2:
		_check(false, "検査の前提: 剣を2個買えた", str(s.cargo_count("sword")))
		return
	var before: int = s.net_worth()
	_check(s.equip_slot(0, "sword"), "検査の前提: 挿せた", "挿せない")
	_check(s.net_worth() == before, "挿しても純資産は変わらない",
		"%d / %d" % [s.net_worth(), before])
	_check(s.unequip_slot(0), "検査の前提: 戻せた", "戻せない")
	_check(s.net_worth() == before, "戻しても純資産は変わらない",
		"%d / %d" % [s.net_worth(), before])


## スロットに挿した装備だけが成功率に効くこと。
## **積荷に何個あっても効かない**のがスロット制の要点なので、
## 「積荷に積んだだけでは上がらない」を先に押さえる。ここが抜けると、
## 旧仕様（積荷を数える）のままでも以降の検査が通ってしまう。
func _test_chance_formula() -> void:
	print("--- 成功率の算出式（スロット） ---")
	var s: GameSession = GameSession.new(20001)
	_check(is_equal_approx(s.explore_chance(), GameData.EXPLORE_BASE_CHANCE),
		"スロットが空なら基本確率のまま", str(s.explore_chance()))

	# 全枠を剣で埋めるので枠数ぶん買う（1個ずつ挿すと積荷から出ていくため)。
	s.buy("sword", GameData.EXPLORE_SLOT_COUNT)
	_check(s.cargo_count("sword") == GameData.EXPLORE_SLOT_COUNT,
		"検査の前提: 剣を枠数ぶん買えた", str(s.cargo_count("sword")))
	_check(is_equal_approx(s.explore_chance(), GameData.EXPLORE_BASE_CHANCE),
		"積荷に積んだだけでは成功率は上がらない", str(s.explore_chance()))

	_check(s.equip_slot(0, "sword"), "スロット0へ挿せる", "挿せない")
	_check(is_equal_approx(s.explore_chance(),
			GameData.EXPLORE_BASE_CHANCE + GameData.EXPLORE_EQUIP_BONUS_PER_UNIT),
		"スロット1個で+3%相当のボーナス", str(s.explore_chance()))

	# 同種は頭打ちまで。5枠すべてを剣で埋めても3個ぶんしか効かない。
	for i: int in range(1, GameData.EXPLORE_SLOT_COUNT):
		s.equip_slot(i, "sword")
	_check(s.slot_counts().get("sword", 0) == GameData.EXPLORE_SLOT_COUNT,
		"検査の前提: 全枠が剣で埋まった", str(s.slot_counts()))
	_check(is_equal_approx(s.explore_chance(),
			GameData.EXPLORE_BASE_CHANCE + GameData.EXPLORE_EQUIP_UNIT_CAP * GameData.EXPLORE_EQUIP_BONUS_PER_UNIT),
		"同種は頭打ち数までしか加算されない", str(s.explore_chance()))

	# 種類を跨ぐと伸びる。全枠を別種で埋めたときが最大。
	var s2: GameSession = GameSession.new(20002)
	s2.silver = 999999
	s2.buy_mount("mammoth")
	for i: int in GameData.EXPLORE_SLOT_COUNT:
		s2.cargo[GameData.EXPLORE_COMBAT_ITEMS[i]] = 1
	for i: int in GameData.EXPLORE_SLOT_COUNT:
		_check(s2.equip_slot(i, GameData.EXPLORE_COMBAT_ITEMS[i]),
			"検査の前提: スロット%d に別種を挿せる" % i, "挿せない")
	var expected_max: float = GameData.EXPLORE_SLOT_COUNT * GameData.EXPLORE_EQUIP_BONUS_PER_UNIT
	_check(is_equal_approx(s2.explore_equip_bonus(), expected_max),
		"別種で全枠を埋めるとスロット数ぶんのボーナス", str(s2.explore_equip_bonus()))
	_check(expected_max < GameData.EXPLORE_EQUIP_BONUS_CAP,
		"スロット制では合計上限に届かない（上限は歯止めとして残るだけ）",
		"%.2f >= %.2f" % [expected_max, GameData.EXPLORE_EQUIP_BONUS_CAP])


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


## 失敗で失うのは**スロットの中身だけ**で、積荷の装備は無傷であること。
## 旧仕様は積荷の装備を消していたので、ここが両方を分けて見る要になる。
func _test_failure() -> void:
	print("--- 探索失敗で失うのはスロットだけ ---")
	var failed: GameSession = null
	for i: int in 400:
		var s: GameSession = GameSession.new(40000 + i)
		# 積荷に4個。うち1個だけをスロットへ移す（残り3個は積荷に残る）。
		s.buy("sword", 4)
		s.buy("ore", 5)
		if s.cargo_count("sword") != 4 or s.cargo_count("ore") != 5:
			continue
		if not s.equip_slot(0, "sword"):
			continue
		s.explore()
		if s.log_entries[-1].contains("探索失敗"):
			failed = s
			break

	if failed == null:
		_check(false, "スロットを埋めたまま失敗するシードが見つかる", "400シード試して0件")
		return
	_check(failed.slot_item(0) == "", "失敗するとスロットが空になる", failed.slot_item(0))
	_check(failed.cargo_count("sword") == 3, "積荷に残した装備は無傷",
		"%d 個（期待 3）" % failed.cargo_count("sword"))
	_check(failed.cargo_count("ore") == 5, "資源は無傷", str(failed.cargo_count("ore")))
	_check(failed.log_entries[-1].contains("探索失敗"),
		"探索失敗が航海日誌に記録される", failed.log_entries[-1])


## 成功したときはスロットが減らないこと（消費は失敗時のみ）。
## 「毎回消費」との取り違えをここで止める。
func _test_success_keeps_slots() -> void:
	print("--- 成功してもスロットは減らない ---")
	var succeeded: GameSession = null
	for i: int in 400:
		var s: GameSession = GameSession.new(45000 + i)
		s.buy("sword", 2)
		if s.cargo_count("sword") != 2:
			continue
		if not s.equip_slot(0, "sword"):
			continue
		s.explore()
		if s.log_entries[-1].contains("探索成功"):
			succeeded = s
			break

	if succeeded == null:
		_check(false, "スロットを埋めたまま成功するシードが見つかる", "400シード試して0件")
		return
	_check(succeeded.slot_item(0) == "sword", "成功後もスロットは挿さったまま", succeeded.slot_item(0))
	_check(succeeded.cargo_count("sword") == 1, "積荷の残りも変わらない",
		str(succeeded.cargo_count("sword")))


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


## スロットがセーブを往復すること。**JSON.stringify() を経由して比べる**
## （辞書どうしの比較はメモリ上で欠けないため、壊れた実装でも通る）。
func _test_slot_save_round_trip() -> void:
	print("--- スロットのセーブ往復 ---")
	var s: GameSession = GameSession.new(20105)
	s.silver = 999999
	s.cargo["sword"] = 1
	s.cargo["bow"] = 1
	if not s.equip_slot(0, "sword") or not s.equip_slot(2, "bow"):
		_check(false, "検査の前提: 2枠に挿せた", str(s.explore_slots))
		return

	var via_json: Variant = JSON.parse_string(JSON.stringify(s.to_dict()))
	_check(via_json is Dictionary, "JSON として往復できる", str(typeof(via_json)))
	if not (via_json is Dictionary):
		return
	var restored: GameSession = GameSession.new(0)
	restored.from_dict(via_json)
	_check(restored.explore_slots.size() == GameData.EXPLORE_SLOT_COUNT,
		"復元後も枠数が揃う", str(restored.explore_slots.size()))
	_check(restored.slot_item(0) == "sword" and restored.slot_item(2) == "bow",
		"挿した中身と位置が戻る", str(restored.explore_slots))
	_check(restored.slot_item(1) == "", "空き枠は空きのまま戻る", restored.slot_item(1))
	_check(is_equal_approx(restored.explore_equip_bonus(), s.explore_equip_bonus()),
		"復元後の成功率ボーナスが一致する", str(restored.explore_equip_bonus()))

	# スロットを持たない版のセーブ（旧セーブ）を読んでも落ちないこと。
	var legacy: Dictionary = s.to_dict()
	legacy.erase("explore_slots")
	var legacy_json: Variant = JSON.parse_string(JSON.stringify(legacy))
	var from_legacy: GameSession = GameSession.new(0)
	from_legacy.from_dict(legacy_json)
	_check(from_legacy.explore_slots.size() == GameData.EXPLORE_SLOT_COUNT,
		"スロットが無い旧セーブでも枠数が揃う", str(from_legacy.explore_slots.size()))
	_check(from_legacy.explore_equip_bonus() == 0.0,
		"旧セーブのスロットは空", str(from_legacy.explore_equip_bonus()))
