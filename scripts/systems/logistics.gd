extends RefCounted
## 都市間の物流。生産地で積み込み、街道を何日かかけて運び、消費地で降ろす。
##
## これが入る前は、どの都市も全品目を毎日わずかずつ「生産」しており
## （PRODUCTION_OTHER_RESOURCE / PRODUCTION_OTHER_EQUIPMENT）、
## 木材が採れないはずの都市にも木材が毎日わいていた。物流を入れた今は
## **在庫が自然に増えるのは生産地だけ**で、それ以外の都市の在庫は隊商が
## 運んできた分しかない（GameData.PRODUCTION_OTHER_* は 0）。
##
## **物流は隊商1層だけでできている。品物は必ずどこかの産地から運ばれる。**
##
## 以前はここに「交易路（_supply_routes）」という2層目があり、産地の在庫を
## **減らさずに**消費地へ毎日補充していた。全都市の棚を成立させるにはそれが
## 手軽だったが、品物が湧いて出るため物流のシミュレーションとして成立して
## いなかった（消費地の在庫が産地と無関係に増え続ける）。2026-08-17 に廃止し、
## **質量保存**——降ろした数は必ずどこかの産地から引かれている——を不変条件に
## した。この原則は `_advance_convoys()` と `_launch()` の対で保たれている。
##
## 廃止にあたって実測し直した所、以前の「隊商だけでは賄えない」という判断は
## 前提が誤っていた。交易路が押し込んでいた 600個/日 は
## `consumption × SUPPLY_RATE` であって**実際の消費ではない**。
##
## そして測っている最中に、交易路が隠していた**本当の問題**が出た。装備は
## 1品目につき産地が1都市（bonus）しかなく生産は 9個/日 だが、消費は全都市
## ぶん積み上がって 31個/日 あった。**物流では埋めようのない赤字**で、
## 交易路はその差を毎日湧かせていた。GameData の CONSUMPTION_EQUIPMENT を
## 5→2、CAERLEON_EQUIPMENT を 14→5 に下げて生産と釣り合わせてある
## （その経緯は game_data.gd の該当箇所に書いた）。
##
## 釣り合わせた後の実測は、世界の消費 88個/日 に対し産地の生産 892個/日。
## 輸送の回転（平均2.13ホップ × DAYS_PER_HOP=2 = 1本あたり4.27日の拘束）を
## 織り込んでも、リトルの法則で必要な同時走行は約12本。地図に出せる数に
## 十分収まる。
##
## 数字を触るときは必ず**品目ごとに**生産と消費を突き合わせること。合計で
## 見ると資源の余剰（+820個/日）に装備の赤字が埋もれて素通りする
## （scenario_m28.gd の「装備の収支」がこれを検査している）。
##
## 消費地は自分では1個も作らない。**産地から隊商が来なければ品切れる**——
## これは不具合ではなく、物流が実際に効いていることの現れ。
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

## 1日に新しく仕立てる隊商の最大数。
##
## **供給の総量はもうこれと積載だけで決まる**（交易路が無いので、ここを
## 絞ると本当に品物が届かなくなる）。世界が1日に食い潰す 88個 を平均積載
## （約9個）で割ると約10本/日。買い占めた分を取り戻す余地を見て倍を取る。
const MAX_DEPARTURES_PER_DAY: int = 20

## 同時に街道を走れる隊商の総数。地図に出る荷車の数の上限でもある
## （描画の重さと、画面の読みやすさの両方をここで抑える）。
##
## 必要量から逆算すると「出発20本/日 × 拘束4.27日 ≒ 85本」だが、実際には
## 行き先が尽きて（_needs() が満杯の都市を外す）そこまで溜まらない。
## 地図の読みやすさを優先して 30 で頭を打つ。**下げるときは供給が落ちる**。
const MAX_ACTIVE_CONVOYS: int = 30

