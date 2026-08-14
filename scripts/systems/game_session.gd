extends RefCounted
## 1回のプレイ（60日）の状態と、プレイヤーが取れる行動をまとめたもの。
##
## autoload には依存しない。load() + .new() で直接生成して駆動できるため、
## --script のハーネスからそのまま検証できる（--script は autoload を
## 初期化しないため、この形を保つこと）。

const GameData = preload("res://scripts/systems/game_data.gd")
const PriceTable = preload("res://scripts/systems/price_table.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")

## 日誌の行の種別。UI が音と色を選ぶのに使う。
##
## セーブには入れない（log_entries は文字列の配列のまま）。復元した行は
## 種別を持たないため、UI 側は kind_for_message() で本文から引き直す。
## 生きている行はここで種別が付くので、本文を書き換えても音は変わらない。
enum LogKind {
	NONE,             ## 音を鳴らさない行（60日の終了、セーブの失敗など）
	TRADE,            ## 売買。音はボタン側で鳴らすため日誌では鳴らさない
	CRAFT,            ## 製作
	UPGRADE,          ## 島の拡張・騎乗の購入
	TRAVEL,           ## 移動
	RAID,             ## 襲撃。積荷の全損
	EXPLORE,          ## 探索（成功・失敗を問わない）
	DAY,              ## 休息・倉庫からの引き取り
	COMPANION_JOINED, ## 同行者の加入・切り替え
	COMPANION_LEFT,   ## 同行者との別れ
}

signal day_advanced(day: int)
signal silver_changed(amount: int)
signal cargo_changed()
## 在庫または需要が動いた。市場画面が売買のたびに引き直すために使う。
signal market_changed()
signal warehouse_changed()
signal island_upgraded(level: int)
signal mount_changed(mount_id: String)
signal companion_changed(companion_id: String)
## 日誌に1行増えた。kind は行の種別（LogKind）で、UI が音と色を選ぶのに使う。
##
## 本文の日本語から種別を当てさせない。文面を書き換えるたびに音と色が
## 黙って変わる（鳴らなくなっても検査は通ってしまう）ため、出す側が種別を
## 添える形にしてある。
signal logged(message: String, kind: int)

var day: int = 1
var silver: int = GameData.INITIAL_SILVER
var current_city: String = GameData.INITIAL_CITY
var mount: String = GameData.INITIAL_MOUNT
var island_level: int = 0

## 同行中のギルド仲間。GameData.COMPANION_NONE（空文字）なら誰もいない。
var active_companion: String = GameData.COMPANION_NONE

## item_id -> 個数
var cargo: Dictionary = {}

## 探索成功のブーストが残っている日数。0なら効果なし。
var _boost_days_left: int = 0

## 島倉庫。容量は無制限（Q3）。item_id -> 個数
var warehouse: Dictionary = {}

## city_id -> {"day": int, "prices": {item_id -> int}}
var memo: Dictionary = {}

## 航海日誌。M7 の画面はこれを表示するだけでよい。
var log_entries: Array[String] = []

var prices: PriceTable

## 都市ごとの在庫と需要。買える上限・売れる上限を決め、価格にも効く。
var market: MarketTable

var _rng: RandomNumberGenerator


## seed を渡すと再現可能になる。検証シナリオでは必ず固定すること。
func _init(rng_seed: int = 0) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = rng_seed
	# 価格が在庫を参照するので、市場を先に作る。
	market = MarketTable.new()
	prices = PriceTable.new(_rng, market)
	_record_memo()


# --- 状態の参照 ---

## 積載量（ロッコが同行していれば加算）。
func capacity() -> int:
	var base: int = GameData.MOUNTS[mount]["capacity"]
	if active_companion == "rocco":
		base += GameData.COMPANION_CAPACITY_BONUS
	return base


func cargo_weight() -> int:
	var total: int = 0
	for item_id: String in cargo:
		total += cargo[item_id] * GameData.ITEMS[item_id]["weight"]
	return total


func free_capacity() -> int:
	return capacity() - cargo_weight()


func cargo_count(item_id: String) -> int:
	return cargo.get(item_id, 0)


func is_over() -> bool:
	return day > GameData.TOTAL_DAYS


## 残り日数。
func days_left() -> int:
	return maxi(0, GameData.TOTAL_DAYS - day + 1)


