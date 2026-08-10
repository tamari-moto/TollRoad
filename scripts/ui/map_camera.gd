extends Camera3D
## 大陸図を周回するカメラ。中央（レイヴンスパイア）を見ながら回る。
##
## 仰角と距離には上下限を設ける。真上や真横まで行くと環状の位置関係が
## 読めなくなり、地図としての役目を失うため。

## 方位角の初期値（ラジアン）。
const DEFAULT_YAW: float = -0.6
## 仰角の初期値と上下限。0 が水平、PI/2 が真上。
const DEFAULT_PITCH: float = 0.62
const MIN_PITCH: float = 0.28
const MAX_PITCH: float = 1.25
## 中心からの距離と上下限。
const DEFAULT_DISTANCE: float = 22.0
const MIN_DISTANCE: float = 12.0
const MAX_DISTANCE: float = 34.0

## ドラッグの感度。
const YAW_SPEED: float = 0.008
const PITCH_SPEED: float = 0.006
## ホイール1目盛りで変わる距離。
const ZOOM_STEP: float = 1.8

## 見る先の初期値。盆地の底より少し上を見て、地平が画面中央に来るようにする。
## 現在地が決まるまでの暫定値で、以降は都市に合わせて動く。
const FOCUS := Vector3(0.0, -0.4, 0.0)

## 注視点が追いつく速さ（1秒あたりの割合）。移動のたびに瞬間移動すると
## どこへ跳んだか分からなくなるので、滑らせて経路を見せる。
const FOCUS_FOLLOW_SPEED: float = 3.5

var yaw: float = DEFAULT_YAW
var pitch: float = DEFAULT_PITCH
var distance: float = DEFAULT_DISTANCE

## 今見ている点と、向かっている先。移動直後はこの2つがずれる。
var focus: Vector3 = FOCUS
var _focus_target: Vector3 = FOCUS


func _init() -> void:
	_apply()


func _ready() -> void:
	current = true
	_apply()


## 方位角を変える。ぐるりと一周できる。
func rotate_by(delta_yaw: float, delta_pitch: float) -> void:
	yaw += delta_yaw
	# 仰角は制限する。真上・真横だと位置関係が読めない。
	pitch = clampf(pitch + delta_pitch, MIN_PITCH, MAX_PITCH)
	_apply()


## 距離を変える。近づきすぎ・離れすぎを防ぐ。
func zoom_by(amount: float) -> void:
	distance = clampf(distance + amount, MIN_DISTANCE, MAX_DISTANCE)
	_apply()


## 見る先を都市へ移す。ツリー外（--script のハーネス）では
## 補間の刻みが来ないので、その場で移す。
func focus_on(point: Vector3, immediate: bool = false) -> void:
	# 高さは元の見下ろし量を保つ。都市の足元を見ると地平が上に寄りすぎる。
	_focus_target = Vector3(point.x, point.y + FOCUS.y, point.z)
	if immediate or not is_inside_tree():
		focus = _focus_target
	_apply()


## 注視点が目標に着いているか。追従中は 2D のボタンも引き直す必要がある。
func is_settled() -> bool:
	return focus.is_equal_approx(_focus_target)


## 注視点を目標へ寄せる。距離に比例して減速するので、
## 近づくほどゆっくり止まる。
func _process(delta: float) -> void:
	if focus.is_equal_approx(_focus_target):
		return
	var t: float = minf(delta * FOCUS_FOLLOW_SPEED, 1.0)
	focus = focus.lerp(_focus_target, t)
	_apply()


func reset_view() -> void:
	yaw = DEFAULT_YAW
	pitch = DEFAULT_PITCH
	distance = DEFAULT_DISTANCE
	_apply()


func _apply() -> void:
	var horizontal: float = cos(pitch) * distance
	var offset := Vector3(
		cos(yaw) * horizontal,
		sin(pitch) * distance,
		sin(yaw) * horizontal)
	var eye: Vector3 = focus + offset

	# look_at はツリー外で使えないため、位置指定版を使う
	# （--script のハーネスでも同じ経路が通るようにする）。
	look_at_from_position(eye, focus, Vector3.UP)