## 隊商1本が積む個数の下限・上限。産地の在庫からこの数だけ引いて運ぶ。
##
## **交易路を廃止したぶん、ここが供給の主役になった。** 積載 × 出発本数 が
## 1日の総供給になる。
##
## 消費 88個/日 を平均4.27日の拘束で運ぶには、リトルの法則で
## 「積載 × 同時走行数 ≧ 88 × 4.27 ≒ 376」が要る。同時走行を地図の
## 読みやすさから 30本 に抑えるので、平均積載は 13個 以上が要る。
##
## 積載は送り先の空き（_launch()）で頭打ちになるため、上限を大きくしても
## 溢れはしない。装備の輸入枠は 2×3=6個 と小さく実際にはそこで切られるが、
## 資源側（消費8×3=24個）はこの上限まで積める。上限はその両方を賄う値。
const CONVOY_LOAD_MIN: int = 8
const CONVOY_LOAD_MAX: int = 22

## 産地の在庫がこの割合を下回っていたら送り出さない。産地自身が品切れに
## なるまで搾り取ると、プレイヤーが産地へ着いたときに何も買えなくなる。
##
## **質量保存を入れて実際に効くようになった線。** 以前は交易路が産地の在庫を
## 減らさなかったため、産地はほぼ常に満杯でこの判定はめったに効かなかった。
## 今は隊商が積んだ分だけ本当に減るので、ここが産地の棚を守る唯一の砦になる。
## 上げすぎると送り出せる余地が消えて消費地が痩せる。
const DEPARTURE_STOCK_FLOOR: float = 0.35

## 送り先の在庫がこの割合を超えていたら隊商を出さない（もう足りている）。
## 上限に張り付いた都市へ運び続けても捨てるだけで、荷車だけが無駄に走る。
##
## 1.0 未満にしておくこと。1.0 にすると満杯の都市へも送り続け、到着時に
## receive_stock() が上限で切り捨てて**積んだ荷が消える＝質量保存が破れる**。
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

## 到着した荷のうち、在庫の上限で切り捨てられて消えた個数の累計。
##
## **0 であるべき値。** 質量保存は「積んだ数 = 降ろした数」で成り立っており、
## receive_stock() が stock_cap で頭打ちにすると産地から引かれた荷が
## どこにも現れずに消える。送り出す側（_launch）が送り先の空きに積載を
## 合わせているので正しく動いていれば増えないが、**溢れているかどうかは
## 在庫を外から見ても分からない**（減ったのか元々無かったのか区別できない）
## ため、起きた場所で数えておく。scenario_m31 がこれを検査する。
var spilled_total: int = 0

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


## 走行中の隊商を1日進め、着いたものを在庫に加えて取り除く。
##
## **質量保存の降ろす側。** 積む側（_launch）が産地から引いた数と、ここで
## 降ろす数は必ず等しい。`receive_stock()` は stock_cap で頭打ちになるため、
## 溢れると荷が消えて保存が破れる。それを避けるのは送り出す側の責務で、
## _needs() が ARRIVAL_STOCK_CEILING で満杯の都市を候補から外し、
## _launch() が送り先の空きに積載を合わせている。
func _advance_convoys(market: MarketTable) -> Array[Dictionary]:
	var arrived: Array[Dictionary] = []
	var still_running: Array[Dictionary] = []
	for convoy: Dictionary in convoys:
		convoy["days_left"] = convoy["days_left"] - 1
		if convoy["days_left"] > 0:
			still_running.append(convoy)
			continue
		# 降ろす前後の在庫の差が、実際に棚へ乗った数。積んできた数との
		# 差が「消えた分」になる（spilled_total のコメント参照）。
		var before: int = market.stock_of(convoy["to"], convoy["item"])
		market.receive_stock(convoy["to"], convoy["item"], convoy["count"])
		var landed: int = market.stock_of(convoy["to"], convoy["item"]) - before
		spilled_total += maxi(0, int(convoy["count"]) - landed)
		arrived.append(convoy)
	convoys = still_running
	return arrived