## どの都市にも移動できない状態か（Q7: ゲームオーバーにはせず休息で継続できる）。
## 島倉庫が貯まれば引き取って売り、復帰できる余地を残す。
func is_stranded() -> bool:
	if is_over():
		return false
	for city_id: String in GameData.CITIES:
		if city_id != current_city and can_move_to(city_id):
			return false
	return true


## 純資産 = シルバー + (積荷 + 島倉庫) の基準価格 × 0.9
func net_worth() -> int:
	var stock_value: int = 0
	for item_id: String in cargo:
		stock_value += GameData.ITEMS[item_id]["base_price"] * cargo[item_id]
	for item_id: String in warehouse:
		stock_value += GameData.ITEMS[item_id]["base_price"] * warehouse[item_id]
	return silver + int(round(stock_value * GameData.NET_WORTH_STOCK_RATE))


func rank() -> String:
	return GameData.rank_for(net_worth())


# --- 取引（日数を消費しない） ---
#
# 市場は無限ではない。買えるのは現在地の在庫まで、売れるのは需要までで、
# どちらも毎日その都市の生産量・消費量ぶんだけ補充される（market_table.gd）。
# 在庫が薄いと買値が上がり、需要が尽きかけていると売値が下がる。

## 現在地でこの品目の在庫が何個あるか（＝買える上限の素）。
func stock_count(item_id: String) -> int:
	return market.stock_of(current_city, item_id)


## 現在地でこの品目の需要が何個あるか（＝売れる上限）。
func demand_count(item_id: String) -> int:
	return market.demand_of(current_city, item_id)


## この都市でのこの品目の購入単価（在庫の希少さを反映し、
## フィナが同行していれば割引後）。
func buy_price(item_id: String) -> int:
	var price: int = prices.buy_price(current_city, item_id)
	if active_companion == "fina":
		price = int(round(price * (1.0 - GameData.COMPANION_BUY_DISCOUNT)))
	return price


## この都市でのこの品目の売却単価（需要の飽きを反映した後）。
func sell_price(item_id: String) -> int:
	return prices.sell_price(current_city, item_id)


## 購入可能な最大数（シルバー・積載空き・在庫のうち最も小さいもの）。
func max_buyable(item_id: String) -> int:
	var price: int = buy_price(item_id)
	if price <= 0:
		return 0
	var by_silver: int = silver / price
	var by_space: int = free_capacity() / GameData.ITEMS[item_id]["weight"]
	return mini(mini(by_silver, by_space), stock_count(item_id))


## 売却可能な最大数（所持数と需要の小さい方）。
func max_sellable(item_id: String) -> int:
	return mini(cargo_count(item_id), demand_count(item_id))


func buy(item_id: String, count: int) -> bool:
	if is_over() or count <= 0 or count > max_buyable(item_id):
		return false
	var price: int = buy_price(item_id)
	var total: int = price * count
	silver -= total
	cargo[item_id] = cargo_count(item_id) + count
	market.consume_stock(current_city, item_id, count)
	_log("%s で %s を %d 個購入（単価 %d、計 %d、在庫の残り %d）" % [
		GameData.CITIES[current_city]["name"], GameData.ITEMS[item_id]["name"],
		count, price, total, stock_count(item_id)], LogKind.TRADE)
	silver_changed.emit(silver)
	cargo_changed.emit()
	market_changed.emit()
	return true


## 売却。税は売上総額にかかる（Q2）。手取り = 総額 - 税。
## 買い取ってもらえるのはその都市の需要の範囲まで。
func sell(item_id: String, count: int) -> bool:
	if is_over() or count <= 0 or count > max_sellable(item_id):
		return false
	var price: int = sell_price(item_id)
	var gross: int = price * count
	var tax: int = int(round(gross * GameData.SELL_TAX_RATE))
	var net: int = gross - tax
	silver += net
	_reduce_cargo(item_id, count)
	market.consume_demand(current_city, item_id, count)
	_log("%s で %s を %d 個売却（単価 %d、総額 %d、税 %d、手取り %d、需要の残り %d）" % [
		GameData.CITIES[current_city]["name"], GameData.ITEMS[item_id]["name"],
		count, price, gross, tax, net, demand_count(item_id)], LogKind.TRADE)
	silver_changed.emit(silver)
	cargo_changed.emit()
	market_changed.emit()
	return true


# --- 製作（1日消費） ---

## その装備をこの都市で作ると材料が還元されるか（生産ボーナス都市か）。
func has_craft_bonus(item_id: String) -> bool:
	return GameData.CITIES[current_city]["bonus"] == item_id


