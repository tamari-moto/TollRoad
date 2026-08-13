extends Node3D
## 大陸図の 3D 表示。地形・都市・経路を組み立てる。
##
## 都市の配置は GameData.ROYAL_ROAD_EDGES（不規則な連結グラフ）を、決定的な
## ばね緩和（Fruchterman-Reingold 型の力学モデル）で水平面に配置してから
## 3D 空間に写す。中央にはレイヴンスパイアを固定する。乱数は使わないので
## 毎回ビット単位で同じ配置になる。
##
## クリック判定は 3D では行わない。map_panel が unproject_position() で
## 画面座標へ変換し、既存の Button を重ねる。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")

## 王道でつながる都市間の目標間隔（3D 空間の単位）。ばね緩和の引力が
## この距離に収束させようとする（旧・環状配置時代の値をそのまま踏襲）。
const CITY_SPACING: float = 10.58
## 地形の一辺に足す余白（配置全体の直径の外側）。_build() で
## MapCamera.MAX_DISTANCE から動的に算出する（_terrain_margin 参照）。
## 固定値だと都市配置が広がった時にカメラの限界より余白が狭くなり、
## 地形の縁が視界に入ってしまうことがあったため。
var _terrain_margin: float = 0.0
## カメラの最大距離に足す余裕（縁が完全にフォグへ溶けるぶんの猶予）。
const TERRAIN_MARGIN_BUFFER: float = 15.0
## 盆地の半径に足す余白（配置全体の半径の外側）。
const BASIN_MARGIN: float = 2.0

## ばね緩和の反復回数。多いほど収束するが、都市数が10程度なので十分少なくて済む。
const RELAXATION_ITERATIONS: int = 300
## 反復1回あたりの最大移動量（温度）。反復が進むにつれ線形に0へ冷やす
## ことで発散を防ぎ、後半ほど収束に近づける（Fruchterman-Reingold の cooling）。
const RELAXATION_INITIAL_TEMPERATURE: float = CITY_SPACING * 0.5
## 中心からの半径を大まかに一定へ寄せる、弱い求心力の強さ（0〜1の割合）。
## 強すぎるとばねと反発の均衡を崩し、弱すぎると配置が全体に広がりすぎる。
const CENTERING_STRENGTH: float = 0.02

## 次数1（行き止まり）の都市が絡む王道にかける引力の倍率。倍率1.0（無補正）
## だと oakhaven が反発に押し負けて半径49.8まで飛ばされ、カメラの
## MAX_DISTANCE(34.0) を大きく超えていた。2〜3倍程度でも半径は下がるが、
## 都市クリックの投影→逆投影の往復（map_panel.pick_city_at()）がその近辺で
## 符号が反転する境界に乗ってしまい、値によって成功・失敗が入れ替わる
## 不安定な帯だった（実測）。5倍で安定して往復が成立し、10倍まで上げると
## 今度は別の行き止まり都市（wyndham）側が近すぎて誤検出を始めたため、
## 安定帯の中央寄りにあるこの値で止めてある。
const PENDANT_EDGE_PULL_MULTIPLIER: float = 5.0

## --- 空・霧・グロウ ---
## GL Compatibility でも動作する範囲（プロシージャルな空、ボリューメトリック
## でない深度フォグ、グロウ）に絞ってある。数値は初期値であり、実際の見え方
## は実機のGUIでしか判断できない（CLAUDE.md参照）。
const SKY_TOP_COLOR := Color(0.08, 0.09, 0.15)
const SKY_HORIZON_COLOR := Color(0.30, 0.26, 0.28)
const SKY_GROUND_COLOR := Color(0.05, 0.05, 0.07)
const AMBIENT_LIGHT_ENERGY: float = 0.6
const FOG_DENSITY: float = 0.01
const GLOW_INTENSITY: float = 0.2
const GLOW_BLOOM: float = 0.04
## グローがHDRとして扱う輝度の下限。既定は1.0だが、明示しないとエンジンの
## 既定値変更で CITY_EMISSION_ENERGY との関係が黙って崩れるため定数化する。
const GLOW_HDR_THRESHOLD: float = 1.0
## 都市パーツの発光エネルギー。旧値0.35では発光色（PIN_FRAME等、輝度0.66〜0.76）
## を掛けても最大0.3程度にしかならず、GLOW_HDR_THRESHOLD を一度も超えられず
## グローが実際には出ていなかった（実機で確認）。輝度×この値が閾値を確実に
## 超えるよう引き上げる。閾値側を下げる手もあるが、空・フォグの色（輝度0.27
## 程度）に波及しない保証がその都度必要になるため、発光源側だけを直す方を選んだ。
const CITY_EMISSION_ENERGY: float = 3.0

## 配置全体の半径（3D 空間の単位）。緩和後の実際の座標の広がりから
## _compute_scale() が算出する（環のような閉形式の計算はしない）。
var _ring_radius: float = 0.0
## 地形の一辺。都市が乗る範囲より広く取る。_compute_scale() で算出する。
var _terrain_size: float = 0.0
## 地形メッシュの1マスの一辺がこれを超えないよう _terrain_subdivisions を
## _compute_scale() で決める。草木の間隔(VEGETATION_GRID_STEP=1.4)や
## footprint(半径0.32)より十分小さい値にしないと、height_at() の連続値
## （草木の設置高さ）と実際に描画されるメッシュの補間値がズレ、草木が
## 地面から浮いたり埋まったりして見える（実測: 固定64分割だと1マスが約2.9
## あり、トランク底面の縁で描画面との誤差が最大1m近く出ていた）。
## 都市配置が広がって _terrain_size が伸びるほど分割数も自動で増える
## （固定値だと過去に都市数が増えた際と同じ理由で再び陳腐化するため）。
const TERRAIN_MAX_QUAD_SIZE: float = 0.8
## 地形の分割数。_compute_scale() が _terrain_size と TERRAIN_MAX_QUAD_SIZE
## から算出する。
var _terrain_subdivisions: int = 64

## 起伏の高さ。
const TERRAIN_HEIGHT: float = 2.4
## ノイズの細かさ。
const TERRAIN_NOISE_SCALE: float = 0.10
## 中央を掘り下げる深さ。レイヴンスパイアが盆地の底に見えるようにする。
const BASIN_DEPTH: float = 2.2
## 盆地の広がり。_compute_scale() で算出する。
var _basin_radius: float = 0.0

## 地形の頂点カラーに使う3色。盆地に近いほど暗く危険な色、外周に近いほど
## 明るい色を基調にし、傾斜が急なところほど岩肌寄りの色を混ぜる。
const TERRAIN_BASIN_COLOR := Color(0.16, 0.16, 0.20)
const TERRAIN_UPLAND_COLOR := Color(0.30, 0.34, 0.30)
const TERRAIN_ROCK_COLOR := Color(0.24, 0.22, 0.22)

## バイオーム（最寄り都市の特産色）が地形に効く範囲。CITY_SPACING より
## やや広めに取り、隣接都市どうしの色がにじみ合って自然に混ざるようにする
## （Voronoi的な硬い境界は引かない）。
const BIOME_INFLUENCE_RADIUS: float = CITY_SPACING * 1.3
## 特産色をそのまま使うと地形の中で浮くため、少し暗くしてから混ぜる。
const BIOME_COLOR_DARKEN: float = 0.35

## 都市の構造物（土台＋尖塔）が使える高さの予算と太さの基準。
## 現在地リングは地形の高さ + RING_LIFT に浮かぶ固定位置で、構造物の実際の
## 高さには追従しない。構造物がめり込んで見えないよう、パーツを増やしても
## 最高点がこの値を超えないようにすること
## （scenario_m17.gd の「柱より上に架かる」検査もこの前提）。
const CITY_HEIGHT: float = 1.5
const CITY_RADIUS: float = 0.55
## 土台が使う高さの割合。残りを尖塔に配分する。
const CITY_BASE_HEIGHT_RATIO: float = 0.5
## 尖塔が使う高さの割合（土台を除いた残りに対する比率）。本数を増やしても
## 個々の高さはほぼ揃えたままにする（本数で密度を、高さで危険度を示さない）。
const CITY_SPIRE_HEIGHT_RATIO: float = 0.85
## 尖塔の本数（中心都市以外）。city_id のハッシュから決定的に決める
## （真の乱数は使わない。同じ都市は毎回同じ見た目になる）。
const CITY_SPIRE_MIN: int = 1
const CITY_SPIRE_MAX: int = 2
## 中心都市の尖塔本数。密集させて、他と違う特別な場所だと分かるようにする。
const CAERLEON_SPIRE_COUNT: int = 4

