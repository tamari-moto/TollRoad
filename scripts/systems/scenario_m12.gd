extends "res://scripts/systems/scenario_base.gd"
## 騎乗・島の図と背景の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m12.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")



func _init() -> void:
	_test_mount_textures()
	_test_island_textures()
	_test_island_panel_art()
	_test_panel_style()
	_test_backdrop()
	_finish()


func _test_mount_textures() -> void:
	print("--- 騎乗の図 ---")
	for mount_id: String in GameData.MOUNTS:
		var texture: Texture2D = UiIcons.mount_texture(mount_id)
		_check(texture != null, "%s の図がある" % mount_id, "null")
	_check(UiIcons.mount_texture("nonexistent") == null, "未定義の騎乗は null", "null でない")

	# 品目・都市・騎乗が同名でも混ざらない。
	_check(UiIcons.mount_texture("ore") == null, "騎乗に品目名で引けない", "引けてしまった")


func _test_island_textures() -> void:
	print("--- 島の図 ---")
	# 島レベルは 0〜3 の4段階。
	for level: int in GameData.ISLAND_LEVELS.size():
		var texture: Texture2D = UiIcons.island_texture(level)
		_check(texture != null, "レベル%d の図がある" % level, "null")

	# 定義外のレベルでも落ちない。
	_check(UiIcons.island_texture(99) == null, "定義外のレベルは null", "null でない")
	_check(UiIcons.island_texture(-1) == null, "負のレベルも null", "null でない")

	# 段階ごとに別の画像であること（同じ絵を使い回していない）。
	var level0: Texture2D = UiIcons.island_texture(0)
	var level3: Texture2D = UiIcons.island_texture(3)
	_check(level0 != level3, "レベルごとに別の図", "同じ画像")


func _test_island_panel_art() -> void:
	print("--- 島パネルへの反映 ---")
	var panel: Node = _spawn("res://scenes/ui/IslandPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(12001)
	panel.bind(session)

	var image: TextureRect = UiUtil.find_node(panel, "IslandImage")
	_check(image != null, "IslandImage がある", "ない")
	if image == null:
		_despawn(panel)
		return

	_check(image.texture == UiIcons.island_texture(0), "初期はレベル0の図", "違う")

	# 拡張すると図が変わる。
	session.silver = 1000000
	session.upgrade_island()
	_check(image.texture == UiIcons.island_texture(1), "拡張でレベル1の図に変わる", "変わらない")
	session.upgrade_island()
	session.upgrade_island()
	_check(image.texture == UiIcons.island_texture(3), "最大でレベル3の図", "違う")

	# 騎乗ボタンに図が入り、テキストも残っている（既存の検査が依存）。
	var mount_list: VBoxContainer = UiUtil.find_node(panel, "MountList")
	_check(mount_list != null, "MountList がある", "ない")
	if mount_list != null:
		var with_icon: int = 0
		var with_text: int = 0
		for child: Node in mount_list.get_children():
			var button: Button = child as Button
			if button == null:
				continue
			if button.icon != null:
				with_icon += 1
			if button.text != "":
				with_text += 1
		_check(with_icon == 3, "騎乗3種に図が入る", str(with_icon))
		_check(with_text == 3, "テキストも維持される", str(with_text))

	_despawn(panel)


func _test_panel_style() -> void:
	print("--- パネルの外観 ---")
	var style: StyleBoxFlat = UiTheme.make_panel_style()
	_check(style != null, "パネルのスタイルが作れる", "null")
	_check(style.bg_color == UiTheme.PANEL_FILL, "地色がパレット由来", "違う")
	_check(style.border_color == UiTheme.PANEL_BORDER, "縁の色がパレット由来", "違う")
	_check(style.corner_radius_top_left == UiTheme.PANEL_RADIUS, "角が丸められる",
		str(style.corner_radius_top_left))

	# 下地は不透明（後ろが透けない）。
	var backdrop: StyleBoxFlat = UiTheme.make_backdrop_style()
	_check(backdrop.bg_color.a >= 0.99, "下地は不透明", str(backdrop.bg_color.a))

	# 適用すると override が付き、二重適用しても壊れない。
	var panel := PanelContainer.new()
	UiTheme.apply_panel_style(panel)
	_check(panel.has_theme_stylebox_override("panel"), "適用でスタイルが付く", "付かない")
	var applied: StyleBox = panel.get_theme_stylebox("panel")
	UiTheme.apply_panel_style(panel)
	_check(panel.get_theme_stylebox("panel") == applied, "二重適用で上書きしない", "上書きされた")
	panel.free()


func _test_backdrop() -> void:
	print("--- 下地の敷き方 ---")
	# Main.tscn の構造だけを確認する（_ready は autoload を要するため走らせない）。
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	_check(scene != null, "Main.tscn が読み込める", "失敗")
	if scene == null:
		return
	var main: Node = scene.instantiate()

	# 下地は _ready で動的に足すので、シーン上にはまだ無い。
	var root_control: Node = main.get_node_or_null("UI/Root")
	_check(root_control != null, "UI/Root がある", "ない")
	if root_control != null:
		_check(root_control.get_node_or_null("Backdrop") == null,
			"下地は実行時に足される（シーンには持たない）", "シーンにある")
		# HUD が Root の直下にあり、下地を差し込める構造になっている。
		_check(main.get_node_or_null("%HUD") != null, "HUD が引ける", "ない")
	main.free()
