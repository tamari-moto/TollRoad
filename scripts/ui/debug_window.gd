extends Window
## 市場デバッグ画面（debug_panel.gd）を入れる**別ウィンドウ**。
##
## F5（logistics_debug_window.gd）と同じ理由で OS のウィンドウにしてある。
## パネルは 1080x720 あり、既定のビューポート（1280x720）ではほぼ全面を覆う。
## 在庫や生産量を見ながら地図と市場画面を確かめたいので、隠し合うと
## 見比べたい2つが同時に見られない。
##
## **中身は一切持たない。** 一覧も五角形も debug_panel.gd にあり、こちらが
## 持つのは置き場所・開閉・キー操作だけ（F5 の窓と同じ役割分担）。

const GameSession = preload("res://scripts/systems/game_session.gd")
const DebugPanel = preload("res://scripts/ui/debug_panel.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

## 起動した時点で開いておくか。
##
## **false。** F5 と違ってここは開けっぱなしにする理由が無い。F5 は物流の
## 記録が「開いた瞬間から先しか無い」と困るので開いた状態で始めるが、
## こちらは押した時点の在庫を見るだけで、遡って見返すものが無い。
const OPEN_ON_START: bool = false

## 開いたときの大きさと、縮められる下限。
## パネルが 1080x720（DebugPanel.PANEL_SIZE）なので、窓の縁のぶんを足してある。
## 下限は名前の列＋棒の列＋価格の列が横に並ぶ幅を下回らない所に置く。
## これより狭めると棒が潰れ、都市どうしの比較ができなくなる。
const DEFAULT_SIZE := Vector2i(1140, 780)
const MIN_SIZE := Vector2i(620, 420)

## 本編のウィンドウから見た初期位置。
##
## F5 と**ずらしてある**。同じ offset だと両方開いたときに完全に重なり、
## 下の窓が隠れて「開いたのに出てこない」ように見える。
const POSITION_OFFSET := Vector2i(48, 32)

var _panel: DebugPanel

## 一度でも本編の隣へ置いたか。位置は最初の一度だけ決める——見ている途中で
## 窓が飛ぶと、どこを見ていたか分からなくなる。
## 「position が (0,0) かどうか」では代用できない。(0,0) は「まだ置いていない」
## と「本当に左上にある」の区別がつかない（F5 の窓で実際に踏んだ）。
var _placed: bool = false


func _init() -> void:
	_configure()


func _ready() -> void:
	_configure()
	# 起動時から開いている場合、show_window() を通らないぶん配置も走らない。
	# 既定では閉じているので通常ここは効かないが、OPEN_ON_START を true へ
	# 変えたときに F5 の窓と同じ罠を踏まないようにしてある。
	if visible:
		_place_beside_main()


## ノードの構築。二重に呼ばれても安全。--script のハーネスでは _ready() が
## 走らないため _init() からも呼ぶ（docs/rules/ui.md）。
func _configure() -> void:
	if _panel != null:
		return

	title = "TollRoad — 市場デバッグ"
	# 本編のウィンドウの中に埋め込まず、OS のウィンドウとして出す。
	#
	# **先に隠してから代入すること。** Window は visible=true で生まれるため、
	# 何も触らないうちから「表示中」と見なされ、setter が
	# 「Can't change "force_native" while a window is displayed」を出して
	# **代入を捨てる**（4.7.1 で実測）。エラーはログに出るだけで例外にならず、
	# 埋め込み＝オーバーレイに戻る。
	visible = false
	force_native = true
	# transient にしない。true にすると本編に追従して最前面に張り付き、
	# 別モニタへ出して置きっぱなしにするという使い方ができなくなる。
	transient = false
	# exclusive にしない。true だと本編が入力を受け取らなくなり、
	# 「日を進めながら在庫を見る」ができなくなる。
	exclusive = false
	# wrap_controls は使わない。中身に合わせてウィンドウが伸び縮みすると、
	# ビューを切り替えるたびに窓の大きさが変わる。
	wrap_controls = false
	size = DEFAULT_SIZE
	min_size = MIN_SIZE
	visible = OPEN_ON_START

	_panel = DebugPanel.new()
	# パネルは自前の「×」を toggle_visible() へ繋いでいる。窓に入れた今、
	# パネルだけを隠すと**中身が消えた空の窓が残る**ので、窓ごと閉じる形へ
	# 繋ぎ替える（パネル側は本編でも単体で使えるよう、そのままにしてある）。
	_panel.close_requested_from_panel.connect(hide_window)
	# **パネルは常に見せる。** オーバーレイとして作られた名残で visible=false
	# で生まれるが、窓に入れた今は開閉を持つのは窓の側。ここを false のままに
	# すると F3 で開いても**中身の無い窓**が出る。
	_panel.visible = true
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
	# 閉じている間は中身を作らない。全都市×全品目の行を毎日組み直すのは
	# 安くなく、見ていない間に払う理由が無い（F5 と違って記録を持たないので、
	# 開いた時点で作れば足りる）。
	if not visible:
		return
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
	# 閉じている間は refresh() を飛ばしているので、開いた時点で追いつかせる。
	_panel.refresh()


func hide_window() -> void:
	_configure()
	visible = false


## 中身。検査とデバッグからパネルの中身へ直接触るための入口。
func panel() -> DebugPanel:
	return _panel


# --- 内部 ---

## 本編のウィンドウの右下へずらして置く。
##
## popup_centered() 系は使わない。ツリー外（--script のハーネス）ではエラーに
## なるうえ、中央に出すと本編にちょうど重なる。位置を一度でも決めた後は
## 動かさない——見ている途中で窓が飛ぶのは、どこを見ていたか分からなくなる。
func _place_beside_main() -> void:
	if _placed:
		return
	var main: Window = _main_window()
	if main == null:
		return
	position = main.position + POSITION_OFFSET
	_placed = true


## 本編のウィンドウ。親を上へ辿って最初に見つかる Window を返す。
##
## **`get_window()` は使えない。** Window 自身の `get_window()` は自分を返すため、
## 自分の位置に POSITION_OFFSET を足す形になる（＝本編の隣ではなく置き去り）。
## 親から `get_window()` を呼ぶ手もあるが、そちらはツリー外だと使えず、
## 検査がホストの窓をツリー外で組む形を取れなくなる。親を直接辿れば
## 本編でも検査でも同じ経路になる。
func _main_window() -> Window:
	var node: Node = get_parent()
	while node != null:
		var window := node as Window
		if window != null and window != self:
			return window
		node = node.get_parent()
	return null


## キー操作。**この窓に焦点がある間、本編のウィンドウは入力を受け取らない。**
## F3 で閉じられないと閉じ方が分からなくなり、Space が効かないと
## 「日を進めながら在庫を見る」ができない。どちらもここで受け直す
## （F5 の窓と同じ理由）。
##
## _input ではなく _unhandled_input なのは本編と同じ理由（ボタンに焦点が
## ある間、そちらからキーを奪わないため）。
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return

	if event.is_action("tr_debug_toggle"):
		hide_window()
		set_input_as_handled()
		return

	if event.is_action("tr_rest"):
		var session: GameSession = _panel.session()
		if session != null and not session.is_over():
			session.rest()
			_panel.refresh()
		set_input_as_handled()
