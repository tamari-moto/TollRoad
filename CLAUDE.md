# CLAUDE.md

TollRoad（Godot 4.7.1 / GL Compatibility）で作業する際の Godot 固有ルール。
プロジェクト構成とセットアップ手順は [README.md](README.md) を参照。

## Godot の実行

バイナリは `PATH` に無い。さらに `Godot_v4.7.1-stable_win64.exe` は**拡張子が .exe のディレクトリ**で、実体はその中にある。必ずフルパスで呼ぶこと。

```bash
"/c/Users/Tamar/Downloads/Godot_v4.7.1-stable_win64.exe/Godot_v4.7.1-stable_win64_console.exe" \
  --headless --path . --quit-after 30
```

期待される出力: `TollRoad start. Day: 1, Gold: 1000` / exit 0。
`_console.exe` の方を使う（stdout がそのまま取れる）。

アセットを追加・変更したら再インポート（GUI 不要）:

```bash
"...Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
```

### autoload を識別子として書かない

`GameState.session` のように**識別子で書くとコンパイル時に autoload
レジストリを引く**。`--script` のハーネスは autoload を初期化しないため、
そのスクリプト自体がロードできなくなる（`Identifier not found: GameState`）。

かつて `main.gd` がこれに当たり、**UI ハンドラを実行する検査が一切書けなかった**。
セーブ関連のバグを1件、そのせいで検査できずレビューでしか見つけられていない。

autoload は実行時に引き、検査が差し込める入口を用意する:

```gdscript
## 型注釈のための preload。パスからの読み込みなので autoload レジストリを
## 引かず、--script でも解決できる（識別子との違いはここ）。
const GameStateScript = preload("res://scripts/autoload/game_state.gd")

func _resolve_state() -> void:
	if _state != null:
		return
	_state = get_node_or_null("/root/GameState") as GameStateScript


## 検査から差し込む入口。本編では呼ばれない。
func bind_state(state: GameStateScript) -> void:
```

`scenario_m19.gd` がこの形で `Main.tscn` を立て、実物のハンドラを走らせている。

## Godot ファイルの扱い

- **`.uid` は必ずコミットする。** Godot 4.4+ ではスクリプトの正体を示す正規ファイルで、
  欠けるとクローン時に UID が再生成され、シーンからの参照が壊れる。
- **`.tscn` / `.tres` の 1行目の `uid=` は変更しない。** Godot が生成する内部識別子で、
  人間には見えず、変えると参照が壊れるだけ。手編集する場合もこの行は触らない。
- `*.import` は追跡対象。`.godot/` は無視（`.gitignore` 済み）。
  新しいアセットは `--import` を通してから `.import` ごとコミットする。

## Git 運用

改行は LF に統一（`.gitattributes` で強制）。`core.autocrlf=false` と
`core.fileMode=false` はリポジトリローカルに設定済み。

**`git restore --staged` の落とし穴**: `git update-index --chmod=-x` でモードだけ
修正した後にこれを使うと、モード修正まで巻き戻る。コミットを分ける際は注意し、
最後に必ず確認する:

```bash
git ls-files -s | grep -c 100755   # 0 であること
```

空ディレクトリは `.gitkeep` で構造を保持している。削除しないこと。

## コード規約

既存コードに合わせる:

- インデントはタブ
- ドキュメントコメントは `##`、日本語
- 型注釈を付ける（`func add_gold(amount: int) -> void`）
- 関数定義の間は空行2つ

## ゲームロジックの置き場所

**ロジックは autoload に置かない。** `scripts/systems/` に素のクラスとして書き、
`load()` + `.new()` で駆動できる形を保つこと。`--script` のハーネスは autoload を
初期化しないため、autoload 経由でしか触れないロジックは検証できなくなる。

[game_state.gd](scripts/autoload/game_state.gd) は
[GameSession](scripts/systems/game_session.gd) を保持するだけの薄い入れ物に留める。

