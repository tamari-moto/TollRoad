extends "res://scripts/systems/scenario_base.gd"
## M22 の検証シナリオ。ギルド仲間（同行者）を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m22.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")

## 検査専用のパス。SaveManager.SAVE_PATH は絶対に使わないこと
## （シナリオを流すたびにプレイヤーのセーブが消える）。
const TEST_PATH: String = "user://scenario_m22_tmp.json"


func _init() -> void:
	_test_set_companion()
	_test_fina_buy_discount()
	_test_gadolf_craft_fee()
	_test_serafina_memo_freshness()
	_test_rocco_capacity_and_raid()
	_test_kale_explore_bonus()
	_test_mira_sell_tax()
	_test_baron_move_cost()
	_test_olga_worker_yield()
	_test_tobias_craft_material_discount()
	_test_companion_stat_without_matching_trait()
	_test_companion_stat_zero_without_companion()
	_test_only_one_active()
	_test_save_round_trip()
	_test_unknown_companion_clamped()
	_finish()


func _test_set_companion() -> void:
	print("--- 同行者の切り替え ---")
	var s: GameSession = GameSession.new(20001)
	_check(s.active_companion == GameData.COMPANION_NONE, "初期は誰も同行しない",
		s.active_companion)

	_check(s.set_companion("fina"), "フィナを同行できる", "できない")
	_check(s.active_companion == "fina", "同行者がフィナになる", s.active_companion)

	_check(not s.set_companion("fina"), "同じ同行者への切り替えは失敗（無変化）", "通ってしまった")
	_check(not s.set_companion("unknown"), "存在しないIDは拒否", "通ってしまった")
	_check(s.active_companion == "fina", "拒否されても同行者は変わらない", s.active_companion)

	_check(s.set_companion(GameData.COMPANION_NONE), "解除できる", "できない")
	_check(s.active_companion == GameData.COMPANION_NONE, "解除すると誰も同行しない",
		s.active_companion)

	# 無料・即時であること（日数を消費しない）。
	var day_before: int = s.day
	s.set_companion("rocco")
	_check(s.day == day_before, "同行者の切り替えは日数を消費しない", str(s.day))


func _test_fina_buy_discount() -> void:
	print("--- フィナ: 買値ダウン ---")
	var s: GameSession = GameSession.new(20002)
	var base_price: int = s.prices.get_price(s.current_city, "ore")
	_check(s.buy_price("ore") == base_price, "同行者無しでは割引無し", str(s.buy_price("ore")))

	s.set_companion("fina")
	# フィナの特性(-8%)と基本ステータスの交渉力(5レベル→-5%)が加算される。
	var expected_discount: float = GameData.COMPANION_BUY_DISCOUNT + (
		GameData.COMPANION_STATS["fina"]["negotiation"] * GameData.COMPANION_STAT_NEGOTIATION_PER_LEVEL)
	var expected: int = int(round(base_price * (1.0 - expected_discount)))
	_check(s.buy_price("ore") == expected, "フィナ同行中は買値が特性+基本ステータスぶん下がる",
		"期待 %d, 実際 %d" % [expected, s.buy_price("ore")])
	_check(expected < base_price, "割引後は元の価格より安い", str(expected))

	var silver_before: int = s.silver
	_check(s.buy("ore", 1), "割引価格で購入できる", "できない")
	_check(s.silver == silver_before - expected, "割引価格ぶんだけシルバーが減る",
		"期待 %d, 実際 %d" % [silver_before - expected, s.silver])


