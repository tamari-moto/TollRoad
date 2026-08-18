extends "res://scripts/systems/scenario_base.gd"
## M23 の検証シナリオ。都市ごとの在庫（生産量）と需要（販売数）を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m23.gd
##
## 見るのは「動くか」ではなく「妥当か」。個数が動くことだけを確かめると、
## 後から生産量を壊しても素通りするので、範囲で歯止めをかける。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## このシナリオ専用のセーブ先。SAVE_PATH は使わない（プレイヤーの
## セーブを消してしまうため）。最後に削除する。
const TEST_PATH: String = "user://scenario_m23_save.json"


func _init() -> void:
	_test_production_shape()
	_test_specialty_distance_tiers()
	_test_balance_guardrails()
	_test_initial_stock_and_demand()
	_test_buy_limited_by_stock()
	_test_sell_limited_by_demand()
	_test_trade_moves_both_ledgers()
	_test_price_reacts_to_stock()
	_test_price_stays_in_scale()
	_test_daily_replenishment()
	_test_save_round_trip()
	_test_market_panel_shows_supply()
	_finish()


func _test_production_shape() -> void:
	print("--- 生産量は特産・生産地に厚い ---")
	# 都市名を直書きせず、CITIES の specialty/bonus から導かれる形だけを見る。
	for city_id: String in GameData.CITIES:
		var city: Dictionary = GameData.CITIES[city_id]
		var specialty: String = city["specialty"]
		var bonus: String = city["bonus"]
		if specialty != "":
			var other: String = _other_resource(specialty)
			_check(MarketTable.production_of(city_id, specialty)
					> MarketTable.production_of(city_id, other),
				"%s は特産(%s)を他の資源より多く産する" % [city_id, specialty],
				"%d vs %d" % [MarketTable.production_of(city_id, specialty),
					MarketTable.production_of(city_id, other)])
		if bonus != "":
			var other_equipment: String = _other_equipment(bonus)
			_check(MarketTable.production_of(city_id, bonus)
					> MarketTable.production_of(city_id, other_equipment),
				"%s は生産地の装備(%s)を他の装備より多く産する" % [city_id, bonus],
				"%d vs %d" % [MarketTable.production_of(city_id, bonus),
					MarketTable.production_of(city_id, other_equipment)])

	# レアは誰も生産しない（探索でしか手に入らないという設計を守る）。
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.RARE:
				_check(MarketTable.production_of(city_id, item_id) == 0,
					"%s はレア(%s)を生産しない" % [city_id, item_id],
					str(MarketTable.production_of(city_id, item_id)))

	# 自分で作っているものは持ち込まれても要らない（需要は生産と逆向き）。
	for city_id: String in GameData.royal_city_ids():
		var specialty: String = GameData.CITIES[city_id]["specialty"]
		if specialty == "":
			continue
		var other: String = _other_resource(specialty)
		_check(MarketTable.consumption_of(city_id, specialty)
				< MarketTable.consumption_of(city_id, other),
			"%s は特産(%s)をあまり買い取らない" % [city_id, specialty],
			"%d vs %d" % [MarketTable.consumption_of(city_id, specialty),
				MarketTable.consumption_of(city_id, other)])

	# レイヴンスパイアは装備を高く買う（MOD_CAERLEON_EQUIPMENT）都市なので、
	# 需要も厚くないと噛み合わない（高く買うのに少ししか捌けない、を防ぐ）。
	var equipment: String = _any_equipment()
	_check(MarketTable.consumption_of(GameData.CAERLEON, equipment)
			> MarketTable.consumption_of(_any_royal_city(), equipment),
		"レイヴンスパイアは装備の需要が他都市より厚い",
		"%d vs %d" % [MarketTable.consumption_of(GameData.CAERLEON, equipment),
			MarketTable.consumption_of(_any_royal_city(), equipment)])


