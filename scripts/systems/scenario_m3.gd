extends "res://scripts/systems/scenario_base.gd"
## M3 の検証シナリオ。島・労働者・倉庫・引き取り・騎乗を検査する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m3.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")



func _init() -> void:
	_test_island_upgrade()
	_test_worker_output()
	_test_worker_distribution()
	_test_withdraw()
	_test_mounts()
	_test_net_worth_includes_warehouse()
	_finish()


func _test_island_upgrade() -> void:
	print("--- 島の拡張 ---")
	var s: GameSession = GameSession.new(2001)
	_check(s.island_level == 0, "初期は島レベル0", str(s.island_level))
	_check(s.worker_count() == 0, "初期は労働者0人", str(s.worker_count()))
	_check(s.island_upgrade_cost() == 26000, "L1の費用は26000", str(s.island_upgrade_cost()))

	var before: int = s.silver
	_check(s.upgrade_island(), "L1へ拡張できる", "できない")
	_check(s.island_level == 1, "レベルが1になる", str(s.island_level))
	_check(s.worker_count() == 3, "労働者が3人になる", str(s.worker_count()))
	_check(s.silver == before - 26000, "費用が引かれる", str(s.silver))
	_check(s.island_upgrade_cost() == 70000, "次はL2で70000", str(s.island_upgrade_cost()))

	# 資金不足では拡張できない（L2は70000、残りは30000-26000=4000）。
	_check(not s.upgrade_island(), "資金不足では拡張できない", "通ってしまった")
	_check(s.island_level == 1, "失敗してもレベルは変わらない", str(s.island_level))

	# レベルは飛ばせず、順に上がる。
	var rich: GameSession = GameSession.new(2002)
	rich.silver = 1000000
	rich.upgrade_island()
	_check(rich.island_level == 1, "1回の拡張で1段階のみ", str(rich.island_level))
	rich.upgrade_island()
	rich.upgrade_island()
	_check(rich.island_level == 3, "3回でL3", str(rich.island_level))
	_check(rich.worker_count() == 20, "L3は労働者20人", str(rich.worker_count()))
	_check(rich.is_island_max_level(), "L3が最大", "まだ上がる")
	_check(not rich.upgrade_island(), "最大レベルからは拡張できない", "通ってしまった")
	_check(rich.island_upgrade_cost() == -1, "最大レベルの費用は-1", str(rich.island_upgrade_cost()))


func _test_worker_output() -> void:
	print("--- 労働者の生産 ---")
	# L0 では何も生産しない。
	var idle: GameSession = GameSession.new(2003)
	idle.rest()
	_check(idle.warehouse_total() == 0, "労働者0人なら倉庫は増えない", str(idle.warehouse_total()))

	# L1（3人）で N 日休むと 2×3×N 個貯まる。
	var s: GameSession = GameSession.new(2004)
	s.silver = 1000000
	s.upgrade_island()
	_check(s.warehouse_total() == 0, "拡張直後は倉庫が空", str(s.warehouse_total()))

	var days: int = 5
	for i: int in days:
		s.rest()
	var expected: int = 2 * 3 * days
	_check(s.warehouse_total() == expected, "3人×2個×5日=30個",
		"期待 %d, 実際 %d" % [expected, s.warehouse_total()])

	# 移動や製作でも日が進むので労働者は働く。
	var before: int = s.warehouse_total()
	s.move_to(_adjacent_royal_city(s.current_city))
	_check(s.warehouse_total() == before + 6, "移動中も労働者は働く",
		"期待 %d, 実際 %d" % [before + 6, s.warehouse_total()])

	# 非隣接移動（2日）なら2日ぶん。
	var before_far: int = s.warehouse_total()
	s.move_to(_far_royal_city(s.current_city))
	_check(s.warehouse_total() == before_far + 12, "2日移動なら2日ぶん働く",
		"期待 %d, 実際 %d" % [before_far + 12, s.warehouse_total()])

	# L3（20人）は1日40個。
	var big: GameSession = GameSession.new(2005)
	big.silver = 1000000
	big.upgrade_island()
	big.upgrade_island()
	big.upgrade_island()
	var big_before: int = big.warehouse_total()
	big.rest()
	_check(big.warehouse_total() == big_before + 40, "20人なら1日40個",
		"期待 %d, 実際 %d" % [big_before + 40, big.warehouse_total()])


func _test_worker_distribution() -> void:
	print("--- 労働者の資源分布（5資源から均等） ---")
	var s: GameSession = GameSession.new(2006)
	s.silver = 1000000
	s.upgrade_island()
	s.upgrade_island()
	s.upgrade_island()
	# 20人×2個×50日 = 2000個
	for i: int in 50:
		s.rest()

	var total: int = s.warehouse_total()
	_check(total == 2000, "2000個貯まる", str(total))

	# 資源のみが入り、装備は入らない。
	var only_resources: bool = true
	for item_id: String in s.warehouse:
		if GameData.ITEMS[item_id]["kind"] != GameData.ItemKind.RESOURCE:
			only_resources = false
	_check(only_resources, "倉庫に入るのは資源のみ", "装備が混ざった")

	# 5資源すべてが出現し、均等（各20%）に近い。
	_check(s.warehouse.size() == 5, "5資源すべてが出現する", str(s.warehouse.size()))
	var balanced: bool = true
	var detail: String = ""
	for item_id: String in s.warehouse:
		var share: float = float(s.warehouse[item_id]) / float(total)
		detail += "%s=%.1f%% " % [item_id, share * 100.0]
		if absf(share - 0.2) > 0.04:
			balanced = false
	_check(balanced, "各資源が約20%ずつ", detail)
	print("     内訳: %s" % detail)


