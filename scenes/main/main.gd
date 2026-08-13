extends Node2D
## メイン画面。各画面パネルを束ね、日誌とリザルトを扱う。
##
## ゲームのルールは GameSession にあり、ここは表示と入力の橋渡しのみを行う。
##
## **autoload を識別子（`GameState`）として書かないこと。** 識別子は
## コンパイル時に autoload レジストリを引くため、`--script` のハーネスから
## この main.gd 自体がロードできなくなり、UI ハンドラを検査できなくなる。
## セッションの供給元は `_resolve_state()` が実行時に引き、検査は
## `bind_state()` で差し込む。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")
## preload はパスからの読み込みで autoload レジストリを引かないため、
## 識別子と違って --script でも解決できる（型注釈のために使う）。
const GameStateScript = preload("res://scripts/autoload/game_state.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const Sfx = preload("res://scripts/ui/sfx.gd")

## 航海日誌に表示する最大件数。古いものから捨てる。
const LOG_DISPLAY_LIMIT: int = 200

## サイドパネルが開いた時の幅（px）。閉じた時のオフセットからこの幅ぶん
## 左へ広げる。Main.tscn の SidePanel の初期状態（閉）と合わせること。
## 市場画面を大きくタップしやすくするため拡大した。5画面共有のため
## 全タブに影響する（Main.tscn の Tabs.custom_minimum_size.x も合わせて拡げてある）。
##
## 480 だと市場画面の「売る」列がスクロールしないと見えなかった
## （実測: ItemGrid.get_combined_minimum_size().x = 530、そこへ
## SidePanelMargin・MarketPanel自身のMargin・縦スクロールバーぶんの
## 余白が要る）。
const SIDE_PANEL_WIDTH: float = 600.0

## ノードは @onready ではなく _resolve_nodes() で引く。
## @onready はツリー投入の次フレームにエンジンが代入するため、--script の
## ハーネスから add_child() した直後の _ready() では**まだ null**になり、
## 接続がまるごと失敗する（実測）。hud.gd と同じ形に揃えてある。
var _hud: PanelContainer
var _tabs: TabContainer
var _side_panel: PanelContainer
var _tab_strip_buttons: Array[Button] = []
var _log_scroll: ScrollContainer
var _log_list: VBoxContainer
var _rest_button: Button
var _briefing_button: Button
var _result_button: Button
var _status_label: Label
var _result_dialog: Window
var _briefing_dialog: Window

var _session: GameSession

## セッションの供給元。本編では autoload の GameState、検査では
## bind_state() で差し込まれた同じ型のインスタンス。
var _state: GameStateScript

## 今開いている開始画面が新規開始の入口か。閉じたときの扱いを分ける。
var _briefing_starts_play: bool = false

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
	_configure()
	_bind_session(_state_session())


## 画面の結線とスタイル適用。**_ready() と bind_state() の両方から呼べる。**
##
## --script のハーネスでは add_child() しても _ready() が走らない
## （実測: is_node_ready() は false のまま）。初期化を _ready() に閉じ込めると
## 検査からは未結線のまま触ることになるため、こちらへ切り出してある
## （fx_layer.gd の _configure() と同じ形）。二度呼ばれても害が無いよう、
## 接続はすべて is_connected でガードする。
func _configure() -> void:
	_resolve_nodes()
	if _rest_button == null:
		return

	_connect_once(_rest_button.pressed, _on_rest_pressed)
	_connect_once(_result_button.pressed, _show_result)
	_connect_once(_result_dialog.restart_requested, _on_restart_requested)
	_connect_once(_briefing_dialog.continue_requested, _on_continue_requested)
	_connect_once(_briefing_dialog.closed, _on_briefing_closed)

	# 目標の読み返し。新規開始ではないので、閉じてもセーブに触らない。
	var reread: Callable = _show_briefing.bind(false)
	if not _briefing_button.pressed.is_connected(reread):
		_briefing_button.pressed.connect(reread)
	_briefing_button.tooltip_text = "目標とヒントをもう一度読む"

	_apply_backdrop()
	_setup_trade_sfx()
	_setup_sfx()
	_rest_button.tooltip_text = "1日を消費して待機する（Space）\n相場が動き、島の労働者が働く"

	_side_panel_closed_offset = _side_panel.offset_left
	for index: int in _tab_strip_buttons.size():
		var button: Button = _tab_strip_buttons[index]
		var handler: Callable = _on_tab_strip_pressed.bind(index)
		if not button.pressed.is_connected(handler):
			button.pressed.connect(handler)
		button.tooltip_text = "%s（%d キー）" % [button.text, index + 1]
	_refresh_tab_strip_highlight()


func _connect_once(sig: Signal, handler: Callable) -> void:
	if not sig.is_connected(handler):
		sig.connect(handler)


## 画面のノードを名前で引く。@onready を使わない理由は宣言のところに書いた。
## %記法はツリー外で引けないことがあるため UiUtil.find_node() を通す。
func _resolve_nodes() -> void:
	if is_instance_valid(_hud):
		return
	_hud = UiUtil.find_node(self, "HUD")
	_tabs = UiUtil.find_node(self, "Tabs")
	_side_panel = UiUtil.find_node(self, "SidePanel")
	_log_scroll = UiUtil.find_node(self, "LogScroll")
	_log_list = UiUtil.find_node(self, "LogList")
	_rest_button = UiUtil.find_node(self, "RestButton")
	_briefing_button = UiUtil.find_node(self, "BriefingButton")
	_result_button = UiUtil.find_node(self, "ResultButton")
	_status_label = UiUtil.find_node(self, "StatusLabel")
	_result_dialog = UiUtil.find_node(self, "ResultDialog")
	_briefing_dialog = UiUtil.find_node(self, "BriefingDialog")

	_tab_strip_buttons.clear()
	for node_name: String in ["MarketTabButton", "CargoTabButton",
			"WorkshopTabButton", "MemoTabButton", "IslandTabButton",
			"ExplorationTabButton"]:
		var button: Button = UiUtil.find_node(self, node_name)
		if button != null:
			_tab_strip_buttons.append(button)

	_panels = []
	for node_name: String in ["大陸図", "MarketPanel", "CargoPanel",
			"製作所", "相場メモ", "島と装備", "探索"]:
		var panel: Node = UiUtil.find_node(self, node_name)
		if panel != null:
			_panels.append(panel)


## セッションの供給元を確定する。既に持っていれば何もしない。
##
## autoload は `get_node_or_null()` で引く。識別子として書くと
## コンパイル時に autoload レジストリを引き、`--script` では
## main.gd 自体がロードできなくなる。
## autoload が無い環境（検査）では null のままで、bind_state() を待つ。
func _resolve_state() -> void:
	if _state != null:
		return
	_state = get_node_or_null("/root/GameState") as GameStateScript


## セッションの供給元を差し込む。**検査から呼ぶための入口。**
##
## --script のハーネスでは autoload が初期化されないため /root/GameState を
## 引けない。実物の game_state.gd を .new() してここへ渡せば、UI ハンドラを
## 実物のまま走らせられる。本編では呼ばれない。
## 検査は add_child() しても _ready() が走らない（実測: is_node_ready() は
## false のまま）。ノードの解決をここでも通しておかないと、_hud などが
## null のまま配布に入って落ちる。_ready() と両方から呼べる形にしてある
## （CLAUDE.md の「_ready() に初期化を置かない」と同じ考え方）。
func bind_state(state: GameStateScript, with_session: bool = true) -> void:
	_configure()
	_state = state
	if with_session and _state != null and _state.session != null:
		_bind_session(_state.session)


# --- 供給元への問い合わせ ---
#
# null の判断をここへ閉じる。各ハンドラに撒くと、抜けが1つでもあると
# そこだけ落ちる（しかも検査を書きたいのはまさにその経路）。

func _state_session() -> GameSession:
	_resolve_state()
	return _state.session if _state != null else null


func _state_has_save() -> bool:
	_resolve_state()
	return _state.has_save() if _state != null else false


func _state_save_game() -> bool:
	_resolve_state()
	return _state.save_game() if _state != null else false


func _state_continue_game() -> bool:
	_resolve_state()
	return _state.continue_game() if _state != null else false


func _state_start_new_game() -> void:
	_resolve_state()
	if _state != null:
		_state.start_new_game()


## セッションを各画面に配る。再プレイ時にも呼ばれる。
##
## with_briefing を false にすると開始画面を出さない（「続きから」で
## 復帰した直後は、いま閉じた画面をもう一度開かない）。
func _bind_session(session: GameSession, with_briefing: bool = true) -> void:
	# 供給元がまだ無い（autoload の無い検査環境で bind_state() 前）ときは
	# 何もしない。ここで弾いておけば、以降のハンドラに null チェックが要らない。
	# _ready() は無害に完走し、パネルの結線とスタイル適用までは済む。
	if session == null:
		return
	_session = session
	print("TollRoad start. Day: %d/%d, Silver: %d, City: %s" % [
		_session.day, GameData.TOTAL_DAYS, _session.silver, _session.current_city])

	_hud.bind(_session)
	for panel: Node in _panels:
		panel.bind(_session)
	_result_dialog.bind(_session)

	# 二重接続を防ぐ。Godot は重複を拒否するが、そのたびに赤いエラーを出す。
	# 同ファイルの他の接続はどれもガード付きで、ここだけが例外だった。
	if not _session.logged.is_connected(_append_log):
		_session.logged.connect(_append_log)
	if not _session.day_advanced.is_connected(_on_day_advanced):
		_session.day_advanced.connect(_on_day_advanced)

	_clear_log()
	# 過去ログの復元では音を鳴らさない（全件が一斉に鳴ってしまう）。
	for entry: String in _session.log_entries:
		_append_log(entry, false)

	_rest_button.disabled = false
	_result_button.visible = false
	_refresh_status()

	# 1日目に何を目指すのかを伝える。再プレイでも同様に出す。
	# これは新規開始の入口なので、閉じた時点でそのセッションを保存する。
	if with_briefing:
		_show_briefing(true)


## 開始画面を出す。続きから始められるセーブがあれば、その選択肢も出す。
##
## starts_play は「これが新規開始の入口か」。起動直後の1回だけ true で、
## HUD の「目標」ボタンから読み返すときは false。閉じたときにセーブへ
## 触ってよいかを、画面ではなく呼び出し側が決める（開始画面は保存の
## 仕組みを知らないままにしておく）。
func _show_briefing(starts_play: bool = false) -> void:
	_briefing_starts_play = starts_play
	_briefing_dialog.show_briefing(_state_has_save())


## 開始画面を閉じた。新規開始の入口だったときだけ、そのセッションを保存する。
##
## **読み返しでは何もしない。** 「目標」ボタンから開き直して閉じただけで
## セーブを作り直すと、進行中の記録を壊す道が増えるため。
##
## delete_save() は呼ばない。save_game() は同じパスへ上書きするので古い
## 記録は残らず、消す工程が無ければ「消したが書けなかった」窓も生まれない。
func _on_briefing_closed() -> void:
	if not _briefing_starts_play:
		return
	_briefing_starts_play = false
	_state_save_game()


## 「続きから」。セーブを読み、各画面へ配り直す。
##
## 切断は読み込みが成功してからにする。先に切ると、失敗したときに
## 日誌もパネル更新も止まったまま復帰できない。
func _on_continue_requested() -> void:
	if not _state_continue_game():
		_append_log("セーブデータを読み込めなかった。%s" % SaveManager.last_error())
		return
	_disconnect_session()
	_bind_session(_state_session(), false)


## 大陸図の3D世界がそのまま画面全体の背景として見えるよう、他パネルと同じ
## 不透明な地色を与えない。大陸図の自前の Sky が不透明に描画されるため
## （SubViewport.transparent_bg = false）、この背後に別の下地は要らない。
func _apply_backdrop() -> void:
	var map_panel: Control = UiUtil.find_node(self, "大陸図")
	map_panel.add_theme_stylebox_override("panel", UiTheme.make_transparent_style())

	UiTheme.apply_panel_style(_hud)
	UiTheme.apply_panel_style(UiUtil.find_node(self, "TabStrip") as Control)
	UiTheme.apply_panel_style(_side_panel)
	UiTheme.apply_panel_style(UiUtil.find_node(self, "LogActions") as Control)
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
	var market: Node = UiUtil.find_node(self, "MarketPanel")
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
	elif message.contains("探索"):
		_play(Sfx.Kind.EXPLORE)
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
	_state_start_new_game()
	_bind_session(_state_session())


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
	# 探索失敗も戦闘装備を失う重い事象なので同様に扱う。
	if message.contains("襲撃") or message.contains("探索失敗"):
		label.add_theme_color_override("font_color", UiTheme.WARN)
	_log_list.add_child(label)
	if with_sound:
		_play_for_log(message)

	while _log_list.get_child_count() > LOG_DISPLAY_LIMIT:
		var oldest: Node = _log_list.get_child(0)
		_log_list.remove_child(oldest)
		oldest.queue_free()

	# 追加直後はまだレイアウトが確定していないので、1フレーム待ってから最下部へ。
	# ツリー外（--script のハーネス）では get_tree() が null で、そもそも
	# フレームが進まない。待たずに戻る（スクロール位置は本編でしか意味がない）。
	if get_tree() == null:
		return
	await get_tree().process_frame
	if is_instance_valid(_log_scroll):
		_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)