## 特産資源は「本拠地でしか採れないが、近隣の街でも少しは採れる」形になって
## いるか。road_distance() 自体の検査も兼ねる。
func _test_specialty_distance_tiers() -> void:
	print("--- 特産資源の生産は本拠地からの距離で段階する ---")

	# road_distance() 単体。
	_check(GameData.road_distance("ironhollow", "ironhollow") == 0,
		"同一都市の距離は0", str(GameData.road_distance("ironhollow", "ironhollow")))
	_check(GameData.road_distance(GameData.CAERLEON, "ironhollow") == -1,
		"レイヴンスパイアは王道のどの都市とも繋がらない（距離-1）",
		str(GameData.road_distance(GameData.CAERLEON, "ironhollow")))

	var home: String = "ironhollow"
	var neighbor: String = GameData.road_neighbors(home)[0]
	_check(GameData.road_distance(home, neighbor) == 1,
		"隣接都市の距離は1", str(GameData.road_distance(home, neighbor)))

	var far_city: String = _far_royal_city(home)
	_check(GameData.road_distance(home, far_city) == 2,
		"2ホップ先の距離は2", str(GameData.road_distance(home, far_city)))

	# 生産量の段階。
	var item_id: String = GameData.CITIES[home]["specialty"]
	_check(MarketTable.production_of(home, item_id) == GameData.PRODUCTION_SPECIALTY,
		"本拠地は最大量を産する", str(MarketTable.production_of(home, item_id)))
	_check(MarketTable.production_of(neighbor, item_id) == GameData.PRODUCTION_SPECIALTY_NEAR_1,
		"隣接都市は1段階減った量を産する", str(MarketTable.production_of(neighbor, item_id)))
	_check(MarketTable.production_of(far_city, item_id) == GameData.PRODUCTION_SPECIALTY_NEAR_2,
		"2ホップ先はさらに減った量を産する", str(MarketTable.production_of(far_city, item_id)))
	_check(MarketTable.production_of(GameData.CAERLEON, item_id) == GameData.PRODUCTION_SPECIALTY_FAR,
		"レイヴンスパイアはごく僅かしか産しない",
		str(MarketTable.production_of(GameData.CAERLEON, item_id)))

	# 段階は単調に減り、距離3以上は0になる（トリクル生産を廃止した設計判断。
	# その距離は隊商の輸入だけに委ねる）。
	_check(GameData.PRODUCTION_SPECIALTY > GameData.PRODUCTION_SPECIALTY_NEAR_1
			and GameData.PRODUCTION_SPECIALTY_NEAR_1 > GameData.PRODUCTION_SPECIALTY_NEAR_2
			and GameData.PRODUCTION_SPECIALTY_NEAR_2 > GameData.PRODUCTION_SPECIALTY_FAR
			and GameData.PRODUCTION_SPECIALTY_FAR == 0,
		"生産量の段階は単調に減り、距離3以上は0になる",
		"%d > %d > %d > %d == 0" % [GameData.PRODUCTION_SPECIALTY,
			GameData.PRODUCTION_SPECIALTY_NEAR_1, GameData.PRODUCTION_SPECIALTY_NEAR_2,
			GameData.PRODUCTION_SPECIALTY_FAR])


func _test_balance_guardrails() -> void:
	print("--- バランスの歯止め ---")
	# 既存のバランス（意図された成長ルート）を壊さない範囲に量を保つ。
	# 数字を上げ下げした人がここで止まるように、上限と下限の両方で挟む。

	# 特産は1回の来訪で積荷を満たせる量がある。ここを絞ると
	# 「安く仕入れて運ぶ」という遊びの中心そのものが成立しなくなる。
	var biggest_capacity: int = 0
	for mount_id: String in GameData.MOUNTS:
		biggest_capacity = maxi(biggest_capacity, GameData.MOUNTS[mount_id]["capacity"])
	var specialty_cap: int = GameData.PRODUCTION_SPECIALTY * GameData.MARKET_CAP_DAYS
	_check(specialty_cap >= biggest_capacity,
		"特産の在庫上限は最大の積載量を賄える",
		"在庫 %d / 積載 %d" % [specialty_cap, biggest_capacity])

	# とはいえ無限ではない。全品目が積載を満たせるなら在庫を入れた意味がない。
	# 資源の非本拠地での最大値は隣接都市（NEAR_1）。
	var other_cap: int = GameData.PRODUCTION_SPECIALTY_NEAR_1 * GameData.MARKET_CAP_DAYS
	_check(other_cap < biggest_capacity,
		"特産以外の在庫は積載を満たせない（巡回の動機が残る）",
		"在庫 %d / 積載 %d" % [other_cap, biggest_capacity])

	# 価格連動の幅は控えめに。広げすぎると価格バーの目盛りから外れる。
	_check(GameData.PRICE_SCARCITY_MAX <= 1.25, "在庫による値上がりは25%以内",
		str(GameData.PRICE_SCARCITY_MAX))
	_check(GameData.PRICE_GLUT_MIN >= 0.80, "需要による値下がりは20%以内",
		str(GameData.PRICE_GLUT_MIN))

	# 補充が遅すぎると、何日も待つだけの手詰まりになる。
	_check(GameData.MARKET_CAP_DAYS >= 2 and GameData.MARKET_CAP_DAYS <= 8,
		"在庫が積み上がる日数は2〜8日", str(GameData.MARKET_CAP_DAYS))


