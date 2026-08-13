extends "res://scripts/systems/scenario_base.gd"
## M1 の検証シナリオ。シード固定で交易ループを一周し、不変条件を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m1.gd
##
## テストフレームワークは使わない。--script は autoload を初期化しないため、
## ロジックは load() + .new() で直接駆動できる形に保っている。
## _check() と _finish() は scenario_base.gd にある。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")


func _init() -> void:
	_test_static_definitions()
	_test_adjacency()
	_test_price_modifiers()
	_test_determinism()
	_test_trade_arithmetic()
	_test_trade_loop()
	_finish()


# --- 検査 ---

func _test_static_definitions() -> void:
	print("--- 静的定義 ---")
	_check(GameData.ITEMS.size() == 19, "品目は19種", str(GameData.ITEMS.size()))
	_check(GameData.CITIES.size() == 10, "都市は10", str(GameData.CITIES.size()))
	_check(GameData.resource_ids().size() == 9, "資源は9種", str(GameData.resource_ids().size()))
	_check(GameData.INITIAL_SILVER == 30000, "初期シルバーは30000", str(GameData.INITIAL_SILVER))
	_check(GameData.TOTAL_DAYS == 60, "全60日", str(GameData.TOTAL_DAYS))

	# 装備は必ず資源を材料に持ち、資源3個で1個作れる。
	for item_id: String in GameData.ITEMS:
		var item: Dictionary = GameData.ITEMS[item_id]
		if item["kind"] == GameData.ItemKind.EQUIPMENT:
			_check(item.has("material"), "%s に材料が定義されている" % item_id, "なし")

	# ランク判定の閾値。
	_check(GameData.rank_for(1200000) == "LEGENDARY MERCHANT", "120万でLEGENDARY", GameData.rank_for(1200000))
	_check(GameData.rank_for(500000) == "MASTER TRADER", "50万でMASTER", GameData.rank_for(500000))
	_check(GameData.rank_for(29999) == "BANKRUPT", "3万未満でBANKRUPT", GameData.rank_for(29999))


func _test_adjacency() -> void:
	print("--- 隣接判定（不規則な連結グラフ） ---")
	# 都市名には依存させず、GameData.ROYAL_ROAD_EDGES から導かれる構造だけを
	# 検査する。環ではなく次数が都市ごとに異なるグラフなので、「全都市が
	# 隣接2つ」のような一様性は前提にしない。
	var ring: Array[String] = GameData.royal_city_ids()

	for a: String in ring:
		_check(not GameData.is_adjacent(a, a), "%s は自分自身とは隣接しない" % a, "隣接扱い")
		_check(not GameData.is_adjacent(a, GameData.CAERLEON),
			"%s は中心都市と王道では接続しない" % a, "接続扱い")
		for b: String in ring:
			_check(GameData.is_adjacent(a, b) == GameData.is_adjacent(b, a),
				"%s-%s の隣接判定は対称" % [a, b], "非対称")

	# ROYAL_ROAD_EDGES が参照する都市は必ず実在の王国都市。
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		_check(ring.has(edge[0]) and ring.has(edge[1]),
			"辺 %s-%s は実在の王国都市を指す" % [edge[0], edge[1]], "不明な都市を含む")

	# 次数（隣接数）が不揃いであること自体が「環ではない」ことの直接的な証拠。
	var min_degree: int = 999
	var max_degree: int = 0
	for city_id: String in ring:
		var degree: int = GameData.road_neighbors(city_id).size()
		min_degree = mini(min_degree, degree)
		max_degree = maxi(max_degree, degree)
	_check(min_degree >= 1, "孤立した都市がない（次数1以上）", str(min_degree))
	_check(min_degree != max_degree, "次数が不揃い（環ではない）", "全都市が次数%d" % min_degree)

	# 黒ゾーンを除いた王道だけでも全都市が連結している。
	var visited: Dictionary = {ring[0]: true}
	var queue: Array[String] = [ring[0]]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbor: String in GameData.road_neighbors(current):
			if not visited.has(neighbor):
				visited[neighbor] = true
				queue.append(neighbor)
	_check(visited.size() == ring.size(), "王道だけで全都市が連結している",
		"%d / %d 都市に到達" % [visited.size(), ring.size()])


