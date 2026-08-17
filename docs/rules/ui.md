# UI と 3D

画面まわりの規約。ツリー外（`--script` のハーネス）での罠が多いので、
実測で分かったことをここに集めている。[CLAUDE.md](../../CLAUDE.md) から
分離した規約のひとつ。

## ツリー外で踏む罠

`--script` のハーネスから UI を検証する際、`root.add_child()` しても
**`is_inside_tree()` は false のまま**になる（`SceneTree` 実行時は root が
構築中のため）。したがって:

- 表示更新の可否を `is_inside_tree()` で判定しない。ノードの有効性は
  `is_instance_valid()` で見る
- `@onready` と手動のノード解決を混ぜない。`@onready` はツリー投入の次フレームに
  エンジンが代入するため、それより先に手動代入した参照を null で上書きしてしまう
- `%NodeName` はシーンのオーナー解決に依存し、ツリー外では引けないことがある。
  `find_child()` へのフォールバックを用意しておく

[hud.gd](../../scripts/ui/hud.gd) の `_resolve_nodes()` / `_is_ready()` がこの形。

**`_ready()` に初期化を置かない。** `--script` のハーネスでは
**`root.add_child()` しても走らない**（実測: `is_node_ready()` が false のまま）。
`@onready` も代入されないので、そこで結線していると**まるごと失敗する**。
`_init()` と `_ready()` の両方から呼べる `_configure()` のような形にすること
（[fx_layer.gd](../../scripts/ui/fx_layer.gd) と
[main.gd](../../scenes/main/main.gd) が例）。二度呼ばれても害が無いよう、
接続は `is_connected` でガードする。
同じ理由で `is_inside_tree()` も判定に使わない — 親の有無を見る。

**ツリー外では `get_tree()` が null。** `await get_tree().process_frame` は
そのまま書くと落ちる。待たずに戻る分岐を用意すること
（`main.gd` の `_append_log()` が例。そもそもフレームが進まない）。

**Tween はツリー外では作れない。** `--script` のハーネスは
`root.add_child()` してもツリー外扱いなので、`is_inside_tree()` が false の
場合はアニメーションを挟まず即座に反映する分岐を必ず用意する
（[hud.gd](../../scripts/ui/hud.gd) の `_animate_silver()`、
[main.gd](../../scenes/main/main.gd) の `_animate_side_panel()` が例）。

**ツリー外では `global_transform` が更新されない。** `--script` のハーネスで
カメラの向きを見るときは `transform` を使う。`look_at()` も使えないので
`look_at_from_position()` を使うこと。

`Window` 系（`popup_centered` など）はツリー外だとエラーになる。
`is_inside_tree()` でガードする。

## パネルの規約

UI パネルは `bind(session)` と `refresh()` を持つ規約。ノード解決は
[ui_util.gd](../../scripts/ui/ui_util.gd) の `find_node()`、**色は必ず**
[ui_theme.gd](../../scripts/ui/ui_theme.gd) から取る（パネルに生の `Color()` を
書かない）。品目アイコンは [ui_icons.gd](../../scripts/ui/ui_icons.gd) 経由で取り、
**画像が無くても壊れない**（`null` が返り、名前だけで表示される）。
`GridContainer` に並ぶセルは `make_labeled_item()` でアイコンと名前を1セルに
収める — 列を増やすと既存シナリオの行数検査が壊れるため。

子を組み直す前は `UiUtil.clear_children()` を使う。`remove_child()` と
`queue_free()` の**両方**が要る（`queue_free()` だけだと解放が次フレームまで
遅れ、その間 `get_child_count()` に残る。ツリー外ではフレームが進まないため
消えたはずの子が見えてしまう）。

Control を親いっぱいに広げるときは `UiUtil.fill_parent()`。
`set_anchors_preset()` はオフセットも書き換えるため、preset だけに頼ると
サイズ 0 で描画されない罠に戻りうる。

