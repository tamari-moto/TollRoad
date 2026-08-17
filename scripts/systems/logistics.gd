extends RefCounted
## 都市間の物流。生産地で積み込み、街道を何日かかけて運び、消費地で降ろす。
##
## これが入る前は、どの都市も全品目を毎日わずかずつ「生産」しており
## （PRODUCTION_OTHER_RESOURCE / PRODUCTION_OTHER_EQUIPMENT）、
## 木材が採れないはずの都市にも木材が毎日わいていた。物流を入れた今は
## **在庫が自然に増えるのは生産地だけ**で、それ以外の都市の在庫は隊商が
## 運んできた分しかない（GameData.PRODUCTION_OTHER_* は 0）。
##
## 物流は**2層**でできている。理由は実測に基づく:
##
## 輸入が要る「都市×品目」の組は153あり、1日に必要な総量は563個ある。
## これを隊商1本ずつ（平均7個）で賄うには1日80本の出発が要り、地図は
## 荷車で埋まる。逆に本数を絵として妥当な範囲（数本）に抑えると供給は
## 21個/日にしかならず、40日で153組中145組が品切れになった（実測）。
##
## そこで、
##
## 1. **交易路（_supply_routes）** — 産地から消費地へ毎日流れる定常の
##    補充。全都市の在庫を成立させるのはこちらの役目で、地図には出ない。
## 2. **隊商（convoys）** — その流れを目に見える形で抜き出したもの。
##    数を絞ってあり、街道を進む荷車として地図に描かれる。着荷は
##    在庫にも乗る（見えている荷車が嘘でないように）。
##
## 「在庫が増えるのは生産地のみ」という原則はどちらの層でも守られている。
## 消費地は自分では1個も作らず、産地から来た分しか増えない。
##
## 地図上の見た目（荷車のメッシュ）は map_view_3d.gd が progress() を
## 読んで描くだけで、ここは描画を一切知らない（GameSession と同じ方針。
## --script から駆動できる）。
##
## 経路は GameData.ROYAL_ROAD_EDGES 上の最短ホップ。所要日数はホップ数と
## 等しく、途中の都市には降ろさない（通過するだけ）。中継で降ろす形にすると
## 「どの都市の在庫がどの隊商由来か」が追えなくなるため、産地→消費地の
## 1本を単位にしてある。

