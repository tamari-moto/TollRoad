extends RefCounted
## ゲーム全体の静的定義（アイテム・都市・各種パラメータ）。
## autoload ではなく定数クラスとして持ち、load() + .new() のハーネスから
## そのまま参照できるようにする。値の出典は docs/game_design.md。

# --- ゲーム進行 ---
const TOTAL_DAYS: int = 60
const INITIAL_SILVER: int = 30000
const INITIAL_CITY: String = "ironhollow"

## 1日目を月曜日とする7日周期。曜日を使う要素（市場イベントなど）は
## ここを経由して曜日を引く。day は GameSession.day と同じ1始まりの値。
const WEEKDAY_NAMES: Array[String] = ["月", "火", "水", "木", "金", "土", "日"]


static func weekday_index(day: int) -> int:
	return (day - 1) % WEEKDAY_NAMES.size()


static func weekday_name(day: int) -> String:
	return WEEKDAY_NAMES[weekday_index(day)]

# --- アイテム ---
## 種別。装備は資源から製作される。RARE は探索でのみ手に入り、製作や
## 労働者の抽選（resource_ids()）の対象外。
enum ItemKind { RESOURCE, EQUIPMENT, RARE }

const RESOURCE_WEIGHT: int = 1
const EQUIPMENT_WEIGHT: int = 3

## 全品目の基準価格と重量。material は装備のみ（資源3個で1個製作）。
const ITEMS: Dictionary = {
	"ore":           {"name": "鉱石",     "kind": ItemKind.RESOURCE,  "base_price": 210,  "weight": RESOURCE_WEIGHT},
	"wood":          {"name": "木材",     "kind": ItemKind.RESOURCE,  "base_price": 205,  "weight": RESOURCE_WEIGHT},
	"fiber":         {"name": "繊維",     "kind": ItemKind.RESOURCE,  "base_price": 200,  "weight": RESOURCE_WEIGHT},
	"hide":          {"name": "皮",       "kind": ItemKind.RESOURCE,  "base_price": 215,  "weight": RESOURCE_WEIGHT},
	"stone":         {"name": "石材",     "kind": ItemKind.RESOURCE,  "base_price": 160,  "weight": RESOURCE_WEIGHT},
	"sword":         {"name": "剣",       "kind": ItemKind.EQUIPMENT, "base_price": 1500, "weight": EQUIPMENT_WEIGHT, "material": "ore"},
	"bow":           {"name": "弓",       "kind": ItemKind.EQUIPMENT, "base_price": 1460, "weight": EQUIPMENT_WEIGHT, "material": "wood"},
	"robe":          {"name": "ローブ",   "kind": ItemKind.EQUIPMENT, "base_price": 1420, "weight": EQUIPMENT_WEIGHT, "material": "fiber"},
	"armor":         {"name": "革鎧",     "kind": ItemKind.EQUIPMENT, "base_price": 1480, "weight": EQUIPMENT_WEIGHT, "material": "hide"},
	"sunstone":      {"name": "陽光石",   "kind": ItemKind.RARE,      "base_price": 900,  "weight": RESOURCE_WEIGHT},
	"ancient_relic": {"name": "古代兵装", "kind": ItemKind.RARE,      "base_price": 4000, "weight": EQUIPMENT_WEIGHT},
	"coal":          {"name": "石炭",     "kind": ItemKind.RESOURCE,  "base_price": 180,  "weight": RESOURCE_WEIGHT},
	"wool":          {"name": "羊毛",     "kind": ItemKind.RESOURCE,  "base_price": 195,  "weight": RESOURCE_WEIGHT},
	"quartz":        {"name": "水晶",     "kind": ItemKind.RESOURCE,  "base_price": 260,  "weight": RESOURCE_WEIGHT},
	"clay":          {"name": "粘土",     "kind": ItemKind.RESOURCE,  "base_price": 150,  "weight": RESOURCE_WEIGHT},
	"shield":        {"name": "盾",       "kind": ItemKind.EQUIPMENT, "base_price": 1350, "weight": EQUIPMENT_WEIGHT, "material": "stone"},
	"warhammer":     {"name": "戦鎚",     "kind": ItemKind.EQUIPMENT, "base_price": 1520, "weight": EQUIPMENT_WEIGHT, "material": "coal"},
	"cloak":         {"name": "外套",     "kind": ItemKind.EQUIPMENT, "base_price": 1440, "weight": EQUIPMENT_WEIGHT, "material": "wool"},
	"staff":         {"name": "杖",       "kind": ItemKind.EQUIPMENT, "base_price": 1750, "weight": EQUIPMENT_WEIGHT, "material": "quartz"},
}

