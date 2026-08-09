# 改善計画

M8 完走後、今後の拡張に向けた基盤整備。構造の説明は
[architecture.md](architecture.md) を参照。

**この文書は作業が完了したら畳む。** 現状の記述と混ぜないために分けてある
（[roadmap.md](roadmap.md) が実装45行時点で凍結され、現状と乖離した前例がある）。

方針は2つ:

1. **検証基盤の整備** — 変更を安全にする
2. **セーブ/ロード** — roadmap.md で唯一「未決」と明記されている項目

**バランス数値は一切変えない**（CLAUDE.md: 検証済み）。今回は構造のみ。

---

## 前提: 実機で確認した3点

Godot 4.7.1 で実測済み。推測ではない。

| 検証 | 結果 |
|---|---|
| `extends "res://.../scenario_base.gd"` を `--script` で実行 | **動く**。`--script` は SceneTree の派生を要求するが、継承チェーンで満たせばよい |
| 1プロセスで `load(s).new()` を連続実行 | **動く**。子 SceneTree の `quit()` はプロセスを殺さない。ただし `free()` しないと RID リークの ERROR が出る |
| 親から `obj.get("_failures")` で集計 | **動く**。失敗件数を吸い上げて exit code にできる |
| **`await` を含むシナリオを子ツリーで実行** | **動かない**（実装中に判明）。下記 |

→ 共通基底は継承で作れる。一括ランナーは Godot 自身で書ける。
ただし `await` を使う4本だけは別プロセスにする必要がある。

### 実装中に判明: `await` は子ツリーで復帰しない

当初の実測は `await` を使わないシナリオでしか確かめていなかった。
子の `SceneTree` ではフレームループが回らないため `await process_frame` から
**復帰せず、`_init()` が途中で止まる**。`_failures` は0のままなので、
ランナーからは**合格に見える**。実測で m13/m14/m16/m17 の**37件が消えた**
（776件しか走っていなかった）。

落ちるより気づけないぶん質が悪い。対応:

- 該当4本は `OS.execute()` で**別プロセス**として起動し、出力の
  `OK` / `FAIL` 行を数えて取り込む
- `AWAIT_SCENARIOS` に番号を登録する。**登録漏れは `_verify_await_list()` が
  検出して exit 1**（planted test で発火を確認済み）

子ツリーを `process()` で手動に回す案も試したが、**ハングして使えなかった**。

---

## 改善1: 検証基盤

### 1-a. 共通基底 `scripts/systems/scenario_base.gd`

現状、`_check()` が**17本すべてに同一実装で重複**している。`var _failures` と
末尾の `quit(0)/quit(1)` ブロックも同様。`_spawn()` / `_despawn()` は**11本で重複**
（m6〜m14, m16, m17）。

`extends SceneTree` の基底を作り、17本を
`extends "res://scripts/systems/scenario_base.gd"` に差し替える。

持たせるもの: `_failures` / `_checks` / `_spawned`、
`_check()` / `_spawn()` / `_despawn()` / `_finish()`。

**composition（RefCounted ヘルパ）は却下。** `_spawn()` が `root` を、
`_finish()` が `quit()` を要る。どちらも SceneTree のものなので注入が必要になり、
継承の手動再実装にしかならない。継承なら**既存17本の本文を1文字も変えずに済む**。

注意点:

- **命名は `scenario_` 接頭辞が必須。** `export_presets.cfg` の
  `exclude_filter="scripts/systems/scenario_*.gd"` にそのまま乗り、配布物へ混入しない
- 基底に `_init()` を**定義しない**（派生に `super()` の要否を意識させないため）
- `_finish()` は `_despawn()` し忘れたノードも回収する（現状は root に残る）

**段階的に移行する。** 一度に17本書き換えると、基底に不具合があったときの
切り分けが不能になる:

| 段 | 対象 | 検証 |
|---|---|---|
| 1 | 基底 + `_spawn` を使わない `scenario_m1.gd` のみ | m1 単体。出力が移行前と**一字一句同じ**（`diff`） |
| 2 | `_spawn`/`_despawn` を使う `scenario_m6.gd` | m6 単体。同上 |
| 3 | 残り15本を機械的に置換 | 17本すべて + 起動層 |

段1・段2 で出力の完全一致が取れていれば、段3 は安全に進められる。
**そこが崩れたら段3 は止める。**

### 1-b. 一括ランナー `scripts/systems/scenario_all.gd`

