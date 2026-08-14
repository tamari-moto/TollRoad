extends PanelContainer
## 画面上部に常時表示される HUD。シルバー・現在地・積載を表示する。
##
## 表示だけを担当し、ゲームのルールには関与しない。値は GameSession の
## シグナルを受けて更新する。純資産の目標・残り日数は
## [GoalPanel](res://scripts/ui/goal_panel.gd) が別パネルとして担う。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## @onready は使わない。ツリー投入の次フレームでエンジンが代入するため、
## bind() が add_child の直後に呼ばれると、手動で解決した参照を後から
## null で上書きしてしまう。_resolve_nodes() に一本化する。
var _silver_label: Label
var _city_label: Label
var _cargo_label: Label

var _session: GameSession

## 現在表示中のシルバー額。カウントアップの開始値に使う。
var _displayed_silver: int = 0
var _silver_tween: Tween


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _on_silver_changed,
		"day_advanced": _on_day_advanced,
		"cargo_changed": _refresh_cargo,
	})
	_session = session
	# 再プレイ時に前回の残額からカウントし始めないよう、表示値を揃えておく。
	_displayed_silver = session.silver
	if _silver_tween != null and _silver_tween.is_valid():
		_silver_tween.kill()
	refresh()


func refresh() -> void:
	_refresh_silver()
	_refresh_city()
	_refresh_cargo()


## 子ノードへの参照を解決する。解決済みなら何もしない。
func _resolve_nodes() -> void:
	if is_instance_valid(_silver_label):
		return
	_silver_label = UiUtil.find_node(self, "SilverLabel")
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
		_silver_label.text = "%s シルバー" % UiUtil.format_number(value)


func _refresh_city() -> void:
	if not _is_ready():
		return
	_city_label.text = GameData.CITIES[_session.current_city]["name"]


func _refresh_cargo() -> void:
	if not _is_ready():
		return
	_cargo_label.text = "積載 %d / %d" % [_session.cargo_weight(), _session.capacity()]


func _on_silver_changed(amount: int) -> void:
	_animate_silver(amount)


func _on_day_advanced(_day: int) -> void:
	_refresh_city()
	_refresh_cargo()
