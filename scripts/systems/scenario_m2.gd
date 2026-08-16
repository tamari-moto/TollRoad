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
	_test_multi_leg_from_hub()
	_finish()


## logged シグナルで EVENT が飛んだかを溜める。
## ローカル変数だとラムダは値をコピーして捕まえるため、内側からの代入が
## 外へ伝わらない（実際にこれで検査が誤通過していた）。メンバ変数にすること。
var _event_seen: bool = false


func _on_logged_watch_event(_message: String, kind: int) -> void:
	if kind == GameSession.LogKind.EVENT:
		_event_seen = true


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

	# 1001 のままだと製作の日送りでランダムイベントが発生し、手数料の
	# 厳密比較が崩れる。1002 は発生しない。
	var s: GameSession = GameSession.new(1002)
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

	# ゲート都市（GameData.BLACK_ZONE_GATES）は全て実在の王国都市。
	for gate: String in GameData.BLACK_ZONE_GATES:
		_check(GameData.royal_city_ids().has(gate), "ゲート %s は実在の王国都市" % gate, "不明な都市")

	# ゲート都市からは直接1日/400（往路・復路とも）。
	for city_id: String in GameData.BLACK_ZONE_GATES:
		var t: GameSession = GameSession.new(1007)
		if t.current_city != city_id:
			t.move_to(city_id)
		var r: Dictionary = t.route_to(GameData.CAERLEON)
		_check(r["cost"] == 400 and r["days"] == 1, "ゲート都市 %s からは直接1日/400" % city_id, str(r))

	# ゲートでない都市は、ゲートまでの王道区間＋黒ゾーン1区間の合成になる。
	# 黒ゾーン区間は最後の1つだけなので、襲撃率は22%のまま変わらない。
	for city_id: String in GameData.royal_city_ids():
		if GameData.BLACK_ZONE_GATES.has(city_id):
			continue
		var t: GameSession = GameSession.new(1008)
		if t.current_city != city_id:
			t.move_to(city_id)
		var r: Dictionary = t.route_to(GameData.CAERLEON)
		_check(r["days"] > 1 and r["cost"] > 400,
			"非ゲート都市 %s からは複数区間になる" % city_id, str(r))
		_check(is_equal_approx(r["raid_chance"], 0.22),
			"%s からも襲撃率は22%%のまま" % city_id, str(r["raid_chance"]))

	# 中心都市発の帰路も黒ゾーン扱い（初期都市はゲートなので直接1区間）。
	var back: GameSession = GameSession.new(1009)
	back.move_to(GameData.CAERLEON)
	var ret: Dictionary = back.route_to(GameData.INITIAL_CITY)
	_check(is_equal_approx(ret["raid_chance"], 0.22), "帰路も襲撃判定がある", str(ret["raid_chance"]))

	# 王道では襲撃しない。
	var safe: GameSession = GameSession.new(1010)
	var neighbor: String = _adjacent_royal_city(safe.current_city)
	_check(is_equal_approx(safe.route_to(neighbor)["raid_chance"], 0.0), "王道は襲撃なし", "襲撃あり")


func _test_raid_outcome() -> void:
	print("--- 襲撃の結果 ---")
	# 襲撃が起きるシードを探し、その挙動を検査する。
	# ランダムイベントが同じ移動中に発生するとシルバーの厳密比較が崩れるため、
	# イベントが起きなかったシードだけを対象にする。
	var raided_session: GameSession = null
	var silver_at_departure: int = 0
	for seed_value: int in range(1, 400):
		var s: GameSession = GameSession.new(seed_value)
		s.buy("ore", 10)
		if s.cargo_count("ore") != 10:
			continue
		silver_at_departure = s.silver
		_event_seen = false
		s.logged.connect(_on_logged_watch_event)
		s.move_to(GameData.CAERLEON)
		s.logged.disconnect(_on_logged_watch_event)
		if _event_seen:
			continue
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


## 中心都市（レイヴンスパイア）発でゲートでない都市着の移動は、必ず
## 「黒ゾーン1区間（襲撃判定あり、最初の区間）＋王道の安全区間1つ以上」
## という複数区間になる（GameData.BLACK_ZONE_GATES がゲートを絞って
## いるため）。道中（最初の区間）で被弾しても、旅程は最終目的地まで続き、
## 費用・日数は経路全体の合計どおりになることを検査する。
func _test_multi_leg_from_hub() -> void:
	print("--- 複数区間の移動（中心都市発、道中に黒ゾーン区間を含む） ---")
	# ゲートでない王国都市を1つ選ぶ（都市名は直書きしない）。
	var destination: String = ""
	for city_id: String in GameData.royal_city_ids():
		if not GameData.BLACK_ZONE_GATES.has(city_id):
			destination = city_id
			break
	_check(destination != "", "ゲートでない王国都市が存在する", "見つからない")
	if destination == "":
		return

	var probe: GameSession = GameSession.new(0)
	if probe.current_city != GameData.CAERLEON:
		probe.move_to(GameData.CAERLEON)
	var expected_route: Dictionary = probe.route_to(destination)
	_check(expected_route["days"] > 1 and expected_route["cost"] > 400,
		"中心都市からゲートでない都市へは複数区間になる", str(expected_route))

	# 実際に襲撃が起きるシードを探す。
	var raided_session: GameSession = null
	var silver_at_departure: int = 0
	var day_before: int = 0
	for seed_value: int in range(1, 500):
		var s: GameSession = GameSession.new(seed_value)
		if s.current_city != GameData.CAERLEON:
			s.move_to(GameData.CAERLEON)
		# レイヴンスパイアは特産を持たず、資源は本拠地からの距離が2を超える
		# （＝FARティア）ため、特産資源は産地周辺以外では市場に並ばない
		# （stock_cap が常に0。market_table.gd 参照）。市場を介さず積荷を
		# 直接積んで前提を作る。積荷が空になるかどうかを見る検査なので、
		# 積み方や量そのものは問わない。
		s.cargo["ore"] = 2
		silver_at_departure = s.silver
		day_before = s.day
		s.move_to(destination)
		if s.cargo.is_empty():
			raided_session = s
			break

	_check(raided_session != null, "多段移動で襲撃が起きるシードが見つかる", "500シード試して0件")
	if raided_session == null:
		return

	_check(raided_session.current_city == destination,
		"道中（黒ゾーン区間）で被弾しても最終目的地まで旅程が続く", raided_session.current_city)
	_check(raided_session.cargo.is_empty(), "襲撃で積荷を全て失う", "残っている")
	_check(raided_session.silver == silver_at_departure - expected_route["cost"],
		"被弾しても費用は経路の合計どおり引かれる", str(raided_session.silver))
	_check(raided_session.day == day_before + expected_route["days"],
		"被弾しても日数は経路の合計どおり進む", str(raided_session.day))

	var found_log: bool = false
	for entry: String in raided_session.log_entries:
		if entry.contains("襲撃"):
			found_log = true
	_check(found_log, "多段移動でも襲撃が航海日誌に記録される", "記録なし")


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
