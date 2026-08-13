extends "res://scripts/systems/scenario_base.gd"
## 草木の設置トランスフォームの検証。
##
## 木・低木・岩が傾斜地の地面に埋まったり浮いたりして見える不具合の原因は
## 2つあった:
##   1. 傾斜への追従が中途半端だと接地面の片側が埋まり反対側が浮く
##      （VEGETATION_SLOPE_ALIGNMENT を0.6→1.0→0.0の順に検討し、最終的に
##      ユーザー指定で「木は常に直立」を優先し0.0にした。急斜面を候補地から
##      外す足切りも一時追加したが、原因2を直したことでめり込みが縮み
##      不要と判断してユーザー指定で外した）
##   2. height_at() は連続関数だが、実際に描画される地形メッシュは粗い格子
##      （頂点間は補間）なので、height_at() をそのまま設置高さに使うと
##      「実際に描画されている地面」とズレる（terrain_mesh_height_at() で
##      描画メッシュの補間に合わせて解消。詳細はそのコメント参照）
##
## _test_partial_alignment_formula() は Basis().slerp() に頼らず
## Vector3.rotated() で独立に期待値を組み立て、実装が「法線へ正しい向きで・
## 指定割合だけ」傾けているかを突き合わせる（外積の順序を逆にすると法線と
## 反対側へ傾き、CLAUDE.md が警告する不具合そのものになる。
## VEGETATION_SLOPE_ALIGNMENT が0.0の現在も回転の仕組み自体は残っており、
## 将来また調整する可能性があるため検査も残す）。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m21.gd

const MapView3D = preload("res://scripts/ui/map_view_3d.gd")

## 検査に使う座標の格子。CITY_SPACING を基準にして、都市間隔と同程度の
## 範囲（起伏が現れる規模）を走査する。
const SAMPLE_STEP: float = MapView3D.CITY_SPACING / 4.0
const SAMPLE_RANGE: float = MapView3D.CITY_SPACING



func _init() -> void:
	_test_normal_is_unit_and_upward()
	_test_position_matches_height_and_lift()
	_test_partial_alignment_formula()
	_test_terrain_mesh_height_matches_grid()
	_finish()


## terrain_normal_at() は地形が上に凸（オーバーハングしない）連続関数
## height_at() から求めているので、常に上向き・単位長のはずである。
func _test_normal_is_unit_and_upward() -> void:
	print("--- 地形の局所法線 ---")
	var world: MapView3D = MapView3D.new()

	var min_y: float = 1.0
	var max_length_error: float = 0.0
	var x: float = -SAMPLE_RANGE
	while x <= SAMPLE_RANGE:
		var z: float = -SAMPLE_RANGE
		while z <= SAMPLE_RANGE:
			var normal: Vector3 = world.terrain_normal_at(x, z)
			max_length_error = maxf(max_length_error, absf(normal.length() - 1.0))
			min_y = minf(min_y, normal.y)
			z += SAMPLE_STEP
		x += SAMPLE_STEP

	_check(max_length_error < 0.001, "法線が単位長", "誤差 %.5f" % max_length_error)
	_check(min_y > 0.0, "法線が常に上向き", "最小 y = %.4f" % min_y)

	world.free()


## vegetation_transform_at() の origin は
## terrain_mesh_height_at(x, z) + VEGETATION_LIFT と一致するはず
## （x, z もそのまま通るはず）。height_at() ではなく terrain_mesh_height_at()
## を使うのは、草木を「実際に描画されている地面」に合わせるため
## （terrain_mesh_height_at() のコメント参照）。
func _test_position_matches_height_and_lift() -> void:
	print("--- 設置位置 ---")
	var world: MapView3D = MapView3D.new()

	var max_error: float = 0.0
	var x: float = -SAMPLE_RANGE
	while x <= SAMPLE_RANGE:
		var z: float = -SAMPLE_RANGE
		while z <= SAMPLE_RANGE:
			var transform: Transform3D = world.vegetation_transform_at(x, z)
			var expected_y: float = world.terrain_mesh_height_at(x, z) + MapView3D.VEGETATION_LIFT
			max_error = maxf(max_error, absf(transform.origin.y - expected_y))
			_check(is_equal_approx(transform.origin.x, x) and is_equal_approx(transform.origin.z, z),
				"(%.1f, %.1f) の水平位置がそのまま通る" % [x, z],
				"%s" % transform.origin)
			z += SAMPLE_STEP
		x += SAMPLE_STEP

	_check(max_error < 0.0001, "y が terrain_mesh_height_at() + VEGETATION_LIFT と一致する",
		"誤差 %.5f" % max_error)

	# 低木用の lift 引数（負値＝少し埋める）も正しく足し込まれるか。
	var bush_error: float = 0.0
	x = -SAMPLE_RANGE
	while x <= SAMPLE_RANGE:
		var z: float = -SAMPLE_RANGE
		while z <= SAMPLE_RANGE:
			var transform: Transform3D = world.vegetation_transform_at(
				x, z, MapView3D.VEGETATION_BUSH_SLOPE_ALIGNMENT, MapView3D.VEGETATION_BUSH_LIFT)
			var expected_y: float = world.terrain_mesh_height_at(x, z) + MapView3D.VEGETATION_BUSH_LIFT
			bush_error = maxf(bush_error, absf(transform.origin.y - expected_y))
			z += SAMPLE_STEP
		x += SAMPLE_STEP

	_check(bush_error < 0.0001, "低木の y が terrain_mesh_height_at() + VEGETATION_BUSH_LIFT と一致する",
		"誤差 %.5f" % bush_error)
	_check(MapView3D.VEGETATION_BUSH_LIFT < 0.0, "VEGETATION_BUSH_LIFT が負（少し埋める設定になっている）",
		"%.4f" % MapView3D.VEGETATION_BUSH_LIFT)

	world.free()