## 装備1個あたりの材料消費数。
const CRAFT_MATERIAL_COUNT: int = 3

# --- 都市 ---
## specialty はその都市で安い資源、bonus はその都市で安い（かつ製作還元がある）装備。
## explore_flavor は探索の演出文（討伐/遺跡探索のどちらの体裁かを都市ごとに変える）。
## 接続関係（どの都市と王道で直接つながるか）は ROYAL_ROAD_EDGES を、
## レイヴンスパイアと黒ゾーンで直結するか（黒ゾーンのゲート）は
## BLACK_ZONE_GATES を参照。
const CITIES: Dictionary = {
	"oakhaven":   {"name": "オークヘイヴン",   "specialty": "wood",  "bonus": "bow",
		"explore_flavor": "森に潜む狼の群れの討伐"},
	"wrenfield":  {"name": "レンフィールド",   "specialty": "fiber", "bonus": "robe",
		"explore_flavor": "湿地に眠る遺跡の探索"},
	"stonegate":  {"name": "ストーンゲート",   "specialty": "stone", "bonus": "shield",
		"explore_flavor": "採石場跡に巣食う魔物の討伐"},
	"ironhollow": {"name": "アイアンホロウ",   "specialty": "ore",   "bonus": "sword",
		"explore_flavor": "山中の坑道遺跡の探索"},
	"foxmere":    {"name": "フォックスミア",   "specialty": "hide",  "bonus": "armor",
		"explore_flavor": "湿原に現れる怪物の討伐"},
	"cragmoor":   {"name": "クラグムーア",     "specialty": "coal",  "bonus": "warhammer",
		"explore_flavor": "廃坑に眠る発破遺構の探索"},
	"fenwick":    {"name": "フェンウィック",   "specialty": "wool",  "bonus": "cloak",
		"explore_flavor": "湿地牧草地を荒らす獣の討伐"},
	"silvermere": {"name": "シルバーミア",     "specialty": "quartz", "bonus": "staff",
		"explore_flavor": "湖底に沈む魔導遺跡の探索"},
	"wyndham":    {"name": "ウィンダム",       "specialty": "clay",  "bonus": "",
		"explore_flavor": "窯場を脅かす盗賊団の討伐"},
	"ravenspire": {"name": "レイヴンスパイア", "specialty": "",      "bonus": "",
		"explore_flavor": "黒ゾーン最奥の遺跡の探索"},
}

const CAERLEON: String = "ravenspire"

## 王国都市どうしを直接つなぐ王道（黒ゾーンを含まない）。片方向だけ書けば
## 双方向とみなす（is_adjacent() が両順序で照合する）。次数はわざと不揃いに
## してある（oakhaven/wyndham は行き止まり、ironhollow は最大の交差点）。
const ROYAL_ROAD_EDGES: Array = [
	["oakhaven", "stonegate"],
	["stonegate", "ironhollow"],
	["ironhollow", "foxmere"],
	["ironhollow", "wrenfield"],
	["ironhollow", "cragmoor"],
	["foxmere", "cragmoor"],
	["foxmere", "silvermere"],
	["wrenfield", "fenwick"],
	["fenwick", "silvermere"],
	["silvermere", "wyndham"],
]

## レイヴンスパイアと黒ゾーンで直結する（＝1区間で到達できる）王国都市。
## それ以外の王国都市は、王道でこのいずれかへ着いてから黒ゾーンに入る
## 必要がある（経路探索が自動で合成する。game_session.gd 参照）。
## 王道での中心寄りの交差点3つを選んである。
const BLACK_ZONE_GATES: Array[String] = ["ironhollow", "foxmere", "silvermere"]

# --- 価格 ---
const JITTER_MIN: float = 0.86
const JITTER_MAX: float = 1.16

const MOD_SPECIALTY: float = 0.72
const MOD_BONUS: float = 0.88
const MOD_CAERLEON_EQUIPMENT: float = 1.24
const MOD_CAERLEON_RESOURCE: float = 1.06