func _test_gadolf_craft_fee() -> void:
	print("--- ガドルフ: 製作手数料ダウン ---")
	var s: GameSession = GameSession.new(20003)
	_check(s.craft_fee_per_unit() == GameData.CRAFT_FEE, "同行者無しでは通常の手数料",
		str(s.craft_fee_per_unit()))

	s.set_companion("gadolf")
	_check(s.craft_fee_per_unit() == GameData.COMPANION_CRAFT_FEE, "ガドルフ同行中は手数料が下がる",
		str(s.craft_fee_per_unit()))
	_check(GameData.COMPANION_CRAFT_FEE < GameData.CRAFT_FEE, "下がった手数料は通常より安い",
		str(GameData.COMPANION_CRAFT_FEE))

	s.buy("ore", 3)
	var silver_before: int = s.silver
	_check(s.craft("sword", 1), "製作できる", "できない")
	# 手数料は個数だけで決まる（生産ボーナスによる材料還元とは無関係）。
	var expected_fee: int = GameData.COMPANION_CRAFT_FEE
	_check(s.silver == silver_before - expected_fee, "下がった手数料が引かれる",
		"期待 %d, 実際 %d" % [silver_before - expected_fee, s.silver])


func _test_serafina_memo_freshness() -> void:
	print("--- セラフィーナ: 相場メモが古くならない ---")
	var s: GameSession = GameSession.new(20004)
	var home: String = s.current_city
	_check(s.has_memo(home), "初期都市は記録済み", "未記録")

	s.move_to(_adjacent_royal_city(home))
	for i: int in GameData.MEMO_STALE_DAYS:
		s.rest()
	_check(s.memo_age(home) >= GameData.MEMO_STALE_DAYS, "検査の前提: 記録が古くなっている",
		str(s.memo_age(home)))
	_check(s.is_memo_stale(home), "同行者無しでは古い記録として扱われる", "古くない")

	s.set_companion("serafina")
	_check(not s.is_memo_stale(home), "セラフィーナ同行中は古くならない", "古いまま")

	s.set_companion(GameData.COMPANION_NONE)
	_check(s.is_memo_stale(home), "同行を解けば再び古い記録として扱われる", "古くない")


func _test_rocco_capacity_and_raid() -> void:
	print("--- ロッコ: 積載量アップと襲撃率ダウン ---")
	var s: GameSession = GameSession.new(20005)
	var base_capacity: int = s.capacity()
	_check(base_capacity == GameData.MOUNTS[s.mount]["capacity"], "同行者無しは騎乗どおりの積載量",
		str(base_capacity))

	s.set_companion("rocco")
	# ロッコの特性(+15)と基本ステータスの積載量補正(5レベル→+5)が加算される。
	var expected_capacity: int = base_capacity + GameData.COMPANION_CAPACITY_BONUS + (
		GameData.COMPANION_STATS["rocco"]["capacity"] * GameData.COMPANION_STAT_CAPACITY_PER_LEVEL)
	_check(s.capacity() == expected_capacity,
		"ロッコ同行中は積載量が特性+基本ステータスぶん増える",
		"期待 %d, 実際 %d" % [expected_capacity, s.capacity()])

	# 黒ゾーンの襲撃率。ゲート都市からなら黒ゾーン1区間で中心都市へ入れる
	# （ゲート以外から出すと王道を歩く区間が混ざり、襲撃率が黒ゾーン単体の
	# 値にならない）。IDは直書きせず BLACK_ZONE_GATES から取る。
	var to_caerleon: GameSession = GameSession.new(20006)
	to_caerleon.move_to(GameData.BLACK_ZONE_GATES[0])
	var route_without: Dictionary = to_caerleon.route_to(GameData.CAERLEON)
	_check(is_equal_approx(route_without["raid_chance"], GameData.RAID_CHANCE),
		"同行者無しは通常の襲撃率", str(route_without["raid_chance"]))

	to_caerleon.set_companion("rocco")
	var route_with: Dictionary = to_caerleon.route_to(GameData.CAERLEON)
	# ロッコの特性(-5pt)と基本ステータスの警戒心(3レベル→-3pt)が加算される。
	var expected_raid: float = GameData.RAID_CHANCE - GameData.COMPANION_RAID_REDUCTION - (
		GameData.COMPANION_STATS["rocco"]["vigilance"] * GameData.COMPANION_STAT_VIGILANCE_PER_LEVEL)
	_check(is_equal_approx(route_with["raid_chance"], expected_raid),
		"ロッコ同行中は襲撃率が特性+基本ステータスぶん下がる",
		"期待 %.4f, 実際 %.4f" % [expected_raid, route_with["raid_chance"]])
	_check(route_with["cost"] == route_without["cost"], "費用・日数は変わらない",
		str(route_with["cost"]))


