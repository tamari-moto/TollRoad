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


## ツリー外でサイズが失われた際に使う既定のダイアログサイズ。
const DEFAULT_DIALOG_SIZE := Vector2i(520, 480)


## Window の中身をウィンドウ全体に広げる。
##
## 手書きの .tscn で anchors_preset だけ書いても offset が 0 のままだと、
## 子の Control はサイズ 0 で描画されない（中身はあるのに何も見えない）。
## エディタを使わずシーンを書く以上、ここはコードで確定させる。
static func fill_window(window: Window) -> void:
	if window == null or window.get_child_count() == 0:
		return
	var content: Control = window.get_child(0) as Control
	if content == null:
		return
	# ツリー外（--script のハーネス）では Window のサイズが 1x1 に
	#潰れることがある。その場合だけ既定の大きさへ戻す。
	if window.size.x <= 1 or window.size.y <= 1:
		window.size = DEFAULT_DIALOG_SIZE
	# アンカーとオフセットの両方を明示する。size を直接代入するとアンカーと
	# 競合して警告になり、しかも子には伝播しない。
	content.anchor_left = 0.0
	content.anchor_top = 0.0
	content.anchor_right = 1.0
	content.anchor_bottom = 1.0
	content.offset_left = 0.0
	content.offset_top = 0.0
	content.offset_right = 0.0
	content.offset_bottom = 0.0


## セッションのシグナルに接続する。二重接続と、古いセッションの繋ぎっぱなしを防ぐ。
## bind() は再プレイ時にもう一度呼ばれるため、各パネルはこれを使うこと。
static func rebind(old_session: Object, new_session: Object,
		connections: Dictionary) -> void:
	for signal_name: String in connections:
		var callable: Callable = connections[signal_name]
		if old_session != null and is_instance_valid(old_session):
			if old_session.is_connected(signal_name, callable):
				old_session.disconnect(signal_name, callable)
		if not new_session.is_connected(signal_name, callable):
			new_session.connect(signal_name, callable)


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