# --- 在庫と需要 ---
## 都市ごとの在庫（買える上限）と需要（売れる上限）。市場は無限ではなく、
## 毎日ここに書いた量だけ生産・消費されて補充される（market_table.gd）。
##
## **量は既存のバランスを壊さない側に振ってある。** 1回の来訪で積載
## （ロバ40〜マンモス170）を満たせる程度に確保し、既存の
## 「アイアンホロウで鉱石→剣を作りレイヴンスパイアで売る」往復が従来どおり
## 回るようにしている。価格・移動費・手数料は一切変えていない。
## docs/game_design.md の実測表は都市を増やした時点から未再検証のままなので、
## この数値を締める前に実機で20〜30回の通しプレイを取り直すこと。

## 1日あたりの生産量。specialty（特産資源）と bonus（生産地の装備）に厚く出す。
## 特産は「1回の来訪で最大の積荷（マンモス170）を満たせる」ことを下限に置く。
## ここを絞ると、安く仕入れて運ぶという遊びの中心が成立しなくなる
## （scenario_m23.gd の _test_balance_guardrails() が上限・下限で挟んでいる）。
const PRODUCTION_SPECIALTY: int = 44
const PRODUCTION_BONUS: int = 9

## **生産地以外は自分では作らない（0）。** 以前はどの都市も全品目を毎日
## わずかに生産しており、木材の採れない都市にも木材がわいていた。物流
## （logistics.gd）を入れた今は、産地以外の在庫は隊商が運んできた分だけになる。
##
## 0 以外に戻すと「生産地のみで在庫が増える」という前提が崩れ、隊商が
## 来なくても品物が並ぶようになる（scenario_m28.gd がこの2つを 0 で押さえている）。
##
## 資源の側は特産の距離段階（PRODUCTION_SPECIALTY_NEAR_*）が生産量を
## 決めるようになったので production_of() からは参照されない。定数を残して
## あるのは scenario_m28.gd の前提として意味があるため。
const PRODUCTION_OTHER_RESOURCE: int = 0
const PRODUCTION_OTHER_EQUIPMENT: int = 0

## 特産資源は本拠地からの王道ホップ距離で段階的に減る（road_distance() 参照）。
## 「その街でしか採れないが、近隣の街でも少しは採れる」という産地の実感を
## 出すための段階。距離2を超える都市（黒ゾーンのレイヴンスパイア含む）では
## 自前生産を持たせず（トリクル生産を廃止）、隊商の輸入だけに委ねる。
## 都市を足しても表を書き足す必要は無い（specialty と ROYAL_ROAD_EDGES から
## 自動で決まる）。
const PRODUCTION_SPECIALTY_NEAR_1: int = 16 ## 隣接都市（distance 1）
const PRODUCTION_SPECIALTY_NEAR_2: int = 4  ## 2ホップ先（distance 2）
const PRODUCTION_SPECIALTY_FAR: int = 0     ## それ以外（自前生産なし）

## 1日あたりの消費量（＝需要の回復量）。生産と逆向きで、自前で作れるものは
## 欲しがらない。レイヴンスパイアは装備の集積地なので装備を厚く買い取る。
const CONSUMPTION_RESOURCE: int = 8
const CONSUMPTION_EQUIPMENT: int = 5
const CONSUMPTION_LOCAL_SURPLUS: int = 2
const CONSUMPTION_CAERLEON_EQUIPMENT: int = 14
const CONSUMPTION_CAERLEON_OTHER: int = 6

## 在庫・需要が積み上がる日数の上限。長いほど「久しぶりに寄った都市には
## 貯まっている」が強くなる。上限 = 1日あたりの量 × この日数。
const MARKET_CAP_DAYS: int = 4

## 輸入品の初期在庫（上限に対する割合）。0 にして完全な品切れから
## 始めるのは、初日から不足を作って隊商を走らせるため
## （market_table.gd の reset() 参照）。
const IMPORT_INITIAL_RATIO: float = 0.0

## 生産しない都市が1日に食い潰す在庫の割合（消費量に対する比）。
## 1.0 だと棚が空く速さに隊商の補充が追いつかず常時品切れになり、
## 0 だと在庫が減らないので隊商が一度も出ない（実測）。その間を取る。
const IMPORT_DRAIN_RATE: float = 0.5