## 装備1個あたりの製作手数料（ガドルフが同行していれば下がる）。
func craft_fee_per_unit() -> int:
	if active_companion == "gadolf":
		return GameData.COMPANION_CRAFT_FEE
	return GameData.CRAFT_FEE


## 装備1個あたりの実質材料消費数。
## ボーナス都市では 3個消費して 3×0.3=0.9 → 四捨五入で1個還元、実質2個（Q: 1個ごとに計算）。
func material_cost_per_unit(item_id: String) -> int:
	if not has_craft_bonus(item_id):
		return GameData.CRAFT_MATERIAL_COUNT
	var refund: int = int(round(GameData.CRAFT_MATERIAL_COUNT * GameData.CRAFT_REFUND_RATE))
	return GameData.CRAFT_MATERIAL_COUNT - refund


## 製作可能な最大数（材料・手数料・積載空きの制約）。
func max_craftable(item_id: String) -> int:
	var item: Dictionary = GameData.ITEMS.get(item_id, {})
	if item.get("kind") != GameData.ItemKind.EQUIPMENT:
		return 0
	var material: String = item["material"]
	var per_unit: int = material_cost_per_unit(item_id)
	var by_material: int = cargo_count(material) / per_unit
	var by_silver: int = silver / craft_fee_per_unit()
	# 材料が減って装備が増えるぶんの正味の重量増加。
	var weight_delta: int = item["weight"] - GameData.ITEMS[material]["weight"] * per_unit
	var by_space: int = 99999
	if weight_delta > 0:
		by_space = free_capacity() / weight_delta
	return maxi(0, mini(by_material, mini(by_silver, by_space)))


## 資源から装備を製作する。個数をまとめて指定でき、消費日数は1日のみ。
func craft(item_id: String, count: int) -> bool:
	if is_over() or count <= 0 or count > max_craftable(item_id):
		return false
	var material: String = GameData.ITEMS[item_id]["material"]
	var per_unit: int = material_cost_per_unit(item_id)
	var material_used: int = per_unit * count
	var fee: int = craft_fee_per_unit() * count

	silver -= fee
	_reduce_cargo(material, material_used)
	cargo[item_id] = cargo_count(item_id) + count

	var bonus_note: String = ""
	if has_craft_bonus(item_id):
		var saved: int = (GameData.CRAFT_MATERIAL_COUNT - per_unit) * count
		bonus_note = "、生産ボーナスで %s を %d 個還元" % [GameData.ITEMS[material]["name"], saved]
	_log("%s で %s を %d 個製作（%s %d 個消費、手数料 %d%s）" % [
		GameData.CITIES[current_city]["name"], GameData.ITEMS[item_id]["name"], count,
		GameData.ITEMS[material]["name"], material_used, fee, bonus_note], LogKind.CRAFT)

	silver_changed.emit(silver)
	cargo_changed.emit()
	_advance_day()
	return true


# --- ギルド仲間 ---

## 同行者を切り替える（""を渡すと解除）。無料・即時で、日数は消費しない。
func set_companion(companion_id: String) -> bool:
	if companion_id != GameData.COMPANION_NONE and not GameData.COMPANIONS.has(companion_id):
		return false
	if companion_id == active_companion:
		return false
	active_companion = companion_id
	if companion_id == GameData.COMPANION_NONE:
		_log("同行者と別れ、一人旅に戻った。", LogKind.COMPANION_LEFT)
	else:
		_log("%s が同行することになった（%s）。" % [
			GameData.COMPANIONS[companion_id]["name"], GameData.COMPANIONS[companion_id]["desc"]],
			LogKind.COMPANION_JOINED)
	companion_changed.emit(active_companion)
	return true


# --- 移動 ---

## from_city から to_city への直接区間（1ホップ）のコスト。
## 直接つながっていない場合は空の Dictionary。
## 経路探索（_shortest_path）と move_to() の実行の両方がこれを辺の重みとして使う。
func _direct_leg(from_city: String, to_city: String) -> Dictionary:
	if from_city == to_city:
		return {}
	# 黒ゾーンで直結するのは GameData.BLACK_ZONE_GATES のみ。
	var is_black_zone: bool = (
		(to_city == GameData.CAERLEON and GameData.BLACK_ZONE_GATES.has(from_city))
		or (from_city == GameData.CAERLEON and GameData.BLACK_ZONE_GATES.has(to_city))
	)
	if is_black_zone:
		# ロッコが同行していれば襲撃率が下がる（下限は0）。
		var raid_chance: float = GameData.RAID_CHANCE
		if active_companion == "rocco":
			raid_chance = maxf(0.0, raid_chance - GameData.COMPANION_RAID_REDUCTION)
		return {
			"days": GameData.MOVE_BLACK_ZONE_DAYS,
			"cost": GameData.MOVE_BLACK_ZONE_COST,
			"raid_chance": raid_chance,
		}
	if GameData.is_adjacent(from_city, to_city):
		return {
			"days": GameData.MOVE_ADJACENT_DAYS,
			"cost": GameData.MOVE_ADJACENT_COST,
			"raid_chance": 0.0,
		}
	return {}


