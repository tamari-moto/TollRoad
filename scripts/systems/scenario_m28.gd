extends "res://scripts/systems/scenario_base.gd"
## 物流（logistics.gd）と、地図に出る荷車の検証。
##
## この機能の約束は「**在庫が自然に増えるのは生産地だけ**で、それ以外の
## 都市の品物は産地から隊商が運んでくる」こと。壊れ方が2通りあり、どちらも
## 画面を見ただけでは気づきにくいので、両側から挟む。
##
##   1. 運ばれてこない側。隊商が止まると消費地は品切れへ向かうが、
##      market_table.gd の advance_day() が黙って全都市に補充を戻した場合
##      （PRODUCTION_OTHER_* を 0 以外に戻す等）、品切れは起きないので
##      「動いている」検査では素通りする。**非生産地が自力で在庫を増やして
##      いないこと**を直接見る必要がある。
##
##   2. 運ばれすぎる側。供給が厚すぎると消費地でも産地並みに買えるように
##      なり、「産地まで足を運ぶ」という遊びの中心が消える。
##      産地と消費地の在庫の開きで歯止めをかける。
##
## **一時的な品切れは許す**（2026-08-17、交易路の廃止に伴う）。隊商が唯一の
## 供給路になったため、着くまでの数日で棚が尽きる組は出る。それは物流が
## 実際に効いていることの現れなので、「1件も品切れが無い」では検査しない
## （そう書くと品物が湧く実装へ戻す圧力になる）。見るのは慢性化——
## 全期間を通して一度も在庫を持てない組が無いこと——と、割合の上限。
##
## 荷車（map_view_3d.gd）は見た目なので最終的な判断は GUI に委ねるが、
## 街道の上に乗っているか・台数が隊商と一致するかは幾何として確かめられる。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m28.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const Logistics = preload("res://scripts/systems/logistics.gd")
const LogisticsTuning = preload("res://scripts/systems/logistics_tuning.gd")
const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const Sfx = preload("res://scripts/ui/sfx.gd")

## 検査で回す日数。隊商が出発して到着するまでを十分含む長さにする。
const RUN_DAYS: int = 30


func _init() -> void:
	_test_arrival_is_logged_at_current_city()
	_test_only_producers_grow_stock()
	_test_imports_arrive_from_producers()
	_test_producer_advantage_remains()
	_test_convoy_routes_follow_roads()
	_test_convoy_carts_ride_the_roads()
	_test_save_round_trip()
	_test_balance_guardrails()
	_finish()


## 現在地に着いた隊商だけが日誌に出て、その行の種別が LOGISTICS であること。
##
## 種別を見るのは、本文の文面を変えても壊れない約束だから
## （rules/testing.md の「実装と同じ判定を書き写さない」）。あわせて、
## セーブから復元した行（文字列しか残らない）でも同じ種別に戻ることを見る。
## ここが戻らないと、復元した日誌の色や音が生きている行と食い違う。
func _test_arrival_is_logged_at_current_city() -> void:
	print("--- 隊商の到着が日誌に出る ---")
	var s: GameSession = GameSession.new(28006)

	# 本文は配列に溜める。ラムダは String をコピーで捕まえるため、
	# 外の変数へ代入しても呼び出し側からは空のままになる（実測でそうなり、
	# 復元の検査が黙って素通りしていた）。Array は参照なので追記は届く。
	var arrival_kinds: Array[int] = []
	var arrival_texts: Array[String] = []
	s.logged.connect(func(message: String, kind: int) -> void:
		if kind == GameSession.LogKind.LOGISTICS:
			arrival_kinds.append(kind)
			arrival_texts.append(message))

	# 現在地の輸入品を空にしておくと、そこへ隊商が向かってくる。
	for item_id: String in GameData.ITEMS:
		if MarketTable.production_of(s.current_city, item_id) > 0:
			continue
		s.market.consume_stock(s.current_city, item_id, 99999)

	for day: int in 12:
		s.rest()

	_check(not arrival_kinds.is_empty(),
		"現在地への到着が LOGISTICS として日誌に出る",
		"%d 行" % arrival_kinds.size())

	# 復元した行が同じ種別に戻ること（本文からしか引けない経路）。
	# **条件付きにしないこと。** 本文が拾えていなければ検査そのものを
	# 落とす（if で包むと、拾えなかった日に黙って素通りする）。
	_check(not arrival_texts.is_empty(), "到着の本文を拾えている",
		"%d 行" % arrival_texts.size())
	var restored_ok: int = 0
	for text: String in arrival_texts:
		if Sfx.kind_for_message(text) == GameSession.LogKind.LOGISTICS:
			restored_ok += 1
	_check(not arrival_texts.is_empty() and restored_ok == arrival_texts.size(),
		"復元した到着の行も LOGISTICS に戻る",
		"%d / %d 行" % [restored_ok, arrival_texts.size()])

	# 到着音は鳴らさない（世界の側の出来事で、日送りのたびに鳴ると煩い）。
	_check(Sfx.sound_for_log_kind(GameSession.LogKind.LOGISTICS) == -1,
		"到着では音を鳴らさない",
		str(Sfx.sound_for_log_kind(GameSession.LogKind.LOGISTICS)))