## 生産しない都市の在庫の上限を決める日数（上限 = 消費量 × この日数）。
## 隊商が運び込んだ品物がどれだけ積み上がれるかを決める。
##
## MARKET_CAP_DAYS より短くしてあるのは、輸入品は「産地ほどは潤沢でない」
## ことを在庫の厚みで示すため。ここを伸ばすと消費地でも大量に買えるように
## なり、産地まで足を運ぶ意味が薄れる。
const IMPORT_CAP_DAYS: int = 3

## 在庫・需要の薄さが価格に効く掛け率。満杯なら 1.0、空なら以下の値。
## 買い占めると値上がりし、売り込むと値崩れする。
## 幅を控えめにしてあるのは、既存の価格帯（ui_theme.gd の
## PRICE_SCALE_MIN〜MAX = 60〜145%）から外れさせないため。
const PRICE_SCARCITY_MAX: float = 1.15
const PRICE_GLUT_MIN: float = 0.88

# --- 取引 ---
## 売却時に売上総額へかかる税率（Q2: 総額課税）。
const SELL_TAX_RATE: float = 0.05

# --- 移動 ---
const MOVE_ADJACENT_DAYS: int = 1
const MOVE_ADJACENT_COST: int = 250
const MOVE_BLACK_ZONE_DAYS: int = 1
const MOVE_BLACK_ZONE_COST: int = 400
const RAID_CHANCE: float = 0.22

# --- 製作 ---
const CRAFT_FEE: int = 90
const CRAFT_REFUND_RATE: float = 0.30

# --- 探索 ---
## 戦闘装備として兼用する既存の交易用装備。積荷にあるほど成功率が上がる。
const EXPLORE_COMBAT_ITEMS: Array[String] = ["sword", "bow", "robe", "armor", "shield", "warhammer", "cloak", "staff"]

const EXPLORE_BASE_CHANCE: float = 0.35
## 装備1個あたりのボーナス。同種は EXPLORE_EQUIP_UNIT_CAP 個までしか加算されない
## （種類を跨いで持つ方が伸びる設計）。
const EXPLORE_EQUIP_BONUS_PER_UNIT: float = 0.03
const EXPLORE_EQUIP_UNIT_CAP: int = 3
const EXPLORE_EQUIP_BONUS_CAP: float = 0.30
const EXPLORE_MAX_CHANCE: float = 0.85
## レイヴンスパイアは黒ゾーンの並びで成功率が下がる代わりに報酬が大きい。
const EXPLORE_CAERLEON_PENALTY: float = 0.15

const EXPLORE_SILVER_MIN: int = 1600
const EXPLORE_SILVER_MAX: int = 4000
const EXPLORE_CAERLEON_SILVER_MULT: float = 2.5

const EXPLORE_GEM_MIN: int = 2
const EXPLORE_GEM_MAX: int = 6
const EXPLORE_RELIC_CHANCE: float = 0.30
const EXPLORE_CAERLEON_RELIC_CHANCE: float = 0.70

## 成功すると数日間、島の労働者の産出が増える。
const EXPLORE_BOOST_DAYS: int = 5
const EXPLORE_BOOST_MULT: int = 2

# --- 日送りランダムイベント ---
## 現在地の specialty をキーに引く。未登録（specialty が空の都市）は DEFAULT を使う。
## 都市IDではなく品目IDをキーにするため、都市を足しても書き足しは不要
## （新しい specialty 品目を足したときだけ追記する）。
const EVENT_CHANCE_DEFAULT: float = 0.08
const EVENT_CHANCE_BY_SPECIALTY: Dictionary = {
	"ore": 0.12, "wood": 0.10, "fiber": 0.10, "hide": 0.11,
	"stone": 0.09, "coal": 0.12, "wool": 0.09, "quartz": 0.10, "clay": 0.08,
}

const EVENT_SILVER_GAIN_MIN: int = 80
const EVENT_SILVER_GAIN_MAX: int = 260
const EVENT_SILVER_LOSS_MIN: int = 80
const EVENT_SILVER_LOSS_MAX: int = 260

const EVENT_CARGO_MIN: int = 1
const EVENT_CARGO_MAX: int = 2

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

# --- ギルド仲間（同行者） ---
## 同時に同行できるのは1人のみ。加入・切り替えはいつでも無料（日数を消費しない）。
## 効果は game_session.gd が companion id を直接見て適用する（汎用の効果ディスパッチは作らない）。
const COMPANION_NONE: String = ""

