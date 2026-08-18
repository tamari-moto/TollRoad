extends Control
## 画面最前面のエフェクト層。パネルをまたぐ演出をここで飛ばす。
##
## 売買の演出は市場（右のサイドパネル）から HUD（画面上部）へ跨いで飛ぶ。
## **どちらかのパネルの内部に置くと境界で切れる。** SidePanel は
## `clip_contents = true` なので、市場パネルの中に置いた飛翔物はパネルの縁で
## 消え、HUD まで届かない。全画面を覆うこの層に置き、グローバル座標で
## 飛ばすことで跨げるようにする。
##
## 吊るのは main.gd（`_setup_trade_fx()`）で、置き場所は `UI/Root` の直下。
## 誰が飛ばすかは fly_item() の呼び出し側が決める（この層は経路だけを持つ）。
##
## 入力は一切拾わない（MOUSE_FILTER_IGNORE）。演出中もボタンは押せる。

const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")

## 飛翔にかける秒数。手応えを出すため HUD の補間よりやや長く取る。
const FLIGHT_DURATION: float = 0.42
## 弧の高さ。まっすぐ飛ぶより「運んでいる」感じが出る。
##
## **固定値ではなく距離に比例させる。** 市場（右のサイドパネル）から HUD
## （画面上部）まで飛ばすようになり、行程が千px級になった。固定 70px では
## 行程に対して弧が相対的に潰れ、直線と見分けがつかない。上下限で挟むのは、
## 短い飛翔で弧が消えず、長い飛翔で画面外へ跳ね上がらないようにするため。
const ARC_HEIGHT_RATIO: float = 0.20
const ARC_HEIGHT_MIN: float = 40.0
const ARC_HEIGHT_MAX: float = 180.0
## 飛翔中のアイコンの大きさ。一覧のアイコンより大きくして目を引く。
const FLIGHT_ICON_SIZE: int = 34
## 着地時に一瞬だけ広がる倍率。
const IMPACT_SCALE: float = 1.5


func _init() -> void:
	# _ready を待たずに設定する。--script のハーネスでは _ready が走らない
	# ことがあり、そこで初期化すると層が機能しないまま検査を通してしまう。
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	# 全画面を覆い、クリックは透過させる。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 品目のアイコンを from から to へ弧を描いて飛ばす。
## 画像が無い品目でも落ちない（その場合は色付きの矩形で代用する）。
func fly_item(item_id: String, from_global: Vector2, to_global: Vector2,
		tint: Color = Color.WHITE) -> void:
	# 親に繋がっていなければ演出しない（孤立したノードで動かさない）。
	if get_parent() == null:
		return

	var flyer: Control = _make_flyer(item_id, tint)
	add_child(flyer)

	var half: Vector2 = flyer.custom_minimum_size * 0.5
	flyer.global_position = from_global - half
	var start: Vector2 = flyer.position
	var end: Vector2 = to_global - global_position - half

	var tween: Tween = create_tween()
	tween.set_parallel(true)

	# 弧を描かせる。制御点を中間の少し上に置く。
	var arc: float = clampf(
		start.distance_to(end) * ARC_HEIGHT_RATIO, ARC_HEIGHT_MIN, ARC_HEIGHT_MAX)
	var control: Vector2 = (start + end) * 0.5 + Vector2(0.0, -arc)
	tween.tween_method(
		func(t: float) -> void: _place_on_arc(flyer, start, control, end, t),
		0.0, 1.0, FLIGHT_DURATION).set_trans(Tween.TRANS_SINE)

	# 飛びながら少し縮み、着地の瞬間に弾ける。
	tween.tween_property(flyer, "scale", Vector2.ONE * 0.7,
		FLIGHT_DURATION * 0.6).set_trans(Tween.TRANS_QUAD)

	tween.chain().tween_property(flyer, "scale", Vector2.ONE * IMPACT_SCALE, 0.08)
	tween.chain().tween_property(flyer, "modulate:a", 0.0, 0.12)
	tween.chain().tween_callback(flyer.queue_free)


## 二次ベジエで弧の上に配置する。
func _place_on_arc(node: Control, start: Vector2, control: Vector2,
		end: Vector2, t: float) -> void:
	if not is_instance_valid(node):
		return
	var a: Vector2 = start.lerp(control, t)
	var b: Vector2 = control.lerp(end, t)
	node.position = a.lerp(b, t)


func _make_flyer(item_id: String, tint: Color) -> Control:
	var size := Vector2(FLIGHT_ICON_SIZE, FLIGHT_ICON_SIZE)
	var texture: Texture2D = UiIcons.item_texture(item_id)

	if texture != null:
		var rect := TextureRect.new()
		rect.texture = texture
		rect.custom_minimum_size = size
		rect.size = size
		rect.pivot_offset = size * 0.5
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.modulate = tint
		return rect

	# 画像が無い品目でも演出は出す。品目色の丸で代用する。
	var dot := ColorRect.new()
	dot.color = UiTheme.item_color(item_id)
	dot.custom_minimum_size = size
	dot.size = size
	dot.pivot_offset = size * 0.5
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return dot