func _test_initial_stock_and_demand() -> void:
	print("--- 初日の在庫・需要 ---")
	# 産地は初日から満杯。輸入品は IMPORT_INITIAL_RATIO=0.0 により初日は
	# 完全な品切れから始まる（隊商が運び込むまで買えない）設計。
	#
	# 「全品目が満杯」では確かめない。産地が満杯であることと、輸入品が
	# 初日は在庫ゼロであることを別々に見る。
	var s: GameSession = GameSession.new(23001)
	var empty_local: int = 0
	var nonzero_import: int = 0
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			var cap: int = MarketTable.stock_cap(city_id, item_id)
			if cap <= 0:
				continue
			var on_hand: int = s.market.stock_of(city_id, item_id)
			if MarketTable.production_of(city_id, item_id) > 0:
				if on_hand < cap:
					empty_local += 1
			elif on_hand > 0:
				nonzero_import += 1
	_check(empty_local == 0, "産地は在庫の上限から始まる",
		"%d 件が満杯でない" % empty_local)
	_check(nonzero_import == 0, "輸入品は初日は在庫ゼロから始まる",
		"%d 件が在庫ゼロでない" % nonzero_import)

	# 現在地では、特産が実際に買える量あること。
	var specialty: String = GameData.CITIES[s.current_city]["specialty"]
	_check(s.stock_count(specialty) > 0, "現在地の特産に在庫がある",
		str(s.stock_count(specialty)))
	_check(s.max_buyable(specialty) > 0, "現在地の特産を実際に買える",
		str(s.max_buyable(specialty)))


func _test_buy_limited_by_stock() -> void:
	print("--- 買えるのは在庫まで ---")
	var s: GameSession = GameSession.new(23002)
	s.silver = 10000000

	# 資金と積載を無限に近づけても、在庫を超えては買えない。
	#
	# **在庫が効いていることを確かめるには、在庫が最も厳しい制約でなければ
	# ならない。** 資金や積載の方が先に尽きる状態で比べると、在庫の制限を
	# 実装から外しても検査が通ってしまう（実際にそうなっていた）。
	# そこで在庫をわざと減らし、資金・積載より小さくしてから見る。
	s.buy_mount("mammoth")
	var item_id: String = GameData.CITIES[s.current_city]["specialty"]
	s.market.consume_stock(s.current_city, item_id,
		s.stock_count(item_id) - 3)
	var stock: int = s.stock_count(item_id)
	_check(stock == 3, "在庫を3個まで減らした", str(stock))
	_check(s.free_capacity() > stock and s.silver / s.buy_price(item_id) > stock,
		"積載と資金は在庫より余裕がある（在庫が制約になっている）",
		"空き %d / 買える %d / 在庫 %d" % [
			s.free_capacity(), s.silver / s.buy_price(item_id), stock])
	_check(s.max_buyable(item_id) == stock, "購入可能数は在庫ちょうどで頭打ち",
		"%d / 在庫 %d" % [s.max_buyable(item_id), stock])
	_check(not s.buy(item_id, stock + 1), "在庫を超える購入は拒否",
		"通ってしまった")

	# 在庫は買った分だけ減る。
	var bought: int = mini(5, stock)
	s.buy(item_id, bought)
	_check(s.stock_count(item_id) == stock - bought, "買った分だけ在庫が減る",
		"%d / 期待 %d" % [s.stock_count(item_id), stock - bought])

	# 買い切ると、その日はもう買えない。
	# if で包むと条件を外したときに検査が黙って消えるので、
	# 在庫を空にできたこと自体も検査にする。
	var s2: GameSession = GameSession.new(23003)
	s2.silver = 10000000
	s2.buy_mount("mammoth")
	var target: String = _cheap_resource_with_small_stock(s2)
	s2.buy(target, s2.max_buyable(target))
	_check(s2.stock_count(target) == 0, "在庫を買い切れた",
		str(s2.stock_count(target)))
	_check(s2.max_buyable(target) == 0, "在庫を切らすと買えなくなる",
		str(s2.max_buyable(target)))
	_check(not s2.buy(target, 1), "在庫0では1個も買えない", "買えてしまった")