## --- 草木 ---
## 候補地を走査する格子の間隔。狭いほど密になる。
const VEGETATION_GRID_STEP: float = 1.4
## 草木をばら撒く範囲。配置の広がり（_ring_radius）にこの余白を足した
## 円の内側だけに生やす（地形の縁のフェード領域まではみ出さない）。
const VEGETATION_OUTER_MARGIN: float = 6.0
## 盆地指標（height_at() と同じ、中心に近いほど1.0）がこれを超える場所には
## 生やさない。黒ゾーン寄りは不毛な土地として読める。
const VEGETATION_BASIN_LIMIT: float = 0.45
## 都市の構造物からこの距離より近づけない。
const VEGETATION_CITY_CLEARANCE: float = 1.8
## 道（王道・黒ゾーン）からこの距離より近づけない。
const VEGETATION_ROAD_CLEARANCE: float = 1.0
## ノイズ値がこれを超えた候補地に低木を生やす。
const VEGETATION_BUSH_THRESHOLD: float = -0.1
## ノイズ値がこれを超えた候補地は低木の代わりに木を生やす
## （木の方が密度は低い＝目立つアクセントとして使う）。
const VEGETATION_TREE_THRESHOLD: float = 0.4
const VEGETATION_TRUNK_COLOR := Color(0.32, 0.24, 0.18)
const VEGETATION_FOLIAGE_COLOR := Color(0.22, 0.32, 0.20)

## この特産を持つ都市の周辺は「豊か」な土地として木・低木を茂らせる
## （木材・繊維・皮・羊毛＝生き物由来の資源）。それ以外（鉱石・石材・石炭・
## 水晶・粘土＝鉱物系）は「不毛」とし、植生を減らして岩を代わりに置く。
const FERTILE_SPECIALTIES: Array[String] = ["wood", "fiber", "hide", "wool"]
## 不毛な土地での木・低木の出現閾値の底上げ量。閾値を上げるほど出にくくなる。
const VEGETATION_BARREN_PENALTY: float = 0.5
## 岩がちな土地でのみ置く。木・低木と同程度の頻度になるよう、豊かな土地の
## 閾値とほぼ揃えてある。
const VEGETATION_ROCK_THRESHOLD: float = -0.1
const VEGETATION_ROCK_COLOR := TERRAIN_ROCK_COLOR

## 木・低木・岩は底が平らなメッシュなので、傾斜地にそのまま真上向きで置くと
## 接地面の片側が地面にめり込み、反対側は宙に浮く（ユーザー報告のスクショで
## 実際に両方が同時に見えていた）。地形の局所法線に合わせて傾けることで
## この接地誤差はほぼゼロにできる（実測: 1.0で5cm超のずれが0.2%まで低下）。
##
## ただし木を傾けると、実物の木のように常に上を向いて育つ見え方が失われ、
## 急斜面ほど幹ごと横倒しに近づく（ユーザー指定でこの見た目を避けたいと
## 判明）。そのため向きは常に直立（0.0=無回転）に固定した。
##
## 直立化した当初は急斜面ほど接地面のめり込み・浮きが避けられないため
## 候補地から外していたが（VEGETATION_MAX_SLOPE_NORMAL_Y）、その後に
## 見つかった本当の原因（height_at() と実際の描画メッシュの解像度ミスマッチ、
## terrain_mesh_height_at() 参照）を直したことでめり込み自体が大幅に縮んだ
## ため、この足切りは不要と判断して外した（ユーザー指定）。急斜面での
## 幹の footprint めり込み（半径×tanθ、無回転なので理論上は斜度が急なほど
## 増える）は残るが、terrain_mesh_height_at() 適用後の実測では許容範囲。
const VEGETATION_SLOPE_ALIGNMENT: float = 0.0
## 低木だけはこちら（VEGETATION_SLOPE_ALIGNMENT の代わり）を使う。丈が低く
## 丸いクラスターなので、木のように直立させ続ける理由がない。むしろ斜面に
## 沿わせたほうが茂みらしく自然に見える（ユーザー指定）。1.0（完全追従）に
## すると接地誤差もほぼゼロになる（VEGETATION_SLOPE_ALIGNMENT のコメントの
## 実測値参照）。
const VEGETATION_BUSH_SLOPE_ALIGNMENT: float = 1.0
## 法線を数値微分で求める際のサンプリング幅（水平方向の微小距離）。
const NORMAL_SAMPLE_EPSILON: float = 0.05
## 草木は terrain_mesh_height_at() で描画メッシュの補間値に合わせて設置するが、
## それでも対角線の分割（双線形近似と実際の三角形補間の差）ぶんのわずかな
## ズレは残る。道の LIFT と同じ理由で、保険として少しだけ浮かせる。
const VEGETATION_LIFT: float = 0.03
## 低木だけはこちら（VEGETATION_LIFT の代わり）を使う。VEGETATION_BUSH_
## SLOPE_ALIGNMENT=1.0 で接地誤差はほぼゼロになるが、誤差ゼロだと逆に
## 「地面に乗っているだけ」に見える。少しだけ埋めて、土から生えている
## ように見せる（ユーザー指定）。
const VEGETATION_BUSH_LIFT: float = -0.05

## --- 謎の巨人 ---
## 地形の外周・霧の中に立たせる、動かない2体の巨人。「世界をゲームとして
## 見ている上位存在」というユーザー指定の解釈を、輪郭だけで語れる静止した
## 人型シルエットに落とし込む。都市の柱のような発光や草木のような脈動は
## 付けない（完全に静止させ、不動・無反応の不気味さを出す）。
##
## 平常時は隠しておき、ゲーム終了（60日終了のリザルト画面）でだけ姿を
## 見せる（ユーザー指定）。表示の切り替えは set_giants_visible() で行う。
##
## 配置は地形の半径（半分の一辺）に対する割合で決める。_ring_radius への
## 固定の足し算（旧実装）だと、都市配置が広がった際に地形からはみ出す
## 恐れがあった。1.0 が地形メッシュそのものの縁で、それを超えると
## 描画される地形の外側に出る（height_at() は連続関数なので座標は
## 計算できるが、そこに地面のポリゴンは無い）。ユーザー指定で1.0を
## 超えた値にしてあり、巨人は地形の外・霧の彼方に浮かんでいるように
## 見える想定（「世界の外から見ている上位存在」という設定に寄せた形）。
const GIANT_EDGE_FRACTION: float = 1.2
## 中心から見た向き（度）。180度反対側に置き、カメラを回したときに
## 一体ずつ視界に入るようにする（常に両方同時に見えると威圧感が薄れる）。
const GIANT_ANGLES_DEG: Array[float] = [55.0, 235.0]

## 全高。都市の柱（CITY_HEIGHT=1.5）の160倍。遠景・霧の中に置くぶん、
## 手前の要素と同程度の大きさでは画面上でほぼ点になって存在感が消える
## ため、大幅に引き上げてある（ユーザー指定の「大きさを四倍」で60→240）。
const GIANT_HEIGHT: float = 240.0
## 上半身（胴・腕・頭）だけを作る。脚は作らない（ユーザー指定）。地面の
## ちょうど高さから胴が始まるので、地形の向こうに埋まった巨人の上半身
## だけが地面を突き破って出ているように見える。
const GIANT_TORSO_HEIGHT_RATIO: float = 0.38
const GIANT_HEAD_RADIUS_RATIO: float = 0.085
## 胴回り・腕の太さも GIANT_HEIGHT に対する比率で持たせる。固定値の
## ままだと GIANT_HEIGHT を上げたときに細すぎる棒人間になってしまうため。
const GIANT_SHOULDER_WIDTH_RATIO: float = 0.24
const GIANT_ARM_RADIUS_RATIO: float = 0.032