## city_id から1ホップで行ける全都市（王道の隣接都市 + ゲートなら中心都市）。
## 中心都市自身からは GameData.BLACK_ZONE_GATES のみが1ホップ
## （ゲートでない王国都市へは、まずいずれかのゲートまで王道で歩く必要がある）。
func _leg_neighbors(city_id: String) -> Array[String]:
	if city_id == GameData.CAERLEON:
		return GameData.BLACK_ZONE_GATES.duplicate()
	var neighbors: Array[String] = GameData.road_neighbors(city_id).duplicate()
	if GameData.BLACK_ZONE_GATES.has(city_id):
		neighbors.append(GameData.CAERLEON)
	return neighbors


## from_city から to_city への最小コスト経路（到着都市の列、from_city 自体は含まない）。
## 都市数が10と少ないので、優先度キュー無しの単純なダイクストラで十分。
## 全区間が1日固定のため、コスト最小化はホップ数最小化とほぼ一致する
## （区間の日数が変わる場合はこの前提が崩れるので、そのときはコストではなく
## 日数を主キーにする設計へ見直すこと）。
## グラフは常に連結なので、from_city != to_city なら空にはならない想定。
func _shortest_path(from_city: String, to_city: String) -> Array[String]:
	var nodes: Array[String] = []
	for id: String in GameData.CITIES:
		nodes.append(id)

	var dist: Dictionary = {}
	var prev: Dictionary = {}
	var visited: Dictionary = {}
	for node: String in nodes:
		dist[node] = INF
	dist[from_city] = 0.0

	while true:
		var current: String = ""
		var current_dist: float = INF
		for node: String in nodes:
			if not visited.has(node) and dist[node] < current_dist:
				current = node
				current_dist = dist[node]
		if current == "" or current == to_city:
			break
		visited[current] = true
		for neighbor: String in _leg_neighbors(current):
			var leg: Dictionary = _direct_leg(current, neighbor)
			var candidate: float = dist[current] + leg["cost"]
			if candidate < dist[neighbor]:
				dist[neighbor] = candidate
				prev[neighbor] = current

	if from_city != to_city and not prev.has(to_city):
		return []

	var path: Array[String] = []
	var step: String = to_city
	while step != from_city:
		path.push_front(step)
		step = prev[step]
	return path


## その都市へ移動するのに必要な合計日数・費用・襲撃率を返す（最短経路の合成）。
## raid_chance は「経路のどこか1区間以上で被弾する確率」
## （1 - 全区間とも無事である確率の積）。到達不能な場合は空の Dictionary。
func route_to(destination: String) -> Dictionary:
	if destination == current_city:
		return {}
	var path: Array[String] = _shortest_path(current_city, destination)
	if path.is_empty():
		return {}

	var total_days: int = 0
	var total_cost: int = 0
	var survive_chance: float = 1.0
	var from_city: String = current_city
	for stop: String in path:
		var leg: Dictionary = _direct_leg(from_city, stop)
		total_days += leg["days"]
		total_cost += leg["cost"]
		survive_chance *= 1.0 - leg["raid_chance"]
		from_city = stop

	return {
		"days": total_days,
		"cost": total_cost,
		"raid_chance": 1.0 - survive_chance,
	}


func can_move_to(destination: String) -> bool:
	if is_over():
		return false
	var route: Dictionary = route_to(destination)
	return not route.is_empty() and silver >= route["cost"]