const GameData = preload("res://scripts/systems/game_data.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const LogisticsTuning = preload("res://scripts/systems/logistics_tuning.gd")

## 以下の const は**既定値**であり、実行中に読むのは `tuning` を通した値。
## デバッグ画面（logistics_debug_panel.gd）から一時的に上書きできるように
## してあるが、上書きが無ければ必ずこの値になる。**const 自体は
## 20〜30回の通しプレイで決めた実測値なので書き換えないこと**
## （docs/rules/balance.md）。仕組みは logistics_tuning.gd 参照。

## 1日に新しく仕立てる隊商の最大数。地図に出る荷車の増え方を決める。
## 供給の総量はこれではなく交易路（_supply_routes）が持つので、ここは
## 「絵としてちょうどよい数」で決めてよい。
const MAX_DEPARTURES_PER_DAY: int = 3

## 同時に街道を走れる隊商の総数。地図に出る荷車の数の上限でもある
## （描画の重さと、画面の読みやすさの両方をここで抑える）。
const MAX_ACTIVE_CONVOYS: int = 12

## 隊商1本が積む個数。産地の在庫からこの数だけ引いて運ぶ。
## 消費地の需要（demand_cap）に対して大きすぎると一度で満たしてしまい、
## 隊商が来る前と後で市場が別物になる。数日ぶんの消費量に収まる大きさにする。
const CONVOY_LOAD_MIN: int = 4
const CONVOY_LOAD_MAX: int = 10

## 交易路が1日に運ぶ量の、消費量に対する倍率。
##
## 1.0 だと消費と釣り合ってちょうど回るが、プレイヤーが買い占めた分を
## 取り戻せない（棚が薄いまま固定される）。1 より少し大きくして、
## 買われた後も数日で戻るようにする。上げすぎると常に満杯になり、
## 在庫という概念自体が効かなくなる。
const SUPPLY_RATE: float = 1.35

## 交易路の補充が届く在庫の上限（stock_cap に対する割合）。
## 定常の流れだけで満杯にはしない。満杯まで積むと隊商の着荷が
## 一切在庫に乗らなくなり（上限で切られる）、地図の荷車が嘘になる。
const SUPPLY_CEILING: float = 0.82

## 産地の在庫がこの割合を下回っていたら送り出さない。産地自身が品切れに
## なるまで搾り取ると、プレイヤーが産地へ着いたときに何も買えなくなる。
const DEPARTURE_STOCK_FLOOR: float = 0.45

## 送り先の在庫がこの割合を超えていたら隊商を出さない（もう足りている）。
## 上限に張り付いた都市へ運び続けても捨てるだけで、荷車だけが無駄に走る。
##
## 交易路の上限（SUPPLY_CEILING）より**高く**しておくこと。低くすると
## 定常の補充だけで常にこの線を超え、隊商が一度も出ない＝地図から荷車が
## 消える（実測でそうなった）。プレイヤーが買った直後や、消費が込み合って
## 棚が薄くなった都市に対して隊商が出る、という関係になる。
const ARRIVAL_STOCK_CEILING: float = 0.95

## 1区間（王道1ホップ）にかかる日数。
##
## **1 にしないこと。** 1 だと隊商の残り日数が常に区間の境目に一致し、
## leg_at() の t が必ず 0.0 になる（実測: 全ての荷車が t=0.00）。荷車が
## 都市の真上にしか現れず、街道の途中に居る絵が一度も出ない。
## プレイヤーの移動（MOVE_ADJACENT_DAYS = 1）より遅いのは、隊商は
## 積み降ろしを挟む重い輸送だという扱い（プレイヤーの方が身軽で速い）。
const DAYS_PER_HOP: int = 2

## 走行中の隊商。各要素は _make_convoy() が作る辞書で、キーは
## from / to / item / count / total_days / days_left / path。
## path は経由する都市IDの並び（from で始まり to で終わる）。
var convoys: Array[Dictionary] = []

## 生成のたびに増える通し番号。地図側が荷車のノードを隊商と対応付けるのに使う
## （配列の添字は到着で詰められるので識別子にできない）。
var _next_id: int = 1

## 上の const を実行中だけ上書きする層（logistics_tuning.gd）。
## 上書きが無ければ const の値をそのまま返すので、既定の挙動は変わらない。
var tuning: LogisticsTuning

## 直近の advance_day() で到着した隊商と、その日に送り出した隊商。
## 統計（logistics_stats.gd）が「その日に何本着いて何本出たか」を読む。
## advance_day() のたびに丸ごと入れ替わるので、次の日を送る前に読むこと。
var _last_arrived: Array[Dictionary] = []
var _last_departed: Array[Dictionary] = []

var _rng: RandomNumberGenerator


## RNG は GameSession から参照で受け取る（自前で作らない）。
## シードを固定したときに物流まで含めて再現できるようにするため。
func _init(rng: RandomNumberGenerator) -> void:
	_rng = rng
	tuning = LogisticsTuning.new(default_tuning())


## 上書き層へ渡す既定値。**const と上書き層をつなぐ唯一の場所。**
##
## 既定値を logistics_tuning.gd 側に書くと同じ数値が2箇所に増え、片方だけ
## 直したときに黙ってズレる。const を持つこちらが名前と値の対応を作る。
static func default_tuning() -> Dictionary:
	return {
		LogisticsTuning.MAX_DEPARTURES_PER_DAY: float(MAX_DEPARTURES_PER_DAY),
		LogisticsTuning.MAX_ACTIVE_CONVOYS: float(MAX_ACTIVE_CONVOYS),
		LogisticsTuning.CONVOY_LOAD_MIN: float(CONVOY_LOAD_MIN),
		LogisticsTuning.CONVOY_LOAD_MAX: float(CONVOY_LOAD_MAX),
		LogisticsTuning.SUPPLY_RATE: SUPPLY_RATE,
		LogisticsTuning.SUPPLY_CEILING: SUPPLY_CEILING,
		LogisticsTuning.DEPARTURE_STOCK_FLOOR: DEPARTURE_STOCK_FLOOR,
		LogisticsTuning.ARRIVAL_STOCK_CEILING: ARRIVAL_STOCK_CEILING,
		LogisticsTuning.DAYS_PER_HOP: float(DAYS_PER_HOP),
	}


# --- 参照 ---

## 走行中の隊商の本数。
func active_count() -> int:
	return convoys.size()


## index 番目の隊商の進み具合（0.0=出発時、1.0=到着時）。
## 地図の荷車はこれを都市間の位置に写して描く。
##
## 到着の当日（days_left=0）は 1.0 になるが、その隊商は _advance_day() の
## 中で取り除かれるので、地図に 1.0 の荷車が残り続けることはない。
func progress(index: int) -> float:
	if index < 0 or index >= convoys.size():
		return 0.0
	var convoy: Dictionary = convoys[index]
	var total: int = convoy["total_days"]
	if total <= 0:
		return 1.0
	return clampf(float(total - convoy["days_left"]) / float(total), 0.0, 1.0)


## index 番目の隊商が運んでいる品目ID。地図の荷車の色に使う。
func item_of(index: int) -> String:
	if index < 0 or index >= convoys.size():
		return ""
	return convoys[index]["item"]


## index 番目の隊商の出発地・目的地。
func from_of(index: int) -> String:
	if index < 0 or index >= convoys.size():
		return ""
	return convoys[index]["from"]


func to_of(index: int) -> String:
	if index < 0 or index >= convoys.size():
		return ""
	return convoys[index]["to"]


## index 番目の隊商が運んでいる個数。
func count_of(index: int) -> int:
	if index < 0 or index >= convoys.size():
		return 0
	return convoys[index]["count"]


## index 番目の隊商の通し番号。地図側がノードとの対応付けに使う。
func id_of(index: int) -> int:
	if index < 0 or index >= convoys.size():
		return 0
	return convoys[index]["id"]


## index 番目の隊商が今いる区間（path 上の何本目の辺か）と、その辺の中での
## 進み具合を返す。地図は都市を直線で結んだ街道の上に荷車を置くため、
## 全体の progress() ではなく「今どの辺にいるか」が要る。
##
## 戻りは {"from": String, "to": String, "t": float}。
func leg_at(index: int) -> Dictionary:
	if index < 0 or index >= convoys.size():
		return {"from": "", "to": "", "t": 0.0}
	var path: Array = convoys[index]["path"]
	if path.size() < 2:
		return {"from": "", "to": "", "t": 0.0}
	var legs: int = path.size() - 1
	var overall: float = progress(index) * float(legs)
	var leg_index: int = clampi(int(floor(overall)), 0, legs - 1)
	return {
		"from": path[leg_index],
		"to": path[leg_index + 1],
		"t": clampf(overall - float(leg_index), 0.0, 1.0),
	}


# --- 経路 ---

## 王道上の最短ホップ経路（BFS）。city_id の並びで返し、到達できなければ空。
##
## レイヴンスパイアは王道につながらないので、黒ゾーンのゲート
## （GameData.BLACK_ZONE_GATES）経由の辺を足して扱う。隊商もプレイヤーと
## 同じ道しか通れないようにするため、ここで道の定義を勝手に増やさないこと。
static func route_between(from_city: String, to_city: String) -> Array[String]:
	if from_city == to_city:
		return []
	var previous: Dictionary = {from_city: ""}
	var queue: Array[String] = [from_city]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if current == to_city:
			break
		for neighbor: String in _neighbors_of(current):
			if previous.has(neighbor):
				continue
			previous[neighbor] = current
			queue.append(neighbor)

	if not previous.has(to_city):
		return []
	var path: Array[String] = []
	var node: String = to_city
	while node != "":
		path.push_front(node)
		node = previous[node]
	return path


## 隊商が通れる道でつながる都市。王道に加えて黒ゾーンのゲートを含む。
static func _neighbors_of(city_id: String) -> Array[String]:
	var neighbors: Array[String] = GameData.road_neighbors(city_id)
	if city_id == GameData.CAERLEON:
		for gate: String in GameData.BLACK_ZONE_GATES:
			if not neighbors.has(gate):
				neighbors.append(gate)
	elif city_id in GameData.BLACK_ZONE_GATES:
		if not neighbors.has(GameData.CAERLEON):
			neighbors.append(GameData.CAERLEON)
	return neighbors


# --- 1日の進行 ---

## 1日ぶん隊商を進め、着いたものを降ろし、新しい隊商を仕立てる。
##
## 順序が要る。**先に到着を処理してから出発を決める**こと。逆にすると、
## その日に着いたばかりの荷物が在庫に乗る前に「まだ足りない」と判定され、
## 同じ都市へ二重に隊商が出る。
##
## 戻り値は今日到着した隊商の配列（GameSession が日誌に出すのに使う）。
func advance_day(market: MarketTable) -> Array[Dictionary]:
	var arrived: Array[Dictionary] = _advance_convoys(market)
	# 定常の交易路。全都市の在庫を成立させるのはこちら（冒頭のコメント参照）。
	# 隊商の着荷を先に乗せてから流すので、隊商が着いた都市はその分だけ
	# 交易路の補充が要らなくなる（二重に積まない）。
	_supply_routes(market)
	_last_departed = _dispatch(market)
	_last_arrived = arrived
	return arrived


## 直近の1日で到着した隊商（advance_day() の戻り値と同じ中身）。
## 戻り値を取り損ねた側（統計）が後から読めるように残してある。
func last_arrived() -> Array[Dictionary]:
	return _last_arrived


## 直近の1日で送り出した隊商。
func last_departed() -> Array[Dictionary]:
	return _last_departed


## 産地から消費地への定常の補充。地図には出ない。
##
## 「どの産地から来たか」は在庫には残らない（在庫は個数でしかない）ため、
## ここでは産地を1つ選ぶ処理はせず、**その品目を作っている都市がどこかに
## あるか**だけを見て流す。産地を選ぶのは隊商（_dispatch）の役目で、
## そちらは地図に出るので出発地に意味がある。
##
## 産地の在庫は減らさない。減らすと、地図に出ない流れが産地の棚を
## 空にしてしまい、プレイヤーが産地へ着いたときに何も買えなくなる
## （そして理由が画面のどこにも出ない）。交易路は「王国の外から
## 補充される背景の流れ」として扱う。
func _supply_routes(market: MarketTable) -> void:
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if MarketTable.production_of(city_id, item_id) > 0:
				continue
			if not MarketTable.has_producer(item_id):
				continue
			var capacity: int = market.stock_cap(city_id, item_id)
			if capacity <= 0:
				continue
			var ceiling: int = int(float(capacity) * tuning.value_of(LogisticsTuning.SUPPLY_CEILING))
			if market.stock_of(city_id, item_id) >= ceiling:
				continue
			var amount: int = maxi(1, int(round(
				float(MarketTable.consumption_of(city_id, item_id))
					* tuning.value_of(LogisticsTuning.SUPPLY_RATE))))
			var room: int = ceiling - market.stock_of(city_id, item_id)
			market.receive_stock(city_id, item_id, mini(amount, room))


## 走行中の隊商を1日進め、着いたものを在庫に加えて取り除く。
func _advance_convoys(market: MarketTable) -> Array[Dictionary]:
	var arrived: Array[Dictionary] = []
	var still_running: Array[Dictionary] = []
	for convoy: Dictionary in convoys:
		convoy["days_left"] = convoy["days_left"] - 1
		if convoy["days_left"] > 0:
			still_running.append(convoy)
			continue
		# 着いた分だけ在庫に積む。上限（stock_cap）は MarketTable が抑える。
		market.receive_stock(convoy["to"], convoy["item"], convoy["count"])
		arrived.append(convoy)
	convoys = still_running
	return arrived


## その日の新しい隊商を決める。
##
## 「足りていない都市」と「余っている産地」を突き合わせ、成立する組から
## MAX_DEPARTURES_PER_DAY 本まで送り出す。候補の並びは決定的（都市・品目とも
## GameData の宣言順）で、そこから RNG で選ぶ。順序に乱数が混ざると、
## 同じシードでも展開が変わる。
## 戻り値はその日に送り出した隊商（統計が本数を読む）。
func _dispatch(market: MarketTable) -> Array[Dictionary]:
	var launched: Array[Dictionary] = []
	if convoys.size() >= tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS):
		return launched

	var candidates: Array[Dictionary] = _find_candidates(market)
	if candidates.is_empty():
		return launched

	var departures: int = mini(tuning.int_of(LogisticsTuning.MAX_DEPARTURES_PER_DAY),
		tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS) - convoys.size())
	for i: int in departures:
		if candidates.is_empty():
			return launched
		var pick: int = _rng.randi_range(0, candidates.size() - 1)
		var candidate: Dictionary = candidates[pick]
		candidates.remove_at(pick)
		var convoy: Dictionary = _launch(market, candidate)
		if not convoy.is_empty():
			launched.append(convoy)
	return launched


