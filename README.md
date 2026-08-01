# EconomySim

Godot 4製の経済シミュレーションゲーム(プロトタイプ)。

## プロジェクト構成

```
scenes/
  main/      メインシーン
  ui/        UI画面(ショップ、ステータスパネルなど)
  entities/  NPC・商品・施設などのシーン
scripts/
  autoload/  グローバル管理(GameState, EconomyManager)
  systems/   価格変動、需要供給などのロジック
  ui/        UI用スクリプト
assets/
  sprites/
  fonts/
  audio/
data/        アイテム・価格などの設定データ(JSON/Resource)
```

## 動作環境

- Godot 4.7.1以降

## セットアップ

1. Godotをインストール(https://godotengine.org/download)
2. Godotのプロジェクトマネージャーで本フォルダの `project.godot` を開く
3. F5またはRunボタンで起動確認

## TODO管理

開発タスクはNotionで管理しています。
