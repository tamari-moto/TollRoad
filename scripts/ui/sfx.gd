extends Node
## 効果音。波形をコードで組み立てて鳴らす。
##
## 音声ファイルを持たない方針なので、AudioStreamWAV を実行時に生成する。
## 画像を SVG で自作したのと同じ考え方で、外部アセットの調達を不要にする。
##
## 生成した音はキャッシュする（同じ音を鳴らすたびに作り直さない）。

const UiTheme = preload("res://scripts/ui/ui_theme.gd")

const SAMPLE_RATE: int = 22050
## 同時に鳴らせる数。連打しても音が途切れないだけの数を確保する。
const VOICE_COUNT: int = 8

## 音の種類。名前は行動に対応させる。
enum Kind {
	BUY,       ## 購入。低めの短い音
	SELL,      ## 売却。硬貨を思わせる高めの音
	CRAFT,     ## 製作。槌を打つような音
	UPGRADE,   ## 島の拡張。上昇する和音
	DAY,       ## 日送り。控えめな低音
	TRAVEL,    ## 移動。ざらついた短い音
	RAID,      ## 襲撃。濁った低音
}

## 種類ごとの音量（dB）。頻度の高い音ほど下げる。
const VOLUMES: Dictionary = {
	Kind.BUY: -14.0,
	Kind.SELL: -13.0,
	Kind.CRAFT: -12.0,
	Kind.UPGRADE: -10.0,
	Kind.DAY: -20.0,
	Kind.TRAVEL: -18.0,
	Kind.RAID: -8.0,
}

static var _cache: Dictionary = {}

var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _muted: bool = false


func _init() -> void:
	_build_voices()


func _ready() -> void:
	_build_voices()


func _build_voices() -> void:
	if not _voices.is_empty():
		return
	for i: int in VOICE_COUNT:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_voices.append(player)


## 鳴らす。音を作れなくても落ちない。
func play(kind: Kind) -> void:
	if _muted or _voices.is_empty():
		return
	var stream: AudioStreamWAV = stream_for(kind)
	if stream == null:
		return

	# 空いている再生機を探し、無ければ順番に使い回す。
	var player: AudioStreamPlayer = null
	for candidate: AudioStreamPlayer in _voices:
		if not candidate.playing:
			player = candidate
			break
	if player == null:
		player = _voices[_next_voice]
		_next_voice = (_next_voice + 1) % _voices.size()

	player.stream = stream
	player.volume_db = VOLUMES.get(kind, -12.0)
	if player.is_inside_tree():
		player.play()


func set_muted(value: bool) -> void:
	_muted = value


func is_muted() -> bool:
	return _muted


## 用意されている再生機の数。連打で増えないことを検査から確かめられる。
func voice_count() -> int:
	return _voices.size()


## その種類の波形。同じ音は作り直さずキャッシュから返す。
## 純関数なので --script の検査から直接呼べる（scenario_m15.gd）。
static func stream_for(kind: Kind) -> AudioStreamWAV:
	if _cache.has(kind):
		return _cache[kind]
	var stream: AudioStreamWAV = _build(kind)
	_cache[kind] = stream
	return stream


static func _build(kind: Kind) -> AudioStreamWAV:
	match kind:
		Kind.BUY:
			# 低めから軽く下がる。物を受け取った感じ。
			return _tone(440.0, 330.0, 0.09, 0.0)
		Kind.SELL:
			# 高めへ跳ね上げる。硬貨の響きを狙う。
			return _tone(660.0, 990.0, 0.11, 0.0)
		Kind.CRAFT:
			# 減衰の速い打撃音。ノイズを混ぜて槌の感じを出す。
			return _tone(200.0, 120.0, 0.14, 0.35)
		Kind.UPGRADE:
			# ゆっくり上昇させて達成感を出す。
			return _tone(330.0, 880.0, 0.32, 0.0)
		Kind.DAY:
			# 目立たない低音。毎日鳴るので控えめに。
			return _tone(180.0, 160.0, 0.10, 0.0)
		Kind.TRAVEL:
			# 砂利を踏むような短いノイズ。
			return _tone(160.0, 130.0, 0.16, 0.7)
		Kind.RAID:
			# 濁った低音。最も重い事象なので長めに取る。
			return _tone(150.0, 70.0, 0.42, 0.5)
	return null


## 開始周波数から終了周波数へ滑らかに変化する音を作る。
## noise は 0 で純音、1 でノイズのみ。
static func _tone(from_hz: float, to_hz: float, seconds: float,
		noise: float) -> AudioStreamWAV:
	var count: int = int(SAMPLE_RATE * seconds)
	if count <= 0:
		return null

	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	# 毎回同じ音になるよう固定する。
	rng.seed = int(from_hz * 100.0 + to_hz)

	var phase: float = 0.0
	for i: int in count:
		var t: float = float(i) / float(count)
		# 立ち上がりを速く、減衰をなだらかにする。
		var envelope: float = _envelope(t)
		var hz: float = lerpf(from_hz, to_hz, t)
		phase += TAU * hz / float(SAMPLE_RATE)

		var wave: float = sin(phase)
		if noise > 0.0:
			wave = lerpf(wave, rng.randf_range(-1.0, 1.0), noise)

		var value: int = clampi(int(wave * envelope * 24000.0), -32768, 32767)
		data.encode_s16(i * 2, value)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


## 音量の時間変化。頭を立て、尾を引かせる。
static func _envelope(t: float) -> float:
	const ATTACK: float = 0.02
	if t < ATTACK:
		return t / ATTACK
	var decay: float = (t - ATTACK) / (1.0 - ATTACK)
	return pow(1.0 - decay, 2.0)