func _test_price_modifiers() -> void:
	print("--- 都市補正 ---")
	const PriceTable = preload("res://scripts/systems/price_table.gd")
	# 都市名を直書きせず、初期都市の specialty/bonus を GameData から引く。
	var city_id: String = GameData.INITIAL_CITY
	var specialty: String = GameData.CITIES[city_id]["specialty"]
	var bonus: String = GameData.CITIES[city_id]["bonus"]
	_check(is_equal_approx(PriceTable.city_modifier(city_id, specialty), GameData.MOD_SPECIALTY),
		"特産資源は%.2f" % GameData.MOD_SPECIALTY, "違う")
	_check(is_equal_approx(PriceTable.city_modifier(city_id, bonus), GameData.MOD_BONUS),
		"ボーナス装備は%.2f" % GameData.MOD_BONUS, "違う")
	_check(is_equal_approx(PriceTable.city_modifier(GameData.CAERLEON, bonus), GameData.MOD_CAERLEON_EQUIPMENT),
		"中心都市の装備は%.2f" % GameData.MOD_CAERLEON_EQUIPMENT, "違う")
	_check(is_equal_approx(PriceTable.city_modifier(GameData.CAERLEON, specialty), GameData.MOD_CAERLEON_RESOURCE),
		"中心都市の資源は%.2f" % GameData.MOD_CAERLEON_RESOURCE, "違う")

	# specialty でも bonus でもない品目は無関係（1.0倍）のはず。
	var unrelated: String = ""
	for item_id: String in GameData.ITEMS:
		if item_id != specialty and item_id != bonus:
			unrelated = item_id
			break
	_check(is_equal_approx(PriceTable.city_modifier(city_id, unrelated), 1.0), "無関係な品目は1.0", "違う")


func _test_determinism() -> void:
	print("--- 決定性（シード固定） ---")
	var a: GameSession = GameSession.new(12345)
	var b: GameSession = GameSession.new(12345)
	var c: GameSession = GameSession.new(99999)

	var price_a: int = a.prices.get_price(GameData.INITIAL_CITY, "ore")
	var price_b: int = b.prices.get_price(GameData.INITIAL_CITY, "ore")
	var price_c: int = c.prices.get_price(GameData.INITIAL_CITY, "ore")
	_check(price_a == price_b, "同じシードなら同じ価格", "%d vs %d" % [price_a, price_b])
	_check(price_a != price_c, "違うシードなら違う価格", "どちらも %d" % price_a)

	# 日を進めた後も一致し続けること。
	a.rest()
	b.rest()
	_check(a.prices.get_price(GameData.CAERLEON, "sword") == b.prices.get_price(GameData.CAERLEON, "sword"),
		"日送り後も再現する", "ずれた")

	# ゆらぎは都市×品目で独立（Q5）。全都市が同一価格にはならない。
	var s: GameSession = GameSession.new(7)
	var seen: Dictionary = {}
	for city_id: String in GameData.royal_city_ids():
		seen[s.prices.get_price(city_id, "stone")] = true
	_check(seen.size() > 1, "同じ品目でも都市ごとに価格が異なる", "全都市が同一価格")


func _test_trade_arithmetic() -> void:
	print("--- 売買の計算 ---")
	var s: GameSession = GameSession.new(2024)
	var start_silver: int = s.silver
	_check(start_silver == 30000, "初期シルバー30000", str(start_silver))
	_check(s.capacity() == 40, "ロバの積載は40", str(s.capacity()))
	_check(s.current_city == GameData.INITIAL_CITY, "初期都市から開始", s.current_city)

	# 購入: シルバーが単価×個数だけ減り、積荷が増える。
	var buy_price: int = s.prices.get_price(GameData.INITIAL_CITY, "ore")
	var bought: bool = s.buy("ore", 10)
	_check(bought, "鉱石を10個購入できる", "できない")
	_check(s.silver == start_silver - buy_price * 10,
		"購入でシルバーが単価×個数減る", "%d" % s.silver)
	_check(s.cargo_count("ore") == 10, "積荷が10個", str(s.cargo_count("ore")))
	_check(s.cargo_weight() == 10, "資源の重量は1なので合計10", str(s.cargo_weight()))
	_check(s.free_capacity() == 30, "空きは30", str(s.free_capacity()))

	# 売却: 総額の5%が税として引かれる（Q2）。
	# 売れるのは都市の需要までなので、需要の範囲内の個数で算術を確かめる。
	# 初期都市の特産（鉱石）は現地では余っており、需要が薄い側に置いてある。
	var sell_count: int = s.max_sellable("ore")
	_check(sell_count > 0, "需要がある範囲では売却できる", str(sell_count))
	var silver_before_sell: int = s.silver
	var sell_price: int = s.sell_price("ore")
	var expected_gross: int = sell_price * sell_count
	var expected_tax: int = int(round(expected_gross * 0.05))
	var expected_net: int = expected_gross - expected_tax
	var held_before_sell: int = s.cargo_count("ore")
	s.sell("ore", sell_count)
	_check(s.silver == silver_before_sell + expected_net,
		"売却の手取りは総額の95%", "期待 %d, 実際 %d" % [silver_before_sell + expected_net, s.silver])
	_check(s.cargo_count("ore") == held_before_sell - sell_count,
		"売った分だけ積荷が減る", str(s.cargo_count("ore")))
	# 需要を使い切ったので、同じ日にこれ以上は売れない。
	_check(s.demand_count("ore") == 0, "需要を使い切った", str(s.demand_count("ore")))
	_check(not s.sell("ore", 1), "需要が尽きたらそれ以上売れない", "通ってしまった")

	# 残りを手放してから、持っていない品目の売却が拒否されることを見る。
	s.cargo.erase("ore")
	# 上限を超える取引は拒否される。
	_check(not s.buy("ore", 99999), "資金を超える購入は拒否", "通ってしまった")
	_check(not s.sell("ore", 1), "持っていない品目の売却は拒否", "通ってしまった")
	_check(not s.buy("ore", 0), "0個の購入は拒否", "通ってしまった")

	# 積載上限: 装備は重量3なので、ロバ(40)には13個までしか積めない。
	var s2: GameSession = GameSession.new(555)
	var max_swords: int = s2.free_capacity() / 3
	_check(max_swords == 13, "ロバに積める剣は13個", str(max_swords))


