extends RefCounted
## UI スクリプト共通の小道具。
##
## ノード解決をここに集約するのは、--script のハーネスで検証する際の罠を
## 各画面で繰り返さないため（詳細は CLAUDE.md）:
## - root.add_child() しても is_inside_tree() は false のまま
## - @onready はツリー投入の次フレームに代入され、手動解決を上書きする
## - %記法はシーンのオーナー解決に依存し、ツリー外では引けないことがある


## 子ノードを名前で引く。%記法で引けなければ再帰探索にフォールバックする。
static func find_node(owner_node: Node, node_name: String) -> Node:
	var found: Node = owner_node.get_node_or_null("%" + node_name)
	if found != null:
		return found
	return owner_node.find_child(node_name, true, false)


## 桁区切りを入れる（1234567 -> 1,234,567）。
static func format_number(value: int) -> String:
	var text: String = str(absi(value))
	var out: String = ""
	var count: int = 0
	for i: int in range(text.length() - 1, -1, -1):
		out = text[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out
