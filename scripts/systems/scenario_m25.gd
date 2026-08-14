extends "res://scripts/systems/scenario_base.gd"
## 地形の起伏と、都市・街道の周辺を平らに均す処理の検証。
##
## 地形は fBm（多重オクターブ）と稜線を混ぜて作り、そのうえで都市と街道の
## 周辺だけ起伏を押し下げている（人は平地に街を作り、道は緩い斜面を通る、
## というユーザー指定の方針）。ここで検査するのは主に次の3つ。
##
##   1. 都市の足元と街道沿いが実際に平らであること。地形を先に決めてから
##      都市を後付けで乗せる構造なので、平地化が壊れても都市は「そこ」に
##      立ち続ける（位置は変わらない）。急斜面に柱が刺さった絵になるだけで
##      ノードの検査は素通りするため、傾斜そのものを見る必要がある。
##
##   2. 平地化の寄せ先が滑らかであること。寄せ先に細かい起伏の残る値を
##      使うと、平らにするどころか逆に急斜面を作る。実際にそうなった
##      （寄せ先に FBM_NORMALIZE 倍した粗いノイズを使い、都市の足元が
##      64.4度・街道の平均が40.4度と、平地化前より悪化した）。
##      この検査は「都市周辺の傾斜が平地化しない場合より緩い」ことを見る。
##
##   3. 平地化が地形を壊していないこと。強すぎると全域が平らになり、
##      都市が周囲から掘り下げられた穴の底に沈む。面積の上限と、
##      都市の沈み込みの深さで歯止めをかける。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m25.gd

const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")
const GameData = preload("res://scripts/systems/game_data.gd")

## 街道1本あたり何点を標本にするか。
const ROAD_SAMPLES: int = 25
## 「見えている範囲」の半径。カメラが寄れる限界より外は霧の中で、
## 見た目の判断に効かないため統計から外す。
const VISIBLE_RADIUS: float = MapCamera.MAX_DISTANCE


func _init() -> void:
	_test_cities_stand_on_flat_ground()
	_test_roads_follow_gentle_slopes()
	_test_flattening_target_is_smooth()
	_test_flattening_does_not_flood_the_map()
	_test_terrain_has_relief()
	_finish()


## 都市の足元が平らであること。柱が急斜面に刺さっていると、土台の片側が
## 地面にめり込み反対側が浮く。
func _test_cities_stand_on_flat_ground() -> void:
	print("--- 都市の足元 ---")
	var world: MapView3D = MapView3D.new()

	var worst: float = 0.0
	var worst_id: String = ""
	var total: float = 0.0
	for city_id: String in world.positions:
		var p: Vector3 = world.positions[city_id]
		var degrees: float = _slope_degrees(world, p.x, p.z)
		total += degrees
		if degrees > worst:
			worst = degrees
			worst_id = city_id

	var mean: float = total / float(world.positions.size())
	_check(mean < 15.0, "都市の足元の平均傾斜が緩い", "%.1f 度" % mean)
	_check(worst < 25.0, "最も急な都市でも柱が刺さらない程度",
		"%s が %.1f 度" % [worst_id, worst])

	# 平地化が効いていること自体も見る（係数が0のまま＝機能していない、
	# を検出する。上の傾斜だけだと、たまたま平らな場所に都市が来た場合に
	# 素通りしうる）。
	var flattened: int = 0
	for city_id: String in world.positions:
		var p: Vector3 = world.positions[city_id]
		if world.settlement_flatten_at(p.x, p.z) > 0.5:
			flattened += 1
	_check(flattened == world.positions.size(), "全都市が平地化の範囲内にある",
		"%d / %d" % [flattened, world.positions.size()])

	world.free()


## 街道沿いが緩い斜面であること。道は幅を持った帯なので、急斜面を横切ると
## 帯の片側が地面へ潜る。
func _test_roads_follow_gentle_slopes() -> void:
	print("--- 街道沿いの傾斜 ---")
	var world: MapView3D = MapView3D.new()

	var worst: float = 0.0
	var total: float = 0.0
	var samples: int = 0
	for edge: Array in GameData.ROYAL_ROAD_EDGES:
		var a: Vector3 = world.positions[edge[0]]
		var b: Vector3 = world.positions[edge[1]]
		for i: int in ROAD_SAMPLES:
			var p: Vector3 = a.lerp(b, float(i) / float(ROAD_SAMPLES - 1))
			var degrees: float = _slope_degrees(world, p.x, p.z)
			total += degrees
			worst = maxf(worst, degrees)
			samples += 1

	var mean: float = total / float(samples)
	_check(mean < 15.0, "街道沿いの平均傾斜が緩い", "%.1f 度" % mean)
	_check(worst < 35.0, "街道が崖を横切らない", "最大 %.1f 度" % worst)

	world.free()


