extends "res://scripts/systems/scenario_base.gd"
## 運送デバッグ（logistics_tuning / logistics_stats / logistics_debug_panel /
## logistics_view_3d）の検証。
##
## この機能が守るべき約束は3つあり、どれも壊れても画面は動いたままになる。
##
##   1. **上書きが本当に効いていること。** スライダーを動かしてもロジックが
##      const を読み続けていたら、値は変わったのに挙動は変わらない。
##      「効かない」ことを目で確かめるのは難しい（隊商の本数は日によって
##      揺れるので、変わっていないのか偶然なのか判別できない）。極端な値を
##      入れて挙動が確実に変わる所を見る。
##
##   2. **既定値がずれていないこと。** 上書き層は既定値を Logistics から
##      受け取る作りなので、対応表（default_tuning()）に書き忘れた項目は
##      黙って 0 になる。0 でも動いてしまう項目（出発本数など）があるため、
##      const と1つずつ突き合わせる。
##
##   3. **図がデータと一致していること。** 3D 図は「見た目＝データ」を
##      優先して補間を入れていない（logistics_view_3d.gd 冒頭）。荷車が
##      街道から外れていても絵としては成立してしまうので、幾何で確かめる。
##
## 記録（logistics_stats.gd）については、集計をこのシナリオ側で独立に
## 積み直して突き合わせる。実装と同じ数え方を書き写すと、両方が同時に
## ずれたときに素通りする（CLAUDE.md）。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m31.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const Logistics = preload("res://scripts/systems/logistics.gd")
const LogisticsTuning = preload("res://scripts/systems/logistics_tuning.gd")
const LogisticsStats = preload("res://scripts/systems/logistics_stats.gd")
const LogisticsChart = preload("res://scripts/ui/logistics_chart.gd")
const LogisticsView3D = preload("res://scripts/ui/logistics_view_3d.gd")
const LogisticsDebugPanel = preload("res://scripts/ui/logistics_debug_panel.gd")
const LogisticsDebugWindow = preload("res://scripts/ui/logistics_debug_window.gd")

## 検査で回す日数。隊商が出発して到着するまでを十分含む長さにする
## （scenario_m28.gd と同じ理由・同じ長さ）。
const RUN_DAYS: int = 30

## シードは固定する。物流は RNG を消費するので、固定しないと本数が日替わりで
## 変わり、閾値を置いた検査が日によって落ちる。
const SEED: int = 20260817

## 位置の比較に使う許容誤差。lerp と三角関数を通るので厳密一致はしない。
const EPSILON: float = 0.001


func _init() -> void:
	_test_defaults_match_consts()
	_test_override_reaches_dispatch()
	_test_override_reaches_convoy_load()
	_test_mass_is_conserved()
	_test_clear_restores_defaults()
	_test_values_are_clamped_to_spec_range()
	_test_warnings_catch_documented_failures()
	_test_inverted_load_range_does_not_crash()
	_test_stats_records_one_entry_per_day()
	_test_shortage_counts_only_import_pairs()
	_test_delivered_totals_match_arrivals()
	_test_window_hosts_the_panel()
	_test_window_sits_beside_main()
	_test_panel_builds_every_view()
	_test_stock_chart_skips_shelfless_cities()
	_test_world_covers_every_travelable_edge()
	_test_world_places_convoys_on_roads()
	_test_world_bar_height_follows_stock()
	_finish()


## シードを固定したセッション。
func _make_session() -> GameSession:
	return GameSession.new(SEED)


func _advance(session: GameSession, days: int) -> void:
	for i: int in days:
		session.rest()


# --- 上書き層 ---

## 既定値が logistics.gd の const と1つずつ一致すること。
##
## default_tuning() の対応表に書き忘れた項目は 0 になる。0 でも動いてしまう
## 項目があるので、「上書きしていなければ const と同じ」を全項目で見る。
func _test_defaults_match_consts() -> void:
	print("--- 上書き層: 既定値が const と一致する ---")
	var tuning := LogisticsTuning.new(Logistics.default_tuning())

	var expected: Dictionary = {
		LogisticsTuning.MAX_DEPARTURES_PER_DAY: float(Logistics.MAX_DEPARTURES_PER_DAY),
		LogisticsTuning.MAX_ACTIVE_CONVOYS: float(Logistics.MAX_ACTIVE_CONVOYS),
		LogisticsTuning.CONVOY_LOAD_MIN: float(Logistics.CONVOY_LOAD_MIN),
		LogisticsTuning.CONVOY_LOAD_MAX: float(Logistics.CONVOY_LOAD_MAX),
		LogisticsTuning.DEPARTURE_STOCK_FLOOR: Logistics.DEPARTURE_STOCK_FLOOR,
		LogisticsTuning.ARRIVAL_STOCK_CEILING: Logistics.ARRIVAL_STOCK_CEILING,
		LogisticsTuning.DAYS_PER_HOP: float(Logistics.DAYS_PER_HOP),
	}

	# SPECS に項目を足して default_tuning() へ足し忘れると、その項目は
	# ここの expected にも無い＝素通りする。件数も突き合わせる。
	_check(LogisticsTuning.SPECS.size() == expected.size(),
		"SPECS の項目数と既定値の対応表の件数が一致する",
		"SPECS %d / 対応表 %d" % [LogisticsTuning.SPECS.size(), expected.size()])

	for key: String in expected:
		_check(is_equal_approx(tuning.value_of(key), float(expected[key])),
			"既定値が const と一致する: %s" % key,
			"%f（const は %f）" % [tuning.value_of(key), float(expected[key])])

	_check(not tuning.has_overrides(), "作った直後は上書きが無い",
		"上書き %d 件" % tuning.overridden_keys().size())


