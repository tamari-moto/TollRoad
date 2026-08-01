extends SceneTree
## M1 の検証シナリオ。シード固定で交易ループを一周し、不変条件を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m1.gd
##
## テストフレームワークは使わない。--script は autoload を初期化しないため、
## ロジックは load() + .new() で直接駆動できる形に保っている。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

var _failures: int = 0


func _init() -> void:
	_test_static_definitions()
	_test_adjacency()
	_test_price_modifiers()
	_test_determinism()
	_test_trade_arithmetic()
	_test_trade_loop()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


# --- 検査 ---

func _test_static_definitions() -> void:
	print("--- 静的定義 ---")
	_check(GameData.ITEMS.size() == 9, "品目は9種", str(GameData.ITEMS.size()))
	_check(GameData.CITIES.size() == 6, "都市は6つ", str(GameData.CITIES.size()))
	_check(GameData.resource_ids().size() == 5, "資源は5種", str(GameData.resource_ids().size()))
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
	print("--- 隣接判定（環は閉じている） ---")
	_check(GameData.is_adjacent("martlock", "bridgewatch"), "マートロック(3)とブリッジウォッチ(2)は隣接", "false")
	_check(GameData.is_adjacent("martlock", "thetford"), "マートロック(3)とセットフォード(4)は隣接", "false")
	# 環が閉じているので 0 と 4 も隣接する。
	_check(GameData.is_adjacent("fort_sterling", "thetford"), "フォートスターリング(0)とセットフォード(4)は隣接", "false")
	_check(not GameData.is_adjacent("fort_sterling", "bridgewatch"), "0と2は非隣接", "true")
	_check(not GameData.is_adjacent("martlock", "caerleon"), "カーレオンは王道で接続しない", "true")
	_check(not GameData.is_adjacent("martlock", "martlock"), "同一都市は隣接ではない", "true")

	# どの王国都市もちょうど2つの隣接を持つ。
	for city_id: String in GameData.royal_city_ids():
		var count: int = 0
		for other: String in GameData.royal_city_ids():
			if GameData.is_adjacent(city_id, other):
				count += 1
		_check(count == 2, "%s の隣接は2都市" % city_id, str(count))


func _test_price_modifiers() -> void:
	print("--- 都市補正 ---")
	const PriceTable = preload("res://scripts/systems/price_table.gd")
	# マートロックの特産は鉱石。
	_check(is_equal_approx(PriceTable.city_modifier("martlock", "ore"), 0.72), "特産資源は0.72", "違う")
	# マートロックのボーナス装備は剣。
	_check(is_equal_approx(PriceTable.city_modifier("martlock", "sword"), 0.88), "ボーナス装備は0.88", "違う")
	_check(is_equal_approx(PriceTable.city_modifier("caerleon", "sword"), 1.24), "カーレオンの装備は1.24", "違う")
	_check(is_equal_approx(PriceTable.city_modifier("caerleon", "ore"), 1.06), "カーレオンの資源は1.06", "違う")
	_check(is_equal_approx(PriceTable.city_modifier("martlock", "wood"), 1.0), "無関係な品目は1.0", "違う")


