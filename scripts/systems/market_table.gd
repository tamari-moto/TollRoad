extends RefCounted
## 全都市 × 全品目の在庫と需要。
##
## 在庫＝その都市が売ってくれる上限（プレイヤーが買うと減る）。
## 需要＝その都市が買い取ってくれる上限（プレイヤーが売ると減る）。
## どちらも毎日 CITY の生産量・消費量ぶんだけ補充され、上限で頭打ちになる。
##
## 生産量は GameData.CITIES の specialty / bonus から導く（表を別に持たない）。
## 都市を足しても、specialty と bonus を書けば在庫と需要が自動で決まる。
##
## 価格連動はここでは行わず、比率（stock_pressure / demand_pressure）だけを
## 返す。実際に価格へ掛けるのは price_table.gd で、価格の決定を1箇所に
## 留めるため（在庫と価格の両方が価格を触ると、どちらが効いたか追えなくなる）。

const GameData = preload("res://scripts/systems/game_data.gd")

## stock[city_id][item_id] -> int / demand[city_id][item_id] -> int
var stock: Dictionary = {}
var demand: Dictionary = {}


func _init() -> void:
	reset()


## 在庫・需要を初期値（＝上限）で埋める。
## 満杯から始めるのは、初日に「品切れの都市」を引かせないため。
func reset() -> void:
	stock.clear()
	demand.clear()
	for city_id: String in GameData.CITIES:
		var city_stock: Dictionary = {}
		var city_demand: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			city_stock[item_id] = stock_cap(city_id, item_id)
			city_demand[item_id] = demand_cap(city_id, item_id)
		stock[city_id] = city_stock
		demand[city_id] = city_demand


# --- 生産と消費の量（GameData の定義から導く） ---

## その都市がその品目を1日に何個生産するか。
## 特産（specialty）と生産地（bonus）に厚く、それ以外は細く出る。
## レアは誰も生産しない（探索でしか手に入らない）。
static func production_of(city_id: String, item_id: String) -> int:
	var kind: int = GameData.ITEMS[item_id]["kind"]
	if kind == GameData.ItemKind.RARE:
		return 0
	var city: Dictionary = GameData.CITIES[city_id]
	if city["specialty"] == item_id:
		return GameData.PRODUCTION_SPECIALTY
	if city["bonus"] == item_id:
		return GameData.PRODUCTION_BONUS
	if kind == GameData.ItemKind.EQUIPMENT:
		return GameData.PRODUCTION_OTHER_EQUIPMENT
	return GameData.PRODUCTION_OTHER_RESOURCE


## その都市がその品目を1日に何個買い取るか（需要の回復量）。
## 生産と逆向きにする — 自前で作れるものは欲しがらず、作れないものを欲しがる。
## レイヴンスパイアは装備の集積地なので装備の需要が厚い（MOD_CAERLEON_EQUIPMENT
## で価格が高いことと揃える。高く買うのに少ししか捌けない、では噛み合わない）。
static func consumption_of(city_id: String, item_id: String) -> int:
	var kind: int = GameData.ITEMS[item_id]["kind"]
	if city_id == GameData.CAERLEON:
		if kind == GameData.ItemKind.EQUIPMENT:
			return GameData.CONSUMPTION_CAERLEON_EQUIPMENT
		return GameData.CONSUMPTION_CAERLEON_OTHER
	var city: Dictionary = GameData.CITIES[city_id]
	# 自分で作っているものは持ち込まれても要らない。
	if city["specialty"] == item_id or city["bonus"] == item_id:
		return GameData.CONSUMPTION_LOCAL_SURPLUS
	if kind == GameData.ItemKind.EQUIPMENT:
		return GameData.CONSUMPTION_EQUIPMENT
	return GameData.CONSUMPTION_RESOURCE


## 在庫の上限。生産量の CAP_DAYS 日ぶんまで積み上がる。
## 「しばらく来なかった都市には貯まっている」を表す。
static func stock_cap(city_id: String, item_id: String) -> int:
	return production_of(city_id, item_id) * GameData.MARKET_CAP_DAYS


## 需要の上限。同じく消費量の CAP_DAYS 日ぶん。
static func demand_cap(city_id: String, item_id: String) -> int:
	return consumption_of(city_id, item_id) * GameData.MARKET_CAP_DAYS


# --- 参照 ---

func stock_of(city_id: String, item_id: String) -> int:
	return stock.get(city_id, {}).get(item_id, 0)


func demand_of(city_id: String, item_id: String) -> int:
	return demand.get(city_id, {}).get(item_id, 0)


