extends Control
## 価格の位置を示すバー。
##
## 安い〜高いの幅の中で今の価格がどこにあるかを一目で示す。数字を9行ぶん
## 読み比べなくても、目立つ行が買い時だと分かるようにするためのもの。
##
## 目盛りは全品目で共通（UiTheme.PRICE_SCALE_MIN〜MAX）。品目ごとに変えると
## 同じバー位置が別の意味になり、行をまたいだ比較ができなくなる。

const UiTheme = preload("res://scripts/ui/ui_theme.gd")

## バーの高さ。行の中に収まる控えめな厚み。
const BAR_HEIGHT: int = 6
## 現在価格を示すマーカーの幅。
const MARKER_WIDTH: float = 3.0
## 基準線（100%）の幅。
const BASELINE_WIDTH: float = 1.0

## 基準価格に対する比率。1.0 が基準価格ちょうど。
var ratio: float = 1.0:
	set(value):
		ratio = value
		queue_redraw()


func _init() -> void:
	# _ready を待たずに設定する。--script のハーネスでは _ready が
	# 走らないことがあり、そこで初期化すると高さ 0 のまま描画されない。
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	custom_minimum_size = Vector2(0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 比率を目盛り上の位置（0.0〜1.0）に変換する。
static func position_for(value: float) -> float:
	var span: float = UiTheme.PRICE_SCALE_MAX - UiTheme.PRICE_SCALE_MIN
	if span <= 0.0:
		return 0.5
	return clampf((value - UiTheme.PRICE_SCALE_MIN) / span, 0.0, 1.0)


func _draw() -> void:
	var width: float = size.x
	var height: float = size.y
	if width <= 0.0 or height <= 0.0:
		return

	# 地色の帯。
	draw_rect(Rect2(0.0, 0.0, width, height), UiTheme.BAR_TRACK)

	# 安い側・高い側の帯を薄く重ねる。どこからが「安い」かの目安になる。
	var cheap_end: float = position_for(UiTheme.CHEAP_RATIO) * width
	if cheap_end > 0.0:
		draw_rect(Rect2(0.0, 0.0, cheap_end, height), UiTheme.BAR_CHEAP_ZONE)
	var dear_start: float = position_for(UiTheme.DEAR_RATIO) * width
	if dear_start < width:
		draw_rect(Rect2(dear_start, 0.0, width - dear_start, height),
			UiTheme.BAR_DEAR_ZONE)

	# 基準価格（100%）の線。損益の分かれ目。
	var baseline: float = position_for(1.0) * width
	draw_rect(Rect2(baseline - BASELINE_WIDTH * 0.5, 0.0, BASELINE_WIDTH, height),
		UiTheme.BAR_BASELINE)

	# 現在価格のマーカー。色は一覧の%表示と同じ判定に合わせる。
	var marker: float = position_for(ratio) * width
	draw_rect(
		Rect2(marker - MARKER_WIDTH * 0.5, 0.0, MARKER_WIDTH, height),
		UiTheme.ratio_color(ratio))