## 成立する「産地 → 不足している都市」の組を全て挙げる。
##
## 同じ品目・同じ目的地の隊商が既に走っていれば挙げない。走行中の分を
## 数えないと、着くまでの数日間ずっと「足りない」と見えて隊商が
## 何本も重なり、着いた瞬間に在庫が上限へ跳ね上がる。
func _find_candidates(market: MarketTable) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for to_city: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if not _needs(market, to_city, item_id):
				continue
			if _is_inbound(to_city, item_id):
				continue
			for from_city: String in GameData.CITIES:
				if from_city == to_city:
					continue
				if not _can_supply(market, from_city, item_id):
					continue
				candidates.append({"from": from_city, "to": to_city, "item": item_id})
	return candidates


## その都市がその品目を欲しがっているか。
## 自前で作れるもの（産地）は運ばれてこない。レアは誰も生産しないので対象外。
##
## stock_cap が0（特産資源で産地から遠すぎる、など）なら demand_cap の大小に
## 関わらず運ばない。受け入れ側の棚が無い都市へ送ると、到着時に
## receive_stock() が容量0で切り捨て、産地の在庫だけ無駄に減って荷が消える
## （幽霊隊商になる）ため。
func _needs(market: MarketTable, city_id: String, item_id: String) -> bool:
	if MarketTable.production_of(city_id, item_id) > 0:
		return false
	if market.stock_cap(city_id, item_id) <= 0:
		return false
	return market.stock_ratio(city_id, item_id) \
		< tuning.value_of(LogisticsTuning.ARRIVAL_STOCK_CEILING)