func _test_kale_explore_bonus() -> void:
	print("--- ケイル: 探索成功率アップ ---")
	var s: GameSession = GameSession.new(20010)
	var base_chance: float = s.explore_chance()

	s.set_companion("kale")
	# ケイルの特性(+5pt)と基本ステータスの探索技能(5レベル→+5pt)が加算される。
	var expected: float = clampf(
		base_chance + GameData.COMPANION_EXPLORE_BONUS + (
			GameData.COMPANION_STATS["kale"]["exploration"] * GameData.COMPANION_STAT_EXPLORATION_PER_LEVEL),
		0.0, GameData.EXPLORE_MAX_CHANCE)
	_check(is_equal_approx(s.explore_chance(), expected),
		"ケイル同行中は探索成功率が特性+基本ステータスぶん上がる",
		"期待 %.4f, 実際 %.4f" % [expected, s.explore_chance()])
	_check(s.explore_chance() > base_chance, "上昇後は元の成功率より高い", str(s.explore_chance()))


func _test_mira_sell_tax() -> void:
	print("--- ミラ: 売却税率ダウン ---")
	var s: GameSession = GameSession.new(20011)
	s.buy("ore", 1)
	var price: int = s.prices.get_price(s.current_city, "ore")

	s.set_companion("mira")
	var silver_before: int = s.silver
	_check(s.sell("ore", 1), "売却できる", "できない")
	# ミラの特性(2%)から基本ステータスの目利き(5レベル→-5pt)がさらに引かれ、
	# 下限0でクランプされるため税がゼロになる。
	var expected_tax_rate: float = maxf(0.0, GameData.COMPANION_SELL_TAX_RATE - (
		GameData.COMPANION_STATS["mira"]["appraisal"] * GameData.COMPANION_STAT_APPRAISAL_PER_LEVEL))
	_check(is_equal_approx(expected_tax_rate, 0.0), "検査の前提: ミラは税がゼロになる",
		str(expected_tax_rate))
	var expected_tax: int = int(round(price * expected_tax_rate))
	var expected_net: int = price - expected_tax
	_check(s.silver == silver_before + expected_net,
		"ミラ同行中は特性+基本ステータスで税がゼロになり手取りが総額と一致する",
		"期待 %d, 実際 %d" % [silver_before + expected_net, s.silver])


func _test_baron_move_cost() -> void:
	print("--- バロン: 王道移動費ダウン（黒ゾーンは対象外） ---")
	var s: GameSession = GameSession.new(20012)
	var home: String = s.current_city
	var adjacent: String = _adjacent_royal_city(home)
	var route_without: Dictionary = s.route_to(adjacent)
	_check(route_without["cost"] == GameData.MOVE_ADJACENT_COST, "同行者無しは通常の移動費",
		str(route_without["cost"]))

	s.set_companion("baron")
	var route_with: Dictionary = s.route_to(adjacent)
	_check(route_with["cost"] == GameData.COMPANION_MOVE_COST, "バロン同行中は王道移動費が下がる",
		str(route_with["cost"]))

	# 黒ゾーンは対象外。
	var to_caerleon: GameSession = GameSession.new(20013)
	to_caerleon.set_companion("baron")
	to_caerleon.move_to(GameData.BLACK_ZONE_GATES[0])
	var black_route: Dictionary = to_caerleon.route_to(GameData.CAERLEON)
	_check(black_route["cost"] == GameData.MOVE_BLACK_ZONE_COST, "黒ゾーンの移動費はバロンでも変わらない",
		str(black_route["cost"]))