## 出発本数の上書きがロジックへ届くこと。
##
## 「値を書いたら読める」ではなく、**隊商の本数が実際に変わる**ことを見る。
## ロジックが const を読み続けていても、値の読み書きだけの検査は通ってしまう。
func _test_override_reaches_dispatch() -> void:
	print("--- 上書き層: 出発本数がロジックへ届く ---")

	var stopped := _make_session()
	stopped.logistics.tuning.set_override(LogisticsTuning.MAX_DEPARTURES_PER_DAY, 0.0)
	_advance(stopped, RUN_DAYS)
	_check(stopped.logistics.active_count() == 0,
		"出発本数を0にすると隊商が1本も走らない",
		"%d 本" % stopped.logistics.active_count())

	var running := _make_session()
	_advance(running, RUN_DAYS)
	_check(running.logistics.active_count() > 0,
		"上書きしなければ隊商は走る（0本の原因が上書きだと言える）",
		"%d 本" % running.logistics.active_count())


## 積載の上書きが供給へ届くこと。
##
## 交易路を廃止したので、供給の総量は「積載 × 出発本数」だけで決まる。
## 積載を絞れば非生産地の在庫の合計は必ず減る。隊商は RNG で行き先が
## 変わるので1都市では揺れるが、全都市の合計なら向きは決まる。
func _test_override_reaches_convoy_load() -> void:
	print("--- 上書き層: 積載が供給へ届く ---")

	var thin := _make_session()
	thin.logistics.tuning.set_override(LogisticsTuning.CONVOY_LOAD_MIN, 1.0)
	thin.logistics.tuning.set_override(LogisticsTuning.CONVOY_LOAD_MAX, 2.0)
	_advance(thin, RUN_DAYS)

	var thick := _make_session()
	_advance(thick, RUN_DAYS)

	var thin_total: int = _import_stock_total(thin)
	var thick_total: int = _import_stock_total(thick)
	_check(thick_total > thin_total,
		"積載を絞ると非生産地の在庫の合計が減る",
		"積載1〜2 で %d / 既定 で %d" % [thin_total, thick_total])


## **品物が湧かないこと。** 交易路を廃止した理由そのものなので、ここが
## この機能の中心の検査になる。
##
## 品目ごとに「全都市の在庫 + 走行中の隊商が積んでいる量」を数え、1日ぶん
## 進めた前後で比べる。増えてよいのは生産（production_of の合計）の分だけで、
## 減ってよいのは消費（_import_drain_of の合計）と、在庫の上限で切られた分。
## 交易路のように「どこからともなく増える」経路があると、増分が生産量を
## 超えるので落ちる。
##
## 上限での切り捨てを許すと「減る側」がざるになるため、**溢れが1件も
## 起きていないこと**も併せて見る（_launch() が送り先の空きに積載を合わせて
## いるので、正しく実装されていれば溢れない）。
func _test_mass_is_conserved() -> void:
	print("--- 質量保存: 品物が湧かない ---")

	var session := _make_session()
	# 走行中の隊商が居る状態から見る。初日は空なので、積んだまま日を
	# またぐ経路（在庫にも市場にも無い量）を検査に含められない。
	_advance(session, 10)

	var violations: int = 0
	var worst: String = ""
	for day: int in RUN_DAYS:
		# 品目ごとに、進める前後の総量を突き合わせる。
		#
		# 許容する増分は**実際に棚へ乗る生産量**にすること。名目の生産量
		# （production_of の合計）で挟むと、産地が上限に張り付いている間は
		# 捨てられるぶんが「増えてよい枠」として残り、そのぶん湧いていても
		# 素通りする（実測: sword は名目16個/日 に対し実際に乗るのは3個/日
		# で、13個ぶんの隙間があった。積んだ量の半分しか産地から引かない
		# 壊し方を入れても、この検査は落ちなかった）。
		var before: Dictionary = {}
		var allowed: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			before[item_id] = _world_total_of(session, item_id)
			allowed[item_id] = _production_that_fits(session, item_id)

		session.rest()

		for item_id: String in GameData.ITEMS:
			var after: int = _world_total_of(session, item_id)
			# 実際に乗る生産を超えて増えていたら、どこかで湧いている。
			if after > int(before[item_id]) + int(allowed[item_id]):
				violations += 1
				if worst == "":
					worst = "%s: %d → %d（棚に乗る生産は %d/日）" % [
						item_id, int(before[item_id]), after, int(allowed[item_id])]

	_check(violations == 0,
		"%d日を通して、在庫＋輸送中の合計が生産量を超えて増えない" % RUN_DAYS,
		"%d 件で湧いた%s" % [violations, "（例 %s）" % worst if worst != "" else ""])

	# 積んだ荷が到着時に上限で切り捨てられていないこと。**「増えない」だけ
	# では保存の半分しか見ていない**（消える側は総量が減るので上の検査は
	# 通ってしまう）。Logistics が起きた場所で数えた値を読む。
	_check(session.logistics.spilled_total == 0,
		"到着した荷が在庫の上限で切り捨てられない（積んだ分は必ず降りる）",
		"%d 個が消えた" % session.logistics.spilled_total)

	# 検査が本当に効いているかの裏取り。生産のある品目が実際に動いて
	# いなければ、上の2つは「何も起きていない」だけで通ってしまう。
	var moved: int = 0
	for item_id: String in GameData.ITEMS:
		if _daily_production_of(item_id) > 0:
			moved += 1
	_check(moved > 0, "生産のある品目が存在する（検査の前提）", "%d 品目" % moved)
	_check(session.logistics.active_count() > 0,
		"検査の終わりに隊商が走っている（輸送中の量を数えている）",
		"%d 本" % session.logistics.active_count())