func _test_sell_limited_by_demand() -> void:
	print("--- 売れるのは需要まで ---")
	var s: GameSession = GameSession.new(23004)
	s.silver = 10000000
	s.buy_mount("mammoth")

	# 現地の特産は現地では余っており、需要が薄い。
	var specialty: String = GameData.CITIES[s.current_city]["specialty"]
	var demand: int = s.demand_count(specialty)
	s.buy(specialty, mini(demand + 10, s.max_buyable(specialty)))
	_check(s.max_sellable(specialty) <= demand, "売却可能数は需要を超えない",
		"%d / 需要 %d" % [s.max_sellable(specialty), demand])
	_check(not s.sell(specialty, demand + 1), "需要を超える売却は拒否",
		"通ってしまった")

	# 需要は売った分だけ減り、尽きたら売れない。
	s.sell(specialty, demand)
	_check(s.demand_count(specialty) == 0, "売った分だけ需要が減る",
		str(s.demand_count(specialty)))
	_check(not s.sell(specialty, 1), "需要が尽きたら売れない", "売れてしまった")
	_check(s.cargo_count(specialty) > 0, "売れ残りは積荷に残る",
		str(s.cargo_count(specialty)))

	# 積荷に無いものは需要があっても売れない。
	var s2: GameSession = GameSession.new(23005)
	var absent: String = ""
	for item_id: String in GameData.ITEMS:
		if s2.cargo_count(item_id) == 0 and s2.demand_count(item_id) > 0:
			absent = item_id
			break
	_check(absent != "" and not s2.sell(absent, 1),
		"需要があっても持っていなければ売れない", "売れてしまった")