func _test_olga_worker_yield() -> void:
	print("--- オルガ: 労働者の産出アップ ---")
	var s: GameSession = GameSession.new(20014)
	s.upgrade_island()
	var before_total: int = s.warehouse_total()
	s.set_companion("olga")
	s.rest()
	var delivered: int = s.warehouse_total() - before_total
	var expected: int = s.worker_count() * GameData.COMPANION_WORKER_YIELD
	_check(delivered == expected, "オルガ同行中は1人あたり3個運ばれる",
		"期待 %d, 実際 %d" % [expected, delivered])


func _test_tobias_craft_material_discount() -> void:
	print("--- トビアス: 製作材料の節約 ---")
	var s: GameSession = GameSession.new(20015)
	var non_bonus_item: String = ""
	for item_id: String in GameData.ITEMS:
		if GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.EQUIPMENT \
				and item_id != GameData.CITIES[s.current_city]["bonus"]:
			non_bonus_item = item_id
			break
	_check(non_bonus_item != "", "検査の前提: 非ボーナスの装備がある", "見つからない")
	if non_bonus_item == "":
		return

	_check(s.material_cost_per_unit(non_bonus_item) == GameData.CRAFT_MATERIAL_COUNT,
		"同行者無しでは通常の材料消費数", str(s.material_cost_per_unit(non_bonus_item)))

	s.set_companion("tobias")
	var expected: int = maxi(1, GameData.CRAFT_MATERIAL_COUNT - GameData.COMPANION_CRAFT_MATERIAL_DISCOUNT)
	_check(s.material_cost_per_unit(non_bonus_item) == expected, "トビアス同行中は材料消費が1個減る",
		"期待 %d, 実際 %d" % [expected, s.material_cost_per_unit(non_bonus_item)])


## 基本ステータスは、その軸に1人1特性を持たない同行者（オルガ）でも
## 単体で効くことを確認する。
func _test_companion_stat_without_matching_trait() -> void:
	print("--- 基本ステータス: 特性が無い軸でも単体で効く（オルガ） ---")
	var s: GameSession = GameSession.new(20016)
	var base_capacity: int = s.capacity()
	var base_price: int = s.buy_price("ore")

	s.set_companion("olga")
	var expected_capacity: int = base_capacity + (
		GameData.COMPANION_STATS["olga"]["capacity"] * GameData.COMPANION_STAT_CAPACITY_PER_LEVEL)
	_check(s.capacity() == expected_capacity,
		"オルガ同行中は積載量が基本ステータスぶんだけ増える（特性は積載量に無関係）",
		"期待 %d, 実際 %d" % [expected_capacity, s.capacity()])

	var expected_price: int = int(round(base_price * (1.0 - (
		GameData.COMPANION_STATS["olga"]["negotiation"] * GameData.COMPANION_STAT_NEGOTIATION_PER_LEVEL))))
	_check(s.buy_price("ore") == expected_price,
		"オルガ同行中は買値が基本ステータスの交渉力ぶんだけ下がる（特性は買値に無関係）",
		"期待 %d, 実際 %d" % [expected_price, s.buy_price("ore")])


## 同行者が居なければ基本ステータスの効果も一切乗らないこと。
func _test_companion_stat_zero_without_companion() -> void:
	print("--- 基本ステータス: 同行者無しでは効果が乗らない ---")
	var s: GameSession = GameSession.new(20017)
	_check(s.capacity() == GameData.MOUNTS[s.mount]["capacity"],
		"同行者無しの積載量は騎乗どおり", str(s.capacity()))

	var base_chance: float = GameData.EXPLORE_BASE_CHANCE
	if s.current_city == GameData.CAERLEON:
		base_chance -= GameData.EXPLORE_CAERLEON_PENALTY
	_check(is_equal_approx(s.explore_chance(), clampf(base_chance, 0.0, GameData.EXPLORE_MAX_CHANCE)),
		"同行者無しの探索成功率は装備ボーナスのみ（基本ステータスは乗らない）",
		str(s.explore_chance()))

	var to_caerleon: GameSession = GameSession.new(20018)
	to_caerleon.move_to(GameData.BLACK_ZONE_GATES[0])
	var route: Dictionary = to_caerleon.route_to(GameData.CAERLEON)
	_check(is_equal_approx(route["raid_chance"], GameData.RAID_CHANCE),
		"同行者無しの黒ゾーン襲撃率は通常値のまま", str(route["raid_chance"]))