**RNG は必ずシードを渡して生成する。** `GameSession.new(seed)` で再現可能になる。
シードを固定できないと、バグの再現もバランスのバッチ検証もできない。

## セーブ/ロード

保存先は `user://savegame.json`、形式は JSON。2層に分かれている:

- [game_session.gd](scripts/systems/game_session.gd) の `to_dict()` / `from_dict()`
  — 状態の写し取り。保存形式は知らない
- [save_manager.gd](scripts/systems/save_manager.gd) — ファイル入出力と版の整合。
  素のクラス（autoload に置かない規約どおり）

[game_state.gd](scripts/autoload/game_state.gd) は `continue_game()` /
`save_game()` の入口を持つだけ。**自動保存は日が進んだ時のみ**
（`day_advanced` に繋いである）。60日を終えた後は保存しない。

踏み抜きやすい点が3つある:

- **`_rng` の seed と state は文字列で保存する。** 64bit の値は JSON の double
  （仮数部53bit）では正確に往復しない。実測で
  `4857946085375722947` → `4857946085375722496` に化ける。
  **検査は必ず `JSON.stringify()` を経由すること** — 辞書どうしを比べても
  メモリ上では欠けないので、壊れた実装でも通ってしまう
- **`prices` も保存する。** `reroll()` は「次の日の相場」を作るもので、
  今日の相場は再現できない。都市や品目を足した後の古いセーブでは、
  部分補完せず**全体を引き直す**（一部だけ埋めるとその品目だけ系列の外になる）
- **`JSON.parse_string()` は数値を float で返す。** 辞書の中身は `int()` を
  通すこと（型注釈のある変数への代入は GDScript が丸めるので気づきにくい）

版は「足す」なら上げない、「意味を変える」なら上げる。
`version > SAVE_VERSION` は**推測で読まず拒否**する。
知らない都市も拒否（現在地が黙って変わると積荷と移動費の前提が崩れる）。
島レベルと騎乗は範囲の問題なので丸める。

**シナリオは `SAVE_PATH` を使わないこと。** 流すたびにプレイヤーの
セーブが消える。`scenario_m18.gd` は専用パスを使い、最後に消している。

## 検証

ロジックの検査はシード固定のシナリオで行う（テストフレームワークは使わない）:

```bash
"...Godot_v4.7.1-stable_win64_console.exe" \
  --headless --path . --script scripts/systems/scenario_m1.gd
```

全件合格なら exit 0、失敗があれば `FAIL:` を出力して exit 1。

各シナリオは [scenario_base.gd](scripts/systems/scenario_base.gd) を継承する。
`_check()` / `_spawn()` / `_despawn()` / `_finish()` は基底にあるので書かない:

```gdscript
extends "res://scripts/systems/scenario_base.gd"

func _init() -> void:
	_test_なにか()
	_finish()
```

**ファイル名は `scenario_` で始めること。** `export_presets.cfg` の
`exclude_filter` がこの接頭辞で配布物から除外している。

### 検証は3層で行う

1本直したら **全部流す**。1本だけでは他への波及が見えない。

| 層 | 手段 | 捕まえるもの |
|---|---|---|
| ロジック | シード固定の `scenario_m*.gd` | 幾何・数値・シグナルの引数 |
| 起動 | `--headless --quit-after 90` | パースエラー、autoload、実行時警告 |
| 描画 | **GUI で目視** | 見た目の破綻 |

```bash
"...console.exe" --headless --path . --script scripts/systems/scenario_all.gd
```

全件合格で exit 0、1件でも失敗があれば exit 1。落ちたシナリオと再実行の
コマンドが最後にまとまって出る。個別実行も引き続き有効で、**1本落ちたら
そのシナリオだけを単体で回して切り分ける**（ランナーは1本がクラッシュすると
以降が回らない）。

