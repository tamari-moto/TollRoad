extends RefCounted
## 物流の日ごとの記録。デバッグ画面（logistics_debug_panel.gd）のグラフが読む。
##
## **GameSession はこれを持たない。** 持たせると、セーブに入れるか捨てるかを
## 決めねばならず、入れれば版の互換を1つ増やし、捨てれば「続きから」の
## グラフだけ穴が空く。どちらもデバッグ用の記録に払う代償として重い。
## そこでデバッグ画面が自分で1つ持ち、`day_advanced` のたびに record() する。
## 本編の挙動（RNG の消費順・セーブ・価格）には一切影響しない。
##
## 記録するのは advance_day() が終わった後の状態なので、「その日の出発・到着」は
## Logistics.last_departed() / last_arrived() から読む（advance_day() の
## 戻り値は GameSession が受け取ってしまっていて、こちらへは来ない）。
##
## 日をまたがずに2度呼ばれても増えない（同じ日は上書きする）。パネルの
## refresh() は移動や取引でも走るため、呼ばれた回数で日数が増えると
## 横軸が実際の経過日数とずれる。

const GameData = preload("res://scripts/systems/game_data.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const Logistics = preload("res://scripts/systems/logistics.gd")

## 保持する日数の上限。本編は60日で終わるが、デバッグ画面は続きからの
## セッションや再開を跨いで生き続けるので、際限なく伸びないよう頭を打つ。
## 超えたら古い日から捨てる（グラフの横軸は残っている範囲だけになる）。
const MAX_DAYS: int = 400

## 記録した日ごとの辞書。並びは day の昇順。各要素のキーは
## day / active / departed / arrived / shortage / delivered / stock。
##   delivered: item_id -> その日に着いた個数
##   stock:     "city_id|item_id" -> その日の在庫（グラフの縦軸に使う）
var _days: Array[Dictionary] = []


## 1日ぶん記録する。同じ日を2度渡したときは上書きする（増やさない）。
func record(day: int, logistics: Logistics, market: MarketTable) -> void:
	var entry: Dictionary = {
		"day": day,
		"active": logistics.active_count(),
		"departed": logistics.last_departed().size(),
		"arrived": logistics.last_arrived().size(),
		"shortage": _count_shortages(market),
		"delivered": _delivered_by_item(logistics),
		"stock": _stock_snapshot(market),
	}

	if not _days.is_empty() and int(_days[_days.size() - 1]["day"]) == day:
		_days[_days.size() - 1] = entry
	else:
		_days.append(entry)

	while _days.size() > MAX_DAYS:
		_days.remove_at(0)


## 記録を捨てる。再プレイでセッションが入れ替わったときに呼ぶ
## （前のプレイの日数が残っていると横軸が繋がって見える）。
func clear() -> void:
	_days.clear()


func day_count() -> int:
	return _days.size()


## 記録の先頭・末尾の日。グラフの横軸の両端に使う。空なら 0。
func first_day() -> int:
	return int(_days[0]["day"]) if not _days.is_empty() else 0


func last_day() -> int:
	return int(_days[_days.size() - 1]["day"]) if not _days.is_empty() else 0


## 最新の記録（空なら空の辞書）。数字の一覧に使う。
func latest() -> Dictionary:
	return _days[_days.size() - 1] if not _days.is_empty() else {}


## 記録の並びから、key の値だけを取り出した系列。グラフへそのまま渡す。
## key は active / departed / arrived / shortage のいずれか。
func series_of(key: String) -> Array[int]:
	var values: Array[int] = []
	for entry: Dictionary in _days:
		values.append(int(entry.get(key, 0)))
	return values


## city_id の item_id の在庫の推移。
func stock_series(city_id: String, item_id: String) -> Array[int]:
	var stock_key: String = "%s|%s" % [city_id, item_id]
	var values: Array[int] = []
	for entry: Dictionary in _days:
		values.append(int((entry["stock"] as Dictionary).get(stock_key, 0)))
	return values


## 直近 days 日で、品目ごとに何個が隊商で運ばれたか。item_id -> 個数。
## days が記録より長ければ、あるだけ集計する。
func delivered_totals(days: int) -> Dictionary:
	var totals: Dictionary = {}
	var start: int = maxi(0, _days.size() - maxi(days, 1))
	for index: int in range(start, _days.size()):
		var delivered: Dictionary = _days[index]["delivered"]
		for item_id: String in delivered:
			totals[item_id] = int(totals.get(item_id, 0)) + int(delivered[item_id])
	return totals


# --- 内部 ---

## 在庫0の「都市×品目」の組の数。**輸入が要る組だけを数える。**
##
## 産地は自分で作るので0にならず、stock_cap が0の組（特産資源で産地から
## 遠すぎる等）はそもそも棚が無いだけで品切れではない。両方を数に入れると
## 母数が動かない下駄になり、線が動いてもどれだけ悪いのか読めない。
## 数え方を変えたら shortage_denominator() も合わせること。
func _count_shortages(market: MarketTable) -> int:
	var count: int = 0
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if not _is_import_pair(city_id, item_id):
				continue
			if market.stock_of(city_id, item_id) <= 0:
				count += 1
	return count


## 品切れ数の母数（輸入が要る「都市×品目」の組の数）。グラフの縦軸の上限と、
## 「153組中いくつ」という表示に使う。市場の状態には依存しないので静的。
static func shortage_denominator() -> int:
	var count: int = 0
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if _is_import_pair(city_id, item_id):
				count += 1
	return count


## その「都市×品目」は輸入で賄う組か。自前で作れる組と、棚が無い組を外す。
static func _is_import_pair(city_id: String, item_id: String) -> bool:
	if MarketTable.production_of(city_id, item_id) > 0:
		return false
	if MarketTable.stock_cap(city_id, item_id) <= 0:
		return false
	return MarketTable.has_producer(item_id)


func _delivered_by_item(logistics: Logistics) -> Dictionary:
	var delivered: Dictionary = {}
	for convoy: Dictionary in logistics.last_arrived():
		var item_id: String = convoy["item"]
		delivered[item_id] = int(delivered.get(item_id, 0)) + int(convoy["count"])
	return delivered


func _stock_snapshot(market: MarketTable) -> Dictionary:
	var snapshot: Dictionary = {}
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			snapshot["%s|%s" % [city_id, item_id]] = market.stock_of(city_id, item_id)
	return snapshot