func _test_only_one_active() -> void:
	print("--- 同時に有効なのは1人だけ（効果は重複しない） ---")
	var s: GameSession = GameSession.new(20007)
	var base_price: int = s.prices.get_price(s.current_city, "ore")

	s.set_companion("fina")
	_check(s.buy_price("ore") < base_price, "フィナの割引が効いている", str(s.buy_price("ore")))

	# ロッコへ切り替えると、フィナの特性(-8%)は消える。ロッコにも基本ステータスの
	# 交渉力(1レベル→-1%)が乗るため、定価そのものには戻らない点に注意。
	s.set_companion("rocco")
	var expected_price: int = int(round(base_price * (1.0 - (
		GameData.COMPANION_STATS["rocco"]["negotiation"] * GameData.COMPANION_STAT_NEGOTIATION_PER_LEVEL))))
	_check(s.buy_price("ore") == expected_price,
		"切り替えるとフィナの特性は消え、ロッコの基本ステータスぶんだけ残る",
		"期待 %d, 実際 %d" % [expected_price, s.buy_price("ore")])
	var expected_capacity: int = GameData.MOUNTS[s.mount]["capacity"] + GameData.COMPANION_CAPACITY_BONUS + (
		GameData.COMPANION_STATS["rocco"]["capacity"] * GameData.COMPANION_STAT_CAPACITY_PER_LEVEL)
	_check(s.capacity() == expected_capacity,
		"ロッコの積載ボーナス（特性+基本ステータス）だけが効いている", str(s.capacity()))


func _test_save_round_trip() -> void:
	print("--- セーブ/ロードで同行者が戻る ---")
	var original: GameSession = GameSession.new(20008)
	original.set_companion("gadolf")

	var restored: GameSession = GameSession.new(0)
	restored.from_dict(original.to_dict())
	_check(restored.active_companion == "gadolf", "辞書の往復で同行者が戻る",
		restored.active_companion)

	# 実ファイル経由でも戻る。
	SaveManager.delete_save(TEST_PATH)
	_check(SaveManager.save_game(original, TEST_PATH), "保存できる", "失敗した")
	var loaded: GameSession = SaveManager.load_game(TEST_PATH)
	_check(loaded != null, "読み込める", SaveManager.last_error())
	if loaded != null:
		_check(loaded.active_companion == "gadolf", "ファイル経由でも同行者が戻る",
			loaded.active_companion)
	SaveManager.delete_save(TEST_PATH)

	# 同行者が無いセーブ（既存のセーブ形式）も問題なく読める。
	var without_companion: Dictionary = original.to_dict()
	without_companion.erase("active_companion")
	var restored_none: GameSession = GameSession.new(0)
	restored_none.from_dict(without_companion)
	_check(restored_none.active_companion == GameData.COMPANION_NONE,
		"active_companion が無い旧セーブは同行者無しになる", restored_none.active_companion)


func _test_unknown_companion_clamped() -> void:
	print("--- 未知の同行者IDは丸められる ---")
	SaveManager.delete_save(TEST_PATH)
	var data: Dictionary = GameSession.new(20009).to_dict()
	data["version"] = SaveManager.SAVE_VERSION
	data["active_companion"] = "phantom_thief"

	var file: FileAccess = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	if file == null:
		_check(false, "検査用のファイルを書ける", "書けない")
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()

	var loaded: GameSession = SaveManager.load_game(TEST_PATH)
	_check(loaded != null, "壊れたIDでも読み込める", SaveManager.last_error())
	if loaded != null:
		_check(loaded.active_companion == GameData.COMPANION_NONE,
			"未知の同行者IDは同行者無しに丸められる", loaded.active_companion)
	SaveManager.delete_save(TEST_PATH)
