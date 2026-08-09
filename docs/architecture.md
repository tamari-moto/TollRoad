# アーキテクチャ

TollRoad の構造の説明。**なぜそうなっているか**を残すのが目的で、
作業時の規約は [CLAUDE.md](../CLAUDE.md) にある（重複させず、必要なら参照する）。

ロードマップ [roadmap.md](roadmap.md) は実装45行の時点で書かれた歴史文書で、
現状とは乖離している。**現在の構造はこの文書を見ること。**

## 全体像

ロジック層は4ファイル 682行。依存は一方向で、循環がない。

```
game_data.gd — 定数のみ。何にも依存しない葉
    ↑ preload
    ├── price_table.gd — 全都市×全品目の価格表
    ↑ preload             _rng は GameSession から参照で受け取る
    │                     ↑ preload
    └── game_session.gd ─┘
            │  1プレイ（60日）の全状態と全アクション。シグナル7つ
            │  to_dict() / from_dict() で状態を写し取る
            ↑ preload
            ├── save_manager.gd — ファイル入出力と版の整合
            ├── game_state.gd — 唯一の autoload。session と保存の入口
            ├── scenes/main/main.gd — 調停役
            └── scripts/ui/*.gd (20ファイル) — bind(session) / refresh() 規約
```

上の層は下を知っているが、下は上を知らない。`GameSession` は UI を一切参照せず、
シグナルを投げるだけ。だから UI 無しで（`--script` から）駆動できる。

## 責務

### ロジック層

| ファイル | 持つもの | 持たないもの |
|---|---|---|
| `game_data.gd` | 全ての静的定義（品目9・都市6・ランク・島・騎乗・各種係数）と static ヘルパ4つ | 状態。インスタンス化されない |
| `price_table.gd` | `prices[city][item]` と `reroll()` | 乱数源（`_rng` は借り物）。日付の概念 |
| `game_session.gd` | 可変状態（下記）とプレイヤーの全行動。ルールの中枢。`to_dict()` / `from_dict()` | UI への参照。autoload への依存。**保存の形式**（JSON かどうかを知らない） |
| `save_manager.gd` | `user://` への読み書き、版の判定、範囲の丸め | 状態の意味（写し取りは GameSession の担当） |
| `game_state.gd` | `session`、`session_started`、保存と再開の入口 | **ゲームのルール**（意図的に空。理由は後述） |

`GameSession` が持つ状態は `day` / `silver` / `current_city` / `mount` /
`island_level` / `cargo` / `warehouse` / `memo` / `log_entries` / `prices` / `_rng`。
すべて int・String・Dictionary・Array[String] で、参照型の絡みがない。

行動系の API は全て `bool` を返し、事前条件を満たさなければ `false` で何もしない。
`buy()` に対する `max_buyable()` のように、**上限を問い合わせる関数が対で用意されている**。
UI はこれを見てボタンの有効・無効を決める。

### UI 層

| ファイル | 責務 |
|---|---|
| `scenes/main/main.gd` | セッションの配布、共通スタイル適用、サイドパネル開閉、航海日誌、効果音の中央発火、キー入力 |
| `ui_theme.gd` | 全ての配色・閾値・アニメ秒数。**パネルに生の `Color()` を書かない**ための単一集約点 |
| `ui_util.gd` | `find_node()` / `rebind()` / `fill_window()` / `format_number()` |
| `ui_icons.gd` | SVG アイコンの遅延ロードとキャッシュ。**欠損時は null を返す**（画像が無くても壊れない） |
| 各パネル | `bind(session)` と `refresh()` の規約に従い、自分の関心事だけを描く |

`main.gd` は**ゲームのルールを持たない**。表示と入力の橋渡しだけを行う。

`map_ground.gd` と `map_routes.gd` は 3D 化以前の 2D 描画層で、`map_panel.gd` から
`const` で preload されるだけで一度も生成されない。戻せるよう残してあるが**現在は未使用**。

## 設計判断とその理由

コードを読んでも分からないものだけを挙げる。

### ロジックを autoload に置かない

