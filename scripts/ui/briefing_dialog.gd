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
const UiIcons = preload("res://scripts/ui/ui_icons.gd")

signal closed
## 「続きから」が押された。main.gd が受けてセッションを差し替える。
signal continue_requested

var _premise: Label
var _goal_label: Label
var _rank_list: VBoxContainer
var _hint: Label
var _start_button: Button
var _continue_button: Button
var _companion_section: VBoxContainer
var _companion_buttons: Dictionary = {}

## 開始画面で選ばれた同行者。新規開始時に main.gd がこれを
## session.set_companion() へそのまま渡す。既定は「誰も同行しない」。
var selected_companion: String = GameData.COMPANION_NONE


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

	_build_companion_section()
	_build_continue_button()


## 「続きから」を開始ボタンの上に足す。.tscn を手で書き足すより、
## ここで組む方がアンカーとサイズの落とし穴を踏まない
## （ランク表の行を組んでいるのと同じやり方）。
func _build_continue_button() -> void:
	if is_instance_valid(_continue_button) or not is_instance_valid(_start_button):
		return
	var column: Node = _start_button.get_parent()
	if column == null:
		return

	_continue_button = Button.new()
	_continue_button.name = "ContinueButton"
	_continue_button.text = "続きから"
	_continue_button.custom_minimum_size = Vector2(0, 44)
	_continue_button.pressed.connect(_on_continue)
	column.add_child(_continue_button)
	# 開始ボタンの直前に置く。続きがある人はこちらを押すことが多い。
	column.move_child(_continue_button, _start_button.get_index())


## 同行者選びを開始ボタンの前に足す。新規開始のときだけ show_briefing() が
## 見せる（読み返しでは同行者は既に決まっているので出さない）。
## companion_panel.gd と同じボタンの組み方（肖像をアイコンに、選択中は無効化）。
func _build_companion_section() -> void:
	if is_instance_valid(_companion_section) or not is_instance_valid(_start_button):
		return
	var column: Node = _start_button.get_parent()
	if column == null:
		return

	_companion_section = VBoxContainer.new()
	_companion_section.name = "CompanionSection"
	_companion_section.add_theme_constant_override("separation", 6)

	var label := Label.new()
	label.text = "同行するギルド仲間を選ぶ（後からいつでも無料で切り替えられる）"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_companion_section.add_child(label)

	var none_button := Button.new()
	none_button.name = "CompanionNoneButton"
	none_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	none_button.custom_minimum_size = Vector2(0, 40)
	none_button.tooltip_text = "誰も同行しない。効果は無いが制約も無い"
	none_button.pressed.connect(_on_companion_pressed.bind(GameData.COMPANION_NONE))
	_companion_section.add_child(none_button)
	_companion_buttons[GameData.COMPANION_NONE] = none_button

	for companion_id: String in GameData.COMPANION_ORDER:
		var button := Button.new()
		button.name = "Companion_%s_Button" % companion_id
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, UiIcons.COMPANION_ICON_SIZE.y)

		var portrait: Texture2D = UiIcons.companion_texture(companion_id)
		if portrait != null:
			button.icon = portrait
			button.expand_icon = true
			button.add_theme_constant_override(
				"icon_max_width", int(UiIcons.COMPANION_ICON_SIZE.x))

		button.pressed.connect(_on_companion_pressed.bind(companion_id))
		_companion_section.add_child(button)
		_companion_buttons[companion_id] = button

	column.add_child(_companion_section)
	column.move_child(_companion_section, _start_button.get_index())
	_refresh_companion_buttons()


func _on_companion_pressed(companion_id: String) -> void:
	selected_companion = companion_id
	_refresh_companion_buttons()


func _refresh_companion_buttons() -> void:
	for companion_id: String in _companion_buttons:
		var button: Button = _companion_buttons[companion_id]
		if not is_instance_valid(button):
			continue
		var active: bool = selected_companion == companion_id
		if companion_id == GameData.COMPANION_NONE:
			button.text = "一人旅（同行者なし）%s" % ["・選択中" if active else ""]
		else:
			var data: Dictionary = GameData.COMPANIONS[companion_id]
			button.text = "%s — %s%s" % [data["name"], data["role"], "・選択中" if active else ""]
			button.tooltip_text = "%s\n%s" % [data["desc"], GameData.companion_stat_line(companion_id)]
		button.disabled = active


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
			"%d つの都市を結ぶ街道を巡り、%d日のうちにどれだけの財を築けるか。\n" +
			"中央の%sは実入りが大きいが、そこへ至る道は無法地帯だ。"
		) % [UiUtil.format_number(GameData.INITIAL_SILVER), GameData.royal_city_ids().size(), GameData.TOTAL_DAYS,
			GameData.CITIES[GameData.CAERLEON]["name"]]

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
	UiUtil.clear_children(_rank_list)

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
##
## can_continue が true のときだけ「続きから」を出す。呼び出し側が
## セーブの有無を判断して渡す（この画面は保存の仕組みを知らない）。
##
## choose_companion が true のときだけ同行者選びを出す。新規開始でだけ true
## になる（main.gd が starts_play をそのまま渡す）。true のたびに選択を
## 「同行者なし」へ戻す。新規セッションの同行者は毎回そこから始まるため。
func show_briefing(can_continue: bool = false, choose_companion: bool = false) -> void:
	_resolve()
	_populate()
	set_continue_available(can_continue)
	if choose_companion:
		selected_companion = GameData.COMPANION_NONE
	if is_instance_valid(_companion_section):
		_companion_section.visible = choose_companion
	_refresh_companion_buttons()
	# 中身をウィンドウいっぱいに広げる（.tscn のアンカーだけでは 0 のまま）。
	UiUtil.fill_window(self)
	# ツリー外（--script のハーネス）では表示できない。文面だけ整えて返す。
	if is_inside_tree():
		popup_centered()


## 「続きから」を出すかどうか。検査から状態を確かめるためにも使う。
func set_continue_available(available: bool) -> void:
	_resolve()
	if is_instance_valid(_continue_button):
		_continue_button.visible = available


## 「続きから」が出ているか。
func is_continue_available() -> bool:
	return is_instance_valid(_continue_button) and _continue_button.visible


func _on_continue() -> void:
	hide()
	continue_requested.emit()


func _on_close() -> void:
	hide()
	closed.emit()
