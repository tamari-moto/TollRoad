extends Node2D
## メイン画面。各画面パネルを束ね、日誌とリザルトを扱う。
##
## ゲームのルールは GameState.session（GameSession）にあり、ここは
## 表示と入力の橋渡しのみを行う。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const Sfx = preload("res://scripts/ui/sfx.gd")

## 航海日誌に表示する最大件数。古いものから捨てる。
const LOG_DISPLAY_LIMIT: int = 200

## サイドパネルが開いた時の幅（px）。閉じた時のオフセットからこの幅ぶん
## 左へ広げる。Main.tscn の SidePanel の初期状態（閉）と合わせること。
## 市場画面を大きくタップしやすくするため拡大した。5画面共有のため
## 全タブに影響する（Main.tscn の Tabs.custom_minimum_size.x も合わせて拡げてある）。
const SIDE_PANEL_WIDTH: float = 480.0

@onready var _hud: PanelContainer = %HUD
@onready var _tabs: TabContainer = %Tabs
@onready var _side_panel: PanelContainer = %SidePanel
@onready var _tab_strip_buttons: Array[Button] = [
	%MarketTabButton, %CargoTabButton, %WorkshopTabButton, %MemoTabButton, %IslandTabButton,
]
@onready var _log_scroll: ScrollContainer = %LogScroll
@onready var _log_list: VBoxContainer = %LogList
@onready var _rest_button: Button = %RestButton
@onready var _briefing_button: Button = %BriefingButton
@onready var _result_button: Button = %ResultButton
@onready var _status_label: Label = %StatusLabel
@onready var _result_dialog: Window = %ResultDialog
@onready var _briefing_dialog: Window = %BriefingDialog

var _session: GameSession

## bind と refresh を持つ画面パネル。日送り時にまとめて更新する。
var _panels: Array[Node] = []

## 効果音。
var _sfx: Sfx

## サイドパネルが開いているか。
var _side_panel_open: bool = false
## サイドパネルの「閉」状態での offset_left。Main.tscn の初期値をそのまま覚える。
var _side_panel_closed_offset: float = 0.0
var _side_panel_tween: Tween


func _ready() -> void:
	_panels = [%大陸図, %MarketPanel, %CargoPanel, %製作所, %相場メモ, %島と装備]

	_rest_button.pressed.connect(_on_rest_pressed)
	_result_button.pressed.connect(_show_result)
	_briefing_button.pressed.connect(_show_briefing)
	_result_dialog.restart_requested.connect(_on_restart_requested)
	_briefing_dialog.continue_requested.connect(_on_continue_requested)
	_briefing_dialog.closed.connect(_on_briefing_closed)
	_briefing_button.tooltip_text = "目標とヒントをもう一度読む"

	_apply_backdrop()
	_setup_trade_sfx()
	_setup_sfx()
	_rest_button.tooltip_text = "1日を消費して待機する（Space）\n相場が動き、島の労働者が働く"

	_side_panel_closed_offset = _side_panel.offset_left
	for index: int in _tab_strip_buttons.size():
		var button: Button = _tab_strip_buttons[index]
		button.pressed.connect(_on_tab_strip_pressed.bind(index))
		button.tooltip_text = "%s（%d キー）" % [button.text, index + 1]
	_refresh_tab_strip_highlight()

	_bind_session(GameState.session)


## セッションを各画面に配る。再プレイ時にも呼ばれる。
##
## with_briefing を false にすると開始画面を出さない（「続きから」で
## 復帰した直後は、いま閉じた画面をもう一度開かない）。
func _bind_session(session: GameSession, with_briefing: bool = true) -> void:
	_session = session
	print("TollRoad start. Day: %d/%d, Silver: %d, City: %s" % [
		_session.day, GameData.TOTAL_DAYS, _session.silver, _session.current_city])

	_hud.bind(_session)
	for panel: Node in _panels:
		panel.bind(_session)
	_result_dialog.bind(_session)

	_session.logged.connect(_append_log)
	_session.day_advanced.connect(_on_day_advanced)

	_clear_log()
	# 過去ログの復元では音を鳴らさない（全件が一斉に鳴ってしまう）。
	for entry: String in _session.log_entries:
		_append_log(entry, false)

	_rest_button.disabled = false
	_result_button.visible = false
	_refresh_status()

	# 1日目に何を目指すのかを伝える。再プレイでも同様に出す。
	if with_briefing:
		_show_briefing()