## 霧に沈むシルエットとして読めるよう、地形のどの色よりも暗く保つ
## （TERRAIN_BASIN_COLOR ですら輝度0.17前後あるのに対しこちらは0.05程度）。
## unshaded にして陰影を持たせない。方向光の当たり方で輪郭の一部だけ
## 明るくなると、「不動の存在」という静けさが崩れるため。
const GIANT_COLOR := Color(0.05, 0.05, 0.07)

## 現在地を囲むリング。内外の二重で描く。
const RING_INNER_RADIUS: float = 1.5
const RING_OUTER_RADIUS: float = 2.1
## 円の分割数。少ないと多角形に見える。
const RING_SEGMENTS: int = 48
## 都市の柱の上に架ける高さ。柱（CITY_HEIGHT）より上に出す。
const RING_LIFT: float = 2.0

## 脈動の周期（秒）。地図を見ている間ずっと動くので、目につかない遅さにする。
const RING_PULSE_PERIOD: float = 2.8
## 脈動で半径が変わる割合。控えめに保つ。
const RING_PULSE_AMOUNT: float = 0.06

var _terrain: MeshInstance3D
var _cities: Dictionary = {}
var _routes: MeshInstance3D
var _selection_ring: MeshInstance3D
## 謎の巨人2体の入れ物。ゲーム終了まで隠しておき、set_giants_visible() で
## まとめて出す。
var _giants: Array[Node3D] = []
## 脈動のためにリングを引き直し続けるので、現在地を覚えておく。
var _ring_city: String = ""
var _pulse_time: float = 0.0
var _noise: FastNoiseLite

## city_id -> Vector3。map_panel がボタンを重ねるのに使う。
var positions: Dictionary = {}


func _init() -> void:
	_build()


func _ready() -> void:
	_build()


func _build() -> void:
	if not _cities.is_empty():
		return
	_noise = FastNoiseLite.new()
	_noise.seed = 20260802
	_noise.frequency = TERRAIN_NOISE_SCALE
	_terrain_margin = (MapCamera.MAX_DISTANCE + TERRAIN_MARGIN_BUFFER) * 2.0

	# 高さ（height_at()）は _basin_radius に依存するため、まず水平面
	# （X-Z）の配置をばね緩和で決め、その広がりから空間定数を算出してから
	# 高さ込みの最終座標を確定させる、という順序を守る必要がある。
	var flat_positions: Dictionary = _relax_positions()
	_compute_scale(flat_positions)
	_compute_positions(flat_positions)
	_build_environment()
	_build_terrain()
	_build_vegetation()
	_build_cities()
	_build_giants()
	_build_routes()
	_build_selection_ring()
	_build_light()


## 空・霧・グロウをまとめた環境設定。own_world_3d の SubViewport 内で
## 完結するので、本編の2D世界には影響しない。
func _build_environment() -> void:
	var environment := Environment.new()

	environment.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = SKY_TOP_COLOR
	sky_material.sky_horizon_color = SKY_HORIZON_COLOR
	sky_material.ground_bottom_color = SKY_GROUND_COLOR
	sky_material.ground_horizon_color = SKY_HORIZON_COLOR
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment.sky = sky

	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = AMBIENT_LIGHT_ENERGY

	# 地形の縁が霧に溶け、閉塞感（黒ゾーンを匂わせる雰囲気）を出す。
	environment.fog_enabled = true
	environment.fog_light_color = SKY_HORIZON_COLOR
	environment.fog_density = FOG_DENSITY

	# 都市の柱・現在地リングは自己発光しているので、グロウで街明かりのように滲む。
	# glow_hdr_threshold はエンジン既定値(1.0)に頼らず明示する。既定が変わると
	# CITY_EMISSION_ENERGY との関係が黙って崩れるため。
	environment.glow_enabled = true
	environment.glow_intensity = GLOW_INTENSITY
	environment.glow_bloom = GLOW_BLOOM
	environment.glow_hdr_threshold = GLOW_HDR_THRESHOLD

	var world_environment := WorldEnvironment.new()
	world_environment.name = "Environment"
	world_environment.environment = environment
	add_child(world_environment)


## 王国都市の水平面(X-Z)配置を、GameData.ROYAL_ROAD_EDGES に沿った決定的な
## ばね緩和で求める（Fruchterman-Reingold 型）。乱数は使わない。
## 中心都市（GameData.CAERLEON）は原点固定で、緩和の対象に含めない。
func _relax_positions() -> Dictionary:
	var ring: Array[String] = GameData.royal_city_ids()
	var flat: Dictionary = {}

	# 初期値は崩壊防止のための単なる仮配置（正円）。緩和で実際の間隔に収束する。
	var seed_radius: float = CITY_SPACING / (2.0 * sin(PI / float(ring.size())))
	for index: int in ring.size():
		var angle: float = -PI / 2.0 + TAU * float(index) / float(ring.size())
		flat[ring[index]] = Vector2(cos(angle), sin(angle)) * seed_radius

	# 次数1（行き止まり）の都市が絡む王道は、綱引きの相手が1本しかない。
	# 通常の引力のままだと反発力に押し負けてカメラの MAX_DISTANCE を大きく
	# 超える位置まで飛ばされる（実測: oakhaven 半径49.8。詳細は下の
	# PENDANT_EDGE_PULL_MULTIPLIER 参照）。
	var degree: Dictionary = {}
	for city_id: String in ring:
		degree[city_id] = 0
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		degree[edge[0]] += 1
		degree[edge[1]] += 1

	var k: float = CITY_SPACING
	for iteration: int in RELAXATION_ITERATIONS:
		var forces: Dictionary = {}
		for city_id: String in ring:
			forces[city_id] = Vector2.ZERO

		# 反発力: 全ペア。近いほど強く押し合う（都市が重なるのを防ぐ）。
		for i: int in ring.size():
			for j: int in range(i + 1, ring.size()):
				var a: String = ring[i]
				var b: String = ring[j]
				var delta: Vector2 = flat[a] - flat[b]
				var dist: float = maxf(delta.length(), 0.01)
				var push: Vector2 = delta.normalized() * (k * k / dist)
				forces[a] += push
				forces[b] -= push

		# 引力: 王道でつながる都市どうしのみ。離れているほど強く引き合う。
		for edge: Array in GameData.ROYAL_ROAD_EDGES:
			var a: String = edge[0]
			var b: String = edge[1]
			var delta: Vector2 = flat[b] - flat[a]
			var dist: float = maxf(delta.length(), 0.01)
			var strength: float = PENDANT_EDGE_PULL_MULTIPLIER \
				if (degree[a] == 1 or degree[b] == 1) else 1.0
			var pull: Vector2 = delta.normalized() * (dist * dist / k) * strength
			forces[a] += pull
			forces[b] -= pull

		# 中心からの半径を大まかに一定へ寄せる、弱い求心力。
		for city_id: String in ring:
			var radius: float = flat[city_id].length()
			if radius > 0.01:
				forces[city_id] -= flat[city_id].normalized() * (radius - seed_radius) * CENTERING_STRENGTH

		# 温度を反復とともに線形に冷やし、1回の移動量に上限をかける
		# （発散を防ぎ、後半の反復ほど収束に近づく）。
		var temperature: float = RELAXATION_INITIAL_TEMPERATURE * (1.0 - float(iteration) / float(RELAXATION_ITERATIONS))
		for city_id: String in ring:
			var force: Vector2 = forces[city_id]
			var magnitude: float = force.length()
			if magnitude > 0.01:
				flat[city_id] += force.normalized() * minf(magnitude, temperature)

	flat[GameData.CAERLEON] = Vector2.ZERO
	return flat


## 緩和後の実際の座標の広がりから空間定数を算出する
## （環のような閉形式の計算はせず、実測値から地形・盆地の大きさを決める）。
func _compute_scale(flat_positions: Dictionary) -> void:
	var max_radius: float = 0.0
	for city_id: String in flat_positions:
		max_radius = maxf(max_radius, flat_positions[city_id].length())
	_ring_radius = max_radius
	_terrain_size = _ring_radius * 2.0 + _terrain_margin
	_basin_radius = _ring_radius + BASIN_MARGIN
	# PlaneMesh(subdivide_width=N) は N+1 マス（N+2 頂点）を生成する
	# （Godot 4.7.1で実測確認済み。Nをそのままマス数として扱うと1マスぶん
	# 過大評価してマス目がずれる）。
	_terrain_subdivisions = maxi(1, ceili(_terrain_size / TERRAIN_MAX_QUAD_SIZE) - 1)


