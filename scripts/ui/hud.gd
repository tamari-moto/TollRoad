extends PanelContainer
## 画面上部に常時表示される HUD。シルバー・日数・現在地・積載を表示する。
##
## 表示だけを担当し、ゲームのルールには関与しない。値は GameSession の
## シグナルを受けて更新する。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## @onready は使わない。ツリー投入の次フレームでエンジンが代入するため、
## bind() が add_child の直後に呼ばれると、手動で解決した参照を後から
## null で上書きしてしまう。_resolve_nodes() に一本化する。
var _silver_label: Label
var _net_worth_label: Label
var _goal_bar: ProgressBar
var _day_label: Label
var _day_bar: ProgressBar
var _city_label: Label
var _cargo_label: Label

var _session: GameSession

## 現在表示中のシルバー額。カウントアップの開始値に使う。
var _displayed_silver: int = 0
var _silver_tween: Tween
var _day_tween: Tween


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _on_silver_changed,
		"day_advanced": _on_day_advanced,
		"cargo_changed": _on_cargo_changed,
		# 島倉庫も純資産に入るため拾う。
		"warehouse_changed": _refresh_net_worth,
	})
	_session = session
	# 再プレイ時に前回の残額からカウントし始めないよう、表示値を揃えておく。
	_displayed_silver = session.silver
	if _silver_tween != null and _silver_tween.is_valid():
		_silver_tween.kill()
	refresh()


## 目標とするランクの閾値。ここに届けば「目標達成」とみなす。
## GameData.RANKS から引くので、バランス調整で数値が変わっても追従する。
static func goal_amount() -> int:
	for rank: Dictionary in GameData.RANKS:
		if rank["name"] == GameData.GOAL_RANK:
			return rank["threshold"]
	return 0


func refresh() -> void:
	_refresh_silver()
	_refresh_net_worth()
	_refresh_day()
	_refresh_cargo()


## 純資産と目標への進捗。
##
## シルバーだけを見ていると、仕入れは「お金が減る行為」にしか見えない。
## 純資産を並べて出すことで、積荷や島倉庫も資産として数えられていること
## ＝仕入れが投資であることが伝わるようにする。
func _refresh_net_worth() -> void:
	if not _is_ready() or not is_instance_valid(_net_worth_label):
		return
	var worth: int = _session.net_worth()
	var goal: int = goal_amount()

	_net_worth_label.text = "純資産 %s / 目標 %s" % [
		_format_number(worth), _format_number(goal)]
	# 目標に届いたら色で知らせる。
	_net_worth_label.add_theme_color_override(
		"font_color", UiTheme.GOOD if worth >= goal else UiTheme.TEXT)

	if is_instance_valid(_goal_bar):
		_goal_bar.max_value = maxf(float(goal), 1.0)
		_goal_bar.value = clampf(float(worth), 0.0, float(goal))


## 子ノードへの参照を解決する。解決済みなら何もしない。
func _resolve_nodes() -> void:
	if is_instance_valid(_silver_label):
		return
	_silver_label = UiUtil.find_node(self, "SilverLabel")
	_net_worth_label = UiUtil.find_node(self, "NetWorthLabel")
	_goal_bar = UiUtil.find_node(self, "GoalBar")
	_day_label = UiUtil.find_node(self, "DayLabel")
	_day_bar = UiUtil.find_node(self, "DayBar")
	_city_label = UiUtil.find_node(self, "CityLabel")
	_cargo_label = UiUtil.find_node(self, "CargoLabel")


## 表示を更新できる状態か。ノードは必要になった時点で解決する。
## is_inside_tree() は見ない（add_child 直後はまだ false を返すため）。
func _is_ready() -> bool:
	if _session == null:
		return false
	_resolve_nodes()
	return is_instance_valid(_silver_label)


func _refresh_silver() -> void:
	if not _is_ready():
		return
	_set_silver_text(_session.silver)
	_displayed_silver = _session.silver


## シルバーの変化を短くカウントアップ／ダウンさせ、増減を色で示す。
## ツリー外（--script のハーネス）では Tween が作れないため即座に反映する。
func _animate_silver(target: int) -> void:
	if not _is_ready():
		return
	if not is_inside_tree():
		_refresh_silver()
		return

	var from: int = _displayed_silver
	_displayed_silver = target
	if from == target:
		_set_silver_text(target)
		return

	if _silver_tween != null and _silver_tween.is_valid():
		_silver_tween.kill()

	# 増減の向きを一瞬だけ色で示してから標準色に戻す。
	_silver_label.add_theme_color_override(
		"font_color", UiTheme.GOOD if target > from else UiTheme.WARN)

	_silver_tween = create_tween()
	_silver_tween.set_parallel(true)
	_silver_tween.tween_method(_set_silver_text, from, target, UiTheme.TWEEN_DURATION)
	_silver_tween.tween_property(_silver_label, "theme_override_colors/font_color",
		UiTheme.TEXT, UiTheme.FLASH_DURATION)
	# Tween が途中で止まっても表示が最終値からずれないようにする。
	_silver_tween.chain().tween_callback(_set_silver_text.bind(target))


func _set_silver_text(value: int) -> void:
	if is_instance_valid(_silver_label):
		_silver_label.text = "%s シルバー" % _format_number(value)


func _refresh_day() -> void:
	if not _is_ready():
		return
	var total: int = GameData.TOTAL_DAYS
	var day: int = mini(_session.day, total)
	_day_label.text = "%d日目 / %d日" % [day, total]
	_day_bar.max_value = total
	_city_label.text = GameData.CITIES[_session.current_city]["name"]

	# バーだけは滑らかに伸ばす。ツリー外では即座に反映する。
	if not is_inside_tree():
		_day_bar.value = day
		return
	if _day_tween != null and _day_tween.is_valid():
		_day_tween.kill()
	_day_tween = create_tween()
	_day_tween.tween_property(_day_bar, "value", float(day), UiTheme.TWEEN_DURATION)


func _refresh_cargo() -> void:
	if not _is_ready():
		return
	_cargo_label.text = "積載 %d / %d" % [_session.cargo_weight(), _session.capacity()]


func _on_silver_changed(amount: int) -> void:
	_animate_silver(amount)
	_refresh_net_worth()


## 積荷が変われば積載量も純資産も変わる。
func _on_cargo_changed() -> void:
	_refresh_cargo()
	_refresh_net_worth()


func _on_day_advanced(_day: int) -> void:
	_refresh_day()
	_refresh_cargo()
	_refresh_net_worth()


## 桁区切りを入れる（1234567 -> 1,234,567）。実体は UiUtil。
static func _format_number(value: int) -> String:
	return UiUtil.format_number(value)
