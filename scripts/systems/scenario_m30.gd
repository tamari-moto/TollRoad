extends "res://scripts/systems/scenario_base.gd"
## 市場の価格推移グラフ（相場メモに追加した折れ線グラフ）の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m30.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const PriceHistory = preload("res://scripts/systems/price_history.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")


func _init() -> void:
	_test_recording()
	_test_round_trip()
	_test_malformed_history()
	_test_chart_geometry()
	_test_panel_wiring()
	_finish()


## 初日にすでに1件、以後 advance_day のたびに1件ずつ伸びる。
func _test_recording() -> void:
	print("--- 記録の伸び方 ---")
	var session: GameSession = GameSession.new(30001)
	var city: String = GameData.INITIAL_CITY

	_check(session.price_history.series(city, "ore").size() == 1,
		"1日目時点で1件記録されている", str(session.price_history.series(city, "ore").size()))
	_check(session.price_history.series(city, "ore")[0] == session.prices.get_price(city, "ore"),
		"初日の記録が当日の建値と一致する", str(session.price_history.series(city, "ore")[0]))

	for i: int in 5:
		session.rest()
	_check(session.price_history.series(city, "ore").size() == session.day,
		"日数ぶんだけ記録が伸びる（%d日目）" % session.day,
		str(session.price_history.series(city, "ore").size()))

	# 訪問していない都市も記録される（相場メモとは別方針）。
	var far_city: String = _far_royal_city(city)
	_check(not session.has_memo(far_city), "訪問していない都市である", "訪問済みだった")
	_check(session.price_history.series(far_city, "ore").size() == session.day,
		"未訪問の都市でも価格推移は記録される", str(session.price_history.series(far_city, "ore").size()))

	# 全都市×全品目で記録日数が揃っている。
	var mismatched: String = ""
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if session.price_history.series(city_id, item_id).size() != session.day and mismatched == "":
				mismatched = "%s / %s" % [city_id, item_id]
	_check(mismatched == "", "全都市×全品目で記録日数が揃っている", mismatched)


func _test_round_trip() -> void:
	print("--- 保存と復元 ---")
	var original: GameSession = GameSession.new(30002)
	for i: int in 7:
		original.rest()

	var restored: GameSession = GameSession.new(0)
	restored.from_dict(original.to_dict())

	var mismatch: String = ""
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if restored.price_history.series(city_id, item_id) \
					!= original.price_history.series(city_id, item_id) and mismatch == "":
				mismatch = "%s / %s" % [city_id, item_id]
	_check(mismatch == "", "全都市×全品目の履歴が一致する", mismatch)

	# 揃った履歴の復元は RNG を消費しない（prices と同じ歯止め）。
	var saved_state: String = str(original.to_dict()["rng"]["state"])
	var restored_state: String = str(restored.to_dict()["rng"]["state"])
	_check(restored_state == saved_state, "揃った履歴の復元は乱数を消費しない",
		"保存 %s / 復元後 %s" % [saved_state, restored_state])

	# JSON を経由しても数値が int のまま往復する。
	var via_json: Variant = JSON.parse_string(JSON.stringify(original.to_dict()))
	var json_restored: GameSession = GameSession.new(0)
	json_restored.from_dict(via_json as Dictionary)
	var sample: Array = json_restored.price_history.series(GameData.INITIAL_CITY, "ore")
	_check(sample.size() > 0 and typeof(sample[0]) == TYPE_INT,
		"JSON を経由しても価格が int で戻る",
		type_string(typeof(sample[0])) if sample.size() > 0 else "空")


