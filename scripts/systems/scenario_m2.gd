extends SceneTree
## M2 の検証シナリオ。製作と黒ゾーンの襲撃を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m2.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

var _failures: int = 0


func _init() -> void:
	_test_craft_basics()
	_test_craft_bonus()
	_test_craft_limits()
	_test_black_zone_route()
	_test_raid_outcome()
	_test_raid_rate()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_craft_basics() -> void:
	print("--- 製作（ボーナスなし） ---")
	# ブリッジウォッチのボーナスは革鎧。剣はボーナス対象外。
	var s: GameSession = GameSession.new(1001)
	s.move_to("bridgewatch")
	_check(not s.has_craft_bonus("sword"), "ブリッジウォッチで剣はボーナス外", "ボーナスあり")
	_check(s.material_cost_per_unit("sword") == 3, "ボーナス外は材料3個", str(s.material_cost_per_unit("sword")))

	s.buy("ore", 9)
	var silver_before: int = s.silver
	var day_before: int = s.day
	var ok: bool = s.craft("sword", 3)
	_check(ok, "剣を3個製作できる", "できない")
	_check(s.cargo_count("sword") == 3, "剣が3個できた", str(s.cargo_count("sword")))
	_check(s.cargo_count("ore") == 0, "鉱石9個を消費した", str(s.cargo_count("ore")))
	_check(s.silver == silver_before - 90 * 3, "手数料は90×3", str(silver_before - s.silver))
	_check(s.day == day_before + 1, "まとめて作っても1日のみ", str(s.day - day_before))


func _test_craft_bonus() -> void:
	print("--- 製作（生産ボーナス都市） ---")
	# マートロックのボーナスは剣。
	var s: GameSession = GameSession.new(1002)
	_check(s.current_city == "martlock", "マートロックにいる", s.current_city)
	_check(s.has_craft_bonus("sword"), "マートロックで剣はボーナス対象", "対象外")
	# 3 × 0.3 = 0.9 → 四捨五入で1個還元 → 実質2個
	_check(s.material_cost_per_unit("sword") == 2, "ボーナス都市では実質2個", str(s.material_cost_per_unit("sword")))

	s.buy("ore", 10)
	s.craft("sword", 5)
	_check(s.cargo_count("sword") == 5, "剣が5個できた", str(s.cargo_count("sword")))
	_check(s.cargo_count("ore") == 0, "鉱石10個で5個作れた（還元なしなら15個必要）", str(s.cargo_count("ore")))

	# 還元の有無で必要量が変わることを直接比較する。
	var no_bonus: GameSession = GameSession.new(1003)
	no_bonus.move_to("bridgewatch")
	_check(no_bonus.material_cost_per_unit("sword") > s.material_cost_per_unit("sword"),
		"ボーナス都市の方が材料が少なくて済む", "同じ")


func _test_craft_limits() -> void:
	print("--- 製作の制約 ---")
	var s: GameSession = GameSession.new(1004)
	# 材料が無ければ作れない。
	_check(s.max_craftable("sword") == 0, "材料なしでは製作不可", str(s.max_craftable("sword")))
	_check(not s.craft("sword", 1), "材料なしの製作は拒否される", "通ってしまった")

	# 資源は製作できない。
	_check(s.max_craftable("ore") == 0, "資源は製作対象外", str(s.max_craftable("ore")))
	_check(not s.craft("ore", 1), "資源の製作は拒否される", "通ってしまった")

	s.buy("ore", 4)
	# マートロックは実質2個消費なので4個から2個作れる。
	_check(s.max_craftable("sword") == 2, "鉱石4個から剣2個", str(s.max_craftable("sword")))
	_check(not s.craft("sword", 3), "上限を超える製作は拒否される", "通ってしまった")
	_check(s.craft("sword", 2), "上限ちょうどは製作できる", "できない")

	# 製作は積載を超えない（剣は重量3、鉱石は1）。
	var s2: GameSession = GameSession.new(1005)
	s2.buy("ore", 40)
	_check(s2.cargo_weight() == 40, "積載いっぱいまで鉱石を積んだ", str(s2.cargo_weight()))
	var craftable: int = s2.max_craftable("sword")
	if craftable > 0:
		s2.craft("sword", craftable)
	_check(s2.cargo_weight() <= s2.capacity(), "製作後も積載超過しない",
		"%d / %d" % [s2.cargo_weight(), s2.capacity()])


func _test_black_zone_route() -> void:
	print("--- 黒ゾーンの経路 ---")
	var s: GameSession = GameSession.new(1006)
	var route: Dictionary = s.route_to("caerleon")
	_check(route["days"] == 1, "黒ゾーンは1日", str(route["days"]))
	_check(route["cost"] == 400, "黒ゾーンの費用は400", str(route["cost"]))
	_check(is_equal_approx(route["raid_chance"], 0.22), "襲撃率は22%", str(route["raid_chance"]))

	# どの王国都市からでも同条件（往路・復路とも）。
	for city_id: String in GameData.royal_city_ids():
		var t: GameSession = GameSession.new(1007)
		if t.current_city != city_id:
			t.move_to(city_id)
		var r: Dictionary = t.route_to("caerleon")
		_check(r["cost"] == 400 and r["days"] == 1, "%s からも同条件" % city_id, str(r))

	# カーレオン発の帰路も黒ゾーン扱い。
	var back: GameSession = GameSession.new(1008)
	back.move_to("caerleon")
	var ret: Dictionary = back.route_to("martlock")
	_check(is_equal_approx(ret["raid_chance"], 0.22), "帰路も襲撃判定がある", str(ret["raid_chance"]))

	# 王道では襲撃しない。
	var safe: GameSession = GameSession.new(1009)
	_check(is_equal_approx(safe.route_to("bridgewatch")["raid_chance"], 0.0), "王道は襲撃なし", "襲撃あり")


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
		s.move_to("caerleon")
		if s.cargo.is_empty():
			raided_session = s
			break

	if raided_session == null:
		_check(false, "襲撃が起きるシードが見つかる", "400シード試して0件")
		return

	_check(raided_session.cargo.is_empty(), "襲撃で積荷を全て失う", "残っている")
	_check(raided_session.silver == silver_at_departure - 400,
		"襲撃されてもシルバーは移動費のみ減る", str(raided_session.silver))
	_check(raided_session.current_city == "caerleon", "襲撃されても移動は成立する", raided_session.current_city)
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
		s.move_to("caerleon")
		if s.cargo.is_empty():
			raids += 1
	var rate: float = float(raids) / float(trials)
	# 1000回試行なら 22% ± 4% にはほぼ確実に収まる。
	_check(absf(rate - 0.22) < 0.04, "襲撃率が約22%になる",
		"%.1f%%（%d/%d）" % [rate * 100.0, raids, trials])
	print("     実測値: %.1f%%（%d/%d）" % [rate * 100.0, raids, trials])


func _check(condition: bool, description: String, actual: String) -> void:
	if condition:
		print("  OK   %s" % description)
	else:
		_failures += 1
		print("  FAIL %s（実際: %s）" % [description, actual])