## 売買が在庫と需要の**両方**を動かすこと。
##
## 片側だけ（買い＝在庫だけ、売り＝需要だけ）だった頃は、売った品が街から
## 消えていた。ここは「増える側」を見る検査なので、減る側の検査
## （_test_buy_limited_by_stock / _test_sell_limited_by_demand）とは別に置く
## ——片側を消しても、そちらの検査は全て通ってしまう（実測）。
func _test_trade_moves_both_ledgers() -> void:
	print("--- 売買は在庫と需要の両方を動かす ---")
	var s: GameSession = GameSession.new(23020)
	s.silver = 10000000
	s.buy_mount("mammoth")

	# --- 売ると在庫が増える ---
	# **移動はしない。** move_to() は日を進めるので advance_day() の補充が
	# 混ざり、「売った分だけ増えたか」が測れなくなる。現在地で需要があり
	# 棚にも乗る品目を選ぶ。
	var item_id: String = _item_with_room_to_sell(s)
	_check(item_id != "", "検査の前提: その場で売り買いできる品目がある", "無い")

	# 売る分を積荷に入れる（買うと在庫が動くので、そこは介さない）。
	var sold: int = mini(s.demand_count(item_id),
		MarketTable.stock_cap(s.current_city, item_id))
	_check(sold > 0, "検査の前提: 売れる個数がある", str(sold))
	# 棚に余地を作る。満杯だと上限で頭打ちになり、増分が測れない。
	s.market.consume_stock(s.current_city, item_id, sold)
	s.cargo[item_id] = s.cargo_count(item_id) + sold

	var stock_before: int = s.stock_count(item_id)
	s.sell(item_id, sold)
	_check(s.stock_count(item_id) == stock_before + sold,
		"売った分だけ在庫が増える（棚に並ぶ）",
		"%d -> %d（売った %d）" % [stock_before, s.stock_count(item_id), sold])

	# 棚に並んだのだから、買い戻せる。「街に物が出入りしている」の実体。
	_check(s.max_buyable(item_id) > 0, "売った品はその場で買い戻せる",
		str(s.max_buyable(item_id)))

	# --- 買うと需要が戻る ---
	var s2: GameSession = GameSession.new(23021)
	s2.silver = 10000000
	s2.buy_mount("mammoth")
	var bought_item: String = GameData.CITIES[s2.current_city]["specialty"]

	# 需要を先に減らしておく（満杯だと上限で頭打ちになり、戻ったか判らない）。
	s2.market.consume_demand(s2.current_city, bought_item,
		s2.demand_count(bought_item))
	_check(s2.demand_count(bought_item) == 0, "検査の前提: 需要を空にした",
		str(s2.demand_count(bought_item)))

	var buy_count: int = mini(5, s2.max_buyable(bought_item))
	_check(buy_count > 0, "検査の前提: 買える個数がある", str(buy_count))
	s2.buy(bought_item, buy_count)
	_check(s2.demand_count(bought_item) == buy_count,
		"買った分だけ需要が戻る（街から出ていった）",
		"%d（買った %d）" % [s2.demand_count(bought_item), buy_count])

	# --- 増える側は上限で頭打ち ---
	# 上限を外すと売り込みで棚が無限に積み上がる（隊商から見て永久に満杯）。
	var s3: GameSession = GameSession.new(23022)
	s3.silver = 10000000
	s3.buy_mount("mammoth")
	var capped: String = _item_with_room_to_sell(s3)
	_check(capped != "", "検査の前提: 需要のある品目がある", "無い")
	var cap: int = MarketTable.stock_cap(s3.current_city, capped)
	# 棚を満杯にしてから、さらに売り込む。
	s3.market.receive_stock(s3.current_city, capped, cap)
	s3.cargo[capped] = s3.cargo_count(capped) + s3.demand_count(capped)
	s3.sell(capped, s3.max_sellable(capped))
	_check(s3.stock_count(capped) <= cap,
		"売り込んでも在庫は上限を超えない",
		"%d / 上限 %d" % [s3.stock_count(capped), cap])

	# 需要も同じく上限で止まる。
	var s4: GameSession = GameSession.new(23023)
	s4.silver = 10000000
	s4.buy_mount("mammoth")
	var d_item: String = GameData.CITIES[s4.current_city]["specialty"]
	var d_cap: int = MarketTable.demand_cap(s4.current_city, d_item)
	s4.buy(d_item, s4.max_buyable(d_item))
	_check(s4.demand_count(d_item) <= d_cap,
		"買い占めても需要は上限を超えない",
		"%d / 上限 %d" % [s4.demand_count(d_item), d_cap])

	# --- 同じ都市での往復では儲からない ---
	# 買ってすぐ売り返す操作が黒字だと、移動せずシルバーを増やせてしまう。
	var s5: GameSession = GameSession.new(23024)
	s5.silver = 10000000
	s5.buy_mount("mammoth")
	var loop_item: String = _item_with_room_to_sell(s5)
	_check(loop_item != "", "検査の前提: 往復に使える品目がある", "無い")
	var silver_before: int = s5.silver
	var loop_count: int = mini(mini(3, s5.max_buyable(loop_item)),
		s5.demand_count(loop_item))
	_check(loop_count > 0, "検査の前提: 往復できる個数がある", str(loop_count))
	s5.buy(loop_item, loop_count)
	s5.sell(loop_item, loop_count)
	_check(s5.silver < silver_before,
		"同じ都市で買ってすぐ売り返すと損をする（無限増殖しない）",
		"%d -> %d" % [silver_before, s5.silver])


## 現在地で「需要があり、棚にも積める（stock_cap > 0）」品目。
## 特産資源は産地から遠いと stock_cap が0で、売っても棚に乗らない。
func _item_with_room_to_sell(session: GameSession) -> String:
	for item_id: String in GameData.ITEMS:
		if session.demand_count(item_id) <= 0:
			continue
		if MarketTable.stock_cap(session.current_city, item_id) <= 0:
			continue
		if session.max_buyable(item_id) <= 0:
			continue
		return item_id
	return ""