## その都市がその品目を送り出せるか。産地であり、かつ自分の在庫に余裕がある。
func _can_supply(market: MarketTable, city_id: String, item_id: String) -> bool:
	if MarketTable.production_of(city_id, item_id) <= 0:
		return false
	return market.stock_ratio(city_id, item_id) \
		>= tuning.value_of(LogisticsTuning.DEPARTURE_STOCK_FLOOR)


## その品目を積んだ隊商が、その都市へ既に向かっているか。
func _is_inbound(to_city: String, item_id: String) -> bool:
	for convoy: Dictionary in convoys:
		if convoy["to"] == to_city and convoy["item"] == item_id:
			return true
	return false


## 隊商を1本仕立て、産地の在庫を減らして走らせる。
## 送り出せなければ空の辞書を返す（経路が無い・積む在庫が無い）。
func _launch(market: MarketTable, candidate: Dictionary) -> Dictionary:
	var from_city: String = candidate["from"]
	var to_city: String = candidate["to"]
	var item_id: String = candidate["item"]

	var path: Array[String] = route_between(from_city, to_city)
	if path.size() < 2:
		return {}

	# 積める分だけ積む。産地の在庫を DEPARTURE_STOCK_FLOOR より下へは
	# 削らない（産地へ来たプレイヤーが買えなくなるのを避ける）。
	var floor_stock: int = int(float(market.stock_cap(from_city, item_id))
		* tuning.value_of(LogisticsTuning.DEPARTURE_STOCK_FLOOR))
	var spare: int = maxi(0, market.stock_of(from_city, item_id) - floor_stock)
	# 上書き層から下限＞上限で入りうる（logistics_tuning.gd は組み合わせを
	# 弾かず警告するだけ）。randi_range() は逆順を渡すとエラーになるので、
	# ここで上限側へ寄せて潰す。
	var load_max: int = tuning.int_of(LogisticsTuning.CONVOY_LOAD_MAX)
	var load_min: int = mini(tuning.int_of(LogisticsTuning.CONVOY_LOAD_MIN), load_max)
	var wanted: int = _rng.randi_range(load_min, load_max)
	var load: int = mini(wanted, spare)
	if load <= 0:
		return {}

	market.consume_stock(from_city, item_id, load)
	var convoy: Dictionary = _make_convoy(from_city, to_city, item_id, load, path)
	convoys.append(convoy)
	return convoy