シナリオを足したら `scenario_all.gd` の `SCENARIO_COUNT` を更新すること。
忘れてもランナーが本数を照合して止める。

**`await` を使うシナリオは `AWAIT_SCENARIOS` にも番号を足す。** 子の
`SceneTree` ではフレームループが回らず `await process_frame` から復帰しないため、
同じプロセスで動かすと**残りの検査が黙って実行されない**（実測で37件が消えた）。
該当する4本は別プロセスで起動している。登録漏れはランナーが検出して止める。

**3層目は省略できない。** ヘッドレスの検査はノードを引けるかしか見ておらず、
描画の破損を検出できない（開始画面が黒い矩形になる不具合を2度見逃した）。
見た目に関わる変更は必ず GUI を起動し、**その判断は人に委ねる**:

```bash
"...Godot_v4.7.1-stable_win64.exe" --path .   # _console でない方
```

速さ・大きさ・色が適切かはヘッドレスでは判断できない。数値を報告して終わりに
せず、調整できる定数名を添えて確認を求めること。

### 検査は「動くか」ではなく「妥当か」を見る

動いていることだけを確かめる検査は、後から値を壊しても素通りする。
**範囲で歯止めをかける**。脈動なら「変化するか」ではなく:

```gdscript
_check(MapView3D.RING_PULSE_AMOUNT <= 0.15, "脈動が控えめ", ...)
_check(MapView3D.RING_PULSE_PERIOD >= 1.5, "周期が速すぎない", ...)
```

こう書いておくと、誰かが振幅を上げすぎたときに止まる。

### 落ちた検査は原因を切り分けてから直す

仕様変更で前提が変わったなら検査を更新する。カメラの中心を現在地へ移した際、
原点前提の検査が落ちたのはこれに当たる（定数 `FOCUS` ではなく現在の
`camera.focus` を見る形に直した）。

**実装のバグなら実装を直す。** 通したいがために閾値を緩めるのは、検査そのものを
無意味にする。どちらか毎回判断すること。

**「環境の揺れ」で片付けない。** 実行のたびに結果が変わる検査を
「ヘッドレスのフレーム進行が一定でないため」と診断したことがあるが、誤りだった。
真因は検査が `elapsed += 0.016` と**フレーム数に固定値を掛けて経過時間を
代用していた**こと（1フレームの実尺は環境と出力先で変わる。実測で12フレーム
93ms、演出に必要な620msに遠く届かない）。揺れではなく待ち方の誤りで、
閾値を緩める方向で片付けていたら検査は無意味になっていた。
**時間を待つなら実時間で計る**（`Time.get_ticks_msec()`）。

### シナリオは公開 API だけを触る

アンダースコア付きの変数や関数を検査から触らない。内部表現を変えるたびに
検査が道連れになるため。**辞書をそのまま公開するのも避ける**（キーの構造まで
契約になる）。用途ごとの細い関数を足すこと（`badge_text_for()`,
`note_text_for()`, `voice_count()` がその形）。

ツリー外という実行環境の制約で必要になる入口は、理由をコメントに書いて
公開してよい:

- `map_panel.layout_nodes()` — ツリー外では `resized` が飛ばず、
  他に配置を確定させる手段がない
- `map_view_3d.pulse_scale_at(elapsed)` — 時刻を引数に取る純関数。
  位相ごとの振る舞いを内部状態に触らず確かめられる

### 検査は実装を壊して効き目を確かめる

書いた検査が本当に効くかは、**わざと実装を壊して落ちることを見る**まで
分からない。実際に、64bit の RNG state を「数値で保存しても通ってしまう」
検査を書いていた（`to_dict()` どうしを比べており、JSON を経由していなかった）。

落ちなければ検査になっていない。書いたら1度は壊してみること。

## 短い指示は実装前に確かめる