## 実装（Basis().slerp()）とは別経路の Vector3.rotated() で期待値を組み立て、
## 「法線への回転を alignment の割合だけ混ぜる」が実装どおりかを突き合わせる。
## 木・岩（VEGETATION_SLOPE_ALIGNMENT=0.0）と低木（VEGETATION_BUSH_
## SLOPE_ALIGNMENT=1.0）の両方で流し、alignment を vegetation_transform_at()
## の第3引数へ正しく渡せているかも確かめる。一致しないケースの主な原因は
## 3つ想定される:
##   - 外積の順序を逆にした（法線と反対側へ傾く）
##   - alignment を掛け忘れて完全に地面へ倣わせた（急斜面で横倒しになる）
##   - 法線が UP と一致する場合の分岐（axis がゼロベクトル）を壊した
func _test_partial_alignment_formula() -> void:
	_test_alignment_formula_for(MapView3D.VEGETATION_SLOPE_ALIGNMENT, "木・岩")
	_test_alignment_formula_for(MapView3D.VEGETATION_BUSH_SLOPE_ALIGNMENT, "低木")


func _test_alignment_formula_for(alignment: float, label: String) -> void:
	print("--- 部分追従の角度（%s, alignment=%.1f） ---" % [label, alignment])
	var world: MapView3D = MapView3D.new()

	var max_angle_error: float = 0.0
	var max_slope_angle: float = 0.0
	var any_exceeds_full_slope: bool = false
	var any_moves_away_from_normal: bool = false

	var x: float = -SAMPLE_RANGE
	while x <= SAMPLE_RANGE:
		var z: float = -SAMPLE_RANGE
		while z <= SAMPLE_RANGE:
			var normal: Vector3 = world.terrain_normal_at(x, z)
			var slope_angle: float = Vector3.UP.angle_to(normal)
			max_slope_angle = maxf(max_slope_angle, slope_angle)

			var expected_up: Vector3 = Vector3.UP
			var axis: Vector3 = Vector3.UP.cross(normal)
			if axis.length() > 0.0001:
				expected_up = Vector3.UP.rotated(axis.normalized(), slope_angle * alignment)

			var transform: Transform3D = world.vegetation_transform_at(x, z, alignment)
			var actual_up: Vector3 = transform.basis * Vector3.UP

			max_angle_error = maxf(max_angle_error, expected_up.angle_to(actual_up))

			var actual_tilt: float = Vector3.UP.angle_to(actual_up)
			if actual_tilt > slope_angle + 0.001:
				any_exceeds_full_slope = true
			if actual_up.dot(normal) < Vector3.UP.dot(normal) - 0.001:
				any_moves_away_from_normal = true
			z += SAMPLE_STEP
		x += SAMPLE_STEP

	_check(max_slope_angle > 0.05, "検査範囲に十分な傾斜が含まれる（前提）",
		"最大傾斜 %.3f rad" % max_slope_angle)
	_check(max_angle_error < 0.01, "傾きが alignment どおりの角度で法線へ追従する",
		"最大誤差 %.5f rad" % max_angle_error)
	_check(not any_exceeds_full_slope, "傾きが地形の傾斜を超えない（alignment<=1.0 の前提）",
		"超えている点がある")
	_check(not any_moves_away_from_normal, "傾く向きが法線に近づく側（反対側へ傾いていない）",
		"法線から遠ざかる点がある")

	world.free()


## terrain_mesh_height_at() が実際に描画されるメッシュへ正しく合わせられて
## いるかの検査。実際の三角形補間との突き合わせ（全域を三角形ごとに探索）は
## 検査として重すぎる（実測で数分かかった）ため、ここでは
## _compute_scale() の意図である「1マスが TERRAIN_MAX_QUAD_SIZE 以下」だけを
## 見る。地形が広がって _terrain_subdivisions の更新を忘れる／計算式を壊す
## と、この検査が最初に気づく（今回の不具合の主因はまさにこれだった）。
func _test_terrain_mesh_height_matches_grid() -> void:
	print("--- 描画メッシュに合わせた設置高さ ---")
	var world: MapView3D = MapView3D.new()

	var quad: float = world.terrain_quad_size()
	_check(quad <= MapView3D.TERRAIN_MAX_QUAD_SIZE + 0.001, "1マスが TERRAIN_MAX_QUAD_SIZE 以下",
		"%.4f" % quad)
	_check(quad > 0.0, "1マスの大きさが正", "%.4f" % quad)

	world.free()