## 緩和済みの水平面座標に高さ（height_at()）を足して最終的な 3D 座標にする。
func _compute_positions(flat_positions: Dictionary) -> void:
	for city_id: String in flat_positions:
		var p: Vector2 = flat_positions[city_id]
		positions[city_id] = Vector3(p.x, height_at(p.x, p.y), p.y)


## その地点の地面の高さ。都市も経路もこれに沿わせる。
func height_at(x: float, z: float) -> float:
	var h: float = _noise.get_noise_2d(x, z) * TERRAIN_HEIGHT
	# 中央を掘り下げる。レイヴンスパイアが盆地の底になり、
	# 外周の王国都市がそれを囲む地形として読める。
	var distance: float = Vector2(x, z).length()
	var basin: float = clampf(1.0 - distance / _basin_radius, 0.0, 1.0)
	return h - basin * basin * BASIN_DEPTH


func _build_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(_terrain_size, _terrain_size)
	plane.subdivide_width = _terrain_subdivisions
	plane.subdivide_depth = _terrain_subdivisions

	# 頂点を高さで動かして起伏を作る。
	var arrays: Array = plane.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i: int in vertices.size():
		var v: Vector3 = vertices[i]
		vertices[i] = Vector3(v.x, height_at(v.x, v.z), v.z)
	arrays[Mesh.ARRAY_VERTEX] = vertices

	# 法線を引き直さないと陰影が平らに見える。
	_recalculate_normals(arrays)

	# 傾斜（法線）と中心からの距離（盆地との近さ）から頂点カラーを塗る。
	# 法線再計算の後でないと傾斜が求まらないので、この順序を守ること。
	_assign_terrain_colors(arrays)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.metallic = 0.0
	mesh.surface_set_material(0, material)

	_terrain = MeshInstance3D.new()
	_terrain.name = "Terrain"
	_terrain.mesh = mesh
	add_child(_terrain)


## 高さ（盆地への近さ）と傾斜から頂点カラーを塗る。
## 盆地に近いほど TERRAIN_BASIN_COLOR、外周に近いほど TERRAIN_UPLAND_COLOR
## を基調にし、急斜面ほど TERRAIN_ROCK_COLOR を混ぜる。続けて、最寄りの
## 王国都市の特産色を近いほど強くにじませ（バイオーム。危険地帯の盆地色を
## 覆い隠さないよう basin の外側でのみ効かせる）、さらに配置の広がり
## （_ring_radius）を超えたあたりから地形の縁に向けて空の色（霧と同じ色）
## へフェードさせ、縁が定規で切ったような直線に見えないようにする
## （アルファ透過は使わない。頂点カラーの補間だけで済ませる）。
func _assign_terrain_colors(arrays: Array) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors := PackedColorArray()
	colors.resize(vertices.size())

	var half_extent: float = _terrain_size * 0.5
	for i: int in vertices.size():
		var v: Vector3 = vertices[i]
		var distance_from_center: float = Vector2(v.x, v.z).length()

		# height_at() の basin と同じ考え方（中心に近いほど1.0）。
		var basin: float = clampf(1.0 - distance_from_center / _basin_radius, 0.0, 1.0)
		var base: Color = TERRAIN_BASIN_COLOR.lerp(TERRAIN_UPLAND_COLOR, 1.0 - basin)
		var slope: float = clampf(1.0 - normals[i].y, 0.0, 1.0)
		var color: Color = base.lerp(TERRAIN_ROCK_COLOR, slope * 0.6)

		var biome: Dictionary = _nearest_biome(Vector2(v.x, v.z))
		var biome_t: float = clampf(1.0 - biome["distance"] / BIOME_INFLUENCE_RADIUS, 0.0, 1.0)
		color = color.lerp(biome["color"], biome_t * (1.0 - basin))

		var edge_t: float = clampf(
			(distance_from_center - _ring_radius) / (half_extent - _ring_radius), 0.0, 1.0)
		colors[i] = color.lerp(SKY_HORIZON_COLOR, edge_t)

	arrays[Mesh.ARRAY_COLOR] = colors


## 水平面上でその地点に最も近い王国都市（レイヴンスパイアは対象外。中心の
## 危険地帯は既存の盆地色がそのまま担う）と、その特産資源の色を返す。
## 地形の色にも植生の豊か/不毛の判定にも使う共通のバイオーム判定。
func _nearest_biome(point: Vector2) -> Dictionary:
	var nearest_id: String = ""
	var nearest_distance: float = INF
	for city_id: String in GameData.royal_city_ids():
		var city_pos: Vector3 = positions[city_id]
		var distance: float = point.distance_to(Vector2(city_pos.x, city_pos.z))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_id = city_id

	var specialty: String = GameData.CITIES[nearest_id]["specialty"]
	return {
		"city_id": nearest_id,
		"color": UiTheme.item_color(specialty).darkened(BIOME_COLOR_DARKEN),
		"distance": nearest_distance,
	}


## 頂点を動かした後の法線を求め直す。面の向きから平均する。
func _recalculate_normals(arrays: Array) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normals := PackedVector3Array()
	normals.resize(vertices.size())

	var i: int = 0
	while i + 2 < indices.size():
		var a: int = indices[i]
		var b: int = indices[i + 1]
		var c: int = indices[i + 2]
		# 外積の順序に注意。逆にすると法線が下を向き、地面が裏返って
		# 光が当たらず真っ黒になる。
		var face: Vector3 = (vertices[c] - vertices[a]).cross(
			vertices[b] - vertices[a])
		normals[a] += face
		normals[b] += face
		normals[c] += face
		i += 3

	for j: int in normals.size():
		normals[j] = normals[j].normalized() if normals[j].length() > 0.0 else Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = normals


func _build_cities() -> void:
	for city_id: String in positions:
		var container := Node3D.new()
		container.name = city_id
		container.position = positions[city_id]
		add_child(container)
		_cities[city_id] = container

		for part: MeshInstance3D in _city_structure_parts(city_id):
			container.add_child(part)


## 都市ごとの構造物（土台＋尖塔）を組み立てる。真の乱数は使わず、city_id の
## ハッシュから決定的にばらつきを付ける（同じ都市は毎回同じ見た目になる。
## --script 検査と save/load の再現性を壊さないため）。
func _city_structure_parts(city_id: String) -> Array[MeshInstance3D]:
	var color: Color = _city_color(city_id)
	var is_hub: bool = city_id == GameData.CAERLEON
	var parts: Array[MeshInstance3D] = []

	# 土台。中心都市は少しだけ太くする。
	var base_height: float = CITY_HEIGHT * CITY_BASE_HEIGHT_RATIO
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = CITY_RADIUS * (0.85 if is_hub else 0.75)
	base_mesh.bottom_radius = CITY_RADIUS * (1.3 if is_hub else 1.0)
	base_mesh.height = base_height
	base_mesh.radial_segments = 6
	var base: MeshInstance3D = _make_city_part(base_mesh, color)
	base.position = Vector3(0.0, base_height * 0.5, 0.0)
	parts.append(base)

	# 尖塔。中心都市は本数を増やして密集させる（高さの予算は他都市と共通。
	# CITY_HEIGHT を超えると現在地リングにめり込むため、本数を増やしても
	# 個々の高さはほぼ揃えたままにする）。
	var spire_count: int = CAERLEON_SPIRE_COUNT if is_hub \
		else CITY_SPIRE_MIN + int(city_id.hash() % (CITY_SPIRE_MAX - CITY_SPIRE_MIN + 1))
	var spire_height: float = (CITY_HEIGHT - base_height) * CITY_SPIRE_HEIGHT_RATIO
	var cluster_radius: float = CITY_RADIUS * 0.4

	for i: int in spire_count:
		var spire_mesh := CylinderMesh.new()
		spire_mesh.top_radius = CITY_RADIUS * 0.12
		spire_mesh.bottom_radius = CITY_RADIUS * 0.3
		spire_mesh.height = spire_height
		spire_mesh.radial_segments = 6
		var spire: MeshInstance3D = _make_city_part(spire_mesh, color)
		# 複数本あるときは土台の中心周りに均等配置する（決定的、乱数不使用）。
		var angle: float = TAU * float(i) / float(spire_count)
		var offset: Vector2 = Vector2.ZERO if spire_count == 1 \
			else Vector2(cos(angle), sin(angle)) * cluster_radius
		spire.position = Vector3(offset.x, base_height + spire_height * 0.5, offset.y)
		parts.append(spire)

	return parts


