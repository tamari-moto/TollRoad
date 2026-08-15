extends RefCounted
## 全都市 × 全品目の日次価格の記録。市場の価格推移グラフ（相場メモ）が読む。
##
## PriceTable.prices は「その日の建値」しか持たない（reroll() で上書きされる）。
## 日をまたいだ推移を描くには別に積み上げて残す必要があるため、この記録を持つ。
##
## **記録は訪問の有無を問わない。** 相場メモ（GameSession.memo）は訪問した都市
## だけを記録するが、こちらは市場そのものの動きを見せる用途なので、全都市を
## 毎日記録する。両者は別の目的を持つ別の記録として扱う。
##
## history[city_id][item_id] -> Array[int]。添字 0 が1日目、以後1日ごとに1件伸びる。

const GameData = preload("res://scripts/systems/game_data.gd")
const PriceTable = preload("res://scripts/systems/price_table.gd")

var history: Dictionary = {}


func _init() -> void:
	reset()


func reset() -> void:
	history.clear()
	for city_id: String in GameData.CITIES:
		var city_history: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			city_history[item_id] = [] as Array[int]
		history[city_id] = city_history


## その日の建値を1件ずつ積む。GameSession が初回と advance_day() のたびに呼ぶ。
func record(prices: PriceTable) -> void:
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			var series: Array = history[city_id][item_id]
			series.append(prices.get_price(city_id, item_id))


## city_id・item_id の系列をそのまま返す（呼び出し側で書き換えない前提の参照）。
func series(city_id: String, item_id: String) -> Array:
	return history.get(city_id, {}).get(item_id, [])


## 記録済みの日数（= 系列の長さ）。全都市・全品目で揃っている前提で1件だけ見る。
func day_count() -> int:
	for city_id: String in history:
		for item_id: String in history[city_id]:
			return history[city_id][item_id].size()
	return 0


# --- 保存と復元 ---

func to_dict() -> Dictionary:
	return history.duplicate(true)


## 保存された履歴を戻す。current_day と全都市×全品目で系列長が一致しない場合は
## 過去を再現できないので、全体を作り直して当日ぶんだけ記録し直す
## （prices / market と同じ「一部だけ埋めない」方針）。
func from_dict(data: Variant, current_day: int, prices: PriceTable) -> void:
	var restored: Dictionary = _restore(data, current_day)
	if restored.is_empty():
		reset()
		record(prices)
		return
	history = restored


func _restore(source: Variant, current_day: int) -> Dictionary:
	if not (source is Dictionary):
		return {}
	var out: Dictionary = {}
	for city_id: String in GameData.CITIES:
		if not source.has(city_id) or not (source[city_id] is Dictionary):
			return {}
		var city_history: Dictionary = {}
		for item_id: String in GameData.ITEMS:
			if not source[city_id].has(item_id) or not (source[city_id][item_id] is Array):
				return {}
			var raw: Array = source[city_id][item_id]
			if raw.size() != current_day:
				return {}
			var series: Array[int] = []
			for value: Variant in raw:
				series.append(int(value))
			city_history[item_id] = series
		out[city_id] = city_history
	return out
