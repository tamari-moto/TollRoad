# CLAUDE.md

TollRoad（Godot 4.7.1 / GL Compatibility）で作業する際の規約の入口。
プロジェクト構成とセットアップ手順は [README.md](README.md) を参照。

規約は領域ごとに [docs/rules/](docs/rules/) へ分けてある。**触る領域の
ファイルを読んでから作業すること。** ここには全領域に効く最重要の罠だけを
置いてある。

| ファイル | 何が書いてあるか |
|---|---|
| [rules/godot.md](docs/rules/godot.md) | Godot の起動コマンド、autoload の扱い、`.uid`/`.tscn` の扱い、Git 運用、コード規約、配布用ビルド |
| [rules/testing.md](docs/rules/testing.md) | シード固定シナリオの書き方、検証の3層、検査が満たすべき条件 |
| [rules/ui.md](docs/rules/ui.md) | ツリー外の罠、パネルの規約、手書き `.tscn`、大陸図（3D）、価格バーと効果音 |
| [rules/save.md](docs/rules/save.md) | セーブ形式、版の扱い、復元の責務、RNG の消費順 |
| [rules/balance.md](docs/rules/balance.md) | バランスの実測値と、それが未再検証である理由 |
| [status.md](docs/status.md) | 現在の実装状況（**時期に依存するのはここだけ**） |
| [architecture.md](docs/architecture.md) | 構造の説明（規約ではない） |
| [game_design.md](docs/game_design.md) | ゲーム内容の設計 |
| [roadmap.md](docs/roadmap.md) | 開発の道筋 |

## 最初に知っておくこと

以下は領域をまたいで効き、踏むと**気づきにくい**形で壊れる。

**autoload を識別子として書かない。** `GameState.session` と書くとコンパイル時に
autoload レジストリを引き、`--script` のハーネスからそのスクリプト自体が
ロードできなくなる。`get_node_or_null("/root/GameState")` で実行時に引き、
検査が差し込める入口（`bind_state()`）を用意する。
→ [rules/godot.md](docs/rules/godot.md)

**ロジックは autoload に置かない。** `scripts/systems/` に素のクラスとして書き、
`load()` + `.new()` で駆動できる形を保つ。**RNG は必ずシードを渡して生成する**
（`GameSession.new(seed)`）。固定できないとバグの再現もバランス検証もできない。
→ [rules/godot.md](docs/rules/godot.md)

**`_ready()` に初期化を置かない。** `--script` のハーネスでは
`root.add_child()` しても走らない（実測: `is_node_ready()` は false のまま）。
`@onready` も代入されない。`_configure()` のような形にして両方から呼ぶ。
→ [rules/ui.md](docs/rules/ui.md)

**検証は3層。** ロジック（シナリオ）・起動（`--quit-after`）・**描画（GUI で目視）**。
ヘッドレスは描画の破損を検出できない。見た目に関わる変更は必ず GUI を起動し、
**その判断は人に委ねる**。
→ [rules/testing.md](docs/rules/testing.md)

**書いた検査は1度壊して確かめる。** 落ちなければ検査になっていない。
実装の判定を検査に書き写さないこと（両方が同時にずれると素通りする）。
→ [rules/testing.md](docs/rules/testing.md)

**バランスの数値を調整しない。** 実測済みで、変える前に20〜30回の通しプレイが要る。
→ [rules/balance.md](docs/rules/balance.md)

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