## パーツ1つぶんの MeshInstance3D を作る。マテリアルは自己発光つき
## （暗い地形の中でも都市が目立つように。グロウで街明かりのように滲む）。
func _make_city_part(mesh: Mesh, color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.6
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = CITY_EMISSION_ENERGY
	mesh.surface_set_material(0, material)

	var part := MeshInstance3D.new()
	part.mesh = mesh
	return part


static func _city_color(city_id: String) -> Color:
	if city_id == GameData.CAERLEON:
		return UiTheme.WARN
	return UiTheme.PIN_FRAME


## 謎の巨人を2体、地形の外周・霧の中に立たせる。中心（レイヴンスパイア）の
## 方を向かせ、世界を見下ろしているように見せる。ゲーム終了までは隠す
## （set_giants_visible() 参照。ユーザー指定で「ゲーム終了時に表示」）。
func _build_giants() -> void:
	var center: Vector3 = positions[GameData.CAERLEON]
	var radius: float = (_terrain_size * 0.5) * GIANT_EDGE_FRACTION
	_giants.clear()
	for index: int in GIANT_ANGLES_DEG.size():
		var angle: float = deg_to_rad(GIANT_ANGLES_DEG[index])
		var x: float = cos(angle) * radius
		var z: float = sin(angle) * radius
		var base: Vector3 = Vector3(x, height_at(x, z), z)

		var container := Node3D.new()
		container.name = "Giant%d" % index
		container.position = base
		# look_at() はツリー外で global_transform が更新されず使えない
		# （CLAUDE.md参照）。look_at_from_position() はローカル transform を
		# 直接組むので、--script のハーネスでも同じ向きになる。
		container.look_at_from_position(base, Vector3(center.x, base.y, center.z), Vector3.UP)
		container.visible = false
		add_child(container)
		_giants.append(container)

		for part: MeshInstance3D in _giant_parts():
			container.add_child(part)


## 巨人の表示・非表示をまとめて切り替える。main.gd の _refresh_status() が
## GameSession.is_over()（60日終了）と同期させる、唯一の公開入口。
func set_giants_visible(value: bool) -> void:
	for giant: Node3D in _giants:
		if is_instance_valid(giant):
			giant.visible = value


## 巨人1体ぶんの上半身パーツ（胴・腕2・頭）を組み立てる。脚は作らない
## （ユーザー指定。地面のちょうど高さから胴が始まるので、地形の向こうに
## 埋まった巨人の上半身だけが突き出ているように見える）。
## 都市の構造物と同じく円柱主体だが、こちらは発光させない
## （不動・無反応の存在として、都市の生きた明かりと対照させる）。
func _giant_parts() -> Array[MeshInstance3D]:
	var parts: Array[MeshInstance3D] = []
	var torso_height: float = GIANT_HEIGHT * GIANT_TORSO_HEIGHT_RATIO
	var head_radius: float = GIANT_HEIGHT * GIANT_HEAD_RADIUS_RATIO
	var shoulder_width: float = GIANT_HEIGHT * GIANT_SHOULDER_WIDTH_RATIO
	var arm_radius: float = GIANT_HEIGHT * GIANT_ARM_RADIUS_RATIO
	var sides: Array[float] = [-1.0, 1.0]

	# 胴は地面（y=0）から生やす。下端が地形の内側に隠れている想定なので、
	# 下細り（下の方が太い一般的な胴のシルエット）にはせず、地面から
	# 均等な太さで突き出た円柱にする。
	var torso := CylinderMesh.new()
	torso.top_radius = shoulder_width * 0.5
	torso.bottom_radius = shoulder_width * 0.5
	torso.height = torso_height
	torso.radial_segments = 8
	var torso_part: MeshInstance3D = _make_giant_part(torso)
	torso_part.position = Vector3(0.0, torso_height * 0.5, 0.0)
	parts.append(torso_part)

	var arm_height: float = torso_height * 0.75
	for side: float in sides:
		var arm := CylinderMesh.new()
		arm.top_radius = arm_radius
		arm.bottom_radius = arm_radius * 0.85
		arm.height = arm_height
		arm.radial_segments = 6
		var arm_part: MeshInstance3D = _make_giant_part(arm)
		arm_part.position = Vector3(
			side * shoulder_width * 0.62, torso_height - arm_height * 0.5, 0.0)
		parts.append(arm_part)

	var head := SphereMesh.new()
	head.radius = head_radius
	head.height = head_radius * 2.0
	head.radial_segments = 10
	head.rings = 6
	var head_part: MeshInstance3D = _make_giant_part(head)
	head_part.position = Vector3(0.0, torso_height + head_radius * 0.85, 0.0)
	parts.append(head_part)

	return parts


## パーツ1つぶんの MeshInstance3D。GIANT_COLOR 固定・unshaded・発光なし
## （都市パーツの _make_city_part() と違い、光らせない）。
func _make_giant_part(mesh: Mesh) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = GIANT_COLOR
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.surface_set_material(0, material)

	var part := MeshInstance3D.new()
	part.mesh = mesh
	return part


## 草木を決定的にばら撒く。真の乱数は使わず、_noise から得られる値だけで
## 密度・位置を決める（都市構造物の city_id.hash() と同じ理由: 再現性・
## --script 検査との整合）。盆地（黒ゾーン寄り）・都市・道の近くには
## 生やさない。個体ごとに MeshInstance3D は作らず、MultiMeshInstance3D で
## まとめて複製する（数百本規模になりうるため描画負荷を抑える）。
func _build_vegetation() -> void:
	var tree_transforms: Array[Transform3D] = []
	var bush_transforms: Array[Transform3D] = []
	var rock_transforms: Array[Transform3D] = []

	var half_extent: float = _ring_radius + VEGETATION_OUTER_MARGIN
	var x: float = -half_extent
	while x < half_extent:
		var z: float = -half_extent
		while z < half_extent:
			# 格子点そのままだと不自然に整列して見えるので、ノイズで
			# 決定的にジッターさせる。
			var jitter_x: float = _noise.get_noise_2d(x * 4.0 + 13.0, z * 4.0 + 71.0) * VEGETATION_GRID_STEP * 0.5
			var jitter_z: float = _noise.get_noise_2d(x * 4.0 + 71.0, z * 4.0 + 13.0) * VEGETATION_GRID_STEP * 0.5
			var px: float = x + VEGETATION_GRID_STEP * 0.5 + jitter_x
			var pz: float = z + VEGETATION_GRID_STEP * 0.5 + jitter_z

			if is_vegetation_site(px, pz):
				var biome: Dictionary = _nearest_biome(Vector2(px, pz))
				var fertile: bool = FERTILE_SPECIALTIES.has(GameData.CITIES[biome["city_id"]]["specialty"])
				var density: float = _noise.get_noise_2d(px * 0.6, pz * 0.6)
				# 個体ごとの見た目のばらつき（大きさ・向き）。ローカル空間側で
				# かけるので、木・低木で異なる傾き（alignment）とは独立に効く。
				var decoration: Transform3D = _vegetation_decoration_at(px, pz)

				# 不毛な土地は木・低木の閾値を大きく引き上げてまばらにし、
				# 代わりに岩を同程度の頻度でばら撒く。
				var penalty: float = 0.0 if fertile else VEGETATION_BARREN_PENALTY
				var bush_threshold: float = VEGETATION_BUSH_THRESHOLD + penalty
				var tree_threshold: float = VEGETATION_TREE_THRESHOLD + penalty

				if density > bush_threshold:
					if density > tree_threshold:
						tree_transforms.append(vegetation_transform_at(px, pz) * decoration)
					else:
						bush_transforms.append(
							vegetation_transform_at(px, pz, VEGETATION_BUSH_SLOPE_ALIGNMENT, VEGETATION_BUSH_LIFT)
							* decoration)
				elif not fertile and density > VEGETATION_ROCK_THRESHOLD:
					rock_transforms.append(vegetation_transform_at(px, pz) * decoration)
			z += VEGETATION_GRID_STEP
		x += VEGETATION_GRID_STEP

	_add_vegetation_multimesh(_make_tree_trunk_mesh(), tree_transforms, "TreeTrunks")
	_add_vegetation_multimesh(_make_tree_foliage_mesh(), tree_transforms, "TreeFoliage")
	_add_vegetation_multimesh(_make_bush_mesh(), bush_transforms, "Bushes")
	_add_vegetation_multimesh(_make_rock_mesh(), rock_transforms, "Rocks")


## その地点の草木1個体ぶんの見た目のばらつき（大きさ・Y軸回りの向き）を
## ローカル空間のトランスフォームとして返す。全個体が同じ大きさ・同じ向きだと
## 量産品のように見えるため、_noise を位置ジッターや密度判定とは別の
## オフセット・周波数でサンプリングして決定的に散らす（真の乱数は使わない。
## 都市構造物の city_id.hash() と同じ理由）。原点はゼロのままなので、
## vegetation_transform_at() が決める設置位置には影響しない
## （拡大縮小・回転はどちらも原点を動かさない）。
##
## 岩（PrismMesh、四角い断面）は向きの効果がとくに大きい。木・低木は円柱で
## 見た目上ほぼ回転対称だが、コストが小さいため同じ処理で揃えている。
func _vegetation_decoration_at(x: float, z: float) -> Transform3D:
	var scale_noise: float = _noise.get_noise_2d(x * 2.0 + 137.0, z * 2.0 + 253.0)
	var scale: float = lerpf(0.82, 1.22, (scale_noise + 1.0) * 0.5)
	var rotation_noise: float = _noise.get_noise_2d(x * 3.0 + 401.0, z * 3.0 + 601.0)
	var angle: float = (rotation_noise + 1.0) * 0.5 * TAU
	var basis := Basis(Vector3.UP, angle).scaled(Vector3.ONE * scale)
	return Transform3D(basis, Vector3.ZERO)


## その地点の設置トランスフォームを、局所法線に alignment の割合だけ
## 合わせて傾けて返す。省略時は VEGETATION_SLOPE_ALIGNMENT / VEGETATION_LIFT
## （現状0.0固定で常に直立。木・岩はこちら。詳細はコメント参照）。低木だけは
## VEGETATION_BUSH_SLOPE_ALIGNMENT / VEGETATION_BUSH_LIFT を明示的に渡す
## （_build_vegetation() 参照。丈が低く丸いクラスターなので、木と違って
## 傾けても倒れたようには見えない。LIFT を負にして少し埋め、土から生えて
## いるように見せる）。
##
## 公開しているのは、pulse_scale_at() と同じ理由で --script の検査から
## 直接確かめられるようにするため（内部状態を持たない純関数）。
func vegetation_transform_at(x: float, z: float, alignment: float = VEGETATION_SLOPE_ALIGNMENT,
		lift: float = VEGETATION_LIFT) -> Transform3D:
	var normal: Vector3 = terrain_normal_at(x, z)
	var axis: Vector3 = Vector3.UP.cross(normal)
	var basis := Basis()
	if axis.length() > 0.0001:
		var tilt := Basis(axis.normalized(), Vector3.UP.angle_to(normal))
		basis = Basis().slerp(tilt, alignment)
	var y: float = terrain_mesh_height_at(x, z) + lift
	return Transform3D(basis, Vector3(x, y, z))


## height_at() は連続関数だが、実際に描画される地形は _terrain_subdivisions
## 分割の平面メッシュ（1辺あたり _terrain_size / (_terrain_subdivisions+1) の
## 格子）で、頂点間は補間される。固定64分割だった頃は現在の地形の広さ
## （都市配置の拡張で1辺100超）に対して格子が粗すぎ（1マス約2.9、草木の
## 間隔1.4より広い）、格子1マスの中で height_at() の細かい起伏（ノイズの
## オクターブ由来）が何度も上下していた。height_at() をそのまま使うと草木が
## 「実際に描画されている地面」とズレた高さに置かれ、実測でトランク底面の縁の
## 9割以上が VEGETATION_LIFT(0.03) を超えてズレていた（浮き沈みの主因）。
## _terrain_subdivisions を TERRAIN_MAX_QUAD_SIZE 基準の動的値にしたことで
## 大きく改善したが、対角線の分割ぶんの残差は VEGETATION_LIFT で吸収する。
##
## この関数は height_at() を格子の4頂点でだけサンプリングし、実際の描画と
## 同じ格子間隔で双線形補間する。草木の設置高さはこちらを使うことで、
## 描画されている地形の起伏に沿う。
##
## 地形メッシュの1マスの一辺の実際の長さ。TERRAIN_MAX_QUAD_SIZE 以下になる
## はず（_compute_scale() が _terrain_subdivisions をそう決めている）。
## PlaneMesh(subdivide_width=N) は N+1 マスを生成する
## （Godot 4.7.1で実測確認済み。N をそのままマス数として使うと格子がずれる）。
func terrain_quad_size() -> float:
	return _terrain_size / float(_terrain_subdivisions + 1)


## 公開しているのは、pulse_scale_at() と同じ理由で --script の検査から
## 直接確かめられるようにするため（内部状態を持たない純関数）。
func terrain_mesh_height_at(x: float, z: float) -> float:
	var segments: int = _terrain_subdivisions + 1
	var quad: float = terrain_quad_size()
	var half: float = _terrain_size * 0.5
	var gx: float = clampf((x + half) / quad, 0.0, float(segments))
	var gz: float = clampf((z + half) / quad, 0.0, float(segments))
	var ix: int = clampi(int(gx), 0, segments - 1)
	var iz: int = clampi(int(gz), 0, segments - 1)
	var fx: float = gx - float(ix)
	var fz: float = gz - float(iz)

	var vx0: float = -half + float(ix) * quad
	var vx1: float = vx0 + quad
	var vz0: float = -half + float(iz) * quad
	var vz1: float = vz0 + quad

	var h00: float = height_at(vx0, vz0)
	var h10: float = height_at(vx1, vz0)
	var h01: float = height_at(vx0, vz1)
	var h11: float = height_at(vx1, vz1)

	var h0: float = lerpf(h00, h10, fx)
	var h1: float = lerpf(h01, h11, fx)
	return lerpf(h0, h1, fz)


## その地点の地形の法線を、height_at() の中心差分で求める。
## _recalculate_normals() はメッシュの頂点・インデックスから面法線を求めるが、
## こちらは任意の連続座標に対して height_at() を直接サンプリングする版
## （草木は地形メッシュの頂点に乗っているとは限らないため）。
func terrain_normal_at(x: float, z: float) -> Vector3:
	var h_left: float = height_at(x - NORMAL_SAMPLE_EPSILON, z)
	var h_right: float = height_at(x + NORMAL_SAMPLE_EPSILON, z)
	var h_back: float = height_at(x, z - NORMAL_SAMPLE_EPSILON)
	var h_front: float = height_at(x, z + NORMAL_SAMPLE_EPSILON)
	return Vector3(h_left - h_right, 2.0 * NORMAL_SAMPLE_EPSILON, h_back - h_front).normalized()


## 木・低木を生やしてよい候補地か。盆地・都市・道・急斜面には生やさない。
##
## 公開しているのは、pulse_scale_at() と同じ理由で --script の検査から
## 直接確かめられるようにするため（内部状態を持たない純関数）。
func is_vegetation_site(x: float, z: float) -> bool:
	var point := Vector2(x, z)

	# height_at() の basin と同じ考え方（中心に近いほど1.0）。
	var basin: float = clampf(1.0 - point.length() / _basin_radius, 0.0, 1.0)
	if basin > VEGETATION_BASIN_LIMIT:
		return false

	for city_id: String in positions:
		var city_pos: Vector3 = positions[city_id]
		if point.distance_to(Vector2(city_pos.x, city_pos.z)) < VEGETATION_CITY_CLEARANCE:
			return false

	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		var a: Vector3 = positions[edge[0]]
		var b: Vector3 = positions[edge[1]]
		if _distance_to_segment(point, Vector2(a.x, a.z), Vector2(b.x, b.z)) < VEGETATION_ROAD_CLEARANCE:
			return false

	var center: Vector3 = positions[GameData.CAERLEON]
	for gate: String in GameData.BLACK_ZONE_GATES:
		var gate_pos: Vector3 = positions[gate]
		if _distance_to_segment(point, Vector2(gate_pos.x, gate_pos.z), Vector2(center.x, center.z)) < VEGETATION_ROAD_CLEARANCE:
			return false

	return true


## 点と線分の最短距離（水平面）。道からの距離判定に使う。
func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var length_sq: float = ab.length_squared()
	if length_sq < 0.0001:
		return point.distance_to(a)
	var t: float = clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)


