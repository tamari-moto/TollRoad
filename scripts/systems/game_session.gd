extends RefCounted
## 1回のプレイ（60日）の状態と、プレイヤーが取れる行動をまとめたもの。
##
## autoload には依存しない。load() + .new() で直接生成して駆動できるため、
## --script のハーネスからそのまま検証できる（--script は autoload を
## 初期化しないため、この形を保つこと）。

const GameData = preload("res://scripts/systems/game_data.gd")
const PriceTable = preload("res://scripts/systems/price_table.gd")

signal day_advanced(day: int)
signal silver_changed(amount: int)
signal cargo_changed()
signal warehouse_changed()
signal island_upgraded(level: int)
signal mount_changed(mount_id: String)
signal logged(message: String)

var day: int = 1
var silver: int = GameData.INITIAL_SILVER
var current_city: String = GameData.INITIAL_CITY
var mount: String = GameData.INITIAL_MOUNT
var island_level: int = 0

## item_id -> 個数
var cargo: Dictionary = {}

## 島倉庫。容量は無制限（Q3）。item_id -> 個数
var warehouse: Dictionary = {}

## city_id -> {"day": int, "prices": {item_id -> int}}
var memo: Dictionary = {}

## 航海日誌。M7 の画面はこれを表示するだけでよい。
var log_entries: Array[String] = []

var prices: PriceTable
var _rng: RandomNumberGenerator


## seed を渡すと再現可能になる。検証シナリオでは必ず固定すること。
func _init(rng_seed: int = 0) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = rng_seed
	prices = PriceTable.new(_rng)
	_record_memo()


# --- 状態の参照 ---

func capacity() -> int:
	return GameData.MOUNTS[mount]["capacity"]


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

## 購入可能な最大数（シルバーと積載空きの小さい方）。
func max_buyable(item_id: String) -> int:
	var price: int = prices.get_price(current_city, item_id)
	if price <= 0:
		return 0
	var by_silver: int = silver / price
	var by_space: int = free_capacity() / GameData.ITEMS[item_id]["weight"]
	return mini(by_silver, by_space)


func buy(item_id: String, count: int) -> bool:
	if is_over() or count <= 0 or count > max_buyable(item_id):
		return false
	var price: int = prices.get_price(current_city, item_id)
	var total: int = price * count
	silver -= total
	cargo[item_id] = cargo_count(item_id) + count
	_log("%s で %s を %d 個購入（単価 %d、計 %d）" % [
		GameData.CITIES[current_city]["name"], GameData.ITEMS[item_id]["name"], count, price, total])
	silver_changed.emit(silver)
	cargo_changed.emit()
	return true


## 売却。税は売上総額にかかる（Q2）。手取り = 総額 - 税。
func sell(item_id: String, count: int) -> bool:
	if is_over() or count <= 0 or count > cargo_count(item_id):
		return false
	var price: int = prices.get_price(current_city, item_id)
	var gross: int = price * count
	var tax: int = int(round(gross * GameData.SELL_TAX_RATE))
	var net: int = gross - tax
	silver += net
	_reduce_cargo(item_id, count)
	_log("%s で %s を %d 個売却（単価 %d、総額 %d、税 %d、手取り %d）" % [
		GameData.CITIES[current_city]["name"], GameData.ITEMS[item_id]["name"], count, price, gross, tax, net])
	silver_changed.emit(silver)
	cargo_changed.emit()
	return true


# --- 製作（1日消費） ---

## その装備をこの都市で作ると材料が還元されるか（生産ボーナス都市か）。
func has_craft_bonus(item_id: String) -> bool:
	return GameData.CITIES[current_city]["bonus"] == item_id


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
	var by_silver: int = silver / GameData.CRAFT_FEE
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
	var fee: int = GameData.CRAFT_FEE * count

	silver -= fee
	_reduce_cargo(material, material_used)
	cargo[item_id] = cargo_count(item_id) + count

	var bonus_note: String = ""
	if has_craft_bonus(item_id):
		var saved: int = (GameData.CRAFT_MATERIAL_COUNT - per_unit) * count
		bonus_note = "、生産ボーナスで %s を %d 個還元" % [GameData.ITEMS[material]["name"], saved]
	_log("%s で %s を %d 個製作（%s %d 個消費、手数料 %d%s）" % [
		GameData.CITIES[current_city]["name"], GameData.ITEMS[item_id]["name"], count,
		GameData.ITEMS[material]["name"], material_used, fee, bonus_note])

	silver_changed.emit(silver)
	cargo_changed.emit()
	_advance_day()
	return true


# --- 移動 ---