## 系列長が day と噛み合わない・欠けている履歴は、過去を再現できないため
## **当日の1件だけ**で作り直す（prices の reroll() と同じく過去は戻せない）。
## 「一部補完しない」（全都市×全品目で必ず揃った長さになる）方針は保つ。
func _test_malformed_history() -> void:
	print("--- 壊れた履歴 ---")
	var played: GameSession = GameSession.new(30003)
	for i: int in 4:
		played.rest()
	var data: Dictionary = played.to_dict()

	# キーそのものが無い。
	var without_history: Dictionary = data.duplicate(true)
	without_history.erase("price_history")
	var no_history: GameSession = GameSession.new(0)
	no_history.from_dict(without_history)
	_check(no_history.price_history.series(GameData.INITIAL_CITY, "ore").size() == 1,
		"履歴が無ければ過去は戻さず当日の1件で作り直す",
		str(no_history.price_history.series(GameData.INITIAL_CITY, "ore").size()))

	# 都市が1つ欠けている（部分補完せず全体を当日の1件で作り直す）。
	var partial: Dictionary = data.duplicate(true)
	partial["price_history"] = partial["price_history"].duplicate(true)
	partial["price_history"].erase(GameData.CAERLEON)
	var rerolled: GameSession = GameSession.new(0)
	rerolled.from_dict(partial)
	var uniform: bool = true
	for city_id: String in GameData.CITIES:
		if rerolled.price_history.series(city_id, "ore").size() != 1:
			uniform = false
	_check(uniform, "都市が1つ欠けていれば全体を当日の1件で作り直す（部分補完しない）",
		"欠けたまま、または不揃い")

	# 系列長が day と食い違う（古い版の名残を想定）。
	var stale: Dictionary = data.duplicate(true)
	stale["price_history"] = stale["price_history"].duplicate(true)
	for city_id: String in GameData.CITIES:
		stale["price_history"][city_id] = stale["price_history"][city_id].duplicate(true)
		stale["price_history"][city_id]["ore"] = [100]
	var mismatched: GameSession = GameSession.new(0)
	mismatched.from_dict(stale)
	_check(mismatched.price_history.series(GameData.INITIAL_CITY, "ore").size() == 1,
		"系列長が day と食い違えば当日の1件で作り直す",
		str(mismatched.price_history.series(GameData.INITIAL_CITY, "ore").size()))

	# 手で壊された値（配列でない）でも落ちない。
	var broken: Dictionary = data.duplicate(true)
	broken["price_history"] = broken["price_history"].duplicate(true)
	broken["price_history"][GameData.INITIAL_CITY] = "壊れている"
	var survived: GameSession = GameSession.new(0)
	survived.from_dict(broken)
	_check(survived.day > 0, "壊れた履歴があっても復元は続く", "落ちた")
	_check(survived.price_history.series(GameData.INITIAL_CITY, "ore").size() == 1,
		"壊れた履歴は当日の1件で作り直される",
		str(survived.price_history.series(GameData.INITIAL_CITY, "ore").size()))