const COMPANIONS: Dictionary = {
	"fina":     {"name": "フィナ",       "role": "猫獣人の交渉屋",     "desc": "買値が8%下がる。"},
	"gadolf":   {"name": "ガドルフ",     "role": "ドワーフの老鍛冶",   "desc": "製作の手数料が90→60に下がる。"},
	"serafina": {"name": "セラフィーナ", "role": "元貴族の相場読み",   "desc": "相場メモが古くならない。"},
	"rocco":    {"name": "ロッコ",       "role": "頼れる運び屋",       "desc": "積載量+15、黒ゾーンの襲撃率-5pt。"},
	"kale":     {"name": "ケイル",       "role": "元斥候・道案内人",   "desc": "探索の基本成功率が+5pt上がる。"},
	"mira":     {"name": "ミラ",         "role": "目利きの故買屋",     "desc": "売却時の税率が5%→2%に下がる。"},
	"baron":    {"name": "バロン",       "role": "退役衛兵",           "desc": "王道区間の移動費用が250→150に下がる。"},
	"olga":     {"name": "オルガ",       "role": "島の元差配人",       "desc": "島の労働者1人あたりの産出が2→3に増える。"},
	"tobias":   {"name": "トビアス",     "role": "倹約家の職人見習い", "desc": "製作の材料所要量が常に1個減る（最低1個）。"},
}

## パネルに表示する順。
const COMPANION_ORDER: Array[String] = [
	"fina", "gadolf", "serafina", "rocco", "kale", "mira", "baron", "olga", "tobias"]

const COMPANION_BUY_DISCOUNT: float = 0.08     # フィナ: 購入価格の割引率
const COMPANION_CRAFT_FEE: int = 60            # ガドルフ: 手数料の置き換え値（通常は CRAFT_FEE=90）
const COMPANION_CAPACITY_BONUS: int = 15       # ロッコ: 積載量の加算
const COMPANION_RAID_REDUCTION: float = 0.05   # ロッコ: 襲撃率の減算
const COMPANION_EXPLORE_BONUS: float = 0.05    # ケイル: 探索の基本成功率の加算
const COMPANION_SELL_TAX_RATE: float = 0.02    # ミラ: 売却税率の置き換え値（通常は SELL_TAX_RATE=0.05）
const COMPANION_MOVE_COST: int = 150           # バロン: 王道隣接区間の移動費用の置き換え値（通常は MOVE_ADJACENT_COST=250）
const COMPANION_WORKER_YIELD: int = 3          # オルガ: 労働者1人あたりの産出の置き換え値（通常は RESOURCES_PER_WORKER_PER_DAY=2）
const COMPANION_CRAFT_MATERIAL_DISCOUNT: int = 1  # トビアス: 製作材料1個あたりの減算（下限1）

## 9人共通の基本ステータス（0〜5の段階値）。1人1特性とは別レイヤーで加算される。
## 特性の軸と一致する人（フィナ/ロッコ/ケイル/ミラ/バロン）はここでも高い値を
## 持ち、特性の無い人（ガドルフ/セラフィーナ/オルガ/トビアス）にもこの5軸で
## 存在感を持たせる。値は初回の仮置きで、実測（プレイ検証）はしていない。
const COMPANION_STATS: Dictionary = {
	"fina":     {"capacity": 1, "negotiation": 5, "appraisal": 2, "exploration": 1, "vigilance": 1},
	"gadolf":   {"capacity": 3, "negotiation": 1, "appraisal": 1, "exploration": 0, "vigilance": 2},
	"serafina": {"capacity": 0, "negotiation": 2, "appraisal": 4, "exploration": 1, "vigilance": 1},
	"rocco":    {"capacity": 5, "negotiation": 1, "appraisal": 1, "exploration": 1, "vigilance": 3},
	"kale":     {"capacity": 2, "negotiation": 0, "appraisal": 1, "exploration": 5, "vigilance": 2},
	"mira":     {"capacity": 1, "negotiation": 3, "appraisal": 5, "exploration": 1, "vigilance": 0},
	"baron":    {"capacity": 3, "negotiation": 0, "appraisal": 1, "exploration": 1, "vigilance": 5},
	"olga":     {"capacity": 2, "negotiation": 1, "appraisal": 2, "exploration": 1, "vigilance": 1},
	"tobias":   {"capacity": 1, "negotiation": 2, "appraisal": 2, "exploration": 0, "vigilance": 1},
}

