extends "res://scripts/systems/scenario_base.gd"
## M5 の検証シナリオ。UI シーンが実際に構築され、HUD が値を反映し、
## 休息ボタンで日が進むことを確認する。
##
## --script は autoload を初期化しないため、ここでは Main.tscn を直接
## インスタンス化せず、UI シーン単体と GameSession の結線を検証する。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m5.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")



func _init() -> void:
	_test_display_settings()
	_test_scene_files_load()
	_test_hud_binding()
	_test_number_format()
	_finish()


func _test_display_settings() -> void:
	print("--- 解像度の設定 ---")
	var width: int = ProjectSettings.get_setting("display/window/size/viewport_width")
	var height: int = ProjectSettings.get_setting("display/window/size/viewport_height")
	var stretch: String = ProjectSettings.get_setting("display/window/stretch/mode")
	var aspect: String = ProjectSettings.get_setting("display/window/stretch/aspect")
	_check(width == 1280, "幅は1280", str(width))
	_check(height == 720, "高さは720", str(height))
	_check(stretch == "canvas_items", "stretch は canvas_items", stretch)
	_check(aspect == "expand", "aspect は expand", aspect)


func _test_scene_files_load() -> void:
	print("--- シーンの読み込み ---")
	_check(load("res://scenes/main/Main.tscn") != null, "Main.tscn が読み込める", "失敗")
	_check(load("res://scenes/ui/HUD.tscn") != null, "HUD.tscn が読み込める", "失敗")

	# 実際にノードを構築できるか（書式ミスはここで露見する）。
	# _spawn() 経由にすると、途中で検査が失敗して抜けても _finish() が
	# 取りこぼしを回収する（直に instantiate すると free に届かない経路ができる）。
	var hud: Node = _spawn("res://scenes/ui/HUD.tscn")
	_check(hud != null, "HUD をインスタンス化できる", "失敗")
	if hud != null:
		_check(hud.has_method("bind"), "HUD に bind がある", "ない")

		# unique_name_in_owner のノードが引ける（%記法の依存先）。
		for node_name: String in ["SilverLabel", "DayLabel", "DayBar", "CityLabel", "CargoLabel"]:
			_check(hud.get_node_or_null("%" + node_name) != null,
				"HUD の %%%s が引ける" % node_name, "見つからない")
		_despawn(hud)

	# Main.tscn も構築できること。ただし _ready は autoload を参照するため
	# 走らせず、ツリー構造だけを検査する（root へ入れても _ready は走らない。
	# 実測で is_node_ready() は false のまま）。
	var main: Node = _spawn("res://scenes/main/Main.tscn")
	_check(main != null, "Main をインスタンス化できる", "失敗")
	if main != null:
		for path: String in ["%HUD", "%LogScroll", "%LogList", "%RestButton", "%StatusLabel"]:
			_check(main.get_node_or_null(path) != null, "Main の %s が引ける" % path, "見つからない")
		_despawn(main)


func _test_hud_binding() -> void:
	print("--- HUD がセッションを反映する ---")
	var hud_scene: PackedScene = load("res://scenes/ui/HUD.tscn")
	if hud_scene == null:
		_check(false, "HUD.tscn が必要", "読み込めない")
		return

	var hud: Node = hud_scene.instantiate()
	# @onready を解決するためツリーに入れる。
	root.add_child(hud)

	var session: GameSession = GameSession.new(5001)
	hud.bind(session)

	var silver_label: Label = hud.get_node("%SilverLabel")
	var day_label: Label = hud.get_node("%DayLabel")
	var city_label: Label = hud.get_node("%CityLabel")
	var cargo_label: Label = hud.get_node("%CargoLabel")
	var day_bar: ProgressBar = hud.get_node("%DayBar")

	_check(silver_label.text.contains("30,000"), "初期シルバーが桁区切りで出る", silver_label.text)
	_check(day_label.text == "1日目 / 60日", "日数が出る", day_label.text)
	_check(city_label.text == GameData.CITIES[GameData.INITIAL_CITY]["name"], "現在地が出る", city_label.text)
	_check(cargo_label.text == "積載 0 / 40", "積載が出る", cargo_label.text)
	_check(day_bar.max_value == 60, "日数バーの最大が60", str(day_bar.max_value))

	# 購入するとシルバーと積載の表示が追従する。
	session.buy("ore", 10)
	_check(not silver_label.text.contains("30,000"), "購入でシルバー表示が変わる", silver_label.text)
	_check(cargo_label.text == "積載 10 / 40", "購入で積載表示が変わる", cargo_label.text)

	# 日が進むと日数表示とバーが追従する。
	session.rest()
	_check(day_label.text == "2日目 / 60日", "休息で日数表示が進む", day_label.text)
	_check(day_bar.value == 2, "日数バーが進む", str(day_bar.value))

	# 移動すると現在地表示が変わる。
	var neighbor: String = _adjacent_royal_city(session.current_city)
	session.move_to(neighbor)
	_check(city_label.text == GameData.CITIES[neighbor]["name"], "移動で現在地表示が変わる", city_label.text)

	# 60日を超えても日数表示は60で頭打ちになる（61日目と出さない）。
	while not session.is_over():
		session.rest()
	_check(day_label.text == "60日目 / 60日", "終了後も60日目と表示する", day_label.text)

	root.remove_child(hud)
	hud.free()


func _test_number_format() -> void:
	print("--- 桁区切り ---")
	# 桁区切りの実体は UiUtil にある（HUD はそれを呼ぶだけ）。
	_check(UiUtil.format_number(0) == "0", "0", UiUtil.format_number(0))
	_check(UiUtil.format_number(999) == "999", "999", UiUtil.format_number(999))
	_check(UiUtil.format_number(1000) == "1,000", "1,000", UiUtil.format_number(1000))
	_check(UiUtil.format_number(30000) == "30,000", "30,000", UiUtil.format_number(30000))
	_check(UiUtil.format_number(1234567) == "1,234,567", "1,234,567", UiUtil.format_number(1234567))
	_check(UiUtil.format_number(-2500) == "-2,500", "負の値", UiUtil.format_number(-2500))
