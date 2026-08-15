# Godot と Git の扱い

TollRoad（Godot 4.7.1 / GL Compatibility）の実行・ファイル・コード規約。
[CLAUDE.md](../../CLAUDE.md) から分離した規約のひとつ。

## Godot の実行

バイナリは `PATH` に無い。さらに `Godot_v4.7.1-stable_win64.exe` は**拡張子が .exe のディレクトリ**で、実体はその中にある。必ずフルパスで呼ぶこと。

**置き場所は固定ではない。** 以前は `~/Downloads/` にあり、今は `c:\work\` に
ある。ここに書いたパスで見つからなければ、探してから使うこと
（`.claude/agents/scenario-runner.md` の `find_godot()` が探索の形）。
`--script` のハーネスはパスが違うだけで**何も実行されないまま exit 0 を返す**
ため、パス切れは検査に通ったように見える。

```bash
"/c/work/Godot_v4.7.1-stable_win64.exe/Godot_v4.7.1-stable_win64_console.exe" \
  --headless --path . --quit-after 30
```

期待される出力: `TollRoad start. Day: 1/60, Silver: 30000, City: ironhollow` / exit 0。
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

[game_state.gd](../../scripts/autoload/game_state.gd) は
[GameSession](../../scripts/systems/game_session.gd) を保持するだけの薄い入れ物に留める。

**RNG は必ずシードを渡して生成する。** `GameSession.new(seed)` で再現可能になる。
シードを固定できないと、バグの再現もバランスのバッチ検証もできない。

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
- [export_presets.cfg](../../export_presets.cfg) は**追跡している**。別環境でも同じ設定で
  作れるようにするため。署名鍵など環境固有の値を入れる場合は `.gitignore` へ戻すこと
- `exclude_filter` で `scenario_*.gd` を除外しているので、検証シナリオは配布物に入らない
- `exports/` は `.gitignore` 済み（109MB をリポジトリに入れない）
