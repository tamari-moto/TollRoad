extends RefCounted
## ゲーム全体の静的定義（アイテム・都市・各種パラメータ）。
## autoload ではなく定数クラスとして持ち、load() + .new() のハーネスから
## そのまま参照できるようにする。値の出典は docs/game_design.md。

# --- ゲーム進行 ---
const TOTAL_DAYS: int = 60
const INITIAL_SILVER: int = 30000
const INITIAL_CITY: String = "martlock"

# --- アイテム ---
## 種別。装備は資源から製作される。
enum ItemKind { RESOURCE, EQUIPMENT }

const RESOURCE_WEIGHT: int = 1
const EQUIPMENT_WEIGHT: int = 3

## 全品目の基準価格と重量。material は装備のみ（資源3個で1個製作）。
const ITEMS: Dictionary = {
	"ore":     {"name": "鉱石",   "kind": ItemKind.RESOURCE,  "base_price": 210,  "weight": RESOURCE_WEIGHT},
	"wood":    {"name": "木材",   "kind": ItemKind.RESOURCE,  "base_price": 205,  "weight": RESOURCE_WEIGHT},
	"fiber":   {"name": "繊維",   "kind": ItemKind.RESOURCE,  "base_price": 200,  "weight": RESOURCE_WEIGHT},
	"hide":    {"name": "皮",     "kind": ItemKind.RESOURCE,  "base_price": 215,  "weight": RESOURCE_WEIGHT},
	"stone":   {"name": "石材",   "kind": ItemKind.RESOURCE,  "base_price": 160,  "weight": RESOURCE_WEIGHT},
	"sword":   {"name": "剣",     "kind": ItemKind.EQUIPMENT, "base_price": 1500, "weight": EQUIPMENT_WEIGHT, "material": "ore"},
	"bow":     {"name": "弓",     "kind": ItemKind.EQUIPMENT, "base_price": 1460, "weight": EQUIPMENT_WEIGHT, "material": "wood"},
	"robe":    {"name": "ローブ", "kind": ItemKind.EQUIPMENT, "base_price": 1420, "weight": EQUIPMENT_WEIGHT, "material": "fiber"},
	"armor":   {"name": "革鎧",   "kind": ItemKind.EQUIPMENT, "base_price": 1480, "weight": EQUIPMENT_WEIGHT, "material": "hide"},
}

## 装備1個あたりの材料消費数。
const CRAFT_MATERIAL_COUNT: int = 3

# --- 都市 ---
## ring は環状位置。カーレオンは中央（黒ゾーン内）なので ring = -1。
## specialty はその都市で安い資源、bonus はその都市で安い（かつ製作還元がある）装備。
const CITIES: Dictionary = {
	"fort_sterling": {"name": "フォートスターリング", "ring": 0,  "specialty": "wood",  "bonus": "bow"},
	"lymhurst":      {"name": "リムハースト",         "ring": 1,  "specialty": "fiber", "bonus": "robe"},
	"bridgewatch":   {"name": "ブリッジウォッチ",     "ring": 2,  "specialty": "stone", "bonus": "armor"},
	"martlock":      {"name": "マートロック",         "ring": 3,  "specialty": "ore",   "bonus": "sword"},
	"thetford":      {"name": "セットフォード",       "ring": 4,  "specialty": "hide",  "bonus": "armor"},
	"caerleon":      {"name": "カーレオン",           "ring": -1, "specialty": "",      "bonus": ""},
}

const CAERLEON: String = "caerleon"
## 環状に並ぶ王国都市の数。隣接判定に使う。
const RING_SIZE: int = 5

# --- 価格 ---
const JITTER_MIN: float = 0.86
const JITTER_MAX: float = 1.16

const MOD_SPECIALTY: float = 0.72
const MOD_BONUS: float = 0.88
const MOD_CAERLEON_EQUIPMENT: float = 1.24
const MOD_CAERLEON_RESOURCE: float = 1.06

# --- 取引 ---
## 売却時に売上総額へかかる税率（Q2: 総額課税）。
const SELL_TAX_RATE: float = 0.05

# --- 移動 ---
const MOVE_ADJACENT_DAYS: int = 1
const MOVE_ADJACENT_COST: int = 250
const MOVE_FAR_DAYS: int = 2
const MOVE_FAR_COST: int = 450
const MOVE_BLACK_ZONE_DAYS: int = 1
const MOVE_BLACK_ZONE_COST: int = 400
const RAID_CHANCE: float = 0.22

# --- 製作 ---
const CRAFT_FEE: int = 90
const CRAFT_REFUND_RATE: float = 0.30

# --- 島と労働者 ---
const ISLAND_LEVELS: Array[Dictionary] = [
	{"cost": 0,      "workers": 0},
	{"cost": 26000,  "workers": 3},
	{"cost": 70000,  "workers": 9},
	{"cost": 180000, "workers": 20},
]
const RESOURCES_PER_WORKER_PER_DAY: int = 2

# --- 騎乗 ---
const MOUNTS: Dictionary = {
	"donkey":  {"name": "ロバ",             "cost": 0,     "capacity": 40},
	"ox":      {"name": "雄牛",             "cost": 18000, "capacity": 85},
	"mammoth": {"name": "輸送用マンモス",   "cost": 60000, "capacity": 170},
}
const INITIAL_MOUNT: String = "donkey"

# --- 相場メモ ---
## この日数以上経過した記録は「古い記録」として扱う。
const MEMO_STALE_DAYS: int = 7

# --- 純資産とランク ---
## 積荷・島倉庫を純資産に算入する際の掛け率。
const NET_WORTH_STOCK_RATE: float = 0.9

## プレイヤーに提示する目標ランク。HUD の進捗バーと開始画面がこれを基準にする。
const GOAL_RANK: String = "MASTER TRADER"

## 判定は上から順に行い、最初に満たした閾値のランクとなる。
const RANKS: Array[Dictionary] = [
	{"threshold": 1200000, "name": "LEGENDARY MERCHANT"},
	{"threshold": 500000,  "name": "MASTER TRADER"},
	{"threshold": 150000,  "name": "JOURNEYMAN"},
	{"threshold": 30000,   "name": "SURVIVOR"},
	{"threshold": 0,       "name": "BANKRUPT"},
]


## 資源のIDを配列で返す（労働者の抽選などに使う）。
static func resource_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in ITEMS:
		if ITEMS[id]["kind"] == ItemKind.RESOURCE:
			ids.append(id)
	return ids


## 王国都市（カーレオン以外）のIDを環状位置の順で返す。
static func royal_city_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.resize(RING_SIZE)
	for id: String in CITIES:
		var ring: int = CITIES[id]["ring"]
		if ring >= 0:
			ids[ring] = id
	return ids


## 2都市が環状で隣接しているか。環は閉じている（0と4も隣接）。
## カーレオンはどの都市とも王道では接続しない。
static func is_adjacent(city_a: String, city_b: String) -> bool:
	if city_a == city_b:
		return false
	var ring_a: int = CITIES[city_a]["ring"]
	var ring_b: int = CITIES[city_b]["ring"]
	if ring_a < 0 or ring_b < 0:
		return false
	var diff: int = absi(ring_a - ring_b)
	return diff == 1 or diff == RING_SIZE - 1


## 純資産から到達ランク名を返す。
static func rank_for(net_worth: int) -> String:
	for rank: Dictionary in RANKS:
		if net_worth >= rank["threshold"]:
			return rank["name"]
	return RANKS[RANKS.size() - 1]["name"]