## 非生産地は自分では在庫を増やさない。
##
## 物流を止めた状態（GameSession を通さず MarketTable だけを進める）で
## 在庫が増えないことを見る。ここが増えると、隊商が1本も走らなくても
## 品物が並んでしまい、物流という仕組み自体が飾りになる。
func _test_only_producers_grow_stock() -> void:
	print("--- 在庫が増えるのは生産地だけ ---")
	var market := MarketTable.new()

	# 在庫を空にしてから1日進める。満杯のまま進めても上限で頭打ちになり、
	# 「増えない」のか「増える余地が無い」のか区別が付かない。
	var grew: int = 0
	var producers_grew: int = 0
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if MarketTable.stock_cap(city_id, item_id) <= 0:
				continue
			market.consume_stock(city_id, item_id, 99999)
			var before: int = market.stock_of(city_id, item_id)
			market.advance_day()
			var after: int = market.stock_of(city_id, item_id)
			if MarketTable.production_of(city_id, item_id) > 0:
				if after > before:
					producers_grew += 1
			elif after > before:
				grew += 1
			# 1日ぶんずつ見たいので、都市・品目ごとに作り直す。
			market = MarketTable.new()

	_check(grew == 0, "物流なしでは非生産地の在庫は増えない",
		"%d 件が自力で増えた" % grew)
	_check(producers_grew > 0, "生産地の在庫は自力で増える",
		"%d 件" % producers_grew)

	# 定義そのものも押さえる。ここが 0 でなくなると上の検査は通るのに
	# 「生産地のみ」という前提が崩れる（全都市が薄く生産を始める）。
	_check(GameData.PRODUCTION_OTHER_RESOURCE == 0,
		"非生産地の資源の生産量は0", str(GameData.PRODUCTION_OTHER_RESOURCE))
	_check(GameData.PRODUCTION_OTHER_EQUIPMENT == 0,
		"非生産地の装備の生産量は0", str(GameData.PRODUCTION_OTHER_EQUIPMENT))