## 開始画面を出す。続きから始められるセーブがあれば、その選択肢も出す。
func _show_briefing() -> void:
	_briefing_dialog.show_briefing(GameState.has_save())


## 開始画面を閉じた＝このセッションで始めると決まった。
##
## 前のプレイのセーブはここで**捨てる**。save_game() で上書きすると、
## 起動直後のセッションは1日目なので、進行中のセーブが1日目に化けて
## 消えたのと同じことになる（実際にそうなっていた）。
func _on_briefing_closed() -> void:
	SaveManager.delete_save()
	GameState.save_game()


## 「続きから」。セーブを読み、各画面へ配り直す。
##
## 切断は読み込みが成功してからにする。先に切ると、失敗したときに
## 日誌もパネル更新も止まったまま復帰できない。
func _on_continue_requested() -> void:
	if not GameState.continue_game():
		_append_log("セーブデータを読み込めなかった。%s" % SaveManager.last_error())
		return
	_disconnect_session()
	_bind_session(GameState.session, false)


## 画面全体の下地を敷き、各パネルに共通の地色を与える。
## パネルごとに書かず、ここでまとめて適用する。
func _apply_backdrop() -> void:
	var root_control: Control = %HUD.get_parent()
	if root_control == null:
		return

	# 下地は最背面に敷く。大陸図の外側（空）はここが透けて見える。
	var backdrop := Panel.new()
	backdrop.name = "Backdrop"
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.add_theme_stylebox_override("panel", UiTheme.make_backdrop_style())
	root_control.add_child(backdrop)
	root_control.move_child(backdrop, 0)

	# 大陸図は画面全体の背景として敷くため、他パネルと同じ不透明な地色は
	# 与えない（3D世界がそのまま背景として見えるようにする）。
	var map_panel: Control = %大陸図
	map_panel.add_theme_stylebox_override("panel", UiTheme.make_transparent_style())

	UiTheme.apply_panel_style(_hud)
	UiTheme.apply_panel_style(%TabStrip as Control)
	UiTheme.apply_panel_style(_side_panel)
	UiTheme.apply_panel_style(%LogActions as Control)
	for panel: Node in _panels:
		if panel == map_panel:
			continue
		UiTheme.apply_panel_style(panel as Control)


## タブボタン帯のボタンが押された。閉じていれば該当タブを開き、
## 開いていれば（同じボタンでも別のボタンでも）閉じる。
func _on_tab_strip_pressed(index: int) -> void:
	if _side_panel_open:
		_close_side_panel()
		return
	_tabs.current_tab = index
	_open_side_panel()


func _open_side_panel() -> void:
	_side_panel_open = true
	_side_panel.visible = true
	_animate_side_panel(_side_panel_closed_offset - SIDE_PANEL_WIDTH)
	_refresh_tab_strip_highlight()


func _close_side_panel() -> void:
	_side_panel_open = false
	_animate_side_panel(_side_panel_closed_offset)
	if not is_inside_tree():
		_side_panel.visible = false
	_refresh_tab_strip_highlight()


## サイドパネルの左端をスライドさせる。ツリー外（--script のハーネス）
## では Tween が作れないため即座に反映する（hud.gd の _animate_silver()
## と同じ形）。
func _animate_side_panel(target_offset: float) -> void:
	if not is_inside_tree():
		_side_panel.offset_left = target_offset
		return
	if _side_panel_tween != null and _side_panel_tween.is_valid():
		_side_panel_tween.kill()
	_side_panel_tween = create_tween()
	_side_panel_tween.tween_property(_side_panel, "offset_left", target_offset, UiTheme.TWEEN_DURATION)
	if target_offset == _side_panel_closed_offset:
		_side_panel_tween.tween_callback(func() -> void: _side_panel.visible = false)


## どのタブが開いているかをボタンの押下状態で示す。閉じていれば全て非押下。
func _refresh_tab_strip_highlight() -> void:
	for index: int in _tab_strip_buttons.size():
		_tab_strip_buttons[index].button_pressed = _side_panel_open and _tabs.current_tab == index