現状、一括ランナーが無い。CLAUDE.md のシェル for ループは exit code を
集計しないため、17本流しても `FAIL:` を目視で探すことになる。

Godot で全本を回す。`load(path).new()` で駆動し、
`obj.get("_failures")` で件数を吸い上げ、`obj.free()` で解放する。

**PowerShell 案は却下** — Windows 専用になり、プロセス起動が17回ぶん遅い
（各1秒前後）。

**`await` を使う4本（m13/m14/m16/m17）だけは `OS.execute()` で別プロセス。**
子ツリーでは復帰しないため（前掲）。残り13本は同一プロセスなので、
17回の起動が4回に減る。

- `SCENARIO_COUNT` 定数を置き、起動時に `DirAccess` で `scenario_m*.gd` の
  本数を数えて**照合する**。不一致なら FAIL。シナリオを足して登録し忘れる事故を止める
- `AWAIT_SCENARIOS` の登録漏れも `_verify_await_list()` が検出する
- 各シナリオの print は素通しし、**最後にまとめて要約**
  （合否表 + 落ちたシナリオの単体再実行コマンド）
- **弱点**: 1本がクラッシュや無限ループを起こすと以降が回らない。
  **個別実行も引き続き有効**と CLAUDE.md に明記済み

実測: **813件**の検査が走り、m14 の2件（下記）を検出して exit 1。

### 1-b-2. 判明した既存の不安定: `scenario_m14.gd`

**移行とは無関係の既存の問題。** 一括ランナーを入れて初めて可視化された。

m14 の2つの検査が**実行のたびに結果が変わる**:

- 「終わると自動的に消える」（実際: 3 個残った）
- 「直線より上を通る（弧を描く）」（実際: 中間 286 / 直線 283 など）

同じ状態で5回流すと 3勝2敗といった具合。**移行前のコードでも同じ**
（`git stash` で戻して5回流し、2回落ちることを確認）。

原因は `await process_frame` でアニメーションの途中を標本化していること。
ヘッドレスのフレーム進行は一定でないため、標本の位置が run ごとにずれる。
弧の判定は `mid.y < straight_y` で、実測値は 283 に対して 284〜325 と
**境界を跨いで揺れる**。

対応案（未着手。段5以降とは独立に判断が要る）:

- **標本ではなく式で検査する** — `fx_layer.gd` の軌道を時刻から座標を返す
  純関数に切り出し、位相を指定して評価する（分類3の `pulse_scale_at` と同じ形）。
  フレーム進行に依存しなくなる
- 判定に余裕を持たせる — 弧の高さの下限を定数化し、`straight_y - 余裕` と比べる。
  ただし**閾値を緩めるだけの調整は検査を無意味にする**ので、
  「どれだけ弧を描くべきか」を定義してから決めること

**この2件が残っている限り一括ランナーは exit 1 のまま。**
先に片付けるか、既知として扱うかは判断が要る。

### 1-c. private 依存の解消

シナリオが実装の private を触っている。3つに仕分ける（全部公開するのではない）。

#### 分類1: 純関数 — 公開またはラッパ削除

| 現状 | 措置 | 依存 |
|---|---|---|
| `hud.gd:193 _format_number()` | **削除**。`UiUtil.format_number()` への1行転送でしかない。呼び出し3箇所を直結 | m5 |
| `result_dialog.gd:114 _rank_color()` | **削除**。`UiTheme.rank_color()` への1行転送 | m8 |
| `market_panel.gd:247 _arrow()` | `arrow_for()` にリネームして公開 | m16 |
| `sfx.gd:94 _stream_for()` | `stream_for()` にリネームして公開 | m15 |

ラッパを公開名にするのは、private 依存を「無意味なラッパへの依存」に
置き換えるだけ。m13 は既に `UiUtil.format_number()` を直接呼んでおり、
m5 だけが揃っていない。

#### 分類2: テスト用アクセサを足す

**辞書をそのまま公開しない**（キー構造まで契約になる）。用途ごとの細い関数を足す。

- `market_panel.gd` — `price_bar_for()` / `badge_text_for()` /
  `ratio_text_for()` / `accent_for()`。バッジと比率は **Label でなく String を返す**
  （Label という実装の選択を契約から外す）。`_rows` は private のまま
- `map_panel.gd` — `node_for()` / `node_count()` / `note_text_for()`、
  `_layout_nodes()`（292行目）→ `layout_nodes()` に公開。
  **ツリー外では `resized` が飛ばないため、シナリオが手で呼ぶ以外に
  配置を確定させる手段がない** — テストのための抜け道ではなく、正当な入口