## その日の新しい隊商を決める。
##
## 「足りていない都市」と「余っている産地」を突き合わせ、成立する組から
## MAX_DEPARTURES_PER_DAY 本まで送り出す。候補の並びは決定的（都市・品目とも
## GameData の宣言順）で、そこから RNG で選ぶ。順序に乱数が混ざると、
## 同じシードでも展開が変わる。
##
## **選ぶ前に、棚の薄い順へ並べ替える。** 交易路が背景で全都市を埋めていた
## 頃は、隊商がどこへ行こうと在庫は成立したので純粋な乱択でよかった。今は
## 隊商が唯一の供給路なので、乱択だと満杯に近い都市へ枠を使い、空の都市が
## 何日も空のまま残る。同じ薄さの候補どうしの選択には従来どおり RNG を使い、
## 1本につき2回消費する形（行き先と積載）も変えていない
## （architecture.md の RNG 消費順）。
## 戻り値はその日に送り出した隊商（統計が本数を読む）。
func _dispatch(market: MarketTable) -> Array[Dictionary]:
	var launched: Array[Dictionary] = []
	if convoys.size() >= tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS):
		return launched

	var candidates: Array[Dictionary] = _find_candidates(market)
	if candidates.is_empty():
		return launched

	# 薄い順（stock_ratio の昇順）。同率は元の宣言順のまま残るよう
	# 安定な比較にする（< だけを見て入れ替えない）。
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["urgency"]) < float(b["urgency"]))

	var departures: int = mini(tuning.int_of(LogisticsTuning.MAX_DEPARTURES_PER_DAY),
		tuning.int_of(LogisticsTuning.MAX_ACTIVE_CONVOYS) - convoys.size())
	for i: int in departures:
		if candidates.is_empty():
			return launched
		# 最も薄い組のうちから選ぶ。同じ行き先・品目の候補は産地違いで
		# 複数並ぶので、そこは RNG に委ねる（どの産地から来るかは絵の問題）。
		var tied: int = _count_tied_front(candidates)
		var pick: int = _rng.randi_range(0, tied - 1)
		var candidate: Dictionary = candidates[pick]
		candidates.remove_at(pick)
		var convoy: Dictionary = _launch(market, candidate)
		if not convoy.is_empty():
			launched.append(convoy)
			# 送り出した組は在庫が動くので、同じ行き先・品目の残り候補
			# （産地違い）を落とす。_is_inbound() は次の日まで効かない。
			_drop_same_target(candidates, candidate)
	return launched


## 先頭と同じ薄さの候補が何件並んでいるか。最低1件。
func _count_tied_front(candidates: Array[Dictionary]) -> int:
	var front: float = float(candidates[0]["urgency"])
	var count: int = 0
	for candidate: Dictionary in candidates:
		if not is_equal_approx(float(candidate["urgency"]), front):
			break
		count += 1
	return maxi(1, count)


## 同じ「行き先 × 品目」の候補を候補列から取り除く。
func _drop_same_target(candidates: Array[Dictionary], sent: Dictionary) -> void:
	for index: int in range(candidates.size() - 1, -1, -1):
		if candidates[index]["to"] == sent["to"] \
				and candidates[index]["item"] == sent["item"]:
			candidates.remove_at(index)


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
			# 薄さは行き先の在庫だけで決まる（産地違いの候補で同じ値になる）。
			# _dispatch() がこれで並べ替えて、空の都市から先に埋める。
			var urgency: float = market.stock_ratio(to_city, item_id)
			for from_city: String in GameData.CITIES:
				if from_city == to_city:
					continue
				if not _can_supply(market, from_city, item_id):
					continue
				candidates.append({
					"from": from_city, "to": to_city, "item": item_id,
					"urgency": urgency,
				})
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

	# 送り先の空きを超えて積まないこと。**質量保存はここで守られる。**
	# 超えて積むと到着時に receive_stock() が stock_cap で切り捨て、
	# 産地から引かれた荷が到着先に乗らずに消える（積載を大きくしたぶん、
	# 旧来の4〜10では滅多に起きなかったこの溢れが現実的な頻度で起きる）。
	# 走行中の同一行き先・同一品目は _is_inbound() が既に弾いているので、
	# 今の在庫だけを見れば足りる。
	var room: int = maxi(0, market.stock_cap(to_city, item_id)
		- market.stock_of(to_city, item_id))
	var load: int = mini(mini(wanted, spare), room)
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