func _test_determinism() -> void:
	print("--- 決定性（シード固定） ---")
	var a: GameSession = GameSession.new(12345)
	var b: GameSession = GameSession.new(12345)
	var c: GameSession = GameSession.new(99999)

	var price_a: int = a.prices.get_price("martlock", "ore")
	var price_b: int = b.prices.get_price("martlock", "ore")
	var price_c: int = c.prices.get_price("martlock", "ore")
	_check(price_a == price_b, "同じシードなら同じ価格", "%d vs %d" % [price_a, price_b])
	_check(price_a != price_c, "違うシードなら違う価格", "どちらも %d" % price_a)

	# 日を進めた後も一致し続けること。
	a.rest()
	b.rest()
	_check(a.prices.get_price("caerleon", "sword") == b.prices.get_price("caerleon", "sword"),
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
	_check(s.current_city == "martlock", "マートロックから開始", s.current_city)

	# 購入: シルバーが単価×個数だけ減り、積荷が増える。
	var buy_price: int = s.prices.get_price("martlock", "ore")
	var bought: bool = s.buy("ore", 10)
	_check(bought, "鉱石を10個購入できる", "できない")
	_check(s.silver == start_silver - buy_price * 10,
		"購入でシルバーが単価×個数減る", "%d" % s.silver)
	_check(s.cargo_count("ore") == 10, "積荷が10個", str(s.cargo_count("ore")))
	_check(s.cargo_weight() == 10, "資源の重量は1なので合計10", str(s.cargo_weight()))
	_check(s.free_capacity() == 30, "空きは30", str(s.free_capacity()))

	# 売却: 総額の5%が税として引かれる（Q2）。
	var silver_before_sell: int = s.silver
	var sell_price: int = s.prices.get_price("martlock", "ore")
	var expected_gross: int = sell_price * 10
	var expected_tax: int = int(round(expected_gross * 0.05))
	var expected_net: int = expected_gross - expected_tax
	s.sell("ore", 10)
	_check(s.silver == silver_before_sell + expected_net,
		"売却の手取りは総額の95%", "期待 %d, 実際 %d" % [silver_before_sell + expected_net, s.silver])
	_check(s.cargo_count("ore") == 0, "積荷が空になる", str(s.cargo_count("ore")))

	# 上限を超える取引は拒否される。
	_check(not s.buy("ore", 99999), "資金を超える購入は拒否", "通ってしまった")
	_check(not s.sell("ore", 1), "持っていない品目の売却は拒否", "通ってしまった")
	_check(not s.buy("ore", 0), "0個の購入は拒否", "通ってしまった")

	# 積載上限: 装備は重量3なので、ロバ(40)には13個までしか積めない。
	var s2: GameSession = GameSession.new(555)
	var max_swords: int = s2.free_capacity() / 3
	_check(max_swords == 13, "ロバに積める剣は13個", str(max_swords))


func _test_trade_loop() -> void:
	print("--- 交易ループ（マートロックで買い、隣町で売る） ---")
	var s: GameSession = GameSession.new(31337)
	var start: int = s.silver

	# マートロックの特産は鉱石（×0.72）なので安く買える。
	var buy_price: int = s.prices.get_price("martlock", "ore")
	s.buy("ore", 20)
	_check(s.cargo_count("ore") == 20, "鉱石を20個積んだ", str(s.cargo_count("ore")))

	# 隣接都市へ移動（1日、250）。
	var silver_before_move: int = s.silver
	var moved: bool = s.move_to("bridgewatch")
	_check(moved, "隣町へ移動できた", "できない")
	_check(s.silver == silver_before_move - 250, "移動費250が引かれる", str(s.silver))
	_check(s.day == 2, "1日経過した", str(s.day))
	_check(s.current_city == "bridgewatch", "移動先にいる", s.current_city)
	_check(s.cargo_count("ore") == 20, "王道では積荷を失わない", str(s.cargo_count("ore")))

	# 移動先で売る。ブリッジウォッチでは鉱石は特産でないため補正1.0。
	var sell_price: int = s.prices.get_price("bridgewatch", "ore")
	s.sell("ore", 20)
	_check(sell_price > buy_price, "特産地で買い他所で売ると単価が上がる",
		"買 %d / 売 %d（シード次第では逆転しうる）" % [buy_price, sell_price])

	# 非隣接への移動は2日・450。
	var day_before: int = s.day
	var silver_before_far: int = s.silver
	s.move_to("fort_sterling")
	_check(s.silver == silver_before_far - 450, "非隣接の移動費は450", str(s.silver))
	_check(s.day == day_before + 2, "非隣接は2日かかる", str(s.day))

	# 不変条件。
	_check(s.silver >= 0, "シルバーが負にならない", str(s.silver))
	_check(s.cargo_weight() <= s.capacity(), "積載超過しない",
		"%d / %d" % [s.cargo_weight(), s.capacity()])

	# 相場メモ: 訪問した都市は記録され、未訪問は残らない。
	_check(s.has_memo("martlock"), "訪問した都市は記録される", "ない")
	_check(s.has_memo("fort_sterling"), "現在地は記録される", "ない")
	_check(not s.has_memo("caerleon"), "未訪問の都市は記録されない", "ある")

	# 7日以上経つと古い記録になる。
	for i: int in 7:
		s.rest()
	_check(s.is_memo_stale("martlock"), "7日経過で古い記録になる", "まだ新しい扱い")
	_check(not s.is_memo_stale("fort_sterling"), "現在地の記録は毎日更新される", "古い扱い")

	# 純資産は手元のシルバーと積荷から算出される。
	var s3: GameSession = GameSession.new(4242)
	var cash: int = s3.silver
	s3.buy("ore", 10)
	# 鉱石10個 = 基準価格210 × 10 × 0.9 = 1890
	var expected: int = s3.silver + int(round(210 * 10 * 0.9))
	_check(s3.net_worth() == expected, "純資産に積荷が基準価格×0.9で算入される",
		"期待 %d, 実際 %d" % [expected, s3.net_worth()])
	_check(cash > s3.silver, "購入でシルバーは減っている", "減っていない")


# --- ヘルパ ---

func _check(condition: bool, description: String, actual: String) -> void:
	if condition:
		print("  OK   %s" % description)
	else:
		_failures += 1
		print("  FAIL %s（実際: %s）" % [description, actual])