## 産地から消費地へ実際に品物が渡っていること。
##
## 非生産地の在庫を空にしてから日を送り、戻ってくることを見る。
## 戻らなければ物流が繋がっていない（消費地が永久に品切れになる）。
func _test_imports_arrive_from_producers() -> void:
	print("--- 産地から消費地へ運ばれてくる ---")
	var s: GameSession = GameSession.new(28001)

	# 生産していない「都市 x 品目」を1組選び、在庫を空にする。
	var target_city: String = ""
	var target_item: String = ""
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if MarketTable.production_of(city_id, item_id) > 0:
				continue
			if MarketTable.stock_cap(city_id, item_id) <= 0:
				continue
			target_city = city_id
			target_item = item_id
			break
		if target_city != "":
			break

	_check(target_city != "", "輸入に頼る都市と品目が存在する", target_city)
	if target_city == "":
		return

	s.market.consume_stock(target_city, target_item, 99999)
	_check(s.market.stock_of(target_city, target_item) == 0,
		"空にした直後は在庫ゼロ", str(s.market.stock_of(target_city, target_item)))

	for day: int in 6:
		s.rest()

	_check(s.market.stock_of(target_city, target_item) > 0,
		"空にしても数日で運ばれてくる",
		"%d 個" % s.market.stock_of(target_city, target_item))

	# 品切れが**慢性化**しないこと。
	#
	# 交易路を廃止したので、一時的な品切れは起きる（隊商が着くまで4日前後
	# かかり、その間に棚が尽きる組はある）。それは物流が実際に効いている
	# ことの現れであって不具合ではない——なので「1件も品切れが無い」では
	# 検査しない（そう書くと、品物が湧く実装へ戻す圧力になる）。
	#
	# 見るのは「同じ組がずっと空のままではない」こと。RUN_DAYS を通して
	# **一度も在庫を持てなかった**組があれば、そこへは隊商が構造的に
	# 到達できていない（経路が無い・産地が送り出せない）。
	var long_run: GameSession = GameSession.new(28002)
	var ever_stocked: Dictionary = {}
	for day: int in RUN_DAYS:
		long_run.rest()
		for city_id: String in GameData.CITIES:
			for item_id: String in GameData.ITEMS:
				if long_run.market.stock_of(city_id, item_id) > 0:
					ever_stocked["%s|%s" % [city_id, item_id]] = true

	var never_stocked: int = 0
	var pairs: int = 0
	for city_id2: String in GameData.CITIES:
		for item_id2: String in GameData.ITEMS:
			if MarketTable.stock_cap(city_id2, item_id2) <= 0:
				continue
			pairs += 1
			if not ever_stocked.has("%s|%s" % [city_id2, item_id2]):
				never_stocked += 1
	_check(never_stocked == 0,
		"%d日を通して一度も在庫を持てない組が無い" % RUN_DAYS,
		"%d / %d 組が全期間ゼロ" % [never_stocked, pairs])

	# とはいえ、常時ほとんどが空では市場として成立しない。最終日の品切れが
	# 全体の一部に収まっていること（品切れを許すぶん、上限で挟む）。
	var starved: int = 0
	for city_id3: String in GameData.CITIES:
		for item_id3: String in GameData.ITEMS:
			if MarketTable.stock_cap(city_id3, item_id3) <= 0:
				continue
			if long_run.market.stock_of(city_id3, item_id3) <= 0:
				starved += 1
	_check(float(starved) / float(pairs) < 0.25,
		"%d日後の品切れが全体の25%%未満に収まる" % RUN_DAYS,
		"%d / %d 組（%.0f%%）" % [starved, pairs,
			float(starved) / float(pairs) * 100.0])


## 産地の方が明確に潤沢で安いこと。
##
## 物流が厚すぎると消費地でも同じだけ買えてしまい、産地へ足を運ぶ理由が
## 消える（既存のバランスの土台が崩れる）。在庫の開きで挟む。
func _test_producer_advantage_remains() -> void:
	print("--- 産地の優位が残っている ---")
	var s: GameSession = GameSession.new(28003)
	for day: int in RUN_DAYS:
		s.rest()

	var checked: int = 0
	var thin_imports: int = 0
	for city_id: String in GameData.CITIES:
		var specialty: String = GameData.CITIES[city_id]["specialty"]
		if specialty == "":
			continue
		var local: int = s.market.stock_of(city_id, specialty)
		# 同じ品目を、産地でない都市で見る。
		#
		# 以前は「生産量が0の都市」で選んでいたが、特産の距離段階
		# （PRODUCTION_SPECIALTY_FAR = 1）が入って生産量0の都市が消え、
		# 1組も選ばれなくなった。見たいのは「産地か否か」なので産地そのものを
		# 除く形にする。近隣が少し採れること自体は m23 が押さえている。
		for other_id: String in GameData.CITIES:
			if other_id == city_id:
				continue
			checked += 1
			if s.market.stock_of(other_id, specialty) < local:
				thin_imports += 1

	_check(checked > 0, "産地と消費地の組が存在する", str(checked))
	_check(thin_imports == checked,
		"特産は産地が最も潤沢",
		"%d / %d 組でしか成立していない" % [thin_imports, checked])

	# 輸入品の上限そのものも産地より薄いこと（在庫の厚みで「輸入品である」
	# ことが読める）。
	_check(GameData.IMPORT_CAP_DAYS < GameData.MARKET_CAP_DAYS,
		"輸入品の在庫上限は産地より薄い",
		"IMPORT_CAP_DAYS=%d / MARKET_CAP_DAYS=%d" % [
			GameData.IMPORT_CAP_DAYS, GameData.MARKET_CAP_DAYS])