## 在庫の充足度（0.0=品切れ、1.0=満杯）。上限が0なら常に0（＝品切れ扱い）。
func stock_ratio(city_id: String, item_id: String) -> float:
	var cap: int = stock_cap(city_id, item_id)
	if cap <= 0:
		return 0.0
	return clampf(float(stock_of(city_id, item_id)) / float(cap), 0.0, 1.0)


## 需要の充足度（0.0=買い手なし、1.0=満杯）。
func demand_ratio(city_id: String, item_id: String) -> float:
	var cap: int = demand_cap(city_id, item_id)
	if cap <= 0:
		return 0.0
	return clampf(float(demand_of(city_id, item_id)) / float(cap), 0.0, 1.0)


# --- 価格連動 ---
#
# 在庫が減るほど買値が上がり、需要が減るほど売値が下がる。
# どちらも「満杯なら 1.0、空なら SCARCITY_MAX / GLUT_MIN」の線形。
# 掛け率にして返すのは、基準価格とゆらぎの決定を price_table.gd 側に
# 残したままにするため（価格を作る場所は1つに保つ）。

## 在庫の希少さによる買値の掛け率。在庫が薄いほど 1.0 より大きくなる。
func scarcity_multiplier(city_id: String, item_id: String) -> float:
	var fullness: float = stock_ratio(city_id, item_id)
	return lerpf(GameData.PRICE_SCARCITY_MAX, 1.0, fullness)


## 需要の飽きによる売値の掛け率。需要が尽きるほど 1.0 より小さくなる。
func glut_multiplier(city_id: String, item_id: String) -> float:
	var fullness: float = demand_ratio(city_id, item_id)
	return lerpf(GameData.PRICE_GLUT_MIN, 1.0, fullness)


# --- 取引による増減 ---

## プレイヤーが買った分だけ在庫を減らす。
## 同時に、その品目がこの都市へ「戻ってきた」ぶん需要も減らす扱いはしない
## （買いと売りは別々の帳簿として動かす。片方の操作が両方を動かすと、
## プレイヤーから見て何がどう減ったのか追えなくなる）。
func consume_stock(city_id: String, item_id: String, count: int) -> void:
	if count <= 0 or not stock.has(city_id):
		return
	stock[city_id][item_id] = maxi(0, stock_of(city_id, item_id) - count)


## プレイヤーが売った分だけ需要を減らす。
func consume_demand(city_id: String, item_id: String, count: int) -> void:
	if count <= 0 or not demand.has(city_id):
		return
	demand[city_id][item_id] = maxi(0, demand_of(city_id, item_id) - count)


## 1日ぶん生産・消費が進み、在庫と需要が上限まで補充される。
## GameSession の _advance_day() から相場の引き直しと同じ頻度で呼ぶ。
func advance_day() -> void:
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			var next_stock: int = stock_of(city_id, item_id) + production_of(city_id, item_id)
			stock[city_id][item_id] = mini(next_stock, stock_cap(city_id, item_id))
			var next_demand: int = demand_of(city_id, item_id) + consumption_of(city_id, item_id)
			demand[city_id][item_id] = mini(next_demand, demand_cap(city_id, item_id))


# --- 保存と復元 ---

## stock / demand をそのまま辞書で返す。
func to_dict() -> Dictionary:
	return {
		"stock": stock.duplicate(true),
		"demand": demand.duplicate(true),
	}


## 保存された在庫・需要を戻す。
##
## 今の GameData と噛み合わなければ**全体を作り直す**（prices と同じ方針）。
## 一部だけ埋めると、その品目だけ生産の系列から外れた値になる。
##
## JSON.parse_string() は数値を float で返すため、必ず int() を通すこと。
func from_dict(data: Dictionary) -> void:
	var restored_stock: Dictionary = _restore_side(data.get("stock", {}), true)
	var restored_demand: Dictionary = _restore_side(data.get("demand", {}), false)
	if restored_stock.is_empty() or restored_demand.is_empty():
		reset()
		return
	stock = restored_stock
	demand = restored_demand


## 片側（在庫または需要）を復元する。欠けている都市・品目が1つでもあれば
## 空を返し、呼び出し側に全体の作り直しを促す。
func _restore_side(source: Variant, is_stock: bool) -> Dictionary:
	if not (source is Dictionary):
		return {}
	var out: Dictionary = {}
	for city_id: String in GameData.CITIES:
		if not source.has(city_id) or not (source[city_id] is Dictionary):
			return {}
		var city_values: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			if not source[city_id].has(item_id):
				return {}
			var cap: int = stock_cap(city_id, item_id) if is_stock else demand_cap(city_id, item_id)
			city_values[item_id] = clampi(int(source[city_id][item_id]), 0, cap)
		out[city_id] = city_values
	return out