## 平地化の寄せ先（_base_shape_at 相当）が滑らかであること。
##
## 実装の内部関数を直接呼ばず、外から見える性質で確かめる: 平地化が
## 最大に効いている地点どうしを近い距離で比べたとき、高さの変化が
## 緩やかであること。寄せ先が細かく上下していると、いくら強く寄せても
## そこが急斜面になるため、この検査が落ちる。
func _test_flattening_target_is_smooth() -> void:
	print("--- 平地化の寄せ先の滑らかさ ---")
	var world: MapView3D = MapView3D.new()

	# 都市の中心から SETTLEMENT_FLAT_RADIUS の内側だけを見る
	# （ここは平地化の係数が 1.0 で一定なので、残る起伏は寄せ先由来）。
	#
	# 中心都市（レイヴンスパイア）だけは対象外。原点は盆地の底で、
	# height_at() に basin^2 * BASIN_DEPTH の掘り下げが乗る。これは
	# 「中心が盆地の底に見える」という設計そのもの（BASIN_DEPTH）であって
	# 平地化の失敗ではない（実測: 中心都市 0.577 に対し、王国都市9つは
	# いずれも 0.33 以下）。ここで一緒に見ると、盆地を深くしただけで
	# この検査が落ちることになる。
	var step: float = 0.4
	var worst: float = 0.0
	var worst_where: String = ""
	for city_id: String in world.positions:
		if city_id == GameData.CAERLEON:
			continue
		var p: Vector3 = world.positions[city_id]
		var radius: float = MapView3D.SETTLEMENT_FLAT_RADIUS - step
		var x: float = -radius
		while x <= radius:
			var z: float = -radius
			while z <= radius:
				if Vector2(x, z).length() <= radius:
					var slope: float = absf(
						world.height_at(p.x + x + step, p.z + z)
						- world.height_at(p.x + x, p.z + z)) / step
					if slope > worst:
						worst = slope
						worst_where = city_id
				z += step
			x += step

	# 傾き（高さ/水平距離）。tan(20度) ≒ 0.36 なので、その程度を上限にする。
	_check(worst < 0.36, "平地化された都市の中心部に急な起伏が残らない（中心都市を除く）",
		"%s 付近で 高さ/距離 = %.3f" % [worst_where, worst])

	world.free()


## 平地化が地図を覆い尽くしていないこと。強すぎたり範囲が広すぎたりすると
## 全域が平らになり、起伏を付けた意味が無くなる。あわせて、都市が周囲から
## 掘り下げられた穴の底に沈んでいないことも見る。
func _test_flattening_does_not_flood_the_map() -> void:
	print("--- 平地化の広がり ---")
	var world: MapView3D = MapView3D.new()

	var flattened: int = 0
	var samples: int = 0
	var step: float = 1.0
	var x: float = -VISIBLE_RADIUS
	while x <= VISIBLE_RADIUS:
		var z: float = -VISIBLE_RADIUS
		while z <= VISIBLE_RADIUS:
			if Vector2(x, z).length() <= VISIBLE_RADIUS:
				samples += 1
				if world.settlement_flatten_at(x, z) > 0.01:
					flattened += 1
			z += step
		x += step

	var ratio: float = float(flattened) / float(samples)
	_check(ratio < 0.75, "平地化が地図を覆い尽くしていない",
		"見える範囲の %.1f%%" % (ratio * 100.0))
	_check(ratio > 0.05, "平地化が実際に効いている（範囲が消えていない）",
		"見える範囲の %.1f%%" % (ratio * 100.0))

	# 都市が周囲より極端に低くないこと（寄せ先を 0 にすると高地の都市が
	# 穴の底に沈む。その退行を検出する）。
	var deepest: float = 0.0
	var deepest_id: String = ""
	for city_id: String in world.positions:
		var p: Vector3 = world.positions[city_id]
		var around: float = 0.0
		for k: int in 8:
			var angle: float = TAU * float(k) / 8.0
			around += world.height_at(p.x + cos(angle) * 9.0, p.z + sin(angle) * 9.0)
		around /= 8.0
		var difference: float = p.y - around
		if difference < deepest:
			deepest = difference
			deepest_id = city_id

	# 中心都市は盆地の底にある設計なので、その深さ（BASIN_DEPTH）は許す。
	_check(deepest > -MapView3D.BASIN_DEPTH, "都市が周囲から掘り下げられた穴に沈んでいない",
		"%s が周囲より %.2f 低い" % [deepest_id, deepest])

	world.free()


## 平地化を強めた結果、地形全体が平らになっていないこと。
## 「平地を広く」と「起伏がある」は両立させる必要がある。
func _test_terrain_has_relief() -> void:
	print("--- 起伏が残っている ---")
	var world: MapView3D = MapView3D.new()

	var lowest: float = 9999.0
	var highest: float = -9999.0
	var step: float = 1.5
	var x: float = -VISIBLE_RADIUS
	while x <= VISIBLE_RADIUS:
		var z: float = -VISIBLE_RADIUS
		while z <= VISIBLE_RADIUS:
			if Vector2(x, z).length() <= VISIBLE_RADIUS:
				var h: float = world.height_at(x, z)
				lowest = minf(lowest, h)
				highest = maxf(highest, h)
			z += step
		x += step

	_check(highest - lowest > 1.5, "見える範囲に高低差がある",
		"%.2f" % (highest - lowest))

	# 起伏の素の形が -1〜1 に収まっていること（正規化が壊れると
	# TERRAIN_HEIGHT との関係が黙ってずれ、都市の柱やリングの高さが合わなくなる）。
	var out_of_range: int = 0
	x = -VISIBLE_RADIUS
	while x <= VISIBLE_RADIUS:
		var z: float = -VISIBLE_RADIUS
		while z <= VISIBLE_RADIUS:
			var s: float = world.terrain_shape_at(x, z)
			if s < -1.0001 or s > 1.0001:
				out_of_range += 1
			z += step
		x += step
	_check(out_of_range == 0, "起伏の素の形が -1〜1 に収まる",
		"範囲外 %d 点" % out_of_range)

	world.free()


## その地点の地形の傾斜（度）。
func _slope_degrees(world: MapView3D, x: float, z: float) -> float:
	var normal: Vector3 = world.terrain_normal_at(x, z)
	return rad_to_deg(acos(clampf(normal.y, -1.0, 1.0)))
