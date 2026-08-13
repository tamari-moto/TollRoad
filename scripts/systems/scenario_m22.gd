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
	var expected: int = int(round(base_price * (1.0 - GameData.COMPANION_BUY_DISCOUNT)))
	_check(s.buy_price("ore") == expected, "フィナ同行中は買値が8%下がる",
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
	_check(s.capacity() == base_capacity + GameData.COMPANION_CAPACITY_BONUS,
		"ロッコ同行中は積載量が+15される",
		"期待 %d, 実際 %d" % [base_capacity + GameData.COMPANION_CAPACITY_BONUS, s.capacity()])

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
	var expected_raid: float = GameData.RAID_CHANCE - GameData.COMPANION_RAID_REDUCTION
	_check(is_equal_approx(route_with["raid_chance"], expected_raid),
		"ロッコ同行中は襲撃率が下がる",
		"期待 %.4f, 実際 %.4f" % [expected_raid, route_with["raid_chance"]])
	_check(route_with["cost"] == route_without["cost"], "費用・日数は変わらない",
		str(route_with["cost"]))


func _test_only_one_active() -> void:
	print("--- 同時に有効なのは1人だけ（効果は重複しない） ---")
	var s: GameSession = GameSession.new(20007)
	var base_price: int = s.prices.get_price(s.current_city, "ore")

	s.set_companion("fina")
	_check(s.buy_price("ore") < base_price, "フィナの割引が効いている", str(s.buy_price("ore")))

	# ロッコへ切り替えると、フィナの効果は消える。
	s.set_companion("rocco")
	_check(s.buy_price("ore") == base_price, "切り替えるとフィナの割引は消える",
		str(s.buy_price("ore")))
	_check(s.capacity() == GameData.MOUNTS[s.mount]["capacity"] + GameData.COMPANION_CAPACITY_BONUS,
		"ロッコの積載ボーナスだけが効いている", str(s.capacity()))


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