## 隊商1本ぶんの辞書を組む。日数は経路のホップ数で決まる。
func _make_convoy(from_city: String, to_city: String, item_id: String,
		count: int, path: Array[String]) -> Dictionary:
	var days: int = maxi(1, (path.size() - 1) * tuning.int_of(LogisticsTuning.DAYS_PER_HOP))
	var convoy: Dictionary = {
		"id": _next_id,
		"from": from_city,
		"to": to_city,
		"item": item_id,
		"count": count,
		"total_days": days,
		"days_left": days,
		"path": path,
	}
	_next_id += 1
	return convoy


# --- 保存と復元 ---

## 走行中の隊商をそのまま辞書で返す。
func to_dict() -> Dictionary:
	var saved: Array = []
	for convoy: Dictionary in convoys:
		saved.append(convoy.duplicate(true))
	return {"convoys": saved, "next_id": _next_id}


## 保存された隊商を戻す。
##
## 今の GameData と噛み合わない隊商（消えた都市・品目を指しているもの）は
## **その1本だけ捨てる**。market_table.gd が全体を作り直すのと方針が違うのは、
## 隊商は互いに独立で、1本欠けても残りが成立するため（在庫は都市×品目が
## 揃って初めて意味を持つので全体を作り直す必要がある）。
##
## JSON.parse_string() は数値を float で返すため、必ず int() を通すこと。
func from_dict(data: Dictionary) -> void:
	convoys.clear()
	# 「直近の1日」は復元したセーブには存在しない（何日目から続けるにせよ、
	# その日の出発・到着はまだ起きていない）。前のプレイの分が残ると
	# 統計の初日だけ嘘の本数が乗る。
	_last_arrived.clear()
	_last_departed.clear()
	_next_id = maxi(1, int(data.get("next_id", 1)))

	var source: Variant = data.get("convoys", [])
	if not (source is Array):
		return
	for entry: Variant in source:
		var convoy: Dictionary = _restore_one(entry)
		if not convoy.is_empty():
			convoys.append(convoy)


