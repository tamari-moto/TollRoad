extends PanelContainer
## 画面上部に常時表示される HUD。シルバー・日数・現在地・積載を表示する。
##
## 表示だけを担当し、ゲームのルールには関与しない。値は GameSession の
## シグナルを受けて更新する。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

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
	_session = session
	session.silver_changed.connect(_on_silver_changed)
	session.day_advanced.connect(_on_day_advanced)
	session.cargo_changed.connect(_refresh_cargo)
	refresh()


func refresh() -> void:
	_refresh_silver()
	_refresh_day()
	_refresh_cargo()


## 子ノードへの参照を解決する。解決済みなら何もしない。
func _resolve_nodes() -> void:
	if is_instance_valid(_silver_label):
		return
	_silver_label = _find("SilverLabel")
	_day_label = _find("DayLabel")
	_day_bar = _find("DayBar")
	_city_label = _find("CityLabel")
	_cargo_label = _find("CargoLabel")


## %記法はシーンのオーナー解決に依存し、ツリー外では引けないことがある。
## 引けなければ名前で再帰的に探す。
func _find(node_name: String) -> Node:
	var found: Node = get_node_or_null("%" + node_name)
	if found != null:
		return found
	return find_child(node_name, true, false)


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


## 桁区切りを入れる（1234567 -> 1,234,567）。
static func _format_number(value: int) -> String:
	var text: String = str(absi(value))
	var out: String = ""
	var count: int = 0
	for i: int in range(text.length() - 1, -1, -1):
		out = text[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out
