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

## 現在の実装状況

M1 まで完了（[roadmap.md](docs/roadmap.md) 参照）。品目9種・都市6つ・価格計算・
売買・移動・日送り・相場メモがヘッドレスで動く。

未着手: 製作と黒ゾーン襲撃（M2）、島と騎乗（M3）、60日通しとランク判定（M4）、UI 一式（M5〜）。
ウィンドウ解像度（`[display]`）は未設定で Godot デフォルトの 1152x648。M5 で決める。
