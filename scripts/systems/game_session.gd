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
signal logged(message: String)

var day: int = 1
var silver: int = GameData.INITIAL_SILVER
var current_city: String = GameData.INITIAL_CITY
var mount: String = GameData.INITIAL_MOUNT

## item_id -> 個数
var cargo: Dictionary = {}

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


## 純資産 = シルバー + 積荷の基準価格 × 0.9
## （島倉庫は M3 で加算する）
func net_worth() -> int:
	var stock_value: int = 0
	for item_id: String in cargo:
		stock_value += GameData.ITEMS[item_id]["base_price"] * cargo[item_id]
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
	if count <= 0 or count > max_buyable(item_id):
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
	if count <= 0 or count > cargo_count(item_id):
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
	if count <= 0 or count > max_craftable(item_id):
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


# --- 時間 ---

## 何もせず1日を送る。
func rest() -> void:
	_log("休息した。")
	_advance_day()


func _advance_day() -> void:
	day += 1
	prices.reroll()
	_record_memo()
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