## 木の幹のメッシュ。幹と葉は別々の MultiMeshInstance3D にする
## （1つの ArrayMesh に2サーフェス＋別マテリアルで持たせて MultiMesh化すると、
## 幹（サーフェス0）が描画されず葉だけになる不具合が実機で発生したため。
## bush/rock は元々単一サーフェスで問題が出ていなかった）。
func _make_tree_trunk_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()

	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.05
	trunk.bottom_radius = 0.08
	trunk.height = 0.5
	trunk.radial_segments = 6
	_append_primitive_surface(mesh, trunk, Vector3(0.0, 0.25, 0.0), VEGETATION_TRUNK_COLOR)

	return mesh


## 木の葉のメッシュ。_make_tree_trunk_mesh() と同じ transforms で重ねて描く。
func _make_tree_foliage_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()

	var foliage := CylinderMesh.new()
	foliage.top_radius = 0.0
	foliage.bottom_radius = 0.32
	foliage.height = 0.65
	foliage.radial_segments = 8
	_append_primitive_surface(mesh, foliage, Vector3(0.0, 0.75, 0.0), VEGETATION_FOLIAGE_COLOR)

	return mesh


## 低木のメッシュ（葉のみ、木より小さい）。単一の半球だと輪郭が単調で
## 「丸いだけ」に見えたため、小さな球を4つ重ねたクラスターにして輪郭を
## 凸凹させ、ふわふわした茂みらしさを出す。
##
## 4つとも同じ ArrayMesh の1サーフェスへ頂点をマージする
## （_merge_primitive_into() 参照）。_append_primitive_surface() のように
## 呼ぶたびに新しいサーフェスを足す形にすると、MultiMeshInstance3D で
## 幹だけ描画されなかった不具合（複数サーフェス＋複数マテリアルが原因）を
## 再現しかねないため、あえて単一サーフェス・単一マテリアルで組む。
func _make_bush_mesh() -> ArrayMesh:
	var accum := {
		"vertices": PackedVector3Array(), "normals": PackedVector3Array(), "indices": PackedInt32Array(),
	}

	# SphereMesh は高さ方向 ±height/2 の範囲で生成される（半径基準ではない。
	# height を 2*radius からずらすと扁平な球になる）ので、底を y=0 に
	# 揃えるオフセットは height/2 を使うこと（radius だと球が沈む）。
	var center_radius: float = 0.15
	var center_height: float = center_radius * 1.7
	var center := SphereMesh.new()
	center.radius = center_radius
	center.height = center_height
	center.radial_segments = 7
	center.rings = 4
	_merge_primitive_into(accum, center, Vector3(0.0, center_height * 0.5, 0.0))

	# 中心球の周りに少し小さい球を3つ、重なる位置に置く。真の乱数は使わず
	# 固定配置にする（大きさ・向きのばらつきは _vegetation_decoration_at() が
	# 個体ごとに別途かけるため、クラスター自体の形は全個体で共通でよい）。
	var satellite_radius: float = 0.12
	var satellite_height: float = satellite_radius * 1.7
	var satellite_horizontal_offsets: Array[Vector2] = [
		Vector2(0.10, 0.0),
		Vector2(-0.06, 0.09),
		Vector2(-0.06, -0.09),
	]
	for h: Vector2 in satellite_horizontal_offsets:
		var satellite := SphereMesh.new()
		satellite.radius = satellite_radius
		satellite.height = satellite_height
		satellite.radial_segments = 6
		satellite.rings = 3
		_merge_primitive_into(accum, satellite, Vector3(h.x, satellite_height * 0.5, h.y))

	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = accum["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = accum["normals"]
	arrays[Mesh.ARRAY_INDEX] = accum["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.albedo_color = VEGETATION_FOLIAGE_COLOR
	material.roughness = 0.9
	mesh.surface_set_material(0, material)

	return mesh


## 岩のメッシュ。不毛な土地（鉱物系の特産を持つ都市の周辺）で木・低木の
## 代わりに置く。角錐に近い低いシルエットにして、木と見分けが付くようにする。
func _make_rock_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()

	var rock := PrismMesh.new()
	rock.size = Vector3(0.4, 0.28, 0.32)
	_append_primitive_surface(mesh, rock, Vector3(0.0, 0.14, 0.0), VEGETATION_ROCK_COLOR)

	return mesh


## source の形状を position だけずらして target の新しいサーフェスとして
## 追加する。単色のパーツなので頂点カラーではなく専用マテリアルで塗る。
func _append_primitive_surface(target: ArrayMesh, source: PrimitiveMesh, offset: Vector3, color: Color) -> void:
	var arrays: Array = source.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i: int in vertices.size():
		vertices[i] += offset
	arrays[Mesh.ARRAY_VERTEX] = vertices

	target.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	target.surface_set_material(target.get_surface_count() - 1, material)


## source の形状を position だけずらして accum（vertices/normals/indices の
## Dictionary）へ頂点データとして追加する。_append_primitive_surface() と
## 違い、新しいサーフェスは作らず既存の1サーフェスへ merge する。
## indices は accum に既に入っている頂点数ぶんオフセットしないと、
## 結合後の配列で別の形状の頂点を指してしまうことに注意。
func _merge_primitive_into(accum: Dictionary, source: PrimitiveMesh, offset: Vector3) -> void:
	var arrays: Array = source.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var base_index: int = accum["vertices"].size()
	for v: Vector3 in vertices:
		accum["vertices"].append(v + offset)
	for n: Vector3 in normals:
		accum["normals"].append(n)
	for idx: int in indices:
		accum["indices"].append(idx + base_index)


## transforms ぶんの木/低木を MultiMeshInstance3D として複製する。
func _add_vegetation_multimesh(mesh: ArrayMesh, transforms: Array[Transform3D], node_name: String) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i: int in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])

	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	add_child(instance)