## 世界にあるその品目の総量（全都市の在庫 + 走行中の隊商の積荷）。
func _world_total_of(session: GameSession, item_id: String) -> int:
	var total: int = 0
	for city_id: String in GameData.CITIES:
		total += session.market.stock_of(city_id, item_id)
	for index: int in session.logistics.active_count():
		if session.logistics.item_of(index) == item_id:
			total += session.logistics.count_of(index)
	return total


## その品目が1日に世界全体で何個生産されるか（名目）。
func _daily_production_of(item_id: String) -> int:
	var total: int = 0
	for city_id: String in GameData.CITIES:
		total += MarketTable.production_of(city_id, item_id)
	return total


## そのうち、**実際に棚へ乗る**ぶん。産地が在庫の上限に張り付いていると
## 生産は切り捨てられるので、名目より小さくなる（多くの日はこちらが 0 に近い）。
## 質量保存の許容増分はこちらで測る。
func _production_that_fits(session: GameSession, item_id: String) -> int:
	var total: int = 0
	for city_id: String in GameData.CITIES:
		var produced: int = MarketTable.production_of(city_id, item_id)
		if produced <= 0:
			continue
		var room: int = MarketTable.stock_cap(city_id, item_id) \
			- session.market.stock_of(city_id, item_id)
		total += clampi(room, 0, produced)
	return total


## 品切れしている「都市×品目」の組の数（輸入が要る組だけ）。
func _shortage_count(session: GameSession) -> int:
	var count: int = 0
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if MarketTable.production_of(city_id, item_id) > 0:
				continue
			if MarketTable.stock_cap(city_id, item_id) <= 0:
				continue
			if session.market.stock_of(city_id, item_id) <= 0:
				count += 1
	return count


## 輸入で賄う「都市×品目」の在庫の合計。
func _import_stock_total(session: GameSession) -> int:
	var total: int = 0
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if MarketTable.production_of(city_id, item_id) > 0:
				continue
			if MarketTable.stock_cap(city_id, item_id) <= 0:
				continue
			total += session.market.stock_of(city_id, item_id)
	return total


## 上書きを消すと const の値へ戻ること。
func _test_clear_restores_defaults() -> void:
	print("--- 上書き層: 消すと既定値へ戻る ---")
	var tuning := LogisticsTuning.new(Logistics.default_tuning())

	tuning.set_override(LogisticsTuning.DAYS_PER_HOP, 5.0)
	_check(tuning.int_of(LogisticsTuning.DAYS_PER_HOP) == 5,
		"上書きした値が読める", "%d" % tuning.int_of(LogisticsTuning.DAYS_PER_HOP))
	_check(tuning.is_overridden(LogisticsTuning.DAYS_PER_HOP),
		"上書き中だと分かる", "上書きされていない")
	_check(is_equal_approx(tuning.default_of(LogisticsTuning.DAYS_PER_HOP),
			float(Logistics.DAYS_PER_HOP)),
		"上書き中でも既定値は const のまま読める",
		"%f" % tuning.default_of(LogisticsTuning.DAYS_PER_HOP))

	tuning.clear_override(LogisticsTuning.DAYS_PER_HOP)
	_check(tuning.int_of(LogisticsTuning.DAYS_PER_HOP) == Logistics.DAYS_PER_HOP,
		"1項目を消すと const の値へ戻る",
		"%d" % tuning.int_of(LogisticsTuning.DAYS_PER_HOP))

	tuning.set_override(LogisticsTuning.CONVOY_LOAD_MAX, 2.0)
	tuning.set_override(LogisticsTuning.MAX_ACTIVE_CONVOYS, 30.0)
	tuning.clear_all()
	_check(not tuning.has_overrides(), "全部消すと上書きが無くなる",
		"上書き %d 件" % tuning.overridden_keys().size())
	_check(is_equal_approx(tuning.value_of(LogisticsTuning.CONVOY_LOAD_MAX),
			float(Logistics.CONVOY_LOAD_MAX)),
		"全部消した後も const の値へ戻る",
		"%f" % tuning.value_of(LogisticsTuning.CONVOY_LOAD_MAX))