## その都市へ移動するのに必要な日数・費用を返す。
## 到達不能な場合は空の Dictionary。
func route_to(destination: String) -> Dictionary:
	if destination == current_city:
		return {}
	var is_black_zone: bool = destination == GameData.CAERLEON or current_city == GameData.CAERLEON
	if is_black_zone:
		return {
			"days": GameData.MOVE_BLACK_ZONE_DAYS,
			"cost": GameData.MOVE_BLACK_ZONE_COST,
			"raid_chance": GameData.RAID_CHANCE,
		}
	if GameData.is_adjacent(current_city, destination):
		return {
			"days": GameData.MOVE_ADJACENT_DAYS,
			"cost": GameData.MOVE_ADJACENT_COST,
			"raid_chance": 0.0,
		}
	return {
		"days": GameData.MOVE_FAR_DAYS,
		"cost": GameData.MOVE_FAR_COST,
		"raid_chance": 0.0,
	}


func can_move_to(destination: String) -> bool:
	if is_over():
		return false
	var route: Dictionary = route_to(destination)
	return not route.is_empty() and silver >= route["cost"]


## 移動する。黒ゾーンでは襲撃判定を行い、被弾すると積荷を全て失う
## （シルバーと島倉庫は無傷）。
## 襲撃判定は片道につき1度（Q6）。黒ゾーンは1日移動なので区間は1つしかなく、
## カーレオンを往復すると計2回判定される（往復とも無事な確率は約61%）。
func move_to(destination: String) -> bool:
	if not can_move_to(destination):
		return false
	var route: Dictionary = route_to(destination)
	silver -= route["cost"]
	current_city = destination
	_log("%s へ移動（%d日、費用 %d）" % [GameData.CITIES[destination]["name"], route["days"], route["cost"]])
	silver_changed.emit(silver)

	var raided: bool = false
	if route["raid_chance"] > 0.0 and _rng.randf() < route["raid_chance"]:
		raided = true

	for i: int in route["days"]:
		_advance_day()

	if raided:
		cargo.clear()
		_log("襲撃された。積荷を全て失った。")
		cargo_changed.emit()
	return true


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
	_log("島をレベル%d へ拡張した（費用 %d、労働者 %d 人）" % [island_level, cost, worker_count()])
	silver_changed.emit(silver)
	island_upgraded.emit(island_level)
	return true


## 労働者が1日ぶん働く。1人につきランダムな資源を2個運ぶ（Q4: 5資源から均等）。
func _run_workers() -> void:
	var workers: int = worker_count()
	if workers <= 0:
		return
	var resources: Array[String] = GameData.resource_ids()
	var delivered: int = workers * GameData.RESOURCES_PER_WORKER_PER_DAY
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

	_log("島倉庫から %d 個を引き取った（倉庫の残り %d 個）" % [moved, warehouse_total()])
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
		GameData.MOUNTS[mount_id]["name"], cost, capacity()])
	silver_changed.emit(silver)
	mount_changed.emit(mount_id)
	return true


# --- 時間 ---

## 何もせず1日を送る。移動費が払えない状態でもこれだけは常に行える（Q7）。
func rest() -> bool:
	if is_over():
		return false
	_log("休息した。")
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
	prices.reroll()
	_record_memo()
	_run_workers()
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
func is_memo_stale(city_id: String) -> bool:
	if not memo.has(city_id):
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
		"cargo": cargo.duplicate(true),
		"warehouse": warehouse.duplicate(true),
		"memo": memo.duplicate(true),
		"log_entries": log_entries.duplicate(),
		"prices": prices.prices.duplicate(true),
		"rng": {"seed": str(_rng.seed), "state": str(_rng.state)},
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

	if data.has("prices"):
		prices.prices = _restore_prices(data["prices"])
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
		var entry: Dictionary = source[city_id]
		var entry_prices: Dictionary = {}
		for item_id: Variant in entry.get("prices", {}):
			var item_key: String = str(item_id)
			if GameData.ITEMS.has(item_key):
				entry_prices[item_key] = int(entry["prices"][item_id])
		out[key] = {"day": int(entry.get("day", 1)), "prices": entry_prices}
	return out


## 保存された相場。今の GameData と噛み合わなければ引き直す。
##
## 一部だけ埋めると、その品目だけ乱数系列の外の値になる。都市や品目を
## 足した後の古いセーブでは、丸ごと作り直す方が筋が通る（1日ぶん相場が
## 変わるが、決定性は保たれる）。
func _restore_prices(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for city_id: String in GameData.CITIES:
		if not source.has(city_id):
			prices.reroll()
			return prices.prices
		var city_prices: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			if not source[city_id].has(item_id):
				prices.reroll()
				return prices.prices
			city_prices[item_id] = int(source[city_id][item_id])
		out[city_id] = city_prices
	return out


# --- 内部 ---

func _reduce_cargo(item_id: String, count: int) -> void:
	var remaining: int = cargo_count(item_id) - count
	if remaining > 0:
		cargo[item_id] = remaining
	else:
		cargo.erase(item_id)


func _log(message: String) -> void:
	var entry: String = "[%d日目] %s" % [day, message]
	log_entries.append(entry)
	logged.emit(entry)