## PriceChart のジオメトリ: 描いた点が描画領域の中に収まり、
## 価格の上下と横軸の日数が一致している。
func _test_chart_geometry() -> void:
	print("--- チャートのジオメトリ ---")
	var script: Script = load("res://scripts/ui/price_chart.gd")
	var chart: Control = script.new()

	# 未選択（空系列）では品目が無いことを示す。
	chart.set_data({}, 1)
	_check(chart.item_ids().is_empty(), "初期状態では系列が空", str(chart.item_ids().size()))

	var series: Dictionary = {
		"ore": [100, 150, 90, 200, 120],
		"wood": [80, 80, 80, 80, 80],
	}
	chart.set_data(series, 5)
	_check(chart.max_day() == 5, "max_day が渡した日数になる", str(chart.max_day()))
	_check(chart.item_ids().size() == 2, "渡した品目数だけ系列が残る", str(chart.item_ids().size()))

	var rect: Rect2 = chart.plot_rect()
	var out_of_bounds: int = 0
	for item_id: String in series:
		for i: int in (series[item_id] as Array).size():
			var point: Vector2 = chart.point_for(item_id, i)
			if not rect.has_point(point) and not rect.abs().grow(0.5).has_point(point):
				out_of_bounds += 1
	_check(out_of_bounds == 0, "全ての点が描画領域の中に収まる", "%d 点がはみ出た" % out_of_bounds)

	# 最高値（200）は最低の点、最安値（80）は最も高い点に来る（Y軸は上が高価格）。
	var highest_point: Vector2 = chart.point_for("ore", 3)  # 価格200
	var lowest_price_point: Vector2 = chart.point_for("wood", 0)  # 価格80
	_check(highest_point.y < lowest_price_point.y,
		"価格が高いほど描画位置が上（Yが小さい）になる",
		"200円の点 y=%.1f / 80円の点 y=%.1f" % [highest_point.y, lowest_price_point.y])

	# 横軸: 1日目が左端、最終日が右端に来る。
	var day1: Vector2 = chart.point_for("ore", 0)
	var day5: Vector2 = chart.point_for("ore", 4)
	_check(day1.x < day5.x, "1日目が左、最終日が右に来る",
		"1日目 x=%.1f / 最終日 x=%.1f" % [day1.x, day5.x])

	# 横軸の目盛り: 1日目と最終日を必ず含み、昇順で、本数が詰まりすぎない。
	var ticks_5: Array[int] = chart.tick_days()
	_check(ticks_5[0] == 1, "目盛りの先頭が1日目", str(ticks_5[0]))
	_check(ticks_5[ticks_5.size() - 1] == 5, "目盛りの末尾が最終日", str(ticks_5[ticks_5.size() - 1]))

	chart.set_data(series, 60)
	var ticks_60: Array[int] = chart.tick_days()
	_check(ticks_60[0] == 1, "60日でも目盛りの先頭が1日目", str(ticks_60[0]))
	_check(ticks_60[ticks_60.size() - 1] == 60, "60日でも目盛りの末尾が最終日",
		str(ticks_60[ticks_60.size() - 1]))
	_check(ticks_60.size() >= 3 and ticks_60.size() <= 10,
		"60日の目盛り本数が詰まりすぎず疎になりすぎない（3〜10本）", str(ticks_60.size()))
	var increasing: bool = true
	for i: int in range(1, ticks_60.size()):
		if ticks_60[i] <= ticks_60[i - 1]:
			increasing = false
	_check(increasing, "目盛りが日数の昇順に並ぶ", str(ticks_60))

	# 実際にプレイ中に踏んだ不具合の再現: 31日目（60日枠で目盛り間隔10日）だと、
	# 直前の目盛り30日目と最終日31日目が1日しか離れておらず、ラベルが重なって
	# 「30日目目」のように潰れて見えた。間隔が詰まる場合は直前の目盛りを削る。
	chart.set_data(series, 31)
	var ticks_31: Array[int] = chart.tick_days()
	_check(not (30 in ticks_31 and 31 in ticks_31),
		"最終日に近すぎる目盛りは重ならないよう間引かれる（30日目と31日目が両方出ない）",
		str(ticks_31))
	_check(ticks_31[ticks_31.size() - 1] == 31, "31日でも目盛りの末尾が最終日",
		str(ticks_31[ticks_31.size() - 1]))
	chart.set_data(series, 5)

	# 価格は負にならないため、縦軸の下限に0を割り込む余白を付けない。
	# 横ばいの安値（1のまま）だと余白が下限を押し下げて負になりやすい
	# （lo=hi=1 の分岐で lo-1=0 になり、そこにさらに8%の余白が乗る）。
	chart.set_data({"clay": [1, 1, 1, 1, 1]}, 5)
	_check(chart.price_bounds().x >= 0.0, "縦軸の下限が0未満にならない",
		str(chart.price_bounds().x))
	chart.set_data(series, 5)

	# 横ばい系列（wood）でも価格範囲が0除算せず、有限の座標になる。
	var flat_point: Vector2 = chart.point_for("wood", 2)
	_check(is_finite(flat_point.x) and is_finite(flat_point.y),
		"横ばいの系列でも座標が有限", str(flat_point))

	chart.free()


## MemoPanel から実際に品目を選ぶと、選んだ都市・品目の系列がチャートへ渡る。
func _test_panel_wiring() -> void:
	print("--- 相場メモのグラフ配線 ---")
	var panel: Node = _spawn("res://scenes/ui/MemoPanel.tscn")
	if panel == null:
		return

	var session: GameSession = GameSession.new(30004)
	for i: int in 3:
		session.rest()
	panel.bind(session)

	var city_select: OptionButton = UiUtil.find_node(panel, "CitySelect")
	var toggles: Container = UiUtil.find_node(panel, "ItemToggles")
	var chart: Control = UiUtil.find_node(panel, "PriceChart")
	_check(city_select != null, "都市選択がある", "ない")
	_check(toggles != null, "品目トグルの入れ物がある", "ない")
	_check(chart != null, "チャートがある", "ない")
	if city_select == null or toggles == null or chart == null:
		_despawn(panel)
		return

	_check(city_select.item_count == GameData.CITIES.size(),
		"都市選択の項目数が都市数と一致する", str(city_select.item_count))
	_check(toggles.get_child_count() == GameData.ITEMS.size(),
		"品目トグルの数が品目数と一致する", str(toggles.get_child_count()))
	_check(chart.item_ids().is_empty(), "何も選んでいなければグラフは空", str(chart.item_ids().size()))

	# 品目を1つ選ぶと、その品目の系列がチャートに渡る。
	var toggle: CheckButton = toggles.get_child(0) as CheckButton
	var first_item: String = GameData.ITEMS.keys()[0]
	toggle.button_pressed = true
	toggle.toggled.emit(true)
	_check(chart.item_ids() == [first_item], "選んだ品目だけがグラフに渡る", str(chart.item_ids()))
	_check(chart.max_day() == session.day, "グラフの横軸が現在の経過日数まで伸びる",
		"%d / %d" % [chart.max_day(), session.day])

	_despawn(panel)
