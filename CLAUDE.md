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

### `--check-only --script` は検証に使わない

このモードは autoload を初期化しないため、`main.gd` を単体でコンパイルすると
`Identifier not found: GameState` という**偽のエラー**を出す。実際のゲームは正常に動く。
スクリプトの検証は上記のヘッドレス実行で行うこと。

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

## 検証

ロジックの検査はシード固定のシナリオで行う（テストフレームワークは使わない）:

```bash
"...Godot_v4.7.1-stable_win64_console.exe" \
  --headless --path . --script scripts/systems/scenario_m1.gd
```

全件合格なら exit 0、失敗があれば `FAIL:` を出力して exit 1。

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
製作所・相場メモ・島と装備・航海日誌・休息・リザルト。解像度は 1280x720。

検証シナリオは `scripts/systems/scenario_m1.gd` 〜 `scenario_m17.gd` の17本。
新しい機能を足したら対応するシナリオも足すこと。

**大陸図は斜め見下ろし**（`UiTheme.MAP_TILT` で Y を圧縮）。円が楕円に潰れるため、
幾何を検査するときは **Y を `MAP_TILT` で割って逆変換してから**距離や角度を見る
（`scenario_m11.gd` / `m17.gd` が例）。層は下から 地盤 → 経路線 → 都市ノードで、
都市は Y の昇順に並べて手前が上に重なるようにしている。

**価格バーの目盛りは全品目で共通**（`UiTheme.PRICE_SCALE_MIN`〜`MAX` = 60〜145%）。
品目ごとに変えると同じバー位置が別の意味になり、行をまたいだ比較ができなく
なる。実測の幅は資源 62〜123%、装備 76〜144% なので現在の目盛りに収まる。
価格の補正値を変えたら `scenario_m16.gd` が範囲外を検出する。

**効果音は音声ファイルを持たない。** [sfx.gd](scripts/ui/sfx.gd) が
`AudioStreamWAV` を実行時に組み立てる（画像を SVG で自作したのと同じ方針）。
音を足すときは `Kind` に追加し、`_build()` で周波数・長さ・ノイズ量を指定、
`VOLUMES` に音量を書く。頻度の高い音ほど小さくすること。

**`_ready()` に初期化を置かない。** `--script` のハーネスでは走らないことが
あり、未初期化のまま検査を通してしまう。`_init()` と `_ready()` の両方から
呼べる `_configure()` のような形にする（[fx_layer.gd](scripts/ui/fx_layer.gd)
が例）。同じ理由で `is_inside_tree()` も判定に使わない — 親の有無を見る。

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

**Tween はツリー外では作れない。** `--script` のハーネスは
`root.add_child()` してもツリー外扱いなので、`is_inside_tree()` が false の
場合はアニメーションを挟まず即座に反映する分岐を必ず用意する
（[hud.gd](scripts/ui/hud.gd) の `_animate_silver()` が例）。

キー操作は `[input]` の `tr_rest`（Space）と `tr_tab_1`〜`4`（1〜4）。
`_input` ではなく `_unhandled_input` で処理し、フォーカス中のコントロールから
キーを奪わないようにしている。
右側の4画面は `Main.tscn` の `%Tabs`（TabContainer）配下にあり、**ノード名が
そのままタブ名になる**ため日本語（`%大陸図` など）。名前を変えると
シナリオの参照も壊れるので注意。

未着手: リザルト画面と調整（M8）。

**バランスは検証済み。数値を調整しないこと。** 実測（各20〜30回の通しプレイ）:

| 戦略 | 中央値 | 到達ランク |
|---|---|---|
| 資源を安く買って高く売るだけ | 57,763 | SURVIVOR |
| 製作を加えて巡回 | 93,446 | SURVIVOR |
| **ボーナス都市⇄カーレオンを製作しながら往復** | **857,345** | **MASTER 11/20** |

意図された成長ルートは「マートロックで鉱石→剣を作りカーレオンで売る」の反復。
剣1個の原価は鉱石2個+手数料90（約356）に対しカーレオンでは約1,860 と5倍。
最適ルートなら LEGENDARY（120万）も射程に入る一方、襲撃が連続すると破産もある。

**積載の罠**: 資源2個（重量2）が装備1個（重量3）になるため正味+1の空きが要る。
積荷を満杯にすると製作できなくなる。[workshop_panel.gd](scripts/ui/workshop_panel.gd)
の `_blocked_reason()` がこれをツールチップで説明している。
ウィンドウ解像度（`[display]`）は未設定で Godot デフォルトの 1152x648。M5 で決める。
