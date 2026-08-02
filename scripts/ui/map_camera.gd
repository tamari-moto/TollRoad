extends Camera3D
## 大陸図を周回するカメラ。中央（カーレオン）を見ながら回る。
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

## 見る先。盆地の底より少し上を見て、地平が画面中央に来るようにする。
const FOCUS := Vector3(0.0, -0.4, 0.0)

var yaw: float = DEFAULT_YAW
var pitch: float = DEFAULT_PITCH
var distance: float = DEFAULT_DISTANCE


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
	var eye: Vector3 = FOCUS + offset

	# look_at はツリー外で使えないため、位置指定版を使う
	# （--script のハーネスでも同じ経路が通るようにする）。
	look_at_from_position(eye, FOCUS, Vector3.UP)
