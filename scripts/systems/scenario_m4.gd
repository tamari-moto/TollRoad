extends "res://scripts/systems/scenario_base.gd"
## M4 の検証シナリオ。60日通しの進行・純資産・ランク判定を検査し、
## 単純な戦略で複数回プレイしてバランスを測る。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m4.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")



func _init() -> void:
	_test_game_end()
	_test_stranded()
	_test_rank_boundaries()
	_test_full_playthrough()
	_run_balance_batch()
	_finish()


func _test_game_end() -> void:
	print("--- 60日で終了する ---")
	var s: GameSession = GameSession.new(3001)
	_check(not s.is_over(), "1日目は終了していない", "終了扱い")
	_check(s.days_left() == 60, "残り60日", str(s.days_left()))

	for i: int in 59:
		s.rest()
	_check(s.day == 60, "59回休むと60日目", str(s.day))
	_check(not s.is_over(), "60日目はまだ終了していない", "終了扱い")
	_check(s.days_left() == 1, "残り1日", str(s.days_left()))

	s.rest()
	_check(s.is_over(), "60日を終えると終了する", "まだ続く")
	_check(s.days_left() == 0, "残り0日", str(s.days_left()))

	# 終了後は行動できない。
	_check(not s.rest(), "終了後は休息できない", "できてしまった")
	_check(not s.buy("ore", 1), "終了後は購入できない", "できてしまった")
	_check(not s.move_to("stonegate"), "終了後は移動できない", "できてしまった")
	var day_after: int = s.day
	s.rest()
	_check(s.day == day_after, "終了後は日が進まない", str(s.day))


func _test_stranded() -> void:
	print("--- 破産しても休息で継続できる（Q7） ---")
	var s: GameSession = GameSession.new(3002)
	s.silver = 100
	_check(s.is_stranded(), "移動費が払えないと立ち往生", "移動できる")
	_check(not s.move_to("stonegate"), "移動は拒否される", "移動できてしまった")
	_check(s.rest(), "それでも休息はできる", "休息もできない")
	_check(s.day == 2, "休息で日が進む", str(s.day))

	# 島があれば倉庫が貯まり、引き取って売れば復帰できる。
	var recover: GameSession = GameSession.new(3003)
	recover.silver = 1000000
	recover.upgrade_island()
	recover.silver = 50
	_check(recover.is_stranded(), "資金を失って立ち往生", "移動できる")
	for i: int in 10:
		recover.rest()
	_check(recover.warehouse_total() > 0, "休息中も倉庫は貯まる", str(recover.warehouse_total()))
	recover.withdraw_from_warehouse()
	_check(recover.cargo_weight() > 0, "引き取って積荷にできる", str(recover.cargo_weight()))
	var before: int = recover.silver
	for item_id: String in recover.cargo.keys():
		recover.sell(item_id, recover.cargo_count(item_id))
	_check(recover.silver > before, "売却して資金を回復できる", str(recover.silver))
	_check(not recover.is_stranded(), "復帰して再び移動できる", "まだ立ち往生")


func _test_rank_boundaries() -> void:
	print("--- ランク判定の境界 ---")
	_check(GameData.rank_for(1199999) == "MASTER TRADER", "119万9999はMASTER", GameData.rank_for(1199999))
	_check(GameData.rank_for(1200000) == "LEGENDARY MERCHANT", "120万ちょうどでLEGENDARY", GameData.rank_for(1200000))
	_check(GameData.rank_for(499999) == "JOURNEYMAN", "49万9999はJOURNEYMAN", GameData.rank_for(499999))
	_check(GameData.rank_for(500000) == "MASTER TRADER", "50万ちょうどでMASTER", GameData.rank_for(500000))
	_check(GameData.rank_for(149999) == "SURVIVOR", "14万9999はSURVIVOR", GameData.rank_for(149999))
	_check(GameData.rank_for(30000) == "SURVIVOR", "3万ちょうどでSURVIVOR", GameData.rank_for(30000))
	_check(GameData.rank_for(29999) == "BANKRUPT", "2万9999はBANKRUPT", GameData.rank_for(29999))
	_check(GameData.rank_for(0) == "BANKRUPT", "0はBANKRUPT", GameData.rank_for(0))

	# 初期状態は30000なのでSURVIVOR。
	var s: GameSession = GameSession.new(3004)
	_check(s.rank() == "SURVIVOR", "初期状態はSURVIVOR", s.rank())


func _test_full_playthrough() -> void:
	print("--- 60日通しプレイ（単純戦略） ---")
	var s: GameSession = GameSession.new(3005)
	var result: Dictionary = _play(s)

	_check(s.is_over(), "60日を完走する", "途中で止まった")
	_check(s.day == 61, "61日目で終了", str(s.day))
	_check(s.silver >= 0, "シルバーが負にならない", str(s.silver))
	_check(s.cargo_weight() <= s.capacity(), "積載超過しない",
		"%d / %d" % [s.cargo_weight(), s.capacity()])
	_check(s.net_worth() > 0, "純資産が算出される", str(s.net_worth()))
	_check(s.log_entries.size() > 0, "航海日誌に記録が残る", str(s.log_entries.size()))
	print("     結果: 純資産 %d（%s）、取引 %d 回" % [s.net_worth(), s.rank(), result["actions"]])