「空中に」「現在地を中心に」のような指示は解釈が割れる。**実装してから
「そういう意味ではない」となる方が高くつく。** `AskUserQuestion` で図を添えて
選んでもらうこと。図があると言葉より速く決まる。

一方、既定のやり方がある選択（命名、置き場所、既存に合わせる形）は聞かずに
決めて、何を選んだか報告する。

## コミットメッセージ

**何を変えたかは diff が語る。なぜそうしたかを書く。**
`reset_view` が中心を残す理由、検査に上限を設けた理由など、コードからは
読み取れない判断を残すこと。

## UI スクリプトの注意

`--script` のハーネスから UI を検証する際、`root.add_child()` しても
**`is_inside_tree()` は false のまま**になる（`SceneTree` 実行時は root が
構築中のため）。したがって:

- 表示更新の可否を `is_inside_tree()` で判定しない。ノードの有効性は
  `is_instance_valid()` で見る
- `@onready` と手動のノード解決を混ぜない。`@onready` はツリー投入の次フレームに
  エンジンが代入するため、それより先に手動代入した参照を null で上書きしてしまう
- `%NodeName` はシーンのオーナー解決に依存し、ツリー外では引けないことがある。
  `find_child()` へのフォールバックを用意しておく

[hud.gd](scripts/ui/hud.gd) の `_resolve_nodes()` / `_is_ready()` がこの形。

## 配布用ビルド

Windows 向けの単一 exe を書き出す:

```bash
mkdir -p exports   # 出力先が無いとエクスポートは失敗する
"...Godot_v4.7.1-stable_win64_console.exe" \
  --headless --path . --export-release "Windows Desktop"
```

`exports/TollRoad.exe`（約109MB）が出来る。PCK を埋め込んでいるので**1ファイルで完結**し、
プロジェクトフォルダの外へ持ち出しても動く。

- エクスポートテンプレートは `~/AppData/Roaming/Godot/export_templates/4.7.1.stable/` に必要
  （約1.28GB。`Godot_v4.7.1-stable_export_templates.tpz` を展開する）
- [export_presets.cfg](export_presets.cfg) は**追跡している**。別環境でも同じ設定で
  作れるようにするため。署名鍵など環境固有の値を入れる場合は `.gitignore` へ戻すこと
- `exclude_filter` で `scenario_*.gd` を除外しているので、検証シナリオは配布物に入らない
- `exports/` は `.gitignore` 済み（109MB をリポジトリに入れない）

## 現在の実装状況

**M8 まで完了 = ロードマップ完走**（[roadmap.md](docs/roadmap.md) 参照）。
1日目から60日目のランク画面まで、マウスだけで通しで遊べる。市場・積荷・大陸図・
製作所・相場メモ・島と装備・探索・航海日誌・休息・リザルト。解像度は 1280x720。
セーブ/ロードは実装済み（日送りで自動保存、開始画面から「続きから」）。

構造の説明は [architecture.md](docs/architecture.md) にある。
CLAUDE.md は作業時の規約、architecture.md は構造の説明という分担。

検証シナリオは `scripts/systems/scenario_m1.gd` 〜 `scenario_m20.gd` の20本。
新しい機能を足したら対応するシナリオも足し、`scenario_all.gd` の
`SCENARIO_COUNT` を更新すること（忘れてもランナーが本数を照合して止める）。

**大陸図は 3D**（[map_view_3d.gd](scripts/ui/map_view_3d.gd)）。`SubViewport` に
地形・都市・経路を描き、`Camera3D` で周回する。`own_world_3d = true` は必須
（付けないと本編の 2D 世界を映す）。

**都市の選択は Button ではなくレイキャスト。** `SubViewportContainer` の
`gui_input` 内で `Camera3D.project_ray_origin/normal()` からレイを作り、
都市の柱（`map_view_3d.gd` の `positions`）との最短距離が `PICK_RADIUS`
以内でカメラに最も近いものを選ぶ（`map_panel.gd` の `pick_city_at()`）。
固定サイズの `Button` を画面座標に重ねる方式は、地図領域が狭いとボタンが
領域外へはみ出し他のパネルに被さる問題があったため廃止した。クリック可能
領域は常に `SubViewportContainer` 自身の矩形内に収まる。

