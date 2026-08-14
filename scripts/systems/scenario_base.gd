extends SceneTree
## 検証シナリオの共通基底。
##
## 各シナリオは `extends "res://scripts/systems/scenario_base.gd"` と書き、
## _init() に検査を並べて末尾で _finish() を呼ぶ。
##
## --script は SceneTree を継承したスクリプトを要求するが、継承チェーンで
## 満たされていればよい（4.7.1 で実測確認済み）。
##
## ファイル名を scenario_ で始めているのは export_presets.cfg の
## exclude_filter="scripts/systems/scenario_*.gd" にそのまま乗せるため。
## 別の名前にすると配布物へ混入する。
##
## _failures は scenario_all.gd が外から読んで集計する。名前を変えないこと。

var _failures: int = 0
var _checks: int = 0

## _spawn() したノード。_finish() が取りこぼしを回収する。
var _spawned: Array[Node] = []


## 条件が偽なら失敗を1件数え、実際の値を添えて出力する。
##
## **この print の書式を変えないこと。** scenario_all.gd は別プロセスで動かす
## シナリオ（AWAIT_SCENARIOS）の結果を、子の出力に含まれる "  OK   " と
## "  FAIL " の**個数を数えて**集計している（子は _failures を返せないため）。
## 先頭の空白の数まで一致している必要があり、整形すると該当シナリオの件数が
## 黙って 0 になる。**落ちるのではなく「全部合格」に見える**ので気づけない。
func _check(condition: bool, description: String, actual: String) -> void:
	_checks += 1
	if condition:
		print("  OK   %s" % description)
	else:
		_failures += 1
		print("  FAIL %s（実際: %s）" % [description, actual])


## シーンを読み込んで root へ入れる。読み込めなければ失敗を数えて null を返す。
##
## root へ入れても is_inside_tree() は false のままになる（SceneTree 実行時は
## root が構築中のため）。ノードの有効性は is_instance_valid() で見ること。
func _spawn(path: String) -> Node:
	var scene: PackedScene = load(path)
	if scene == null:
		_check(false, "%s が読み込める" % path, "失敗")
		return null
	var node: Node = scene.instantiate()
	root.add_child(node)
	_spawned.append(node)
	return node


## _spawn() したノードをツリーから外して解放する。
func _despawn(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	_spawned.erase(node)
	root.remove_child(node)
	node.free()


## city_id と王道で直接つながる都市の1つ（=1日で行ける隣接都市）。
##
## 都市名を直書きすると都市の増減・改名・接続変更のたびにシナリオを
## 書き換える羽目になるため、「隣接都市が要る」検査はこれ経由で都市IDを
## 得ること。次数が都市ごとに不揃い（GameData.ROYAL_ROAD_EDGES 参照）なので
## 「次」という順序の概念は無く、road_neighbors() の先頭を返す。
## GameData は関数内ローカルの const にして、各シナリオ側で個別に
## preload している同名の const と衝突しないようにしてある。
func _adjacent_royal_city(city_id: String) -> String:
	const GameData = preload("res://scripts/systems/game_data.gd")
	return GameData.road_neighbors(city_id)[0]


## city_id から王道でちょうど2ホップ先（直接隣接ではない）都市。
##
## 現在のトポロジーは全都市がこの条件を満たす候補を持つ（設計時に手計算で
## 確認済み）。BFSで距離2に達した最初の都市を返す。
func _far_royal_city(city_id: String) -> String:
	const GameData = preload("res://scripts/systems/game_data.gd")
	var visited: Dictionary = {city_id: 0}
	var queue: Array[String] = [city_id]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		var current_dist: int = visited[current]
		if current_dist >= 2:
			continue
		for neighbor: String in GameData.road_neighbors(current):
			if not visited.has(neighbor):
				visited[neighbor] = current_dist + 1
				queue.append(neighbor)
	for id: String in visited:
		if visited[id] == 2:
			return id
	return city_id


## 結果を集計して終了する。各シナリオの _init() の末尾で必ず呼ぶこと。
##
## _despawn() し忘れたノードもここで回収する。
func _finish() -> void:
	for node: Node in _spawned.duplicate():
		_despawn(node)
	_spawned.clear()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)