`--script` のハーネスは autoload を初期化しない。autoload 経由でしか触れない
ロジックは検証できなくなる。そのため `scripts/systems/` に素のクラスとして書き、
`load()` + `.new()` で駆動できる形を保っている。

`game_state.gd` が薄いのはこの帰結。`GameSession` を作って持つだけで、
ルールは一切持たない。**この制約が18本の検証シナリオを成立させている。**

### RNG は単一インスタンスを共有する

`GameSession._init()` が `RandomNumberGenerator` を1つ作り、
`PriceTable.new(_rng)` へ**参照で**渡す。乱数を消費するのは3箇所:

| 箇所 | 消費 |
|---|---|
| `price_table.gd` の価格ゆらぎ | 6都市 × 9品目 = 54回／日 |
| `game_session.gd` の襲撃判定 | 黒ゾーン移動1回につき1 |
| `game_session.gd` の労働者の抽選 | 労働者数 × 2 回／日 |

**消費の順序は `_advance_day()` が固定している**（価格リロール → メモ記録 → 労働者）。
この順序を変えると、同じシードでも過去の記録と別の展開になる。

副作用として、**島レベルが違うと労働者の消費数が変わり、以降の価格系列がずれる**。
同じシードでも行動が違えば別の相場になるということで、これは意図した性質。
再現の単位は「シード」ではなく「シード＋同じ操作列」。

### 都市の選択はレイキャストで行う

3D の大陸図で都市を選ぶのに、画面座標へ `Button` を重ねる方式は使わない。
固定サイズの `Button` は地図領域が狭いと領域外へはみ出し、他のパネルに被さる。

代わりに `SubViewportContainer` の `gui_input` でレイを飛ばし、都市の柱との
最短距離が `PICK_RADIUS` 以内でカメラに最も近いものを選ぶ。
**クリック可能領域が常に `SubViewportContainer` の矩形内に収まる。**

見た目（ピンとラベル）は `mouse_filter = IGNORE` の素の `Control` で、
入力は下のコンテナへ透過する。判定と表示が分離している。

### セーブは2層に分け、起動時には消さない

状態の写し取り（`GameSession.to_dict()`）と、ファイル入出力・版の整合
（`save_manager.gd`）を分けている。セッションの内部を知っているのは
セッション自身だけなので `_rng` を外へ公開せずに済み、保存形式を変えても
セッションには手が入らない。

**`GameState._ready()` はセーブを消さない。** 起動時のセッションを
`start_new_game()` で作ると、その中の `delete_save()` が走って
**「続きから」が永遠に出なくなる**。実際に書いていて踏んだ。
セーブを捨てるのは「新規で始める」と決まった時点（開始画面を閉じた時）。

自動保存は `day_advanced` のみに繋ぐ。売買のたびに書くと頻度が高すぎる一方、
日送りは1日1回で、失っても直前の取引だけで済む。

落とし穴（64bit の RNG state、`prices` の保存、JSON の float 化）は
[CLAUDE.md](../CLAUDE.md) の「セーブ/ロード」節にまとめてある。

### 大陸図は画面全体の背景

`%大陸図` は `Root` 直下に `PRESET_FULL_RECT` で敷かれ、他の画面はその上に浮かぶ。
`_apply_backdrop()` は `%大陸図` にだけ `apply_panel_style()` をかけず、
`make_transparent_style()`（`StyleBoxEmpty`）を与える。

他のパネルと同じ不透明な地色を敷くと、3D世界の外側（空）を覆い隠してしまい、
背景として機能しなくなるため。

## 採らなかった選択肢

一度検討して却下した案。**再検討で時間を溶かさないために理由を残す。**

### 検証シナリオの共通化に composition を使わない

`scenario_base.gd` は継承（`extends "res://.../scenario_base.gd"`）にしてある。
RefCounted のヘルパを各シナリオが持つ形（composition）は却下した。

`_spawn()` が `root` を、`_finish()` が `quit()` を要る。どちらも `SceneTree` の
ものなのでヘルパへ注入が必要になり、**継承の手動再実装にしかならない**。
継承なら既存シナリオの本文に手を入れずに済んだ。