## 隊商1本を復元する。壊れていれば空の辞書を返す。
func _restore_one(entry: Variant) -> Dictionary:
	if not (entry is Dictionary):
		return {}
	var from_city: String = str(entry.get("from", ""))
	var to_city: String = str(entry.get("to", ""))
	var item_id: String = str(entry.get("item", ""))
	if not GameData.CITIES.has(from_city) or not GameData.CITIES.has(to_city):
		return {}
	if not GameData.ITEMS.has(item_id):
		return {}

	# 経路は保存された値を信じず引き直す。道の定義（ROYAL_ROAD_EDGES）が
	# 変わっていると、保存時の経路は今は存在しない辺を通っていることがある。
	var path: Array[String] = route_between(from_city, to_city)
	if path.size() < 2:
		return {}

	var total: int = maxi(1, (path.size() - 1) * tuning.int_of(LogisticsTuning.DAYS_PER_HOP))
	var left: int = clampi(int(entry.get("days_left", total)), 1, total)
	var count: int = maxi(0, int(entry.get("count", 0)))
	if count <= 0:
		return {}

	var id: int = maxi(0, int(entry.get("id", 0)))
	if id <= 0:
		id = _next_id
		_next_id += 1
	return {
		"id": id,
		"from": from_city,
		"to": to_city,
		"item": item_id,
		"count": count,
		"total_days": total,
		"days_left": left,
		"path": path,
	}