func _test_price_reacts_to_stock() -> void:
	print("--- 在庫と需要が価格に効く ---")
	var s: GameSession = GameSession.new(23006)
	s.silver = 10000000
	s.buy_mount("mammoth")
	var item_id: String = GameData.CITIES[s.current_city]["specialty"]

	# 買い占めるほど買値が上がる。
	var price_before: int = s.buy_price(item_id)
	s.buy(item_id, s.stock_count(item_id) / 2)
	var price_after: int = s.buy_price(item_id)
	_check(price_after > price_before, "買い占めると買値が上がる",
		"%d -> %d" % [price_before, price_after])

	# 建値そのものは動かない（相場メモとの整合を保つため）。
	_check(s.prices.get_price(s.current_city, item_id)
			== s.memo_price(s.current_city, item_id),
		"建値は取引では動かない（メモと一致し続ける）",
		"%d vs %d" % [s.prices.get_price(s.current_city, item_id),
			s.memo_price(s.current_city, item_id)])

	# 売り込むほど売値が下がる。需要の厚い都市で見る。
	var s2: GameSession = GameSession.new(23007)
	s2.silver = 10000000
	s2.buy_mount("mammoth")
	var equipment: String = _any_equipment()
	var sell_before: int = s2.sell_price(equipment)
	s2.cargo[equipment] = 200  # 積載の検査ではないので直接積む。
	s2.sell(equipment, s2.max_sellable(equipment) / 2)
	var sell_after: int = s2.sell_price(equipment)
	_check(sell_after < sell_before, "売り込むと売値が下がる",
		"%d -> %d" % [sell_before, sell_after])

	# 満杯なら建値と一致する（掛け率1.0）。掛け算が常に効いていると
	# 「普段の価格」が静かにずれるため、境界を押さえておく。
	var s3: GameSession = GameSession.new(23008)
	var fresh: String = _any_equipment()
	_check(s3.prices.buy_price(s3.current_city, fresh)
			== s3.prices.get_price(s3.current_city, fresh),
		"在庫が満杯なら買値は建値どおり", "ずれている")
	_check(s3.prices.sell_price(s3.current_city, fresh)
			== s3.prices.get_price(s3.current_city, fresh),
		"需要が満杯なら売値は建値どおり", "ずれている")


func _test_price_stays_in_scale() -> void:
	print("--- 価格バーの目盛りから外れない ---")
	# 在庫連動で価格が動くようになったので、極端な状態でも
	# UiTheme.PRICE_SCALE_MIN〜MAX に収まることを確かめる。
	# 外れるとマーカーが端で振り切れ、行をまたいだ比較ができなくなる。
	var out_of_range: int = 0
	var lowest: float = 99.0
	var highest: float = 0.0
	for seed_value: int in range(1, 25):
		var s: GameSession = GameSession.new(seed_value * 53)
		# 在庫と需要を空にした最悪の状態を作る。
		for city_id: String in GameData.CITIES:
			for item_id: String in GameData.ITEMS:
				s.market.consume_stock(city_id, item_id, 99999)
				s.market.consume_demand(city_id, item_id, 99999)
		for city_id: String in GameData.CITIES:
			for item_id: String in GameData.ITEMS:
				var base: float = float(GameData.ITEMS[item_id]["base_price"])
				for price: int in [s.prices.buy_price(city_id, item_id),
						s.prices.sell_price(city_id, item_id)]:
					var ratio: float = float(price) / base
					lowest = minf(lowest, ratio)
					highest = maxf(highest, ratio)
					if ratio < UiTheme.PRICE_SCALE_MIN or ratio > UiTheme.PRICE_SCALE_MAX:
						out_of_range += 1
	print("     在庫・需要が空のときの幅: %.0f%% 〜 %.0f%%（目盛り %.0f%% 〜 %.0f%%）" % [
		lowest * 100.0, highest * 100.0,
		UiTheme.PRICE_SCALE_MIN * 100.0, UiTheme.PRICE_SCALE_MAX * 100.0])
	_check(out_of_range == 0, "在庫連動後も全価格が目盛りに収まる",
		"%d 件が範囲外" % out_of_range)


