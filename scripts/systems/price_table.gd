extends RefCounted
## 全都市 × 全品目の価格表。日が進むたびに再抽選される。
##
## 価格 = 基準価格 × 都市補正 × ゆらぎ
## ゆらぎは都市×品目ごとに独立して抽選する（Q5）。そのため同じ品目でも
## 都市間の価格差が日ごとに大きく揺れ、「今日どこが安いか」を探す動機になる。
##
## ここに入る prices は**その日の建値**で、在庫・需要の増減では動かない。
## 買い占め／売り崩しによる価格の変化は buy_price() / sell_price() が
## MarketTable の掛け率を都度かけて出す（その場の取引で建値そのものを
## 書き換えると、日をまたいだ相場メモとの整合が取れなくなるため）。

const GameData = preload("res://scripts/systems/game_data.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")

## prices[city_id][item_id] -> int
var prices: Dictionary = {}

var _rng: RandomNumberGenerator

## 在庫と需要。価格連動のために参照する。null なら連動しない（建値のまま）。
var _market: MarketTable


func _init(rng: RandomNumberGenerator, market: MarketTable = null) -> void:
	_rng = rng
	_market = market
	reroll()


## 全都市・全品目の価格を引き直す。
func reroll() -> void:
	prices.clear()
	for city_id: String in GameData.CITIES:
		var city_prices: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			city_prices[item_id] = _roll_price(city_id, item_id)
		prices[city_id] = city_prices


## その日の建値。在庫・需要の増減では動かない（相場メモが記録するのもこれ）。
func get_price(city_id: String, item_id: String) -> int:
	return prices[city_id][item_id]


## 実際に買うときの単価。在庫が薄いほど建値より高くなる。
## 在庫を参照しない場合（_market が null）は建値のまま。
func buy_price(city_id: String, item_id: String) -> int:
	if _market == null:
		return get_price(city_id, item_id)
	return int(round(get_price(city_id, item_id)
		* _market.scarcity_multiplier(city_id, item_id)))


## 実際に売るときの単価。需要が尽きるほど建値より安くなる。
func sell_price(city_id: String, item_id: String) -> int:
	if _market == null:
		return get_price(city_id, item_id)
	return int(round(get_price(city_id, item_id)
		* _market.glut_multiplier(city_id, item_id)))


# --- 保存と復元 ---

## 保存された相場を戻す。MarketTable.from_dict() と対になる。
##
## 今の GameData と噛み合わなければ**全体を引き直す**。一部だけ埋めると、
## その品目だけ乱数系列の外の値になる（都市や品目を足した後の古いセーブが
## これに当たる。1日ぶん相場が変わるが、決定性は保たれる）。
##
## **reroll() は RNG を消費する。** 呼ぶ／呼ばないの分岐が変わるとロード後の
## 乱数系列がずれ、同じセーブから同じ展開にならなくなる。「1つでも欠けたら
## 引き直す・全部揃っていれば一度も引かない」という意味論を厳密に保つこと。
func from_dict(data: Dictionary) -> void:
	var restored: Dictionary = _restore_prices(data)
	if restored.is_empty():
		reroll()
		return
	prices = restored


## 保存された相場を検証して返す。欠けている都市・品目が1つでもあれば空を返し、
## 呼び出し側に全体の引き直しを促す（MarketTable._restore_side() と同じ規約）。
##
## **この関数は RNG を消費しない。** 引き直しは呼び出し側の責務に寄せてある。
##
## 手で編集されたセーブでは辞書以外が入っていることがあるため、型を確かめる
## （market_table.gd の _restore_side() と game_session.gd の _restore_memo() が
## 同じ理由で同じ checks を持つ）。
##
## JSON.parse_string() は数値を float で返すため、必ず int() を通すこと。
func _restore_prices(source: Variant) -> Dictionary:
	if not (source is Dictionary):
		return {}
	var out: Dictionary = {}
	for city_id: String in GameData.CITIES:
		if not source.has(city_id) or not (source[city_id] is Dictionary):
			return {}
		var city_prices: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			if not source[city_id].has(item_id):
				return {}
			city_prices[item_id] = int(source[city_id][item_id])
		out[city_id] = city_prices
	return out


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