## 道の幅（3D 空間の単位）。
const ROAD_WIDTH: float = 0.5
## 黒ゾーンの道は細めにして、王道と見分けが付くようにする。
const BLACK_ZONE_ROAD_WIDTH: float = 0.32
const ROAD_COLOR := Color(0.45, 0.42, 0.36)

## 経路を地形の上に沿わせて描く、幅を持った帯（道）。
## 王道は連続した帯、黒ゾーンは切れ目のある帯にして、2D 版と同じ
## 実線／破線の区別を保つ。黒ゾーンの帯は GameData.BLACK_ZONE_GATES の
## 都市からのみ引く（それ以外の王国都市は中心都市と直結していない）。
func _build_routes() -> void:
	# 各区間は _build_road_ribbon() が自前の配列を組んで返す
	# （PackedArray を関数の引数越しに書き換えても呼び出し元には反映されない
	# ことがあるため、必ず戻り値で受け取って呼び出し側でつなぎ合わせる）。
	var segments: Array[Dictionary] = []
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		segments.append(_build_road_ribbon(positions[edge[0]], positions[edge[1]],
			ROAD_WIDTH, ROAD_COLOR, false))

	var center: Vector3 = positions[GameData.CAERLEON]
	for city_id: String in GameData.BLACK_ZONE_GATES:
		segments.append(_build_road_ribbon(positions[city_id], center,
			BLACK_ZONE_ROAD_WIDTH, UiTheme.WARN, true))

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for segment: Dictionary in segments:
		var offset: int = vertices.size()
		vertices.append_array(segment["vertices"])
		normals.append_array(segment["normals"])
		colors.append_array(segment["colors"])
		for idx: int in segment["indices"]:
			indices.append(idx + offset)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	# 三角形の巻き順を厳密に合わせなくても両面とも描画されるようにする
	# （このファイルで一度踏んだ「外積の順序」の落とし穴を避けるため）。
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)

	_routes = MeshInstance3D.new()
	_routes.name = "Routes"
	_routes.mesh = mesh
	add_child(_routes)


