extends Window
## 運送デバッグ画面（logistics_debug_panel.gd）を入れる**別ウィンドウ**。
##
## オーバーレイをやめて OS のウィンドウにした理由は場所の取り合い。パネルは
## 1180x760 あり、既定のビューポート（1280x720）ではほぼ全面を覆う。物流の
## 調整は「値をいじる → 日を進める → 地図で荷車を見る」の繰り返しなので、
## 本編とデバッグ画面を交互に隠し合うと、見比べたい2つが同時に見られない。
## 別ウィンドウなら並べて置ける（別モニタへも出せる）。
##
## **`force_native` は Godot 4.3 以降。** これが無いと、`Window` は親ビューポートの
## `gui_embed_subwindows` に従って**本編のウィンドウの中に埋め込まれる**
## （＝オーバーレイに戻る）。プロジェクト設定の `embed_subwindows` を false に
## する手もあるが、それだと開始画面・リザルトの2つのダイアログまで OS の
## ウィンドウになり、本編の見た目が変わる。ここだけを native にする。
##
## `force_native` が platform 側の都合で効かなかった場合は埋め込みに落ちる。
## その場合もタイトルバー付きの移動できるウィンドウとして成立するので、
## 壊れはしない（オーバーレイに戻るだけ）。
##
## **中身は一切持たない。** グラフも 3D も調整欄も logistics_debug_panel.gd に
## あり、こちらが持つのは置き場所・開閉・キー操作だけ。

const GameSession = preload("res://scripts/systems/game_session.gd")
const LogisticsDebugPanel = preload("res://scripts/ui/logistics_debug_panel.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

## 起動した時点で開いておくか。
##
## true にしてある。物流の調整をしている間は毎回 F5 を押すことになり、
## 「押し忘れて数日進めてしまい、その分の記録が無い」が起こる。別ウィンドウに
## なった今は本編を覆わないので、開いたままでも邪魔にならない。
## 配布に向けて閉じた状態にするならここを false に戻す
## （F3 の debug_panel.gd は従来どおり閉じた状態で始まる）。
const OPEN_ON_START: bool = true

## 開いたときの大きさと、縮められる下限。
## 下限は「グラフの幅（CHART_WIDTH=700）＋調整欄（TUNING_WIDTH=360）」を
## 下回らない所に置く。これより狭めると調整欄が横スクロールに隠れ、
## 何のためのウィンドウか分からなくなる。
const DEFAULT_SIZE := Vector2i(1180, 760)
const MIN_SIZE := Vector2i(1120, 520)

## 本編のウィンドウから見た初期位置。右下にずらして、本編を完全には
## 隠さないようにする（重なった状態で開くと、別ウィンドウにした意味が
## 一目で伝わらない）。
const POSITION_OFFSET := Vector2i(96, 64)

var _panel: LogisticsDebugPanel


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()


## ノードの構築。二重に呼ばれても安全。--script のハーネスでは _ready() が
## 走らないため _init() からも呼ぶ（docs/rules/ui.md）。
func _configure() -> void:
	if _panel != null:
		return

	title = "TollRoad — 運送デバッグ"
	# 本編のウィンドウの中に埋め込まず、OS のウィンドウとして出す。
	force_native = true
	# transient にしない。true にすると本編に追従して最前面に張り付き、
	# 別モニタへ出して置きっぱなしにするという使い方ができなくなる。
	transient = false
	# exclusive にしない。true だと本編が入力を受け取らなくなり、
	# 「日を進めながらグラフを見る」ができなくなる。
	exclusive = false
	# wrap_controls は使わない。中身に合わせてウィンドウが伸び縮みすると、
	# ビューを切り替えるたびに窓の大きさが変わる（docs/rules/ui.md にある
	# autowrap との組み合わせの破綻もここで踏む）。
	wrap_controls = false
	size = DEFAULT_SIZE
	min_size = MIN_SIZE
	visible = OPEN_ON_START

	_panel = LogisticsDebugPanel.new()
	add_child(_panel)
	# アンカーとオフセットを確定させる。preset だけだとサイズ0で描画されない
	# 罠に戻りうる（docs/rules/ui.md）。
	UiUtil.fill_window(self)

	if not close_requested.is_connected(hide_window):
		close_requested.connect(hide_window)


# --- 公開 API（main.gd / シナリオから使う。パネル規約に合わせる） ---

func bind(session: GameSession) -> void:
	_configure()
	_panel.bind(session)


func refresh() -> void:
	_configure()
	# 閉じている間も記録は続ける。開いた瞬間から先しかグラフが無いと、
	# 「おかしくなった所を見返す」というデバッグの一番効く使い方ができない。
	_panel.refresh()


func toggle_visible() -> void:
	_configure()
	if visible:
		hide_window()
	else:
		show_window()


func show_window() -> void:
	_configure()
	visible = true
	_place_beside_main()
	_panel.refresh()


func hide_window() -> void:
	_configure()
	visible = false


## 中身。検査とデバッグからパネルの中身へ直接触るための入口。
func panel() -> LogisticsDebugPanel:
	return _panel


# --- 内部 ---

## 本編のウィンドウの右下へずらして置く。
##
## popup_centered() 系は使わない。ツリー外（--script のハーネス）ではエラーに
## なるうえ、中央に出すと本編にちょうど重なる。位置を一度でも動かした後は
## 動かさない——見ている途中で窓が飛ぶのは、どこを見ていたか分からなくなる。
func _place_beside_main() -> void:
	if not is_inside_tree():
		return
	if position != Vector2i.ZERO:
		return
	var main: Window = get_window()
	if main == null:
		return
	position = main.position + POSITION_OFFSET


## キー操作。**この窓に焦点がある間、本編のウィンドウは入力を受け取らない。**
## F5 で閉じられないと閉じ方が分からなくなり、Space が効かないと
## 「日を進めながらグラフを見る」ができない。どちらもここで受け直す。
##
## _input ではなく _unhandled_input なのは本編と同じ理由（スライダーや
## 数値入力に焦点がある間、そちらからキーを奪わないため）。
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return

	if event.is_action("tr_logistics_debug_toggle"):
		hide_window()
		set_input_as_handled()
		return

	if event.is_action("tr_rest"):
		var session: GameSession = _panel.session()
		if session != null and not session.is_over():
			session.rest()
		set_input_as_handled()
