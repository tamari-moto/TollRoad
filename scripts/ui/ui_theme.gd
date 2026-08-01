extends RefCounted
## UI 全体の配色。
##
## 以前は同じ色が複数のパネルに重複定義されていた（好調の緑が3箇所、
## 注目の青が3箇所など）。色を1つ変えるのに複数ファイルを触る状態だったため、
## ここに集約する。値は従来のまま — 各色の意味は既に定まっている。
##
## ui_util.gd と同じく定数クラスにしてあるので、--script のハーネスからも
## そのまま参照できる。

# --- 意味色 ---

## 好調・有利。安い価格、生産ボーナス、既知の最安、資金の増加。
const GOOD := Color(0.45, 0.85, 0.5)
## 警戒・不利。高い価格、黒ゾーンの危険、襲撃、資金の減少。
const WARN := Color(0.95, 0.6, 0.45)
## 注目。現在地。
const FOCUS := Color(0.55, 0.8, 0.95)

# --- テキスト ---

## 標準のテキスト。
const TEXT := Color(0.88, 0.88, 0.9)
## 補助的なテキスト。表の見出しや項目名。
const TEXT_DIM := Color(0.6, 0.6, 0.65)
## information が古い、確度が落ちている状態。相場メモの古い記録。
const TEXT_STALE := Color(0.5, 0.5, 0.55)
## 情報が無い状態。未訪問の都市。
const TEXT_UNKNOWN := Color(0.38, 0.38, 0.42)

# --- 積荷バー ---

## 積載の空き部分。
const CARGO_EMPTY := Color(0.2, 0.2, 0.22)

## 品目ごとの色。資源は寒色〜土色、装備は暖色で系統を分ける。
const ITEM_COLORS: Dictionary = {
	"ore":   Color(0.55, 0.58, 0.65),
	"wood":  Color(0.55, 0.42, 0.28),
	"fiber": Color(0.45, 0.65, 0.55),
	"hide":  Color(0.68, 0.5, 0.35),
	"stone": Color(0.5, 0.5, 0.5),
	"sword": Color(0.85, 0.45, 0.4),
	"bow":   Color(0.8, 0.65, 0.35),
	"robe":  Color(0.65, 0.45, 0.75),
	"armor": Color(0.8, 0.55, 0.3),
}

# --- ランク ---

const RANK_LEGENDARY := Color(1.0, 0.85, 0.4)
const RANK_MASTER := Color(0.55, 0.85, 0.95)
const RANK_NORMAL := Color(0.85, 0.85, 0.88)
const RANK_BANKRUPT := Color(0.9, 0.55, 0.5)

# --- 表示の閾値 ---

## 基準価格に対する比率がこれ以下なら「安い」、これ以上なら「高い」とみなす。
const CHEAP_RATIO: float = 0.95
const DEAR_RATIO: float = 1.05

# --- アニメーション ---

## 数値のカウントアップやバーの補間にかける秒数。
## 経営シミの落ち着いた印象を保つため短く抑える。
const TWEEN_DURATION: float = 0.25
## 増減を示す着色が元の色へ戻るまでの秒数。
const FLASH_DURATION: float = 0.45


## 品目の表示色。未定義なら灰色。
static func item_color(item_id: String) -> Color:
	return ITEM_COLORS.get(item_id, Color.GRAY)


## 基準価格との比率に応じた色。安ければ好調色、高ければ警戒色。
static func ratio_color(ratio: float) -> Color:
	if ratio <= CHEAP_RATIO:
		return GOOD
	if ratio >= DEAR_RATIO:
		return WARN
	return TEXT


## ランク名に応じた色。
static func rank_color(rank_name: String) -> Color:
	match rank_name:
		"LEGENDARY MERCHANT":
			return RANK_LEGENDARY
		"MASTER TRADER":
			return RANK_MASTER
		"BANKRUPT":
			return RANK_BANKRUPT
		_:
			return RANK_NORMAL