都市の見た目（ピンと都市名ラベル）は `mouse_filter = IGNORE` の素の
`Control`（旧 `Button`）で、入力は下の `SubViewportContainer` へ透過する。
ホバー中のツールチップは `_tooltip` として手動で表示・追従させている
（Godot標準の `tooltip_text` は使わない）。

`pick_city_at()` / `select_city()` / `is_selectable()` / `screen_position_for()` /
`tooltip_text_for()` はいずれも公開関数で、`--script` からそのまま呼べる。
操作の検査（`scenario_m6.gd`, `scenario_m17.gd`）はこれらを直接呼ぶ形で行う。
カメラを動かしたら `_update_button_positions()` を呼ぶこと（ピンの追従。
当たり判定はレイキャストが毎回その場で計算するので追従処理は不要）。

幾何の検査は **3D の `Vector3` で行う**（投影後の画面座標はカメラ次第で変わる）。
`gl_compatibility` でも基本的な 3D は動くが、SSAO・VoxelGI・高度な影は使えない。

**頂点を動かしたら法線を引き直す。外積の順序に注意。**
逆にすると法線が下を向き、地面が裏返って光が当たらず**真っ黒に描画される**
（実際にそうなった）。ノードもメッシュも正常に見えるためヘッドレスでは
気づけない。`scenario_m17.gd` が法線の向きを検査する。

**ツリー外では `global_transform` が更新されない。** `--script` のハーネスで
カメラの向きを見るときは `transform` を使う。`look_at()` も使えないので
`look_at_from_position()` を使うこと。

3D 化で不要になった 2D の描画層（`map_ground.gd` / `map_routes.gd`）は
削除済み。戻すなら git 履歴から取る。
`map_pin.gd` は 2D 由来だが**現役**（都市ノードの枠と軸を描いている）。

**価格バーの目盛りは全品目で共通**（`UiTheme.PRICE_SCALE_MIN`〜`MAX` = 60〜145%）。
品目ごとに変えると同じバー位置が別の意味になり、行をまたいだ比較ができなく
なる。実測の幅は資源 62〜123%、装備 76〜144% なので現在の目盛りに収まる。
価格の補正値を変えたら `scenario_m16.gd` が範囲外を検出する。

**効果音は音声ファイルを持たない。** [sfx.gd](scripts/ui/sfx.gd) が
`AudioStreamWAV` を実行時に組み立てる（画像を SVG で自作したのと同じ方針）。
音を足すときは `Kind` に追加し、`_build()` で周波数・長さ・ノイズ量を指定、
`VOLUMES` に音量を書く。頻度の高い音ほど小さくすること。

**`_ready()` に初期化を置かない。** `--script` のハーネスでは
**`root.add_child()` しても走らない**（実測: `is_node_ready()` が false のまま）。
`@onready` も代入されないので、そこで結線していると**まるごと失敗する**。
`_init()` と `_ready()` の両方から呼べる `_configure()` のような形にすること
（[fx_layer.gd](scripts/ui/fx_layer.gd) と
[main.gd](scenes/main/main.gd) が例）。二度呼ばれても害が無いよう、
接続は `is_connected` でガードする。
同じ理由で `is_inside_tree()` も判定に使わない — 親の有無を見る。

**ツリー外では `get_tree()` が null。** `await get_tree().process_frame` は
そのまま書くと落ちる。待たずに戻る分岐を用意すること
（`main.gd` の `_append_log()` が例。そもそもフレームが進まない）。

**`.tscn` を手書きしたら、必ず GUI で1度見ること。**
ヘッドレスの検査はノードを引けるかしか見ておらず、**描画の破損を検出できない**。
実際に開始画面が中身のない黒い矩形として表示される不具合を2度見逃した。