## SPECS の範囲外を渡しても範囲へ丸まること（弾かずに丸める仕様）。
func _test_values_are_clamped_to_spec_range() -> void:
	print("--- 上書き層: 範囲へ丸める ---")
	var tuning := LogisticsTuning.new(Logistics.default_tuning())

	for spec: Dictionary in LogisticsTuning.SPECS:
		var key: String = spec["key"]
		tuning.set_override(key, float(spec["max"]) + 1000.0)
		_check(tuning.value_of(key) <= float(spec["max"]) + EPSILON,
			"上限を超えた値は上限へ丸まる: %s" % key,
			"%f（上限 %f）" % [tuning.value_of(key), float(spec["max"])])
		tuning.set_override(key, float(spec["min"]) - 1000.0)
		_check(tuning.value_of(key) >= float(spec["min"]) - EPSILON,
			"下限を下回った値は下限へ丸まる: %s" % key,
			"%f（下限 %f）" % [tuning.value_of(key), float(spec["min"])])

	# int の項目に小数を入れても整数になること。SpinBox の step は 1 だが、
	# set_override() を直接呼ぶ経路（検査・将来の入口）では小数が入りうる。
	tuning.set_override(LogisticsTuning.DAYS_PER_HOP, 3.7)
	_check(is_equal_approx(tuning.value_of(LogisticsTuning.DAYS_PER_HOP), 4.0),
		"int の項目は整数へ丸まる",
		"%f" % tuning.value_of(LogisticsTuning.DAYS_PER_HOP))


## logistics.gd のコメントが「そうすると壊れる」と書いている組み合わせを
## 警告が拾うこと。既定値では1件も出ないこと。
func _test_warnings_catch_documented_failures() -> void:
	print("--- 上書き層: 壊れる組み合わせを警告する ---")

	var clean := LogisticsTuning.new(Logistics.default_tuning())
	_check(clean.warnings().is_empty(),
		"既定値では警告が出ない",
		"%d 件: %s" % [clean.warnings().size(), "／".join(clean.warnings())])

	# 供給が消費に足りない組み合わせ。交易路が無いので、積載を絞ると
	# そのまま非生産地が痩せる（旧来はここを絞っても交易路が埋めていた）。
	var starved := LogisticsTuning.new(Logistics.default_tuning())
	starved.set_override(LogisticsTuning.CONVOY_LOAD_MIN, 1.0)
	starved.set_override(LogisticsTuning.CONVOY_LOAD_MAX, 2.0)
	_check(not starved.warnings().is_empty(),
		"供給が世界の消費を下回ると警告する", "警告なし")

	# 実際にその状態にすると品切れが増えること。警告の文面が正しいかどうかは
	# 文字列を見ても分からないので、書いてある通りになるかを回して確かめる。
	var thin := _make_session()
	thin.logistics.tuning.set_override(LogisticsTuning.CONVOY_LOAD_MIN, 1.0)
	thin.logistics.tuning.set_override(LogisticsTuning.CONVOY_LOAD_MAX, 2.0)
	_advance(thin, RUN_DAYS)

	var healthy := _make_session()
	_advance(healthy, RUN_DAYS)
	_check(_shortage_count(thin) > _shortage_count(healthy),
		"警告どおり、供給が足りないと品切れが増える",
		"薄い %d 組 / 既定 %d 組"
			% [_shortage_count(thin), _shortage_count(healthy)])

	# 到着の上限 1.00 は荷が溢れて消える（質量保存が破れる）。
	var spilling := LogisticsTuning.new(Logistics.default_tuning())
	spilling.set_override(LogisticsTuning.ARRIVAL_STOCK_CEILING, 1.0)
	_check(not spilling.warnings().is_empty(),
		"到着の上限が 1.00 だと警告する", "警告なし")

	var one_hop := LogisticsTuning.new(Logistics.default_tuning())
	one_hop.set_override(LogisticsTuning.DAYS_PER_HOP, 1.0)
	_check(not one_hop.warnings().is_empty(),
		"1区間1日だと警告する", "警告なし")

	# 1区間1日にすると leg_at() の t が必ず 0 になる、という実測の再現。
	# これが荷車が都市の真上にしか出ない原因（logistics.gd の DAYS_PER_HOP）。
	var flat := _make_session()
	flat.logistics.tuning.set_override(LogisticsTuning.DAYS_PER_HOP, 1.0)
	_advance(flat, RUN_DAYS)
	var moving: int = 0
	for index: int in flat.logistics.active_count():
		if float(flat.logistics.leg_at(index)["t"]) > EPSILON:
			moving += 1
	_check(flat.logistics.active_count() > 0,
		"1区間1日でも隊商は走る（0本だと次の検査が無意味）",
		"%d 本" % flat.logistics.active_count())
	_check(moving == 0,
		"警告どおり、1区間1日では街道の途中に居る隊商が1本も出ない",
		"走行中 %d 本のうち途中に居るのが %d 本"
			% [flat.logistics.active_count(), moving])


## 積載の下限＞上限でも落ちないこと。
##
## randi_range() は逆順を渡すとエラーになる。上書き層は組み合わせを弾かず
## 警告するだけなので、この状態は実際に作れてしまう。
func _test_inverted_load_range_does_not_crash() -> void:
	print("--- 上書き層: 積載の下限＞上限でも走る ---")

	var session := _make_session()
	session.logistics.tuning.set_override(LogisticsTuning.CONVOY_LOAD_MIN, 30.0)
	session.logistics.tuning.set_override(LogisticsTuning.CONVOY_LOAD_MAX, 5.0)
	_advance(session, RUN_DAYS)

	_check(session.logistics.active_count() > 0,
		"下限＞上限でも隊商は走る（落ちない）",
		"%d 本" % session.logistics.active_count())

	var over: int = 0
	for index: int in session.logistics.active_count():
		if session.logistics.count_of(index) > 5:
			over += 1
	_check(over == 0, "積載は上限側（5個）へ丸められる",
		"上限を超える隊商が %d 本" % over)

	_check(not session.logistics.tuning.warnings().is_empty(),
		"下限＞上限は警告される", "警告なし")


# --- 記録 ---

