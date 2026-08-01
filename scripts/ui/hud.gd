extends PanelContainer
## 画面上部に常時表示される HUD。シルバー・日数・現在地・積載を表示する。
##
## 表示だけを担当し、ゲームのルールには関与しない。値は GameSession の
## シグナルを受けて更新する。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

## @onready は使わない。ツリー投入の次フレームでエンジンが代入するため、
## bind() が add_child の直後に呼ばれると、手動で解決した参照を後から
## null で上書きしてしまう。_resolve_nodes() に一本化する。
var _silver_label: Label
var _day_label: Label
var _day_bar: ProgressBar
var _city_label: Label
var _cargo_label: Label

var _session: GameSession


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"silver_changed": _on_silver_changed,
		"day_advanced": _on_day_advanced,
		"cargo_changed": _refresh_cargo,
	})
	_session = session
	refresh()


func refresh() -> void:
	_refresh_silver()
	_refresh_day()
	_refresh_cargo()


## 子ノードへの参照を解決する。解決済みなら何もしない。
func _resolve_nodes() -> void:
	if is_instance_valid(_silver_label):
		return
	_silver_label = UiUtil.find_node(self, "SilverLabel")
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
	_silver_label.text = "%s シルバー" % _format_number(_session.silver)


func _refresh_day() -> void:
	if not _is_ready():
		return
	var total: int = GameData.TOTAL_DAYS
	var day: int = mini(_session.day, total)
	_day_label.text = "%d日目 / %d日" % [day, total]
	_day_bar.max_value = total
	_day_bar.value = day
	_city_label.text = GameData.CITIES[_session.current_city]["name"]


func _refresh_cargo() -> void:
	if not _is_ready():
		return
	_cargo_label.text = "積載 %d / %d" % [_session.cargo_weight(), _session.capacity()]


func _on_silver_changed(_amount: int) -> void:
	_refresh_silver()


func _on_day_advanced(_day: int) -> void:
	_refresh_day()
	_refresh_cargo()


## 桁区切りを入れる（1234567 -> 1,234,567）。実体は UiUtil。
static func _format_number(value: int) -> String:
	return UiUtil.format_number(value)