特に `Window` の子は要注意:

- `anchors_preset` だけ書いて `offset_right` / `offset_bottom` を省くと
  **サイズが (0,0) のまま**になり、中身があっても描画されない
- `autowrap_mode` の `Label` は幅の起点がないと縦に膨張する（実際に高さ
  6694px になった）。`custom_minimum_size` で幅を与えること
- `wrap_controls = true` は Window を中身に合わせて広げるため、上記と
  組み合わさると破綻する

`ui_util.fill_window()` がアンカーとオフセットを確定させる。ダイアログを
足したら呼ぶこと。`scenario_m13.gd` の `_test_dialog_sizing()` が実寸を検査し、
`_test_scene_headers()` が `load_steps` の整合を見る。

**目標額は `GameData.GOAL_RANK` 経由で引く。** HUD の進捗バーと開始画面が
同じ定義を参照しており、`RANKS` の数値を変えれば説明文も追従する。
UI に閾値をハードコードしないこと。

**シグナルとハンドラの引数を一致させること。** `silver_changed(amount)` や
`day_advanced(day)` は引数を渡す。引数なしのハンドラを繋いでも Godot は接続を
許すが、発火時に毎回エラーになり**そのハンドラだけ呼ばれない**。他のシグナル
経由で更新されると検査は通ってしまうため気づきにくい。`scenario_m10.gd` の
`_test_signal_arity()` が全パネルで検出する。

UI パネルは `bind(session)` と `refresh()` を持つ規約。ノード解決は
[ui_util.gd](scripts/ui/ui_util.gd) の `find_node()`、**色は必ず**
[ui_theme.gd](scripts/ui/ui_theme.gd) から取る（パネルに生の `Color()` を
書かない）。品目アイコンは [ui_icons.gd](scripts/ui/ui_icons.gd) 経由で取り、
**画像が無くても壊れない**（`null` が返り、名前だけで表示される）。
`GridContainer` に並ぶセルは `make_labeled_item()` でアイコンと名前を1セルに
収める — 列を増やすと既存シナリオの行数検査が壊れるため。

大陸図（[map_panel.gd](scripts/ui/map_panel.gd)）は都市を絶対座標で円周配置する。
`CityList` の子には経路線の層（`Routes`）とボタンが混在するので、ボタンだけを
拾うこと。ノードのテキストは中の `Note` ラベルとツールチップに入り、
`button.text` は空。

`Window` 系（`popup_centered` など）はツリー外だとエラーになる。
`is_inside_tree()` でガードする。

画像は `assets/sprites/` の4種別（`items` / `cities` / `mounts` / `island`）。
`ui_icons.gd` が種別ごとに引く（`item_texture` / `city_texture` /
`mount_texture` / `island_texture`）。**種別が違えば同名でも混ざらない**。
背景とパネルの地色は `ui_theme.gd` の `apply_panel_style()` /
`make_backdrop_style()` で、[main.gd](scenes/main/main.gd) の
`_apply_backdrop()` がまとめて適用する（パネル側には書かない）。`bind()` は `UiUtil.rebind()` 経由にすること — 再プレイで
古いセッションが繋がったままになるのを防ぐため。

**大陸図は画面全体の背景。** `Main.tscn` の `%大陸図` は `Root` 直下に
`PRESET_FULL_RECT` で敷き、他の画面はその上に浮かぶオーバーレイとして
配置する。`_apply_backdrop()` は `%大陸図` だけ `apply_panel_style()` を
かけず、代わりに `UiTheme.make_transparent_style()`（`StyleBoxEmpty`）を
与える。他パネルと同じ不透明な地色を敷くと、3D世界の外側（空）を覆い
隠して背景として機能しなくなるため。