## 移動する。最短経路が複数区間にまたがる場合も、1回の呼び出しで最終目的地
## まで一括して進む（プレイヤーの操作は1クリックのまま）。
## 黒ゾーンを含む区間ごとに独立して襲撃判定を行う（Q6 の「片道につき1度」を
## 区間単位に一般化したもの）。被弾しても旅程はそのまま最終目的地まで続く。
## 積荷は最初の被弾で失われ、同じ旅程内で2度目以降の被弾があってもログは
## 重複させない（乱数の消費自体は区間ごとに必ず行い、決定性を保つ）。
func move_to(destination: String) -> bool:
	if not can_move_to(destination):
		return false
	var path: Array[String] = _shortest_path(current_city, destination)
	var route: Dictionary = route_to(destination)
	silver -= route["cost"]
	_log("%s へ移動（%d日、費用 %d）" % [GameData.CITIES[destination]["name"], route["days"], route["cost"]], LogKind.TRAVEL)
	silver_changed.emit(silver)

	var raided_this_trip: bool = false
	var from_city: String = current_city
	for stop: String in path:
		var leg: Dictionary = _direct_leg(from_city, stop)
		current_city = stop
		if leg["raid_chance"] > 0.0:
			var this_leg_raided: bool = _rng.randf() < leg["raid_chance"]
			if this_leg_raided:
				raided_this_trip = true
		for i: int in leg["days"]:
			_advance_day()
		from_city = stop

	if raided_this_trip:
		cargo.clear()
		_log("襲撃された。積荷を全て失った。", LogKind.RAID)
		cargo_changed.emit()
	return true


# --- 探索（1日消費） ---

## 積荷にある戦闘装備（GameData.EXPLORE_COMBAT_ITEMS）による成功率の加算。
## 同種は EXPLORE_EQUIP_UNIT_CAP 個までしか加算されない
## （種類を跨いで持つ方が伸びる設計）。
func explore_equip_bonus() -> float:
	var bonus: float = 0.0
	for item_id: String in GameData.EXPLORE_COMBAT_ITEMS:
		bonus += mini(cargo_count(item_id), GameData.EXPLORE_EQUIP_UNIT_CAP) * GameData.EXPLORE_EQUIP_BONUS_PER_UNIT
	return minf(bonus, GameData.EXPLORE_EQUIP_BONUS_CAP)


## 探索の成功率。レイヴンスパイアは黒ゾーンの並びで基本確率が下がる。
func explore_chance() -> float:
	var base: float = GameData.EXPLORE_BASE_CHANCE
	if current_city == GameData.CAERLEON:
		base -= GameData.EXPLORE_CAERLEON_PENALTY
	return clampf(base + explore_equip_bonus(), 0.0, GameData.EXPLORE_MAX_CHANCE)


## 探索する。成功すればシルバー・レア品・島倉庫のブーストを得る。
## 失敗すると積荷の戦闘装備（GameData.EXPLORE_COMBAT_ITEMS）を全て失う（資源は無傷）。
## 黒ゾーン襲撃の「積荷全損」とは区別する。
func explore() -> bool:
	if is_over():
		return false
	var is_caerleon: bool = current_city == GameData.CAERLEON
	if _rng.randf() < explore_chance():
		_apply_explore_success(is_caerleon)
	else:
		_apply_explore_failure()
	_advance_day()
	return true


func _apply_explore_success(is_caerleon: bool) -> void:
	var silver_gain: int = _rng.randi_range(GameData.EXPLORE_SILVER_MIN, GameData.EXPLORE_SILVER_MAX)
	if is_caerleon:
		silver_gain = int(silver_gain * GameData.EXPLORE_CAERLEON_SILVER_MULT)
	silver += silver_gain

	var gem_count: int = _rng.randi_range(GameData.EXPLORE_GEM_MIN, GameData.EXPLORE_GEM_MAX)
	var granted_gems: int = _grant_item("sunstone", gem_count)

	var relic_chance: float = GameData.EXPLORE_CAERLEON_RELIC_CHANCE if is_caerleon else GameData.EXPLORE_RELIC_CHANCE
	var granted_relic: bool = _rng.randf() < relic_chance and _grant_item("ancient_relic", 1) > 0

	_boost_days_left = maxi(_boost_days_left, GameData.EXPLORE_BOOST_DAYS)

	var reward_note: String = "%s を %d 個" % [GameData.ITEMS["sunstone"]["name"], granted_gems]
	if granted_relic:
		reward_note += "、%s を1個" % GameData.ITEMS["ancient_relic"]["name"]
	# "探索成功"/"探索失敗" を必ず含める。main.gd はログ本文のキーワードで
	# 音・配色を分岐しており（"探索" で SE、"探索失敗" で警戒色）、
	# 都市ごとに異なる explore_flavor だけに頼ると一部の都市で拾えなくなる。
	_log("%s で探索成功（%s）。シルバー %d と%s獲得。%d日間、島の労働者の産出が増える" % [
		GameData.CITIES[current_city]["name"], GameData.CITIES[current_city]["explore_flavor"],
		silver_gain, reward_note, GameData.EXPLORE_BOOST_DAYS], LogKind.EXPLORE)
	silver_changed.emit(silver)
	cargo_changed.emit()