func _test_daily_replenishment() -> void:
	print("--- 日が変わると補充される ---")
	var s: GameSession = GameSession.new(23009)
	s.silver = 10000000
	s.buy_mount("mammoth")
	var item_id: String = GameData.CITIES[s.current_city]["specialty"]

	var before: int = s.stock_count(item_id)
	# 生産量より多く買っておく。少ししか減らしていないと、翌日の補充が
	# 上限で頭打ちになって「生産量ちょうど増える」ことを確かめられない。
	var production: int = MarketTable.production_of(s.current_city, item_id)
	s.buy(item_id, mini(production * 2, s.max_buyable(item_id)))
	var after_buy: int = s.stock_count(item_id)
	s.rest()
	var after_rest: int = s.stock_count(item_id)
	_check(after_rest > after_buy, "翌日には在庫が増えている",
		"%d -> %d" % [after_buy, after_rest])
	_check(after_rest - after_buy == production,
		"増える量は生産量ちょうど",
		"%d / 期待 %d" % [after_rest - after_buy, production])

	# 上限を超えて積み上がらない（何日休んでも無限には貯まらない）。
	for i: int in 20:
		s.rest()
	_check(s.stock_count(item_id) == MarketTable.stock_cap(s.current_city, item_id),
		"在庫は上限で頭打ちになる",
		"%d / 上限 %d" % [s.stock_count(item_id),
			MarketTable.stock_cap(s.current_city, item_id)])
	_check(s.stock_count(item_id) <= before, "上限は初日の在庫と同じ",
		"%d / %d" % [s.stock_count(item_id), before])

	# 需要も同じように戻る。
	var s2: GameSession = GameSession.new(23010)
	var specialty: String = GameData.CITIES[s2.current_city]["specialty"]
	s2.cargo[specialty] = 100
	var demand_before: int = s2.demand_count(specialty)
	s2.sell(specialty, demand_before)
	_check(s2.demand_count(specialty) == 0, "需要を使い切った",
		str(s2.demand_count(specialty)))
	s2.rest()
	_check(s2.demand_count(specialty) > 0, "翌日には需要が戻る",
		str(s2.demand_count(specialty)))


func _test_save_round_trip() -> void:
	print("--- セーブ/ロードで在庫と需要が戻る ---")
	var s: GameSession = GameSession.new(23011)
	s.silver = 10000000
	s.buy_mount("mammoth")
	var item_id: String = GameData.CITIES[s.current_city]["specialty"]
	# 日を進めてから在庫を減らす。順序が逆だと補充で上限へ戻ってしまい、
	# 「減った状態が保存されているか」を確かめられない。
	s.rest()
	s.buy(item_id, mini(17, s.max_buyable(item_id)))
	s.cargo[item_id] = 50
	s.sell(item_id, s.max_sellable(item_id))

	# **必ず JSON.stringify() を経由すること。** 辞書どうしを比べても
	# メモリ上では欠けないので、壊れた実装でも通ってしまう。
	var text: String = JSON.stringify(s.to_dict())
	var parsed: Variant = JSON.parse_string(text)
	_check(parsed is Dictionary, "JSON を往復できる", "辞書にならない")
	if not (parsed is Dictionary):
		return

	var restored: GameSession = GameSession.new(0)
	restored.from_dict(parsed as Dictionary)

	var mismatched: int = 0
	for city_id: String in GameData.CITIES:
		for id: String in GameData.ITEMS:
			if restored.market.stock_of(city_id, id) != s.market.stock_of(city_id, id):
				mismatched += 1
			if restored.market.demand_of(city_id, id) != s.market.demand_of(city_id, id):
				mismatched += 1
	_check(mismatched == 0, "全都市・全品目の在庫と需要が一致する",
		"%d 件がずれた" % mismatched)

	# JSON は数値を float で返す。int を通していないと個数の比較が化ける。
	_check(typeof(restored.market.stock_of(s.current_city, item_id)) == TYPE_INT,
		"復元した在庫が int になっている",
		str(typeof(restored.market.stock_of(s.current_city, item_id))))

	# 在庫が減った状態が本当に保存されている（満杯に戻っていない）。
	_check(restored.market.stock_of(s.current_city, item_id)
			< MarketTable.stock_cap(s.current_city, item_id),
		"減った在庫が満杯に戻っていない",
		str(restored.market.stock_of(s.current_city, item_id)))

	# ファイル経由でも往復する。
	_check(SaveManager.save_game(s, TEST_PATH), "保存できる", "失敗")
	var loaded: GameSession = SaveManager.load_game(TEST_PATH)
	_check(loaded != null, "読み込める", SaveManager.last_error())
	if loaded != null:
		_check(loaded.market.stock_of(s.current_city, item_id)
				== s.market.stock_of(s.current_city, item_id),
			"ファイル経由でも在庫が戻る",
			str(loaded.market.stock_of(s.current_city, item_id)))

	# 在庫を持たない古いセーブは満杯として読む（品切れを勝手に作らない）。
	var old_data: Dictionary = s.to_dict()
	old_data.erase("market")
	var old_session: GameSession = GameSession.new(0)
	old_session.from_dict(old_data)
	_check(old_session.market.stock_of(s.current_city, item_id)
			== MarketTable.stock_cap(s.current_city, item_id),
		"market が無い旧セーブは在庫満杯で始まる",
		str(old_session.market.stock_of(s.current_city, item_id)))

	# 欠けたセーブは部分補完せず全体を作り直す（一部だけ埋めると
	# その品目だけ生産の系列から外れる。prices と同じ方針）。
	var broken: Dictionary = s.to_dict()
	(broken["market"]["stock"] as Dictionary).erase(s.current_city)
	var broken_session: GameSession = GameSession.new(0)
	broken_session.from_dict(broken)
	_check(broken_session.market.stock_of(s.current_city, item_id)
			== MarketTable.stock_cap(s.current_city, item_id),
		"欠けた在庫は全体を作り直す",
		str(broken_session.market.stock_of(s.current_city, item_id)))

	SaveManager.delete_save(TEST_PATH)
	_check(not SaveManager.has_save(TEST_PATH), "検査用のセーブを消した", "残っている")