const COMPANION_STAT_CAPACITY_PER_LEVEL: int = 1          # 積載量補正: 1レベルあたりの加算
const COMPANION_STAT_NEGOTIATION_PER_LEVEL: float = 0.01  # 交渉力: 1レベルあたりの買値割引
const COMPANION_STAT_APPRAISAL_PER_LEVEL: float = 0.01    # 目利き: 1レベルあたりの売却税率の減算
const COMPANION_STAT_EXPLORATION_PER_LEVEL: float = 0.01  # 探索技能: 1レベルあたりの探索成功率の加算
const COMPANION_STAT_VIGILANCE_PER_LEVEL: float = 0.01    # 警戒心: 1レベルあたりの黒ゾーン襲撃率の減算


## 基本ステータス5軸を1行にまとめた表示用文字列。COMPANION_STATS に無い
## IDなら空文字を返す（"誰も同行しない"ボタンなど）。
static func companion_stat_line(companion_id: String) -> String:
	if not COMPANION_STATS.has(companion_id):
		return ""
	var s: Dictionary = COMPANION_STATS[companion_id]
	return "積載+%d 交渉+%d%% 目利き+%d%% 探索+%d%% 警戒+%d%%" % [
		int(s["capacity"]) * COMPANION_STAT_CAPACITY_PER_LEVEL,
		int(round(int(s["negotiation"]) * COMPANION_STAT_NEGOTIATION_PER_LEVEL * 100)),
		int(round(int(s["appraisal"]) * COMPANION_STAT_APPRAISAL_PER_LEVEL * 100)),
		int(round(int(s["exploration"]) * COMPANION_STAT_EXPLORATION_PER_LEVEL * 100)),
		int(round(int(s["vigilance"]) * COMPANION_STAT_VIGILANCE_PER_LEVEL * 100)),
	]

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


## 王国都市（レイヴンスパイア以外）のIDを CITIES の宣言順で返す。
## 順序はトポロジーとは無関係な、表示用の安定順でしかない。
static func royal_city_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in CITIES:
		if id != CAERLEON:
			ids.append(id)
	return ids


## 2都市が王道で直接つながっているか（ROYAL_ROAD_EDGES に辺があるか）。
## レイヴンスパイアはどの都市とも王道では接続しない（黒ゾーン隣接は含まない）。
static func is_adjacent(city_a: String, city_b: String) -> bool:
	if city_a == city_b:
		return false
	for edge: Array in ROYAL_ROAD_EDGES:
		if (edge[0] == city_a and edge[1] == city_b) or (edge[0] == city_b and edge[1] == city_a):
			return true
	return false


## city_id と王道で直接つながる都市のIDを返す（レイヴンスパイアは常に空）。
static func road_neighbors(city_id: String) -> Array[String]:
	var neighbors: Array[String] = []
	for edge: Array in ROYAL_ROAD_EDGES:
		if edge[0] == city_id:
			neighbors.append(edge[1])
		elif edge[1] == city_id:
			neighbors.append(edge[0])
	return neighbors


## 品目を specialty として持つ都市。無ければ空文字。
static func city_for_specialty(item_id: String) -> String:
	for city_id: String in CITIES:
		if CITIES[city_id]["specialty"] == item_id:
			return city_id
	return ""


## 王道上の最短ホップ数（road_neighbors() による BFS）。黒ゾーン経由は
## 数えない。到達できない場合（レイヴンスパイアなど王道に一切繋がらない
## 都市を含む場合）は -1。
static func road_distance(city_a: String, city_b: String) -> int:
	if city_a == city_b:
		return 0
	var visited: Dictionary = {city_a: 0}
	var queue: Array[String] = [city_a]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbor: String in road_neighbors(current):
			if neighbor == city_b:
				return visited[current] + 1
			if not visited.has(neighbor):
				visited[neighbor] = visited[current] + 1
				queue.append(neighbor)
	return -1


## 純資産から到達ランク名を返す。
static func rank_for(net_worth: int) -> String:
	for rank: Dictionary in RANKS:
		if net_worth >= rank["threshold"]:
			return rank["name"]
	return RANKS[RANKS.size() - 1]["name"]