func _apply_explore_failure() -> void:
	var lost: bool = false
	for item_id: String in GameData.EXPLORE_COMBAT_ITEMS:
		if cargo_count(item_id) > 0:
			cargo.erase(item_id)
			lost = true
	var flavor: String = GameData.CITIES[current_city]["explore_flavor"]
	if lost:
		_log("%s で探索失敗（%s）。積荷の戦闘装備を失った。" % [GameData.CITIES[current_city]["name"], flavor], LogKind.EXPLORE)
		cargo_changed.emit()
	else:
		_log("%s で探索失敗（%s）。" % [GameData.CITIES[current_city]["name"], flavor], LogKind.EXPLORE)


## 積載の空きまで item_id を count 個だけ積む。積み切れない分はシルバーに換算する。
## 探索の報酬は選べないため、購入/製作と違って積載超過を許さない
## （free_capacity() が常に非負である前提を他の計算[max_withdrawable()等]が
## 使っているため、崩さないように換金で受け止める）。戻り値は積めた個数。
## シグナルは呼び出し側でまとめて発火するため、ここでは emit しない。
func _grant_item(item_id: String, count: int) -> int:
	if count <= 0:
		return 0
	var weight: int = GameData.ITEMS[item_id]["weight"]
	var grantable: int = mini(count, free_capacity() / weight)
	if grantable > 0:
		cargo[item_id] = cargo_count(item_id) + grantable
	var overflow: int = count - grantable
	if overflow > 0:
		silver += overflow * GameData.ITEMS[item_id]["base_price"]
	return grantable


# --- 島と労働者 ---

func worker_count() -> int:
	return GameData.ISLAND_LEVELS[island_level]["workers"]


func warehouse_count(item_id: String) -> int:
	return warehouse.get(item_id, 0)


func warehouse_total() -> int:
	var total: int = 0
	for item_id: String in warehouse:
		total += warehouse[item_id]
	return total


func is_island_max_level() -> bool:
	return island_level >= GameData.ISLAND_LEVELS.size() - 1


## 次のレベルへの拡張費用。最大レベルなら -1。
func island_upgrade_cost() -> int:
	if is_island_max_level():
		return -1
	return GameData.ISLAND_LEVELS[island_level + 1]["cost"]


## 島を1段階拡張する。レベルは飛ばせない。
func upgrade_island() -> bool:
	if is_island_max_level():
		return false
	var cost: int = island_upgrade_cost()
	if silver < cost:
		return false
	silver -= cost
	island_level += 1
	_log("島をレベル%d へ拡張した（費用 %d、労働者 %d 人）" % [island_level, cost, worker_count()], LogKind.UPGRADE)
	silver_changed.emit(silver)
	island_upgraded.emit(island_level)
	return true


## 労働者が1日ぶん働く。1人につきランダムな資源を2個運ぶ（Q4: 5資源から均等）。
## 探索成功のブーストが残っていれば産出量が倍になる。
func _run_workers() -> void:
	var workers: int = worker_count()
	if workers <= 0:
		return
	var resources: Array[String] = GameData.resource_ids()
	var per_worker: int = GameData.RESOURCES_PER_WORKER_PER_DAY
	if _boost_days_left > 0:
		per_worker *= GameData.EXPLORE_BOOST_MULT
	var delivered: int = workers * per_worker
	for i: int in delivered:
		var pick: String = resources[_rng.randi_range(0, resources.size() - 1)]
		warehouse[pick] = warehouse_count(pick) + 1
	warehouse_changed.emit()


## 島倉庫から積荷へ移せる最大数（積載空きで決まる）。
func max_withdrawable() -> int:
	var space: int = free_capacity()
	var available: int = warehouse_total()
	# 倉庫にあるのは資源のみ（重量1）なので、空きがそのまま個数になる。
	return mini(space / GameData.RESOURCE_WEIGHT, available)