func _test_market_panel_shows_supply() -> void:
	print("--- 市場画面に在庫と需要が出る ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(23012)
	panel.bind(session)

	var item_id: String = GameData.CITIES[session.current_city]["specialty"]
	_check(panel.stock_text_for(item_id).contains(str(session.stock_count(item_id))),
		"在庫の数字が出る", panel.stock_text_for(item_id))
	_check(panel.demand_text_for(item_id).contains(str(session.demand_count(item_id))),
		"需要の数字が出る", panel.demand_text_for(item_id))

	# 買うと表示が追従する（market_changed で引き直される）。
	var before: String = panel.stock_text_for(item_id)
	session.buy(item_id, 1)
	_check(panel.stock_text_for(item_id) != before, "買うと在庫表示が減る",
		"%s のまま" % before)
	_check(panel.stock_text_for(item_id).contains(str(session.stock_count(item_id))),
		"減った後も実際の在庫と一致する", panel.stock_text_for(item_id))

	# 需要が尽きた品目は売るボタンが無効になり、理由が出る。
	var specialty: String = GameData.CITIES[session.current_city]["specialty"]
	session.cargo[specialty] = 100
	session.sell(specialty, session.max_sellable(specialty))
	panel.refresh()
	var sell_button: Button = panel.sell_button_for(specialty)
	_check(sell_button.disabled, "需要が尽きると売るボタンが無効になる", "押せる")
	_check(sell_button.tooltip_text != "", "無効な理由がツールチップに出る", "空")

	_despawn(panel)


# --- 補助 ---

## item_id ではない資源をひとつ。都市名・品目名の直書きを避けるため。
func _other_resource(item_id: String) -> String:
	for id: String in GameData.resource_ids():
		if id != item_id:
			return id
	return item_id


## item_id ではない装備をひとつ。
func _other_equipment(item_id: String) -> String:
	for id: String in GameData.ITEMS:
		if GameData.ITEMS[id]["kind"] == GameData.ItemKind.EQUIPMENT and id != item_id:
			return id
	return item_id


func _any_equipment() -> String:
	for id: String in GameData.ITEMS:
		if GameData.ITEMS[id]["kind"] == GameData.ItemKind.EQUIPMENT:
			return id
	return ""


func _any_royal_city() -> String:
	return GameData.royal_city_ids()[0]


## 積載に収まる程度の在庫しかない資源。買い切りの検査に使う。
func _cheap_resource_with_small_stock(session: GameSession) -> String:
	var best: String = ""
	var best_stock: int = 99999
	for id: String in GameData.resource_ids():
		var stock: int = session.stock_count(id)
		if stock > 0 and stock < best_stock:
			best_stock = stock
			best = id
	return best