## 隊商の経路が実際の街道を辿っていること。
##
## 経路を勝手に直線で結ぶと、地図の荷車が道の無いところを横切る。
## 隣接していない都市どうしが経路上で隣り合っていないかを見る。
func _test_convoy_routes_follow_roads() -> void:
	print("--- 隊商の経路は街道を辿る ---")

	var checked: int = 0
	var broken: int = 0
	for from_city: String in GameData.CITIES:
		for to_city: String in GameData.CITIES:
			if from_city == to_city:
				continue
			var path: Array[String] = Logistics.route_between(from_city, to_city)
			if path.is_empty():
				broken += 1
				continue
			checked += 1
			if path[0] != from_city or path[path.size() - 1] != to_city:
				broken += 1
				continue
			# 隣り合う2都市は、王道か黒ゾーンのゲートで実際に繋がっていること。
			for i: int in path.size() - 1:
				if not _connected(path[i], path[i + 1]):
					broken += 1
					break

	_check(checked > 0, "経路を引ける都市の組がある", str(checked))
	_check(broken == 0, "全ての経路が実在する道だけを通る",
		"%d 組が壊れている" % broken)


## 2都市が隊商の通れる道で直接つながっているか。
## logistics.gd の _neighbors_of() と同じ判定を書き写さないよう、
## GameData の定義から組み立てる。
func _connected(a: String, b: String) -> bool:
	if GameData.is_adjacent(a, b):
		return true
	if a == GameData.CAERLEON and b in GameData.BLACK_ZONE_GATES:
		return true
	if b == GameData.CAERLEON and a in GameData.BLACK_ZONE_GATES:
		return true
	return false