## 島倉庫から積載上限まで引き取る（1日消費）。
func withdraw_from_warehouse() -> bool:
	if is_over() or warehouse.is_empty():
		return false
	var moved: int = 0
	var limit: int = max_withdrawable()
	# 品目ごとに順に積み、積載上限で打ち切る。
	for item_id: String in warehouse.keys():
		if moved >= limit:
			break
		var take: int = mini(warehouse[item_id], limit - moved)
		if take <= 0:
			continue
		cargo[item_id] = cargo_count(item_id) + take
		var remaining: int = warehouse[item_id] - take
		if remaining > 0:
			warehouse[item_id] = remaining
		else:
			warehouse.erase(item_id)
		moved += take

	_log("島倉庫から %d 個を引き取った（倉庫の残り %d 個）" % [moved, warehouse_total()], LogKind.DAY)
	cargo_changed.emit()
	warehouse_changed.emit()
	_advance_day()
	return true


# --- 騎乗 ---

## 騎乗を購入して積載量を変える。同じ騎乗は買い直せない。
func buy_mount(mount_id: String) -> bool:
	if not GameData.MOUNTS.has(mount_id) or mount_id == mount:
		return false
	var cost: int = GameData.MOUNTS[mount_id]["cost"]
	if silver < cost:
		return false
	silver -= cost
	mount = mount_id
	_log("%s を購入した（費用 %d、積載 %d）" % [
		GameData.MOUNTS[mount_id]["name"], cost, capacity()], LogKind.UPGRADE)
	silver_changed.emit(silver)
	mount_changed.emit(mount_id)
	return true


# --- 時間 ---

## 何もせず1日を送る。移動費が払えない状態でもこれだけは常に行える（Q7）。
func rest() -> bool:
	if is_over():
		return false
	_log("休息した。", LogKind.DAY)
	_advance_day()
	return true


func _advance_day() -> void:
	day += 1
	if is_over():
		# 60日を終えた時点で相場も労働も止まる。純資産は積荷・倉庫を
		# 評価額として算入する（Q8: 強制換金はしない）。
		_log("60日が終了した。純資産 %d（%s）" % [net_worth(), rank()])
		day_advanced.emit(day)
		return
	# 在庫と需要を先に補充してから相場を引く。買値・売値は在庫の薄さを
	# 掛けて出すため、順序が逆だと表示と実際の取引がその日だけ食い違う。
	market.advance_day()
	prices.reroll()
	_record_memo()
	market_changed.emit()
	_run_workers()
	if _boost_days_left > 0:
		_boost_days_left -= 1
	day_advanced.emit(day)


# --- 相場メモ ---

## 現在地の価格を既知の相場として記録する。
## 表画面は M7 だが、記録は最初から取らないと履歴が残らない。
func _record_memo() -> void:
	memo[current_city] = {
		"day": day,
		"prices": prices.prices[current_city].duplicate(),
	}


## その都市の記録が古い（MEMO_STALE_DAYS 以上経過）か。未訪問なら false。
## セラフィーナが同行していれば記録は古くならない。
func is_memo_stale(city_id: String) -> bool:
	if not memo.has(city_id):
		return false
	if active_companion == "serafina":
		return false
	return day - memo[city_id]["day"] >= GameData.MEMO_STALE_DAYS


func has_memo(city_id: String) -> bool:
	return memo.has(city_id)


## 記録が何日前のものか。未訪問なら -1。現在地は 0。
func memo_age(city_id: String) -> int:
	if not memo.has(city_id):
		return -1
	return day - memo[city_id]["day"]


## 記録されている価格。未訪問なら -1。
func memo_price(city_id: String, item_id: String) -> int:
	if not memo.has(city_id):
		return -1
	return memo[city_id]["prices"].get(item_id, -1)


# --- 保存と復元 ---

## この時点の状態をすべて辞書に写す。保存形式（JSON など）は知らない。
##
## _rng の状態を含めるのが要点。これが無いとロード後の乱数系列が変わり、
## 同じセーブから同じ展開にならない。
##
## seed と state を**文字列で持つ**のは、64bit の値が JSON の double
## （仮数部53bit）では正確に往復しないため。実測で state が
## 4857946085375722947 -> 4857946085375722496 に化ける。
##
## prices も保存する。reroll() は「次の日の相場」を作るものなので、
## state を戻して引き直しても今日の相場は再現できない。
func to_dict() -> Dictionary:
	# prices と rng は続けて読む。間に乱数を消費すると噛み合わなくなる。
	return {
		"day": day,
		"silver": silver,
		"current_city": current_city,
		"mount": mount,
		"island_level": island_level,
		"active_companion": active_companion,
		"cargo": cargo.duplicate(true),
		"warehouse": warehouse.duplicate(true),
		"memo": memo.duplicate(true),
		"log_entries": log_entries.duplicate(),
		"prices": prices.prices.duplicate(true),
		"market": market.to_dict(),
		"rng": {"seed": str(_rng.seed), "state": str(_rng.state)},
		"boost_days_left": _boost_days_left,
	}


