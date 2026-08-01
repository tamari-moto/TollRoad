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

## 現在の実装状況

M6 まで完了（[roadmap.md](docs/roadmap.md) 参照）。**マウスだけで交易が回せる**
状態。市場での売買（数量 1/5/半分/全部）、積荷バー、大陸図と移動確認ダイアログ、
航海日誌、休息が動く。解像度は 1280x720。

検証シナリオは `scripts/systems/scenario_m1.gd` 〜 `scenario_m6.gd` の6本。
新しい機能を足したら対応するシナリオも足すこと。

UI パネルは `bind(session)` と `refresh()` を持つ規約。ノード解決は
[ui_util.gd](scripts/ui/ui_util.gd) の `find_node()` を使う。

未着手: 製作所・相場メモ・島と装備の画面（M7）、リザルトと調整（M8）。

**バランスについて**: 単純戦略（安く買って高く売る）での60日プレイは中央値
57,763 で、目標の MASTER TRADER（500,000）には届かない。これは意図された設計で、
製作 → 騎乗投資 → 装備の大量輸送という成長ルートを見つけた場合にのみ到達する。
数値を安易に調整しないこと。
ウィンドウ解像度（`[display]`）は未設定で Godot デフォルトの 1152x648。M5 で決める。