`--script` は `SceneTree` の派生を要求するが、**継承チェーンで満たしていれば
起動できる**（4.7.1 で実測）。

### 一括ランナーを PowerShell で書かない

Windows 専用になるうえ、プロセス起動が本数ぶん遅い（各1秒前後）。
Godot 自身なら `load().new()` で大半を1プロセスに収められる。

### `await` のシナリオを子ツリーで回さない

子の `SceneTree` ではフレームループが回らず `await process_frame` から
**復帰しない**。`_init()` が途中で止まり、`_failures` は0のままなので
**ランナーからは合格に見える**（実測で37件が黙って消えた）。

`process()` を手で呼んで回す案も試したが、**ハングして使えなかった**。
該当するシナリオは `OS.execute()` で別プロセスとして起動している
（`scenario_all.gd` の `AWAIT_SCENARIOS`）。

## シグナルの流れ

`GameSession` の7シグナル — `day_advanced(day)` / `silver_changed(amount)` /
`cargo_changed()` / `warehouse_changed()` / `island_upgraded(level)` /
`mount_changed(id)` / `logged(message)`。

**分散購読が主。** 各パネルが `bind()` の中で自分の関心事だけを直接繋ぐ。
繋ぎ替えは必ず `UiUtil.rebind()` を通す（再プレイで古いセッションが
繋がったままになるのを防ぐ）。

**中央購読が補。** `main.gd` が `logged` と `day_advanced` を拾い、
日誌への追記と効果音、および全パネルの一括 `refresh()` を行う。

> 一括 `refresh()` は各パネルの個別購読と重複している。移動で現在地が変わると
> 相場も製作ボーナスも変わるため確実を期したもので、1日1回なので実害はない。

**引数の一致は必須。** 引数なしのハンドラを繋いでも Godot は接続を許すが、
発火時に毎回エラーになり**そのハンドラだけ呼ばれない**。他のシグナル経由で
更新されると検査は通ってしまい気づきにくい。`scenario_m10.gd` の
`_test_signal_arity()` が全パネルで検出する。

## ツリー外という実行環境

`--script` のハーネスでは `root.add_child()` しても `is_inside_tree()` は
**false のまま**（`SceneTree` 実行時は root が構築中のため）。ここから制約が生まれる:

- ノードの有効性は `is_instance_valid()` で見る。`is_inside_tree()` で判定しない
- **Tween が作れない。** アニメーションを挟まず即反映する分岐を必ず用意する
  （`hud.gd` の `_animate_silver()`、`main.gd` の `_animate_side_panel()`）
- `@onready` と手動のノード解決を混ぜない（`@onready` が後から null で上書きする）
- `%NodeName` はツリー外で引けないことがある → `UiUtil.find_node()` が
  `find_child()` へフォールバックする
- `global_transform` が更新されない。`look_at()` も使えないので
  `look_at_from_position()` を使う
- `resized` シグナルが飛ばない → `map_panel` の配置は明示的に呼ぶ必要がある

`_ready()` に初期化を置かないのも同じ理由。走らないことがあり、未初期化のまま
検査を通してしまう。`_init()` と `_ready()` の両方から呼べる形にする
（`fx_layer.gd` の `_configure()` が例）。

## 検証

3層。詳細と実行方法は [CLAUDE.md](../CLAUDE.md) を参照。

| 層 | 手段 | 捕まえるもの |
|---|---|---|
| ロジック | シード固定の `scenario_m*.gd` | 幾何・数値・シグナルの引数 |
| 起動 | `--headless --quit-after 90` | パースエラー、autoload、実行時警告 |
| 描画 | **GUI で目視** | 見た目の破綻 |

**3層目は省略できない。** ヘッドレスの検査はノードを引けるかしか見ておらず、
描画の破損を検出できない（開始画面が黒い矩形になる不具合を2度見逃した）。

検査は「動くか」ではなく「妥当か」を見る。脈動なら「変化するか」ではなく
振幅と周期の上下限を範囲で押さえる。そうしておくと、誰かが値を壊したときに止まる。