- `sfx.gd` — `voice_count()`（m15 は `_voices.size()` しか見ていない）
- `hud._refresh_net_worth()` — **実装変更不要**。m13 を `hud.refresh()` に
  直すだけで済む（`refresh()` の中で呼ばれている）

実装して分かったこと（段5 完了時）:

- **`badge_text_for()` は隠れているバッジを空文字で返す。** m16 は元々
  `badge.visible and badge.text.contains(...)` と書いていた。String を返す形に
  すると `visible` が失われるので、**非表示なら空文字**という規約にして
  意味を保った。文字だけ残って非表示、という状態を見逃さない
- **m11 の検査が厳しくなった。** 元は `if note != null:` で囲まれていて、
  ラベルが無いと**検査ごと素通り**していた。`note_text_for()` は必ず String を
  返すので、囲いを外して常に評価されるようにした（検査の数は変わらない）
- `map_panel.layout_nodes()` の公開理由はドキュメントコメントに残した。
  ツリー外では `resized` が飛ばないという実行環境の制約に対する入口であり、
  テストのための抜け道ではない

#### 分類3: 触るのをやめる

`map_view_3d.gd` の `_pulse_time` への**書き込み**（m17 が4箇所: 219/221/235/240行）。
唯一の書き込み依存で、CLAUDE.md 自身が負債と認めている箇所。

時刻を引数に取る純関数へ切り出す:

```gdscript
## 経過時間に対する半径の倍率。1.0 を中心にゆっくり上下する。
##
## 内部状態を持たない純関数にしてあるのは、位相ごとの振る舞いを
## --script の検査から直接確かめられるようにするため
## （以前は _pulse_time を外から書き換えていた）。
static func pulse_scale_at(elapsed: float) -> float


## 指定した位相でリングを引き直す。検査は時間を進められないため、
## 位相を渡して任意の瞬間を再現できるようにする。
func redraw_selection_ring_at(elapsed: float) -> void
```

`_redraw_selection_ring()` は倍率を引数で受け取る形に変え、`_process` からは
`pulse_scale()` を渡す。これで**内部状態への書き込みがゼロ**になり、
`_pulse_time` は private のまま閉じる。

→ CLAUDE.md の「検査から内部変数を触った箇所は覚えておく」節は該当なしになるので
**削除し**、「シナリオは公開 API だけを触る。ツリー外の制約で必要な入口は公開する
（`layout_nodes`, `pulse_scale_at`）」に書き換える。

---

## 改善2: セーブ/ロード

### 形式: JSON（`user://savegame.json`）

`GameSession` の状態は int / String / Dictionary / Array[String] のみで
JSON の型と完全一致する。人間が開いて読めるのでバグ調査で効く。

- ConfigFile は却下 — 入れ子の `memo[city]["prices"][item]` が素直に入らない
- Resource (.tres) は却下 — エンジンのシリアライズ規則に縛られ、
  プロパティ名の変更が破壊的になる

#### 踏む前に潰す落とし穴が2つ

1. **`JSON.parse_string()` は全ての数値を float で返す。**
   `from_dict()` 側で必ず `int()` を通す。これを外すと、値が一致していても
   後で `silver / price` の整数除算が浮動小数除算に化ける

2. **`_rng.state` は 64bit で、JSON の double（仮数部53bit）では正確に往復しない。**
   → **seed と state は文字列で保存し、`String.to_int()` で戻す。**

2つ目が**この設計で最も重要な一点**。外すと「再現性がある」つもりで静かに壊れる。

実測（段7）: `state = 4857946085375722947` を数値のまま JSON に通すと
`4857946085375722496` に化ける。大きい seed は符号まで反転する。
文字列なら `String.to_int()` で正確に戻る。

**検査は必ず JSON を通すこと（段7 で判明）。** `to_dict()` の結果どうしを
比べても意味がない — メモリ上では数値でも 64bit は欠けないため、
**数値で保存する実装のままでも検査が通ってしまう**。実際に最初に書いた
検査はこれを見逃し、わざと数値保存に戻しても素通りした。
`JSON.stringify()` → `JSON.parse_string()` を挟んで初めて捕まる。

なお `silver` のような**型付き変数への代入は GDScript が int へ丸める**ため、
`int()` を外しても壊れない。`int()` が実際に効くのは `cargo` の個数や
`prices` のような**辞書の中身**（型注釈が効かない場所）。

### 置き場所: 2層に分ける