func _test_trade_loop() -> void:
	print("--- 交易ループ（初期都市の特産を買い、隣町で売る） ---")
	var s: GameSession = GameSession.new(31337)
	var start: int = s.silver
	var home: String = s.current_city
	var neighbor: String = _adjacent_royal_city(home)
	var specialty: String = GameData.CITIES[home]["specialty"]

	# 初期都市の特産は×0.72なので安く買える。
	var buy_price: int = s.prices.get_price(home, specialty)
	s.buy(specialty, 20)
	_check(s.cargo_count(specialty) == 20, "特産資源を20個積んだ", str(s.cargo_count(specialty)))

	# 隣接都市へ移動（1日、250）。
	var silver_before_move: int = s.silver
	var moved: bool = s.move_to(neighbor)
	_check(moved, "隣町へ移動できた", "できない")
	_check(s.silver == silver_before_move - 250, "移動費250が引かれる", str(s.silver))
	_check(s.day == 2, "1日経過した", str(s.day))
	_check(s.current_city == neighbor, "移動先にいる", s.current_city)
	_check(s.cargo_count(specialty) == 20, "王道では積荷を失わない", str(s.cargo_count(specialty)))

	# 移動先で売る。隣町では特産扱いでない可能性が高い。
	var sell_price: int = s.prices.get_price(neighbor, specialty)
	s.sell(specialty, 20)
	_check(sell_price > buy_price, "特産地で買い他所で売ると単価が上がる",
		"買 %d / 売 %d（シード次第では逆転しうる）" % [buy_price, sell_price])

	# 王道2ホップ先（非隣接）への移動は、王道250×2の500・2日
	# （黒ゾーン経由の800より安いので経路探索はこちらを選ぶ）。
	var far_city: String = _far_royal_city(s.current_city)
	var day_before: int = s.day
	var silver_before_far: int = s.silver
	s.move_to(far_city)
	_check(s.silver == silver_before_far - 500, "2ホップ先の移動費は500", str(s.silver))
	_check(s.day == day_before + 2, "2ホップ先は2日かかる", str(s.day))

	# 不変条件。
	_check(s.silver >= 0, "シルバーが負にならない", str(s.silver))
	_check(s.cargo_weight() <= s.capacity(), "積載超過しない",
		"%d / %d" % [s.cargo_weight(), s.capacity()])

	# 相場メモ: 訪問した都市は記録され、未訪問は残らない。
	_check(s.has_memo(home), "訪問した都市は記録される", "ない")
	_check(s.has_memo(far_city), "現在地は記録される", "ない")
	_check(not s.has_memo(GameData.CAERLEON), "未訪問の都市は記録されない", "ある")

	# 7日以上経つと古い記録になる。
	for i: int in 7:
		s.rest()
	_check(s.is_memo_stale(home), "7日経過で古い記録になる", "まだ新しい扱い")
	_check(not s.is_memo_stale(far_city), "現在地の記録は毎日更新される", "古い扱い")

	# 純資産は手元のシルバーと積荷から算出される。
	var s3: GameSession = GameSession.new(4242)
	var cash: int = s3.silver
	s3.buy("ore", 10)
	# 鉱石10個 = 基準価格210 × 10 × 0.9 = 1890
	var expected: int = s3.silver + int(round(210 * 10 * 0.9))
	_check(s3.net_worth() == expected, "純資産に積荷が基準価格×0.9で算入される",
		"期待 %d, 実際 %d" % [expected, s3.net_worth()])
	_check(cash > s3.silver, "購入でシルバーは減っている", "減っていない")