func _test_withdraw() -> void:
	print("--- 島倉庫からの引き取り ---")
	var s: GameSession = GameSession.new(2007)
	s.silver = 1000000
	s.upgrade_island()
	s.upgrade_island()
	s.upgrade_island()
	# 20人×2個×3日 = 120個（積載40を大きく超える）
	for i: int in 3:
		s.rest()
	_check(s.warehouse_total() == 120, "倉庫に120個ある", str(s.warehouse_total()))
	_check(s.warehouse_total() > s.capacity(), "積載量を超えて貯まる（倉庫は無制限）", "超えていない")

	var day_before: int = s.day
	var stock_before: int = s.warehouse_total()
	_check(s.withdraw_from_warehouse(), "引き取りできる", "できない")
	_check(s.cargo_weight() == s.capacity(), "積載上限まで引き取る",
		"%d / %d" % [s.cargo_weight(), s.capacity()])
	_check(s.day == day_before + 1, "引き取りは1日消費", str(s.day - day_before))
	# 引き取った40個ぶん減り、その日の労働者ぶん40個増える。
	_check(s.warehouse_total() == stock_before - 40 + 40, "倉庫から引き取ったぶん減る",
		str(s.warehouse_total()))

	# 積荷が満杯なら引き取れない。
	var full: GameSession = GameSession.new(2008)
	full.silver = 1000000
	full.upgrade_island()
	full.rest()
	full.buy("ore", full.max_buyable("ore"))
	if full.free_capacity() == 0:
		_check(full.max_withdrawable() == 0, "積荷満杯なら引き取れる数は0", str(full.max_withdrawable()))

	# 倉庫が空なら失敗する。
	var empty: GameSession = GameSession.new(2009)
	_check(not empty.withdraw_from_warehouse(), "倉庫が空なら引き取りは失敗", "成功してしまった")
	_check(empty.day == 1, "失敗時は日が進まない", str(empty.day))


func _test_mounts() -> void:
	print("--- 騎乗 ---")
	var s: GameSession = GameSession.new(2010)
	_check(s.mount == "donkey", "初期はロバ", s.mount)
	_check(s.capacity() == 40, "ロバの積載は40", str(s.capacity()))

	var before: int = s.silver
	_check(s.buy_mount("ox"), "雄牛を買える", "買えない")
	_check(s.mount == "ox", "騎乗が雄牛になる", s.mount)
	_check(s.capacity() == 85, "積載が85になる", str(s.capacity()))
	_check(s.silver == before - 18000, "費用18000が引かれる", str(s.silver))

	_check(not s.buy_mount("ox"), "同じ騎乗は買い直せない", "買えてしまった")
	_check(not s.buy_mount("unknown"), "存在しない騎乗は拒否", "通ってしまった")
	# 残り12000ではマンモス（60000）は買えない。
	_check(not s.buy_mount("mammoth"), "資金不足では買えない", "買えてしまった")

	var rich: GameSession = GameSession.new(2011)
	rich.silver = 1000000
	rich.buy_mount("mammoth")
	_check(rich.capacity() == 170, "マンモスの積載は170", str(rich.capacity()))
	# 積載が増えたぶん多く積める。
	var bought: int = rich.max_buyable("stone")
	rich.buy("stone", bought)
	_check(rich.cargo_weight() <= 170, "マンモスでも積載上限は守られる", str(rich.cargo_weight()))
	_check(rich.cargo_weight() > 40, "ロバより多く積める", str(rich.cargo_weight()))


func _test_net_worth_includes_warehouse() -> void:
	print("--- 純資産に島倉庫が算入される ---")
	var s: GameSession = GameSession.new(2012)
	s.silver = 100000
	s.upgrade_island()
	var cash: int = s.silver
	s.rest()

	# 倉庫の中身の基準価格を手計算する。
	var stock_value: int = 0
	for item_id: String in s.warehouse:
		stock_value += GameData.ITEMS[item_id]["base_price"] * s.warehouse[item_id]
	_check(stock_value > 0, "倉庫に資源がある", str(stock_value))

	var expected: int = s.silver + int(round(stock_value * 0.9))
	_check(s.net_worth() == expected, "純資産 = シルバー + 倉庫の基準価格×0.9",
		"期待 %d, 実際 %d" % [expected, s.net_worth()])
	_check(s.net_worth() > cash - 26000, "倉庫のぶん純資産が上乗せされる", str(s.net_worth()))
