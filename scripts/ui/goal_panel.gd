extends PanelContainer
## 画面右上に常時表示される目標パネル。純資産の目標到達度と残り日数を表示する。
##
## HUD 本体（シルバー・現在地・積載）とは別パネルに分けてある。見るべき
## タイミングが違う（HUD は取引の都度、こちらは進捗の確認）ため。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## @onready は使わない。ツリー投入の次フレームでエンジンが代入するため、
## bind() が add_child の直後に呼ばれると、手動で解決した参照を後から
## null で上書きしてしまう。_resolve_nodes() に一本化する。
var _net_worth_label: Label
var _goal_bar: ProgressBar
var _day_label: Label
var _day_bar: ProgressBar

var _session: GameSession
var _day_tween: Tween


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _refresh_net_worth,
		"day_advanced": _on_day_advanced,
		"cargo_changed": _refresh_net_worth,
		# 島倉庫も純資産に入るため拾う。
		"warehouse_changed": _refresh_net_worth,
	})
	_session = session
	refresh()


## 目標とするランクの閾値。ここに届けば「目標達成」とみなす。
## GameData.RANKS から引くので、バランス調整で数値が変わっても追従する。
static func goal_amount() -> int:
	for rank: Dictionary in GameData.RANKS:
		if rank["name"] == GameData.GOAL_RANK:
			return rank["threshold"]
	return 0


func refresh() -> void:
	_refresh_net_worth()
	_refresh_day()


## 純資産と目標への進捗。
##
## シルバーだけを見ていると、仕入れは「お金が減る行為」にしか見えない。
## 純資産を並べて出すことで、積荷や島倉庫も資産として数えられていること
## ＝仕入れが投資であることが伝わるようにする。
func _refresh_net_worth() -> void:
	if not _is_ready():
		return
	var worth: int = _session.net_worth()
	var goal: int = goal_amount()

	_net_worth_label.text = "純資産 %s / 目標 %s" % [
		UiUtil.format_number(worth), UiUtil.format_number(goal)]
	# 目標に届いたら色で知らせる。
	_net_worth_label.add_theme_color_override(
		"font_color", UiTheme.GOOD if worth >= goal else UiTheme.TEXT)

	_goal_bar.max_value = maxf(float(goal), 1.0)
	_goal_bar.value = clampf(float(worth), 0.0, float(goal))


## 子ノードへの参照を解決する。解決済みなら何もしない。
func _resolve_nodes() -> void:
	if is_instance_valid(_net_worth_label):
		return
	_net_worth_label = UiUtil.find_node(self, "NetWorthLabel")
	_goal_bar = UiUtil.find_node(self, "GoalBar")
	_day_label = UiUtil.find_node(self, "DayLabel")
	_day_bar = UiUtil.find_node(self, "DayBar")


## 表示を更新できる状態か。ノードは必要になった時点で解決する。
func _is_ready() -> bool:
	if _session == null:
		return false
	_resolve_nodes()
	return is_instance_valid(_net_worth_label)


func _refresh_day() -> void:
	if not _is_ready():
		return
	var total: int = GameData.TOTAL_DAYS
	var day: int = mini(_session.day, total)
	_day_label.text = "残り%d日" % (total - day)
	_day_bar.max_value = total

	# バーだけは滑らかに伸ばす。ツリー外では即座に反映する。
	if not is_inside_tree():
		_day_bar.value = day
		return
	if _day_tween != null and _day_tween.is_valid():
		_day_tween.kill()
	_day_tween = create_tween()
	_day_tween.tween_property(_day_bar, "value", float(day), UiTheme.TWEEN_DURATION)


func _on_day_advanced(_day: int) -> void:
	_refresh_day()
	_refresh_net_worth()
