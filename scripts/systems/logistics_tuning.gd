extends RefCounted
## 物流（logistics.gd）の定数を、実行中だけ上書きする層。
##
## logistics.gd の const は 20〜30 回の通しプレイで決めた実測値であり、
## **書き換えないこと**（docs/rules/balance.md）。とはいえ「この値を上げたら
## 荷車はどう増えるのか」はコードを読んでも分からず、値を変えて回してみるのが
## 一番速い。そこで const は既定値として残したまま、その上に上書きを重ねる形に
## してある。上書きを消せば必ず const の値へ戻るので、いじった状態のまま忘れて
## 「既定値がどれだったか分からなくなる」ことがない。
##
## **既定値をこのファイルに書かないこと。** 書くと同じ数値が logistics.gd と
## 2箇所に増え、片方だけ直したときに黙ってズレる（そしてズレても動くので
## 気づけない）。既定値は `Logistics.default_tuning()` が const から組んで
## `_init()` へ渡す。この層が自前で持つのは「上書きされているか」だけ。
##
## 値の意味と、なぜその値なのかは logistics.gd の各 const のコメントにある。
## ここが持つのは調整に要る範囲（下限・上限・刻み）と表示名だけ。
##
## セーブには入れない。デバッグの都合で一時的に触るものであって、
## 続きから始めたときに前回いじった値が残っていると、なぜ挙動が違うのか
## 画面のどこにも出ない。

## 上書きできる項目のキー。logistics.gd の const 名をスネークケースにしたもの。
const MAX_DEPARTURES_PER_DAY: String = "max_departures_per_day"
const MAX_ACTIVE_CONVOYS: String = "max_active_convoys"
const CONVOY_LOAD_MIN: String = "convoy_load_min"
const CONVOY_LOAD_MAX: String = "convoy_load_max"
const SUPPLY_RATE: String = "supply_rate"
const SUPPLY_CEILING: String = "supply_ceiling"
const DEPARTURE_STOCK_FLOOR: String = "departure_stock_floor"
const ARRIVAL_STOCK_CEILING: String = "arrival_stock_ceiling"
const DAYS_PER_HOP: String = "days_per_hop"

## 項目の並びと、調整に要る情報。**この順にスライダーが並ぶ。**
##
## 範囲は「既定値を挟んで、壊れ方が見える所まで」を取ってある。壊れる側を
## 範囲外にすると、warnings() が警告する状況をそもそも作れず、警告の文面が
## 正しいかどうか確かめられない。
##
## is_int が false のものは float。刻み（step）は SpinBox / HSlider にそのまま渡す。
const SPECS: Array[Dictionary] = [
	{
		"key": MAX_DEPARTURES_PER_DAY, "label": "1日の出発本数", "is_int": true,
		"min": 0.0, "max": 20.0, "step": 1.0,
		"help": "1日に新しく仕立てる隊商の最大数。地図に出る荷車の増え方を決める。",
	},
	{
		"key": MAX_ACTIVE_CONVOYS, "label": "同時走行の上限", "is_int": true,
		"min": 0.0, "max": 60.0, "step": 1.0,
		"help": "同時に街道を走れる隊商の総数。地図に出る荷車の数の上限でもある。",
	},
	{
		"key": CONVOY_LOAD_MIN, "label": "積載（下限）", "is_int": true,
		"min": 1.0, "max": 40.0, "step": 1.0,
		"help": "隊商1本が積む個数の下限。産地の在庫からこの数だけ引いて運ぶ。",
	},
	{
		"key": CONVOY_LOAD_MAX, "label": "積載（上限）", "is_int": true,
		"min": 1.0, "max": 40.0, "step": 1.0,
		"help": "隊商1本が積む個数の上限。消費地の需要に対して大きすぎると一度で満たしてしまう。",
	},
	{
		"key": SUPPLY_RATE, "label": "交易路の倍率", "is_int": false,
		"min": 0.0, "max": 4.0, "step": 0.05,
		"help": "交易路が1日に運ぶ量の、消費量に対する倍率。1.0 だと買い占めた分を取り戻せない。",
	},
	{
		"key": SUPPLY_CEILING, "label": "交易路の上限", "is_int": false,
		"min": 0.0, "max": 1.0, "step": 0.01,
		"help": "交易路の補充が届く在庫の上限（stock_cap に対する割合）。到着上限より低く保つこと。",
	},
	{
		"key": DEPARTURE_STOCK_FLOOR, "label": "産地の下限", "is_int": false,
		"min": 0.0, "max": 1.0, "step": 0.01,
		"help": "産地の在庫がこの割合を下回っていたら送り出さない。産地を搾り取らないための線。",
	},
	{
		"key": ARRIVAL_STOCK_CEILING, "label": "到着の上限", "is_int": false,
		"min": 0.0, "max": 1.0, "step": 0.01,
		"help": "送り先の在庫がこの割合を超えていたら隊商を出さない。交易路の上限より高く保つこと。",
	},
	{
		"key": DAYS_PER_HOP, "label": "1区間の日数", "is_int": true,
		"min": 1.0, "max": 8.0, "step": 1.0,
		"help": "王道1ホップにかかる日数。1 にすると荷車が都市の真上にしか現れない。",
	},
]

