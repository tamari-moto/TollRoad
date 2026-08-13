extends "res://scripts/systems/scenario_base.gd"
## 謎の巨人（背景のシルエット2体）の検証。
##
## 描画結果そのものはヘッドレスで確認できないため、ここで見るのは配置
## （地形の縁付近・GIANT_EDGE_FRACTION どおりの半径・中心を向く）と、
## シルエットとして読めるための色・陰影設定（地形のどの色より暗い・
## unshaded・発光なし）。
##
## 配置の半径は _terrain_size（内部変数）を直接見ず、_ring_radius と
## 同じ値のはずの「王国都市の最大半径」（world.positions から自前で
## 求める、公開API）と、_build() と同じ式（MapCamera.MAX_DISTANCE と
## MapView3D.TERRAIN_MARGIN_BUFFER から terrain_margin を組み立てる）から
## 独立に再計算する。アンダースコア付きの内部変数はシナリオから触らない
## 規約のため（CLAUDE.md参照）。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m22.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")

const GIANT_PART_COUNT: int = 4  ## 胴1 + 腕2 + 頭1（脚は作らない。ユーザー指定で上半身のみ）



func _init() -> void:
	_test_giants_exist_and_placed()
	_test_giants_face_center()
	_test_giants_read_as_silhouette()
	_finish()


func _test_giants_exist_and_placed() -> void:
	print("--- 巨人の配置 ---")
	var world: MapView3D = MapView3D.new()

	# 王国都市の輪の広がり（= _ring_radius と同じ値。Caerleon は原点なので
	# 最大値には効かない）を world.positions（公開）から自前で求める。
	# _ring_radius など内部変数はシナリオから触らない規約（CLAUDE.md参照）。
	var max_city_radius: float = 0.0
	for city_id: String in GameData.royal_city_ids():
		var p: Vector3 = world.positions[city_id]
		max_city_radius = maxf(max_city_radius, Vector2(p.x, p.z).length())

	# _build() の _terrain_margin / _terrain_size と同じ式で、地形の半径を
	# 独立に再計算する（map_view_3d.gd の _build() 冒頭・_compute_scale() 参照）。
	var terrain_margin: float = (MapCamera.MAX_DISTANCE + MapView3D.TERRAIN_MARGIN_BUFFER) * 2.0
	var expected_half_extent: float = max_city_radius + terrain_margin * 0.5
	var expected_giant_radius: float = expected_half_extent * MapView3D.GIANT_EDGE_FRACTION

	var giants: Array[Node3D] = []
	for index: int in MapView3D.GIANT_ANGLES_DEG.size():
		var giant: Node3D = world.get_node_or_null("Giant%d" % index) as Node3D
		_check(giant != null, "Giant%d がある" % index, "ない")
		if giant != null:
			giants.append(giant)

	_check(giants.size() == 2, "巨人が2体いる", str(giants.size()))

	for giant: Node3D in giants:
		_check(giant.get_child_count() == GIANT_PART_COUNT,
			"%s が胴+腕2+頭のパーツを持つ（脚は無い）" % giant.name,
			str(giant.get_child_count()))

		# 地面に乗っている（都市や草木と同じ height_at() 基準）。
		var ground_y: float = world.height_at(giant.position.x, giant.position.z)
		_check(is_equal_approx(giant.position.y, ground_y),
			"%s が地面に乗っている" % giant.name,
			"%.2f / 地面 %.2f" % [giant.position.y, ground_y])

		# 王国都市の輪の外側にいる（背景として都市を隠さない）。
		var flat_distance: float = Vector2(giant.position.x, giant.position.z).length()
		_check(flat_distance > max_city_radius, "%s が都市の輪の外にいる" % giant.name,
			"%.2f / 都市の最大半径 %.2f" % [flat_distance, max_city_radius])

		# GIANT_EDGE_FRACTION どおり、地形の縁付近（半径の92%）に置かれている。
		_check(absf(flat_distance - expected_giant_radius) < 0.05,
			"%s が地形の縁付近（半径の%.0f%%）にいる" % [giant.name, MapView3D.GIANT_EDGE_FRACTION * 100.0],
			"%.2f / 期待 %.2f" % [flat_distance, expected_giant_radius])

		# 地形の内側に収まっている（GIANT_EDGE_FRACTION < 1.0 の前提の再確認）。
		_check(flat_distance < expected_half_extent, "%s が地形の内側にいる" % giant.name,
			"%.2f / 地形の半分 %.2f" % [flat_distance, expected_half_extent])

	# 2体は中心から見て概ね反対側（カメラを回すと一体ずつ現れる設計）。
	if giants.size() == 2:
		var a: Vector2 = Vector2(giants[0].position.x, giants[0].position.z)
		var b: Vector2 = Vector2(giants[1].position.x, giants[1].position.z)
		var separation: float = rad_to_deg(absf(a.angle_to(b)))
		_check(absf(separation - 180.0) < 30.0,
			"2体が中心を挟んでおおむね反対側にいる",
			"%.1f 度" % separation)

	world.free()


func _test_giants_face_center() -> void:
	print("--- 巨人の向き ---")
	var world: MapView3D = MapView3D.new()
	var center: Vector3 = world.positions[GameData.CAERLEON]

	for index: int in MapView3D.GIANT_ANGLES_DEG.size():
		var giant: Node3D = world.get_node_or_null("Giant%d" % index) as Node3D
		if giant == null:
			continue
		# ツリー外では global_transform が更新されないため transform を使う
		# （CLAUDE.md参照。map_camera.gd の検査と同じ流儀）。
		var forward: Vector3 = -giant.transform.basis.z
		var to_center: Vector3 = Vector3(
			center.x - giant.position.x, 0.0, center.z - giant.position.z).normalized()
		_check(forward.dot(to_center) > 0.99, "Giant%d が中心を向いている" % index,
			"内積 %.3f" % forward.dot(to_center))

	world.free()


## 「動くか」ではなく「妥当か」を見る検査（CLAUDE.md参照）。GIANT_COLOR を
## 明るくしたり発光を付けたりしたら、この検査は落ちなければならない。
func _test_giants_read_as_silhouette() -> void:
	print("--- 巨人がシルエットとして読めるか ---")
	var world: MapView3D = MapView3D.new()

	var giant: Node3D = world.get_node_or_null("Giant0") as Node3D
	_check(giant != null, "Giant0 がある", "ない")
	if giant == null:
		world.free()
		return

	var basin_luminance: float = 0.2126 * MapView3D.TERRAIN_BASIN_COLOR.r \
		+ 0.7152 * MapView3D.TERRAIN_BASIN_COLOR.g + 0.0722 * MapView3D.TERRAIN_BASIN_COLOR.b

	for part: Node in giant.get_children():
		var mesh_part: MeshInstance3D = part as MeshInstance3D
		if mesh_part == null or mesh_part.mesh == null:
			continue
		var material: StandardMaterial3D = mesh_part.mesh.surface_get_material(0)
		_check(material != null, "%s にマテリアルがある" % mesh_part.name, "ない")
		if material == null:
			continue

		_check(not material.emission_enabled, "%s は発光しない（不動の存在）" % mesh_part.name,
			"発光している")
		_check(material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
			"%s が unshaded（陰影で輪郭が崩れない）" % mesh_part.name, "陰影あり")

		var color: Color = material.albedo_color
		var luminance: float = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
		_check(luminance < basin_luminance,
			"%s が地形の最暗色より暗い（霧に沈むシルエット）" % mesh_part.name,
			"輝度 %.3f >= 地形 %.3f" % [luminance, basin_luminance])

	world.free()
