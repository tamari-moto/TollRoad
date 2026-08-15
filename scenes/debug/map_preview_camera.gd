extends Camera3D
## 確認用シーン専用の、FPS 操作で歩き回るカメラ。
##
## 本編の MapCamera は中心を見ながら回る周回カメラで、位置は
## focus + yaw/pitch/distance から導かれる。地表を自由に歩く操作とは
## 座標の決め方そのものが違うため、あちらに手を入れず別物として置く
## （本編の見え方を変えないことを優先した）。
##
## 地形の当たり判定は持たない。MapView3D.terrain_mesh_height_at() で
## 真下の高さを引き、そこから目線分だけ持ち上げるだけの簡易な追従にして
## ある。PhysicsBody を足すと本編の大陸図に無い依存が増えるため避けた。

const MapView3D = preload("res://scripts/ui/map_view_3d.gd")

## 歩く速さ（3D 空間の単位／秒）。都市間の目標間隔が 10.58 なので、
## この速さなら隣の街まで数秒で着く。
const MOVE_SPEED: float = 12.0
## Shift を押している間の倍率。地形の端まで見に行くとき用。
const SPRINT_MULTIPLIER: float = 3.0
## マウスの感度（ラジアン／ピクセル）。
const LOOK_SENSITIVITY: float = 0.003
## 上下の視線の限界。真上・真下で像がひっくり返るのを防ぐ。
const MAX_PITCH: float = 1.5

## 地表からの目線の高さ。人の背丈よりやや高く取り、都市の構造物を
## 見下ろしすぎない値にしてある。
const EYE_HEIGHT: float = 1.8
## 地形に沿って上下する速さ（1秒あたりの割合）。急な斜面で跳ねないよう
## 補間する。
const GROUND_FOLLOW_SPEED: float = 12.0

## 自由飛行のときの上下移動の速さ。
const FLY_VERTICAL_SPEED: float = 8.0

## 開始位置。中心（レイヴンスパイア）から少し離れた場所に置く。
const START_POSITION := Vector3(0.0, 0.0, 14.0)

var yaw: float = PI
var pitch: float = 0.0
## 地形に沿って歩くか、自由に飛ぶか。F で切り替える。
var walking: bool = true

var _world: MapView3D
var _height: float = 0.0


func _init() -> void:
	current = true
	position = START_POSITION
	_apply_rotation()


func _ready() -> void:
	current = true


## 地表の高さを引くために MapView3D を渡す。渡されなければ高さ0の平面を
## 歩いているものとして扱う（検査から単体で動かせるようにするため）。
func bind_world(world: MapView3D) -> void:
	_world = world
	_height = position.y
	_snap_to_ground()


## 視線を回す。上下は制限する。
func look_by(delta_yaw: float, delta_pitch: float) -> void:
	yaw += delta_yaw
	pitch = clampf(pitch + delta_pitch, -MAX_PITCH, MAX_PITCH)
	_apply_rotation()


## 歩く／飛ぶを切り替える。飛ぶときは今の高さをそのまま保つ。
func toggle_walking() -> void:
	walking = not walking
	if walking:
		_snap_to_ground()


func reset_view() -> void:
	position = START_POSITION
	yaw = PI
	pitch = 0.0
	walking = true
	_apply_rotation()
	_snap_to_ground()


## WASD と QE を読んで動かす。ツリー外では _process が来ないので、
## 検査からは step() を直接呼べるようにしてある。
##
## InputMap の action を足さずキーを直接見ているのは、確認用シーンのために
## project.godot の [input]（本編の tr_* だけが並ぶ）を汚したくないため。
## 物理キーで見るので、配列が違っても位置で WASD になる。
func _process(delta: float) -> void:
	var input := Vector3(
		_axis(KEY_A, KEY_D),
		_axis(KEY_Q, KEY_E),
		_axis(KEY_W, KEY_S))
	var sprint: bool = Input.is_physical_key_pressed(KEY_SHIFT)
	step(input, sprint, delta)


## 2つのキーを -1／+1 の軸として読む。両方押していれば 0。
func _axis(negative: Key, positive: Key) -> float:
	var value: float = 0.0
	if Input.is_physical_key_pressed(positive):
		value += 1.0
	if Input.is_physical_key_pressed(negative):
		value -= 1.0
	return value


## 1フレーム分動かす。input は右／上／後ろを正とする -1〜1。
func step(input: Vector3, sprint: bool, delta: float) -> void:
	var speed: float = MOVE_SPEED * (SPRINT_MULTIPLIER if sprint else 1.0)

	# 前後左右は視線の向きに沿わせるが、歩いている間は水平に保つ
	# （見上げながら歩くと前に進まなくなるのを防ぐ）。
	# 向きは basis から取る。sin/cos で組むと Godot の「カメラは -Z を向く」
	# 規約と符号が合わず、前後と左右で辻褄の合い方が変わる（実際に前進だけ
	# 正しく左右が反転した）。
	var flat := Basis(Vector3.UP, yaw)
	var forward: Vector3 = -flat.z
	var right: Vector3 = flat.x
	# input.z は「後ろが正」なので、前進のときに forward を向くよう反転する。
	var motion: Vector3 = (right * input.x - forward * input.z) * speed * delta
	position += motion

	if walking:
		_follow_ground(delta)
	else:
		position.y += input.y * FLY_VERTICAL_SPEED * delta


## 真下の地形の高さへ目線を寄せる。急斜面で跳ねないよう補間する。
func _follow_ground(delta: float) -> void:
	var target: float = _ground_height() + EYE_HEIGHT
	var t: float = minf(delta * GROUND_FOLLOW_SPEED, 1.0)
	_height = lerpf(_height, target, t)
	position.y = _height


func _snap_to_ground() -> void:
	_height = _ground_height() + EYE_HEIGHT
	position.y = _height


func _ground_height() -> float:
	if _world == null:
		return 0.0
	return _world.terrain_mesh_height_at(position.x, position.z)


## look_at はツリー外で使えないため、基底から回転を組む
## （--script の検査でも同じ経路が通るようにする）。
func _apply_rotation() -> void:
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	transform = Transform3D(basis, position)