**層1 — `GameSession.to_dict()` / `from_dict()`**（状態の写し取り）

セッションの内部を知っているのはセッション自身だけ。ここに置けば `_rng` を
外へ公開せずに済む。

`from_dict()` は**既存インスタンスへの上書き**にする。`_init()` が
`PriceTable.new()` と `_record_memo()` を走らせるため、素の状態を作る経路を
別に用意するより、作ってから上書きする方が既存コードに触らずに済む:

```gdscript
var session := GameSession.new(0)
session.from_dict(data)
```

欠損キーは `data.get(key, 既定値)` で「触らない」= 宣言時の初期値が残る形にする。
初期値の定義が1箇所に留まる。

**層2 — `scripts/systems/save_manager.gd`**（ファイル入出力と版管理）

`extends RefCounted` の素のクラス、`static func` のみ。autoload に置かない規約に従う。

`save_game()` / `load_game()` / `has_save()` / `delete_save()` / `last_error()`。

**すべて `path` を引数に取り既定値を持たせる。** シナリオが
`user://scenario_m18_tmp.json` を使えるようになり、プレイヤーの実セーブを
壊さずに検査できる。

**`GameState`（autoload）は入口を2つ足すだけ** — `continue_game()` / `save_game()`。
`session_started` を発火させれば既存の UI 再バインド経路にそのまま乗るので、
**UI 側の新規配線は不要**。

### 保存する状態

`version` / `day` / `silver` / `current_city` / `mount` / `island_level` /
`cargo` / `warehouse` / `memo` / `log_entries` / `prices` / `rng{seed, state}`。

**`prices` の保存が必要な理由**: `reroll()` は「次の日の相場」を作るもので、
今日の値を再現しない。RNG の state を戻して `reroll()` を呼んでも、
次の日ぶんが出てくるだけで今日の相場は失われる。

`to_dict()` の中で `prices` と `rng` を続けて読めば、間に RNG 消費が挟まらず整合する。

### 後方互換

原則: **「足す」は版を上げない、「意味を変える」は上げる。**

| 変更 | 版 | 古いセーブの扱い |
|---|---|---|
| 品目・都市の追加／削除 | 上げない | 未知キーは捨て、欠損キーは既定値 |
| `GameSession` に状態変数を追加 | 上げない | 欠損 = 宣言時の初期値 |
| 既存キーの**意味**が変わる | **上げる** | `_migrate()` に変換を書く。書かないなら `MIN_SUPPORTED_VERSION` を上げて拒否 |

個別の判断:

- **`prices` は一部欠損なら部分補完せず `reroll()` で作り直す。**
  一部だけ埋めると、その品目だけ乱数系列の外の値になる。1日ぶん相場が変わるが、
  古いセーブを開いた時だけの説明のつく副作用で、決定性は保たれる
- **`version > SAVE_VERSION` は推測で読まず拒否。** 新しい版で意味が変わったキーを
  旧解釈で読むと、静かに壊れた状態で遊ぶことになる
- **`current_city` が未知なら復元を拒否。** 黙って現在地が変わると積荷と移動費の
  前提が崩れる。`mount` / `island_level` は範囲の問題なので既定値へ丸めてよい
- JSON が壊れている場合も `null` + `last_error()`。**例外は投げない**（GDScript に無い）

### UI からの導線（最小限）

「状態を正しく往復できる」ことを優先し、導線は最小に留める。

- **自動保存: 日が進むたび。** `GameState` が `session.day_advanced` に繋ぐ。
  1日1回程度の頻度で数KB の書き出しなので負荷にならない。手動保存の UI
  （スロット選択、上書き確認）は作らない
- **ロードの入口: 開始画面**（`BriefingDialog`）。`has_save()` が true のときだけ
  「続きから」を出す
- **新規開始でセーブを消す。** 消さないと「新規開始 → 何もせず終了 → 続きから」で
  古いセーブが復活する
- **60日終了後は保存しない**（結果画面から終わった状態に戻れても意味がない）

### `scenario_m18.gd`

- `_test_round_trip()` — 30日ぶん遊んで全フィールドを埋めてから往復。
  **prices は54項目を個別に比較**（`==` 一発だと落ちた時にどの都市のどの品目か
  分からない）。**型が int で戻ることも検査**（float 化の歯止め）