## 荷車が街道の上（都市の間・地面の高さ）に乗っていること。
##
## 見た目そのものの判断は GUI に委ねるが、地面にめり込む・宙に浮くのは
## 幾何として検出できる（草木で実際に踏んだ不具合と同じ形）。
func _test_convoy_carts_ride_the_roads() -> void:
	print("--- 荷車が街道の上に乗る ---")
	var world := MapView3D.new()

	var from_city: String = GameData.royal_city_ids()[0]
	var to_city: String = _adjacent_royal_city(from_city)

	# 区間の両端と途中で、地面からの高さが CONVOY_LIFT どおりであること。
	var max_error: float = 0.0
	var off_road: int = 0
	for step: int in 11:
		var t: float = float(step) / 10.0
		var transform: Transform3D = world.convoy_transform_at(from_city, to_city, t)
		var ground: float = world.height_at(transform.origin.x, transform.origin.z)
		max_error = maxf(max_error, absf(
			transform.origin.y - (ground + MapView3D.CONVOY_LIFT)))

		# 都市を結ぶ線分の上に乗っていること（横滑りしていない）。
		var a: Vector3 = world.positions[from_city]
		var b: Vector3 = world.positions[to_city]
		var expected := Vector2(lerpf(a.x, b.x, t), lerpf(a.z, b.z, t))
		if Vector2(transform.origin.x, transform.origin.z).distance_to(expected) > 0.001:
			off_road += 1

	_check(max_error < 0.001, "荷車は地面から一定の高さに乗る",
		"最大誤差 %.4f" % max_error)
	_check(off_road == 0, "荷車は都市を結ぶ線分の上を進む",
		"%d 点が外れている" % off_road)

	# t=0 は出発地、t=1 は到着地に重なること（進みの向きが逆でない）。
	var start: Transform3D = world.convoy_transform_at(from_city, to_city, 0.0)
	var end: Transform3D = world.convoy_transform_at(from_city, to_city, 1.0)
	var start_gap: float = Vector2(start.origin.x, start.origin.z).distance_to(
		Vector2(world.positions[from_city].x, world.positions[from_city].z))
	var end_gap: float = Vector2(end.origin.x, end.origin.z).distance_to(
		Vector2(world.positions[to_city].x, world.positions[to_city].z))
	_check(start_gap < 0.001, "t=0 は出発地に重なる", "%.4f" % start_gap)
	_check(end_gap < 0.001, "t=1 は到着地に重なる", "%.4f" % end_gap)

	# 揺れは控えめで、浮き上がって見えない範囲に収まること。
	_check(MapView3D.CONVOY_BOB_AMOUNT < MapView3D.CONVOY_LIFT,
		"揺れ幅は浮かせる高さより小さい",
		"%.3f / %.3f" % [MapView3D.CONVOY_BOB_AMOUNT, MapView3D.CONVOY_LIFT])
	# 荷車が都市より大きいと、地図の主役が入れ替わって見える。
	_check(MapView3D.CONVOY_BODY_SIZE.y < MapView3D.CITY_HEIGHT * 0.5,
		"荷車は都市の柱より十分小さい",
		"%.2f / %.2f" % [MapView3D.CONVOY_BODY_SIZE.y, MapView3D.CITY_HEIGHT])

	# 隊商の数だけノードが出ること（増減が反映されないと、着いた荷車が
	# 地図に残り続ける）。
	var views: Array[Dictionary] = [
		{"id": 1, "from": from_city, "to": to_city, "t": 0.2, "color": Color.WHITE},
		{"id": 2, "from": to_city, "to": from_city, "t": 0.6, "color": Color.RED},
	]
	world.sync_convoys(views)
	_check(world.convoy_node_count() == 2, "隊商の数だけ荷車が出る",
		str(world.convoy_node_count()))

	views.remove_at(1)
	world.sync_convoys(views)
	_check(world.convoy_node_count() == 1, "着いた隊商の荷車は消える",
		str(world.convoy_node_count()))

	world.sync_convoys([])
	_check(world.convoy_node_count() == 0, "隊商が居なければ荷車も出ない",
		str(world.convoy_node_count()))

	world.free()


## 走行中の隊商がセーブを往復しても失われないこと。
##
## 隊商が消えると、地図の荷車が日送りのたびに湧いては消える。
## JSON を経由させるのは、数値が float 化しても壊れないことまで見るため。
func _test_save_round_trip() -> void:
	print("--- 隊商がセーブを往復する ---")
	var s: GameSession = GameSession.new(28004)
	for day: int in 8:
		s.rest()

	var before: int = s.logistics.active_count()
	_check(before > 0, "往復させる隊商が走っている", str(before))

	var json: String = JSON.stringify(s.to_dict())
	var restored: GameSession = GameSession.new(0)
	restored.from_dict(JSON.parse_string(json))

	_check(restored.logistics.active_count() == before,
		"隊商の本数が往復で保たれる",
		"%d -> %d" % [before, restored.logistics.active_count()])

	var same: int = 0
	for index: int in before:
		if restored.logistics.id_of(index) == s.logistics.id_of(index) \
				and restored.logistics.item_of(index) == s.logistics.item_of(index) \
				and restored.logistics.count_of(index) == s.logistics.count_of(index) \
				and restored.logistics.to_of(index) == s.logistics.to_of(index) \
				and is_equal_approx(restored.logistics.progress(index), s.logistics.progress(index)):
			same += 1
	_check(same == before, "隊商の中身と進みが往復で保たれる",
		"%d / %d 本が一致" % [same, before])

	# 物流を知らない古いセーブでも壊れないこと。
	var legacy: Dictionary = JSON.parse_string(json)
	legacy.erase("logistics")
	var from_legacy: GameSession = GameSession.new(0)
	from_legacy.from_dict(legacy)
	_check(from_legacy.logistics.active_count() == 0,
		"物流の無い古いセーブは隊商0本で読める",
		str(from_legacy.logistics.active_count()))
	# 読めるだけでなく、その後も回ること（次の日から隊商が出る）。
	from_legacy.rest()
	_check(from_legacy.market.stock_of(GameData.INITIAL_CITY, "wood") >= 0,
		"古いセーブから読んでも日送りが通る", "例外なし")