## 同じ日に何度記録しても日数が増えないこと。
##
## パネルの refresh() は移動や取引でも走る。呼ばれた回数で日数が増えると、
## グラフの横軸が実際の経過日数と食い違う（そして横軸のラベルは
## 「N日目」と出るので、ずれていても正しく見える）。
func _test_stats_records_one_entry_per_day() -> void:
	print("--- 記録: 1日1件 ---")

	var session := _make_session()
	var stats := LogisticsStats.new()

	stats.record(session.day, session.logistics, session.market)
	stats.record(session.day, session.logistics, session.market)
	stats.record(session.day, session.logistics, session.market)
	_check(stats.day_count() == 1, "同じ日に3回記録しても1件",
		"%d 件" % stats.day_count())

	session.rest()
	stats.record(session.day, session.logistics, session.market)
	_check(stats.day_count() == 2, "日が進めば増える", "%d 件" % stats.day_count())
	_check(stats.last_day() == session.day, "末尾の日が今の日と一致する",
		"記録 %d / セッション %d" % [stats.last_day(), session.day])

	stats.clear()
	_check(stats.day_count() == 0, "clear() で記録が消える",
		"%d 件" % stats.day_count())


## 品切れの数え方が「輸入が要る組」に閉じていること。
##
## 全在庫を空にすれば、品切れ数は母数と一致するはず。産地や棚の無い組まで
## 数えていれば母数を超え、逆に数え漏らせば下回る。
func _test_shortage_counts_only_import_pairs() -> void:
	print("--- 記録: 品切れは輸入が要る組だけ数える ---")

	var denominator: int = LogisticsStats.shortage_denominator()
	var all_pairs: int = GameData.CITIES.size() * GameData.ITEMS.size()
	_check(denominator > 0 and denominator < all_pairs,
		"母数は全組より少なく、0ではない",
		"%d 組（全 %d 組）" % [denominator, all_pairs])

	var session := _make_session()
	var stats := LogisticsStats.new()

	# 全ての棚を空にする。consume_stock() は上限で止まるので、
	# 在庫より大きい数を渡せば0になる。
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			session.market.consume_stock(city_id, item_id,
				session.market.stock_of(city_id, item_id))

	stats.record(session.day, session.logistics, session.market)
	var shortage: int = int(stats.latest().get("shortage", -1))
	_check(shortage == denominator,
		"全在庫を空にすると品切れ数が母数と一致する",
		"品切れ %d / 母数 %d" % [shortage, denominator])


## 品目ごとの搬入量が、実際の到着と一致すること。
##
## 集計はこのシナリオ側でも独立に積み直す。実装と同じ数え方を書き写すと
## 両方が同時にずれたときに素通りする（CLAUDE.md）。
func _test_delivered_totals_match_arrivals() -> void:
	print("--- 記録: 搬入量が到着と一致する ---")

	var session := _make_session()
	var stats := LogisticsStats.new()
	var expected: Dictionary = {}

	stats.record(session.day, session.logistics, session.market)
	for i: int in RUN_DAYS:
		session.rest()
		# 記録より先に、この日の到着を自前で足す。
		for convoy: Dictionary in session.logistics.last_arrived():
			var item_id: String = convoy["item"]
			expected[item_id] = int(expected.get(item_id, 0)) + int(convoy["count"])
		stats.record(session.day, session.logistics, session.market)

	var totals: Dictionary = stats.delivered_totals(LogisticsStats.MAX_DAYS)
	var arrivals: int = 0
	for item_id: String in expected:
		arrivals += int(expected[item_id])
	_check(arrivals > 0, "検査の期間中に隊商が着いている（0件だと以下が無意味）",
		"%d 個" % arrivals)

	var mismatched: int = 0
	for item_id: String in GameData.ITEMS:
		if int(totals.get(item_id, 0)) != int(expected.get(item_id, 0)):
			mismatched += 1
	_check(mismatched == 0, "品目ごとの搬入量が自前の集計と一致する",
		"%d 品目でずれた" % mismatched)

	# 直近1日ぶんは、その日の到着だけに一致する。期間の切り出しが
	# できていないと、全期間と同じ値が返る。
	var last_day_totals: Dictionary = stats.delivered_totals(1)
	var last_day_sum: int = 0
	for item_id: String in last_day_totals:
		last_day_sum += int(last_day_totals[item_id])
	var actual_last: int = 0
	for convoy: Dictionary in session.logistics.last_arrived():
		actual_last += int(convoy["count"])
	_check(last_day_sum == actual_last,
		"直近1日の集計はその日の到着と一致する",
		"集計 %d / 実際 %d" % [last_day_sum, actual_last])


# --- ウィンドウ ---

