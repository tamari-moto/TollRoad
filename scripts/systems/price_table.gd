extends RefCounted
## 全都市 × 全品目の価格表。日が進むたびに再抽選される。
##
## 価格 = 基準価格 × 都市補正 × ゆらぎ
## ゆらぎは都市×品目ごとに独立して抽選する（Q5）。そのため同じ品目でも
## 都市間の価格差が日ごとに大きく揺れ、「今日どこが安いか」を探す動機になる。

const GameData = preload("res://scripts/systems/game_data.gd")

## prices[city_id][item_id] -> int
var prices: Dictionary = {}

var _rng: RandomNumberGenerator


func _init(rng: RandomNumberGenerator) -> void:
	_rng = rng
	reroll()


## 全都市・全品目の価格を引き直す。
func reroll() -> void:
	prices.clear()
	for city_id: String in GameData.CITIES:
		var city_prices: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			city_prices[item_id] = _roll_price(city_id, item_id)
		prices[city_id] = city_prices


func get_price(city_id: String, item_id: String) -> int:
	return prices[city_id][item_id]


## 都市補正を返す。該当しなければ 1.0。
static func city_modifier(city_id: String, item_id: String) -> float:
	var city: Dictionary = GameData.CITIES[city_id]
	if city_id == GameData.CAERLEON:
		var kind: int = GameData.ITEMS[item_id]["kind"]
		if kind == GameData.ItemKind.EQUIPMENT:
			return GameData.MOD_CAERLEON_EQUIPMENT
		return GameData.MOD_CAERLEON_RESOURCE
	if city["specialty"] == item_id:
		return GameData.MOD_SPECIALTY
	if city["bonus"] == item_id:
		return GameData.MOD_BONUS
	return 1.0


## 端数処理は最後に一度だけ行う（基準価格 × 補正 × ゆらぎ を丸める）。
## 途中で int 化すると手計算の期待値とずれるため、規約として固定する。
func _roll_price(city_id: String, item_id: String) -> int:
	var base: int = GameData.ITEMS[item_id]["base_price"]
	var modifier: float = city_modifier(city_id, item_id)
	var jitter: float = _rng.randf_range(GameData.JITTER_MIN, GameData.JITTER_MAX)
	return int(round(base * modifier * jitter))
