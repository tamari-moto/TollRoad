extends "res://scripts/systems/scenario_base.gd"
## M2 の検証シナリオ。製作と黒ゾーンの襲撃を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m2.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")



func _init() -> void:
	_test_craft_basics()
	_test_craft_bonus()
	_test_craft_limits()
	_test_black_zone_route()
	_test_raid_outcome()
	_test_raid_rate()
	_finish()


## 初期都市のボーナス対象ではない王国都市を1つ返す（比較・非ボーナス検査用）。
func _non_bonus_royal_city(home: String) -> String:
	for city_id: String in GameData.royal_city_ids():
		if city_id != home:
			return city_id
	return home


func _test_craft_basics() -> void:
	print("--- 製作（ボーナスなし） ---")
	# 初期都市のボーナス品目を、ボーナス対象でない都市で製作する。
	var home: String = GameData.INITIAL_CITY
	var bonus_item: String = GameData.CITIES[home]["bonus"]
	var material: String = GameData.ITEMS[bonus_item]["material"]
	var other_city: String = _non_bonus_royal_city(home)

	var s: GameSession = GameSession.new(1001)
	s.move_to(other_city)
	_check(not s.has_craft_bonus(bonus_item), "%s ではボーナス外" % GameData.CITIES[other_city]["name"], "ボーナスあり")
	_check(s.material_cost_per_unit(bonus_item) == 3, "ボーナス外は材料3個", str(s.material_cost_per_unit(bonus_item)))

	s.buy(material, 9)
	var silver_before: int = s.silver
	var day_before: int = s.day
	var ok: bool = s.craft(bonus_item, 3)
	_check(ok, "%sを3個製作できる" % GameData.ITEMS[bonus_item]["name"], "できない")
	_check(s.cargo_count(bonus_item) == 3, "%sが3個できた" % GameData.ITEMS[bonus_item]["name"], str(s.cargo_count(bonus_item)))
	_check(s.cargo_count(material) == 0, "%sを9個消費した" % GameData.ITEMS[material]["name"], str(s.cargo_count(material)))
	_check(s.silver == silver_before - 90 * 3, "手数料は90×3", str(silver_before - s.silver))
	_check(s.day == day_before + 1, "まとめて作っても1日のみ", str(s.day - day_before))


func _test_craft_bonus() -> void:
	print("--- 製作（生産ボーナス都市） ---")
	# 初期都市はそのボーナス品目の製作地。
	var home: String = GameData.INITIAL_CITY
	var bonus_item: String = GameData.CITIES[home]["bonus"]
	var material: String = GameData.ITEMS[bonus_item]["material"]
	var s: GameSession = GameSession.new(1002)
	_check(s.current_city == home, "初期都市にいる", s.current_city)
	_check(s.has_craft_bonus(bonus_item), "初期都市では%sはボーナス対象" % GameData.ITEMS[bonus_item]["name"], "対象外")
	# 3 × 0.3 = 0.9 → 四捨五入で1個還元 → 実質2個
	_check(s.material_cost_per_unit(bonus_item) == 2, "ボーナス都市では実質2個", str(s.material_cost_per_unit(bonus_item)))

	s.buy(material, 10)
	s.craft(bonus_item, 5)
	_check(s.cargo_count(bonus_item) == 5, "%sが5個できた" % GameData.ITEMS[bonus_item]["name"], str(s.cargo_count(bonus_item)))
	_check(s.cargo_count(material) == 0, "%s10個で5個作れた（還元なしなら15個必要）" % GameData.ITEMS[material]["name"], str(s.cargo_count(material)))

	# 還元の有無で必要量が変わることを直接比較する。
	var no_bonus: GameSession = GameSession.new(1003)
	no_bonus.move_to(_non_bonus_royal_city(home))
	_check(no_bonus.material_cost_per_unit(bonus_item) > s.material_cost_per_unit(bonus_item),
		"ボーナス都市の方が材料が少なくて済む", "同じ")