## 別ウィンドウが中身を抱え、開閉と bind を素通しすること。
##
## **root へ入れない。** Window はツリーに入った時点で実体を作りにいくので、
## ヘッドレスの検査で native のウィンドウを開こうとすることになる。ここで
## 見たいのは「どう組まれているか」だけなので、ツリー外のまま確かめる
## （docs/rules/ui.md の「Window 系はツリー外だとエラーになる」の裏返しで、
## ツリーに入れないぶんには property の確認はできる）。
func _test_window_hosts_the_panel() -> void:
	print("--- ウィンドウ: 別ウィンドウとして組まれる ---")

	var window := LogisticsDebugWindow.new()

	# ここが false だと、親ビューポートの gui_embed_subwindows に従って
	# 本編のウィンドウの中に埋め込まれる＝オーバーレイに戻る。
	# 見た目では「窓っぽいもの」が出るので、目視では気づきにくい。
	_check(window.force_native, "OS の別ウィンドウとして出す設定になっている",
		"force_native=%s" % window.force_native)
	_check(not window.exclusive,
		"排他ではない（本編が入力を受け取り続ける）",
		"exclusive=%s" % window.exclusive)
	_check(not window.transient,
		"追従しない（別モニタへ出して置いておける）",
		"transient=%s" % window.transient)

	_check(window.panel() != null, "中身のパネルを抱えている", "null")
	_check(window.size == LogisticsDebugWindow.DEFAULT_SIZE,
		"開いたときの大きさが既定と一致する", str(window.size))
	# 調整欄が横スクロールに隠れない幅を下限にしてある。下限がグラフ＋調整欄
	# より狭いと、縮めた瞬間に何のための窓か分からなくなる。
	_check(window.min_size.x >= int(LogisticsDebugPanel.CHART_WIDTH)
			+ LogisticsDebugPanel.TUNING_WIDTH,
		"縮められる下限が、グラフ幅＋調整欄の幅を下回らない",
		"下限 %d / グラフ %d + 調整 %d" % [window.min_size.x,
			int(LogisticsDebugPanel.CHART_WIDTH), LogisticsDebugPanel.TUNING_WIDTH])

	# 開閉の初期状態。OPEN_ON_START を切り替えたときに実際の visible が
	# 追従しているかを見る（定数だけ変えて代入を直し忘れると、値は変わって
	# いるのに窓は前のまま——しかもエラーは出ない）。
	_check(window.visible == LogisticsDebugWindow.OPEN_ON_START,
		"起動直後の開閉が OPEN_ON_START と一致する",
		"visible=%s / OPEN_ON_START=%s"
			% [window.visible, LogisticsDebugWindow.OPEN_ON_START])

	window.toggle_visible()
	_check(window.visible != LogisticsDebugWindow.OPEN_ON_START,
		"F5（toggle_visible）で開閉が反転する", "visible=%s" % window.visible)
	window.toggle_visible()
	_check(window.visible == LogisticsDebugWindow.OPEN_ON_START,
		"もう一度で戻る", "visible=%s" % window.visible)

	# タイトルバーの×は close_requested を出すだけ。ここで解放してしまうと
	# 次に F5 を押したときに解放済みのノードを触ることになる。
	window.hide_window()
	_check(not window.visible and is_instance_valid(window.panel()),
		"閉じても中身は残る（×で解放しない）",
		"visible=%s / panel=%s" % [window.visible, window.panel()])

	# bind と refresh の素通し。窓が受けてパネルへ渡していないと、
	# main.gd の _panels 経由の更新が全く効かない（画面は最初の状態のまま）。
	var session := _make_session()
	_advance(session, 3)
	window.bind(session)
	_check(window.panel().session() == session,
		"bind() が中身のパネルへ届く", "届いていない")
	_check(window.panel().stats().day_count() >= 1,
		"閉じている間も記録される（開くまで空にならない）",
		"%d 日" % window.panel().stats().day_count())

	var before: int = window.panel().stats().day_count()
	session.rest()
	window.refresh()
	_check(window.panel().stats().day_count() == before + 1,
		"refresh() が中身のパネルへ届く",
		"%d → %d 日" % [before, window.panel().stats().day_count()])

	window.free()


# --- パネル ---

## 4つのビューがすべて組み立てられること。
func _test_panel_builds_every_view() -> void:
	print("--- パネル: 4つのビューが組める ---")

	var session := _make_session()
	_advance(session, RUN_DAYS)

	var panel := LogisticsDebugPanel.new()
	root.add_child(panel)
	panel.bind(session)

	_check(panel.stats().day_count() >= 1,
		"bind() で記録が始まる", "%d 日" % panel.stats().day_count())

	panel.show_view(LogisticsDebugPanel.View.TREND)
	_check(panel.current_view() == LogisticsDebugPanel.View.TREND,
		"推移ビューへ切り替わる", "%d" % panel.current_view())
	_check(panel.chart().series_count() == 4,
		"推移は4本の線（走行中・出発・到着・品切れ率）",
		"%d 本" % panel.chart().series_count())
	_check(panel.chart().mode() == LogisticsChart.Mode.LINE,
		"推移は折れ線", "%d" % panel.chart().mode())

	panel.show_view(LogisticsDebugPanel.View.FLOW)
	_check(panel.chart().mode() == LogisticsChart.Mode.BAR,
		"流量は横棒", "%d" % panel.chart().mode())
	_check(panel.chart().bar_count() == GameData.ITEMS.size(),
		"流量は全品目ぶんの棒", "%d 本（全 %d 品目）"
			% [panel.chart().bar_count(), GameData.ITEMS.size()])

	panel.show_view(LogisticsDebugPanel.View.WORLD)
	_check(panel.world().item_id() == panel.current_item(),
		"立体ビューは選択中の品目を描く",
		"図 %s / 選択 %s" % [panel.world().item_id(), panel.current_item()])

	_check(panel.summary_text().contains("走行中"),
		"下の要約に走行中の本数が出る", panel.summary_text())

	# 上書きの入口。パネル経由で set_tuning() したら Logistics 側に届くこと
	# （パネルが自前の辞書に溜めているだけだと、値は表示されるのに効かない）。
	panel.set_tuning(LogisticsTuning.MAX_ACTIVE_CONVOYS, 40.0)
	_check(session.logistics.tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS) == 40,
		"パネルからの上書きが Logistics に届く",
		"%d" % session.logistics.tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS))
	_check(panel.warning_text() == "",
		"健全な値では警告が出ない", panel.warning_text())

	panel.set_tuning(LogisticsTuning.CONVOY_LOAD_MIN, 1.0)
	panel.set_tuning(LogisticsTuning.CONVOY_LOAD_MAX, 2.0)
	_check(panel.warning_text() != "",
		"壊れる組み合わせにすると警告が出る", "空のまま")

	panel.reset_all_tuning()
	_check(not session.logistics.tuning.has_overrides(),
		"パネルから全部戻せる",
		"上書き %d 件" % session.logistics.tuning.overridden_keys().size())

	_despawn(panel)