## 辞書から状態を復元する。
##
## 既存のインスタンスへの上書きとして使う（GameSession.new(0) してから呼ぶ）。
## _init() が PriceTable と初回のメモを作るため、素の状態を別に用意するより
## 作ってから上書きする方が既存の流れに手を入れずに済む。
##
## 欠損したキーには触らない。宣言時の初期値がそのまま残る。
## **数値は必ず int() を通すこと。** JSON を経由すると float になっており、
## そのまま入れると後の整数除算が浮動小数除算に化ける。
##
## 復元の途中で _log() を呼ばないこと。日誌を戻した後に自分で行を足すと
## 往復の同一性が崩れる。
func from_dict(data: Dictionary) -> void:
	if data.has("day"):
		day = int(data["day"])
	if data.has("silver"):
		silver = int(data["silver"])
	if data.has("current_city"):
		current_city = str(data["current_city"])
	if data.has("mount"):
		mount = str(data["mount"])
	if data.has("island_level"):
		island_level = int(data["island_level"])
	if data.has("active_companion"):
		active_companion = str(data["active_companion"])
	if data.has("boost_days_left"):
		_boost_days_left = int(data["boost_days_left"])

	if data.has("cargo"):
		cargo = _restore_counts(data["cargo"])
	if data.has("warehouse"):
		warehouse = _restore_counts(data["warehouse"])
	if data.has("memo"):
		memo = _restore_memo(data["memo"])
	if data.has("log_entries"):
		log_entries.clear()
		for entry: Variant in data["log_entries"]:
			log_entries.append(str(entry))

	# RNG を戻してから相場を決める。相場を引き直す場合に系列を合わせるため。
	if data.has("rng"):
		var rng_data: Dictionary = data["rng"]
		if rng_data.has("seed"):
			_rng.seed = str(rng_data["seed"]).to_int()
		if rng_data.has("state"):
			_rng.state = str(rng_data["state"]).to_int()

	# 在庫と需要を相場より先に戻す。買値・売値が在庫を参照するため。
	# 記録が無ければ満杯から始める（在庫を入れる前の古いセーブがこれに当たる。
	# 品切れ状態を勝手に作るより、補充済みとして読む方が安全側）。
	if data.has("market"):
		market.from_dict(data["market"])
	else:
		market.reset()

	if data.has("prices"):
		# 検証と引き直しの判断は PriceTable に委ねる（market の from_dict と対称）。
		prices.from_dict(data["prices"])
	else:
		# 相場が無ければ引き直す。get_price() が落ちる状態にはしない。
		prices.reroll()


## item_id -> 個数。未知の品目は捨てる（品目を消した後の古いセーブ対策）。
func _restore_counts(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for item_id: Variant in source:
		var key: String = str(item_id)
		if not GameData.ITEMS.has(key):
			continue
		var count: int = int(source[item_id])
		if count > 0:
			out[key] = count
	return out


## city_id -> {"day": int, "prices": {item_id -> int}}。未知の都市は捨てる。
func _restore_memo(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for city_id: Variant in source:
		var key: String = str(city_id)
		if not GameData.CITIES.has(key):
			continue
		# 手で編集されたセーブでは辞書以外が入っていることがある。
		if not (source[city_id] is Dictionary):
			continue
		var entry: Dictionary = source[city_id]
		var entry_prices: Dictionary = {}
		for item_id: Variant in entry.get("prices", {}):
			var item_key: String = str(item_id)
			if GameData.ITEMS.has(item_key):
				entry_prices[item_key] = int(entry["prices"][item_id])
		out[key] = {"day": int(entry.get("day", 1)), "prices": entry_prices}
	return out


# --- 内部 ---

func _reduce_cargo(item_id: String, count: int) -> void:
	var remaining: int = cargo_count(item_id) - count
	if remaining > 0:
		cargo[item_id] = remaining
	else:
		cargo.erase(item_id)


func _log(message: String, kind: LogKind = LogKind.NONE) -> void:
	var entry: String = "[%d日目] %s" % [day, message]
	log_entries.append(entry)
	logged.emit(entry, kind)