func _test_craft_limits() -> void:
	print("--- 製作の制約 ---")
	# 初期都市はボーナス品目の製作地なので、セッション開始直後がそのまま条件になる。
	var home: String = GameData.INITIAL_CITY
	var bonus_item: String = GameData.CITIES[home]["bonus"]
	var material: String = GameData.ITEMS[bonus_item]["material"]
	var s: GameSession = GameSession.new(1004)
	# 材料が無ければ作れない。
	_check(s.max_craftable(bonus_item) == 0, "材料なしでは製作不可", str(s.max_craftable(bonus_item)))
	_check(not s.craft(bonus_item, 1), "材料なしの製作は拒否される", "通ってしまった")

	# 資源は製作できない。
	_check(s.max_craftable(material) == 0, "資源は製作対象外", str(s.max_craftable(material)))
	_check(not s.craft(material, 1), "資源の製作は拒否される", "通ってしまった")

	s.buy(material, 4)
	# 初期都市は実質2個消費なので4個から2個作れる。
	_check(s.max_craftable(bonus_item) == 2, "材料4個から%s2個" % GameData.ITEMS[bonus_item]["name"], str(s.max_craftable(bonus_item)))
	_check(not s.craft(bonus_item, 3), "上限を超える製作は拒否される", "通ってしまった")
	_check(s.craft(bonus_item, 2), "上限ちょうどは製作できる", "できない")

	# 製作は積載を超えない（装備は重量3、資源は1）。
	var s2: GameSession = GameSession.new(1005)
	s2.buy(material, 40)
	_check(s2.cargo_weight() == 40, "積載いっぱいまで%sを積んだ" % GameData.ITEMS[material]["name"], str(s2.cargo_weight()))
	var craftable: int = s2.max_craftable(bonus_item)
	if craftable > 0:
		s2.craft(bonus_item, craftable)
	_check(s2.cargo_weight() <= s2.capacity(), "製作後も積載超過しない",
		"%d / %d" % [s2.cargo_weight(), s2.capacity()])


func _test_black_zone_route() -> void:
	print("--- 黒ゾーンの経路 ---")
	var s: GameSession = GameSession.new(1006)
	var route: Dictionary = s.route_to(GameData.CAERLEON)
	_check(route["days"] == 1, "黒ゾーンは1日", str(route["days"]))
	_check(route["cost"] == 400, "黒ゾーンの費用は400", str(route["cost"]))
	_check(is_equal_approx(route["raid_chance"], 0.22), "襲撃率は22%", str(route["raid_chance"]))

	# どの王国都市からでも同条件（往路・復路とも）。
	for city_id: String in GameData.royal_city_ids():
		var t: GameSession = GameSession.new(1007)
		if t.current_city != city_id:
			t.move_to(city_id)
		var r: Dictionary = t.route_to(GameData.CAERLEON)
		_check(r["cost"] == 400 and r["days"] == 1, "%s からも同条件" % city_id, str(r))

	# 中心都市発の帰路も黒ゾーン扱い。
	var back: GameSession = GameSession.new(1008)
	back.move_to(GameData.CAERLEON)
	var ret: Dictionary = back.route_to(GameData.INITIAL_CITY)
	_check(is_equal_approx(ret["raid_chance"], 0.22), "帰路も襲撃判定がある", str(ret["raid_chance"]))

	# 王道では襲撃しない。
	var safe: GameSession = GameSession.new(1009)
	var neighbor: String = _adjacent_royal_city(safe.current_city)
	_check(is_equal_approx(safe.route_to(neighbor)["raid_chance"], 0.0), "王道は襲撃なし", "襲撃あり")


func _test_raid_outcome() -> void:
	print("--- 襲撃の結果 ---")
	# 襲撃が起きるシードを探し、その挙動を検査する。
	var raided_session: GameSession = null
	var silver_at_departure: int = 0
	for seed_value: int in range(1, 400):
		var s: GameSession = GameSession.new(seed_value)
		s.buy("ore", 10)
		if s.cargo_count("ore") != 10:
			continue
		silver_at_departure = s.silver
		s.move_to(GameData.CAERLEON)
		if s.cargo.is_empty():
			raided_session = s
			break

	if raided_session == null:
		_check(false, "襲撃が起きるシードが見つかる", "400シード試して0件")
		return

	_check(raided_session.cargo.is_empty(), "襲撃で積荷を全て失う", "残っている")
	_check(raided_session.silver == silver_at_departure - 400,
		"襲撃されてもシルバーは移動費のみ減る", str(raided_session.silver))
	_check(raided_session.current_city == GameData.CAERLEON, "襲撃されても移動は成立する", raided_session.current_city)
	_check(raided_session.day == 2, "襲撃されても1日で着く", str(raided_session.day))

	var found_log: bool = false
	for entry: String in raided_session.log_entries:
		if entry.contains("襲撃"):
			found_log = true
	_check(found_log, "襲撃が航海日誌に記録される", "記録なし")


func _test_raid_rate() -> void:
	print("--- 襲撃率の実測（1000回） ---")
	var trials: int = 1000
	var raids: int = 0
	for i: int in trials:
		var s: GameSession = GameSession.new(50000 + i)
		s.buy("ore", 5)
		if s.cargo_count("ore") == 0:
			continue
		s.move_to(GameData.CAERLEON)
		if s.cargo.is_empty():
			raids += 1
	var rate: float = float(raids) / float(trials)
	# 1000回試行なら 22% ± 4% にはほぼ確実に収まる。
	_check(absf(rate - 0.22) < 0.04, "襲撃率が約22%になる",
		"%.1f%%（%d/%d）" % [rate * 100.0, raids, trials])
	print("     実測値: %.1f%%（%d/%d）" % [rate * 100.0, raids, trials])