## 在庫ビューが、棚の無い都市の線を出さないこと。
##
## 棚が無い都市は常に0の線になる。19品目のうち何本かは必ずこうなり、
## 底に張り付いた線が積み上がると他の線が読めなくなる。
func _test_stock_chart_skips_shelfless_cities() -> void:
	print("--- パネル: 棚の無い都市は在庫グラフに出ない ---")

	var session := _make_session()
	_advance(session, 3)

	var panel := LogisticsDebugPanel.new()
	root.add_child(panel)
	panel.bind(session)
	panel.show_view(LogisticsDebugPanel.View.STOCK)

	# 棚の無い都市がある品目を探す。1つも無ければこの検査は何も見ていない
	# ことになるので、そのこと自体を失敗として出す。
	var target: String = ""
	for item_id: String in GameData.ITEMS:
		for city_id: String in GameData.CITIES:
			if MarketTable.stock_cap(city_id, item_id) <= 0:
				target = item_id
				break
		if target != "":
			break
	_check(target != "", "棚の無い都市がある品目が存在する（検査の前提）", "見つからない")
	if target == "":
		_despawn(panel)
		return

	panel.select_item(target)
	var with_shelf: int = 0
	for city_id2: String in GameData.CITIES:
		if MarketTable.stock_cap(city_id2, target) > 0:
			with_shelf += 1
	_check(panel.chart().series_count() == with_shelf,
		"線の本数が、棚のある都市の数と一致する",
		"線 %d 本 / 棚のある都市 %d"
			% [panel.chart().series_count(), with_shelf])
	_check(with_shelf < GameData.CITIES.size(),
		"実際に間引かれている（全都市そのままではない）",
		"%d / %d 都市" % [with_shelf, GameData.CITIES.size()])

	_despawn(panel)


# --- 3D 図 ---