## サイドパネルが開いているか。検査から直接呼べるよう公開している。
func is_side_panel_open() -> bool:
	return _side_panel_open


## 市場の売買成立を効果音に繋ぐ。市場と積荷は別タブで同時には映らないため、
## アイコンを飛ばす演出はせず、即座に反映して音だけ鳴らす。
func _setup_trade_sfx() -> void:
	var market: Node = %MarketPanel
	if market.has_signal("traded") and not market.traded.is_connected(_on_traded):
		market.traded.connect(_on_traded)


func _setup_sfx() -> void:
	_sfx = Sfx.new()
	_sfx.name = "Sfx"
	add_child(_sfx)


func _on_traded(_item_id: String, is_buy: bool, _origin: Vector2) -> void:
	_play(Sfx.Kind.BUY if is_buy else Sfx.Kind.SELL)


func _play(kind: Sfx.Kind) -> void:
	if _sfx != null and is_instance_valid(_sfx):
		_sfx.play(kind)


## 航海日誌の内容から音を選ぶ。
## 売買はボタン側で鳴らすため、ここでは扱わない（二重に鳴らさない）。
func _play_for_log(message: String) -> void:
	if message.contains("襲撃"):
		_play(Sfx.Kind.RAID)
	elif message.contains("製作"):
		_play(Sfx.Kind.CRAFT)
	elif message.contains("拡張") or message.contains("購入した"):
		_play(Sfx.Kind.UPGRADE)
	elif message.contains("移動"):
		_play(Sfx.Kind.TRAVEL)
	elif message.contains("休息") or message.contains("引き取"):
		_play(Sfx.Kind.DAY)


## キー操作。_input ではなく _unhandled_input を使うのは、ボタンや
## ダイアログにフォーカスがある時にキーを奪わないため。
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return

	if event.is_action("tr_rest"):
		if not _rest_button.disabled:
			_session.rest()
		get_viewport().set_input_as_handled()
		return

	for index: int in _tab_strip_buttons.size():
		if event.is_action("tr_tab_%d" % (index + 1)):
			_on_tab_strip_pressed(index)
			get_viewport().set_input_as_handled()
			return


func _on_rest_pressed() -> void:
	_session.rest()


func _on_day_advanced(_day: int) -> void:
	# 移動で現在地が変わると相場も製作ボーナスも変わるため、まとめて更新する。
	for panel: Node in _panels:
		panel.refresh()
	_refresh_status()

	if _session.is_over():
		_show_result()


func _refresh_status() -> void:
	if _session.is_over():
		_rest_button.disabled = true
		_result_button.visible = true
		_status_label.text = "60日が終了した。純資産 %d（%s）" % [
			_session.net_worth(), _session.rank()]
		return
	if _session.is_stranded():
		_status_label.text = "資金が尽きて移動できない。休息して島の収入を待つしかない。"
	else:
		_status_label.text = ""


func _show_result() -> void:
	_result_dialog.show_result()


func _on_restart_requested() -> void:
	_disconnect_session()
	GameState.start_new_game()
	_bind_session(GameState.session)


## 古いセッションのシグナルを切る。繋ぎ替えの前に必ず呼ぶ。
func _disconnect_session() -> void:
	if _session == null:
		return
	if _session.logged.is_connected(_append_log):
		_session.logged.disconnect(_append_log)
	if _session.day_advanced.is_connected(_on_day_advanced):
		_session.day_advanced.disconnect(_on_day_advanced)


func _clear_log() -> void:
	for child: Node in _log_list.get_children():
		_log_list.remove_child(child)
		child.queue_free()


func _append_log(message: String, with_sound: bool = true) -> void:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 積荷の全損は最も重い事象なので、その行だけ色を変えて見落とさせない。
	if message.contains("襲撃"):
		label.add_theme_color_override("font_color", UiTheme.WARN)
	_log_list.add_child(label)
	if with_sound:
		_play_for_log(message)

	while _log_list.get_child_count() > LOG_DISPLAY_LIMIT:
		var oldest: Node = _log_list.get_child(0)
		_log_list.remove_child(oldest)
		oldest.queue_free()

	# 追加直後はまだレイアウトが確定していないので、1フレーム待ってから最下部へ。
	await get_tree().process_frame
	if is_instance_valid(_log_scroll):
		_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)