func _run_balance_batch() -> void:
	print("--- バランス検証（30回のプレイ） ---")
	var runs: int = 30
	var results: Array[int] = []
	var ranks: Dictionary = {}

	for i: int in runs:
		var s: GameSession = GameSession.new(90000 + i * 137)
		_play(s)
		results.append(s.net_worth())
		var r: String = s.rank()
		ranks[r] = ranks.get(r, 0) + 1

	results.sort()
	var total: int = 0
	for v: int in results:
		total += v
	var average: int = total / runs
	var median: int = results[runs / 2]

	print("     最低 %d / 中央 %d / 平均 %d / 最高 %d" % [
		results[0], median, average, results[runs - 1]])
	var rank_detail: String = ""
	for rank_name: String in ranks:
		rank_detail += "%s=%d " % [rank_name, ranks[rank_name]]
	print("     ランク分布: %s" % rank_detail)

	# バランスそのものの良し悪しは判定しない。破綻していないことだけ確認する。
	_check(results[0] >= 0, "どのプレイでも純資産が負にならない", str(results[0]))
	_check(average > GameData.INITIAL_SILVER,
		"平均が初期資金を上回る（単純戦略でも増える）", str(average))


## 意図された成長ルートで60日を通しプレイする。
## ボーナス都市で特産資源を装備に変え、レイヴンスパイアへ運んで売る。余力があれば
## 島を拡張する。最適解ではなく、バランスが破綻していないことを測る基準線。
func _play(s: GameSession) -> Dictionary:
	var actions: int = 0
	while not s.is_over():
		# 島が拡張できるなら優先する（パッシブ収入の複利を働かせる）。
		if not s.is_island_max_level() and s.silver >= s.island_upgrade_cost() * 2:
			s.upgrade_island()
			continue

		# 積荷があれば、ここで売れるものを売る。
		if not s.cargo.is_empty():
			for item_id: String in s.cargo.keys():
				var price: int = s.prices.get_price(s.current_city, item_id)
				var base: int = GameData.ITEMS[item_id]["base_price"]
				var is_equipment: bool = GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.EQUIPMENT
				# 装備はレイヴンスパイアが最も高いので、他所では基準の1割増を待つ。
				var threshold: float = 1.1 if is_equipment and s.current_city != GameData.CAERLEON else 1.0
				if float(price) > float(base) * threshold:
					s.sell(item_id, s.cargo_count(item_id))
					actions += 1

		# 倉庫が積載量ぶん貯まっていれば引き取る。
		if s.warehouse_total() >= s.capacity() and s.free_capacity() >= s.capacity() / 2:
			s.withdraw_from_warehouse()
			actions += 1
			continue

		# ボーナス都市なら特産資源を装備に変える（原価の2倍以上で売れる）。
		# 資源2個(重量2)が装備1個(重量3)になるため、積載に空きを残しておく必要がある。
		var bonus: String = GameData.CITIES[s.current_city]["bonus"]
		if bonus != "" and GameData.ITEMS[bonus]["material"] == GameData.CITIES[s.current_city]["specialty"]:
			var material: String = GameData.ITEMS[bonus]["material"]
			var per_unit: int = s.material_cost_per_unit(bonus)
			# 完成品が収まるよう、積載の 2/3 までしか材料を積まない。
			var room: int = (s.capacity() * 2 / 3) / GameData.ITEMS[material]["weight"]
			var want: int = mini(room - s.cargo_count(material), s.max_buyable(material))
			if want > 0:
				s.buy(material, want)
			if s.max_craftable(bonus) > 0:
				s.craft(bonus, s.max_craftable(bonus))
				continue

		# 空きがあれば、最も割安な資源を買う。
		if s.free_capacity() > 0:
			var best_id: String = ""
			var best_ratio: float = 1.0
			for item_id: String in GameData.resource_ids():
				var price: int = s.prices.get_price(s.current_city, item_id)
				var base: int = GameData.ITEMS[item_id]["base_price"]
				var ratio: float = float(price) / float(base)
				if ratio < best_ratio and s.max_buyable(item_id) > 0:
					best_ratio = ratio
					best_id = item_id
			if best_id != "":
				s.buy(best_id, s.max_buyable(best_id))
				actions += 1

		# 装備を積んでいればレイヴンスパイアへ渡る（装備は 1.24 倍で売れる）。
		# 22% で全損するが、期待値では見合う。
		var has_equipment: bool = false
		for item_id: String in s.cargo:
			if GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.EQUIPMENT:
				has_equipment = true
		if has_equipment and s.current_city != GameData.CAERLEON and s.can_move_to(GameData.CAERLEON):
			s.move_to(GameData.CAERLEON)
			actions += 1
			continue

		# 隣町へ移動する。移動できなければ休息（Q7 の継続）。
		var moved: bool = false
		for city_id: String in GameData.royal_city_ids():
			if GameData.is_adjacent(s.current_city, city_id) and s.can_move_to(city_id):
				s.move_to(city_id)
				actions += 1
				moved = true
				break
		if not moved:
			s.rest()

	return {"actions": actions}