## key -> 既定値。_init() で Logistics から受け取る（自前では持たない）。
var _defaults: Dictionary = {}

## key -> 上書きされた値。既定値と同じ値を入れても「上書き中」として扱う
## （画面上でどれを触ったかが分かる方が、調整中は役に立つ）。
var _overrides: Dictionary = {}


## defaults は key -> 値。Logistics.default_tuning() が const から組んで渡す。
func _init(defaults: Dictionary) -> void:
	_defaults = defaults.duplicate()


# --- 参照 ---

## 今の値（上書きがあればそれ、無ければ既定値）。
func value_of(key: String) -> float:
	if _overrides.has(key):
		return float(_overrides[key])
	return float(_defaults.get(key, 0.0))


## 今の値を int で。int の項目（is_int）を読むときはこちらを使う。
func int_of(key: String) -> int:
	return int(round(value_of(key)))


## 既定値（const の値）。上書き中でも変わらない。
func default_of(key: String) -> float:
	return float(_defaults.get(key, 0.0))


func is_overridden(key: String) -> bool:
	return _overrides.has(key)


## 上書きされている項目が1つでもあるか。画面に「調整中」を出す判断に使う。
func has_overrides() -> bool:
	return not _overrides.is_empty()


func overridden_keys() -> Array[String]:
	var found: Array[String] = []
	# SPECS の順で返す。_overrides の並びは触った順になるので、画面に出す
	# 際にスライダーの並びと食い違う。
	for spec: Dictionary in SPECS:
		if _overrides.has(spec["key"]):
			found.append(spec["key"])
	return found


static func spec_of(key: String) -> Dictionary:
	for spec: Dictionary in SPECS:
		if spec["key"] == key:
			return spec
	return {}


## SPECS の並びのままキーを返す。
## `keys` という名前にしないのは Dictionary.keys() と読み違えやすいため。
static func all_keys() -> Array[String]:
	var found: Array[String] = []
	for spec: Dictionary in SPECS:
		found.append(spec["key"])
	return found


# --- 変更 ---

## 上書きする。SPECS の範囲へ丸め、int の項目は整数に落とす。
##
## 範囲外を弾かず丸めるのは、スライダーと数値入力の両方から来るため。
## 弾くと数値入力に途中の値（"1" と打った瞬間の 1）を入れられなくなる。
func set_override(key: String, value: float) -> void:
	var spec: Dictionary = spec_of(key)
	if spec.is_empty():
		return
	var clamped: float = clampf(value, float(spec["min"]), float(spec["max"]))
	if bool(spec["is_int"]):
		clamped = round(clamped)
	_overrides[key] = clamped


func clear_override(key: String) -> void:
	_overrides.erase(key)


## すべての上書きを捨てて const の既定値へ戻す。
func clear_all() -> void:
	_overrides.clear()


# --- 整合の警告 ---

## 今の値の組み合わせで、logistics.gd のコメントが「そうすると壊れる」と
## 書いている状態になっていないか。壊れ方の説明つきで返す（空なら健全）。
##
## **これは検査ではなく案内。** 値は意図的に壊してみるためのものなので、
## 止めずに「こうなるはず」だけを出す。逆に言えば、警告が出ている状態で
## 見えている挙動は「壊した結果」であって物流の不具合ではない、と読める。
func warnings() -> Array[String]:
	var messages: Array[String] = []

	if value_of(SUPPLY_CEILING) >= value_of(ARRIVAL_STOCK_CEILING):
		messages.append(
			"交易路の上限（%.2f）が到着の上限（%.2f）以上。定常の補充だけで常に到着の上限を超えるため、隊商が一度も出ず地図から荷車が消える。"
			% [value_of(SUPPLY_CEILING), value_of(ARRIVAL_STOCK_CEILING)])

	if int_of(DAYS_PER_HOP) <= 1:
		messages.append(
			"1区間の日数が 1。隊商の残り日数が常に区間の境目に一致するため、荷車が都市の真上にしか現れず街道の途中に居る絵が出ない。")

	if int_of(CONVOY_LOAD_MIN) > int_of(CONVOY_LOAD_MAX):
		messages.append(
			"積載の下限（%d）が上限（%d）を超えている。積載は上限側へ丸めて扱う。"
			% [int_of(CONVOY_LOAD_MIN), int_of(CONVOY_LOAD_MAX)])

	if int_of(MAX_DEPARTURES_PER_DAY) <= 0 or int_of(MAX_ACTIVE_CONVOYS) <= 0:
		messages.append(
			"出発本数か同時走行の上限が 0。隊商は出ないが、交易路（地図に出ない補充）は流れ続けるので在庫は成立する。")

	if value_of(DEPARTURE_STOCK_FLOOR) >= 1.0:
		messages.append(
			"産地の下限が 1.00。在庫が上限に張り付いていないと送り出せないため、隊商はほとんど出ない。")

	# 倍率 0 でも補充は止まらない（_supply_routes() が maxi(1, ...) で
	# 下限を1に切り上げるため）。「止まる」と書くと画面の説明が実際とズレる。
	if value_of(SUPPLY_RATE) <= 0.0:
		messages.append(
			"交易路の倍率が 0。補充は止まらないが 1個/日 まで落ちるため、消費に追いつかず非生産地は品切れへ向かう。")

	return messages