## 隊商が通れる辺すべてに街道が引かれていること。
##
## logistics.gd の _neighbors_of() は王道に黒ゾーンのゲートを足す。図が
## 王道だけを引くと、レイヴンスパイア発着の隊商が「道の無い所」を走って見える。
func _test_world_covers_every_travelable_edge() -> void:
	print("--- 3D図: 隊商が通れる辺すべてに街道がある ---")

	var world := LogisticsView3D.new()

	# 期待する辺をこのシナリオ側で数え直す（実装の _all_edges() は呼ばない）。
	var expected: Dictionary = {}
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		var a: String = edge[0]
		var b: String = edge[1]
		expected["%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]] = true
	for gate: String in GameData.BLACK_ZONE_GATES:
		var c: String = GameData.CAERLEON
		expected["%s|%s" % [c, gate] if c < gate else "%s|%s" % [gate, c]] = true

	_check(world.road_count() == expected.size(),
		"街道の本数が、隊商が通れる辺の数と一致する",
		"図 %d 本 / 期待 %d 本" % [world.road_count(), expected.size()])

	var missing: int = 0
	for edge2: Array in GameData.ROYAL_ROAD_EDGES:
		if world.road_of(edge2[0], edge2[1]) == null:
			missing += 1
	for gate2: String in GameData.BLACK_ZONE_GATES:
		if world.road_of(GameData.CAERLEON, gate2) == null:
			missing += 1
	_check(missing == 0, "個々の辺が引ける（向きを入れ替えても同じ辺）",
		"%d 本が無い" % missing)

	# 都市の棒とラベルが全都市ぶんある。
	var absent: int = 0
	for city_id: String in GameData.CITIES:
		if world.city_bar_of(city_id) == null or world.city_label_of(city_id) == null:
			absent += 1
	_check(absent == 0, "全都市に棒とラベルがある", "%d 都市が欠けている" % absent)

	world.free()


## 隊商の点が街道の線分の上に乗っていること。
##
## 位置は lerp で作っているが、検査は「線分までの距離が0」という別の性質で
## 見る。同じ lerp を書き写すと、両方が同時にずれたときに素通りする。
func _test_world_places_convoys_on_roads() -> void:
	print("--- 3D図: 隊商が街道の上に乗る ---")

	var session := _make_session()
	_advance(session, RUN_DAYS)

	var world := LogisticsView3D.new()
	world.sync(session.market, session.logistics, GameData.resource_ids()[0])

	_check(session.logistics.active_count() > 0,
		"検査の時点で隊商が走っている（0本だと以下が無意味）",
		"%d 本" % session.logistics.active_count())
	_check(world.convoy_node_count() == session.logistics.active_count(),
		"点の数が走行中の隊商の本数と一致する",
		"点 %d / 隊商 %d"
			% [world.convoy_node_count(), session.logistics.active_count()])

	var off_road: int = 0
	var wrong_height: int = 0
	for index: int in session.logistics.active_count():
		var node: MeshInstance3D = world.convoy_node_of(session.logistics.id_of(index))
		if node == null:
			off_road += 1
			continue
		var leg: Dictionary = session.logistics.leg_at(index)
		var from_pos: Vector3 = world.ground_position_of(leg["from"])
		var to_pos: Vector3 = world.ground_position_of(leg["to"])
		# 高さぶんを落として、地面の線分と比べる。
		var flat := Vector3(node.position.x, 0.0, node.position.z)
		if _distance_to_segment(flat, from_pos, to_pos) > EPSILON:
			off_road += 1
		if not is_equal_approx(node.position.y, LogisticsView3D.CONVOY_LIFT):
			wrong_height += 1

	_check(off_road == 0, "すべての点が、その隊商が今いる区間の線分の上にある",
		"%d 本が街道から外れている" % off_road)
	_check(wrong_height == 0, "点の高さが CONVOY_LIFT で揃っている",
		"%d 本がずれている" % wrong_height)

	world.free()


## 点から線分までの距離。
func _distance_to_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var delta: Vector3 = b - a
	var length_squared: float = delta.length_squared()
	if length_squared <= 0.0:
		return point.distance_to(a)
	var t: float = clampf((point - a).dot(delta) / length_squared, 0.0, 1.0)
	return point.distance_to(a + delta * t)


## 都市の棒の高さが在庫に従うこと。
##
## 在庫を空にした都市と満たした都市を作り、高さの大小を見る。倍率をここで
## 計算し直すと実装の式を書き写すことになるので、**順序だけ**を見る。
func _test_world_bar_height_follows_stock() -> void:
	print("--- 3D図: 棒の高さが在庫に従う ---")

	var session := _make_session()
	var item_id: String = GameData.resource_ids()[0]

	# 棚のある都市を2つ選ぶ。片方を空に、片方を上限まで満たす。
	var shelved: Array[String] = []
	for city_id: String in GameData.CITIES:
		if MarketTable.stock_cap(city_id, item_id) > 0:
			shelved.append(city_id)
	_check(shelved.size() >= 2, "棚のある都市が2つ以上ある（検査の前提）",
		"%d 都市" % shelved.size())
	if shelved.size() < 2:
		return

	var empty_city: String = shelved[0]
	var full_city: String = shelved[1]
	session.market.consume_stock(empty_city, item_id,
		session.market.stock_of(empty_city, item_id))
	session.market.receive_stock(full_city, item_id,
		MarketTable.stock_cap(full_city, item_id))

	var world := LogisticsView3D.new()
	world.sync(session.market, session.logistics, item_id)

	var empty_bar: MeshInstance3D = world.city_bar_of(empty_city)
	var full_bar: MeshInstance3D = world.city_bar_of(full_city)
	var empty_height: float = (empty_bar.mesh as CylinderMesh).height
	var full_height: float = (full_bar.mesh as CylinderMesh).height

	_check(full_height > empty_height,
		"在庫の多い都市の棒が高い",
		"満 %.2f / 空 %.2f" % [full_height, empty_height])
	_check(empty_height > 0.0,
		"在庫0でも棒は残る（都市の位置が図から消えない）",
		"%.2f" % empty_height)

	# 底面が地面に接していること。中心を地面に合わせると棒が半分埋まり、
	# 高さの比較が見た目では効かなくなる。
	var base: float = full_bar.position.y - full_height / 2.0
	_check(is_zero_approx(base), "棒の底面が地面（Y=0）にある", "%.4f" % base)

	world.free()


## 開いたときに本編の窓の隣へ置かれること。
##
## **ここは実際に落ちた所。** `get_window()` は Window 自身を返すため、
## 自分の位置に POSITION_OFFSET を足す形になっていた。さらに
## OPEN_ON_START=true だと show_window() を通らないぶん配置そのものが走らず、
## 窓は (0,0)（モニタの左上）に取り残されていた。本編が原点の近くにあると
## 真上に重なり、別ウィンドウにした意味が消える。
##
## 検査には親の窓が要る（本編の位置を引く先）。root へ入れると native の窓を
## 開きにいくので、ホストの Window をツリー外で組んでそこへ吊る。
func _test_window_sits_beside_main() -> void:
	print("--- ウィンドウ: 本編の隣へ置かれる ---")

	var host := Window.new()
	host.position = Vector2i(400, 300)

	var window := LogisticsDebugWindow.new()
	host.add_child(window)
	window.show_window()

	var expected: Vector2i = host.position + LogisticsDebugWindow.POSITION_OFFSET
	_check(window.position == expected,
		"本編の窓の右下へずらして置かれる",
		"実際 %s / 期待 %s" % [window.position, expected])
	# 自分を見ていると (0,0) のまま、あるいは自分＋offset になる。
	_check(window.position != Vector2i.ZERO,
		"画面の左上に取り残されない", str(window.position))

	# 一度置いたら動かさない。見ている途中で窓が飛ぶと、どこを見ていたか
	# 分からなくなる。
	var moved := Vector2i(50, 60)
	window.position = moved
	window.hide_window()
	window.show_window()
	_check(window.position == moved,
		"二度目に開いても位置を動かさない（見ていた所を保つ）",
		str(window.position))

	host.free()