**Tween はツリー外では作れない。** `--script` のハーネスは
`root.add_child()` してもツリー外扱いなので、`is_inside_tree()` が false の
場合はアニメーションを挟まず即座に反映する分岐を必ず用意する
（[hud.gd](scripts/ui/hud.gd) の `_animate_silver()`、
[main.gd](scenes/main/main.gd) の `_animate_side_panel()` が例）。

キー操作は `[input]` の `tr_rest`（Space）と `tr_tab_1`〜`5`（1〜5）。
`_input` ではなく `_unhandled_input` で処理し、フォーカス中のコントロールから
キーを奪わないようにしている。

**市場・積荷・製作所・相場メモ・島と装備の5画面はスライド式サイドパネル。**
常時表示は右端の `%TabStrip`（5つのボタン）のみで、押すと `%SidePanel`
（中身は従来どおり `%Tabs` という `TabContainer`）が画面右からスライドで
出てくる。閉じている間は幅0まで畳まれる（`SidePanel` の `offset_left` を
Tween で動かす。`clip_contents = true` なので畳まれている間は中身が
見えない）。**開いている状態でどのボタンを押しても閉じる**（別のタブへの
切り替えではない）。キーボードの `tr_tab_1`〜`5` も `main.gd` の
`_on_tab_strip_pressed()` を経由するため同じ挙動になる。`Tabs` 自体の
タブバーは `tabs_visible = false` で隠している（選択は `TabStrip` 側が
持つため、二重に出さない）。`is_side_panel_open()` が公開関数で、
検査から開閉状態を直接確認できる。

航海日誌と操作ボタン（休息する/目標/結果を見る）は `%LogActions` として
左下に常時表示のオーバーレイでまとめている。中身（`LogPanel` 相当の
`LogTitle`/`LogScroll`/`LogList` と `Actions` の各ボタン）は以前の構成から
そのまま持ってきているだけで、ロジックの変更はない。

**バランスは検証済み。数値を調整しないこと。** 実測（各20〜30回の通しプレイ、王国都市5＋カーレオン計6都市だった頃の地図で測定）:

| 戦略 | 中央値 | 到達ランク |
|---|---|---|
| 資源を安く買って高く売るだけ | 57,763 | SURVIVOR |
| 製作を加えて巡回 | 93,446 | SURVIVOR |
| **ボーナス都市⇄カーレオンを製作しながら往復** | **857,345** | **MASTER 11/20** |

意図された成長ルートは「アイアンホロウで鉱石→剣を作りレイヴンスパイアで売る」の反復。
剣1個の原価は鉱石2個+手数料90（約356）に対しレイヴンスパイアでは約1,860 と5倍。
最適ルートなら LEGENDARY（120万）も射程に入る一方、襲撃が連続すると破産もある。

**王国都市を5→9に増やした際（レイヴンスパイア含め計10都市）、上表の実測値は
再検証していない。** 巡回ルートの総移動日数や周回効率が変わるため、この表を
根拠に数値を調整する前に実機で20〜30回の通しプレイを取り直すこと。

**王道を環から不規則な連結グラフ（GameData.ROYAL_ROAD_EDGES）に変更した際も、
同じ理由で上表は未再検証。** 移動は経路探索により複数区間を自動でまたぐため、
都市ペアごとの実質コスト・日数・襲撃リスクが環のときと変わる（黒ゾーンを
2回経由した方が安い遠方ペアが生まれるなど）。上記の5→9拡張の再検証と
まとめて、実機での通しプレイで測り直すこと。

**積載の罠**: 資源2個（重量2）が装備1個（重量3）になるため正味+1の空きが要る。
積荷を満杯にすると製作できなくなる。[workshop_panel.gd](scripts/ui/workshop_panel.gd)
の `_blocked_reason()` がこれをツールチップで説明している。
ウィンドウ解像度（`[display]`）は未設定で Godot デフォルトの 1152x648。M5 で決める。