画像は `assets/sprites/` の4種別（`items` / `cities` / `mounts` / `island`）。
`ui_icons.gd` が種別ごとに引く（`item_texture` / `city_texture` /
`mount_texture` / `island_texture`）。**種別が違えば同名でも混ざらない**。
パネルの地色は `ui_theme.gd` の `apply_panel_style()` で適用する
（パネル側には書かない）。`bind()` は `UiUtil.rebind()` 経由にすること — 再プレイで
古いセッションが繋がったままになるのを防ぐため。

**シグナルとハンドラの引数を一致させること。** `silver_changed(amount)` や
`day_advanced(day)` は引数を渡す。引数なしのハンドラを繋いでも Godot は接続を
許すが、発火時に毎回エラーになり**そのハンドラだけ呼ばれない**。他のシグナル
経由で更新されると検査は通ってしまうため気づきにくい。`scenario_m10.gd` の
`_test_signal_arity()` が全パネルで検出する。

**目標額は `GameData.GOAL_RANK` 経由で引く。** 目標到達度のバーと開始画面が
同じ定義を参照しており、`RANKS` の数値を変えれば説明文も追従する。
UI に閾値をハードコードしないこと。

## 手書きの .tscn

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

## 画面の構成

**大陸図は画面全体の背景。** `Main.tscn` の `%大陸図` は `Root` 直下に
`PRESET_FULL_RECT` で敷き、他の画面はその上に浮かぶオーバーレイとして
配置する。[main.gd](../../scenes/main/main.gd) の `_apply_backdrop()` は
`%大陸図` だけ `apply_panel_style()` をかけず、代わりに
`UiTheme.make_transparent_style()`（`StyleBoxEmpty`）を与える。他パネルと
同じ不透明な地色を敷くと、3D世界の外側（空）を覆い隠して背景として
機能しなくなるため。大陸図の `SubViewport` 自体が `transparent_bg = false`
で自前の Sky を不透明に描画するので、この背後に別の下地パネルは不要
（かつて敷いていたが、大陸図が常時画面全体を覆うため一度も見えない
まま隠れていた。実測で発見し撤去した）。

**サイドパネルはスライド式。** 常時表示は右端の `%TabStrip` のみで、押すと
`%SidePanel`（中身は `%Tabs` という `TabContainer`）が画面右からスライドで
出てくる。閉じている間は幅0まで畳まれる（`SidePanel` の `offset_left` を
Tween で動かす。`clip_contents = true` なので畳まれている間は中身が
見えない）。**開いている状態でどのボタンを押しても閉じる**（別のタブへの
切り替えではない）。キーボードのタブキーも `main.gd` の
`_on_tab_strip_pressed()` を経由するため同じ挙動になる。`Tabs` 自体の
タブバーは `tabs_visible = false` で隠している（選択は `TabStrip` 側が
持つため、二重に出さない）。`is_side_panel_open()` が公開関数で、
検査から開閉状態を直接確認できる。タブの現在の顔ぶれは
[status.md](../status.md) を参照。

航海日誌と操作ボタン（休息する/目標/結果を見る）は `%LogActions` として
左下に常時表示のオーバーレイでまとめている。

キー操作は `[input]` に定義する。`_input` ではなく `_unhandled_input` で
処理し、フォーカス中のコントロールからキーを奪わないようにしている。

**デバッグ画面はサイドパネルの外**にある。F3 が市場データ
（[debug_panel.gd](../../scripts/ui/debug_panel.gd)）、F5 が運送
（[logistics_debug_panel.gd](../../scripts/ui/logistics_debug_panel.gd)）で、
どちらも `%SidePanel` のタブとは独立したオーバーレイ。`main.gd` の
`_unhandled_input()` から `toggle_visible()` を呼ぶだけで、タブストリップの
開閉ロジックには一切触れない。`_panels` には乗るので `bind()` / `refresh()` は
他のパネルと同じに来る。F4 はトゥーンの切り替えで埋まっているため空いていない。

デバッグ画面が `SubViewport` を持つ場合、`render_target_update_mode` を
`UPDATE_ALWAYS` にしないこと。パネルは普段閉じており、見えない 3D を毎フレーム
描き続けることになる（本編の大陸図と二重に描く）。`UPDATE_WHEN_VISIBLE` を使う。