- `_test_rng_continuity()` — 保存後10日ぶんの価格系列を**日ごとに**記録して一致を見る
  （10日後の1点だけだと途中でずれて偶然戻るのを見逃す）。島レベルを上げた状態でやる
  （`_run_workers()` が RNG を消費するため）。加えて **state を捨てると系列がずれること
  も検査** — 実装の正しさではなく「この検査が意味を持つこと」の裏取り
- `_test_prices_preserved()` — 復元直後は当日の相場のまま、**かつ** `rest()` すると
  変わる。両方見る（前者だけだと相場が凍ったバグを見逃す）
- `_test_version_mismatch()` — 新しすぎる／古すぎる／`version` キー無し。
  **`last_error()` が空でないことまで見る**（null だけでは UI が理由を出せない）
- `_test_missing_keys()` — 各キーを1つずつ落として既定値が残ることを確認。
  特に `prices` 欠損時に `reroll()` 済みの54項目が入っていること
- `_test_unknown_keys()` — 未知のフィールド／品目 ID／都市を混ぜても壊れないこと
- `_test_corrupt_file()` — 存在しない・`{` だけ・配列・空。**どれも落ちないこと**
- `_test_file_io()` — 実ファイルの往復。**専用パスを使い最後に必ず消す**
  （`SAVE_PATH` の既定値をシナリオが使わないことを規約にする）

`scenario_all.gd` の `SCENARIO_COUNT` を 17 → 18 に更新する
（本数照合が更新漏れを検出する）。

---

## 実装順序

| 段 | 作業 | 検証 | 状態 |
|---|---|---|---|
| 1 | `scenario_base.gd` + m1 移行 | m1 単体、出力が移行前と完全一致 | **完了** |
| 2 | m6 移行 | m6 単体、同上 | **完了** |
| 3 | 残り15本 | 17本すべて + 起動層 | **完了** |
| 4 | `scenario_all.gd` | 全合格で exit 0。1本わざと壊して exit 1 と要約表を確認、戻す | **完了** |
| 5 | private 分類1・2 | 17本 + 起動 | **完了** |
| 6 | private 分類3（脈動） | 17本 + 起動 + **GUI で目視** | **完了** |
| 7 | `to_dict()` / `from_dict()` | m18 の往復・RNG・相場の3本 | **完了** |
| 8 | `save_manager.gd` + 版・エラー処理 | m18 全本 | **完了** |
| 9 | `GameState` の入口 + 自動保存 + 「続きから」 | 18本 + 起動 + **GUI で目視** | **完了** |
| 10 | CLAUDE.md / roadmap.md 更新 | — | **完了** |

**全段完了（2026-08-09）。** 実測 18本 898件、m14 の既知2件のみ失敗。

段9 で分かったこと: **`GameState._ready()` でセーブを消してはいけない。**
当初の設計どおり起動時のセッションを `start_new_game()` で作ると、その中の
`delete_save()` が走って「続きから」が永遠に出ない。セーブを捨てるのは
「新規で始める」と決まった時点（開始画面を閉じた時）にした。

段1〜5、7〜8 はヘッドレスで完結する。**段6と段9だけが3層目（GUI 目視）を要する。**
段6 は `_redraw_selection_ring()` の引数を変えるため、脈動が止まる・暴れるといった
破綻がヘッドレスでは見えない。

## 検証

```bash
# 1層目（段4以降は一括ランナー）
"/c/Users/Tamar/Downloads/Godot_v4.7.1-stable_win64.exe/Godot_v4.7.1-stable_win64_console.exe" \
  --headless --path . --script scripts/systems/scenario_all.gd

# 2層目
"...console.exe" --headless --path . --quit-after 90

# 3層目（段6・段9は必須。判断は人に委ねる）
"...Godot_v4.7.1-stable_win64.exe" --path .
```

## 注意点

- **`.uid` を必ずコミット**（新規スクリプト4本ぶん）
- `export_presets.cfg` は**触らない**。`scenario_base.gd` / `scenario_all.gd` /
  `scenario_m18.gd` は `scenario_*` に合致して自動的に除外され、
  `save_manager.gd` は配布物に入る（どちらも正しい）
- **`from_dict()` の中で `_log()` を呼ばない。** 復元処理自身がログを足すと
  往復同一性の検査が落ちる。`prices` を reroll した通知は `print` に留める
  （セーブの都合はプレイヤーの航海日誌に書くことではない）
- `JSON.stringify(data, "\t")` でインデントする。数KB 増えるだけで、
  中身を目で追える利得の方が大きい
- `FileAccess.open()` の戻り値を必ず null 検査する（`user://` が書けない環境がある）
