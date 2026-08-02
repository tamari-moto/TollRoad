extends Window
## 開始画面。何を目指すゲームなのかを最初に伝える。
##
## 目標がリザルト画面にしか出ていなかったため、プレイヤーは60日を終えて
## から初めて評価基準を知る状態だった。ここで前提・目標・進め方の指針を
## 渡し、1日目から判断できるようにする。
##
## 文面の数値は GameData から組み立てる。バランス調整で日数や目標額が
## 変わっても、説明とゲームがずれない。

const GameData = preload("res://scripts/systems/game_data.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

signal closed

var _premise: Label
var _goal_label: Label
var _rank_list: VBoxContainer
var _hint: Label
var _start_button: Button


func _ready() -> void:
	_resolve()
	_populate()


func _resolve() -> void:
	if is_instance_valid(_premise):
		return
	_premise = UiUtil.find_node(self, "Premise")
	_goal_label = UiUtil.find_node(self, "GoalLabel")
	_rank_list = UiUtil.find_node(self, "RankList")
	_hint = UiUtil.find_node(self, "Hint")
	_start_button = UiUtil.find_node(self, "StartButton")

	if is_instance_valid(_start_button) and not _start_button.pressed.is_connected(_on_close):
		_start_button.pressed.connect(_on_close)
	if not close_requested.is_connected(_on_close):
		close_requested.connect(_on_close)


## 目標ランクの閾値。
static func goal_amount() -> int:
	for rank: Dictionary in GameData.RANKS:
		if rank["name"] == GameData.GOAL_RANK:
			return rank["threshold"]
	return 0


func _populate() -> void:
	_resolve()

	if is_instance_valid(_premise):
		_premise.text = (
			"あなたは駆け出しの商人。\n" +
			"手持ちは %s シルバーと、荷を積むロバが一頭きり。\n\n" +
			"5つの都市を結ぶ街道を巡り、%d日のうちにどれだけの財を築けるか。\n" +
			"中央のカーレオンは実入りが大きいが、そこへ至る道は無法地帯だ。"
		) % [UiUtil.format_number(GameData.INITIAL_SILVER), GameData.TOTAL_DAYS]

	if is_instance_valid(_goal_label):
		_goal_label.text = "目標: %d日目に純資産 %s を築き、%s となること" % [
			GameData.TOTAL_DAYS, UiUtil.format_number(goal_amount()), GameData.GOAL_RANK]

	_populate_ranks()

	if is_instance_valid(_hint):
		_hint.text = (
			"純資産は「シルバー ＋ 積荷と島倉庫の評価額」。\n" +
			"仕入れで手持ちが減っても、財産が減ったわけではない。\n\n" +
			"特産地では資源が安い。生産ボーナスのある都市なら、\n" +
			"その資源を装備に仕立てて運ぶ手もある。"
		)


## ランク表。目標のランクだけ色を変えて、どこを目指すのかを示す。
func _populate_ranks() -> void:
	if not is_instance_valid(_rank_list):
		return
	for child: Node in _rank_list.get_children():
		_rank_list.remove_child(child)
		child.queue_free()

	for rank: Dictionary in GameData.RANKS:
		var row := HBoxContainer.new()

		var name_label := Label.new()
		name_label.text = rank["name"]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		var threshold_label := Label.new()
		threshold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		threshold_label.text = ("%s 以上" % UiUtil.format_number(rank["threshold"])
			if rank["threshold"] > 0 else "それ未満")
		row.add_child(threshold_label)

		var color: Color = UiTheme.rank_color(rank["name"])
		if rank["name"] != GameData.GOAL_RANK:
			color = UiTheme.TEXT_DIM
		name_label.add_theme_color_override("font_color", color)
		threshold_label.add_theme_color_override("font_color", color)

		_rank_list.add_child(row)


## 表示する。再表示にも使える。
func show_briefing() -> void:
	_resolve()
	_populate()
	# 中身をウィンドウいっぱいに広げる（.tscn のアンカーだけでは 0 のまま）。
	UiUtil.fill_window(self)
	# ツリー外（--script のハーネス）では表示できない。文面だけ整えて返す。
	if is_inside_tree():
		popup_centered()


func _on_close() -> void:
	hide()
	closed.emit()