## 数値の歯止め。ここを緩めると物流が「飾り」か「作業ゲー」のどちらかに倒れる。
func _test_balance_guardrails() -> void:
	print("--- 物流の歯止め ---")

	# 隊商が地図を埋め尽くさないこと（絵として読めなくなる）。
	# 交易路の廃止で供給を隊商が全部担うようになり、必要な本数が増えた
	# （旧 20本以内 → 交易路の無い今は 30本前後が定常状態）。積載を上げて
	# 本数を抑える方針にしてあるので、ここが跳ね上がったら積載の側を疑う。
	_check(Logistics.MAX_ACTIVE_CONVOYS <= 50,
		"同時に走る隊商は50本以内", str(Logistics.MAX_ACTIVE_CONVOYS))
	_check(Logistics.MAX_DEPARTURES_PER_DAY >= 1,
		"毎日1本以上は出発しうる", str(Logistics.MAX_DEPARTURES_PER_DAY))

	# 到着の上限が 1.0 未満であること。1.0 だと満杯の都市へも送り出し、
	# 到着時に stock_cap で切り捨てられて荷が消える（質量保存が破れる）。
	_check(Logistics.ARRIVAL_STOCK_CEILING < 1.0,
		"満杯の都市へは送り出さない（到着した荷が消えない）",
		str(Logistics.ARRIVAL_STOCK_CEILING))

	# 産地を空にするまで搾り取らないこと。質量保存を入れて実際に効く線に
	# なった（以前は交易路が産地を減らさなかったのでめったに効かなかった）。
	_check(Logistics.DEPARTURE_STOCK_FLOOR > 0.0,
		"産地の在庫を空にしてまでは送り出さない",
		str(Logistics.DEPARTURE_STOCK_FLOOR))
	_check(Logistics.DEPARTURE_STOCK_FLOOR < 1.0,
		"産地の下限が高すぎて送り出せなくならない",
		str(Logistics.DEPARTURE_STOCK_FLOOR))

	# 輸入品が減り続けるだけ／増え続けるだけにならないこと。
	_check(GameData.IMPORT_DRAIN_RATE > 0.0 and GameData.IMPORT_DRAIN_RATE <= 1.0,
		"輸入品の消費は0より大きく消費量以下", str(GameData.IMPORT_DRAIN_RATE))

	# **品目ごとに、生産が消費を賄えること。**
	#
	# 交易路が品物を湧かせていた頃は、生産より消費が多くても差が埋まって
	# しまい、成立しない配分のまま気づけなかった（実測: 装備は生産9個/日に
	# 対し消費31個/日で、どんな物流でも埋められない赤字だった）。
	# 質量保存を入れた今、ここが赤字の品目は必ず慢性的な品切れになる。
	#
	# 合計ではなく**品目ごと**に見ること。資源が大幅に余っているので、
	# 合計だと装備の赤字が埋もれて素通りする。
	var deficit: int = 0
	var worst: String = ""
	for item_id: String in GameData.ITEMS:
		if GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.RARE:
			continue
		var produced: int = 0
		var consumed: int = 0
		for city_id: String in GameData.CITIES:
			produced += MarketTable.production_of(city_id, item_id)
			if MarketTable.production_of(city_id, item_id) > 0:
				continue
			if MarketTable.stock_cap(city_id, item_id) <= 0:
				continue
			consumed += MarketTable._import_drain_of(city_id, item_id)
		if produced < consumed:
			deficit += 1
			if worst == "":
				worst = "%s（生産 %d/日 < 消費 %d/日）" % [item_id, produced, consumed]
	_check(deficit == 0,
		"どの品目も生産が消費を賄える（物流で埋められない赤字が無い）",
		"%d 品目が赤字%s" % [deficit, ": %s" % worst if worst != "" else ""])

	# 交易路を廃止したので、供給の総量は「積載 × 出発本数」だけで決まる。
	# 世界の消費（実測 248個/日）を下回ると消費地は品切れへ向かう。
	var average_load: float = float(Logistics.CONVOY_LOAD_MIN
		+ Logistics.CONVOY_LOAD_MAX) / 2.0
	var throughput: float = average_load * float(Logistics.MAX_DEPARTURES_PER_DAY)
	_check(throughput >= float(LogisticsTuning.WORLD_DAILY_DRAIN),
		"隊商だけで世界の消費を賄える供給量がある",
		"供給 %.0f個/日 / 消費 %d個/日" % [
			throughput, LogisticsTuning.WORLD_DAILY_DRAIN])

	# 実際に必要な量を運べるだけの同時走行の枠があること。
	#
	# 「出発本数 × 拘束日数」で見ないこと。MAX_DEPARTURES_PER_DAY は
	# 買い占めからの回復用に余裕を持たせた上限で、定常状態では行き先が
	# 尽きて（_needs() が満杯の都市を候補から外す）そこまで出ない。
	# その式で挟むと、余裕を持たせるほど枠を増やせと言われる（実際に
	# そうなった）。見るべきは**消費を賄えるか**なので、リトルの法則を
	# 必要量の側から解く: 枠 ≧ 消費 ÷ 積載 × 拘束日数。
	var hold_days: float = LogisticsTuning.AVERAGE_HOPS * float(Logistics.DAYS_PER_HOP)
	var needed_active: float = float(LogisticsTuning.WORLD_DAILY_DRAIN) \
		/ average_load * hold_days
	_check(float(Logistics.MAX_ACTIVE_CONVOYS) >= needed_active,
		"同時走行の枠が世界の消費を運ぶのに足りている",
		"枠 %d / 要 %.0f（消費 %d ÷ 積載 %.0f × 拘束 %.1f日）" % [
			Logistics.MAX_ACTIVE_CONVOYS, needed_active,
			LogisticsTuning.WORLD_DAILY_DRAIN, average_load, hold_days])

	# 荷車の移動が日送りより遅いと、前日の進みが残って位置がずれていく。
	_check(MapView3D.CONVOY_TRAVEL_SECONDS <= 3.0,
		"荷車は1区間を3秒以内で詰める", str(MapView3D.CONVOY_TRAVEL_SECONDS))

	# 1区間が1日だと隊商の残り日数が常に区間の境目に一致し、leg_at() の t が
	# 必ず 0 になる。荷車が都市の真上にしか現れず、街道を進む絵が出ない
	# （実測でそうなった）。定数と、実際に t>0 の荷車が出ることの両方を見る。
	_check(Logistics.DAYS_PER_HOP >= 2,
		"1区間に2日以上かけて街道の途中に荷車が居る",
		str(Logistics.DAYS_PER_HOP))

	var s: GameSession = GameSession.new(28005)
	for day: int in 12:
		s.rest()
	var mid_road: int = 0
	for index: int in s.logistics.active_count():
		if s.logistics.leg_at(index)["t"] > 0.001:
			mid_road += 1
	_check(mid_road > 0, "実際に街道の途中に居る荷車がある",
		"%d / %d 本" % [mid_road, s.logistics.active_count()])