## 大陸図（3D）

**大陸図は 3D**（[map_view_3d.gd](../../scripts/ui/map_view_3d.gd)）。`SubViewport` に
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

**都市と街道の周辺は地形を平らに均している。** 人は平地に街を作り道は緩い
斜面を通る、という方針で `height_at()` が `_flat_positions`（ばね緩和後の
水平配置）を見て起伏を押し下げる。ここには順序の制約がある —
`positions` は `height_at()` を通して作られるので、`height_at()` が
`positions` を見ると循環する。**水平配置（`_flat_positions`）を見ること**、
そして `_build()` で `_compute_positions()` より先に代入すること。

平らにする際の**寄せ先は 0 ではなく、その一帯のなだらかな標高**にする
（0 に寄せると高地の都市が穴の底に沈む）。寄せ先自体が滑らかでないと
平地化にならず、逆に急斜面を作る。実際に寄せ先へ細かい起伏の残る値を
使い、都市の足元が64度・街道の平均が40度と**平地化前より悪化した**。
`scenario_m27.gd` が都市・街道の傾斜と、都市の沈み込みを検査する。

**頂点を動かしたら法線を引き直す。外積の順序に注意。**
逆にすると法線が下を向き、地面が裏返って光が当たらず**真っ黒に描画される**
（実際にそうなった）。ノードもメッシュも正常に見えるためヘッドレスでは
気づけない。`scenario_m17.gd` が法線の向きを検査する。

**`map_view_3d.gd` は定数をシナリオが静的に読む。** `scenario_m21.gd` は
ファイルスコープの `const` 初期化子で `MapView3D.CITY_SPACING` を参照して
おり、パース時に解決される。GDScript は const を再エクスポートできないため、
定数を別ファイルへ移すと同じ値が2箇所に増える。分割を考える際はここが制約になる。

大陸図（[map_panel.gd](../../scripts/ui/map_panel.gd)）は都市を絶対座標で配置する。
`CityList` の子には経路線の層（`Routes`）とノードが混在するので、都市ノードだけを
拾うこと。ノードのテキストは中の `Note` ラベルとツールチップに入り、
`button.text` は空。

3D 化で不要になった 2D の描画層（`map_ground.gd` / `map_routes.gd`）は
削除済み。戻すなら git 履歴から取る。
`map_pin.gd` は 2D 由来だが**現役**（都市ノードの枠と軸を描いている）。

## 価格バーと効果音

**価格バーの目盛りは全品目で共通**（`UiTheme.PRICE_SCALE_MIN`〜`MAX` = 50〜170%）。
品目ごとに変えると同じバー位置が別の意味になり、行をまたいだ比較ができなく
なる。建値だけなら資源 62〜123%、装備 76〜144% だが、実際の買値・売値には
さらに在庫・需要の掛け率が乗るため（最悪 54〜165%）、その両端を含む幅にしてある。
価格の補正値を変えたら `scenario_m16.gd` が、在庫連動を変えたら
`scenario_m23.gd` が範囲外を検出する。

**効果音は音声ファイルを持たない。** [sfx.gd](../../scripts/ui/sfx.gd) が
`AudioStreamWAV` を実行時に組み立てる（画像を SVG で自作したのと同じ方針）。
音を足すときは `Kind` に追加し、`_build()` で周波数・長さ・ノイズ量を指定、
`VOLUMES` に音量を書く。頻度の高い音ほど小さくすること。

**日誌から鳴らす音は本文で選ばない。** `GameSession.LogKind` を見ること。
本文の日本語から選ぶと、文面を書き換えたときに音が黙って鳴らなくなる
（かつて効果の説明文に「製作」「襲撃」が含まれる同行者だけ、たまたま音が
鳴っていた）。セーブから復元した行だけは種別が残っていないため、
`Sfx.kind_for_message()` が本文から引き直す。この判定は1箇所に閉じること。
