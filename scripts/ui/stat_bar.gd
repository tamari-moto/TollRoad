extends Control
## 「現在値 / 上限」を示す汎用バー。デバッグパネルの在庫・需要表示に使う。
##
## price_bar.gd は UiTheme.PRICE_SCALE_MIN〜MAX を前提にした価格専用のバーで
## 使い回せないため、_draw() の手法だけをフォークして汎用化した。

const UiTheme = preload("res://scripts/ui/ui_theme.gd")

const BAR_HEIGHT: int = 6

## 現在値。
var value: float = 0.0:
	set(new_value):
		value = new_value
		queue_redraw()

## 上限値。0以下なら常に空のバーとして描く。
var max_value: float = 0.0:
	set(new_value):
		max_value = new_value
		queue_redraw()

## 塗りの色。
var fill_color: Color = UiTheme.GOOD:
	set(new_value):
		fill_color = new_value
		queue_redraw()


func _init() -> void:
	# --script のハーネスでは _ready が走らないことがあるため、
	# ここでも初期化する（price_bar.gd と同じ理由）。
	_configure()


func _ready() -> void:
	_configure()


func _configure() -> void:
	custom_minimum_size = Vector2(0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 充足度（0.0〜1.0）。上限が0以下なら0（品切れ・生産0のレア品など）。
func ratio() -> float:
	if max_value <= 0.0:
		return 0.0
	return clampf(value / max_value, 0.0, 1.0)


func _draw() -> void:
	var width: float = size.x
	var height: float = size.y
	if width <= 0.0 or height <= 0.0:
		return

	draw_rect(Rect2(0.0, 0.0, width, height), UiTheme.BAR_TRACK)

	var fill_width: float = ratio() * width
	if fill_width > 0.0:
		draw_rect(Rect2(0.0, 0.0, fill_width, height), fill_color)