## from_point から to_point まで、地形に沿った帯（道）1区間ぶんの頂点・法線・
## 色・インデックスを組み立てて返す。dashed なら区切って破線状の帯にする。
## インデックスはこの帯の中だけで0始まり（呼び出し側で全体の頂点配列に
## つなぎ合わせる際にオフセットする）。
func _build_road_ribbon(from_point: Vector3, to_point: Vector3, width: float,
		color: Color, dashed: bool) -> Dictionary:
	const STEPS: int = 24
	const LIFT: float = 0.08

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var direction: Vector2 = Vector2(to_point.x - from_point.x, to_point.z - from_point.z)
	if direction.length() < 0.001:
		return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices}
	direction = direction.normalized()
	# 進行方向に対して垂直な向き（水平面）。帯の左右の縁をこれで作る。
	var right: Vector2 = Vector2(-direction.y, direction.x) * (width * 0.5)

	for i: int in STEPS:
		if dashed and i % 2 == 1:
			continue
		var t0: float = float(i) / float(STEPS)
		var t1: float = float(i + 1) / float(STEPS)
		var c0: Vector3 = from_point.lerp(to_point, t0)
		var c1: Vector3 = from_point.lerp(to_point, t1)
		# 地面にめり込まないよう、その地点の高さに合わせて少し浮かせる。
		c0.y = height_at(c0.x, c0.z) + LIFT
		c1.y = height_at(c1.x, c1.z) + LIFT

		var base_index: int = vertices.size()
		vertices.append(c0 + Vector3(-right.x, 0.0, -right.y))
		vertices.append(c0 + Vector3(right.x, 0.0, right.y))
		vertices.append(c1 + Vector3(-right.x, 0.0, -right.y))
		vertices.append(c1 + Vector3(right.x, 0.0, right.y))
		for j: int in 4:
			normals.append(Vector3.UP)
			colors.append(color)
		indices.append(base_index)
		indices.append(base_index + 1)
		indices.append(base_index + 2)
		indices.append(base_index + 1)
		indices.append(base_index + 3)
		indices.append(base_index + 2)

	return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices}


## 現在地を囲むリング。入れ物だけ先に作り、中身は到着のたびに引き直す。
func _build_selection_ring() -> void:
	_selection_ring = MeshInstance3D.new()
	_selection_ring.name = "SelectionRing"
	_selection_ring.mesh = ImmediateMesh.new()
	add_child(_selection_ring)


## 脈動させる。地図を見ている間ずっと動くので、変化幅は小さく保つ。
func _process(delta: float) -> void:
	if _ring_city == "" or not is_instance_valid(_selection_ring):
		return
	if not _selection_ring.visible:
		return
	_pulse_time += delta
	_redraw_selection_ring(positions[_ring_city], pulse_scale())


## 経過時間に対する半径の倍率。1.0 を中心にゆっくり上下する。
##
## 内部状態を持たない純関数にしてあるのは、位相ごとの振る舞いを
## --script の検査から直接確かめられるようにするため
## （以前は _pulse_time を外から書き換えていた）。
static func pulse_scale_at(elapsed: float) -> float:
	var phase: float = TAU * elapsed / RING_PULSE_PERIOD
	return 1.0 + sin(phase) * RING_PULSE_AMOUNT


## 今この瞬間の半径の倍率。
func pulse_scale() -> float:
	return pulse_scale_at(_pulse_time)


## リングが付いている都市。付いていなければ空文字。
func ring_city() -> String:
	return _ring_city


## 指定した位相でリングを引き直す。
##
## 検査は時間を進められない（ツリー外では _process が回らない）ため、
## 位相を渡して任意の瞬間を再現できるようにしている。
func redraw_selection_ring_at(elapsed: float) -> void:
	if _ring_city == "" or not positions.has(_ring_city):
		return
	_redraw_selection_ring(positions[_ring_city], pulse_scale_at(elapsed))


## リングをその都市の足元に描き直す。
##
## 平らな円を作って位置だけ動かすのでは駄目で、都市ごとに地面の高さが
## 違うため斜面に埋まったり浮いたりする。円周上の各点で地形の高さを
## 引き直し、地面に寝かせる。
func _redraw_selection_ring(center: Vector3, scale: float) -> void:
	if not is_instance_valid(_selection_ring):
		return
	var mesh: ImmediateMesh = _selection_ring.mesh
	mesh.clear_surfaces()

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	# unshaded でも emission は独立して効く。都市の柱と同じ発光エネルギーを
	# 使い、グローの強さを揃える（両方とも UiTheme.FOCUS の単色なので
	# 頂点ごとの色と emission の単一色がズレる心配はない）。
	material.emission_enabled = true
	material.emission = UiTheme.FOCUS
	material.emission_energy_multiplier = CITY_EMISSION_ENERGY

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	_add_ring(mesh, center, RING_INNER_RADIUS * scale, UiTheme.FOCUS)
	_add_ring(mesh, center, RING_OUTER_RADIUS * scale, UiTheme.FOCUS)
	mesh.surface_end()


## 都市の頭上に水平な円を1本引く。
## 高さは中心の一点で決める。地形をなぞると輪が傾き、
## 都市に架かっているようには見えなくなる。
func _add_ring(mesh: ImmediateMesh, center: Vector3, radius: float,
		color: Color) -> void:
	var y: float = ring_height(center)
	for i: int in RING_SEGMENTS:
		var a0: float = TAU * float(i) / float(RING_SEGMENTS)
		var a1: float = TAU * float(i + 1) / float(RING_SEGMENTS)
		var p0 := Vector3(center.x + cos(a0) * radius, y,
			center.z + sin(a0) * radius)
		var p1 := Vector3(center.x + cos(a1) * radius, y,
			center.z + sin(a1) * radius)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(p0)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(p1)


## 輪を架ける高さ。都市の足元を基準にするので、
## 高地の都市では輪もそのぶん高くなる。
func ring_height(center: Vector3) -> float:
	return height_at(center.x, center.z) + RING_LIFT


func _build_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	# 斜め上から当てて起伏に陰影を付ける。
	light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	light.light_energy = 1.1
	# シーンが小さい（都市10×パーツ数個＋地形1枚）ため負荷は軽いはずだが、
	# シャドウアクネ等が出ないかは実機のGUIでしか判断できない（要確認）。
	light.shadow_enabled = true
	add_child(light)


## 現在地を示す。都市の色を状態に合わせて塗り替える（構造物の全パーツぶん）。
func set_current_city(city_id: String) -> void:
	for id: String in _cities:
		var container: Node3D = _cities[id]
		if not is_instance_valid(container):
			continue
		var color: Color = UiTheme.FOCUS if id == city_id else _city_color(id)
		for part: Node in container.get_children():
			var mesh_part: MeshInstance3D = part as MeshInstance3D
			if mesh_part == null or mesh_part.mesh == null:
				continue
			var material: StandardMaterial3D = mesh_part.mesh.surface_get_material(0)
			if material == null:
				continue
			material.albedo_color = color
			material.emission = color

	# 足元のリングを現在地へ移す。地面の高さが都市ごとに違うので引き直す。
	if positions.has(city_id):
		_ring_city = city_id
		# 到着のたびに位相を戻し、リングが広がるところから始まるようにする。
		_pulse_time = 0.0
		_redraw_selection_ring(positions[city_id], pulse_scale())
		if is_instance_valid(_selection_ring):
			_selection_ring.visible = true
	else:
		_ring_city = ""
		if is_instance_valid(_selection_ring):
			_selection_ring.visible = false
