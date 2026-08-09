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
